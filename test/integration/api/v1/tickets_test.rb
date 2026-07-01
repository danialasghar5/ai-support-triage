require "test_helper"


class Api::V1::TicketsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  def auth_headers
    { "Authorization" => "Bearer triage-mvp-token" }
  end

  test "should return unauthorized when auth header is missing or invalid" do
    post api_v1_tickets_path, params: { ticket: { customer_email: "test@example.com", body: "help" } }, as: :json
    assert_response :unauthorized
    assert_equal "Unauthorized", JSON.parse(response.body)["error"]

    post api_v1_tickets_path, params: { ticket: { customer_email: "test@example.com", body: "help" } }, headers: { "Authorization" => "Bearer bad-token" }, as: :json
    assert_response :unauthorized

    get api_v1_ticket_path(tickets(:two)), as: :json
    assert_response :unauthorized
  end

  test "should create ticket and enqueue triage job when parameters are valid and authenticated" do
    assert_enqueued_jobs 1, only: TicketTriageJob do
      post api_v1_tickets_path, params: {
        ticket: {
          customer_email: "test@example.com",
          subject: "Broken widget",
          body: "My widget broke, please help!",
          external_id: "ext-123",
          metadata: { plan: "pro" }
        }
      }, headers: auth_headers, as: :json
    end

    assert_response :accepted
    json_response = JSON.parse(response.body)
    assert_not_nil json_response["ticket_id"]
    assert_equal "pending", json_response["status"]
  end

  test "should return unprocessable entity when parameters are invalid and authenticated" do
    assert_no_enqueued_jobs do
      post api_v1_tickets_path, params: {
        ticket: {
          customer_email: "invalid-email",
          body: ""
        }
      }, headers: auth_headers, as: :json
    end

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_includes json_response["errors"], "Customer email is invalid"
    assert_includes json_response["errors"], "Body can't be blank"
  end

  test "should show ticket classification details when ticket exists and authenticated" do
    ticket = tickets(:two)

    get api_v1_ticket_path(ticket), headers: auth_headers, as: :json

    assert_response :ok
    json_response = JSON.parse(response.body)
    assert_equal ticket.id, json_response["ticket_id"]
    assert_equal "completed", json_response["status"]
    assert_equal "billing", json_response["category"]
    assert_equal "high", json_response["urgency"]
    assert_equal "Problem with billing.", json_response["summary"]
    assert_equal "We will refund your amount.", json_response["suggested_reply"]
    assert_equal({ "source" => "web" }, json_response["metadata"])
  end

  test "should return not found for non-existent ticket ID and authenticated" do
    get api_v1_ticket_path(id: SecureRandom.uuid), headers: auth_headers, as: :json

    assert_response :not_found
    json_response = JSON.parse(response.body)
    assert_equal "Ticket not found", json_response["error"]
  end
end

