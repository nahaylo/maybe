# Client for the Monobank personal API (https://api.monobank.ua/docs/).
#
# Deliberately thin: it authenticates, enforces the documented range limit, and
# returns parsed JSON exactly as the API sent it. Mapping onto Maybe's models
# happens in MonobankImport::Statement, and the raw shape is what
# MonobankImport::Cache writes to disk -- normalising here would mean caching a
# derived form that a later mapping change could not be replayed against.
#
# ONE REQUEST PER 60 SECONDS per token, across every endpoint. There is no
# sandbox and no test token; tests drive this class with stubbed responses.
class Provider::Monobank < Provider
  Error = Class.new(Provider::Error)
  RateLimitedError = Class.new(Error)
  InvalidRangeError = Class.new(Error)

  # The API rejects a wider window outright ("31 днiв + 1 година").
  MAX_RANGE = (31 * 86_400 + 3_600).seconds

  # One request per 60 seconds per token, across every endpoint. Importing more
  # than one account in a run means more than one request, so the second would
  # 429 and take the whole run down with it. Pace them instead.
  MIN_REQUEST_INTERVAL = 60.seconds

  attr_reader :token

  def initialize(token)
    @token = token
  end

  # @return [Provider::Response] data is the raw client-info hash: personal
  #   details, `accounts`, and `jars`.
  def client_info
    with_provider_response { get("/personal/client-info") }
  end

  # @param from [Time] inclusive start
  # @param to [Time] inclusive end
  # @return [Provider::Response] data is an array of raw statement rows,
  #   newest first, capped by the API at 500 per response.
  def statement(account_id:, from:, to:)
    with_provider_response do
      span = to.to_i - from.to_i

      raise InvalidRangeError, "#{from} is after #{to}" if span.negative?

      if span > MAX_RANGE.to_i
        raise InvalidRangeError,
              "Monobank allows at most 31 days per statement request, asked for #{(span / 86_400.0).round(1)}"
      end

      get("/personal/statement/#{account_id}/#{from.to_i}/#{to.to_i}")
    end
  end

  # Seconds still to wait before another request is allowed, 0 when free.
  def cooldown
    return 0 if @last_request_at.nil?

    [ MIN_REQUEST_INTERVAL - (monotonic_now - @last_request_at), 0 ].max
  end

  private
    def get(path)
      throttle
      @last_request_at = monotonic_now
      JSON.parse(client.get(path).body)
    end

    # Waits out the token's rate limit rather than letting the next request 429.
    # Only real requests get here -- MonobankImport::Cache serves hits without
    # touching the provider, so a cached run never sleeps.
    def throttle
      remaining = cooldown
      return if remaining.zero?

      Rails.logger.info("Provider::Monobank waiting #{remaining.round}s for the rate limit")
      sleep(remaining)
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def base_url
      ENV["MONOBANK_URL"] || "https://api.monobank.ua"
    end

    def client
      @client ||= Faraday.new(url: base_url) do |faraday|
        faraday.headers["X-Token"] = token
        faraday.response :raise_error
      end
    end

    # No automatic retry on 429. The rate limit is a full minute, so retrying
    # would silently block a rake task; the caller is told to wait instead.
    def default_error_transformer(error)
      case error
      when Error
        error # already ours -- InvalidRangeError must not be flattened to Error
      when Faraday::TooManyRequestsError
        RateLimitedError.new(
          "Monobank allows one request per 60 seconds -- wait a minute and try again " \
          "(cached responses are reused, so a repeat run may need no request at all)",
          details: error.response&.dig(:body)
        )
      when Faraday::Error
        Error.new(monobank_message(error) || error.message, details: error.response&.dig(:body))
      else
        super
      end
    end

    # Monobank puts the useful part in an errorDescription field.
    def monobank_message(error)
      body = error.response&.dig(:body)
      return nil if body.blank?

      JSON.parse(body)["errorDescription"].presence
    rescue JSON::ParserError
      nil
    end
end
