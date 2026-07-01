OpenAI.configure do |config|
  config.access_token = ENV.fetch("OPENAI_API_KEY", "mock-key")
  config.request_timeout = 15 # Timeout after 15 seconds to prevent thread starvation
end
