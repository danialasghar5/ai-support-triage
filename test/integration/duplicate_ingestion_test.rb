require "test_helper"

# Proves ingestion idempotency is enforced by the DATABASE, not merely by the
# controller's pre-check. Two real threads insert the same external_id at once;
# the unique index adjudicates and lets exactly one win. Runs without
# transactional fixtures so each thread's own connection can see the other's
# committed row. Creates and destroys only its own external_id.
class DuplicateIngestionTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  teardown do
    Ticket.where(external_id: @external_id).delete_all if @external_id
  end

  test "concurrent inserts with the same external_id yield exactly one row; the database rejects the loser" do
    @external_id = "race-#{SecureRandom.hex(4)}"
    outcomes = Queue.new
    gate = Queue.new

    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          gate.pop # release both at once so they genuinely contend
          begin
            Ticket.create!(customer_email: "race@example.com", body: "dup", external_id: @external_id)
            outcomes << :created
          rescue ActiveRecord::RecordNotUnique
            outcomes << :rejected
          end
        end
      end
    end
    2.times { gate.push(:go) }
    threads.each(&:join)

    # Deterministic regardless of timing: with the unique index, exactly one
    # insert commits and the other raises. Without it, both would succeed
    # ([:created, :created]) and this fails -- which is the point.
    assert_equal [ :created, :rejected ], [ outcomes.pop, outcomes.pop ].sort,
      "the database must let exactly one insert win"
    assert_equal 1, Ticket.where(external_id: @external_id).count
  end
end
