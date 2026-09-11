require "test_helper"

class AccountTypesTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @account = accounts(:depository)
  end

  test "the new-account picker offers the new types" do
    get new_account_path
    assert_response :success

    labels = Nokogiri::HTML(response.body)
      .css("a[href*='step=method_select']").map { |a| a.text.squish }

    assert_includes labels, "Deposit"
    assert_includes labels, "Business"
  end

  test "new and edit pages render for both new types" do
    get new_deposit_path
    assert_response :success
    get new_business_path
    assert_response :success

    @account.convert_to!("Deposit")
    get edit_deposit_path(@account)
    assert_response :success
  end

  test "converting an account through the endpoint keeps its history" do
    entries = @account.entries.count

    patch convert_account_path(@account), params: { accountable_type: "Business" }

    assert_redirected_to account_path(@account)
    @account.reload
    assert_equal "Business", @account.accountable_type
    assert_equal entries, @account.entries.count
  end

  test "converting to an unknown type is rejected" do
    patch convert_account_path(@account), params: { accountable_type: "Nonsense" }

    assert_redirected_to account_path(@account)
    assert_equal "Depository", @account.reload.accountable_type
  end

  test "the edit form exposes a type selector on an unlinked account" do
    get edit_depository_path(@account)
    assert_response :success

    select = Nokogiri::HTML(response.body).at_css("select[name=accountable_type]")
    assert select, "expected a type selector on the edit form"
    assert_includes select.css("option").map { |o| o["value"] }, "Deposit"
  end

  # A linked account's type comes from the provider, so it must not be offered.
  test "no type selector on a linked account" do
    linked = accounts(:connected)
    assert linked.linked?

    get edit_depository_path(linked)
    assert_response :success
    assert_nil Nokogiri::HTML(response.body).at_css("select[name=accountable_type]")
  end
end
