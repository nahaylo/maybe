require "test_helper"

class InvestmentPerformancesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @account = accounts(:investment)
  end

  test "renders the performance frame for this year" do
    get investment_performance_url(account_id: @account.id)

    assert_response :success
    assert_select "h2", text: "Performance"
  end

  test "an out-of-range year falls back to the current one" do
    get investment_performance_url(account_id: @account.id, year: 1800)

    assert_response :success
    assert_select "h2", text: "Performance"
  end
end
