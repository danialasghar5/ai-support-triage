class Api::V1::TicketsController < ActionController::API
  before_action :authenticate_request!
  before_action :set_ticket, only: [ :show ]

  # POST /api/v1/tickets
  #
  # Ingestion is idempotent on external_id: re-delivering the same ticket
  # returns the original record instead of creating a duplicate (and a
  # duplicate triage job).
  def create
    ticket = Ticket.new(ticket_params)

    if ticket.external_id.present? && (existing = Ticket.find_by(external_id: ticket.external_id))
      return render_existing(existing)
    end

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
  rescue ActiveRecord::RecordNotUnique
    # Lost the race with a concurrent, identical ingestion. The unique index
    # guarantees exactly one row exists; return it.
    render_existing(Ticket.find_by!(external_id: ticket.external_id))
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
    expected_token = ENV["API_AUTH_TOKEN"]

    # Fail closed: an unconfigured server must never accept requests.
    if expected_token.blank?
      return render json: { error: "Server authentication is not configured" }, status: :service_unavailable
    end

    token = request.headers["Authorization"]&.split(" ")&.last

    unless token.present? && ActiveSupport::SecurityUtils.secure_compare(token, expected_token)
      render json: { error: "Unauthorized" }, status: :unauthorized
    end
  end

  def set_ticket
    @ticket = Ticket.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Ticket not found" }, status: :not_found
  end

  def render_existing(ticket)
    render json: {
      ticket_id: ticket.id,
      status: ticket.status,
      message: "Ticket already exists."
    }, status: :ok
  end

  def ticket_params
    # Permitting metadata as a hash
    params.require(:ticket).permit(:customer_email, :subject, :body, :external_id).tap do |whitelisted|
      whitelisted[:metadata] = params[:ticket][:metadata].to_unsafe_h if params[:ticket][:metadata].is_a?(Hash)
    end
  end
end
