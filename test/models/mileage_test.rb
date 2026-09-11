require "test_helper"

class MileageTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @account = @family.accounts.create!(
      name: "Test Car", balance: 0, currency: "USD",
      accountable: Vehicle.new(make: "Mazda", model: "6", mileage_unit: "km")
    )
    @vehicle = @account.vehicle
  end

  test "a reading does not move the account balance" do
    assert_no_difference -> { @account.reload.balance } do
      reading(date: 1.year.ago.to_date, value: 10_000)
    end
  end

  test "the vehicle's mileage tracks the latest reading" do
    reading(date: 2.years.ago.to_date, value: 10_000)
    reading(date: 1.year.ago.to_date, value: 30_000)

    assert_equal 30_000, @vehicle.reload.mileage_value
  end

  test "deleting the latest reading falls back to the previous one" do
    reading(date: 2.years.ago.to_date, value: 10_000)
    latest = reading(date: 1.year.ago.to_date, value: 30_000)

    latest.destroy!

    assert_equal 10_000, @vehicle.reload.mileage_value
  end

  test "an odometer cannot go backwards" do
    reading(date: 2.years.ago.to_date, value: 30_000)

    entry = build_reading(date: 1.year.ago.to_date, value: 10_000)

    assert_not entry.valid?
    assert_match(/must be above/, entry.errors.full_messages.to_sentence)
  end

  test "a reading inserted between two others must fit between them" do
    reading(date: 3.years.ago.to_date, value: 10_000)
    reading(date: 1.year.ago.to_date, value: 30_000)

    entry = build_reading(date: 2.years.ago.to_date, value: 50_000)

    assert_not entry.valid?
    assert_match(/must be below/, entry.errors.full_messages.to_sentence)
  end

  test "only one reading per day" do
    date = 1.year.ago.to_date
    reading(date: date, value: 10_000)

    entry = build_reading(date: date, value: 20_000)

    assert_not entry.valid?
  end

  test "readings are refused on non-vehicle accounts" do
    depository = @family.accounts.create!(
      name: "Not a car", balance: 0, currency: "USD", accountable: Depository.new
    )
    entry = depository.entries.build(
      date: Date.current, amount: 100, currency: "USD", name: "Odometer",
      entryable: Mileage.new(unit: "km")
    )

    assert_not entry.valid?
    assert_match(/vehicle account/, entry.errors.full_messages.to_sentence)
  end

  private
    def build_reading(date:, value:, unit: "km")
      @account.entries.build(
        date: date, amount: value, currency: @account.currency,
        name: "Odometer", entryable: Mileage.new(unit: unit)
      )
    end

    def reading(date:, value:, unit: "km")
      build_reading(date: date, value: value, unit: unit).tap(&:save!)
    end
end
