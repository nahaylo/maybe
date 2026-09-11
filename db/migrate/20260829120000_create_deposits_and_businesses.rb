class CreateDepositsAndBusinesses < ActiveRecord::Migration[7.2]
  def change
    # Both mirror `depositories` exactly: an accountable carries no data of its
    # own, it only gives the account a type. Everything real (entries, balances,
    # holdings) hangs off `accounts`, which is why an account can be converted
    # between types without touching its history.
    create_table :deposits, id: :uuid do |t|
      t.jsonb :locked_attributes, default: {}

      t.timestamps
    end

    create_table :businesses, id: :uuid do |t|
      t.jsonb :locked_attributes, default: {}

      t.timestamps
    end
  end
end
