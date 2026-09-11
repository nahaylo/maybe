class CreateMileages < ActiveRecord::Migration[7.2]
  def change
    # An odometer reading. The reading itself lives in entries.amount -- like a
    # Valuation, whose amount is the account's value rather than a payment.
    create_table :mileages, id: :uuid do |t|
      t.string :unit, null: false, default: "km"
      t.jsonb :locked_attributes, default: {}

      t.timestamps
    end
  end
end
