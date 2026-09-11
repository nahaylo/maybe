require "test_helper"
require "ostruct"

class AccountConversionTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
  end

  test "converts to another type and keeps all history" do
    create_transaction(account: @account, amount: 100)
    create_transaction(account: @account, amount: -50)
    @account.update!(position: 3)
    entries = @account.entries.count
    balance = @account.balance

    assert @account.convert_to!("Deposit")
    @account.reload

    assert_equal "Deposit", @account.accountable_type
    assert_equal entries, @account.entries.count
    assert_equal balance, @account.balance
    assert_equal 3, @account.position
  end

  # Nothing lives on the accountable, but the old row must not be orphaned.
  test "destroys the previous accountable row" do
    old_id = @account.accountable_id

    @account.convert_to!("Business")

    assert_not Depository.exists?(old_id)
    assert Business.exists?(@account.reload.accountable_id)
  end

  test "clears subtype, which is defined per type" do
    @account.update!(subtype: "checking")

    @account.convert_to!("Deposit")

    assert_nil @account.reload.subtype
  end

  test "returns false when already that type, without touching the record" do
    accountable_id = @account.accountable_id

    assert_not @account.convert_to!("Depository")
    assert_equal accountable_id, @account.reload.accountable_id
  end

  test "rejects an unknown type" do
    assert_raises(ArgumentError) { @account.convert_to!("Nonsense") }
    assert_equal "Depository", @account.reload.accountable_type
  end

  test "refuses to convert a linked account" do
    linked = accounts(:connected)

    assert linked.linked?
    assert_raises(ArgumentError) { linked.convert_to!("Deposit") }
    assert_not linked.convertible?
  end

  # An unlisted type raises in balance_type, which would break every balance calc.
  test "every registered type has a liquidity classification" do
    Accountable::TYPES.each do |type|
      balance_type = begin
        Account.new(accountable_type: type).balance_type
      rescue StandardError => e
        flunk "#{type} is missing from Account#balance_type (#{e.message})"
      end

      assert_includes %i[cash non_cash investment], balance_type, "#{type} has an unexpected balance type"
    end
  end

  test "new types are registered and usable" do
    %w[Deposit Business].each do |type|
      assert_includes Accountable::TYPES, type
      klass = Accountable.from_type(type)
      assert_equal "asset", klass.classification
      assert klass.color.present?
      assert klass.icon.present?
    end
  end
end
