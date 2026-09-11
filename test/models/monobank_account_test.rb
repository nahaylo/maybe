require "test_helper"

class MonobankAccountTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = MonobankItem.create!(family: @family, name: "personal", access_token: "token-a")
    @account = @family.accounts.create!(
      name: "Mono Link Test", balance: 0, currency: "UAH", accountable: Depository.new
    )
  end

  test "one Monobank account cannot be linked twice within a connection" do
    MonobankAccount.create!(monobank_item: @item, account: @account, monobank_id: "abc")
    other = @family.accounts.create!(
      name: "Mono Link Test 2", balance: 0, currency: "UAH", accountable: Depository.new
    )

    duplicate = MonobankAccount.new(monobank_item: @item, account: other, monobank_id: "abc")

    assert_not duplicate.valid?
  end

  # The token authenticates one family's bank; pointing it at another family's
  # ledger would import real money into the wrong books.
  test "refuses to link an account from another family" do
    stranger = families(:empty).accounts.create!(
      name: "Someone else's", balance: 0, currency: "UAH", accountable: Depository.new
    )

    link = MonobankAccount.new(monobank_item: @item, account: stranger, monobank_id: "abc")

    assert_not link.valid?
    assert_includes link.errors[:account].join, "different family"
  end

  test "unlinking leaves the imported entries alone" do
    link = MonobankAccount.create!(monobank_item: @item, account: @account, monobank_id: "abc")
    @account.entries.create!(
      date: Date.current, amount: 10, currency: "UAH", name: "imported", entryable: Transaction.new
    )

    assert_no_difference "Entry.count" do
      link.destroy!
    end
  end
end
