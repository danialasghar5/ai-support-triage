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
  rescue => e
    # Persist the failure details for internal triage / dashboard monitoring.
    ticket&.update(status: :failed, error_message: e.message)

    # Re-raise to trigger Sidekiq's retry framework.
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
