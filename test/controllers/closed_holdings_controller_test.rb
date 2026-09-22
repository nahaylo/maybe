require "test_helper"

class ClosedHoldingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @account = accounts(:investment)
  end

  test "renders the closed positions frame" do
    get closed_holdings_url(account_id: @account.id)

    assert_response :success
    assert_select "h2", text: "Closed positions"
  end

  test "lists a position that was sold out, newest sale first, and not one still held" do
    @account.entries.delete_all
    @account.holdings.delete_all
    sold = Security.create!(ticker: "MMP", offline: true)
    held = Security.create!(ticker: "OKE", offline: true)
    trade(sold, Date.new(2023, 1, 5), 10, 47)
    trade(sold, Date.new(2023, 9, 22), -10, 69)
    trade(held, Date.new(2023, 1, 5), 8, 50)
    @account.holdings.create!(security: sold, date: Date.current, qty: 0, price: 0, amount: 0, currency: "USD")
    @account.holdings.create!(security: held, date: Date.current, qty: 8, price: 60, amount: 480, currency: "USD")

    get closed_holdings_url(account_id: @account.id)

    assert_response :success
    assert_select "a", text: "MMP"
    assert_select "a", text: "OKE", count: 0
    assert_match(/220\.00/, response.body, "realised 10 × (69 − 47)")
  end

  private
    def trade(security, date, qty, price)
      @account.entries.create!(
        date: date, name: "trade", amount: qty * price, currency: "USD",
        entryable: Trade.new(qty: qty, price: price, currency: "USD", security: security)
      )
    end
end
