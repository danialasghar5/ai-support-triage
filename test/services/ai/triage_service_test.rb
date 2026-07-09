require "test_helper"

# Exercises the real OpenAI::Client through Faraday (including its :raise_error
# middleware) via WebMock, so the request shape, error classification, and JSON
# parsing are all verified against real HTTP behavior rather than a stubbed client.
class Ai::TriageServiceTest < ActiveSupport::TestCase
  ENDPOINT = "https://api.openai.com/v1/chat/completions".freeze

  VALID_CONTENT = {
    "category" => "billing",
    "urgency" => "high",
    "summary" => "Charged twice for subscription.",
    "suggested_reply" => "Hello, we will resolve this billing issue."
  }.freeze

  # Wrap a content hash in the OpenAI chat-completion response envelope.
  def chat_body(content_hash)
    { choices: [ { message: { content: content_hash.to_json } } ] }.to_json
  end

  def stub_openai(status: 200, body: nil)
    stub_request(:post, ENDPOINT).to_return(
      status: status,
      body: body || chat_body(VALID_CONTENT),
      headers: { "Content-Type" => "application/json" }
    )
  end

  # --- Success + request contract -------------------------------------------

  test "should return the parsed triage hash on a successful response" do
    stub_openai
    result = Ai::TriageService.call(tickets(:one))

    assert_equal :billing, result[:category].to_sym
    assert_equal :high, result[:urgency].to_sym
    assert_equal "Charged twice for subscription.", result[:summary]
    assert_equal "Hello, we will resolve this billing issue.", result[:suggested_reply]
  end

  test "should send a well-formed request matching our schema contract" do
    stub_openai
    ticket = tickets(:one)
    Ai::TriageService.call(ticket)

    assert_requested(:post, ENDPOINT) do |req|
      payload = JSON.parse(req.body)
      schema = payload.dig("response_format", "json_schema", "schema")

      assert_equal "gpt-4o-mini", payload["model"]
      assert_equal 0.1, payload["temperature"]
      assert_equal "json_schema", payload.dig("response_format", "type")
      assert_equal Ticket::URGENCIES, schema.dig("properties", "urgency", "enum")
      assert_equal Ai::TriageService::REQUIRED_FIELDS.map(&:to_s), schema["required"]
      assert(payload["messages"].any? { |m| m["content"].to_s.include?(ticket.body) })
      true
    end
  end

  # --- Error classification (through the real Faraday middleware) ------------

  RETRYABLE_STATUSES = { "rate limit (429)" => 429, "server error (500)" => 500, "bad gateway (502)" => 502 }.freeze
  PERMANENT_STATUSES = { "bad request (400)" => 400, "unauthorized (401)" => 401, "forbidden (403)" => 403 }.freeze

  RETRYABLE_STATUSES.each do |label, status|
    test "should classify #{label} as a TransientError" do
      stub_openai(status: status, body: { error: { message: label } }.to_json)
      assert_raises(Ai::TriageService::TransientError) { Ai::TriageService.call(tickets(:one)) }
    end
  end

  PERMANENT_STATUSES.each do |label, status|
    test "should classify #{label} as a PermanentError" do
      stub_openai(status: status, body: { error: { message: label } }.to_json)
      assert_raises(Ai::TriageService::PermanentError) { Ai::TriageService.call(tickets(:one)) }
    end
  end

  test "should classify a network timeout as a TransientError" do
    stub_request(:post, ENDPOINT).to_timeout
    assert_raises(Ai::TriageService::TransientError) { Ai::TriageService.call(tickets(:one)) }
  end

  # --- Malformed / refusal / missing-field output ---------------------------

  test "should raise PermanentError when the model refuses the request" do
    stub_openai(body: { choices: [ { message: { refusal: "I can't help with that." } } ] }.to_json)
    assert_raises(Ai::TriageService::PermanentError) { Ai::TriageService.call(tickets(:one)) }
  end

  test "should raise PermanentError on empty content" do
    stub_openai(body: { choices: [ { message: { content: "" } } ] }.to_json)
    assert_raises(Ai::TriageService::PermanentError) { Ai::TriageService.call(tickets(:one)) }
  end

  test "should raise PermanentError on malformed JSON content" do
    stub_openai(body: { choices: [ { message: { content: "{not json" } } ] }.to_json)
    assert_raises(Ai::TriageService::PermanentError) { Ai::TriageService.call(tickets(:one)) }
  end

  test "should raise PermanentError when a required field is missing" do
    incomplete = VALID_CONTENT.except("urgency")
    stub_openai(body: chat_body(incomplete))
    assert_raises(Ai::TriageService::PermanentError) { Ai::TriageService.call(tickets(:one)) }
  end

  test "should raise PermanentError when a required field is blank" do
    blank = VALID_CONTENT.merge("summary" => "")
    stub_openai(body: chat_body(blank))
    assert_raises(Ai::TriageService::PermanentError) { Ai::TriageService.call(tickets(:one)) }
  end

  # --- Timeout configuration ------------------------------------------------

  test "should configure a bounded request timeout to prevent hanging threads" do
    assert_equal 15, OpenAI.configuration.request_timeout
  end

  # --- Structured logging ---------------------------------------------------

  test "should log a structured success line with timing and no ticket content" do
    secret = VALID_CONTENT.merge("summary" => "secret account 12345")
    stub_openai(body: chat_body(secret))
    ticket = tickets(:one)

    logs = capture_logs { Ai::TriageService.call(ticket) }

    assert_match(/event=ai_triage\.request/, logs)
    assert_match(/outcome=success/, logs)
    assert_match(/ticket_id=#{ticket.id}/, logs)
    assert_match(/duration_ms=\d+/, logs)
    assert_no_match(/secret account/, logs)
  end

  test "should log a structured error line with the classified error class" do
    stub_openai(status: 429, body: { error: { message: "rate limited" } }.to_json)
    ticket = tickets(:one)

    logs = capture_logs do
      assert_raises(Ai::TriageService::TransientError) { Ai::TriageService.call(ticket) }
    end

    assert_match(/outcome=error/, logs)
    assert_match(/error_class=Ai::TriageService::TransientError/, logs)
    assert_match(/retryable=true/, logs)
  end
end
