require "test_helper"

# Яна's TSLA history, verbatim: 5 bought at 375, all 5 sold at 427.56, then 3
# bought at 307.325 and still held; a mark of 364.27 on the latest report.
class Holding::PerformanceTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:investment) # USD
    @account.entries.delete_all
    @security = Security.create!(ticker: "TSLA", exchange_operating_mic: "XNAS", offline: true)
    Security.stubs(:provider).returns(nil)
    @security.prices.create!(date: Date.new(2026, 9, 18), price: 364.27, currency: "USD")

    @buy1 = trade(Date.new(2026, 4, 1), 5, 375)
    @sell = trade(Date.new(2026, 5, 12), -5, 427.56)
    @buy2 = trade(Date.new(2026, 7, 30), 3, 307.325)
    commission(@buy1, 1.0)
    commission(@sell, 1.05)
    commission(@buy2, 1.0)
  end

  test "the position and its cost basis are the lots still open, FIFO" do
    perf = performance

    assert_equal 3.to_d, perf.open_qty
    assert_equal Money.new(921.975, "USD"), perf.cost_basis
    assert_equal Money.new(307.325, "USD"), perf.cost_basis_per_share
  end

  test "a sell realises the difference against the oldest lots" do
    perf = performance

    closing = perf.closings.sole
    assert_equal @sell, closing.sell_entry
    assert_equal 2137.8.to_d, closing.proceeds
    assert_equal 1875.to_d, closing.cost
    assert_equal 262.8.to_d, closing.gain
    assert_equal 14.0, closing.percent
    assert_equal Money.new(262.8, "USD"), perf.realized_gain
  end

  test "unrealised gain is the open lots against the latest price" do
    perf = performance

    assert_equal Money.new(364.27, "USD"), perf.current_price
    assert_equal Money.new(1092.81, "USD"), perf.market_value
    assert_equal Money.new(170.835, "USD"), perf.unrealized.value
    assert_equal 18.5, perf.unrealized.percent
  end

  test "fees, dividends and tax come from the linked cash rows" do
    dividend(Date.new(2026, 6, 1), 7.35)
    tax(Date.new(2026, 6, 1), 0.11)

    perf = performance

    assert_equal Money.new(3.05, "USD"), perf.fees
    assert_equal Money.new(7.35, "USD"), perf.dividends
    assert_equal Money.new(0.11, "USD"), perf.withholding_tax
    assert_equal Money.new(0, "USD"), perf.other_income
    # 170.835 + 262.8 + 7.35 - 0.11 - 3.05
    assert_equal Money.new(437.825, "USD"), perf.total_return
  end

  # IBKR books a withholding-tax correction as tax paid, tax reversed, tax
  # paid again. The reversal is an inflow, but it is still tax.
  test "a tax refund nets against tax rather than counting as income" do
    tax(Date.new(2026, 6, 1), 1.10)
    tax(Date.new(2026, 6, 1), -1.10)
    tax(Date.new(2026, 6, 1), 0.11)

    perf = performance

    assert_equal Money.new(0.11, "USD"), perf.withholding_tax
    assert_equal Money.new(0, "USD"), perf.other_income
  end

  test "cash rows of another security do not leak in" do
    other = Security.create!(ticker: "PM", exchange_operating_mic: "XNYS", offline: true)
    @account.entries.create!(
      date: Date.new(2026, 6, 1), name: "Dividend: PM", amount: -7.35, currency: "USD",
      entryable: Transaction.new(kind: "investment_activity", security: other)
    )

    assert_equal Money.new(0, "USD"), performance.dividends
  end

  test "each trade knows what became of it" do
    perf = performance

    first = perf.outcome_for(@buy1)
    assert_predicate first, :buy?
    assert_equal 0.to_d, first.remaining_qty
    assert_equal Date.new(2026, 5, 12), first.closed_on

    sale = perf.outcome_for(@sell)
    assert_predicate sale, :sell?
    assert_equal Money.new(262.8, "USD"), sale.gain
    assert_equal 375.to_d, sale.closing.cost_per_share

    held = perf.outcome_for(@buy2)
    assert_predicate held, :still_held?
    assert_equal 3.to_d, held.remaining_qty
    assert_equal Money.new(170.835, "USD"), held.gain
    assert_equal 18.5, held.percent
  end

  test "a partial sell leaves the rest of the lot open" do
    @account.entries.delete_all
    buy = trade(Date.new(2026, 4, 1), 10, 100)
    trade(Date.new(2026, 5, 1), -4, 120)

    perf = performance

    assert_equal 6.to_d, perf.open_qty
    assert_equal Money.new(600, "USD"), perf.cost_basis
    assert_equal Money.new(80, "USD"), perf.realized_gain
    assert_equal 6.to_d, perf.outcome_for(buy).remaining_qty
    assert_nil perf.outcome_for(buy).closed_on
  end

  test "without a price there is no market value or unrealised gain, but the rest still works" do
    Security::Price.delete_all

    perf = performance

    assert_nil perf.current_price
    assert_nil perf.unrealized
    assert_equal Money.new(262.8 - 3.05, "USD"), perf.total_return
  end

  test "the timeline interleaves trades and linked cash rows, newest first" do
    dividend(Date.new(2026, 6, 1), 7.35)

    names = performance.timeline.map(&:name)

    assert_equal [ "Buy 3.0 shares of TSLA", "Dividend: TSLA", "Sell 5.0 shares of TSLA", "Buy 5.0 shares of TSLA" ],
                 names.grep_v(/Commission/)
  end

  private
    def performance = Holding::Performance.new(@account, @security)

    def trade(date, qty, price)
      @account.entries.create!(
        date: date, name: Trade.build_name(qty.positive? ? "buy" : "sell", qty.abs, "TSLA"),
        amount: qty * price, currency: "USD",
        entryable: Trade.new(qty: qty, price: price, currency: "USD", security: @security)
      )
    end

    def commission(trade_entry, amount)
      @account.entries.create!(
        date: trade_entry.date, name: "Commission: #{trade_entry.name}", amount: amount, currency: "USD",
        entryable: Transaction.new(kind: "investment_activity", security: @security)
      )
    end

    def dividend(date, amount)
      @account.entries.create!(
        date: date, name: "Dividend: TSLA", amount: -amount, currency: "USD",
        entryable: Transaction.new(kind: "investment_activity", security: @security)
      )
    end

    def tax(date, amount)
      @account.entries.create!(
        date: date, name: "Withholding tax: TSLA", amount: amount, currency: "USD",
        entryable: Transaction.new(kind: "investment_activity", security: @security)
      )
    end
end
