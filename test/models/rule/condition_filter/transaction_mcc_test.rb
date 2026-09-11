require "test_helper"

class Rule::ConditionFilter::TransactionMccTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @rule = rules(:one)
    @family = @rule.family
    @account = @family.accounts.create!(name: "MCC test", balance: 1000, currency: "USD", accountable: Depository.new)

    @groceries = create_transaction(date: Date.current, account: @account, amount: 10, name: "Silpo")
    @groceries.entryable.update!(mcc: 5411)
    @restaurant = create_transaction(date: Date.current, account: @account, amount: 20, name: "Mangal")
    @restaurant.entryable.update!(mcc: 5812)
    @unknown = create_transaction(date: Date.current, account: @account, amount: 30, name: "Cash")
  end

  test "matches an exact code" do
    assert_equal [ @groceries.entryable_id ], apply("=", 5411).pluck(:id)
  end

  test "matches a block of codes, which is how MCCs are allocated" do
    # 5400-5499 is food stores; a range condition is the reason this filter is
    # numeric rather than a select.
    scope = apply(">=", 5400)

    assert_equal [ @groceries.entryable_id, @restaurant.entryable_id ].sort, scope.pluck(:id).sort
    assert_equal [ @groceries.entryable_id ], apply("<", 5500).pluck(:id)
  end

  test "a transaction with no MCC never matches" do
    assert_not_includes apply(">=", 0).pluck(:id), @unknown.entryable_id
  end

  test "steps by whole numbers, not currency minor units" do
    assert_equal 1, Rule::ConditionFilter::TransactionMcc.new(@rule).number_step
  end

  test "is offered as a condition on transaction rules" do
    assert_includes @rule.condition_filters.map(&:key), "transaction_mcc"
  end

  private
    def apply(operator, value)
      Rule::Condition.new(
        rule: @rule, condition_type: "transaction_mcc", operator: operator, value: value.to_s
      ).apply(@account.transactions)
    end
end
