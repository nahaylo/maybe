require "test_helper"

class Transfer::CreatorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @source_account = accounts(:depository)
    @destination_account = accounts(:investment)
    @date = Date.current
    @amount = 100
  end

  test "creates basic transfer" do
    creator = Transfer::Creator.new(
      family: @family,
      source_account_id: @source_account.id,
      destination_account_id: @destination_account.id,
      date: @date,
      amount: @amount
    )

    transfer = creator.create

    assert transfer.persisted?
    assert_equal "confirmed", transfer.status
    assert transfer.regular_transfer?
    assert_equal "transfer", transfer.transfer_type

    # Verify outflow transaction (from source account)
    outflow = transfer.outflow_transaction
    assert_equal "funds_movement", outflow.kind
    assert_equal @amount, outflow.entry.amount
    assert_equal @source_account.currency, outflow.entry.currency
    assert_equal "Transfer to #{@destination_account.name}", outflow.entry.name

    # Verify inflow transaction (to destination account)
    inflow = transfer.inflow_transaction
    assert_equal "funds_movement", inflow.kind
    assert_equal(@amount * -1, inflow.entry.amount)
    assert_equal @destination_account.currency, inflow.entry.currency
    assert_equal "Transfer from #{@source_account.name}", inflow.entry.name
  end

  # Replaces a former "creates multi-currency transfer" test that used the crypto
  # fixture -- which is USD, so it never exercised a conversion at all.
  test "converts the destination leg using the stored exchange rate" do
    usd_to_eur_rate
    transfer = create_transfer(destination_account_id: eur_account.id)

    assert transfer.persisted?
    assert_equal 100, transfer.outflow_transaction.entry.amount
    assert_equal "USD", transfer.outflow_transaction.entry.currency
    assert_equal(-90, transfer.inflow_transaction.entry.amount)
    assert_equal "EUR", transfer.inflow_transaction.entry.currency
  end

  test "uses the supplied destination amount instead of the rate" do
    usd_to_eur_rate
    transfer = create_transfer(destination_account_id: eur_account.id, destination_amount: 95)

    assert transfer.persisted?
    assert_equal 100, transfer.outflow_transaction.entry.amount
    assert_equal(-95, transfer.inflow_transaction.entry.amount)
  end

  test "creates a cross-currency transfer with a supplied amount when no rate exists" do
    eur_account
    ExchangeRate.delete_all
    ExchangeRate.stubs(:provider).returns(nil)

    transfer = create_transfer(destination_account_id: eur_account.id, destination_amount: 95)

    assert transfer.persisted?
    assert_equal(-95, transfer.inflow_transaction.entry.amount)
  end

  # Regression test for the silent 1:1 fallback, which recorded 100 USD as 100 EUR.
  test "does not create a cross-currency transfer when no rate and no amount are given" do
    eur_account
    ExchangeRate.delete_all
    ExchangeRate.stubs(:provider).returns(nil)

    transfer = nil
    assert_no_difference "Transfer.count" do
      transfer = create_transfer(destination_account_id: eur_account.id)
    end

    assert_not transfer.persisted?
    assert_match(/USD/, transfer.errors.full_messages.first)
    assert_match(/EUR/, transfer.errors.full_messages.first)
  end

  test "carries the last published rate forward when the exact date has none" do
    usd_to_eur_rate # rate exists for @date only

    transfer = create_transfer(destination_account_id: eur_account.id, date: @date + 3.days)

    assert transfer.persisted?
    assert_equal(-90, transfer.inflow_transaction.entry.amount)
  end

  test "does not carry a rate backwards to a date before it was published" do
    usd_to_eur_rate
    ExchangeRate.stubs(:provider).returns(nil)

    transfer = create_transfer(destination_account_id: eur_account.id, date: @date - 3.days)

    assert_not transfer.persisted?
  end

  test "ignores the destination amount when both accounts share a currency" do
    transfer = create_transfer(destination_amount: 999)

    assert transfer.persisted?
    assert_equal(-100, transfer.inflow_transaction.entry.amount)
  end

  test "treats a zero destination amount as absent and falls back to the rate" do
    usd_to_eur_rate
    transfer = create_transfer(destination_account_id: eur_account.id, destination_amount: 0)

    assert transfer.persisted?
    assert_equal(-90, transfer.inflow_transaction.entry.amount)
  end

  test "normalizes a negative destination amount" do
    usd_to_eur_rate
    transfer = create_transfer(destination_account_id: eur_account.id, destination_amount: -95)

    assert transfer.persisted?
    assert_equal(-95, transfer.inflow_transaction.entry.amount)
  end

  test "rounds the converted amount to the destination currency precision" do
    jpy_account = @family.accounts.create!(
      name: "JPY Wallet", balance: 0, currency: "JPY", accountable: Depository.new
    )
    ExchangeRate.create!(from_currency: "USD", to_currency: "JPY", rate: 147.5, date: @date)

    transfer = create_transfer(destination_account_id: jpy_account.id, amount: 10.03)

    # JPY has a default_precision of 0, so the leg is whole yen
    assert_equal(-1479, transfer.inflow_transaction.entry.amount)
  end

  test "creates loan payment" do
    loan_account = accounts(:loan)

    creator = Transfer::Creator.new(
      family: @family,
      source_account_id: @source_account.id,
      destination_account_id: loan_account.id,
      date: @date,
      amount: @amount
    )

    transfer = creator.create

    assert transfer.persisted?
    assert transfer.loan_payment?
    assert_equal "loan_payment", transfer.transfer_type

    # Verify outflow transaction is marked as loan payment
    outflow = transfer.outflow_transaction
    assert_equal "loan_payment", outflow.kind
    assert_equal "Payment to #{loan_account.name}", outflow.entry.name

    # Verify inflow transaction
    inflow = transfer.inflow_transaction
    assert_equal "funds_movement", inflow.kind
    assert_equal "Payment from #{@source_account.name}", inflow.entry.name
  end

  test "creates credit card payment" do
    credit_card_account = accounts(:credit_card)

    creator = Transfer::Creator.new(
      family: @family,
      source_account_id: @source_account.id,
      destination_account_id: credit_card_account.id,
      date: @date,
      amount: @amount
    )

    transfer = creator.create

    assert transfer.persisted?
    assert transfer.liability_payment?
    assert_equal "liability_payment", transfer.transfer_type

    # Verify outflow transaction is marked as payment for liability
    outflow = transfer.outflow_transaction
    assert_equal "cc_payment", outflow.kind
    assert_equal "Payment to #{credit_card_account.name}", outflow.entry.name

    # Verify inflow transaction
    inflow = transfer.inflow_transaction
    assert_equal "funds_movement", inflow.kind
    assert_equal "Payment from #{@source_account.name}", inflow.entry.name
  end

  test "raises error when source account ID is invalid" do
    assert_raises(ActiveRecord::RecordNotFound) do
      Transfer::Creator.new(
        family: @family,
        source_account_id: 99999,
        destination_account_id: @destination_account.id,
        date: @date,
        amount: @amount
      )
    end
  end

  test "raises error when destination account ID is invalid" do
    assert_raises(ActiveRecord::RecordNotFound) do
      Transfer::Creator.new(
        family: @family,
        source_account_id: @source_account.id,
        destination_account_id: 99999,
        date: @date,
        amount: @amount
      )
    end
  end

  test "raises error when source account belongs to different family" do
    other_family = families(:empty)

    assert_raises(ActiveRecord::RecordNotFound) do
      Transfer::Creator.new(
        family: other_family,
        source_account_id: @source_account.id,
        destination_account_id: @destination_account.id,
        date: @date,
        amount: @amount
      )
    end
  end

  private
    def eur_account
      @eur_account ||= @family.accounts.create!(
        name: "EUR Checking", balance: 0, currency: "EUR", accountable: Depository.new
      )
    end

    def usd_to_eur_rate
      ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", rate: 0.9, date: @date)
    end

    def create_transfer(**overrides)
      Transfer::Creator.new(
        **{
          family: @family,
          source_account_id: @source_account.id,
          destination_account_id: @destination_account.id,
          date: @date,
          amount: @amount
        }.merge(overrides)
      ).create
    end
end
