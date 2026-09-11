require "test_helper"

class AccountOrderingTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "ordered falls back to name while positions are unset" do
    @family.accounts.update_all(position: nil)

    names = @family.accounts.ordered.pluck(:name)
    assert_equal names.sort, names
  end

  test "ordered respects position over name" do
    a, b, c = @family.accounts.ordered.first(3)
    @family.reorder_accounts!([ c.id, a.id, b.id ])

    assert_equal [ c.id, a.id, b.id ], @family.accounts.ordered.first(3).map(&:id)
  end

  test "reorder_accounts! assigns a contiguous sequence from 1" do
    ids = @family.accounts.ordered.pluck(:id)
    @family.reorder_accounts!(ids.reverse)

    assert_equal (1..ids.size).to_a, @family.accounts.ordered.pluck(:position)
  end

  test "reorder_accounts! ignores ids from another family" do
    intruder = families(:empty).accounts.create!(
      name: "Someone Else's Account",
      balance: 1,
      currency: "USD",
      accountable: Depository.new
    )
    mine = @family.accounts.ordered.pluck(:id)
    before = intruder.position

    moved = @family.reorder_accounts!([ intruder.id ] + mine)

    assert_equal mine.size, moved
    assert_equal before, intruder.reload.position
    assert_equal mine, @family.accounts.ordered.pluck(:id)
  end

  test "reorder_accounts! is a no-op for an empty list" do
    positions = @family.accounts.order(:id).pluck(:position)

    assert_equal 0, @family.reorder_accounts!([])
    assert_equal positions, @family.accounts.order(:id).pluck(:position)
  end

  # build_cache_key reads accounts.maximum(:updated_at), and update_all skips
  # timestamps -- so without an explicit bump the balance sheet would keep
  # serving the old order.
  test "reorder_accounts! expires the balance sheet cache key" do
    before = @family.build_cache_key("balance_sheet_account_rows", invalidate_on_data_updates: true)

    travel 1.second do
      @family.reorder_accounts!(@family.accounts.ordered.pluck(:id).reverse)
    end

    assert_not_equal before,
      Family.find(@family.id).build_cache_key("balance_sheet_account_rows", invalidate_on_data_updates: true)
  end

  test "new accounts are appended to the end of the order" do
    @family.reorder_accounts!(@family.accounts.ordered.pluck(:id))
    max = @family.accounts.maximum(:position)

    account = @family.accounts.create!(
      name: "Brand New",
      balance: 100,
      currency: "USD",
      accountable: Depository.new
    )

    assert_equal max + 1, account.position
    assert_equal account.id, @family.accounts.ordered.last.id
  end

  # The dashboard and sidebar both read balance_sheet.account_groups, which builds
  # groups with group_by -- so it inherits whatever order the query produced.
  test "balance sheet account groups follow the manual order" do
    all_ids = @family.accounts.visible.ordered.pluck(:id)
    @family.reorder_accounts!(all_ids.reverse)
    Rails.cache.clear

    depositories = @family.accounts.visible.where(accountable_type: "Depository").ordered.pluck(:id)
    skip "needs at least two depository accounts" if depositories.size < 2

    group = Family.find(@family.id).balance_sheet.assets.account_groups.find { |g| g.key == "depository" }
    assert_equal depositories, group.accounts.map(&:id)
  end
end
