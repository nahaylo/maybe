require "test_helper"

class Rule::ConditionFilter::TransactionCategoryTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    # The options list reads the RULE's family, so everything has to hang off
    # the same one.
    @rule = rules(:one)
    @family = @rule.family
    @account = @family.accounts.create!(name: "Rule test", balance: 1000, currency: "USD", accountable: Depository.new)
    @grocery = @family.categories.create!(name: "Grocery")

    @uncategorized = create_transaction(date: Date.current, account: @account, amount: 10, name: "Gadget Shop case")
    @categorized = create_transaction(date: Date.current, account: @account, amount: 20, name: "Gadget Shop cover", category: @grocery)
  end

  test "matches only transactions with no category" do
    assert_equal [ @uncategorized.entryable_id ], apply(Rule::ConditionFilter::TransactionCategory::UNCATEGORIZED).pluck(:id)
  end

  test "matches a specific category" do
    assert_equal [ @categorized.entryable_id ], apply(@grocery.id).pluck(:id)
  end

  test "offers Uncategorized ahead of the family's categories" do
    options = Rule::ConditionFilter::TransactionCategory.new(@rule).options

    assert_equal [ "Uncategorized", Rule::ConditionFilter::TransactionCategory::UNCATEGORIZED ], options.first
    assert_includes options, [ "Grocery", @grocery.id ]
  end

  test "guards a name rule from rewriting an already-categorised transaction" do
    # The reason this filter exists: a merchant rule matched by name otherwise
    # reaches every transaction back to the rule's effective date, whatever
    # category they already carry.
    by_name = Rule::Condition.new(rule: @rule, condition_type: "transaction_name", operator: "like", value: "Gadget Shop")
    guard = Rule::Condition.new(rule: @rule, condition_type: "transaction_category", operator: "=",
                                value: Rule::ConditionFilter::TransactionCategory::UNCATEGORIZED)

    scope = by_name.apply(@account.transactions.with_entry)
    assert_equal 2, scope.count

    assert_equal 1, guard.apply(scope).count
  end

  private
    def apply(value)
      Rule::Condition.new(
        rule: @rule, condition_type: "transaction_category", operator: "=", value: value
      ).apply(@account.transactions)
    end
end
