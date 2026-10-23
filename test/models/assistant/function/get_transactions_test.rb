require "test_helper"

class Assistant::Function::GetTransactionsTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @account = accounts(:depository)
  end

  # Searches are mostly about what a transaction was, so its name must come back.
  test "returns each transaction's name" do
    create_transaction(account: @account, name: "Coffee beans 1kg", amount: 25)

    result = Assistant::Function::GetTransactions.new(@user).call("search" => "Coffee beans", "order" => "desc")

    assert_equal [ "Coffee beans 1kg" ], result[:transactions].map { |row| row[:name] }
  end

  # "How many kg of coffee" needs the recorded quantity, not a guess from the name.
  test "returns the quantity and unit when one is recorded" do
    create_transaction(account: @account, name: "Coffee beans", amount: 50, quantity: 2, unit: "kg")
    create_transaction(account: @account, name: "Coffee cup", amount: 3)

    result = Assistant::Function::GetTransactions.new(@user).call("search" => "Coffee", "order" => "desc")
    rows = result[:transactions].index_by { |row| row[:name] }

    assert_equal [ 2, "kg" ], rows["Coffee beans"].values_at(:quantity, :unit)
    assert_equal [ nil, nil ], rows["Coffee cup"].values_at(:quantity, :unit)
  end
end
