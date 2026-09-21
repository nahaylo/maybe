class AddSecurityToTransactions < ActiveRecord::Migration[7.2]
  # Dividends, withholding tax, commissions and the like are cash rows thrown
  # off by a specific holding. Linking them to the security -- rather than
  # leaving the ticker buried in the entry name -- is what lets a holding show
  # what it paid and cost over its whole life.
  def change
    add_reference :transactions, :security, type: :uuid, null: true, foreign_key: true, index: true
  end
end
