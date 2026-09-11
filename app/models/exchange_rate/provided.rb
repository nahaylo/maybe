module ExchangeRate::Provided
  extend ActiveSupport::Concern

  class_methods do
    # Any configured exchange-rate provider, used for "is this app able to
    # fetch rates at all?" checks. Prefer provider_for when the pair is known.
    def provider
      providers.first
    end

    def providers
      @providers = nil unless Rails.env.production?
      @providers ||= Provider::Registry.for_concept(:exchange_rates).providers.compact
    end

    # No single provider covers every pair: Frankfurter serves ECB rates and has
    # no UAH, NBU serves UAH pairs only. Pick whichever supports this one.
    def provider_for(from:, to:)
      providers.find do |candidate|
        # Synth predates the concept and answers for every pair.
        candidate.respond_to?(:supports?) ? candidate.supports?(from: from, to: to) : true
      end
    end

    def find_or_fetch_rate(from:, to:, date: Date.current, cache: true)
      rate = find_by(from_currency: from, to_currency: to, date: date)
      return rate if rate.present?

      selected = provider_for(from: from, to: to)
      return nil if selected.nil? # No provider covers this pair

      response = selected.fetch_exchange_rate(from: from, to: to, date: date)

      return nil unless response.success? # Provider error

      rate = response.data
      ExchangeRate.find_or_create_by!(
        from_currency: rate.from,
        to_currency: rate.to,
        date: rate.date,
        rate: rate.rate
      ) if cache
      rate
    end

    # Falls back to the most recent rate on or before the given date.
    #
    # Providers publish on business days only, and a backfill may not reach
    # today yet, so an exact-date miss is normal rather than exceptional. The
    # carried-forward rate is a far better estimate than refusing outright.
    def find_rate_on_or_before(from:, to:, date: Date.current)
      find_or_fetch_rate(from: from, to: to, date: date) ||
        where(from_currency: from, to_currency: to)
          .where(date: ..date)
          .order(date: :desc)
          .first
    end

    # @return [Integer] The number of exchange rates synced
    def import_provider_rates(from:, to:, start_date:, end_date:, clear_cache: false)
      selected = provider_for(from: from, to: to)

      if selected.nil?
        Rails.logger.warn("No provider supports #{from} to #{to} for ExchangeRate.import_provider_rates")
        return 0
      end

      ExchangeRate::Importer.new(
        exchange_rate_provider: selected,
        from: from,
        to: to,
        start_date: start_date,
        end_date: end_date,
        clear_cache: clear_cache
      ).import_provider_rates
    end
  end
end
