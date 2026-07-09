class AddUniqueIndexToTicketsExternalId < ActiveRecord::Migration[8.1]
  def change
    # Enforce idempotent ingestion: a client's external_id maps to exactly one
    # ticket. Postgres treats NULLs as distinct, so tickets without an
    # external_id are unaffected.
    remove_index :tickets, :external_id
    add_index :tickets, :external_id, unique: true
  end
end
