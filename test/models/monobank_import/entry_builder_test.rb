require "test_helper"

class MonobankImport::EntryBuilderTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @category = categories(:food_and_drink)
    @builder = MonobankImport::EntryBuilder.new(family: @family, account: @account)
  end

  test "creates an entry with the sign flipped, the MCC, and the provenance tag" do
    row = build_row(amount: -25_000, mcc: 5411, description: "Сільпо")

    outcome = build(row).sole

    assert_equal :created, outcome.status
    assert_equal 250.to_d, outcome.entry.amount
    assert_equal @account.currency, outcome.entry.currency
    assert_equal "Сільпо", outcome.entry.name
    assert_equal row.external_id, outcome.entry.external_id
    assert_equal 5411, outcome.entry.transaction.mcc
    assert_nil outcome.entry.transaction.category, "categorisation belongs to the rules engine now"
    assert_equal [ "mono-import" ], outcome.entry.transaction.tags.map(&:name)
  end

  test "a utility bill is tagged so the other property's can be found later" do
    # Every utility row is filed under a default property by rule; the payload
    # has nothing that says which property it belongs to.
    outcome = build(build_row(mcc: MonobankImport::EntryBuilder::UTILITY_MCC, description: "Холодна вода")).sole

    assert_equal [ "mono-import", "utilities-guessed" ], outcome.entry.transaction.tags.map(&:name).sort
    assert_predicate outcome.row, :utility?
  end

  test "a non-utility row is not tagged as one" do
    outcome = build(build_row(mcc: 5411)).sole

    assert_equal [ "mono-import" ], outcome.entry.transaction.tags.map(&:name)
  end


  test "an unsettled row is imported and tagged as pending" do
    outcome = build(build_row(hold: true)).sole

    assert_equal :created_hold, outcome.status
    assert_includes outcome.entry.transaction.tags.map(&:name), "pending-hold"
  end

  test "a hold that posts updates the row in place and drops the pending tag" do
    hold = build_row(amount: -25_000, hold: true)
    build(hold)

    settled = build_row(amount: -26_000, hold: false) # same id, final amount differs
    outcome = MonobankImport::EntryBuilder
                .new(family: @family, account: @account)
                .build!(rows: [ settled ])
                .sole

    assert_equal :settled, outcome.status
    assert_equal 260.to_d, outcome.entry.reload.amount
    assert_not_includes outcome.entry.transaction.tags.map(&:name), "pending-hold"
    assert_equal 1, @account.entries.where(external_id: hold.external_id).count
  end

  test "a hold the bank stops reporting is removed rather than left to double-count" do
    hold = build_row(amount: -25_000, hold: true, id: "gone")
    build(hold)

    # The same window comes back with a different row -- the hold was reissued
    # under a new id, or cancelled.
    replacement = build_row(amount: -26_000, id: "reissued", time: hold.time + 60)
    outcomes = MonobankImport::EntryBuilder
                 .new(family: @family, account: @account)
                 .build!(rows: [ replacement ])

    assert_equal [ :hold_dropped, :created ], outcomes.map(&:status)
    assert_equal 0, @account.entries.where(external_id: "gone").count
    assert_equal 1, @account.entries.where(external_id: "reissued").count
  end

  test "a hold the user has edited is never purged or overwritten" do
    hold = build_row(amount: -25_000, hold: true, id: "mine")
    entry = build(hold).sole.entry
    entry.transaction.lock_saved_attributes!

    replacement = build_row(amount: -26_000, id: "other", time: hold.time + 60)
    outcomes = MonobankImport::EntryBuilder
                 .new(family: @family, account: @account)
                 .build!(rows: [ replacement ])

    assert_equal [ :created ], outcomes.map(&:status)
    assert_equal 1, @account.entries.where(external_id: "mine").count, "a row the user edited must survive"
  end

  test "a row already imported is skipped" do
    row = build_row

    assert_difference "@account.entries.count", 1 do
      build(row)
    end

    assert_no_difference "@account.entries.count" do
      outcome = MonobankImport::EntryBuilder
                  .new(family: @family, account: @account)
                  .build!(rows: [ row ])
                  .sole

      assert_equal :skipped_imported, outcome.status
    end
  end

  test "a row matching a hand-entered transaction is skipped, not duplicated" do
    row = build_row(amount: -25_000)
    existing = manual_entry(date: row.date, amount: 250)

    outcome = build(row).sole

    assert_equal :skipped_collision, outcome.status
    assert_equal existing, outcome.entry
  end

  test "the collision window reaches three days forward" do
    # Purchases get written down when noticed, sometimes two or three days after they post.
    [ -1, 2, 3 ].each do |offset|
      account = @account.entries.count
      row = build_row(amount: -25_000, id: "row#{offset}")
      manual_entry(date: row.date + offset, amount: 250)

      assert_equal :skipped_collision,
                   build(row).sole.status,
                   "offset #{offset}"
      assert_equal account + 1, @account.entries.count
    end
  end

  test "a match four days later is too far to believe" do
    row = build_row(amount: -25_000)
    manual_entry(date: row.date + 4, amount: 250)

    assert_equal :created, build(row).sole.status
  end

  test "the window barely reaches backwards, because writing a purchase down before it posts does not happen" do
    # A round-figure transfer to one bank must not absorb an unrelated transfer
    # of the same amount to another bank a few days later.
    [ -2, -3 ].each do |offset|
      row = build_row(amount: -25_000, id: "back#{offset}")
      manual_entry(date: row.date + offset, amount: 250)

      assert_equal :created,
                   build(row).sole.status,
                   "offset #{offset} should be out of range"
    end
  end

  test "the nearest candidate wins" do
    row = build_row(amount: -25_000)
    far = manual_entry(date: row.date + 3, amount: 250)
    near = manual_entry(date: row.date + 1, amount: 250)

    outcome = build(row).sole

    assert_equal near, outcome.entry
    assert_not_equal far, outcome.entry
  end

  test "a charge recorded as several same-day rows is recognised as one split" do
    # One shop charge of 3,750.00, written down by hand as two separate items.
    row = build_row(amount: -375_000)
    manual_entry(date: row.date, amount: 2_000)
    manual_entry(date: row.date, amount: 1_750)

    outcome = build(row).sole

    assert_equal :skipped_split, outcome.status
    assert_equal 'already recorded as "hand entered" + "hand entered"', outcome.detail
  end

  test "split parts have to fall on the charge's own day" do
    row = build_row(amount: -375_000)
    manual_entry(date: row.date, amount: 2_000)
    manual_entry(date: row.date + 1, amount: 1_750)

    assert_equal :created, build(row).sole.status
  end

  test "a refund plus an unrelated purchase is not read as a split" do
    # The signs differ, which is what separates this from a real split.
    row = build_row(amount: -343_036)
    manual_entry(date: row.date, amount: 3_580.36)
    manual_entry(date: row.date, amount: -150)

    assert_equal :created, build(row).sole.status
  end

  test "split parts are consumed, so they cannot explain a second charge" do
    first = build_row(amount: -375_000, id: "a")
    second = build_row(amount: -375_000, id: "b")
    manual_entry(date: first.date, amount: 2_000)
    manual_entry(date: first.date, amount: 1_750)

    outcomes = build([ first, second ])

    assert_equal [ :skipped_split, :created ], outcomes.map(&:status)
  end

  test "one hand-entered transaction can only explain one statement row" do
    first = build_row(amount: -25_000, id: "a")
    second = build_row(amount: -25_000, id: "b")
    manual_entry(date: first.date, amount: 250)

    outcomes = build([ first, second ])

    assert_equal [ :skipped_collision, :created ], outcomes.map(&:status)
  end

  test "FORCE imports a row that looks like a duplicate" do
    row = build_row(amount: -25_000)
    manual_entry(date: row.date, amount: 250)

    outcome = MonobankImport::EntryBuilder
                .new(family: @family, account: @account, force: true)
                .build!(rows: [ row ])
                .sole

    assert_equal :created, outcome.status
  end

  test "a foreign purchase records the original amount in the notes" do
    row = build_row(amount: -48_500, operation_amount: -1_000, currency_code: 978)

    outcome = build(row).sole

    assert_match(/10\.0 EUR/, outcome.entry.notes)
  end


  private
    def build_row(id: "mono-1", amount: -10_000, mcc: 5411, description: "Сільпо",
                  hold: false, operation_amount: nil, currency_code: 980, time: 1_755_594_000)
      MonobankImport::Statement.row_from(
        "id" => id,
        "time" => time,
        "description" => description,
        "mcc" => mcc,
        "hold" => hold,
        "amount" => amount,
        "operationAmount" => operation_amount || amount,
        "currencyCode" => currency_code
      )
    end

    def build(rows)
      @builder.build!(rows: Array(rows))
    end

    def manual_entry(date:, amount:)
      @account.entries.create!(
        date: date, amount: amount, currency: @account.currency,
        name: "hand entered", entryable: Transaction.new
      )
    end
end
