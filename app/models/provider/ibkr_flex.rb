# Client for the Interactive Brokers Flex Web Service, version 3.
#
# A Flex Query is a report template you define once in Client Portal; this
# class only runs it. That takes two round trips: SendRequest asks IBKR to
# generate the report and answers with a reference code, GetStatement collects
# the finished XML under that code. Generation is asynchronous, so the second
# call can answer "in progress" and is repeated until the report is ready.
#
# Deliberately thin: it returns the statement XML exactly as IBKR sent it.
# Mapping onto Maybe's models happens in IbkrImport::Statement, and the raw
# text is what IbkrImport::Cache writes to disk, so a later mapping change can
# be replayed against what was actually fetched.
class Provider::IbkrFlex < Provider
  Error = Class.new(Provider::Error)
  RequestError = Class.new(Error) # IBKR answered with Status=Fail
  TimeoutError = Class.new(Error) # the report was still generating after every retry

  BASE_URL = "https://ndcdyn.interactivebrokers.com/AccountManagement/FlexWebService".freeze
  VERSION = 3

  # "Statement generation in progress" and "server under load": ask again.
  # Every other code is final for this request.
  IN_PROGRESS_CODES = %w[1009 1019].freeze
  MAX_ATTEMPTS = 12
  RETRY_INTERVAL = 5

  # What IBKR's status envelope says. `nil` for a body that is not one -- i.e.
  # the statement itself.
  Status = Data.define(:status, :code, :message, :reference_code, :url) do
    def success? = status == "Success"
    def in_progress? = Provider::IbkrFlex::IN_PROGRESS_CODES.include?(code.to_s)
  end

  attr_reader :token

  # @param sleeper [#call] how to wait between polls; tests pass a no-op
  def initialize(token, sleeper: ->(seconds) { sleep(seconds) })
    @token = token
    @sleeper = sleeper
  end

  # @param query_id [String, Integer] the Flex Query id shown in Client Portal
  # @return [Provider::Response] data is the statement XML as a String
  def statement(query_id:)
    with_provider_response do
      status = request_statement(query_id)
      fetch_statement(status.reference_code, status.url.presence || "#{base_url}/GetStatement")
    end
  end

  private
    attr_reader :sleeper

    def request_statement(query_id)
      body = get("#{base_url}/SendRequest", t: token, q: query_id, v: VERSION)
      status = parse_status(body)

      if status.nil?
        raise Error, "IBKR Flex returned an unexpected response to SendRequest"
      end

      raise RequestError, describe(status) unless status.success?
      raise Error, "IBKR Flex accepted the request but returned no reference code" if status.reference_code.blank?

      status
    end

    def fetch_statement(reference_code, url)
      MAX_ATTEMPTS.times do |attempt|
        body = get_with_host_fallback(url, t: token, q: reference_code, v: VERSION)
        status = parse_status(body)

        # Anything that is not a status envelope is the report.
        return body if status.nil?

        raise RequestError, describe(status) unless status.in_progress?

        Rails.logger.info("Provider::IbkrFlex statement not ready (attempt #{attempt + 1}/#{MAX_ATTEMPTS}): #{status.message}")
        sleeper.call(RETRY_INTERVAL)
      end

      raise TimeoutError,
            "IBKR had not finished generating the statement after #{MAX_ATTEMPTS} attempts -- try again in a minute"
    end

    def get(url, params)
      client.get(url, params).body
    end

    # SendRequest names the GetStatement host itself, and it is not always the
    # one SendRequest was sent to (gdcdyn vs ndcdyn). They are aliases of one
    # service, and the returned one has been seen not to resolve from behind
    # some DNS resolvers. When it cannot be reached, retry the same path on the
    # host that just answered SendRequest.
    def get_with_host_fallback(url, params)
      get(url, params)
    rescue Faraday::ConnectionFailed => e
      fallback = on_base_host(url)
      raise if fallback.nil? || fallback == url

      Rails.logger.warn("Provider::IbkrFlex could not reach #{URI(url).host} (#{e.message}); retrying via #{URI(fallback).host}")
      get(fallback, params)
    end

    def on_base_host(url)
      target = URI(url)
      base = URI(base_url)
      target.scheme = base.scheme
      target.host = base.host
      target.port = base.port
      target.to_s
    rescue URI::Error
      nil
    end

    def parse_status(body)
      doc = Nokogiri::XML(body)
      root = doc.root
      return nil if root.nil? || root.name != "FlexStatementResponse"

      Status.new(
        status: root.at_xpath("Status")&.text&.strip,
        code: root.at_xpath("ErrorCode")&.text&.strip,
        message: root.at_xpath("ErrorMessage")&.text&.strip,
        reference_code: root.at_xpath("ReferenceCode")&.text&.strip,
        url: root.at_xpath("Url")&.text&.strip
      )
    end

    def describe(status)
      code = status.code.presence
      message = status.message.presence || "no error message"
      code ? "IBKR Flex error #{code}: #{message}" : "IBKR Flex error: #{message}"
    end

    def base_url
      ENV["IBKR_FLEX_URL"] || BASE_URL
    end

    def client
      @client ||= Faraday.new do |faraday|
        # IBKR rejects requests with no User-Agent.
        faraday.headers["User-Agent"] = "Maybe/IbkrFlex"
        faraday.response :raise_error
      end
    end

    # Our own errors must keep their class -- the task tells RequestError
    # (fix the token or query) apart from TimeoutError (just retry).
    def default_error_transformer(error)
      case error
      when Error
        error
      when Faraday::Error
        Error.new(error.message, details: error.response&.dig(:body))
      else
        super
      end
    end
end
