# Reaper for tickets stranded in `processing`.
#
# The atomic claim moves a ticket pending/failed -> processing and stamps
# claimed_at. If the worker then crashes, the ticket is left in `processing`,
# which is NOT in the claimable set -- nothing in the normal claim path recovers
# it, and open-source Sidekiq has no reliable-fetch, so the crashed job is gone.
# This job is the recovery path: it resets tickets that have sat in `processing`
# longer than CLAIM_TIMEOUT back to `pending` and re-enqueues triage.
#
# This is a visibility timeout: it can also resurrect a job whose worker is
# merely hung (not dead). That is why correctness rests on the claim + the
# unique index -- the at-most-once claim means a resurrected ticket is still
# only triaged once -- and not on the timeout. CLAIM_TIMEOUT is set comfortably
# longer than the LLM timeout x retries so a healthy job is never reaped.
class ReclaimStaleTicketsJob < ApplicationJob
  queue_as :default

  # A ticket running longer than this is treated as abandoned. Default 5 minutes
  # -- well beyond the ~15s OpenAI timeout x 3 Sidekiq retries plus headroom.
  CLAIM_TIMEOUT = Integer(ENV.fetch("TRIAGE_CLAIM_TIMEOUT_SECONDS", 300)).seconds

  def perform
    cutoff = CLAIM_TIMEOUT.ago
    reclaimed = 0

    # A NULL claimed_at means the row entered processing without the claim
    # stamping it (legacy rows, or a direct status write) -- indistinguishable
    # from stranded, so reclaim it too.
    stale = Ticket.where(status: :processing)
                  .where("claimed_at < :cutoff OR claimed_at IS NULL", cutoff: cutoff)

    stale.find_each do |ticket|
      # Re-check the guard atomically at write time: if the worker finished
      # (processing -> completed) or the row was already reclaimed between the
      # scan and now, this affects zero rows and we neither reset nor re-enqueue.
      # The database adjudicates, exactly as the claim does.
      updated = Ticket.where(id: ticket.id, status: Ticket.statuses[:processing])
                      .where("claimed_at < :cutoff OR claimed_at IS NULL", cutoff: cutoff)
                      .update_all(status: Ticket.statuses[:pending], claimed_at: nil, updated_at: Time.current)

      next unless updated == 1

      TicketTriageJob.perform_later(ticket.id)
      reclaimed += 1
    end

    log_event("tickets.reclaim_stale", reclaimed: reclaimed, timeout_s: CLAIM_TIMEOUT.to_i)
    reclaimed
  end

  private

  # Structured (logfmt) line, matching the convention used elsewhere. Counts and
  # config only -- never ticket content.
  def log_event(event, **fields)
    pairs = { event: event }.merge(fields)
    Rails.logger.info(pairs.map { |k, v| "#{k}=#{v}" }.join(" "))
  end
end
