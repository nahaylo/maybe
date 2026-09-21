require "test_helper"

# Stubs with WebMock rather than VCR: a Flex token is personal and the report
# it returns is a real brokerage statement, so there is nothing to record.
class Provider::IbkrFlexTest < ActiveSupport::TestCase
  include WebMock::API

  BASE = Provider::IbkrFlex::BASE_URL
  STATEMENT = %(<?xml version="1.0"?><FlexQueryResponse queryName="q" type="AF"><FlexStatements count="0"/></FlexQueryResponse>).freeze

  setup do
    @waits = []
    @provider = Provider::IbkrFlex.new("tok", sleeper: ->(seconds) { @waits << seconds })
  end

  # `include WebMock::API` brings the stubbing DSL but not the per-test reset
  # the minitest adapter would install, so stubs and the request log leak.
  teardown { WebMock.reset! }

  test "asks for the report, then collects it under the reference code" do
    send_request = stub_request(:get, "#{BASE}/SendRequest")
                     .with(query: { "t" => "tok", "q" => "123456", "v" => "3" })
                     .to_return(body: envelope(status: "Success", reference: "987", url: "#{BASE}/GetStatement"))
    get_statement = stub_request(:get, "#{BASE}/GetStatement")
                      .with(query: { "t" => "tok", "q" => "987", "v" => "3" })
                      .to_return(body: STATEMENT)

    response = @provider.statement(query_id: "123456")

    assert_predicate response, :success?
    assert_equal STATEMENT, response.data
    assert_requested send_request
    assert_requested get_statement
    assert_empty @waits
  end

  test "waits and asks again while the statement is still generating" do
    stub_request(:get, "#{BASE}/SendRequest").with(query: hash_including("q" => "1"))
      .to_return(body: envelope(status: "Success", reference: "5", url: "#{BASE}/GetStatement"))
    stub_request(:get, "#{BASE}/GetStatement").with(query: hash_including("q" => "5"))
      .to_return(
        { body: envelope(status: "Warn", code: "1019", message: "Statement generation in progress. Please try again shortly.") },
        { body: STATEMENT }
      )

    response = @provider.statement(query_id: "1")

    assert_predicate response, :success?
    assert_equal [ Provider::IbkrFlex::RETRY_INTERVAL ], @waits
  end

  test "gives up after the retry budget rather than polling forever" do
    stub_request(:get, "#{BASE}/SendRequest").with(query: hash_including("q" => "1"))
      .to_return(body: envelope(status: "Success", reference: "5", url: "#{BASE}/GetStatement"))
    stub_request(:get, "#{BASE}/GetStatement").with(query: hash_including("q" => "5"))
      .to_return(body: envelope(status: "Warn", code: "1019", message: "in progress"))

    response = @provider.statement(query_id: "1")

    assert_not_predicate response, :success?
    assert_kind_of Provider::IbkrFlex::TimeoutError, response.error
    assert_equal Provider::IbkrFlex::MAX_ATTEMPTS, @waits.size
  end

  test "a rejected request surfaces IBKR's code and message and never polls" do
    stub_request(:get, "#{BASE}/SendRequest").with(query: hash_including("q" => "1"))
      .to_return(body: envelope(status: "Fail", code: "1012", message: "Token has expired."))

    response = @provider.statement(query_id: "1")

    assert_not_predicate response, :success?
    assert_kind_of Provider::IbkrFlex::RequestError, response.error
    assert_equal "IBKR Flex error 1012: Token has expired.", response.error.message
    assert_not_requested :get, %r{/GetStatement}
  end

  test "a final error while collecting is not retried" do
    stub_request(:get, "#{BASE}/SendRequest").with(query: hash_including("q" => "1"))
      .to_return(body: envelope(status: "Success", reference: "5", url: "#{BASE}/GetStatement"))
    stub_request(:get, "#{BASE}/GetStatement").with(query: hash_including("q" => "5"))
      .to_return(body: envelope(status: "Fail", code: "1020", message: "Invalid request or unable to validate request."))

    response = @provider.statement(query_id: "1")

    assert_kind_of Provider::IbkrFlex::RequestError, response.error
    assert_empty @waits
  end

  test "an HTTP failure is reported as a provider error with the body attached" do
    stub_request(:get, "#{BASE}/SendRequest").with(query: hash_including("q" => "1"))
      .to_return(status: 503, body: "down")

    response = @provider.statement(query_id: "1")

    assert_not_predicate response, :success?
    assert_kind_of Provider::IbkrFlex::Error, response.error
    assert_equal "down", response.error.details
  end

  private
    def envelope(status:, code: nil, message: nil, reference: nil, url: nil)
      parts = [ "<Status>#{status}</Status>" ]
      parts << "<ErrorCode>#{code}</ErrorCode>" if code
      parts << "<ErrorMessage>#{message}</ErrorMessage>" if message
      parts << "<ReferenceCode>#{reference}</ReferenceCode>" if reference
      parts << "<Url>#{url}</Url>" if url

      %(<FlexStatementResponse timestamp='20 September, 2026 03:15 AM EDT'>#{parts.join}</FlexStatementResponse>)
    end
end
