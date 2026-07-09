module Ai
  class TriageService
    # Base error. Subclasses tell the caller whether a retry is worthwhile:
    #   TransientError -> re-raise so Sidekiq retries (rate limit, 5xx, timeout)
    #   PermanentError -> record and stop; a retry cannot succeed (4xx, auth,
    #                     model refusal, malformed output)
    class Error < StandardError; end
    class TransientError < Error; end
    class PermanentError < Error; end

    # HTTP failures surface as typed Faraday exceptions (ruby-openai mounts the
    # :raise_error middleware). Note the ordering constraints these encode:
    # TooManyRequestsError is a ClientError, so it must be matched before the
    # 4xx bucket; TimeoutError is a ServerError, so it is covered here for free.
    RETRYABLE_ERRORS = [
      Faraday::TooManyRequestsError, # 429
      Faraday::ServerError,          # 5xx (includes Faraday::TimeoutError)
      Faraday::ConnectionFailed      # DNS / connection reset
    ].freeze

    DEFAULT_MODEL = "gpt-4o-mini".freeze

    def self.call(ticket)
      new(ticket).call
    end

    def initialize(ticket, model: DEFAULT_MODEL)
      @ticket = ticket
      @model = model
      @client = OpenAI::Client.new
    end

    def call
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      response = @client.chat(
        parameters: {
          model: @model,
          messages: messages,
          response_format: response_format,
          temperature: 0.1
        }
      )

      result = handle_response(response)
      log_event("ai_triage.request", outcome: "success", duration_ms: elapsed_ms(started_at))
      result
    rescue => e
      # One classification + one log point for every failure, so even a 15s
      # timeout records its duration and error type before re-raising.
      classified = classify(e)
      log_event(
        "ai_triage.request",
        outcome: "error",
        error_class: classified.class.name,
        retryable: classified.is_a?(TransientError),
        duration_ms: elapsed_ms(started_at)
      )
      raise classified
    end

    private

    # Map a raw exception onto a TransientError/PermanentError. Already-classified
    # errors (raised by handle_response) pass through untouched.
    def classify(error)
      case error
      when Error
        error
      when *RETRYABLE_ERRORS
        TransientError.new("AI Triage failed (transient): #{error.message}")
      when Faraday::ClientError, OpenAI::Error
        # Remaining 4xx (400/401/403/422) and OpenAI auth/config errors.
        PermanentError.new("AI Triage failed (permanent): #{error.message}")
      else
        # Unknown failure. Prefer a bounded retry over dropping the ticket.
        TransientError.new("AI Triage failed (unexpected): #{error.message}")
      end
    end

    def elapsed_ms(started_at)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
    end

    # Structured (logfmt) line. Never logs ticket content, only identifiers and
    # metrics, so PII stays out of the logs.
    def log_event(event, **fields)
      pairs = { event: event, ticket_id: @ticket.id, model: @model }.merge(fields)
      Rails.logger.info(pairs.map { |k, v| "#{k}=#{v}" }.join(" "))
    end

    def messages
      [
        {
          role: "system",
          content: "You are an expert customer support agent. Analyze the customer support ticket subject and body, and output a JSON object containing classification details: category, urgency, summary, and a polite, helpful suggested reply. Use the specified JSON schema."
        },
        {
          role: "user",
          content: "Subject: #{@ticket.subject}\n\nBody: #{@ticket.body}"
        }
      ]
    end

    def response_format
      {
        type: "json_schema",
        json_schema: {
          name: "ticket_triage",
          strict: true,
          schema: {
            type: "object",
            properties: {
              category: {
                type: "string",
                description: "The category of the ticket (e.g., technical, billing, sales, feedback, account, general)"
              },
              urgency: {
                type: "string",
                enum: Ticket::URGENCIES,
                description: "The urgency of the ticket based on customer sentiment and urgency of the issue"
              },
              summary: {
                type: "string",
                description: "A 1-2 sentence concise summary of the customer's problem or request"
              },
              suggested_reply: {
                type: "string",
                description: "A professional, draft response addressing the user's issue directly, prompting for next steps if needed"
              }
            },
            required: [ "category", "urgency", "summary", "suggested_reply" ],
            additionalProperties: false
          }
        }
      }
    end

    def handle_response(response)
      # A 200 response carrying an error body (rare; most API errors raise a
      # Faraday::Error first). Cause is ambiguous here, so treat as transient.
      raise TransientError, response.dig("error", "message") if response["error"]

      message = response.dig("choices", 0, "message")

      # A structured-output refusal or empty content won't change on retry.
      raise PermanentError, "AI model refused the request: #{message['refusal']}" if message && message["refusal"].present?

      content = message && message["content"]
      raise PermanentError, "Empty response from AI model" if content.blank?

      JSON.parse(content).symbolize_keys
    rescue JSON::ParserError => e
      raise PermanentError, "Malformed JSON from AI model: #{e.message}"
    end
  end
end
