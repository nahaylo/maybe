class AddCurrencyToIbkrAccounts < ActiveRecord::Migration[7.2]
  # An IBKR account holds cash in several currencies, and Maybe marks cash to
  # market only per account. So one IBKR account now links to one Maybe account
  # PER CURRENCY, and rows are routed by the currency they are booked in.
  def up
    add_column :ibkr_accounts, :currency, :string

    execute <<~SQL
      UPDATE ibkr_accounts
      SET currency = accounts.currency
      FROM accounts
      WHERE accounts.id = ibkr_accounts.account_id
    SQL

    change_column_null :ibkr_accounts, :currency, false

    remove_index :ibkr_accounts, %i[ibkr_item_id ibkr_id]
    add_index :ibkr_accounts, %i[ibkr_item_id ibkr_id currency], unique: true
  end

  def down
    remove_index :ibkr_accounts, %i[ibkr_item_id ibkr_id currency]
    add_index :ibkr_accounts, %i[ibkr_item_id ibkr_id], unique: true
    remove_column :ibkr_accounts, :currency
  end
end
