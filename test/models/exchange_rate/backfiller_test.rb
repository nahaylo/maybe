require "test_helper"
require "ostruct"

class ExchangeRate::BackfillerTest < ActiveSupport::TestCase
  # Stands in for a real provider so the backfiller's routing and importing
  # can be tested without hitting the network.
  class FakeProvider
    def initialize(rates_by_pair)
      @rates_by_pair = rates_by_pair
    end

    def supports?(from:, to:)
      @rates_by_pair.key?([ from, to ])
    end

    def fetch_exchange_rates(from:, to:, start_date:, end_date:)
      Provider::Response.new(success?: true, data: @rates_by_pair.fetch([ from, to ], []), error: nil)
    end
  end

  test "routes ECB pairs to Frankfurter and UAH pairs to NBU" do
    Provider::Frankfurter.any_instance.stubs(:supported_currencies).returns(%w[USD EUR GBP])

    assert_instance_of Provider::Frankfurter, ExchangeRate::Backfiller.provider_for(from: "USD", to: "EUR")
    assert_instance_of Provider::Nbu, ExchangeRate::Backfiller.provider_for(from: "USD", to: "UAH")
    assert_nil ExchangeRate::Backfiller.provider_for(from: "USD", to: "XYZ")
  end

  test "imports rates for the requested pair" do
    ExchangeRate.delete_all

    stub_providers_with([ "USD", "UAH" ] => [
      OpenStruct.new(from: "USD", to: "UAH", date: 2.days.ago.to_date, rate: 41.1),
      OpenStruct.new(from: "USD", to: "UAH", date: 1.day.ago.to_date, rate: 41.2),
      OpenStruct.new(from: "USD", to: "UAH", date: Date.current, rate: 41.3)
    ])

    results = ExchangeRate::Backfiller.new(
      pairs: [ [ "USD", "UAH" ] ],
      start_date: 2.days.ago.to_date,
      end_date: Date.current
    ).backfill

    assert_equal 1, results.size
    assert_equal 3, results.first.imported_count
    assert_not results.first.failed?
    assert_equal 3, ExchangeRate.where(from_currency: "USD", to_currency: "UAH").count
  end

  test "reports a skipped result when no provider covers the pair" do
    stub_providers_with({})

    results = ExchangeRate::Backfiller.new(
      pairs: [ [ "USD", "XYZ" ] ],
      start_date: 1.day.ago.to_date,
      end_date: Date.current
    ).backfill

    assert results.first.skipped?
    assert_equal 0, results.first.imported_count
  end

  test "captures provider failures instead of aborting the whole run" do
    failing_provider = FakeProvider.new([ "USD", "EUR" ] => [])
    failing_provider.stubs(:fetch_exchange_rates).raises(StandardError.new("boom"))
    ExchangeRate::Backfiller.stubs(:providers).returns([ failing_provider ])

    results = ExchangeRate::Backfiller.new(
      pairs: [ [ "USD", "EUR" ] ],
      start_date: 1.day.ago.to_date,
      end_date: Date.current
    ).backfill

    assert results.first.failed?
    assert_equal "boom", results.first.error.message
  end

  test "include_reverse adds the inverse pair" do
    ExchangeRate.delete_all

    stub_providers_with(
      [ "USD", "UAH" ] => [ OpenStruct.new(from: "USD", to: "UAH", date: Date.current, rate: 41.3) ],
      [ "UAH", "USD" ] => [ OpenStruct.new(from: "UAH", to: "USD", date: Date.current, rate: 0.024) ]
    )

    results = ExchangeRate::Backfiller.new(
      pairs: [ [ "USD", "UAH" ] ],
      start_date: Date.current,
      end_date: Date.current,
      include_reverse: true
    ).backfill

    assert_equal [ [ "USD", "UAH" ], [ "UAH", "USD" ] ], results.map { |r| [ r.from, r.to ] }
    assert ExchangeRate.exists?(from_currency: "UAH", to_currency: "USD")
  end

  test "required_pairs derives pairs from accounts denominated outside the family currency" do
    family = families(:dylan_family)
    family.accounts.first.update!(currency: "UAH")

    assert_includes ExchangeRate::Backfiller.required_pairs, [ "UAH", family.currency ]
  end

  private
    def stub_providers_with(rates_by_pair)
      ExchangeRate::Backfiller.stubs(:providers).returns([ FakeProvider.new(rates_by_pair) ])
    end
end
