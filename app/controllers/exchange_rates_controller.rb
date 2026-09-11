class ExchangeRatesController < ApplicationController
  # Fetching a single date is unreliable: providers skip weekends and holidays,
  # so pull a short window and let the importer gapfill it.
  IMPORT_WINDOW_DAYS = 7

  # Advisory endpoint for the transfer form: given a currency pair, a date and a
  # source amount, returns the rate and the converted amount. The conversion is
  # done here rather than in JavaScript so the prefilled value uses the same
  # BigDecimal arithmetic and currency precision the server applies on create.
  def show
    return head :unprocessable_entity unless currencies_permitted?

    render json: rate_payload
  rescue ArgumentError
    # Covers both Money::Currency::UnknownCurrencyError and Date::Error
    head :unprocessable_entity
  end

  # Imports the pair on demand, for when the form has no rate to show. Uses the
  # same free providers as the backfill rake task.
  def create
    return head :unprocessable_entity unless currencies_permitted?

    ExchangeRate::Backfiller.new(
      pairs: [ [ from_currency.iso_code, to_currency.iso_code ] ],
      start_date: rate_date - IMPORT_WINDOW_DAYS,
      end_date: rate_date
    ).backfill

    render json: rate_payload
  rescue ArgumentError
    head :unprocessable_entity
  end

  private
    def rate_payload
      if from_currency.iso_code == to_currency.iso_code
        rate, published_on = 1.to_d, rate_date
      else
        record = ExchangeRate.find_rate_on_or_before(
          from: from_currency.iso_code, to: to_currency.iso_code, date: rate_date
        )
        rate, published_on = record&.rate, record&.date
      end

      {
        from: from_currency.iso_code,
        to: to_currency.iso_code,
        date: rate_date.to_s,
        # A missing rate is a successful "unknown", not an error -- the form shows
        # a warning inline and offers to fetch the pair.
        # Rounded for display only; converted_amount above uses the full value.
        rate: rate && display_rate(rate),
        # The date the rate was actually published. When it predates the requested
        # date the rate was carried forward, and the form says so.
        rate_date: published_on&.to_s,
        stale: published_on.present? && published_on != rate_date,
        converted_amount: rate && (source_amount * rate).round(to_currency.default_precision).to_s,
        to_currency: {
          iso_code: to_currency.iso_code,
          symbol: to_currency.symbol,
          default_precision: to_currency.default_precision
        }
      }
    end

    # Rates span several orders of magnitude (44.7064 UAH/USD vs 0.0195 EUR/UAH),
    # so round by magnitude rather than to a fixed number of decimals.
    def display_rate(rate)
      rate.round(rate.abs >= 1 ? 6 : 10).to_s("F")
    end

    def from_currency
      @from_currency ||= Money::Currency.new(params[:from])
    end

    def to_currency
      @to_currency ||= Money::Currency.new(params[:to])
    end

    def source_amount
      params[:amount].to_d
    end

    def rate_date
      @rate_date ||= begin
        date = params[:date].present? ? Date.parse(params[:date]) : Date.current
        [ date, Date.current ].min
      end
    end

    # `find_or_fetch_rate` and the backfiller can both call out to a provider, and
    # this route is not covered by Rack::Attack, so only serve pairs the family uses.
    def currencies_permitted?
      [ from_currency, to_currency ].all? { |currency| family_currencies.include?(currency.iso_code) }
    end

    def family_currencies
      @family_currencies ||= (
        Current.family.accounts.distinct.pluck(:currency) + [ Current.family.currency ]
      ).compact.uniq
    end
end
