namespace :tickets do
  desc "Reclaim tickets stranded in processing by a crashed worker (schedule this to run periodically, e.g. every minute)"
  task reclaim_stale: :environment do
    reclaimed = ReclaimStaleTicketsJob.perform_now
    puts "Reclaimed #{reclaimed} stale ticket(s)."
  end
end
