require "test_helper"

class TicketTriageJobTest < ActiveJob::TestCase
  # A simple pure-Ruby stub helper for Ai::TriageService.call
  def stub_service_call(result_or_proc)
    class << Ai::TriageService
      alias_method :original_call, :call
    end

    Ai::TriageService.define_singleton_method(:call) do |*args|
      if result_or_proc.respond_to?(:call)
        result_or_proc.call(*args)
      else
        result_or_proc
      end
    end
    yield
  ensure
    class << Ai::TriageService
      alias_method :call, :original_call
      remove_method :original_call
    end
  end

  test "should successfully triage and update ticket attributes" do
    ticket = tickets(:one)
    assert ticket.pending?

    mock_triage_result = {
      category: "technical",
      urgency: "urgent",
      summary: "Database connection timeouts.",
      suggested_reply: "We are investigating the database issue."
    }

    # Stub the AI service to return mock results
    stub_service_call(mock_triage_result) do
      TicketTriageJob.perform_now(ticket.id)
    end

    ticket.reload
    assert ticket.completed?
    assert_equal "technical", ticket.category
    assert_equal "urgent", ticket.urgency
    assert_equal "Database connection timeouts.", ticket.summary
    assert_equal "We are investigating the database issue.", ticket.suggested_reply
    assert_nil ticket.error_message
  end

  test "should save error message and mark ticket as failed if AI service raises an error" do
    ticket = tickets(:one)
    assert ticket.pending?

    # Stub the AI service to raise an error
    error_proc = proc { raise Ai::TriageService::Error.new("API Timeout") }

    stub_service_call(error_proc) do
      assert_raises(Ai::TriageService::Error) do
        TicketTriageJob.perform_now(ticket.id)
      end
    end

    ticket.reload
    assert ticket.failed?
    assert_equal "API Timeout", ticket.error_message
  end

  test "should return early without calling AI service if ticket is already completed" do
    ticket = tickets(:two) # 'two' is completed in fixtures
    assert ticket.completed?

    called = false
    track_proc = proc { called = true }

    stub_service_call(track_proc) do
      TicketTriageJob.perform_now(ticket.id)
    end

    assert_not called, "AI service should not have been called for completed tickets"
  end

  test "should not call AI service when the ticket is already being processed by another worker" do
    ticket = tickets(:one)
    ticket.processing! # Simulate a concurrent worker having claimed the ticket.

    called = false
    track_proc = proc { called = true }

    stub_service_call(track_proc) do
      TicketTriageJob.perform_now(ticket.id)
    end

    assert_not called, "A second worker must not trigger a duplicate LLM call"
    assert ticket.reload.processing?
  end

  test "should reprocess a previously failed ticket on retry" do
    ticket = tickets(:one)
    ticket.failed!

    mock_triage_result = {
      category: "billing",
      urgency: "low",
      summary: "Recovered on retry.",
      suggested_reply: "Resolved."
    }

    stub_service_call(mock_triage_result) do
      TicketTriageJob.perform_now(ticket.id)
    end

    assert ticket.reload.completed?
    assert_nil ticket.error_message
  end
end
