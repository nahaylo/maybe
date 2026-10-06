require "test_helper"

class Family::PortfolioMapTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:investment) # USD
    @family.update!(currency: "USD")
    @account.entries.delete_all
    @account.holdings.delete_all
    Security.stubs(:provider).returns(nil)

    @winner = Security.create!(ticker: "WIN", name: "Winner Inc", offline: true)
    @loser = Security.create!(ticker: "LOSE", name: "Loser Inc", offline: true)
    position(@winner, qty: 10, cost: 100, price: 150) # +50%
    position(@loser, qty: 5, cost: 200, price: 150)   # -25%
  end

  test "one tile per open position, sized by value and coloured by return against FIFO cost" do
    map = Family::PortfolioMap.new(@family)
    tiles = map.tiles.index_by(&:ticker)

    assert_equal Money.new(1500, "USD"), tiles["WIN"].value
    assert_equal 50.0, tiles["WIN"].percent
    assert_equal Money.new(500, "USD"), tiles["WIN"].gain
    assert_equal(-25.0, tiles["LOSE"].percent)
    assert_equal Money.new(2250, "USD"), map.total_value
    assert_equal Money.new(2000, "USD"), map.total_cost
  end

  test "groups by account by default, by currency on request, and ignores an unknown grouping" do
    assert_equal [ @account.name ], Family::PortfolioMap.new(@family).groups.map(&:name)
    assert_equal [ "USD" ], Family::PortfolioMap.new(@family, group_by: "currency").groups.map(&:name)
    assert_equal "account", Family::PortfolioMap.new(@family, group_by: "nonsense").group_by
  end

  test "a sold-out position has no tile" do
    @account.holdings.where(security: @loser).update_all(qty: 0, amount: 0)

    assert_equal [ "WIN" ], Family::PortfolioMap.new(@family).tiles.map(&:ticker)
  end

  test "the tree carries what the chart draws, largest first" do
    tree = Family::PortfolioMap.new(@family).as_tree(url_for_holding: ->(h) { "/holdings/#{h.id}" })
    tiles = tree[:children].sole[:children]

    assert_equal %w[WIN LOSE], tiles.map { |t| t[:ticker] }
    assert_equal 1500.0, tiles.first[:value]
    assert_equal 66.7, tiles.first[:weight]
    assert_match %r{\A/holdings/}, tiles.first[:url]
  end

  private
    def position(security, qty:, cost:, price:)
      @account.entries.create!(
        date: 10.days.ago.to_date, name: "Buy #{security.ticker}", amount: qty * cost, currency: "USD",
        entryable: Trade.new(qty: qty, price: cost, currency: "USD", security: security)
      )
      security.prices.create!(date: Date.current, price: price, currency: "USD")
      @account.holdings.create!(security: security, date: Date.current, qty: qty, price: price, amount: qty * price, currency: "USD")
    end
end
