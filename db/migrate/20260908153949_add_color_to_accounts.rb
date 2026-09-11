class AddColorToAccounts < ActiveRecord::Migration[7.2]
  def change
    add_column :accounts, :custom_color, :string
  end
end
