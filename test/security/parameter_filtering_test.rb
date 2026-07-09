require "test_helper"

# Support tickets carry customer PII in their free-text fields. These fields must
# be redacted from request logs.
class ParameterFilteringTest < ActiveSupport::TestCase
  def filter
    ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
  end

  test "should redact PII-bearing ticket fields from logged parameters" do
    filtered = filter.filter(
      "customer_email" => "jane@example.com",
      "subject" => "sensitive subject",
      "body" => "my account number is 12345",
      "metadata" => { "stripe_customer_id" => "cus_123" }
    )

    assert_equal "[FILTERED]", filtered["customer_email"]
    assert_equal "[FILTERED]", filtered["subject"]
    assert_equal "[FILTERED]", filtered["body"]
    assert_equal "[FILTERED]", filtered["metadata"]
  end
end
