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
  end

  test "no type filter returns every entry" do
    assert_equal entries(@expense, @income, @transfer, @valuation), search(types: nil)
    assert_equal entries(@expense, @income, @transfer, @valuation), search(types: [])
  end

  # Checking all three is equivalent to checking none: both mean "no filtering".
  test "selecting all three types returns every entry" do
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

  # Valuations and Trades are not income, expense or transfer, so the type filter
  # must not bucket them by amount sign and hide them.
  test "non-transaction entries are never hidden by the type filter" do
    %w[income expense transfer].each do |type|
      assert_includes search(types: [ type ]), @valuation,
        "valuation should survive types=[#{type}]"
    end
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
