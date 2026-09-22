require "test_helper"

class IbkrImport::StatementTest < ActiveSupport::TestCase
  setup do
    @parsed = IbkrImport::Statement.parse(file_fixture("ibkr/flex.xml").read)
    @trades = @parsed.trades.index_by(&:external_id)
    @cash = @parsed.cash.index_by(&:external_id)
  end

  test "one account per FlexStatement, with the period the query covered" do
    assert_equal %w[U1234567 U7654321], @parsed.accounts.map(&:id)

    usd = @parsed.accounts.first
    assert_equal "USD", usd.currency
    assert_equal Date.new(2026, 8, 1), usd.from
    assert_equal Date.new(2026, 9, 19), usd.to
  end

  test "reads executions only, not the order rows the query may also carry" do
    assert_equal 7, @parsed.trades.size
    assert_not_includes @trades.keys, "ibkr-trade-"
  end

  test "trades are oldest first" do
    assert_equal @parsed.trades.map(&:date).sort, @parsed.trades.map(&:date)
  end

  test "a buy keeps IBKR's positive quantity and costs cash" do
    buy = @trades["ibkr-trade-7001"]

    assert_equal "CAT", buy.symbol
    assert_equal Date.new(2026, 9, 14), buy.date
    assert_equal 3.to_d, buy.qty
    assert_equal 790.6.to_d, buy.price
    assert_equal 2371.8.to_d, buy.amount
    assert_predicate buy, :buy?
    assert_equal "Buy 3.0 shares of CAT", buy.name
  end

  test "a sell is a negative quantity and brings cash in" do
    sell = @trades["ibkr-trade-7003"]

    assert_equal(-4.to_d, sell.qty)
    assert_equal(-500.to_d, sell.amount)
    assert_not_predicate sell, :buy?
    assert_equal "Sell 4.0 shares of VT", sell.name
  end

  test "commission flips from IBKR's negative cash to Maybe's positive outflow" do
    assert_equal 1.to_d, @trades["ibkr-trade-7001"].commission_amount
    assert_predicate @trades["ibkr-trade-7001"], :commission?
    assert_not_predicate @trades["ibkr-trade-7004"], :commission?
  end

  test "only stocks and funds are supported; conversions are their own kind" do
    assert_predicate @trades["ibkr-trade-7001"], :supported?
    assert_predicate @trades["ibkr-trade-7005"], :unsupported?
    assert_equal "OPT", @trades["ibkr-trade-7005"].asset_category
    assert_predicate @trades["ibkr-trade-7006"], :fx?
    assert_not_predicate @trades["ibkr-trade-7006"], :unsupported?
  end

  test "a conversion knows which currency left and which arrived" do
    fx = @trades["ibkr-trade-7006"]

    # Sold 500 EUR (negative quantity in EUR.USD) for 580 USD.
    assert_equal "EUR", fx.fx_out_currency
    assert_equal 500.to_d, fx.fx_out_amount
    assert_equal "USD", fx.fx_in_currency
    assert_equal 580.to_d, fx.fx_in_amount
    assert_equal "Convert 500.0 EUR to USD", fx.name

    bought = fx.with(qty: 200.to_d, proceeds: -232.0049.to_d)
    assert_equal "USD", bought.fx_out_currency
    assert_equal 232.to_d, bought.fx_out_amount, "IBKR's seven-decimal proceeds are kept to cents"
    assert_equal "EUR", bought.fx_in_currency
    assert_equal 200.to_d, bought.fx_in_amount
  end

  test "lists every currency an account books money in" do
    assert_equal %w[EUR USD], @parsed.for_account("U1234567").currencies
    assert_equal %w[EUR], @parsed.for_account("U7654321").currencies
  end

  test "reads detail cash rows only, not the per-symbol summaries" do
    assert_equal 7, @parsed.cash.size
    assert_not_includes @cash.keys, "ibkr-cash-"
  end

  test "money in becomes a negative amount, money out positive" do
    assert_equal(-3000.to_d, @cash["ibkr-cash-5001"].amount)
    assert_predicate @cash["ibkr-cash-5001"], :inflow?
    assert_predicate @cash["ibkr-cash-5001"], :deposit_or_withdrawal?
    assert_equal 0.68.to_d, @cash["ibkr-cash-5003"].amount
    assert_equal "Withholding Tax", @cash["ibkr-cash-5003"].type
  end

  test "tax lots are kept apart from the position summaries" do
    assert_equal 5, @parsed.positions.size
    assert_equal 2, @parsed.lots.size
    assert_not_includes @parsed.positions.map(&:symbol), nil
  end

  test "a lot with no originating order was acquired outside a trade" do
    traded, granted = @parsed.lots.partition { |l| l.originating_order_id.present? }

    assert_equal [ "VT" ], traded.map(&:symbol)
    assert_not_predicate traded.first, :outside_trade?

    bonus = granted.sole
    assert_predicate bonus, :outside_trade?
    assert_equal "IBKR", bonus.symbol
    assert_equal "ibkr-lot-38027172677", bonus.external_id
    assert_equal Date.new(2026, 2, 13), bonus.date
    assert_equal 0.219.to_d, bonus.qty
    assert_equal 16.to_d, bonus.cost
    assert_equal "Shares received: 0.219 IBKR", bonus.name
  end

  test "position summaries carry the marks" do
    assert_equal 5, @parsed.positions.size

    vt = @parsed.positions.find { |p| p.symbol == "VT" }
    assert_equal 6.to_d, vt.qty
    assert_equal 126.4.to_d, vt.mark_price
    assert_equal Date.new(2026, 9, 19), vt.date
  end

  test "slices everything belonging to one account" do
    eur = @parsed.for_account("U7654321")

    assert_equal [ "U7654321" ], eur.accounts.map(&:id)
    assert_equal [ "VWCE" ], eur.trades.map(&:symbol)
    assert_equal [ "ibkr-cash-5101" ], eur.cash.map(&:external_id)
    assert_equal [ "VWCE" ], eur.positions.map(&:symbol)
    assert_empty eur.lots
    assert_equal "EUR", eur.trades.first.currency
  end

  test "maps IBKR listing exchanges to operating MICs, leaving unknown ones nil" do
    assert_equal "XNYS", IbkrImport::Statement.operating_mic("NYSE")
    assert_equal "XNAS", IbkrImport::Statement.operating_mic("nasdaq")
    assert_equal "XETR", IbkrImport::Statement.operating_mic("IBIS2")
    assert_nil IbkrImport::Statement.operating_mic("CBOE")
    assert_nil IbkrImport::Statement.operating_mic(nil)
  end

  test "keeps only the day from IBKR's date;time stamps" do
    assert_equal Date.new(2026, 9, 14), IbkrImport::Statement.parse_date("20260914;153001")
    assert_equal Date.new(2026, 9, 14), IbkrImport::Statement.parse_date("20260914")
    assert_nil IbkrImport::Statement.parse_date("")
  end

  # Spin-off and merger lots name no transaction at all; before this they all
  # collapsed onto one id and only the first was ever imported.
  test "lots without any transaction id are told apart by contract and open time" do
    xml = <<~XML
      <FlexQueryResponse queryName="q" type="AF"><FlexStatements count="1">
      <FlexStatement accountId="U1" fromDate="20220103" toDate="20221230" period="" whenGenerated="20260922;120000">
      <OpenPositions>
      <OpenPosition accountId="U1" currency="USD" assetCategory="STK" symbol="WBD" conid="554208351" reportDate="20221230" position="9.6767" openPrice="28.1165" costBasisMoney="272.08" levelOfDetail="LOT" openDateTime="20210614;121145" originatingOrderID="" originatingTransactionID="" />
      <OpenPosition accountId="U1" currency="USD" assetCategory="STK" symbol="MICC" conid="836365978" reportDate="20221230" position="1" openPrice="13.38" costBasisMoney="13.38" levelOfDetail="LOT" openDateTime="20220209;155602" originatingOrderID="" originatingTransactionID="" />
      </OpenPositions>
      </FlexStatement></FlexStatements></FlexQueryResponse>
    XML

    lots = IbkrImport::Statement.parse(xml).lots

    assert_equal [ "ibkr-lot-554208351-20210614121145", "ibkr-lot-836365978-20220209155602" ], lots.map(&:external_id)
    assert lots.all?(&:outside_trade?)
  end

  test "corporate action legs keep IBKR's type, quantity, value and cash, dated when they posted" do
    parsed = IbkrImport::Statement.parse(file_fixture("ibkr/corporate_actions.xml").read)
    by_id = parsed.corporate_actions.index_by(&:external_id)

    split = by_id["ibkr-ca-17102223584"]
    assert_equal "FS", split.type
    assert_equal "NVDA", split.ticker
    assert_equal 6.to_d, split.qty
    assert_equal Date.new(2021, 7, 19), split.date
    assert_predicate split, :split?
    assert_equal "Split 4 for 1: NVDA", split.name

    out, inn = by_id["ibkr-ca-25117820406"], by_id["ibkr-ca-25117820402"]
    assert_equal [ "TC", -10.to_d, 250.to_d, -690.to_d ], [ out.type, out.qty, out.proceeds, out.value ]
    assert_equal [ "OKE", 6.67.to_d, 443.8218.to_d ], [ inn.ticker, inn.qty, inn.value ]
    assert_equal out.action_id, inn.action_id
    assert_equal "Merger: 10.0 MMP exchanged", out.name
    assert_equal "Merger: 6.67 OKE received", inn.name

    spin = by_id["ibkr-ca-20121318699"]
    assert_equal "Spin-off: 9.6767 WBD from T", spin.name
  end

  # An identity change is two legs, one under a placeholder symbol. Both are
  # the same holding, which is what `ticker` says.
  test "legs of an identity change resolve their placeholder symbols to the real holding" do
    parsed = IbkrImport::Statement.parse(file_fixture("ibkr/corporate_actions.xml").read)
    by_id = parsed.corporate_actions.index_by(&:external_id)

    assert_equal "OKE", by_id["ibkr-ca-42674756990"].ticker # symbol 2682320D
    assert_equal "OKE", by_id["ibkr-ca-42674756997"].ticker # symbol OKE.OLD
    assert_equal "UL", by_id["ibkr-ca-36677668055"].ticker  # symbol 20251208172441UL
    assert_equal "UL", by_id["ibkr-ca-36677668049"].ticker
    assert_equal "WBD", by_id["ibkr-ca-20121318699"].ticker, "a spin-off's own symbol is the new holding"
  end

  test "refuses a document that is not a Flex statement" do
    assert_raises(IbkrImport::Error) { IbkrImport::Statement.parse("<html><body>login</body></html>") }
  end

  test "fetches through the provider on a cache miss, then serves from cache" do
    root = Pathname.new(Dir.mktmpdir)
    provider = mock
    provider.expects(:statement).with(query_id: "123456").once
            .returns(Provider::Response.new(success?: true, data: file_fixture("ibkr/flex.xml").read, error: nil))
    statement = IbkrImport::Statement.new(provider: provider, cache: IbkrImport::Cache.new(root: root), scope: "item-1")

    first = statement.fetch(query_id: "123456", date: Date.new(2026, 9, 21))
    second = statement.fetch(query_id: "123456", date: Date.new(2026, 9, 21))

    assert_equal 7, first.trades.size
    assert_equal first.trades.size, second.trades.size
    assert_predicate root.join("item-1-flex-123456-20260921.xml"), :exist?

    # A second copy filed by the statement's own period survives a backfill
    # that re-fetches the same query several times in one day.
    period = first.accounts.first
    archived = root.join("statements", "item-1-flex-123456-#{period.from.strftime('%Y%m%d')}-#{period.to.strftime('%Y%m%d')}.xml")
    assert_predicate archived, :exist?
    assert_equal file_fixture("ibkr/flex.xml").read, archived.read
  ensure
    FileUtils.remove_entry(root) if root
  end

  test "a provider failure is raised, not cached" do
    root = Pathname.new(Dir.mktmpdir)
    provider = mock
    provider.stubs(:statement).returns(
      Provider::Response.new(success?: false, data: nil, error: Provider::IbkrFlex::RequestError.new("IBKR Flex error 1012: Token has expired."))
    )
    statement = IbkrImport::Statement.new(provider: provider, cache: IbkrImport::Cache.new(root: root))

    error = assert_raises(Provider::IbkrFlex::RequestError) { statement.fetch(query_id: "1") }
    assert_match(/1012/, error.message)
    assert_empty root.children
  ensure
    FileUtils.remove_entry(root) if root
  end
end
