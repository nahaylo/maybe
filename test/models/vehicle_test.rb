require "test_helper"

class VehicleTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @account = @family.accounts.create!(
      name: "Test Car", balance: 0, currency: "USD",
      accountable: Vehicle.new(make: "Mazda", model: "6", mileage_value: 10_000, mileage_unit: "km")
    )
    @vehicle = @account.vehicle
    @fuel = @family.categories.create!(name: "Fuel")
    @cash = @family.accounts.create!(
      name: "Test Cash", balance: 0, currency: "USD", accountable: Depository.new
    )
  end

  test "reports nothing until a fuel category is named" do
    fill_up(amount: 50, quantity: 40)

    assert_not_predicate @vehicle, :tracks_fuel?
    assert_equal 0, @vehicle.fuel_spend.amount
    assert_equal 0, @vehicle.fuel_litres
    assert_nil @vehicle.fuel_economy
  end

  test "sums spend and volume for the named category" do
    @vehicle.update!(fuel_category: @fuel)
    fill_up(amount: 50, quantity: 40)
    fill_up(amount: 30, quantity: 25)
    create_transaction(account: @cash, amount: 999, category: @family.categories.create!(name: "Other"))

    assert_equal 80, @vehicle.fuel_spend.amount
    assert_equal 65, @vehicle.fuel_litres
  end

  # Guards the case that made the hand-computed figures wrong: summing raw
  # amounts across currencies treats 50 EUR as 50 USD.
  test "converts foreign fill-ups at the rate on their own date" do
    @vehicle.update!(fuel_category: @fuel)
    date = Date.current
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", rate: 2, date: date)

    eur_account = @family.accounts.create!(
      name: "EUR Cash", balance: 0, currency: "EUR", accountable: Depository.new
    )
    create_transaction(account: eur_account, currency: "EUR", amount: 50, date: date,
                       category: @fuel, quantity: 30, unit: "l")

    assert_equal 100, @vehicle.fuel_spend.amount
    assert_equal "USD", @vehicle.fuel_spend.currency.iso_code
  end

  test "only litres count toward volume" do
    @vehicle.update!(fuel_category: @fuel)
    fill_up(amount: 50, quantity: 40)
    create_transaction(account: @cash, amount: 20, category: @fuel, quantity: 5, unit: "gal")

    assert_equal 40, @vehicle.fuel_litres
    assert_equal 70, @vehicle.fuel_spend.amount
  end

  test "economy is litres per 100 km" do
    @vehicle.update!(fuel_category: @fuel)
    fill_up(amount: 100, quantity: 800) # 800 l over 10,000 km

    assert_equal 8.0, @vehicle.fuel_economy
  end

  test "economy converts a mileage recorded in miles" do
    @vehicle.update!(fuel_category: @fuel, mileage_value: 10_000, mileage_unit: "mi")
    fill_up(amount: 100, quantity: 800)

    # 10,000 mi is 16,093.44 km, so the same fuel goes further per 100 km.
    assert_equal 4.97, @vehicle.fuel_economy
  end

  test "economy is unknown rather than zero when mileage is missing" do
    @vehicle.update!(fuel_category: @fuel, mileage_value: nil)
    fill_up(amount: 50, quantity: 40)

    assert_nil @vehicle.fuel_economy
  end

  test "economy series pairs consecutive readings with the fuel burned between them" do
    @vehicle.update!(fuel_category: @fuel)
    odometer(date: Date.new(2026, 1, 1), value: 10_000)
    fill_up(amount: 100, quantity: 400, date: Date.new(2026, 2, 1))
    odometer(date: Date.new(2026, 3, 1), value: 15_000)

    series = @vehicle.fuel_economy_series

    assert_equal 1, series.size
    assert_equal 5_000, series.first[:km]
    assert_equal 400, series.first[:litres]
    assert_equal 8.0, series.first[:economy]
  end

  test "fuel on the first reading's own day belongs to the earlier interval, not this one" do
    @vehicle.update!(fuel_category: @fuel)
    odometer(date: Date.new(2026, 1, 1), value: 10_000)
    fill_up(amount: 100, quantity: 999, date: Date.new(2026, 1, 1))
    fill_up(amount: 100, quantity: 400, date: Date.new(2026, 2, 1))
    odometer(date: Date.new(2026, 3, 1), value: 15_000)

    assert_equal 400, @vehicle.fuel_economy_series.first[:litres]
  end

  test "tracks no costs until something is attributed or fuel is named" do
    assert_not_predicate @vehicle, :tracks_costs?

    create_transaction(account: @cash, amount: 100, attributed_account: @account)

    assert_predicate @vehicle, :tracks_costs?
  end

  test "running costs add attributed spending to fuel without double counting" do
    @vehicle.update!(fuel_category: @fuel)
    fill_up(amount: 50, quantity: 40)
    create_transaction(account: @cash, amount: 50, category: @fuel, quantity: 40, unit: "l",
                       attributed_account: @account) # fuel that is also attributed
    create_transaction(account: @cash, amount: 100, attributed_account: @account)
    create_transaction(account: @cash, amount: 999, attributed_account: @account, kind: "funds_movement")
    create_transaction(account: @cash, amount: 999, attributed_account: @account, excluded: true)
    create_transaction(account: @cash, amount: 999) # unrelated

    assert_equal 200, @vehicle.running_costs.amount
  end

  test "cost per km divides by distance, all-in and running" do
    @account.entries.create!(date: 1.year.ago.to_date, amount: 1_000, currency: "USD",
                             name: "Bought", entryable: Valuation.new)
    create_transaction(account: @cash, amount: 500, attributed_account: @account)

    assert_equal 1_500, @vehicle.total_cost_of_ownership.amount
    assert_equal 0.15, @vehicle.cost_per_km.amount
    assert_equal 0.05, @vehicle.running_cost_per_km.amount
  end

  test "purchase price skips a zero opening anchor and nets the sale out of total cost" do
    @account.entries.create!(date: Date.new(2020, 1, 1), amount: 0, currency: "USD",
                             name: "Opening", entryable: Valuation.new(kind: "opening_anchor"))
    @account.entries.create!(date: Date.new(2020, 1, 2), amount: 10_000, currency: "USD",
                             name: "Bought", entryable: Valuation.new)
    create_transaction(account: @cash, amount: 1_000, attributed_account: @account)
    # Sale proceeds: a transfer leg leaving the car.
    @account.entries.create!(date: Date.new(2021, 1, 1), amount: 6_000, currency: "USD",
                             name: "Sold", entryable: Transaction.new(kind: "funds_movement"))

    assert_equal 10_000, @vehicle.purchase_price.amount
    assert_equal 6_000, @vehicle.sale_proceeds.amount
    assert_predicate @vehicle, :sold?
    assert_equal 5_000, @vehicle.total_cost_of_ownership.amount
  end

  test "cost per km is unknown without mileage" do
    @vehicle.update!(mileage_value: nil)
    create_transaction(account: @cash, amount: 500, attributed_account: @account)

    assert_nil @vehicle.cost_per_km
  end

  test "a single reading yields no series" do
    @vehicle.update!(fuel_category: @fuel)
    odometer(date: Date.new(2026, 1, 1), value: 10_000)
    fill_up(amount: 100, quantity: 400)

    assert_empty @vehicle.fuel_economy_series
  end

  private
    def odometer(date:, value:)
      @account.entries.create!(
        date: date, amount: value, currency: @account.currency,
        name: "Odometer", entryable: Mileage.new(unit: "km")
      )
    end

    def fill_up(amount:, quantity:, date: Date.current)
      create_transaction(account: @cash, amount: amount, category: @fuel,
                         quantity: quantity, unit: "l", date: date)
    end
end
