class AddLucideIconToAccounts < ActiveRecord::Migration[7.2]
  def change
    add_column :accounts, :lucide_icon, :string
  end
end
