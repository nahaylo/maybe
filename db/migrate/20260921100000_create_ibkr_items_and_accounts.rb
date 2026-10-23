class CreateIbkrItemsAndAccounts < ActiveRecord::Migration[7.2]
  def change
    # One row per Interactive Brokers Flex Web Service token. A token belongs
    # to one IBKR login and the Flex Query it runs decides which of that
    # login's accounts are in the report, so token + query is the connection --
    # the same role plaid_items and monobank_items play.
    create_table :ibkr_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name, null: false
      t.string :access_token, null: false
      t.string :query_id, null: false

      t.timestamps
    end

    add_index :ibkr_items, %i[family_id name], unique: true

    # Links an IBKR account (U1234567) to the Maybe account it is imported
    # into. A join row rather than a column on `accounts`, for the same reason
    # monobank_accounts is: only the importer asks the question.
    create_table :ibkr_accounts, id: :uuid do |t|
      t.references :ibkr_item, null: false, foreign_key: true, type: :uuid
      t.references :account, null: false, type: :uuid,
                   foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :ibkr_id, null: false

      t.timestamps
    end

    add_index :ibkr_accounts, %i[ibkr_item_id ibkr_id], unique: true
  end
end
