require "test_helper"

# Stubs with WebMock rather than VCR, unlike the other provider tests. Their
# cassettes were recorded against live APIs; Monobank has no sandbox and no test
# token, so there is nothing to record. WebMock also lets the token header and
# the 429 path be asserted directly.
class Provider::MonobankTest < ActiveSupport::TestCase
  include WebMock::API

  setup do
    @provider = Provider::Monobank.new("test-token")
    @from = Time.utc(2026, 8, 1)
    @to = Time.utc(2026, 8, 21)
  end

  # `include WebMock::API` brings the stubbing DSL but not the per-test reset
  # the minitest adapter would install, so stubs and the request log leak.
  teardown { WebMock.reset! }

  test "sends the token as X-Token" do
    stub = stub_request(:get, %r{/personal/client-info})
             .with(headers: { "X-Token" => "test-token" })
             .to_return(body: { "name" => "Test" }.to_json)

    assert_predicate @provider.client_info, :success?
    assert_requested stub
  end

  test "requests the statement as unix seconds" do
    stub = stub_request(:get, "https://api.monobank.ua/personal/statement/acc/#{@from.to_i}/#{@to.to_i}")
             .to_return(body: [].to_json)

    assert_predicate @provider.statement(account_id: "acc", from: @from, to: @to), :success?
    assert_requested stub
  end

  test "refuses a range wider than the API allows before spending the request" do
    response = @provider.statement(account_id: "acc", from: @from, to: @from + 40.days)

    assert_not_predicate response, :success?
    assert_kind_of Provider::Monobank::InvalidRangeError, response.error
    assert_not_requested :get, %r{api.monobank.ua}
  end

  test "a 429 is reported as a rate limit, not a generic failure" do
    stub_request(:get, %r{/personal/client-info}).to_return(status: 429, body: "")

    response = @provider.client_info

    assert_not_predicate response, :success?
    assert_kind_of Provider::Monobank::RateLimitedError, response.error
    assert_match(/60 seconds/, response.error.message)
  end

  test "surfaces the API's own error description" do
    stub_request(:get, %r{/personal/client-info})
      .to_return(status: 403, body: { "errorDescription" => "Unknown 'X-Token'" }.to_json)

    response = @provider.client_info

    assert_not_predicate response, :success?
    assert_equal "Unknown 'X-Token'", response.error.message
  end
end
