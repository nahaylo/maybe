# Merchant category code (ISO 18245), as reported by the card network.
#
# Numeric rather than a select: the code space is fixed and large, only a
# handful ever appear in one ledger, and a select could only offer the ones
# already seen -- useless for the first transaction from a new kind of shop.
# Numeric operators also make ranges expressible, which matters because MCCs
# are block-allocated (5400-5499 are food stores, 5800-5899 eating places).
class Rule::ConditionFilter::TransactionMcc < Rule::ConditionFilter
  def type
    "number"
  end

  def label
    "Transaction MCC"
  end

  # The base class steps by the family currency's minor unit, which would offer
  # 0.01 increments on what is always a whole number.
  def number_step
    1
  end

  def apply(scope, operator, value)
    scope.where(build_sanitized_where_condition("transactions.mcc", operator, value.to_i))
  end
end
