class TicketTriageJob < ApplicationJob
  queue_as :default
  sidekiq_options retry: 3

  def perform(ticket_id)
    ticket = Ticket.find(ticket_id)

    # Atomically claim the ticket. If another worker already holds it (or it is
    # done), we return without calling the LLM. This guarantees at most one
    # triage call per ticket even when duplicate jobs run concurrently.
    return unless claim(ticket)

    triage_results = Ai::TriageService.call(ticket)

    ticket.update!(
      category: triage_results[:category],
      urgency: triage_results[:urgency],
      summary: triage_results[:summary],
      suggested_reply: triage_results[:suggested_reply],
      status: :completed
    )
  rescue ActiveRecord::RecordNotFound
    # Ticket was deleted before we could process it. Nothing to record or retry.
    nil
  rescue Ai::TriageService::PermanentError => e
    # Terminal failure (bad request, auth, refusal). Record and swallow so
    # Sidekiq does not retry — a retry cannot succeed.
    ticket&.update(status: :failed, error_message: e.message)
  rescue => e
    # Transient or unexpected failure. Record, then re-raise so Sidekiq retries
    # per sidekiq_options. Sidekiq remains the only retry authority.
    ticket&.update(status: :failed, error_message: e.message)
    raise e
  end

  private

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
