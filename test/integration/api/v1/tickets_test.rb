require "test_helper"


class Api::V1::TicketsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  def auth_headers
    { "Authorization" => "Bearer #{ENV['API_AUTH_TOKEN']}" }
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

  test "should fail closed with service unavailable when server token is not configured" do
    original = ENV.delete("API_AUTH_TOKEN")

    # Even a well-formed request must be rejected when the server has no secret.
    get api_v1_ticket_path(tickets(:two)), headers: { "Authorization" => "Bearer anything" }, as: :json
    assert_response :service_unavailable
    assert_equal "Server authentication is not configured", JSON.parse(response.body)["error"]
  ensure
    ENV["API_AUTH_TOKEN"] = original
  end

  test "should be idempotent on external_id, returning the existing ticket without a second job" do
    payload = {
      ticket: {
        customer_email: "dupe@example.com",
        subject: "Duplicate delivery",
        body: "Same webhook delivered twice.",
        external_id: "ext-dup-1"
      }
    }

    assert_difference -> { Ticket.count }, 1 do
      assert_enqueued_jobs 1, only: TicketTriageJob do
        post api_v1_tickets_path, params: payload, headers: auth_headers, as: :json
      end
    end
    assert_response :accepted
    first_id = JSON.parse(response.body)["ticket_id"]

    # Re-delivery: no new row, no new job, and the original ticket_id is returned.
    assert_no_difference -> { Ticket.count } do
      assert_no_enqueued_jobs only: TicketTriageJob do
        post api_v1_tickets_path, params: payload, headers: auth_headers, as: :json
      end
    end
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal first_id, body["ticket_id"]
    assert_equal "Ticket already exists.", body["message"]
  end

  test "should allow multiple tickets without an external_id" do
    2.times do |i|
      post api_v1_tickets_path, params: {
        ticket: { customer_email: "no-ext-#{i}@example.com", body: "help" }
      }, headers: auth_headers, as: :json
      assert_response :accepted
    end
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
