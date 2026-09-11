class Transfer::Creator
  MissingExchangeRateError = Class.new(StandardError)

  def initialize(family:, source_account_id:, destination_account_id:, date:, amount:, destination_amount: nil)
    @family = family
    @source_account = family.accounts.find(source_account_id) # early throw if not found
    @destination_account = family.accounts.find(destination_account_id) # early throw if not found
    @date = date
    @amount = amount.to_d
    @destination_amount = normalize_destination_amount(destination_amount)
  end

  def create
    transfer = Transfer.new(
      inflow_transaction: inflow_transaction,
      outflow_transaction: outflow_transaction,
      status: "confirmed"
    )

    if transfer.save
      source_account.sync_later
      destination_account.sync_later
    end

    transfer
  rescue MissingExchangeRateError
    # Rather than silently converting 1:1, hand back an unsaved transfer carrying
    # an actionable error. The controller already renders `errors.full_messages`.
    Transfer.new.tap do |failed_transfer|
      failed_transfer.errors.add(
        :base,
        "No exchange rate available from #{source_account.currency} to #{destination_account.currency} " \
        "on #{date}. Enter the destination amount manually."
      )
    end
  end

  private
    attr_reader :family, :source_account, :destination_account, :date, :amount, :destination_amount

    def outflow_transaction
      name = "#{name_prefix} to #{destination_account.name}"

      Transaction.new(
        kind: outflow_transaction_kind,
        entry: source_account.entries.build(
          amount: amount.abs,
          currency: source_account.currency,
          date: date,
          name: name,
        )
      )
    end

    def inflow_transaction
      name = "#{name_prefix} from #{source_account.name}"

      Transaction.new(
        kind: "funds_movement",
        entry: destination_account.entries.build(
          amount: inflow_amount * -1,
          currency: destination_account.currency,
          date: date,
          name: name,
        )
      )
    end

    # Blank and zero both mean "no amount supplied" so that the trade form and
    # non-JS submits keep falling through to the market rate.
    def normalize_destination_amount(value)
      normalized = value.presence&.to_d&.abs
      return nil if normalized.nil? || normalized.zero?
      normalized
    end

    # A user-supplied amount wins over the market rate, but only when the two
    # accounts actually differ in currency -- a stale or hand-crafted value must
    # never desynchronize the two legs of a same-currency transfer.
    def inflow_amount
      return amount.abs unless cross_currency?
      return destination_amount if destination_amount.present?

      raise MissingExchangeRateError if market_rate.nil?

      (amount.abs * market_rate).round(destination_currency.default_precision)
    end

    # Carries the last published rate forward rather than refusing, since
    # providers skip weekends and a backfill may not reach today yet. Nil only
    # when the pair has never been imported -- there is no 1:1 fallback.
    def market_rate
      return @market_rate if defined?(@market_rate)

      @market_rate = ExchangeRate.find_rate_on_or_before(
        from: source_account.currency,
        to: destination_account.currency,
        date: date
      )&.rate
    end

    def cross_currency?
      source_account.currency != destination_account.currency
    end

    def destination_currency
      @destination_currency ||= Money::Currency.new(destination_account.currency)
    end

    # The "expense" side of a transfer is treated different in analytics based on where it goes.
    def outflow_transaction_kind
      if destination_account.loan?
        "loan_payment"
      elsif destination_account.liability?
        "cc_payment"
      else
        "funds_movement"
      end
    end

    def name_prefix
      if destination_account.liability?
        "Payment"
      else
        "Transfer"
      end
    end
end
