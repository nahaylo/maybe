class AddAttributedAccountToTransactions < ActiveRecord::Migration[7.2]
  def change
    # Which asset (vehicle, property) a spend served. Metadata only: the
    # transaction stays in the account that paid, and balances are untouched.
    add_reference :transactions, :attributed_account, type: :uuid, null: true,
                  foreign_key: { to_table: :accounts, on_delete: :nullify }
  end
end
