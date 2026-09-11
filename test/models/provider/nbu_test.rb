require "test_helper"

class Provider::NbuTest < ActiveSupport::TestCase
  setup do
    @subject = @nbu = Provider::Nbu.new
  end

  test "fetches single exchange rate quoted in UAH" do
    VCR.use_cassette("nbu/exchange_rate") do
      response = @nbu.fetch_exchange_rate(
        from: "USD",
        to: "UAH",
        date: Date.parse("2024-01-02")
      )

      assert response.success?

      rate = response.data

      assert_equal "USD", rate.from
      assert_equal "UAH", rate.to
      assert_equal Date.parse("2024-01-02"), rate.date
      assert_in_delta 38.01, rate.rate, 0.5
    end
  end

  test "inverts the quote when converting from UAH" do
    VCR.use_cassette("nbu/exchange_rate") do
      response = @nbu.fetch_exchange_rate(
        from: "UAH",
        to: "USD",
        date: Date.parse("2024-01-02")
      )

      rate = response.data

      # NBU quotes UAH per 1 USD, so the UAH -> USD direction is the reciprocal
      assert_equal "UAH", rate.from
      assert_equal "USD", rate.to
      assert_in_delta 1 / 38.01, rate.rate, 0.001
    end
  end

  test "rounds the reciprocal instead of storing meaningless precision" do
    VCR.use_cassette("nbu/exchange_rate") do
      rate = @nbu.fetch_exchange_rate(from: "UAH", to: "USD", date: Date.parse("2024-01-02")).data.rate

      # 1 / 38.0144 is a repeating decimal; keep it to 12 significant digits
      assert_operator rate.to_s("F").split(".").last.length, :<=, 14
      assert_in_delta 1 / 38.0144, rate, 0.0000001
    end
  end

  test "fetches historical rates day by day and skips non-publication days" do
    VCR.use_cassette("nbu/exchange_rates") do
      response = @nbu.fetch_exchange_rates(
        from: "USD", to: "UAH", start_date: Date.parse("2024-01-01"), end_date: Date.parse("2024-01-07")
      )

      assert response.success?

      rates = response.data

      assert rates.count.positive?
      assert rates.all? { |rate| rate.date.is_a?(Date) }
      assert rates.all? { |rate| rate.rate.positive? }
    end
  end

  test "only supports pairs involving UAH" do
    assert @nbu.supports?(from: "USD", to: "UAH")
    assert @nbu.supports?(from: "UAH", to: "EUR")
    assert_not @nbu.supports?(from: "USD", to: "EUR")
    assert_not @nbu.supports?(from: "UAH", to: "UAH")
  end

  test "returns failed response for unsupported pair" do
    response = @nbu.fetch_exchange_rate(from: "USD", to: "EUR", date: Date.parse("2024-01-02"))

    assert_not response.success?
    assert_match(/only supports pairs involving UAH/, response.error.message)
  end
end
