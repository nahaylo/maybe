require "test_helper"

class MonobankImport::ImporterTest < ActiveSupport::TestCase
  ACCOUNT_ID = "testacc".freeze
  FIRST_ROW_DATE = Date.new(2026, 7, 16)

  setup do
    @family = families(:dylan_family)
    @account = @family.accounts.create!(
      name: "Mono Test USD", balance: 0, currency: "USD", accountable: Depository.new
    )
    @item = MonobankItem.create!(family: @family, name: "personal", access_token: "test-token")
    @link = MonobankAccount.create!(monobank_item: @item, account: @account, monobank_id: ACCOUNT_ID)
    @root = Pathname.new(Dir.mktmpdir)
  end

  teardown { FileUtils.remove_entry(@root) }

  test "reports drift when the ledger disagrees with the bank's opening balance" do
    ledger_entry(date: Date.new(2026, 6, 1), amount: -100) # an inflow, ledger = 100
    seed_statement(balance_after: 80)
    seed_client_info(credit_limit: 0)

    boundary = report.boundary

    # Bank says 80 after a 2.99 charge, so 82.99 before it. Ledger says 100.
    assert_equal FIRST_ROW_DATE, boundary.date
    assert_equal 82.99.to_d, boundary.bank
    assert_equal 100.to_d, boundary.ledger
    assert_equal(-17.01.to_d, boundary.drift)
    assert_not_predicate boundary, :clean?
  end

  test "no drift when they agree" do
    ledger_entry(date: Date.new(2026, 6, 1), amount: -82.99)
    seed_statement(balance_after: 80)
    seed_client_info(credit_limit: 0)

    assert_predicate report.boundary, :clean?
  end

  test "the credit limit is subtracted from the bank's figure" do
    # Monobank reports balance inclusive of the credit limit; the ledger has no
    # concept of it, so without this every credit card would look adrift.
    ledger_entry(date: Date.new(2026, 6, 1), amount: -82.99)
    seed_statement(balance_after: 100_080)
    seed_client_info(credit_limit: 100_000)

    assert_predicate report.boundary, :clean?
  end

  test "entries after the first statement row do not count toward the opening balance" do
    ledger_entry(date: Date.new(2026, 6, 1), amount: -82.99)
    ledger_entry(date: FIRST_ROW_DATE + 5, amount: -500)
    seed_statement(balance_after: 80)
    seed_client_info(credit_limit: 0)

    assert_predicate report.boundary, :clean?
  end

  test "the check is skipped rather than guessed at when client-info is not cached" do
    ledger_entry(date: Date.new(2026, 6, 1), amount: -100)
    seed_statement(balance_after: 80)

    assert_nil report.boundary
  end

  test "the check is skipped when the statement is empty" do
    seed_statement(rows: [])

    assert_nil report.boundary
  end

  test "reports imported utility bills, because they all need checking by hand" do
    seed_client_info(credit_limit: 0)
    seed_statement(rows: [ utility_row("Холодна вода", -34_274), utility_row("Холодна вода", -2_742, offset: 46) ])

    io = StringIO.new
    MonobankImport::Importer.new(
      family: @family, io: io,
      cache: MonobankImport::Cache.new(root: @root, offline: true)
    ).import!(from: from, to: to)

    output = io.string
    assert_match(/2 utility bill\(s\) imported, ALL filed under the default property/, output)
    assert_match(/342\.74/, output)
    assert_match(/27\.42/, output)
    assert_match(/utilities-guessed/, output)
  end

  test "says nothing about utilities when none were imported" do
    seed_client_info(credit_limit: 0)
    seed_statement(balance_after: 80)

    io = StringIO.new
    MonobankImport::Importer.new(
      family: @family, io: io,
      cache: MonobankImport::Cache.new(root: @root, offline: true)
    ).import!(from: from, to: to)

    assert_no_match(/utility bill/, io.string)
  end

  private
    def utility_row(description, amount, offset: 0)
      {
        "id" => "util-#{description}-#{amount}",
        "time" => FIRST_ROW_DATE.in_time_zone(MonobankImport::Statement::ZONE).change(hour: 10).to_i + offset,
        "description" => description, "mcc" => MonobankImport::EntryBuilder::UTILITY_MCC,
        "hold" => false, "amount" => amount, "operationAmount" => amount,
        "currencyCode" => 840, "balance" => 8_000
      }
    end

    def from = Date.new(2026, 7, 1)
    def to = Date.new(2026, 7, 31)

    def report
      importer = MonobankImport::Importer.new(
        family: @family,
        io: StringIO.new,
        cache: MonobankImport::Cache.new(root: @root, offline: true)
      )

      importer.import!(from: from, to: to).sole
    end

    def ledger_entry(date:, amount:)
      @account.entries.create!(
        date: date, amount: amount, currency: @account.currency,
        name: "existing", entryable: Transaction.new
      )
    end

    def seed_statement(balance_after: 80, rows: nil)
      rows ||= [ {
        "id" => "row-1",
        "time" => FIRST_ROW_DATE.in_time_zone(MonobankImport::Statement::ZONE).change(hour: 12).to_i,
        "description" => "Apple", "mcc" => 5818, "hold" => false,
        "amount" => -299, "operationAmount" => -299, "currencyCode" => 840,
        "balance" => (balance_after * 100).to_i
      } ]

      # Seeded through the same windowing the importer uses, so the keys match
      # even when the range is wide enough to be split into several requests.
      zone = MonobankImport::Statement::ZONE
      windows = MonobankImport::Statement.new.windows(
        from.in_time_zone(zone).beginning_of_day,
        to.in_time_zone(zone).end_of_day
      )

      windows.each_with_index do |(start, finish), index|
        write(MonobankImport::Statement.cache_key(ACCOUNT_ID, start, finish), index.zero? ? rows : [])
      end
    end

    def seed_client_info(credit_limit:)
      write(
        MonobankImport::Statement.client_info_key(@item.cache_scope),
        { "accounts" => [ { "id" => ACCOUNT_ID, "creditLimit" => credit_limit * 100 } ] }
      )
    end

    def write(key, payload)
      file = @root.join("#{key}.json")
      file.dirname.mkpath
      file.write(JSON.generate(payload))
    end
end
