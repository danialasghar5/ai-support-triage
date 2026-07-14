class AddClaimedAtToTickets < ActiveRecord::Migration[8.1]
  # When a worker claims a ticket (pending/failed -> processing) it stamps
  # claimed_at. This is the reaper's only input for telling "legitimately
  # running" apart from "abandoned by a crashed worker": a ticket stuck in
  # processing with an old claimed_at is stranded work to reclaim.
  def change
    add_column :tickets, :claimed_at, :datetime
  end
end
