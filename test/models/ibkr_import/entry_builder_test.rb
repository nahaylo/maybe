require "test_helper"

class IbkrImport::EntryBuilderTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:investment) # USD
    @parsed = IbkrImport::Statement.parse(file_fixture("ibkr/flex.xml").read).for_account("U1234567")
    @builder = builder
  end

  test "a buy becomes a trade entry priced at the trade price, plus a tagged commission" do
    outcomes = @builder.build!(trades: [ trade("ibkr-trade-7001") ], cash: [])

    assert_equal %i[created_trade created_commission], outcomes.map(&:status)

    entry = outcomes.first.entry
    assert_equal @account, entry.account
    assert_equal "ibkr-trade-7001", entry.external_id
    assert_equal Date.new(2026, 9, 14), entry.date
    assert_equal 2371.8.to_d, entry.amount
    assert_equal "USD", entry.currency
    assert_equal "Buy 3.0 shares of CAT", entry.name
    assert_equal 3.to_d, entry.trade.qty
    assert_equal 790.6.to_d, entry.trade.price
    assert_equal "CAT", entry.trade.security.ticker
    assert_equal "XNYS", entry.trade.security.exchange_operating_mic
    assert_equal "CATERPILLAR INC", entry.trade.security.name
    assert_predicate entry.trade.security, :offline?

    commission = outcomes.last.entry
    assert_equal "ibkr-trade-7001-commission", commission.external_id
    assert_equal 1.to_d, commission.amount
    assert_equal "Commission: Buy 3.0 shares of CAT", commission.name
    assert_equal "investment_activity", commission.transaction.kind
    assert_equal entry.trade.security, commission.transaction.security
    assert_equal [ "ibkr-import" ], commission.transaction.tags.map(&:name)
  end

  test "a sell is a negative quantity and a cash inflow" do
    entry = @builder.build!(trades: [ trade("ibkr-trade-7003") ], cash: []).first.entry

    assert_equal(-4.to_d, entry.trade.qty)
    assert_equal(-500.to_d, entry.amount)
  end

  test "a zero commission creates no commission row" do
    outcomes = @builder.build!(trades: [ trade("ibkr-trade-7004") ], cash: [])

    assert_equal [ :created_trade ], outcomes.map(&:status)
  end

  test "reuses a security the ledger already knows instead of creating a twin" do
    assert_no_difference "Security.count" do
      entry = @builder.build!(trades: [ trade("ibkr-trade-7004") ], cash: []).first.entry
      assert_equal securities(:aapl), entry.trade.security
    end
  end

  test "reuses a hand-entered ticker that has no exchange rather than adding one with" do
    manual = Security.create!(ticker: "CAT", offline: true)

    assert_no_difference "Security.count" do
      entry = @builder.build!(trades: [ trade("ibkr-trade-7001") ], cash: []).first.entry
      assert_equal manual, entry.trade.security
    end
  end

  test "an unsupported asset category is reported, not imported" do
    outcomes = @builder.build!(trades: [ trade("ibkr-trade-7005") ], cash: [])

    assert_equal [ :skipped_unsupported ], outcomes.map(&:status)
    assert_match(/OPT/, outcomes.first.detail)
  end

  test "rows in a currency with no linked account are reported, not imported" do
    outcomes = @builder.build!(trades: [ trade("ibkr-trade-7006") ], cash: [ cash("ibkr-cash-5006") ])

    assert_equal %i[skipped_no_account skipped_no_account], outcomes.map(&:status)
    assert_match(/no EUR account linked/, outcomes.first.detail)
  end

  test "rows go to the account of their currency" do
    eur = eur_account
    outcomes = builder(eur: eur).build!(trades: [], cash: [ cash("ibkr-cash-5001"), cash("ibkr-cash-5006") ])

    assert_equal [ @account, eur ], outcomes.map { |o| o.entry.account }
    assert_equal "EUR", outcomes.last.entry.currency
    assert_equal(-500.to_d, outcomes.last.entry.amount)
    assert_equal "Deposit to #{eur.name}", outcomes.last.entry.name
  end

  test "a conversion becomes a transfer between the two currency accounts, plus its commission" do
    eur = eur_account
    outcomes = builder(eur: eur).build!(trades: [ trade("ibkr-trade-7006") ], cash: [])

    assert_equal %i[created_fx created_commission], outcomes.map(&:status)

    outflow = outcomes.first.entry
    assert_equal eur, outflow.account
    assert_equal 500.to_d, outflow.amount
    assert_equal "EUR", outflow.currency
    assert_equal "Transfer to #{@account.name}", outflow.name
    assert_equal "funds_movement", outflow.transaction.kind
    assert_equal "ibkr-trade-7006-out", outflow.external_id

    transfer = outflow.transaction.transfer_as_outflow
    assert_predicate transfer, :confirmed?
    inflow = transfer.inflow_transaction.entry
    assert_equal @account, inflow.account
    assert_equal(-580.to_d, inflow.amount)
    assert_equal "USD", inflow.currency
    assert_equal "ibkr-trade-7006-in", inflow.external_id
    assert_equal 1.16.to_d, transfer.derived_exchange_rate

    commission = outcomes.last.entry
    assert_equal @account, commission.account
    assert_equal 2.to_d, commission.amount
  end

  test "shares that arrived without a trade are booked at IBKR's lot cost, offset by an income row" do
    outcomes = @builder.build!(trades: [], cash: [], lots: @parsed.lots)

    assert_equal [ :created_grant ], outcomes.map(&:status), "the VT lot came from a trade and must not be booked twice"

    entry = outcomes.sole.entry
    assert_equal "ibkr-lot-38027172677", entry.external_id
    assert_equal Date.new(2026, 2, 13), entry.date
    assert_equal 16.to_d, entry.amount
    assert_equal 0.219.to_d, entry.trade.qty
    assert_equal 73.0594.to_d, entry.trade.price
    assert_equal "IBKR", entry.trade.security.ticker

    offset = @account.entries.find_by(external_id: "ibkr-lot-38027172677-income")
    assert_equal(-16.to_d, offset.amount)
    assert_equal "Shares received: 0.219 IBKR", offset.name
    assert_equal "investment_activity", offset.transaction.kind
    assert_equal entry.trade.security, offset.transaction.security
    assert_equal [ "ibkr-import" ], offset.transaction.tags.map(&:name)
    assert_equal 0, @account.entries.where("external_id LIKE ?", "ibkr-lot-%").sum(:amount), "a grant must not move cash"
  end

  test "a cash row without an exchange reuses the ticker's existing security instead of creating a twin" do
    @builder.build!(trades: [ trade("ibkr-trade-7002") ], cash: [])

    assert_no_difference "Security.count" do
      @builder.build!(trades: [], cash: [ cash("ibkr-cash-5002") ])
    end
  end

  test "re-running the same rows is a no-op" do
    eur = eur_account
    builder(eur: eur).build!(trades: @parsed.trades, cash: @parsed.cash, lots: @parsed.lots)

    assert_no_difference [ "Entry.count", "Transfer.count" ] do
      outcomes = builder(eur: eur).build!(trades: @parsed.trades, cash: @parsed.cash, lots: @parsed.lots)
      assert_equal %i[skipped_imported skipped_unsupported], outcomes.map(&:status).uniq.sort
    end
  end

  test "a trade already entered by hand for the same day, security and quantity is skipped" do
    cat = Security.create!(ticker: "CAT", exchange_operating_mic: "XNYS", offline: true)
    manual = @account.entries.create!(
      date: Date.new(2026, 9, 14), amount: 2370, currency: "USD", name: "Buy 3 shares of CAT",
      entryable: Trade.new(qty: 3, price: 790, currency: "USD", security: cat)
    )

    outcomes = @builder.build!(trades: [ trade("ibkr-trade-7001") ], cash: [])

    assert_equal [ :skipped_collision ], outcomes.map(&:status)
    assert_equal manual, outcomes.first.entry
  end

  test "FORCE imports over a hand-entered twin" do
    cat = Security.create!(ticker: "CAT", exchange_operating_mic: "XNYS", offline: true)
    @account.entries.create!(
      date: Date.new(2026, 9, 14), amount: 2370, currency: "USD", name: "Buy 3 shares of CAT",
      entryable: Trade.new(qty: 3, price: 790, currency: "USD", security: cat)
    )

    outcomes = builder(force: true).build!(trades: [ trade("ibkr-trade-7001") ], cash: [])

    assert_equal :created_trade, outcomes.first.status
  end

  test "a deposit becomes an inflow named like the trade form would name it" do
    entry = @builder.build!(trades: [], cash: [ cash("ibkr-cash-5001") ]).first.entry

    assert_equal(-3000.to_d, entry.amount)
    assert_equal "Deposit to #{@account.name}", entry.name
    assert_equal "CASH RECEIPTS / ELECTRONIC FUND TRANSFERS", entry.notes
    assert_nil entry.transaction.category, "categorisation belongs to the rules engine"
    assert_equal "standard", entry.transaction.kind
    assert_equal [ "ibkr-import" ], entry.transaction.tags.map(&:name)
  end

  test "dividends, taxes, interest and fees get readable names and are never transfer candidates" do
    entries = @builder.build!(trades: [], cash: @parsed.cash).filter_map(&:entry).index_by(&:external_id)

    assert_equal "standard", entries["ibkr-cash-5001"].transaction.kind, "a deposit may be the far leg of a transfer"
    assert_equal %w[investment_activity], entries.except("ibkr-cash-5001").values.map { |e| e.transaction.kind }.uniq
    assert_equal "Dividend: VT", entries["ibkr-cash-5002"].name
    assert_equal(-4.5.to_d, entries["ibkr-cash-5002"].amount)
    assert_equal "VT", entries["ibkr-cash-5002"].transaction.security.ticker
    assert_equal entries["ibkr-cash-5002"].transaction.security, entries["ibkr-cash-5003"].transaction.security
    assert_nil entries["ibkr-cash-5001"].transaction.security, "a deposit belongs to no holding"
    assert_equal "Withholding tax: VT", entries["ibkr-cash-5003"].name
    assert_equal 0.68.to_d, entries["ibkr-cash-5003"].amount
    assert_equal "Interest payment", entries["ibkr-cash-5004"].name
    assert_equal "Fee: MARKET DATA FEE", entries["ibkr-cash-5005"].name
    assert_equal 1.5.to_d, entries["ibkr-cash-5005"].amount
  end

  test "a deposit already written down by hand a day earlier is skipped" do
    manual = @account.entries.create!(
      date: Date.new(2026, 8, 31), amount: -3000, currency: "USD", name: "Wire to IB", entryable: Transaction.new
    )

    outcomes = @builder.build!(trades: [], cash: [ cash("ibkr-cash-5001") ])

    assert_equal [ :skipped_collision ], outcomes.map(&:status)
    assert_equal manual, outcomes.first.entry
  end

  test "records the position marks and the trades' closing prices, once per security and day" do
    count = @builder.record_prices!(positions: @parsed.positions, trades: @parsed.trades)

    # 4 marks on the report date + 4 executions (the option and the conversion carry no security)
    assert_equal 8, count

    cat = Security.find_by(ticker: "CAT")
    assert_equal 801.25.to_d, cat.prices.find_by(date: Date.new(2026, 9, 19)).price
    assert_equal 792.1.to_d, cat.prices.find_by(date: Date.new(2026, 9, 14)).price
    assert_equal "USD", cat.prices.first.currency

    assert_no_difference "Security::Price.count" do
      assert_equal 0, builder.record_prices!(positions: @parsed.positions, trades: @parsed.trades),
                   "unchanged prices must not count, or every rerun would queue a sync"
    end
  end

  test "a mark that moved is rewritten and counted" do
    @builder.record_prices!(positions: @parsed.positions, trades: [])
    moved = @parsed.positions.map { |p| p.symbol == "CAT" ? p.with(mark_price: 810.to_d) : p }

    count = builder.record_prices!(positions: moved, trades: [])

    assert_equal 1, count
    assert_equal 810.to_d, Security.find_by(ticker: "CAT").prices.find_by(date: Date.new(2026, 9, 19)).price
  end

  test "the prices land on the existing security when there is one" do
    @builder.record_prices!(positions: @parsed.positions.select { |p| p.symbol == "AAPL" }, trades: [])

    assert_equal 233.1.to_d, securities(:aapl).prices.find_by(date: Date.new(2026, 9, 19)).price
  end

  private
    def builder(eur: nil, force: false)
      accounts = { "USD" => @account }
      accounts["EUR"] = eur if eur
      IbkrImport::EntryBuilder.new(family: @family, accounts: accounts, force: force)
    end

    def eur_account
      @eur_account ||= @family.accounts.create!(name: "IB EUR", balance: 0, currency: "EUR", accountable: Investment.new)
    end

    def trade(id) = @parsed.trades.find { |t| t.external_id == id }
    def cash(id) = @parsed.cash.find { |c| c.external_id == id }
end
