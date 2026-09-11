require "test_helper"

class Rule::ConditionFilter::TransactionDateTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @rule = rules(:one)
    @family = @rule.family
    @account = @family.accounts.create!(name: "Rule test", balance: 1000, currency: "USD", accountable: Depository.new)

    @before = create_transaction(date: Date.new(2017, 2, 28), account: @account, amount: 10, name: "old car")
    @on = create_transaction(date: Date.new(2017, 3, 1), account: @account, amount: 20, name: "handover day")
    @after = create_transaction(date: Date.new(2017, 3, 2), account: @account, amount: 30, name: "new car")
  end

  # The reason this filter exists: bounding the END of a rule, so two rules over
  # the same categories can hand off from one asset to the next.
  test "before excludes the boundary day" do
    assert_equal [ @before.entryable_id ], apply("<", "2017-03-01").pluck(:id)
  end

  test "on or after includes the boundary day" do
    assert_equal [ @on.entryable_id, @after.entryable_id ].sort, apply(">=", "2017-03-01").pluck(:id).sort
  end

  test "an unparseable date matches nothing instead of raising" do
    assert_empty apply("<", "not a date")
  end

  private
    def apply(operator, value)
      condition = Rule::Condition.new(rule: @rule, condition_type: "transaction_date", operator: operator, value: value)
      scope = @rule.registry.resource_scope.where(entries: { account_id: @account.id })
      condition.apply(condition.prepare(scope))
    end
end
