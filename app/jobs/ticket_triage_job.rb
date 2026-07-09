class TicketTriageJob < ApplicationJob
  queue_as :default
  sidekiq_options retry: 3

  def perform(ticket_id)
    ticket = Ticket.find(ticket_id)

    # Atomically claim the ticket. If another worker already holds it (or it is
    # done), we return without calling the LLM. This guarantees at most one
    # triage call per ticket even when duplicate jobs run concurrently.
    unless claim(ticket)
      log_event("ticket_triage.skipped", ticket_id: ticket.id, status: ticket.status)
      return
    end

    triage_results = Ai::TriageService.call(ticket)

    ticket.update!(
      category: triage_results[:category],
      urgency: triage_results[:urgency],
      summary: triage_results[:summary],
      suggested_reply: triage_results[:suggested_reply],
      status: :completed
    )
    log_event("ticket_triage.completed", ticket_id: ticket.id)
  rescue ActiveRecord::RecordNotFound
    # Ticket was deleted before we could process it. Nothing to record or retry.
    log_event("ticket_triage.not_found", ticket_id: ticket_id)
  rescue Ai::TriageService::PermanentError, ActiveRecord::RecordInvalid => e
    # Terminal failure (bad request, auth, refusal, or output that fails our
    # own validations, e.g. an over-length category). A retry cannot succeed,
    # so record and swallow.
    fail_ticket(ticket, e)
    log_event("ticket_triage.failed", ticket_id: ticket&.id, error_class: e.class.name, retryable: false)
  rescue => e
    # Transient or unexpected failure. Record, then re-raise so Sidekiq retries
    # per sidekiq_options. Sidekiq remains the only retry authority.
    fail_ticket(ticket, e)
    log_event("ticket_triage.failed", ticket_id: ticket&.id, error_class: e.class.name, retryable: true)
    raise e
  end

  private

  # Persist the failed state without re-running validations. After a failed
  # completion write the in-memory record still carries the rejected attributes
  # (e.g. an over-length category), so a validating update would fail again and
  # strand the ticket in `processing`. update_columns writes directly and always
  # succeeds, guaranteeing the ticket can always leave `processing`.
  def fail_ticket(ticket, error)
    return unless ticket&.persisted?

    ticket.update_columns(status: "failed", error_message: error.message.to_s.truncate(1000))
  end

  # Structured (logfmt) line for the job's terminal outcome. Identifiers and
  # metrics only — never ticket content.
  def log_event(event, **fields)
    pairs = { event: event }.merge(fields)
    Rails.logger.info(pairs.map { |k, v| "#{k}=#{v}" }.join(" "))
  end

  # Transition pending/failed -> processing inside a row lock so two workers
  # can't both proceed. The lock is held only for this fast state change, never
  # across the LLM call. Returns true if this worker won the claim.
  def claim(ticket)
    ticket.with_lock do
      return false if ticket.completed? || ticket.processing?

      ticket.update!(status: :processing, error_message: nil)
      true
    end
  end
end
