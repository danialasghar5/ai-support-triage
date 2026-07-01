class TicketTriageJob < ApplicationJob
  queue_as :default

  def perform(ticket_id)
    ticket = Ticket.find(ticket_id)
    return if ticket.completed? # Idempotency: avoid reprocessing already completed tickets

    ticket.processing!
    ticket.update!(error_message: nil)

    triage_results = Ai::TriageService.call(ticket)

    ticket.update!(
      category: triage_results[:category],
      urgency: triage_results[:urgency],
      summary: triage_results[:summary],
      suggested_reply: triage_results[:suggested_reply],
      status: :completed
    )
  rescue => e
    # Persist the failure details for internal triage / dashboard monitoring
    ticket&.update(
      status: :failed,
      error_message: e.message
    )
    
    # Re-raise to trigger Sidekiq's retry framework
    raise e
  end
end

