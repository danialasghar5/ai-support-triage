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
      @response
    end
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

  test "should raise custom error when OpenAI client encounters an error response" do
    ticket = tickets(:one)
    mock_error_response = {
      "error" => {
        "message" => "Rate limit exceeded"
      }
    }

    mock_client = MockOpenAiClient.new(mock_error_response)

    stub_openai_client(mock_client) do
      assert_raises(Ai::TriageService::Error, "AI Triage failed: Rate limit exceeded") do
        Ai::TriageService.call(ticket)
      end
    end
  end
end
