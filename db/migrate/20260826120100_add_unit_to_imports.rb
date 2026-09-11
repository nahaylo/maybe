class AddUnitToImports < ActiveRecord::Migration[7.2]
  def change
    add_column :import_rows, :unit, :string
    add_column :imports, :unit_col_label, :string
  end
end
