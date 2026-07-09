require "test_helper"

class Ai::TriageServiceTest < ActiveSupport::TestCase
  class MockOpenAiClient
    attr_reader :calls

    def initialize(response)
      @response = response
      @calls = []
    end

    def chat(parameters:)
      @calls << parameters
      # If configured with an exception, raise it to simulate the ruby-openai
      # client surfacing a typed Faraday/OpenAI error.
      raise @response if @response.is_a?(Exception)

      @response
    end
  end

  # Wrap a JSON-string content payload in the OpenAI chat response shape.
  def openai_response(content_hash)
    { "choices" => [ { "message" => { "content" => content_hash.to_json } } ] }
  end

  # A simple pure-Ruby stub helper for OpenAI::Client.new
  def stub_openai_client(mock_client)
    class << OpenAI::Client
      alias_method :original_new, :new
    end

    OpenAI::Client.define_singleton_method(:new) { |*args| mock_client }
    yield
  ensure
    class << OpenAI::Client
      alias_method :new, :original_new
      remove_method :original_new
    end
  end

  test "should return triage hash on successful OpenAI response" do
    ticket = tickets(:one)
    mock_response = {
      "choices" => [
        {
          "message" => {
            "content" => {
              "category" => "billing",
              "urgency" => "high",
              "summary" => "Charged twice for subscription.",
              "suggested_reply" => "Hello, we will resolve this billing issue."
            }.to_json
          }
        }
      ]
    }

    mock_client = MockOpenAiClient.new(mock_response)

    stub_openai_client(mock_client) do
      result = Ai::TriageService.call(ticket)

      assert_equal :billing, result[:category].to_sym
      assert_equal :high, result[:urgency].to_sym
      assert_equal "Charged twice for subscription.", result[:summary]
      assert_equal "Hello, we will resolve this billing issue.", result[:suggested_reply]
    end

    assert_equal 1, mock_client.calls.size
    call_args = mock_client.calls.first
    assert_equal "gpt-4o-mini", call_args[:model]
    assert_equal 0.1, call_args[:temperature]
    assert_equal "json_schema", call_args.dig(:response_format, :type)
  end

  test "should drive the urgency schema enum from Ticket::URGENCIES" do
    mock_client = MockOpenAiClient.new(openai_response(category: "billing", urgency: "low", summary: "s", suggested_reply: "r"))

    stub_openai_client(mock_client) do
      Ai::TriageService.call(tickets(:one))
    end

    enum = mock_client.calls.first.dig(:response_format, :json_schema, :schema, :properties, :urgency, :enum)
    assert_equal Ticket::URGENCIES, enum
  end

  test "should log a structured success line with timing and no ticket content" do
    ticket = tickets(:one)
    mock_client = MockOpenAiClient.new(openai_response(category: "billing", urgency: "low", summary: "secret summary", suggested_reply: "r"))

    logs = capture_logs do
      stub_openai_client(mock_client) do
        Ai::TriageService.call(ticket)
      end
    end

    assert_match(/event=ai_triage\.request/, logs)
    assert_match(/outcome=success/, logs)
    assert_match(/ticket_id=#{ticket.id}/, logs)
    assert_match(/duration_ms=\d+/, logs)
    assert_no_match(/secret summary/, logs) # never log ticket content
  end

  test "should log a structured error line with the classified error class" do
    ticket = tickets(:one)
    mock_client = MockOpenAiClient.new(Faraday::TooManyRequestsError.new("429"))

    logs = capture_logs do
      stub_openai_client(mock_client) do
        assert_raises(Ai::TriageService::TransientError) { Ai::TriageService.call(ticket) }
      end
    end

    assert_match(/outcome=error/, logs)
    assert_match(/error_class=Ai::TriageService::TransientError/, logs)
    assert_match(/retryable=true/, logs)
  end

  test "should raise custom error when OpenAI client encounters an error response" do
    ticket = tickets(:one)
    mock_error_response = {
      "error" => {
        "message" => "Rate limit exceeded"
      }
    }

    mock_client = MockOpenAiClient.new(mock_error_response)

    stub_openai_client(mock_client) do
      assert_raises(Ai::TriageService::Error) do
        Ai::TriageService.call(ticket)
      end
    end
  end

  # --- Error classification -------------------------------------------------

  RETRYABLE_CASES = {
    "rate limit (429)" => Faraday::TooManyRequestsError.new("429 Too Many Requests"),
    "server error (5xx)" => Faraday::ServerError.new("503 Service Unavailable"),
    "timeout" => Faraday::TimeoutError.new("execution expired"),
    "connection failure" => Faraday::ConnectionFailed.new("connection refused")
  }.freeze

  PERMANENT_CASES = {
    "bad request (400)" => Faraday::BadRequestError.new("400 Bad Request"),
    "unauthorized (401)" => Faraday::UnauthorizedError.new("401 Unauthorized"),
    "openai auth error" => OpenAI::AuthenticationError.new("invalid api key")
  }.freeze

  RETRYABLE_CASES.each do |label, error|
    test "should classify #{label} as a TransientError" do
      mock_client = MockOpenAiClient.new(error)
      stub_openai_client(mock_client) do
        assert_raises(Ai::TriageService::TransientError) do
          Ai::TriageService.call(tickets(:one))
        end
      end
    end
  end

  PERMANENT_CASES.each do |label, error|
    test "should classify #{label} as a PermanentError" do
      mock_client = MockOpenAiClient.new(error)
      stub_openai_client(mock_client) do
        assert_raises(Ai::TriageService::PermanentError) do
          Ai::TriageService.call(tickets(:one))
        end
      end
    end
  end

  test "should classify an unexpected error as a TransientError" do
    mock_client = MockOpenAiClient.new(RuntimeError.new("something odd"))
    stub_openai_client(mock_client) do
      assert_raises(Ai::TriageService::TransientError) do
        Ai::TriageService.call(tickets(:one))
      end
    end
  end

  test "should raise PermanentError when the model refuses the request" do
    refusal = { "choices" => [ { "message" => { "refusal" => "I can't help with that." } } ] }
    mock_client = MockOpenAiClient.new(refusal)
    stub_openai_client(mock_client) do
      assert_raises(Ai::TriageService::PermanentError) do
        Ai::TriageService.call(tickets(:one))
      end
    end
  end

  test "should raise PermanentError when the model returns empty content" do
    empty = { "choices" => [ { "message" => { "content" => "" } } ] }
    mock_client = MockOpenAiClient.new(empty)
    stub_openai_client(mock_client) do
      assert_raises(Ai::TriageService::PermanentError) do
        Ai::TriageService.call(tickets(:one))
      end
    end
  end

  test "should raise PermanentError when the model returns malformed JSON" do
    malformed = { "choices" => [ { "message" => { "content" => "{not json" } } ] }
    mock_client = MockOpenAiClient.new(malformed)
    stub_openai_client(mock_client) do
      assert_raises(Ai::TriageService::PermanentError) do
        Ai::TriageService.call(tickets(:one))
      end
    end
  end
end
