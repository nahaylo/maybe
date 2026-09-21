# Turns one IBKR account's statement rows into entries and prices, routing
# each row to the Maybe account of its currency and skipping anything already
# in the ledger.
#
# Four kinds of output:
#
#   * a Trade entry per execution, priced at the trade price so holdings and
#     cost basis come out the way a hand-entered trade would;
#   * a Transaction entry per cash row (deposit, dividend, tax, interest, fee)
#     and per non-zero commission, tagged for provenance;
#   * a Transfer per currency conversion, one leg in each currency's account,
#     which is what makes the conversion visible at all;
#   * for shares that arrived without a trade (IBKR's stock bonuses), a Trade
#     at IBKR's lot cost plus an offsetting income row, so the position and
#     its cost basis match IBKR's while cash stays flat;
#   * a Security::Price per open position (IBKR's mark on the report date) and
#     per trade (that day's close), so holdings revalue without a market data
#     provider -- there is none configured any more.
#
# Like MonobankImport::EntryBuilder it neither locks attributes nor bulk
# inserts: a run is tens of rows, and every one of them should stay editable.
class IbkrImport::EntryBuilder
  TAG_NAME = "ibkr-import".freeze

  # How far apart an IBKR cash row and a hand-entered transaction can be and
  # still be believed to be the same movement. Deposits are usually written
  # down on the day they are sent, which settles at IBKR a day later.
  CASH_COLLISION_WINDOW = 1

  CREATED_STATUSES = %i[created_trade created_commission created_cash created_fx created_grant].freeze

  Outcome = Data.define(:row, :status, :entry, :detail) do
    def created? = IbkrImport::EntryBuilder::CREATED_STATUSES.include?(status)
    def skipped? = !created?
  end

  attr_reader :family, :accounts, :force

  # @param accounts [Hash{String => Account}] the Maybe account for each currency
  def initialize(family:, accounts:, force: false)
    @family = family
    @accounts = accounts.transform_keys(&:upcase)
    @force = force
    @securities = {}
    @pools = {}
  end

  # @param trades [Array<IbkrImport::Statement::TradeRow>]
  # @param cash [Array<IbkrImport::Statement::CashRow>]
  # @param lots [Array<IbkrImport::Statement::LotRow>] only lots opened
  #   outside a trade are booked; the rest are the trades' own lots
  # @return [Array<Outcome>]
  # Rows that are income or cost thrown off by the holdings, never a transfer.
  INVESTMENT_ACTIVITY_KIND = "investment_activity".freeze

  def build!(trades:, cash:, lots: [])
    seen = Entry.where(account_id: accounts.values.map(&:id))
                .where.not(external_id: nil)
                .pluck(:external_id)
                .to_set
    @rows = trades + cash

    trades.flat_map { |row| row.fx? ? build_fx(row, seen) : build_trade(row, seen) } +
      cash.map { |row| build_cash(row, seen) } +
      lots.select(&:outside_trade?).map { |row| build_grant(row, seen) }
  end

  # Records the prices the statement carries. Idempotent: a price already on
  # file with the same figure is neither rewritten nor counted, so a rerun
  # that changes nothing reports zero and triggers no sync.
  #
  # @return [Integer] prices that were new or different
  def record_prices!(positions:, trades:)
    rows = {}

    positions.select(&:supported?).each do |row|
      next if row.mark_price.nil? || row.date.nil?

      rows[[ row.symbol, row.listing_exchange, row.date ]] = price_row(row, row.date, row.mark_price)
    end

    trades.select(&:supported?).each do |row|
      next if row.close_price.nil? || row.date.nil?

      # A position mark on the same day is IBKR's own figure for it; keep it.
      rows[[ row.symbol, row.listing_exchange, row.date ]] ||= price_row(row, row.date, row.close_price)
    end

    existing = existing_prices(rows.values)
    changed = rows.values.reject { |row| existing[[ row[:security_id], row[:date], row[:currency] ]] == row[:price] }
    return 0 if changed.empty?

    Security::Price.upsert_all(changed, unique_by: %i[security_id date currency], returning: [ "id" ]).count
  end

  private
    def build_trade(row, seen)
      if row.unsupported?
        return [ Outcome.new(row: row, status: :skipped_unsupported, entry: nil,
                             detail: "#{row.asset_category} is not supported -- record it by hand if it matters") ]
      end

      if seen.include?(row.external_id)
        return [ Outcome.new(row: row, status: :skipped_imported, entry: nil, detail: "already imported") ]
      end

      account = accounts[row.currency]
      return [ no_account(row, row.currency) ] if account.nil?

      security = security_for(row)

      if !force && (existing = claim_trade_collision(account, row, security))
        return [ Outcome.new(row: row, status: :skipped_collision, entry: existing,
                             detail: "matches existing #{existing.date} #{existing.name.inspect}") ]
      end

      entry = create_trade!(account, row, security)
      seen << row.external_id
      [ Outcome.new(row: row, status: :created_trade, entry: entry, detail: nil) ] + build_commission(row, seen)
    end

    # A conversion has a leg in each currency, so it needs both accounts.
    def build_fx(row, seen)
      out_id = "#{row.external_id}-out"
      in_id = "#{row.external_id}-in"

      if seen.include?(out_id) || seen.include?(in_id)
        return [ Outcome.new(row: row, status: :skipped_imported, entry: nil, detail: "already imported") ]
      end

      out_account = accounts[row.fx_out_currency]
      in_account = accounts[row.fx_in_currency]
      return [ no_account(row, row.fx_out_currency) ] if out_account.nil?
      return [ no_account(row, row.fx_in_currency) ] if in_account.nil?

      notes = "IBKR conversion #{row.symbol} @ #{row.price.to_s('F')}"

      outflow = create_transaction!(
        out_account,
        external_id: out_id, date: row.date, name: "Transfer to #{in_account.name}",
        amount: row.fx_out_amount, currency: row.fx_out_currency, notes: notes, kind: "funds_movement"
      )
      inflow = create_transaction!(
        in_account,
        external_id: in_id, date: row.date, name: "Transfer from #{out_account.name}",
        amount: -row.fx_in_amount, currency: row.fx_in_currency, notes: notes, kind: "funds_movement"
      )
      Transfer.create!(inflow_transaction: inflow.transaction, outflow_transaction: outflow.transaction, status: "confirmed")

      seen << out_id << in_id

      [ Outcome.new(row: row, status: :created_fx, entry: outflow,
                    detail: "#{row.fx_in_amount.to_s('F')} #{row.fx_in_currency} @ #{row.price.to_s('F')}") ] +
        build_commission(row, seen)
    end

    # Shares credited without a trade. IBKR carries them at the market value
    # of the day, so a buy at that price plus an equal inflow reproduces both
    # the cost basis and the fact that no cash left the account.
    def build_grant(row, seen)
      unless row.supported?
        return Outcome.new(row: row, status: :skipped_unsupported, entry: nil,
                           detail: "#{row.asset_category} is not supported -- record it by hand if it matters")
      end

      if seen.include?(row.external_id)
        return Outcome.new(row: row, status: :skipped_imported, entry: nil, detail: "already imported")
      end

      account = accounts[row.currency]
      return no_account(row, row.currency) if account.nil?

      cost = (row.cost || row.qty * row.price).round(2)
      security = security_for(row)

      entry = account.entries.new(
        external_id: row.external_id,
        date: row.date,
        name: ::Trade.build_name("buy", row.qty, row.symbol),
        amount: cost,
        currency: row.currency,
        notes: "Received without a trade (IBKR lot); cost basis as reported by IBKR",
        entryable: Trade.new(qty: row.qty, price: row.price, currency: row.currency, security: security)
      )
      entry.save!

      offset = create_transaction!(
        account,
        external_id: "#{row.external_id}-income", date: row.date, name: row.name,
        amount: -cost, currency: row.currency, notes: "Offsets the #{row.symbol} lot booked the same day",
        kind: INVESTMENT_ACTIVITY_KIND
      )

      seen << row.external_id << offset.external_id
      Outcome.new(row: row, status: :created_grant, entry: entry,
                  detail: "#{row.qty.to_s('F')} @ #{row.price.round(4).to_s('F')}, offset by #{row.name.inspect}")
    end

    def build_commission(row, seen)
      return [] unless row.commission?

      id = commission_id(row)
      return [] if seen.include?(id)

      currency = row.commission_currency || row.currency
      account = accounts[currency]
      return [ no_account(row, currency, what: "its commission") ] if account.nil?

      entry = create_transaction!(
        account,
        external_id: id, date: row.date, name: "Commission: #{row.name}",
        amount: row.commission_amount, currency: currency, notes: nil,
        kind: INVESTMENT_ACTIVITY_KIND
      )
      seen << id

      [ Outcome.new(row: row, status: :created_commission, entry: entry,
                    detail: "commission #{row.commission_amount.to_s('F')} #{currency}") ]
    end

    def build_cash(row, seen)
      if seen.include?(row.external_id)
        return Outcome.new(row: row, status: :skipped_imported, entry: nil, detail: "already imported")
      end

      account = accounts[row.currency]
      return no_account(row, row.currency) if account.nil?

      if !force && (existing = claim_cash_collision(account, row))
        return Outcome.new(row: row, status: :skipped_collision, entry: existing,
                           detail: "matches existing #{existing.date} #{existing.name.inspect}")
      end

      entry = create_transaction!(
        account,
        external_id: row.external_id, date: row.date, name: cash_name(row, account),
        amount: row.amount, currency: row.currency, notes: row.description.presence,
        # A deposit may be the far leg of a transfer from the family's bank; a
        # dividend, tax, interest or fee never is.
        kind: row.deposit_or_withdrawal? ? "standard" : INVESTMENT_ACTIVITY_KIND
      )
      seen << row.external_id
      Outcome.new(row: row, status: :created_cash, entry: entry, detail: row.type)
    end

    def no_account(row, currency, what: nil)
      Outcome.new(row: row, status: :skipped_no_account, entry: nil,
                  detail: "no #{currency} account linked#{what ? " for #{what}" : ''}")
    end

    def create_trade!(account, row, security)
      entry = account.entries.new(
        external_id: row.external_id,
        date: row.date,
        name: row.name,
        amount: row.amount,
        currency: row.currency,
        notes: row.description.presence,
        entryable: Trade.new(
          qty: row.qty,
          price: row.price,
          currency: row.currency,
          security: security
        )
      )

      entry.save!
      entry
    end

    def create_transaction!(account, external_id:, date:, name:, amount:, currency:, notes:, kind: "standard")
      entry = account.entries.new(
        external_id: external_id,
        date: date,
        name: name,
        amount: amount,
        currency: currency,
        notes: notes,
        # No category: the rules engine assigns it on the next family sync.
        entryable: Transaction.new(kind: kind)
      )

      entry.save!
      entry.transaction.tags = [ tag ]
      entry
    end

    # Names follow what the trade form produces for the same movements, so an
    # imported ledger reads like a hand-kept one.
    def cash_name(row, account)
      case row.type
      when IbkrImport::Statement::DEPOSIT_TYPE
        row.inflow? ? "Deposit to #{account.name}" : "Withdrawal from #{account.name}"
      when "Dividends"
        "Dividend: #{row.symbol}"
      when "Payment In Lieu Of Dividends"
        "Payment in lieu of dividend: #{row.symbol}"
      when "Withholding Tax"
        "Withholding tax: #{row.symbol}"
      when "Broker Interest Received"
        "Interest payment"
      when "Broker Interest Paid"
        "Interest charge"
      when "Other Fees"
        "Fee: #{row.description.presence || 'IBKR'}"
      else
        [ row.type, row.symbol ].compact.join(": ")
      end
    end

    def commission_id(row)
      "#{row.external_id}-commission"
    end

    # The Security a row refers to, created offline when unknown. Reuses a
    # ticker that was entered by hand without an exchange rather than creating
    # a second copy of it with one.
    def security_for(row)
      mic = IbkrImport::Statement.operating_mic(row.listing_exchange)

      @securities[[ row.symbol, mic ]] ||= begin
        security = Security.find_by(ticker: row.symbol, exchange_operating_mic: mic) ||
                   (mic && Security.find_by(ticker: row.symbol, exchange_operating_mic: nil)) ||
                   Security.create!(
                     ticker: row.symbol,
                     exchange_operating_mic: mic,
                     name: row.description.presence,
                     # No provider knows this ticker; the mark prices come from IBKR.
                     offline: true
                   )

        security.update!(name: row.description) if security.name.blank? && row.description.present?
        security
      end
    end

    # What is already on file for the securities and days this run touches,
    # keyed the way the unique index is.
    def existing_prices(rows)
      Security::Price
        .where(security_id: rows.map { |r| r[:security_id] }.uniq, date: rows.map { |r| r[:date] }.uniq)
        .pluck(:security_id, :date, :currency, :price)
        .to_h { |security_id, date, currency, price| [ [ security_id, date, currency ], price ] }
    end

    def price_row(row, date, price)
      {
        security_id: security_for(row).id,
        date: date,
        price: price,
        currency: row.currency
      }
    end

    # Entries that could be a hand-written version of one of this run's rows:
    # same account, no external id of their own, within the window. One pool
    # per account, built on first use.
    def collision_pool(account)
      @pools[account.id] ||= begin
        dates = @rows.map(&:date).compact

        if dates.empty?
          []
        else
          account.entries
                 .where(external_id: nil)
                 .where(date: (dates.min - CASH_COLLISION_WINDOW)..(dates.max + CASH_COLLISION_WINDOW))
                 .includes(:entryable)
                 .to_a
        end
      end
    end

    # A hand-entered trade for the same security, day and signed quantity.
    # Removed from the pool once matched so two executions cannot both be
    # explained by one entry.
    def claim_trade_collision(account, row, security)
      pool = collision_pool(account)
      match = pool.find do |entry|
        entry.trade? && entry.date == row.date &&
          entry.trade.security_id == security.id && entry.trade.qty == row.qty
      end

      pool.delete(match) if match
    end

    def claim_cash_collision(account, row)
      pool = collision_pool(account)
      match = pool.select do |entry|
        entry.transaction? && entry.amount == row.amount &&
          (entry.date - row.date).abs <= CASH_COLLISION_WINDOW
      end.min_by { |entry| (entry.date - row.date).abs }

      pool.delete(match) if match
    end

    def tag
      @tag ||= family.tags.find_or_create_by!(name: TAG_NAME)
    end
end
