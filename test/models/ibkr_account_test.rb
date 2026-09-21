require "test_helper"

class IbkrAccountTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = IbkrItem.create!(family: @family, name: "ib", access_token: "token-a", query_id: "123456")
    @account = @family.accounts.create!(
      name: "IB Link Test", balance: 0, currency: "USD", accountable: Investment.new
    )
  end

  test "the link takes the account's currency" do
    link = IbkrAccount.create!(ibkr_item: @item, account: @account, ibkr_id: "U1")

    assert_equal "USD", link.currency
  end

  test "one currency of an IBKR account cannot be linked twice within a connection" do
    IbkrAccount.create!(ibkr_item: @item, account: @account, ibkr_id: "U1")
    other = @family.accounts.create!(
      name: "IB Link Test 2", balance: 0, currency: "USD", accountable: Investment.new
    )

    duplicate = IbkrAccount.new(ibkr_item: @item, account: other, ibkr_id: "U1")

    assert_not duplicate.valid?
  end

  test "the same IBKR account links once per currency" do
    IbkrAccount.create!(ibkr_item: @item, account: @account, ibkr_id: "U1")
    eur = @family.accounts.create!(
      name: "IB Link Test EUR", balance: 0, currency: "EUR", accountable: Investment.new
    )

    assert IbkrAccount.new(ibkr_item: @item, account: eur, ibkr_id: "U1").valid?
  end

  test "refuses a link whose currency is not the account's" do
    link = IbkrAccount.new(ibkr_item: @item, account: @account, ibkr_id: "U1", currency: "EUR")

    assert_not link.valid?
    assert_includes link.errors[:account].join, "is in USD"
  end

  # The token authenticates one family's broker; pointing it at another
  # family's ledger would import real money into the wrong books.
  test "refuses to link an account from another family" do
    stranger = families(:empty).accounts.create!(
      name: "Someone else's", balance: 0, currency: "USD", accountable: Investment.new
    )

    link = IbkrAccount.new(ibkr_item: @item, account: stranger, ibkr_id: "U1")

    assert_not link.valid?
    assert_includes link.errors[:account].join, "different family"
  end

  test "unlinking leaves the imported entries alone" do
    link = IbkrAccount.create!(ibkr_item: @item, account: @account, ibkr_id: "U1")
    @account.entries.create!(
      date: Date.current, amount: 10, currency: "USD", name: "imported", entryable: Transaction.new
    )

    assert_no_difference "Entry.count" do
      link.destroy!
    end
  end
end
