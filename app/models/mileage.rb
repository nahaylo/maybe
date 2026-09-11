# An odometer reading on a vehicle account, on a date.
#
# The reading is stored in `entries.amount`. That column is already
# type-dependent -- a payment for Transaction, cash impact for Trade, the
# account's total value for Valuation -- so "kilometres for Mileage" is the same
# polymorphism, and it avoids parking a meaningless zero in the ledger.
#
# Readings never affect a balance: Balance::BaseCalculator#flows_for_date sums
# only `transaction?` and `trade?` entries, and valuations take a separate path.
class Mileage < ApplicationRecord
  include Entryable

  UNITS = { "km" => "Kilometers (km)", "mi" => "Miles (mi)" }.freeze
  KM_PER_MILE = 1.609344.to_d

  validates :unit, inclusion: { in: UNITS.keys }

  def value_in_km
    return nil if entry&.amount.nil?

    unit == "mi" ? entry.amount * KM_PER_MILE : entry.amount
  end

  # mileage_value/_unit on the vehicle are a cache of the latest reading, so
  # Vehicle#mileage, #fuel_economy and the overview cards need no changes.
  # The entry is gone by the time the destroy commits, so the vehicle has to be
  # captured while the association is still reachable.
  before_destroy :remember_vehicle
  after_commit :refresh_vehicle_mileage!

  def refresh_vehicle_mileage!
    vehicle = @remembered_vehicle || entry&.account&.vehicle
    return if vehicle.nil?

    latest = vehicle.mileage_readings.last
    vehicle.update_columns(
      mileage_value: latest&.amount&.to_i,
      mileage_unit: latest&.entryable&.unit || vehicle.mileage_unit
    )
  end

  def remember_vehicle
    @remembered_vehicle = entry&.account&.vehicle
  end

  def display_value
    "#{ActiveSupport::NumberHelper.number_to_delimited(entry.amount.to_i)} #{unit}"
  end
end
