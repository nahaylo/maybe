require "test_helper"

class AccountTest < ActiveSupport::TestCase
  include SyncableInterfaceTest, EntriesTestHelper

  setup do
    @account = @syncable = accounts(:depository)
    @family = families(:dylan_family)
  end

  test "icon falls back to the accountable type default" do
    assert_nil @account.lucide_icon
    assert_equal Depository.icon, @account.icon
  end

  test "icon prefers the user's pick" do
    @account.update!(lucide_icon: "piggy-bank")
    assert_equal "piggy-bank", @account.icon
  end

  test "blank icon pick is stored as nil" do
    @account.update!(lucide_icon: "")
    assert_nil @account.reload.lucide_icon
  end

  test "rejects an icon outside the picker list" do
    @account.lucide_icon = "not-a-lucide-icon"
    assert_not @account.valid?
    assert_includes @account.errors[:lucide_icon], "is not included in the list"
  end

  test "color falls back to the accountable type default" do
    assert_nil @account.custom_color
    assert_equal Depository.color, @account.color
  end

  test "color prefers the user's pick" do
    @account.update!(custom_color: Account::COLORS.first)
    assert_equal Account::COLORS.first, @account.color
    assert_equal Account::COLORS.first, @account.custom_color
  end

  test "blank color pick is stored as nil and resolves to the type default" do
    @account.update!(custom_color: "")
    assert_nil @account.reload.custom_color
    assert_equal Depository.color, @account.color
  end

  test "rejects a color outside the palette" do
    @account.custom_color = "#ABCDEF"
    assert_not @account.valid?
    assert_includes @account.errors[:custom_color], "is not included in the list"
  end

  test "can destroy" do
    assert_difference "Account.count", -1 do
      @account.destroy
    end
  end

  test "gets short/long subtype label" do
    account = @family.accounts.create!(
      name: "Test Investment",
      balance: 1000,
      currency: "USD",
      subtype: "hsa",
      accountable: Investment.new
    )

    assert_equal "HSA", account.short_subtype_label
    assert_equal "Health Savings Account", account.long_subtype_label

    # Test with nil subtype
    account.update!(subtype: nil)
    assert_equal "Investments", account.short_subtype_label
    assert_equal "Investments", account.long_subtype_label
  end
  test "closed holdings are the sold-out securities' latest rows, and never a held one" do
    account = accounts(:investment)
    account.entries.delete_all
    account.holdings.delete_all
    sold = Security.create!(ticker: "MMP", offline: true)
    held = Security.create!(ticker: "OKE", offline: true)
    [ sold, held ].each do |security|
      account.entries.create!(date: Date.new(2023, 1, 5), name: "buy", amount: 100, currency: "USD",
                              entryable: Trade.new(qty: 1, price: 100, currency: "USD", security: security))
    end
    account.holdings.create!(security: sold, date: Date.new(2023, 9, 22), qty: 1, price: 100, amount: 100, currency: "USD")
    account.holdings.create!(security: sold, date: Date.new(2023, 9, 23), qty: 0, price: 0, amount: 0, currency: "USD")
    account.holdings.create!(security: held, date: Date.new(2023, 9, 23), qty: 1, price: 100, amount: 100, currency: "USD")

    assert_equal [ sold ], account.closed_holdings.map(&:security)
    assert_equal Date.new(2023, 9, 23), account.closed_holdings.sole.date
  end
end
