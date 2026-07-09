ENV["RAILS_ENV"] ||= "test"
# The app fails closed when API_AUTH_TOKEN is unset; the suite needs a configured
# secret to exercise authenticated paths.
ENV["API_AUTH_TOKEN"] ||= "test-triage-token"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Capture everything written to Rails.logger during the block and return it
    # as a string, so tests can assert on structured log output.
    def capture_logs
      io = StringIO.new
      original = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(io)
      yield
      io.string
    ensure
      Rails.logger = original
    end
  end
end
