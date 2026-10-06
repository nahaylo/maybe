require "test_helper"

class PortfolioMapsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  test "renders the map grouped by account" do
    get portfolio_map_url

    assert_response :success
    assert_select "h1", text: "Portfolio map"
    assert_select "a[aria-current=page]", text: "Account"
  end

  test "switches to grouping by currency" do
    get portfolio_map_url(group: "currency")

    assert_response :success
    assert_select "a[aria-current=page]", text: "Currency"
  end
end
