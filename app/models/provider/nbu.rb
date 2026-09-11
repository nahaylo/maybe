class Provider::Nbu < Provider
  include ExchangeRateConcept

  # Subclass so errors caught in this provider are raised as Provider::Nbu::Error
  Error = Class.new(Provider::Error)
  InvalidExchangeRateError = Class.new(Error)

  BASE_CURRENCY = "UAH".freeze
  RECIPROCAL_PRECISION = 12

  # The National Bank of Ukraine publishes rates for UAH against other
  # currencies only, so exactly one side of the pair must be UAH.
  def supports?(from:, to:)
    [ from.to_s.upcase, to.to_s.upcase ].count(BASE_CURRENCY) == 1
  end

  def fetch_exchange_rate(from:, to:, date:)
    with_provider_response do
      rate = fetch_rate_for_date(from:, to:, date: date.to_date)

      raise InvalidExchangeRateError, "#{self.class.name} returned no rate for #{from} to #{to} on #{date}" if rate.nil?

      rate
    end
  end

  # NBU exposes one publication date per request, so a range is walked day by
  # day. Non-publication days (weekends, holidays) return nothing and are
  # skipped -- the importer gapfills them with the last observed rate.
  def fetch_exchange_rates(from:, to:, start_date:, end_date:)
    with_provider_response do
      start_date.to_date.upto(end_date.to_date).filter_map do |date|
        fetch_rate_for_date(from:, to:, date:)
      end
    end
  end

  private
    def fetch_rate_for_date(from:, to:, date:)
      unless supports?(from:, to:)
        raise InvalidExchangeRateError, "#{self.class.name} only supports pairs involving #{BASE_CURRENCY}, got #{from} to #{to}"
      end

      # The non-UAH side of the pair is what NBU quotes against UAH.
      foreign_currency = from.to_s.upcase == BASE_CURRENCY ? to.to_s.upcase : from.to_s.upcase

      response = client.get("#{base_url}/statdirectory/exchange") do |req|
        req.params["valcode"] = foreign_currency
        req.params["date"] = date.strftime("%Y%m%d")
        req.params["json"] = ""
      end

      quote = JSON.parse(response.body).first
      return nil if quote.nil?

      # NBU quotes UAH per 1 unit of the foreign currency, so the UAH-based
      # direction is the reciprocal.
      quoted_rate = quote.fetch("rate").to_d
      return nil unless quoted_rate.positive?

      # `div` takes significant digits, which keeps small reciprocals (e.g.
      # UAH -> EUR ~= 0.0195) precise without storing 30+ meaningless digits.
      rate = from.to_s.upcase == BASE_CURRENCY ? 1.to_d.div(quoted_rate, RECIPROCAL_PRECISION) : quoted_rate

      Rate.new(date: Date.strptime(quote.fetch("exchangedate"), "%d.%m.%Y"), from:, to:, rate:)
    end

    def base_url
      ENV["NBU_URL"] || "https://bank.gov.ua/NBUStatService/v1"
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
