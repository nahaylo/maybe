require "test_helper"

class SecurityTest < ActiveSupport::TestCase
  # Below has 3 example scenarios:
  # 1. Original ticker
  # 2. Duplicate ticker on a different exchange (different market price)
  # 3. "Offline" version of the same ticker (for users not connected to a provider)
  test "can have duplicate tickers if exchange is different" do
    original = Security.create!(ticker: "TEST", exchange_operating_mic: "XNAS")
    duplicate = Security.create!(ticker: "TEST", exchange_operating_mic: "CBOE")
    offline = Security.create!(ticker: "TEST", exchange_operating_mic: nil)

    assert original.valid?
    assert duplicate.valid?
    assert offline.valid?
  end

  test "cannot have duplicate tickers if exchange is the same" do
    original = Security.create!(ticker: "TEST", exchange_operating_mic: "XNAS")
    duplicate = Security.new(ticker: "TEST", exchange_operating_mic: "XNAS")

    assert_not duplicate.valid?
    assert_equal [ "has already been taken" ], duplicate.errors[:ticker]
  end

  test "cannot have duplicate tickers if exchange is nil" do
    original = Security.create!(ticker: "TEST", exchange_operating_mic: nil)
    duplicate = Security.new(ticker: "TEST", exchange_operating_mic: nil)

    assert_not duplicate.valid?
    assert_equal [ "has already been taken" ], duplicate.errors[:ticker]
  end

  test "casing is ignored when checking for duplicates" do
    original = Security.create!(ticker: "TEST", exchange_operating_mic: "XNAS")
    duplicate = Security.new(ticker: "tEst", exchange_operating_mic: "xNaS")

    assert_not duplicate.valid?
    assert_equal [ "has already been taken" ], duplicate.errors[:ticker]
  end

  # No provider is configured, and imported prices land on trade days and
  # report dates. The drawer showed "Unknown" for every holding because only
  # today's price was ever looked up.
  test "current price falls back to the latest price on file when today has none" do
    Security.stubs(:provider).returns(nil)
    security = Security.create!(ticker: "MARKED", offline: true)
    security.prices.create!(date: 10.days.ago.to_date, price: 90, currency: "USD")
    security.prices.create!(date: 3.days.ago.to_date, price: 95, currency: "USD")

    assert_equal Money.new(95, "USD"), security.current_price
  end

  test "current price is nil when nothing is on file" do
    Security.stubs(:provider).returns(nil)
    security = Security.create!(ticker: "UNPRICED", offline: true)

    assert_nil security.current_price
  end
end
