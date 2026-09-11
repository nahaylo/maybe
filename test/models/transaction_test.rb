require "test_helper"

class TransactionTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @transaction = transactions(:one)
  end

  test "defaults the unit when a quantity is given without one" do
    @transaction.update!(quantity: 3)

    assert_equal "pcs", @transaction.unit
  end

  test "clears the unit when the quantity is removed" do
    @transaction.update!(quantity: 2.5, unit: "kg")
    @transaction.update!(quantity: "")

    assert_nil @transaction.reload.quantity
    assert_nil @transaction.unit
  end

  test "drops a unit supplied without a quantity" do
    @transaction.update!(unit: "kg")

    assert_nil @transaction.reload.unit
  end

  test "downcases the unit" do
    @transaction.update!(quantity: 1, unit: "KG")

    assert_equal "kg", @transaction.unit
  end

  test "rejects a non-positive quantity" do
    [ 0, -1 ].each do |quantity|
      @transaction.quantity = quantity
      assert @transaction.invalid?, "expected #{quantity} to be invalid"
    end
  end

  test "rejects an unknown unit" do
    @transaction.quantity = 1
    @transaction.unit = "furlong"

    assert @transaction.invalid?
  end

  test "quantity_display formats without trailing zeros" do
    @transaction.quantity = 2.5
    @transaction.unit = "kg"
    assert_equal "2.5 kg", @transaction.quantity_display

    @transaction.quantity = 3
    @transaction.unit = "pcs"
    assert_equal "3 pcs", @transaction.quantity_display

    @transaction.quantity = nil
    assert_nil @transaction.quantity_display
  end
end
