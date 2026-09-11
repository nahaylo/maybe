# Backfills historical exchange rates from free, keyless providers.
#
# Each provider implements Provider::ExchangeRateConcept and declares which
# pairs it can serve, so pairs are routed to the first provider that supports
# them. Fetched rates are handed to ExchangeRate::Importer, which gapfills
# non-publication days and upserts them.
class ExchangeRate::Backfiller
  DEFAULT_BACKFILL_DAYS = 730

  Result = Data.define(:from, :to, :provider_name, :imported_count, :error) do
    def skipped?
      provider_name.nil? && error.nil?
    end

    def failed?
      error.present?
    end
  end

  class << self
    # Ordered by preference: Frankfurter resolves a whole range in one request,
    # NBU covers the UAH pairs the ECB feed omits.
    def providers
      [ Provider::Frankfurter.new, Provider::Nbu.new ]
    end

    def provider_for(from:, to:)
      providers.find { |provider| provider.supports?(from:, to:) }
    end

    # Currency pairs the app actually needs: anything denominated differently
    # from the currency it rolls up into.
    def required_pairs
      pairs = Set.new

      Account.joins(:family)
             .where.not("families.currency = accounts.currency")
             .distinct
             .pluck("accounts.currency", "families.currency")
             .each { |pair| pairs << pair }

      Entry.joins(:account)
           .where.not("entries.currency = accounts.currency")
           .distinct
           .pluck("entries.currency", "accounts.currency")
           .each { |pair| pairs << pair }

      pairs.to_a
    end
  end

  def initialize(pairs: nil, start_date: nil, end_date: nil, clear_cache: false, include_reverse: false)
    @pairs = pairs.presence || self.class.required_pairs
    @pairs |= @pairs.map(&:reverse) if include_reverse
    @start_date = start_date || DEFAULT_BACKFILL_DAYS.days.ago.to_date
    @end_date = end_date || Date.current
    @clear_cache = clear_cache
  end

  # @return [Array<Result>] one result per pair
  def backfill
    pairs.map { |from, to| backfill_pair(from, to) }
  end

  private
    attr_reader :pairs, :start_date, :end_date, :clear_cache

    def backfill_pair(from, to)
      provider = self.class.provider_for(from:, to:)

      return Result.new(from:, to:, provider_name: nil, imported_count: 0, error: nil) if provider.nil?

      before = rate_count(from, to)

      ExchangeRate::Importer.new(
        exchange_rate_provider: provider,
        from: from,
        to: to,
        start_date: start_date,
        end_date: end_date,
        clear_cache: clear_cache
      ).import_provider_rates

      Result.new(
        from:,
        to:,
        provider_name: provider.class.name.demodulize,
        imported_count: rate_count(from, to) - before,
        error: nil
      )
    rescue StandardError => e
      Result.new(from:, to:, provider_name: provider&.class&.name&.demodulize, imported_count: 0, error: e)
    end

    def rate_count(from, to)
      ExchangeRate.where(from_currency: from, to_currency: to, date: start_date..end_date).count
    end
end
