class Api::V1::TicketsController < ActionController::API
  before_action :authenticate_request!
  before_action :set_ticket, only: [:show]


  # POST /api/v1/tickets
  def create
    ticket = Ticket.new(ticket_params)

    if ticket.save
      TicketTriageJob.perform_later(ticket.id)
      render json: {
        ticket_id: ticket.id,
        status: ticket.status,
        message: "Ticket created and queued for triage."
      }, status: :accepted
    else
      render json: {
        errors: ticket.errors.full_messages
      }, status: :unprocessable_entity
    end
  end

  # GET /api/v1/tickets/:id
  def show
    render json: {
      ticket_id: @ticket.id,
      external_id: @ticket.external_id,
      customer_email: @ticket.customer_email,
      status: @ticket.status,
      category: @ticket.category,
      urgency: @ticket.urgency,
      summary: @ticket.summary,
      suggested_reply: @ticket.suggested_reply,
      error_message: @ticket.error_message,
      metadata: @ticket.metadata,
      created_at: @ticket.created_at,
      updated_at: @ticket.updated_at
    }, status: :ok
  end

  private

  def authenticate_request!
    token = request.headers["Authorization"]&.split(" ")&.last
    expected_token = ENV.fetch("API_AUTH_TOKEN", "triage-mvp-token")

    if token != expected_token
      render json: { error: "Unauthorized" }, status: :unauthorized
    end
  end

  def set_ticket
    @ticket = Ticket.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Ticket not found" }, status: :not_found
  end

  def ticket_params
    # Permitting metadata as a hash
    params.require(:ticket).permit(:customer_email, :subject, :body, :external_id).tap do |whitelisted|
      whitelisted[:metadata] = params[:ticket][:metadata].to_unsafe_h if params[:ticket][:metadata].is_a?(Hash)
    end
  end
end

