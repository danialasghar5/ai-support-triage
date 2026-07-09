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
  rescue Ai::TriageService::PermanentError => e
    # Terminal failure (bad request, auth, refusal). Record and swallow so
    # Sidekiq does not retry — a retry cannot succeed.
    ticket&.update(status: :failed, error_message: e.message)
    log_event("ticket_triage.failed", ticket_id: ticket&.id, error_class: e.class.name, retryable: false)
  rescue => e
    # Transient or unexpected failure. Record, then re-raise so Sidekiq retries
    # per sidekiq_options. Sidekiq remains the only retry authority.
    ticket&.update(status: :failed, error_message: e.message)
    log_event("ticket_triage.failed", ticket_id: ticket&.id, error_class: e.class.name, retryable: true)
    raise e
  end

  private

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
