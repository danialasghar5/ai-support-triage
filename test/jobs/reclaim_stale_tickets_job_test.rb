require "test_helper"

class ReclaimStaleTicketsJobTest < ActiveJob::TestCase
  def processing_ticket(claimed_at:)
    Ticket.create!(
      customer_email: "stale@example.com",
      body: "Stranded in processing",
      status: :processing,
      claimed_at: claimed_at
    )
  end

  test "reclaims a ticket stranded in processing past the timeout and re-enqueues triage" do
    ticket = processing_ticket(claimed_at: (ReclaimStaleTicketsJob::CLAIM_TIMEOUT + 1.minute).ago)

    assert_enqueued_with(job: TicketTriageJob, args: [ ticket.id ]) do
      assert_equal 1, ReclaimStaleTicketsJob.perform_now
    end

    ticket.reload
    assert ticket.pending?, "stranded ticket must return to pending"
    assert_nil ticket.claimed_at, "claimed_at must be cleared so the next claim re-stamps it"
  end

  test "leaves a ticket that is still legitimately processing alone" do
    ticket = processing_ticket(claimed_at: 5.seconds.ago)

    assert_no_enqueued_jobs only: TicketTriageJob do
      assert_equal 0, ReclaimStaleTicketsJob.perform_now
    end

    assert ticket.reload.processing?, "a healthy in-flight ticket must not be reaped"
  end

  test "treats a processing ticket with no claimed_at as stranded" do
    # A NULL claimed_at (legacy row, or a direct status write) is
    # indistinguishable from abandoned, so it is reclaimed.
    ticket = processing_ticket(claimed_at: nil)

    assert_equal 1, ReclaimStaleTicketsJob.perform_now
    assert ticket.reload.pending?
  end

  test "does not touch tickets that are not processing" do
    # pending / failed are claimable by the normal path; completed is terminal.
    # None are the reaper's concern.
    pending = Ticket.create!(customer_email: "p@example.com", body: "b", status: :pending)
    failed  = Ticket.create!(customer_email: "f@example.com", body: "b", status: :failed)
    done    = Ticket.create!(customer_email: "c@example.com", body: "b", status: :completed)

    assert_no_enqueued_jobs only: TicketTriageJob do
      assert_equal 0, ReclaimStaleTicketsJob.perform_now
    end

    assert pending.reload.pending?
    assert failed.reload.failed?
    assert done.reload.completed?
  end
end
