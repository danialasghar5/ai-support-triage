class Ticket < ApplicationRecord
  # Single source of truth for urgency: also feeds the AI service's JSON schema
  # so the LLM contract and this validation cannot drift apart.
  URGENCIES = %w[low medium high urgent].freeze

  enum :status, {
    pending: "pending",
    processing: "processing",
    completed: "completed",
    failed: "failed"
  }, default: "pending"

  validates :customer_email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :body, presence: true
  validates :status, presence: true

  # Reject AI output that drifts outside the expected vocabulary. Nil is allowed
  # because these fields are unset until triage completes. Category is left open
  # (the schema allows arbitrary categories) but bounded to a sane length.
  validates :urgency, inclusion: { in: URGENCIES }, allow_nil: true
  validates :category, length: { maximum: 50 }, allow_nil: true

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
