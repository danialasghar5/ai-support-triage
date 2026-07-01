class CreateTickets < ActiveRecord::Migration[8.1]
  def change
    enable_extension 'pgcrypto' unless extension_enabled?('pgcrypto')

    create_table :tickets, id: :uuid do |t|
      t.string :customer_email, null: false
      t.string :subject
      t.text :body, null: false
      t.string :status, null: false, default: 'pending'
      t.string :category
      t.string :urgency
      t.text :summary
      t.text :suggested_reply
      t.jsonb :metadata, null: false, default: {}
      t.text :error_message
      t.string :external_id

      t.timestamps
    end

    add_index :tickets, :external_id
    add_index :tickets, :status
  end
end

