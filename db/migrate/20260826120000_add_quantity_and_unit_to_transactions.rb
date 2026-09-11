class AddQuantityAndUnitToTransactions < ActiveRecord::Migration[7.2]
  def change
    add_column :transactions, :quantity, :decimal, precision: 19, scale: 4
    add_column :transactions, :unit, :string
  end
end
