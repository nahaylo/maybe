# Turns a Flex Query XML statement into rows the entry builder can use.
#
# A Flex report is one <FlexQueryResponse> holding one <FlexStatement> per
# IBKR account the query covers. Within each, the sections this importer
# reads are Trades, Cash Transactions and Open Positions -- anything else the
# query happens to include is ignored.
#
# Money keeps IBKR's sign convention until the last moment: IBKR is
# positive-for-money-in, Maybe is positive-for-outflow, and every row flips it
# in exactly one method so the rule is not repeated at call sites.
class IbkrImport::Statement
  # Asset categories that map onto Maybe's Security + Trade model. Currency
  # conversions ("CASH") become transfers between the per-currency accounts;
  # options, futures and bonds have no home here and are reported as skipped
  # rather than silently dropped.
  SUPPORTED_ASSET_CATEGORIES = %w[STK FUND].freeze
  FX_ASSET_CATEGORY = "CASH".freeze

  # The cash row types IBKR uses, for naming. Anything else keeps its type as
  # the name so it is at least recognisable.
  DEPOSIT_TYPE = "Deposits/Withdrawals".freeze

  # IBKR's `listingExchange` codes are its own; Maybe stores ISO 10383
  # operating MICs. Best effort for the common venues -- an unmapped exchange
  # leaves the MIC nil, which is how a manually entered ticker looks too.
  OPERATING_MICS = {
    "NYSE" => "XNYS", "ARCA" => "XNYS", "AMEX" => "XNYS",
    "NASDAQ" => "XNAS", "ISLAND" => "XNAS",
    "BATS" => "BATS", "IEX" => "IEXG", "PINK" => "OTCM",
    "LSE" => "XLON", "LSEETF" => "XLON",
    "IBIS" => "XETR", "IBIS2" => "XETR", "FWB" => "XFRA", "SWB" => "XSTU",
    "SBF" => "XPAR", "AEB" => "XAMS", "EBS" => "XSWX", "VSE" => "XWBO",
    "BM" => "BMEX", "BVME" => "XMIL",
    "TSE" => "XTSE", "VENTURE" => "XTSX",
    "ASX" => "XASX", "SEHK" => "XHKG", "TSEJ" => "XJPX", "SGX" => "XSES",
    "OSE" => "XOSL", "SFB" => "XSTO", "CPH" => "XCSE", "HEX" => "XHEL",
    "WSE" => "XWAR", "MEXI" => "XMEX"
  }.freeze

  Account = Data.define(:id, :currency, :name, :from, :to)

  TradeRow = Data.define(
    :external_id, :account_id, :asset_category, :symbol, :description, :listing_exchange,
    :isin, :currency, :date, :qty, :price, :proceeds, :commission, :commission_currency, :close_price
  ) do
    def buy? = qty.positive?
    def supported? = IbkrImport::Statement::SUPPORTED_ASSET_CATEGORIES.include?(asset_category)
    def fx? = asset_category == IbkrImport::Statement::FX_ASSET_CATEGORY
    def unsupported? = !supported? && !fx?

    # A conversion is a "trade" in a pair such as EUR.USD: the quantity is in
    # the base currency (EUR), the proceeds in the quote currency (USD, which
    # is also the row's `currency`). A negative quantity sold the base.
    def fx_base = symbol.split(".").first
    def fx_quote = symbol.split(".").last
    def fx_out_currency = qty.negative? ? fx_base : fx_quote
    def fx_in_currency = qty.negative? ? fx_quote : fx_base
    # IBKR reports proceeds to seven decimals; the ledger keeps cents.
    def fx_out_amount = qty.negative? ? qty.abs : proceeds.abs.round(2)
    def fx_in_amount = qty.negative? ? proceeds.abs.round(2) : qty.abs

    # Maybe's Trade convention: qty signed (+buy / -sell), amount = qty * price,
    # so a buy is a positive cash outflow. IBKR's quantity is already signed
    # the same way.
    def amount = qty * price

    # IBKR reports commission as a negative cash figure; Maybe wants outflows
    # positive. Zero when the row has none.
    def commission_amount = -(commission || 0.to_d)
    def commission? = !commission_amount.zero?

    def name
      if fx?
        "Convert #{fx_out_amount.to_s('F')} #{fx_out_currency} to #{fx_in_currency}"
      else
        ::Trade.build_name(buy? ? "buy" : "sell", qty.abs, symbol)
      end
    end
  end

  CashRow = Data.define(
    :external_id, :account_id, :type, :symbol, :description, :listing_exchange, :currency, :date, :ib_amount
  ) do
    # IBKR positive = money into the account; Maybe positive = outflow.
    def amount = -ib_amount
    def inflow? = amount.negative?
    def deposit_or_withdrawal? = type == IbkrImport::Statement::DEPOSIT_TYPE
  end

  PositionRow = Data.define(
    :account_id, :asset_category, :symbol, :description, :listing_exchange, :isin,
    :currency, :date, :qty, :mark_price
  ) do
    def supported? = IbkrImport::Statement::SUPPORTED_ASSET_CATEGORIES.include?(asset_category)
  end

  # A tax lot of an open position. Lots opened by a trade carry the order
  # that opened them; lots with no order were acquired some other way --
  # IBKR's stock bonuses land like this, credited straight into the position
  # with a cost basis but no trade, transfer or corporate action anywhere in
  # the report.
  LotRow = Data.define(
    :external_id, :account_id, :asset_category, :symbol, :description, :listing_exchange, :isin,
    :currency, :date, :qty, :price, :cost, :originating_order_id
  ) do
    def supported? = IbkrImport::Statement::SUPPORTED_ASSET_CATEGORIES.include?(asset_category)
    def outside_trade? = originating_order_id.blank?
    def name = "Shares received: #{qty.to_s('F')} #{symbol}"
  end

  Parsed = Data.define(:accounts, :trades, :cash, :positions, :lots) do
    # Every currency money is booked in -- each needs a Maybe account.
    def currencies
      trade_currencies = trades.flat_map do |t|
        t.fx? ? [ t.fx_out_currency, t.fx_in_currency, t.commission_currency ] : [ t.currency, t.commission_currency ]
      end

      (trade_currencies + cash.map(&:currency)).compact_blank.uniq.sort
    end

    # Everything belonging to one IBKR account, in the same shape.
    def for_account(ibkr_id)
      with(
        accounts: accounts.select { |a| a.id == ibkr_id },
        trades: trades.select { |t| t.account_id == ibkr_id },
        cash: cash.select { |c| c.account_id == ibkr_id },
        positions: positions.select { |p| p.account_id == ibkr_id },
        lots: lots.select { |l| l.account_id == ibkr_id }
      )
    end
  end

  class << self
    # Public so `rake ibkr:seed` can place a fixture at exactly the key a real
    # fetch would have written. Keyed by day: IBKR regenerates the report on
    # every request, and a same-day rerun should not ask twice.
    def cache_key(query_id, date)
      "flex-#{query_id.to_s.gsub(/[^A-Za-z0-9_-]/, '')}-#{date.strftime('%Y%m%d')}"
    end

    def operating_mic(listing_exchange)
      OPERATING_MICS[listing_exchange.to_s.upcase]
    end

    # @param xml [String] a FlexQueryResponse document
    # @return [Parsed]
    def parse(xml)
      doc = Nokogiri::XML(xml)
      root = doc.root

      unless root&.name == "FlexQueryResponse"
        raise IbkrImport::Error, "not a Flex statement (root element is #{root&.name.inspect})"
      end

      accounts = []
      trades = []
      cash = []
      positions = []
      lots = []

      root.xpath("FlexStatements/FlexStatement").each do |statement|
        account_id = statement["accountId"]
        info = statement.at_xpath("AccountInformation")

        accounts << Account.new(
          id: account_id,
          currency: info&.[]("currency").presence,
          name: info&.[]("name").presence,
          from: parse_date(statement["fromDate"]),
          to: parse_date(statement["toDate"])
        )

        # With "Orders" ticked in the query the section also carries <Order>
        # rows, and an EXECUTION/ORDER level flag on each. Only executions
        # are money that moved.
        statement.xpath("Trades/Trade").each do |node|
          next unless node["levelOfDetail"].blank? || node["levelOfDetail"] == "EXECUTION"

          trades << trade_row(node, account_id)
        end

        # SUMMARY rows repeat the DETAIL rows aggregated per symbol.
        statement.xpath("CashTransactions/CashTransaction").each do |node|
          next if node["levelOfDetail"] == "SUMMARY"

          cash << cash_row(node, account_id)
        end

        # LOT rows break a position into tax lots; SUMMARY is the position.
        statement.xpath("OpenPositions/OpenPosition").each do |node|
          if node["levelOfDetail"] == "LOT"
            lots << lot_row(node, account_id)
          else
            positions << position_row(node, account_id)
          end
        end
      end

      Parsed.new(
        accounts: accounts,
        trades: trades.sort_by { |t| [ t.date, t.external_id ] },
        cash: cash.sort_by { |c| [ c.date, c.external_id ] },
        positions: positions,
        lots: lots.sort_by { |l| [ l.date, l.external_id ] }
      )
    end

    # IBKR dates are "20260914"; timestamps are "20260914;153001", in the
    # account's own time zone. Only the day is kept.
    def parse_date(value)
      return nil if value.blank?

      Date.strptime(value.to_s.split(";").first, "%Y%m%d")
    end

    private
      def trade_row(node, account_id)
        TradeRow.new(
          external_id: "ibkr-trade-#{node['tradeID'].presence || node['transactionID']}",
          account_id: account_id,
          asset_category: node["assetCategory"].to_s.upcase,
          symbol: node["symbol"].to_s.strip.upcase,
          description: node["description"].to_s.strip,
          listing_exchange: node["listingExchange"].presence,
          isin: node["isin"].presence,
          currency: node["currency"].to_s.upcase,
          date: parse_date(node["tradeDate"].presence || node["dateTime"].presence || node["reportDate"]),
          qty: decimal(node["quantity"]),
          price: decimal(node["tradePrice"]),
          proceeds: decimal(node["proceeds"]),
          commission: decimal(node["ibCommission"]),
          commission_currency: node["ibCommissionCurrency"].presence&.upcase,
          close_price: decimal(node["closePrice"])
        )
      end

      def cash_row(node, account_id)
        CashRow.new(
          external_id: "ibkr-cash-#{node['transactionID']}",
          account_id: account_id,
          type: node["type"].to_s.strip,
          symbol: node["symbol"].to_s.strip.upcase.presence,
          description: node["description"].to_s.strip,
          listing_exchange: node["listingExchange"].presence,
          currency: node["currency"].to_s.upcase,
          date: parse_date(node["dateTime"].presence || node["settleDate"].presence || node["reportDate"]),
          ib_amount: decimal(node["amount"]) || 0.to_d
        )
      end

      def position_row(node, account_id)
        PositionRow.new(
          account_id: account_id,
          asset_category: node["assetCategory"].to_s.upcase,
          symbol: node["symbol"].to_s.strip.upcase,
          description: node["description"].to_s.strip,
          listing_exchange: node["listingExchange"].presence,
          isin: node["isin"].presence,
          currency: node["currency"].to_s.upcase,
          date: parse_date(node["reportDate"]),
          qty: decimal(node["position"]),
          mark_price: decimal(node["markPrice"])
        )
      end

      def lot_row(node, account_id)
        LotRow.new(
          external_id: "ibkr-lot-#{node['originatingTransactionID'].presence || node['transactionID']}",
          account_id: account_id,
          asset_category: node["assetCategory"].to_s.upcase,
          symbol: node["symbol"].to_s.strip.upcase,
          description: node["description"].to_s.strip,
          listing_exchange: node["listingExchange"].presence,
          isin: node["isin"].presence,
          currency: node["currency"].to_s.upcase,
          date: parse_date(node["openDateTime"].presence || node["reportDate"]),
          qty: decimal(node["position"]),
          price: decimal(node["openPrice"]) || decimal(node["costBasisPrice"]),
          cost: decimal(node["costBasisMoney"]),
          originating_order_id: node["originatingOrderID"].presence
        )
      end

      def decimal(value)
        return nil if value.blank?

        BigDecimal(value.to_s)
      rescue ArgumentError
        nil
      end
  end

  attr_reader :provider, :cache, :scope

  # provider may be nil: a run served entirely from the cache needs no client,
  # which is what makes OFFLINE=1 possible.
  #
  # @param scope [String, nil] namespaces the cache keys -- IbkrItem#cache_scope
  #   in production, nil in single-connection tests.
  def initialize(provider: nil, cache: IbkrImport::Cache.new, scope: nil)
    @provider = provider
    @cache = cache
    @scope = scope
  end

  # @return [Parsed]
  def fetch(query_id:, date: Date.current)
    self.class.parse(raw(query_id: query_id, date: date))
  end

  def raw(query_id:, date: Date.current)
    cache.fetch(key_for(query_id, date)) do
      response = provider!.statement(query_id: query_id)
      raise response.error unless response.success?

      response.data
    end
  end

  def key_for(query_id, date)
    key = self.class.cache_key(query_id, date)
    scope.present? ? "#{scope.to_s.gsub(/[^A-Za-z0-9_-]/, '')}-#{key}" : key
  end

  private
    def provider!
      provider || raise(IbkrImport::Error,
                        "no IBKR connection to call, and nothing is cached for this request")
    end
end
