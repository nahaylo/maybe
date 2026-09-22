# What an investment account has earned, across every security it has ever
# traded: the per-security Holding::Performance figures rolled up, plus the
# closed positions and dividends of one year for the "how did I do this year"
# question.
#
# Amounts are in the account's currency. Realised gains are dated by the sell,
# dividends and fees by the day the cash moved.
class Account::InvestmentPerformance
  Row = Data.define(:security, :performance)
  Sale = Data.define(:security, :closing) do
    def date = closing.sell_entry.date
  end
  DividendLine = Data.define(:security, :payments, :gross, :tax) do
    def net = gross - tax
  end

  attr_reader :account, :year

  def initialize(account, year: Date.current.year)
    @account = account
    @year = year
  end

  def range
    Date.new(year, 1, 1)..Date.new(year, 12, 31)
  end

  # Years with any trade or linked cash row, newest first, for the selector.
  def years
    dates = account.entries.where(entryable_type: "Trade").pluck(:date) +
            account.entries.where(entryable: account.transactions.where.not(security_id: nil)).pluck(:date)
    (dates.map(&:year) << Date.current.year).uniq.sort.reverse
  end

  def rows
    @rows ||= Security.where(id: account.trades.select(:security_id))
                      .order(:ticker)
                      .map { |security| Row.new(security: security, performance: Holding::Performance.new(account, security)) }
  end

  # ---- this year

  def sales
    rows.flat_map { |row| row.performance.closings.map { |c| Sale.new(security: row.security, closing: c) } }
        .select { |sale| range.cover?(sale.date) }
        .sort_by(&:date)
        .reverse
  end

  def realized = sum { |p| p.realized_gain(range) }
  def dividends = sum { |p| p.dividends(range) }
  def withholding_tax = sum { |p| p.withholding_tax(range) }
  def fees = sum { |p| p.fees(range) }
  def other_income = sum { |p| p.other_income(range) }
  def net_dividends = dividends - withholding_tax

  def dividend_lines
    rows.filter_map do |row|
      perf = row.performance
      payments = perf.dividend_entries.count { |e| range.cover?(e.date) }
      next if payments.zero? && perf.withholding_tax(range).zero?

      DividendLine.new(security: row.security, payments: payments, gross: perf.dividends(range), tax: perf.withholding_tax(range))
    end.sort_by { |line| -line.net.amount }
  end

  # Net dividends per month of the year, January first.
  def dividends_by_month
    (1..12).map do |month|
      month_range = Date.new(year, month, 1)..Date.new(year, month, -1)
      sum { |p| p.dividends(month_range) - p.withholding_tax(month_range) }
    end
  end

  # ---- all time, as of now

  def market_value = sum { |p| p.market_value || money(0) }
  def cost_basis = sum { |p| p.cost_basis }
  def unrealized = sum { |p| p.unrealized ? p.unrealized.value : money(0) }
  def total_return = sum { |p| p.total_return }

  private
    def sum
      rows.sum(money(0)) { |row| yield(row.performance) }
    end

    def money(amount)
      Money.new(amount, account.currency)
    end
end
