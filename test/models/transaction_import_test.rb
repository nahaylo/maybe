require "test_helper"

class TransactionImportTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper, ImportInterfaceTest

  setup do
    @subject = @import = imports(:transaction)
  end

  test "uploaded? if raw_file_str is present" do
    @import.expects(:raw_file_str).returns("test").once
    assert @import.uploaded?
  end

  test "configured? if uploaded and rows are generated" do
    @import.expects(:uploaded?).returns(true).once
    assert @import.configured?
  end

  test "cleaned? if rows are generated and valid" do
    @import.expects(:configured?).returns(true).once
    assert @import.cleaned?
  end

  test "publishable? if cleaned and mappings are valid" do
    @import.expects(:cleaned?).returns(true).once
    assert @import.publishable?
  end

  test "imports transactions, categories, tags, and accounts" do
    import = <<~CSV
      date,name,amount,category,tags,account,notes
      01/01/2024,Txn1,100,TestCategory1,TestTag1,TestAccount1,notes1
      01/02/2024,Txn2,200,TestCategory2,TestTag1|TestTag2,TestAccount2,notes2
      01/03/2024,Txn3,300,,,,notes3
    CSV

    @import.update!(
      raw_file_str: import,
      date_col_label: "date",
      amount_col_label: "amount",
      date_format: "%m/%d/%Y"
    )

    @import.generate_rows_from_csv

    @import.mappings.create! key: "TestCategory1", create_when_empty: true, type: "Import::CategoryMapping"
    @import.mappings.create! key: "TestCategory2", mappable: categories(:food_and_drink), type: "Import::CategoryMapping"
    @import.mappings.create! key: "", create_when_empty: false, mappable: nil, type: "Import::CategoryMapping" # Leaves uncategorized

    @import.mappings.create! key: "TestTag1", create_when_empty: true, type: "Import::TagMapping"
    @import.mappings.create! key: "TestTag2", mappable: tags(:one), type: "Import::TagMapping"
    @import.mappings.create! key: "", create_when_empty: false, mappable: nil, type: "Import::TagMapping" # Leaves untagged

    @import.mappings.create! key: "TestAccount1", create_when_empty: true, type: "Import::AccountMapping"
    @import.mappings.create! key: "TestAccount2", mappable: accounts(:depository), type: "Import::AccountMapping"
    @import.mappings.create! key: "", mappable: accounts(:depository), type: "Import::AccountMapping"

    @import.reload

    assert_difference -> { Entry.count } => 3,
                      -> { Transaction.count } => 3,
                      -> { Tag.count } => 1,
                      -> { Category.count } => 1,
                      -> { Account.count } => 1 do
      @import.publish
    end

    assert_equal "complete", @import.status
  end

  test "imports quantity and unit" do
    import = <<~CSV
      date,name,amount,qty,unit
      01/01/2024,Groceries,100,2.5,kg
      01/02/2024,Coffee,20,3,PCS
      01/03/2024,Rent,300,,
    CSV

    @import.update!(
      account: accounts(:depository),
      raw_file_str: import,
      date_col_label: "date",
      amount_col_label: "amount",
      name_col_label: "name",
      qty_col_label: "qty",
      unit_col_label: "unit",
      date_format: "%m/%d/%Y"
    )

    @import.generate_rows_from_csv
    @import.reload

    assert @import.cleaned?

    @import.publish
    assert_equal "complete", @import.status

    by_name = Entry.where(import: @import).index_by(&:name)
    assert_equal 3, by_name.size

    assert_equal 2.5, by_name["Groceries"].transaction.quantity
    assert_equal "kg", by_name["Groceries"].transaction.unit

    assert_equal 3, by_name["Coffee"].transaction.quantity
    assert_equal "pcs", by_name["Coffee"].transaction.unit

    assert_nil by_name["Rent"].transaction.quantity
    assert_nil by_name["Rent"].transaction.unit
  end

  test "flags rows with an unknown unit instead of failing the publish" do
    import = <<~CSV
      date,name,amount,qty,unit
      01/01/2024,Groceries,100,2.5,furlong
    CSV

    @import.update!(
      account: accounts(:depository),
      raw_file_str: import,
      date_col_label: "date",
      amount_col_label: "amount",
      name_col_label: "name",
      qty_col_label: "qty",
      unit_col_label: "unit",
      date_format: "%m/%d/%Y"
    )

    @import.generate_rows_from_csv
    @import.reload

    assert_not @import.cleaned?
    assert_match(/must be one of/, @import.rows.first.errors.full_messages.to_sentence)
  end

  test "imports transactions with separate type column for signage convention" do
    import = <<~CSV
      date,amount,amount_type
      01/01/2024,100,debit
      01/02/2024,200,credit
      01/03/2024,300,debit
    CSV

    @import.update!(
      account: accounts(:depository),
      raw_file_str: import,
      date_col_label: "date",
      date_format: "%m/%d/%Y",
      amount_col_label: "amount",
      entity_type_col_label: "amount_type",
      amount_type_inflow_value: "debit",
      amount_type_strategy: "custom_column",
      signage_convention: nil # Explicitly set to nil to prove this is not needed
    )

    @import.generate_rows_from_csv

    @import.reload

    assert_difference -> { Entry.count } => 3,
                      -> { Transaction.count } => 3 do
      @import.publish
    end

    assert_equal [ -100, 200, -300 ], @import.entries.map(&:amount)
  end
end
