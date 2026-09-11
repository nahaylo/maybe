# Marks matching transactions as spent on behalf of an asset account (a vehicle
# or a property) without moving any money. Mirrors SetTransactionCategory:
# user edits lock the attribute, and locked rows are skipped.
class Rule::ActionExecutor::AttributeToAccount < Rule::ActionExecutor
  def type
    "select"
  end

  def options
    family.accounts.attributable.alphabetically.pluck(:name, :id)
  end

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false)
    # A disabled account drops out of `attributable`, so a rule that still
    # points at a car you no longer own becomes a no-op instead of tagging new
    # spending onto it.
    account = family.accounts.attributable.find_by_id(value)
    return if account.nil?

    scope = transaction_scope
    scope = scope.enrichable(:attributed_account_id) unless ignore_attribute_locks

    scope.each do |txn|
      txn.enrich_attribute(:attributed_account_id, account.id, source: "rule")
    end
  end
end
