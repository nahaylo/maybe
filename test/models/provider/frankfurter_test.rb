require "test_helper"

class Provider::FrankfurterTest < ActiveSupport::TestCase
  setup do
    @subject = @frankfurter = Provider::Frankfurter.new
  end

  test "fetches single exchange rate" do
    VCR.use_cassette("frankfurter/exchange_rate") do
      response = @frankfurter.fetch_exchange_rate(
        from: "USD",
        to: "GBP",
        date: Date.parse("2024-01-02")
      )

      assert response.success?

      rate = response.data

      assert_equal "USD", rate.from
      assert_equal "GBP", rate.to
      assert rate.date.is_a?(Date)
      assert_in_delta 0.78, rate.rate, 0.05
    end
  end

  test "fetches historical exchange rates for a date range" do
    VCR.use_cassette("frankfurter/exchange_rates") do
      response = @frankfurter.fetch_exchange_rates(
        from: "USD", to: "GBP", start_date: Date.parse("2024-01-01"), end_date: Date.parse("2024-01-31")
      )

      assert response.success?

      rates = response.data

      # ECB publishes on business days only, so we get fewer rates than days
      assert rates.count.between?(20, 23), "expected ~22 business days, got #{rates.count}"
      assert rates.all? { |rate| rate.date.is_a?(Date) }
      assert rates.all? { |rate| rate.rate.present? }
      assert_equal rates.map(&:date).sort, rates.map(&:date), "rates should be sorted by date"
    end
  end

  test "returns failed response when provider errors" do
    VCR.use_cassette("frankfurter/exchange_rate_error") do
      response = @frankfurter.fetch_exchange_rate(
        from: "USD",
        to: "NOPE",
        date: Date.parse("2024-01-02")
      )

      assert_not response.success?
      assert response.error.present?
    end
  end

  test "supports pairs within the ECB currency list" do
    VCR.use_cassette("frankfurter/currencies") do
      assert @frankfurter.supports?(from: "USD", to: "GBP")
      assert_not @frankfurter.supports?(from: "USD", to: "UAH"), "ECB feed does not publish UAH"
    end
  end
end
