require "test_helper"

class AccountsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:depository)
  end

  test "should get index" do
    get accounts_url
    assert_response :success
  end

  test "should get show" do
    get account_url(@account)
    assert_response :success
  end

  test "vehicle page lists spending attributed to it from other accounts" do
    vehicle = accounts(:vehicle)
    create_transaction(account: @account, name: "Winter tyres", amount: 400, attributed_account: vehicle)
    create_transaction(account: @account, name: "Groceries", amount: 50)

    get account_url(vehicle, tab: "costs")

    assert_response :success
    assert_select "#costs_account_#{vehicle.id}" do
      assert_select "*", text: /Winter tyres/
      assert_select "*", text: /Groceries/, count: 0
    end
  end

  # Tabs switch client-side, so a pagination link must carry its own tab or
  # following it lands on the default tab with the right page of the wrong list.
  test "each list's pagination links pin their own tab" do
    vehicle = accounts(:vehicle)
    12.times { |i| create_transaction(account: @account, name: "Cost #{i}", amount: 10, attributed_account: vehicle) }
    12.times { |i| vehicle.entries.create!(date: i.days.ago.to_date, amount: 1000 - i, currency: "USD", name: "Odometer", entryable: Mileage.new) }

    get account_url(vehicle)

    assert_response :success
    assert_select "#costs_account_#{vehicle.id} a[href*='costs_page=2'][href*='tab=costs']"
    assert_select "#entries_account_#{vehicle.id} a[href*='page=2'][href*='tab=activity']"
  end

  test "should sync account" do
    post sync_account_url(@account)
    assert_redirected_to account_url(@account)
  end

  test "should get sparkline" do
    get sparkline_account_url(@account)
    assert_response :success
  end

  test "destroys account" do
    delete account_url(@account)
    assert_redirected_to accounts_path
    assert_enqueued_with job: DestroyJob
    assert_equal "Account scheduled for deletion", flash[:notice]
  end
end
