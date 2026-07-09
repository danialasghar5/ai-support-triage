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

  test "should configure Sidekiq to retry three times" do
    # Sidekiq is the retry authority; this proves the wiring is in place.
    assert_equal 3, TicketTriageJob.get_sidekiq_options["retry"]
  end

  test "should re-claim and re-raise on each transient attempt, then complete on recovery" do
    ticket = tickets(:one)

    # Model Sidekiq's retry loop: a persistent transient failure re-raises every
    # attempt (handing the retry decision back to Sidekiq) and leaves the ticket
    # in a re-claimable failed state.
    failing = proc { raise Ai::TriageService::TransientError.new("rate limited") }
    stub_service_call(failing) do
      3.times do
        assert_raises(Ai::TriageService::TransientError) { TicketTriageJob.perform_now(ticket.id) }
        assert ticket.reload.failed?
      end
    end

    # A later attempt (after the transient condition clears) recovers the ticket.
    recovered = { category: "billing", urgency: "low", summary: "s", suggested_reply: "r" }
    stub_service_call(recovered) do
      TicketTriageJob.perform_now(ticket.id)
    end

    assert ticket.reload.completed?
    assert_nil ticket.error_message
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

  test "should mark ticket failed and re-raise on a transient error so Sidekiq retries" do
    ticket = tickets(:one)
    assert ticket.pending?

    error_proc = proc { raise Ai::TriageService::TransientError.new("Rate limited") }

    stub_service_call(error_proc) do
      # Re-raising is how the job hands the retry decision to Sidekiq.
      assert_raises(Ai::TriageService::TransientError) do
        TicketTriageJob.perform_now(ticket.id)
      end
    end

    ticket.reload
    assert ticket.failed?
    assert_equal "Rate limited", ticket.error_message
  end

  test "should mark ticket failed WITHOUT re-raising on a permanent error (no retry)" do
    ticket = tickets(:one)
    assert ticket.pending?

    error_proc = proc { raise Ai::TriageService::PermanentError.new("Invalid API key") }

    # Swallow-and-record: the job must not raise, so Sidekiq will not retry.
    stub_service_call(error_proc) do
      assert_nothing_raised do
        TicketTriageJob.perform_now(ticket.id)
      end
    end

    ticket.reload
    assert ticket.failed?
    assert_equal "Invalid API key", ticket.error_message
  end

  test "should not raise or retry when the ticket no longer exists" do
    missing_id = SecureRandom.uuid

    called = false
    track_proc = proc { called = true }

    stub_service_call(track_proc) do
      assert_nothing_raised do
        TicketTriageJob.perform_now(missing_id)
      end
    end

    assert_not called, "AI service should not be called for a missing ticket"
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

  test "should log a structured completed line on success" do
    ticket = tickets(:one)
    result = { category: "billing", urgency: "low", summary: "s", suggested_reply: "r" }

    logs = capture_logs do
      stub_service_call(result) do
        TicketTriageJob.perform_now(ticket.id)
      end
    end

    assert_match(/event=ticket_triage\.completed/, logs)
    assert_match(/ticket_id=#{ticket.id}/, logs)
  end

  test "should log a structured failed line with retryable flag on a permanent error" do
    ticket = tickets(:one)
    error_proc = proc { raise Ai::TriageService::PermanentError.new("bad key") }

    logs = capture_logs do
      stub_service_call(error_proc) do
        TicketTriageJob.perform_now(ticket.id)
      end
    end

    assert_match(/event=ticket_triage\.failed/, logs)
    assert_match(/error_class=Ai::TriageService::PermanentError/, logs)
    assert_match(/retryable=false/, logs)
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
