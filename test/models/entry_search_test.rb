require "test_helper"

class EntrySearchTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @family.accounts.each { |account| account.entries.delete_all }

    @expense = create_transaction(account: @account, amount: 100, kind: "standard")
    @income = create_transaction(account: @account, amount: -50, kind: "standard")
    @transfer = create_transaction(account: @account, amount: 200, kind: "funds_movement")
    @valuation = create_valuation(account: @account, amount: 5000)
    @trade = @account.entries.create!(
      date: Date.current, name: "Buy 1 share of AAPL", amount: 10, currency: "USD",
      entryable: Trade.new(qty: 1, price: 10, currency: "USD", security: securities(:aapl))
    )
  end

  test "no type filter returns every entry" do
    assert_equal entries(@expense, @income, @transfer, @valuation, @trade), search(types: nil)
    assert_equal entries(@expense, @income, @transfer, @valuation, @trade), search(types: [])
  end

  # Checking every offered type is equivalent to checking none: both mean "no filtering".
  test "selecting every type returns every entry" do
    assert_equal entries(@expense, @income, @transfer, @valuation, @trade),
                 search(types: %w[income expense transfer trade])
  end

  test "selecting the three transaction types shows every transaction but no trades" do
    assert_equal entries(@expense, @income, @transfer, @valuation),
                 search(types: %w[income expense transfer])
  end

  test "filters transactions by single type" do
    assert_equal entries(@expense, @valuation), search(types: %w[expense])
    assert_equal entries(@income, @valuation), search(types: %w[income])
    assert_equal entries(@transfer, @valuation), search(types: %w[transfer])
  end

  test "filters transactions by type pairs" do
    assert_equal entries(@expense, @income, @valuation), search(types: %w[expense income])
    assert_equal entries(@expense, @transfer, @valuation), search(types: %w[expense transfer])
    assert_equal entries(@income, @transfer, @valuation), search(types: %w[income transfer])
  end

  # Valuations are balance anchors, not activity of any type, so the type
  # filter leaves them visible.
  test "valuations are never hidden by the type filter" do
    %w[income expense transfer trade].each do |type|
      assert_includes search(types: [ type ]), @valuation,
        "valuation should survive types=[#{type}]"
    end
  end

  # A buy is not income and a sell is not expense; showing them under those
  # filters made an investment account's Income view list its purchases.
  test "trades are hidden by the transaction type filters" do
    %w[income expense transfer].each do |type|
      assert_not_includes search(types: [ type ]), @trade, "trade should be hidden by types=[#{type}]"
    end
  end

  test "the trade type shows trades, alone or alongside a transaction type" do
    assert_equal entries(@trade, @valuation), search(types: %w[trade])
    assert_equal entries(@income, @trade, @valuation), search(types: %w[income trade])
  end

  test "zero-amount transactions count as expense only, not both buckets" do
    zero = create_transaction(account: @account, amount: 0, kind: "standard")

    assert_includes search(types: %w[expense]), zero
    assert_not_includes search(types: %w[income]), zero
  end

  test "type filter composes with the name search filter" do
    @expense.update!(name: "Groceries")

    assert_equal [ @expense ], search(types: %w[expense], search: "grocer")
    assert_empty search(types: %w[income], search: "grocer")
  end

  private
    def search(filters)
      @account.entries.search(filters).to_a.sort_by(&:id)
    end

    def entries(*records)
      records.sort_by(&:id)
    end
end
