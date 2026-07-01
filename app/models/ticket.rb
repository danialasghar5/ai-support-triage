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

  # Ensure metadata defaults to a hash if nil
  after_initialize :set_default_metadata, if: :new_record?

  private

  def set_default_metadata
    self.metadata ||= {}
  end
end

