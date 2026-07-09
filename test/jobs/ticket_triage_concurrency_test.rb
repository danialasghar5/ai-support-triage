require "test_helper"

# Proves the core concurrency guarantee with two real worker threads contending
# for the same ticket: exactly one LLM call happens. Runs without transactional
# fixtures because a second thread needs its own connection that can see the
# committed ticket. It creates and destroys only its own row, so it does not
# touch fixture data used by the rest of the suite.
class TicketTriageConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  # The claim's check-then-set is normally too fast to collide by chance, which
  # would make this a tautology (it passes even with the row lock removed). This
  # seam widens the window so the race is deterministic: without a lock, both
  # workers read `pending` before either writes `processing` and both call the
  # LLM; with the lock, the second worker blocks on SELECT FOR UPDATE until the
  # first commits, then sees `processing` and skips. Prepended once and guarded
  # by a flag, so it is inert for every other test.
  module WidenClaimWindow
    class << self; attr_accessor :enabled; end

    def update!(*args)
      attrs = args.first
      sleep 0.1 if WidenClaimWindow.enabled && attrs.is_a?(Hash) && attrs[:status].to_s == "processing"
      super
    end
  end
  Ticket.prepend(WidenClaimWindow)

  setup do
    @ticket = Ticket.create!(customer_email: "race@example.com", body: "Concurrent triage", external_id: "concurrency-#{SecureRandom.hex(4)}")
  end

  teardown do
    WidenClaimWindow.enabled = false
    Ticket.where(id: @ticket.id).delete_all
  end

  # Replace Ai::TriageService.call with a thread-safe counter, so we can assert
  # exactly how many LLM calls were made across the contending workers.
  def counting_service_stub
    mutex = Mutex.new
    count = 0
    original = Ai::TriageService.method(:call)

    Ai::TriageService.define_singleton_method(:call) do |*|
      mutex.synchronize { count += 1 }
      { category: "billing", urgency: "low", summary: "s", suggested_reply: "r" }
    end

    yield -> { mutex.synchronize { count } }
  ensure
    Ai::TriageService.define_singleton_method(:call, original)
  end

  # Release all threads at once so they genuinely contend on the row lock.
  def run_concurrently(worker_count)
    gate = Queue.new
    threads = worker_count.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          gate.pop
          yield
        end
      end
    end
    worker_count.times { gate.push(:go) }
    threads.each(&:join)
  end

  test "two concurrent workers trigger exactly one LLM call for the same ticket" do
    WidenClaimWindow.enabled = true

    counting_service_stub do |count|
      run_concurrently(2) { TicketTriageJob.perform_now(@ticket.id) }

      assert_equal 1, count.call, "expected exactly one LLM call across concurrent workers"
      assert @ticket.reload.completed?
    end
  end
end
