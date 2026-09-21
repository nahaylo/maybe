require "test_helper"

class IbkrImport::ImporterTest < ActiveSupport::TestCase
  QUERY_ID = "123456".freeze
  DATE = Date.new(2026, 9, 21)

  setup do
    @family = families(:dylan_family)
    @account = accounts(:investment) # USD
    @item = IbkrItem.create!(family: @family, name: "ib", access_token: "tok", query_id: QUERY_ID)
    @link = IbkrAccount.create!(ibkr_item: @item, account: @account, ibkr_id: "U1234567")
    @root = Pathname.new(Dir.mktmpdir)
    @io = StringIO.new
    seed_statement
  end

  teardown { FileUtils.remove_entry(@root) }

  test "imports the linked currency's slice of the report and records the prices" do
    report = importer.import!.sole

    assert_equal "U1234567", report.ibkr_id
    assert_equal [ @account ], report.accounts
    assert_equal Date.new(2026, 8, 1), report.from
    assert_equal Date.new(2026, 9, 19), report.to
    # 4 trades + 3 commissions + 5 USD cash rows + 1 bonus lot
    assert_equal 13, report.created.size
    assert_equal 1, report.by_status[:created_grant]
    assert_equal 1, report.by_status[:skipped_unsupported]
    # the conversion and the EUR deposit have nowhere to go yet
    assert_equal 2, report.by_status[:skipped_no_account]
    assert_equal [ "EUR" ], report.missing_currencies
    assert_equal 8, report.prices
    assert_predicate report, :changed?

    assert_match(/U1234567 -> USD: #{Regexp.escape(@account.name)}/, @io.string)
    assert_match(/created_trade\s+4/, @io.string)
    assert_match(/prices\s+8/, @io.string)
    assert_match(/rows in EUR skipped: no EUR account is linked to U1234567/, @io.string)
    assert_match(/1 row\(s\) skipped: options/, @io.string)
  end

  test "with a EUR account linked, the conversion becomes a transfer and the EUR deposit lands there" do
    eur = link_eur

    report = importer.import!.sole

    assert_equal [ @account, eur ].to_set, report.accounts.to_set
    assert_equal 16, report.created.size
    assert_empty report.missing_currencies
    assert_equal 1, report.by_status[:created_fx]

    transfer = Transfer.joins(outflow_transaction: :entry).find_by(entries: { external_id: "ibkr-trade-7006-out" })
    assert_equal eur, transfer.from_account
    assert_equal @account, transfer.to_account
    assert_equal(-500.to_d, eur.entries.find_by(external_id: "ibkr-cash-5006").amount)
  end

  test "rows for an IBKR account that is not linked are left alone" do
    importer.import!

    assert_nil Entry.find_by(external_id: "ibkr-cash-5101")
    assert_nil Security.find_by(ticker: "VWCE")
  end

  test "a second IBKR account takes its own slice of the same report without a second fetch" do
    eur = @family.accounts.create!(name: "IB two EUR", balance: 0, currency: "EUR", accountable: Investment.new)
    IbkrAccount.create!(ibkr_item: @item, account: eur, ibkr_id: "U7654321")

    reports = importer.import!

    assert_equal %w[U1234567 U7654321], reports.map(&:ibkr_id).sort
    eur_report = reports.find { |r| r.ibkr_id == "U7654321" }
    assert_equal 3, eur_report.created.size
    assert_equal "EUR", eur_report.created.first.entry.currency
  end

  test "ONLY restricts the run to one IBKR account" do
    eur = @family.accounts.create!(name: "IB two EUR", balance: 0, currency: "EUR", accountable: Investment.new)
    IbkrAccount.create!(ibkr_item: @item, account: eur, ibkr_id: "U7654321")

    reports = importer.import!(only: [ "U7654321" ])

    assert_equal [ "U7654321" ], reports.map(&:ibkr_id)
  end

  test "a link whose IBKR account is missing from the report is reported and skipped" do
    @link.update!(ibkr_id: "U0000000")

    report = importer.import!.sole

    assert_empty report.outcomes
    assert_not_predicate report, :changed?
    assert_match(/not in this report/, @io.string)
  end

  test "lists the accounts and currencies the report covers and which are linked" do
    importer.accounts!

    assert_match(/U1234567\s+2026-08-01 \.\. 2026-09-19/, @io.string)
    assert_match(/USD\s+-> #{Regexp.escape(@account.name)}/, @io.string)
    assert_match(/EUR\s+\(not linked\)/, @io.string)
    assert_match(/rails ibkr:link ITEM=ib ID=U1234567 ACCOUNT="<EUR account name>"/, @io.string)
    assert_match(/U7654321/, @io.string)
  end

  test "a second run changes nothing" do
    link_eur
    importer.import!

    assert_no_difference [ "Entry.count", "Transfer.count", "Security::Price.count" ] do
      report = importer(StringIO.new).import!.sole
      assert_empty report.created
      assert_equal 0, report.prices
      assert_not_predicate report, :changed?, "a rerun that changed nothing must not queue a sync"
    end
  end

  private
    def importer(io = @io)
      IbkrImport::Importer.new(
        family: @family, io: io, date: DATE,
        cache: IbkrImport::Cache.new(root: @root, offline: true)
      )
    end

    def link_eur
      eur = @family.accounts.create!(name: "IB EUR", balance: 0, currency: "EUR", accountable: Investment.new)
      IbkrAccount.create!(ibkr_item: @item, account: eur, ibkr_id: "U1234567")
      eur
    end

    def seed_statement
      statement = IbkrImport::Statement.new(cache: IbkrImport::Cache.new(root: @root), scope: @item.cache_scope)
      target = statement.cache.path_for(statement.key_for(QUERY_ID, DATE))
      target.dirname.mkpath
      target.write(file_fixture("ibkr/flex.xml").read)
    end
end
