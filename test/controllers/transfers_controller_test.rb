require "test_helper"

class TransfersControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  test "should get new" do
    get new_transfer_url
    assert_response :success
  end

  test "new preselects the account it was opened from" do
    get new_transfer_url(account_id: accounts(:depository).id)

    assert_response :success
    assert_select "select#transfer_from_account_id option[selected][value=?]", accounts(:depository).id
    assert_select "select#transfer_to_account_id option[selected]", count: 0
  end

  test "new groups accounts by type in sidebar order and hides disabled ones" do
    closed = families(:dylan_family).accounts.create!(
      name: "Closed account", balance: 0, currency: "USD", accountable: Depository.new, status: "disabled"
    )

    get new_transfer_url

    labels = css_select("select#transfer_from_account_id optgroup").map { |g| g["label"] }
    sidebar_order = Accountable::TYPES.map { |type| Accountable.from_type(type).display_name }
    assert_equal sidebar_order & labels, labels
    assert_operator labels.index("Cash"), :<, labels.index("Vehicles")
    assert_operator labels.index("Vehicles"), :<, labels.index("Credit Cards")

    assert_select "select#transfer_from_account_id optgroup[label='Cash'] option[value=?]", accounts(:depository).id
    assert_select "select#transfer_from_account_id option[value=?]", closed.id, count: 0
    assert_select "select#transfer_from_account_id option[value=?]", accounts(:connected).id, count: 0
    assert_select "select#transfer_from_account_id option[data-currency]", minimum: 1
  end

  test "can create transfers" do
    assert_difference "Transfer.count", 1 do
      post transfers_url, params: {
        transfer: {
          from_account_id: accounts(:depository).id,
          to_account_id: accounts(:credit_card).id,
          date: Date.current,
          amount: 100,
          name: "Test Transfer"
        }
      }
      assert_enqueued_with job: SyncJob
    end
  end

  test "creates a cross-currency transfer with an explicit destination amount" do
    eur_account = families(:dylan_family).accounts.create!(
      name: "EUR Checking", balance: 0, currency: "EUR", accountable: Depository.new
    )

    assert_difference "Transfer.count", 1 do
      post transfers_url, params: {
        transfer: {
          from_account_id: accounts(:depository).id,
          to_account_id: eur_account.id,
          date: Date.current,
          amount: 100,
          destination_amount: 95
        }
      }
    end

    assert_equal(-95, Transfer.order(:created_at).last.inflow_transaction.entry.amount)
  end

  test "refuses to create a cross-currency transfer when no rate is available" do
    eur_account = families(:dylan_family).accounts.create!(
      name: "EUR Checking", balance: 0, currency: "EUR", accountable: Depository.new
    )
    ExchangeRate.delete_all
    ExchangeRate.stubs(:provider).returns(nil)

    assert_no_difference "Transfer.count" do
      post transfers_url, params: {
        transfer: {
          from_account_id: accounts(:depository).id,
          to_account_id: eur_account.id,
          date: Date.current,
          amount: 100
        }
      }
    end

    assert_response :unprocessable_entity
    assert_match(/exchange rate/i, response.body)
    # The submitted amount is echoed back so the user is not asked to retype it
    assert_match(/value="100"/, response.body)
  end

  test "soft deletes transfer" do
    assert_difference -> { Transfer.count }, -1 do
      delete transfer_url(transfers(:one))
    end
  end

  test "can add notes to transfer" do
    transfer = transfers(:one)
    assert_nil transfer.notes

    patch transfer_url(transfer), params: { transfer: { notes: "Test notes" } }

    assert_redirected_to transactions_url
    assert_equal "Transfer updated", flash[:notice]
    assert_equal "Test notes", transfer.reload.notes
  end

  test "handles rejection without FrozenError" do
    transfer = transfers(:one)

    assert_difference "Transfer.count", -1 do
      patch transfer_url(transfer), params: {
        transfer: {
          status: "rejected"
        }
      }
    end

    assert_redirected_to transactions_url
    assert_equal "Transfer updated", flash[:notice]

    # Verify the transfer was actually destroyed
    assert_raises(ActiveRecord::RecordNotFound) do
      transfer.reload
    end
  end
end
