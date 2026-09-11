class AddFuelCategoryToVehicles < ActiveRecord::Migration[7.2]
  def change
    # Which spending category counts as this vehicle's fuel. Nullify rather than
    # cascade: deleting a category must not delete the vehicle.
    add_reference :vehicles, :fuel_category, type: :uuid, null: true,
                  foreign_key: { to_table: :categories, on_delete: :nullify }
  end
end
