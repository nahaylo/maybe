# What one security has earned in one account, worked out the way a broker
# does it: FIFO lots.
#
# Replays the account's trades in the security oldest first. A buy opens a
# lot; a sell consumes the oldest open lots and books the difference between
# proceeds and their cost as realised gain. Whatever lots remain are the
# position and its cost basis. Cash rows linked to the security (dividends,
# withholding tax, commissions, bonus-share offsets) are summed alongside, so
# total return is everything the holding has produced over its whole life --
# including periods when the position was closed and reopened.
#
# Everything is expressed in the account's currency. A trade or cash row in
# another currency is converted at its own date, like the balance engine does.
class Holding::Performance
  Lot = Struct.new(:entry, :qty, :price) # qty still open, price per share

  Closing = Data.define(:sell_entry, :qty, :proceeds, :cost, :lots) do
    def gain = proceeds - cost
    def percent = cost.zero? ? nil : (gain / cost * 100).round(1)
    def cost_per_share = qty.zero? ? 0.to_d : cost / qty
  end

  attr_reader :account, :security

  def initialize(account, security)
    @account = account
    @security = security
    replay
  end

  # Trade entries, oldest first.
  def trades
    @trades ||= account.entries
                       .where(entryable: account.trades.where(security: security))
                       .includes(:entryable)
                       .chronological
                       .to_a
  end

  # Cash entries linked to this security, oldest first.
  def cash_entries
    @cash_entries ||= account.entries
                             .where(entryable: account.transactions.where(security: security))
                             .includes(:entryable)
                             .chronological
                             .to_a
  end

  # Trades and cash rows interleaved, newest first, for a history timeline.
  def timeline
    (trades + cash_entries).sort_by { |e| [ e.date, e.created_at ] }.reverse
  end

  def open_qty = @lots.sum(&:qty)
  def open? = open_qty.positive?

  def cost_basis = money(@lots.sum { |lot| lot.qty * lot.price })
  def cost_basis_per_share = money(open_qty.zero? ? 0 : cost_basis.amount / open_qty)

  def current_price
    @current_price ||= begin
      price = security.current_price
      price && convert(price, Date.current)
    end
  end

  def market_value
    return nil if current_price.nil?

    money(open_qty * current_price.amount)
  end

  # Gain on the shares still held, against what they cost.
  def unrealized
    return nil if market_value.nil? || open_qty.zero?

    Trend.new(current: market_value, previous: cost_basis)
  end

  def closings = @closings
  def realized_gain = money(@closings.sum(&:gain))

  # Signed sums, so a reversed dividend or a refunded tax nets out in its own
  # line instead of showing up as income of another kind.
  def dividends = money(sum_cash { |e| dividend?(e) ? -e.amount : 0 })
  def withholding_tax = money(sum_cash { |e| tax?(e) ? e.amount : 0 })
  def fees = money(sum_cash { |e| !dividend?(e) && !tax?(e) && e.amount.positive? ? e.amount : 0 })
  def other_income = money(sum_cash { |e| !dividend?(e) && !tax?(e) && e.amount.negative? ? -e.amount : 0 })

  # Everything the holding has produced: price gains realised and unrealised,
  # cash it paid out, minus what it cost to hold.
  def total_return
    unrealized_amount = unrealized ? unrealized.value : money(0)
    unrealized_amount + realized_gain + dividends + other_income - withholding_tax - fees
  end

  def total_return_trend
    Trend.new(current: total_return, previous: money(0))
  end

  # What happened to one trade: for a buy, how much of the lot is still held
  # and what it is worth now; for a sell, what it realised.
  def outcome_for(entry)
    @outcomes[entry.id]
  end

  private
    Outcome = Data.define(:kind, :closing, :remaining_qty, :closed_on, :gain, :percent) do
      def buy? = kind == :buy
      def sell? = kind == :sell
      def still_held? = buy? && remaining_qty.positive?
    end

    def replay
      @lots = []
      @closings = []
      @outcomes = {}
      lot_closed_on = {}

      trades.each do |entry|
        trade = entry.entryable
        qty = trade.qty
        price = convert(Money.new(trade.price, trade.currency), entry.date).amount

        if qty.positive?
          @lots << Lot.new(entry, qty, price)
        elsif qty.negative?
          @closings << close(entry, qty.abs, price, lot_closed_on)
        end
      end

      trades.each do |entry|
        trade = entry.entryable

        if trade.qty.positive?
          lot = @lots.find { |l| l.entry.id == entry.id }
          remaining = lot ? lot.qty : 0.to_d
          gain = remaining.positive? && current_price ? (current_price.amount - lot.price) * remaining : nil
          @outcomes[entry.id] = Outcome.new(
            kind: :buy, closing: nil, remaining_qty: remaining, closed_on: lot_closed_on[entry.id],
            gain: gain && money(gain),
            percent: gain && lot.price.positive? ? ((current_price.amount - lot.price) / lot.price * 100).round(1) : nil
          )
        else
          closing = @closings.find { |c| c.sell_entry.id == entry.id }
          @outcomes[entry.id] = Outcome.new(
            kind: :sell, closing: closing, remaining_qty: 0.to_d, closed_on: nil,
            gain: money(closing.gain), percent: closing.percent
          )
        end
      end

      @lots.reject! { |lot| lot.qty.zero? }
    end

    # FIFO: the oldest open lots go first. A sell of more than is on the
    # books (history that starts after the buy) costs nothing for the excess,
    # which overstates the gain rather than inventing a cost.
    def close(sell_entry, qty, price, lot_closed_on)
      remaining = qty
      cost = 0.to_d
      consumed = []

      @lots.each do |lot|
        break if remaining.zero?
        next if lot.qty.zero?

        take = [ lot.qty, remaining ].min
        cost += take * lot.price
        lot.qty -= take
        remaining -= take
        consumed << lot
        lot_closed_on[lot.entry.id] = sell_entry.date if lot.qty.zero?
      end

      Closing.new(sell_entry: sell_entry, qty: qty, proceeds: qty * price, cost: cost, lots: consumed)
    end

    # The block returns the signed amount to count for an entry, in the entry's
    # own currency; it is converted at the entry's date.
    def sum_cash
      cash_entries.sum do |entry|
        counted = yield(entry).to_d
        next 0.to_d if counted.zero?

        convert(Money.new(counted, entry.currency), entry.date).amount
      end
    end

    def dividend?(entry)
      entry.name.match?(/\A(Dividend|Payment in lieu)/i)
    end

    def tax?(entry)
      entry.name.match?(/tax/i)
    end

    def convert(money_value, date)
      return money_value if money_value.currency.iso_code == account.currency

      money_value.exchange_to(account.currency, date: date, fallback_rate: 1)
    end

    def money(amount)
      Money.new(amount, account.currency)
    end
end
