# Bounds a rule by transaction date. `effective_date` already gives every rule
# a start; this adds the end, which is what lets two rules over the same
# categories hand off from one asset to the next (a sold car to its
# replacement) without fighting over the rows in between.
class Rule::ConditionFilter::TransactionDate < Rule::ConditionFilter
  def type
    "date"
  end

  def prepare(scope)
    scope.with_entry
  end

  def apply(scope, operator, value)
    date = Date.parse(value.to_s)
    scope.where(build_sanitized_where_condition("entries.date", operator, date))
  rescue Date::Error
    # An unparseable date matches nothing rather than aborting the whole sync.
    scope.none
  end
end
