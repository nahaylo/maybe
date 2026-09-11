class Vehicle < ApplicationRecord
  include Accountable

  attribute :mileage_unit, :string, default: "mi"

  KM_PER_MILE = 1.609344.to_d

  # The spending category that counts as this vehicle's fuel. Optional, and
  # matched exactly -- subcategories are deliberately not included, so pointing
  # at a parent like "car" does not silently mean "every car cost".
  belongs_to :fuel_category, class_name: "Category", optional: true

  def mileage
    Measurement.new(mileage_value, mileage_unit) if mileage_value.present?
  end

  # Odometer readings, oldest first. The source of truth for mileage --
  # mileage_value/_unit are a cache of the most recent one, refreshed by
  # Mileage#refresh_vehicle_mileage! so everything reading `mileage` keeps
  # working unchanged.
  def mileage_readings
    return Entry.none if account.nil?

    account.entries.where(entryable_type: "Mileage").includes(:entryable).order(:date)
  end

  # Litres per 100 km between each consecutive pair of readings. The first
  # reading has no predecessor, so a series needs at least two.
  #
  # @return [Array<Hash>] {from:, to:, km:, litres:, economy:}
  def fuel_economy_series
    readings = mileage_readings.to_a
    return [] if readings.size < 2 || !tracks_fuel?

    readings.each_cons(2).filter_map do |previous, current|
      km = current.entryable.value_in_km - previous.entryable.value_in_km
      next if km <= 0

      litres = fuel_transactions
                 .where(unit: "l")
                 .where("entries.date > ? AND entries.date <= ?", previous.date, current.date)
                 .sum(:quantity)
      next if litres.zero?

      { from: previous.date, to: current.date, km: km, litres: litres,
        economy: (litres / km * 100).round(2) }
    end
  end

  def tracks_fuel? = fuel_category.present?

  def fuel_transactions
    return Transaction.none unless tracks_fuel?

    Transaction.where(category_id: fuel_category_id).joins(:entry)
  end

  def fuel_spend
    sum_in_account_currency(fuel_transactions)
  end

  # Spending that counts toward owning this vehicle: everything attributed to
  # it via Transaction#attributed_account, plus its fuel (identified by category
  # instead, so the two sets may overlap without double counting). Transfers
  # are not spending, and excluded entries stay excluded.
  def cost_transactions
    return Transaction.none if account.nil?

    scope = Transaction.where(attributed_account_id: account.id)
    scope = scope.or(Transaction.where(category_id: fuel_category_id)) if tracks_fuel?

    scope.joins(:entry).where(kind: %w[standard one_time], entries: { excluded: false })
  end

  # The same rows as entries, for lists: the row partials render entries, not
  # transactions, and the paying account's currency comes from the entry.
  def cost_entries
    Entry.where(entryable_type: "Transaction", entryable_id: cost_transactions.select("transactions.id"))
  end

  def tracks_costs?
    tracks_fuel? || (account.present? && account.attributed_transactions.exists?)
  end

  def running_costs
    sum_in_account_currency(cost_transactions)
  end

  # Money that came back out of the car: transfer legs leaving the account,
  # i.e. what it sold for. Zero while the car is still owned.
  def sale_proceeds
    return Money.new(0, account.currency) if account.nil?

    total = account.transactions.joins(:entry).where(kind: "funds_movement").where("entries.amount > 0").sum("entries.amount")
    Money.new(total, account.currency)
  end

  def sold?
    sale_proceeds.positive?
  end

  # What the car actually cost to have: bought for, spent on, minus what it
  # returned when sold.
  def total_cost_of_ownership
    purchase_price + running_costs - sale_proceeds
  end

  # Nil rather than zero when there is no mileage: "unknown", not "free".
  def running_cost_per_km
    per_km(running_costs)
  end

  def cost_per_km
    per_km(total_cost_of_ownership)
  end

  def fuel_litres
    fuel_transactions.where(unit: "l").sum(:quantity)
  end

  # Litres per 100 km. Nil unless there is both a mileage reading and fuel
  # recorded -- a zero would read as "extremely efficient" rather than "unknown".
  def fuel_economy
    km = mileage_in_km
    return nil if km.nil? || km.zero? || fuel_litres.zero?

    (fuel_litres / km * 100).round(2)
  end

  def purchase_price
    first_valuation_amount
  end

  def trend
    Trend.new(current: account.balance_money, previous: first_valuation_amount)
  end

  class << self
    def color
      "#F23E94"
    end

    def icon
      "car-front"
    end

    def classification
      "asset"
    end
  end

  private
    # Rows are not all one currency (fuel abroad, insurance in EUR), so each is
    # converted at the rate on its own date rather than summed raw. A row with
    # no rate is skipped rather than counted unconverted -- understating is
    # less wrong than treating 50 EUR as 50 UAH.
    def sum_in_account_currency(transactions)
      target = account.currency

      total = transactions.includes(:entry).sum do |transaction|
        entry = transaction.entry
        next entry.amount if entry.currency == target

        begin
          entry.amount_money.exchange_to(target, date: entry.date).amount
        rescue Money::ConversionError
          0
        end
      end

      Money.new(total, target)
    end

    def per_km(money)
      km = mileage_in_km
      return nil if km.nil? || km.zero?

      Money.new((money.amount / km).round(2), account.currency)
    end

    def mileage_in_km
      return nil if mileage_value.blank? || mileage_value.zero?

      mileage_unit == "mi" ? mileage_value * KM_PER_MILE : mileage_value.to_d
    end

    # A car bought through transfers starts from a zero opening anchor, and
    # the purchase price is the first value it reaches after that.
    def first_valuation_amount
      valuation = account.entries.valuations.includes(:entryable).order(:date).find do |entry|
        !(entry.entryable.opening_anchor? && entry.amount.zero?)
      end

      valuation&.amount_money || account.balance_money
    end
end
