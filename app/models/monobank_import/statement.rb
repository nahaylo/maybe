# Turns raw Monobank statement rows into something the entry builder can use.
#
# Money arrives in minor units as integers, and the sign convention is the
# opposite of Maybe's, so every row goes through Row rather than being read
# field by field at the call site.
class MonobankImport::Statement
  # Monobank timestamps are unix seconds; the calendar date they belong to is
  # the bank's, not the server's.
  ZONE = "Europe/Kyiv".freeze

  # A statement request covers at most 31 days, so a longer backfill is split
  # into windows. Each is cached under its own key, so an interrupted backfill
  # resumes without re-fetching what it already has -- which matters when every
  # request costs a minute.
  CHUNK = 30.days

  Row = Data.define(
    :external_id, :time, :description, :mcc, :original_mcc, :hold,
    :amount_minor, :operation_amount_minor, :currency_code,
    :commission_minor, :cashback_minor, :balance_minor,
    :comment, :counter_name, :counter_iban, :counter_edrpou
  ) do
    def date
      time.in_time_zone(MonobankImport::Statement::ZONE).to_date
    end

    # Monobank is negative-for-spend; Maybe is positive-for-outflow.
    def amount
      -minor_to_decimal(amount_minor)
    end

    def operation_amount
      -minor_to_decimal(operation_amount_minor)
    end

    def balance
      minor_to_decimal(balance_minor)
    end

    def commission = minor_to_decimal(commission_minor)
    def cashback = minor_to_decimal(cashback_minor)

    # The alpha code for `currency_code`, or nil for a code this app has no
    # currency definition for.
    def currency
      MonobankImport::Statement.alpha_code(currency_code)
    end

    # True when the operation was settled in a different currency than the
    # amount posted to the account -- the reliable marker of a foreign
    # purchase, and independent of how currency_code is interpreted.
    def foreign?
      operation_amount_minor.present? && operation_amount_minor != amount_minor
    end

    def hold? = hold

    # A utility bill. Which property it belongs to is not knowable from the
    # payload -- see MonobankImport::EntryBuilder::UTILITY_MCC.
    def utility? = mcc == MonobankImport::EntryBuilder::UTILITY_MCC

    # The most specific label available. counter_name carries the real payer or
    # payee on the business accounts, where description is generic.
    def name
      [ description.presence, counter_name.presence ].compact.uniq.first ||
        "Monobank #{external_id}"
    end

    private
      def minor_to_decimal(minor)
        return 0.to_d if minor.blank?

        minor.to_d / 100
      end
  end

  class << self
    # ISO 4217 numeric -> alpha, built from config/currencies.yml rather than a
    # second hardcoded table.
    def alpha_code(numeric)
      return nil if numeric.blank?

      numeric_index[numeric.to_i]
    end

    # Public so `rake monobank:seed` can place a fixture at exactly the key a
    # real fetch would have written.
    def cache_key(account_id, from, to)
      # Account ids are base64url ("-" and "_" are filename safe), but guard
      # rather than trust the API's alphabet.
      safe_id = account_id.gsub(/[^A-Za-z0-9_-]/, "")
      "statement-#{safe_id}-#{from.to_i}-#{to.to_i}"
    end

    # client-info carries no account id, so unlike a statement key it would
    # collide across connections. Scoping it by the item keeps one token's
    # account list from overwriting another's.
    def client_info_key(scope = nil)
      return "client-info" if scope.blank?

      "client-info-#{scope.to_s.gsub(/[^A-Za-z0-9_-]/, '')}"
    end

    def parse(payload)
      Array(payload).map { |raw| row_from(raw) }.sort_by(&:time)
    end

    def row_from(raw)
      Row.new(
        external_id: raw["id"],
        time: Time.zone.at(raw.fetch("time").to_i),
        description: raw["description"].to_s.strip,
        mcc: raw["mcc"]&.to_i,
        original_mcc: raw["originalMcc"]&.to_i,
        hold: raw.fetch("hold", false),
        amount_minor: raw["amount"]&.to_i,
        operation_amount_minor: raw["operationAmount"]&.to_i,
        currency_code: raw["currencyCode"]&.to_i,
        commission_minor: raw["commissionRate"]&.to_i,
        cashback_minor: raw["cashbackAmount"]&.to_i,
        balance_minor: raw["balance"]&.to_i,
        comment: raw["comment"].presence,
        counter_name: raw["counterName"].presence,
        counter_iban: raw["counterIban"].presence,
        counter_edrpou: raw["counterEdrpou"].presence
      )
    end

    private
      def numeric_index
        @numeric_index ||= Money::Currency.all.values.to_h do |currency|
          [ currency["iso_numeric"].to_i, currency["iso_code"] ]
        end
      end
  end

  attr_reader :provider, :cache, :scope

  # provider may be nil: a run served entirely from the cache needs no client,
  # and requiring a token to replay cached responses would make offline mode
  # impossible to test.
  #
  # @param scope [String, nil] namespaces the connection-wide cache keys --
  #   MonobankItem#cache_scope in production, nil in single-connection tests.
  def initialize(provider: nil, cache: MonobankImport::Cache.new, scope: nil)
    @provider = provider
    @cache = cache
    @scope = scope
  end

  # @return [Array<Row>] chronological, oldest first
  def rows(account_id:, from:, to:)
    windows(from, to).flat_map { |start, finish| self.class.parse(raw(account_id: account_id, from: start, to: finish)) }
                     .uniq(&:external_id)
                     .sort_by(&:time)
  end

  # @return [Array<[Time, Time]>] consecutive windows covering from..to
  def windows(from, to)
    result = []
    cursor = from

    while cursor < to
      finish = [ cursor + CHUNK, to ].min
      result << [ cursor, finish ]
      cursor = finish + 1.second
    end

    result.presence || [ [ from, to ] ]
  end

  def raw(account_id:, from:, to:)
    cache.fetch(self.class.cache_key(account_id, from, to)) do
      response = provider!.statement(account_id: account_id, from: from, to: to)
      raise response.error unless response.success?

      response.data
    end
  end

  def client_info
    cache.fetch(self.class.client_info_key(scope)) do
      response = provider!.client_info
      raise response.error unless response.success?

      response.data
    end
  end

  private
    def provider!
      provider || raise(MonobankImport::Error,
                        "no Monobank connection to call, and nothing is cached for this request")
    end
end
