# Lets a rule test what category a transaction already has -- in particular
# "Uncategorized", which is how a rule says "fill this in only if nothing else
# already did".
#
# Without it, a rule overwrites whatever category a transaction already carries
# unless the user has explicitly locked it. That is fine for a rule written
# today against today's data, but a merchant rule matched by name reaches every
# transaction back to `effective_date`. A short name like "Cafe" can match
# years of hand-categorised rows spread across several categories, of which
# only the freshly imported ones should be touched.
class Rule::ConditionFilter::TransactionCategory < Rule::ConditionFilter
  UNCATEGORIZED = "uncategorized".freeze

  def type
    "select"
  end

  def label
    "Transaction category"
  end

  def options
    [ [ "Uncategorized", UNCATEGORIZED ] ] + family.categories.order(:name).pluck(:name, :id)
  end

  def apply(scope, operator, value)
    return scope.where(transactions: { category_id: nil }) if value == UNCATEGORIZED

    scope.where(build_sanitized_where_condition("transactions.category_id", operator, value))
  end
end
