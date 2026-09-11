class Provider::Frankfurter < Provider
  include ExchangeRateConcept

  # Subclass so errors caught in this provider are raised as Provider::Frankfurter::Error
  Error = Class.new(Provider::Error)
  InvalidExchangeRateError = Class.new(Error)

  # The ECB reference set, which changes at most once every few years. Held as
  # a constant because supports? sits on the hot path of every rate lookup --
  # asking the API each time would put an HTTP round trip in front of a cache
  # hit, and would make the provider unusable offline or under test.
  # Refresh with fetch_supported_currencies if the ECB ever revises the list.
  SUPPORTED_CURRENCIES = %w[
    AUD BRL CAD CHF CNY CZK DKK EUR GBP HKD
    HUF IDR ILS INR ISK JPY KRW MXN MYR NOK
    NZD PHP PLN RON SEK SGD THB TRY USD ZAR
  ].freeze

  def supports?(from:, to:)
    supported_currencies.include?(from.to_s.upcase) && supported_currencies.include?(to.to_s.upcase)
  end

  def supported_currencies
    SUPPORTED_CURRENCIES
  end

  # Live list, for verifying SUPPORTED_CURRENCIES is still current.
  def fetch_supported_currencies
    JSON.parse(client.get("#{base_url}/currencies").body).keys
  end

  def fetch_exchange_rate(from:, to:, date:)
    with_provider_response do
      response = client.get("#{base_url}/#{date.to_date.iso8601}") do |req|
        req.params["base"] = from
        req.params["symbols"] = to
      end

      parsed = JSON.parse(response.body)
      rate = parsed.dig("rates", to)

      raise InvalidExchangeRateError, "#{self.class.name} returned no rate for #{from} to #{to} on #{date}" if rate.nil?

      # Frankfurter resolves weekends/holidays back to the previous publication
      # date, so we report the date it actually returned rather than the request.
      Rate.new(date: parsed.dig("date").to_date, from:, to:, rate:)
    end
  end

  def fetch_exchange_rates(from:, to:, start_date:, end_date:)
    with_provider_response do
      range = "#{start_date.to_date.iso8601}..#{end_date.to_date.iso8601}"

      response = client.get("#{base_url}/#{range}") do |req|
        req.params["base"] = from
        req.params["symbols"] = to
      end

      rates = JSON.parse(response.body).dig("rates") || {}

      rates.filter_map do |date, values|
        rate = values&.dig(to)

        if rate.nil?
          Rails.logger.warn("#{self.class.name} returned invalid rate data for pair from: #{from} to: #{to} on: #{date}")
          next
        end

        Rate.new(date: date.to_date, from:, to:, rate:)
      end.sort_by(&:date)
    end
  end

  private
    def base_url
      ENV["FRANKFURTER_URL"] || "https://api.frankfurter.dev/v1"
    end

    def client
      @client ||= Faraday.new(url: base_url) do |faraday|
        faraday.request(:retry, {
          max: 2,
          interval: 0.05,
          interval_randomness: 0.5,
          backoff_factor: 2
        })

        faraday.response :raise_error
      end
    end
end
