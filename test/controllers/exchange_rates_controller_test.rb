require "test_helper"

class ExchangeRatesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @family = families(:dylan_family)
    @family.accounts.create!(name: "EUR Checking", balance: 0, currency: "EUR", accountable: Depository.new)
  end

  test "returns the rate and the converted amount" do
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", rate: 0.9, date: Date.current)

    get exchange_rate_url(format: :json), params: { from: "USD", to: "EUR", date: Date.current, amount: 100 }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 0.9, body["rate"].to_d
    assert_equal 90, body["converted_amount"].to_d
    assert_equal 2, body.dig("to_currency", "default_precision")
    assert_not body["stale"]
  end

  test "returns a null rate rather than an error when none is available" do
    ExchangeRate.expects(:find_or_fetch_rate).returns(nil)

    get exchange_rate_url(format: :json), params: { from: "USD", to: "EUR", date: Date.current, amount: 100 }

    assert_response :success
    body = JSON.parse(response.body)
    assert_nil body["rate"]
    assert_nil body["converted_amount"]
  end

  test "carries the last published rate forward and flags it as stale" do
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", rate: 0.9, date: Date.current - 2.days)

    get exchange_rate_url(format: :json), params: { from: "USD", to: "EUR", date: Date.current, amount: 100 }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 0.9, body["rate"].to_d
    assert_equal 90, body["converted_amount"].to_d
    assert_equal((Date.current - 2.days).to_s, body["rate_date"])
    assert body["stale"]
  end

  test "returns a rate of 1 when both currencies match" do
    get exchange_rate_url(format: :json), params: { from: "USD", to: "USD", amount: 100 }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 1, body["rate"].to_d
    assert_equal 100, body["converted_amount"].to_d
  end

  test "rejects an unknown currency" do
    get exchange_rate_url(format: :json), params: { from: "USD", to: "NOTACURRENCY" }
    assert_response :unprocessable_entity
  end

  test "rejects an unparseable date" do
    get exchange_rate_url(format: :json), params: { from: "USD", to: "EUR", date: "not-a-date" }
    assert_response :unprocessable_entity
  end

  # Guards against driving unbounded provider lookups for arbitrary pairs
  test "rejects a currency the family does not use" do
    get exchange_rate_url(format: :json), params: { from: "USD", to: "JPY" }
    assert_response :unprocessable_entity
  end

  test "imports the pair on demand and returns the fetched rate" do
    ExchangeRate.delete_all

    # Stub the provider layer so the test never touches the network
    ExchangeRate::Backfiller.any_instance.stubs(:backfill).with do
      ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", rate: 0.87, date: Date.current)
      true
    end.returns([])

    post exchange_rate_url(format: :json), params: { from: "USD", to: "EUR", date: Date.current, amount: 100 }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 0.87, body["rate"].to_d
    assert_equal 87, body["converted_amount"].to_d
  end

  test "returns a null rate when no provider can supply the pair" do
    ExchangeRate.delete_all
    ExchangeRate::Backfiller.any_instance.stubs(:backfill).returns([])

    post exchange_rate_url(format: :json), params: { from: "USD", to: "EUR", date: Date.current, amount: 100 }

    assert_response :success
    assert_nil JSON.parse(response.body)["rate"]
  end

  test "refuses to import a pair the family does not use" do
    ExchangeRate::Backfiller.any_instance.expects(:backfill).never

    post exchange_rate_url(format: :json), params: { from: "USD", to: "JPY" }

    assert_response :unprocessable_entity
  end

  test "requires authentication" do
    @user.sessions.each { |session| delete session_path(session) }

    get exchange_rate_url(format: :json), params: { from: "USD", to: "EUR" }
    assert_redirected_to new_session_url
  end
end
