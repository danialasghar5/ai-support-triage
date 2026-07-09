module Ai
  class TriageService
    class Error < StandardError; end

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
      response = @client.chat(
        parameters: {
          model: @model,
          messages: messages,
          response_format: response_format,
          temperature: 0.1
        }
      )

      handle_response(response)
    rescue => e
      raise Error, "AI Triage failed: #{e.message}"
    end

    private

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
                enum: [ "low", "medium", "high", "urgent" ],
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
      if response["error"]
        raise Error, response.dig("error", "message")
      end

      choice = response.dig("choices", 0, "message", "content")
      raise Error, "Empty response from AI model" if choice.blank?

      JSON.parse(choice).symbolize_keys
    end
  end
end
