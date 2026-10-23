require "test_helper"

class Account::InvestmentPerformanceTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:investment) # USD
    @account.entries.delete_all
    Security.stubs(:provider).returns(nil)

    @tsla = Security.create!(ticker: "TSLA", exchange_operating_mic: "XNAS", offline: true)
    @pm = Security.create!(ticker: "PM", exchange_operating_mic: "XNYS", offline: true)
    @tsla.prices.create!(date: Date.new(2026, 9, 18), price: 364.27, currency: "USD")
    @pm.prices.create!(date: Date.new(2026, 9, 18), price: 188.62, currency: "USD")

    trade(@tsla, Date.new(2025, 11, 3), 2, 300)      # last year
    trade(@tsla, Date.new(2025, 12, 1), -2, 320)     # realised 40 last year
    trade(@tsla, Date.new(2026, 4, 1), 5, 375)
    trade(@tsla, Date.new(2026, 5, 12), -5, 427.56)  # realised 262.80 this year
    trade(@tsla, Date.new(2026, 7, 30), 3, 307.325)
    trade(@pm, Date.new(2026, 3, 9), 5, 170.67)

    cash(@pm, Date.new(2026, 4, 13), "Dividend: PM", -7.35)
    cash(@pm, Date.new(2026, 4, 13), "Withholding tax: PM", 0.11)
    cash(@pm, Date.new(2026, 7, 20), "Dividend: PM", -7.35)
    cash(@pm, Date.new(2026, 7, 20), "Withholding tax: PM", 0.11)
    cash(@pm, Date.new(2025, 12, 20), "Dividend: PM", -6.00) # last year
    cash(@tsla, Date.new(2026, 4, 1), "Commission: Buy 5.0 shares of TSLA", 1.0)
  end

  test "realised gains are the year's sales only" do
    perf = performance(2026)

    assert_equal Money.new(262.8, "USD"), perf.realized
    assert_equal [ "TSLA" ], perf.sales.map { |s| s.security.ticker }
    assert_equal Date.new(2026, 5, 12), perf.sales.sole.date

    assert_equal Money.new(40, "USD"), performance(2025).realized
  end

  test "dividends, tax and fees are the year's cash rows" do
    perf = performance(2026)

    assert_equal Money.new(14.7, "USD"), perf.dividends
    assert_equal Money.new(0.22, "USD"), perf.withholding_tax
    assert_equal Money.new(14.48, "USD"), perf.net_dividends
    assert_equal Money.new(1.0, "USD"), perf.fees

    line = perf.dividend_lines.sole
    assert_equal @pm, line.security
    assert_equal 2, line.payments
    assert_equal Money.new(14.48, "USD"), line.net

    assert_equal Money.new(6, "USD"), performance(2025).dividends
  end

  test "dividends by month put each payment in its month, net of tax" do
    by_month = performance(2026).dividends_by_month

    assert_equal 12, by_month.size
    assert_equal Money.new(7.24, "USD"), by_month[3]  # April
    assert_equal Money.new(7.24, "USD"), by_month[6]  # July
    assert_equal Money.new(0, "USD"), by_month[0]
  end

  test "position figures are as of now, regardless of year" do
    [ 2025, 2026 ].each do |year|
      perf = performance(year)

      # 3 TSLA at 364.27 + 5 PM at 188.62
      assert_equal Money.new(3 * 364.27.to_d + 5 * 188.62.to_d, "USD"), perf.market_value
      assert_equal Money.new(921.975.to_d + 853.35.to_d, "USD"), perf.cost_basis
    end
  end

  test "total return is every security's total, all time" do
    expected = Holding::Performance.new(@account, @tsla).total_return + Holding::Performance.new(@account, @pm).total_return

    assert_equal expected, performance(2026).total_return
  end

  test "years lists every year with activity, newest first, always including this one" do
    assert_equal [ Date.current.year, 2026, 2025 ].uniq, performance(2026).years
  end

  private
    def performance(year) = Account::InvestmentPerformance.new(@account, year: year)

    def trade(security, date, qty, price)
      @account.entries.create!(
        date: date, name: Trade.build_name(qty.positive? ? "buy" : "sell", qty.abs, security.ticker),
        amount: qty * price, currency: "USD",
        entryable: Trade.new(qty: qty, price: price, currency: "USD", security: security)
      )
    end

    def cash(security, date, name, amount)
      @account.entries.create!(
        date: date, name: name, amount: amount, currency: "USD",
        entryable: Transaction.new(kind: "investment_activity", security: security)
      )
    end
end
