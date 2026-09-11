class CreateMonobankItemsAndAccounts < ActiveRecord::Migration[7.2]
  def change
    # One row per Monobank API token. A token belongs to one Monobank client and
    # can read only that client's accounts, so it is the connection -- the same
    # role plaid_items plays for Plaid.
    create_table :monobank_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name, null: false
      t.string :access_token, null: false

      t.timestamps
    end

    add_index :monobank_items, %i[family_id name], unique: true

    # Links a Monobank account to the Maybe account it is imported into. The
    # foreign key lives here rather than on `accounts` deliberately: only the
    # importer ever asks the question, so there is no reason for a vendor column
    # on a table the whole app reads.
    create_table :monobank_accounts, id: :uuid do |t|
      t.references :monobank_item, null: false, foreign_key: true, type: :uuid
      t.references :account, null: false, type: :uuid,
                   foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :monobank_id, null: false

      t.timestamps
    end

    add_index :monobank_accounts, %i[monobank_item_id monobank_id], unique: true
  end
end
