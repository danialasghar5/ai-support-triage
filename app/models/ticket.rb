class Ticket < ApplicationRecord
  enum :status, {
    pending: "pending",
    processing: "processing",
    completed: "completed",
    failed: "failed"
  }, default: "pending"

  validates :customer_email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :body, presence: true
  validates :status, presence: true

  # Treat a blank external_id as "no external_id" so the unique index (which
  # allows multiple NULLs) doesn't reject a second blank-id ticket.
  normalizes :external_id, with: ->(value) { value.presence }

  # Ensure metadata defaults to a hash if nil
  after_initialize :set_default_metadata, if: :new_record?

  private

  def set_default_metadata
    self.metadata ||= {}
  end
end
