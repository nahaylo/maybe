class EntrySearch
  include ActiveModel::Model
  include ActiveModel::Attributes

  # Transaction kinds the "transfer" bucket of the type filter covers. The
  # remaining kinds (standard, one_time, investment_activity) fall into income
  # or expense by sign, so the three buckets partition every transaction
  # exactly once.
  TRANSFER_KINDS = %w[funds_movement cc_payment loan_payment].freeze

  # The type filter's buckets. The first three partition transactions; "trade"
  # is the buys and sells of an investment account, which are neither income
  # nor expense -- a buy moves cash into holdings, nothing leaves the account.
  TRANSACTION_TYPES = %w[income expense transfer].freeze
  TYPES = (TRANSACTION_TYPES + %w[trade]).freeze

  attribute :search, :string
  attribute :amount, :string
  attribute :amount_operator, :string
  attribute :types, array: true
  attribute :accounts, array: true
  attribute :account_ids, array: true
  attribute :start_date, :string
  attribute :end_date, :string

  class << self
    def apply_search_filter(scope, search)
      return scope if search.blank?

      query = scope
      query = query.where("entries.name ILIKE :search",
        search: "%#{ActiveRecord::Base.sanitize_sql_like(search)}%"
      )
      query
    end

    def apply_date_filters(scope, start_date, end_date)
      return scope if start_date.blank? && end_date.blank?

      query = scope
      query = query.where("entries.date >= ?", start_date) if start_date.present?
      query = query.where("entries.date <= ?", end_date) if end_date.present?
      query
    end

    def apply_amount_filter(scope, amount, amount_operator)
      return scope if amount.blank? || amount_operator.blank?

      query = scope

      case amount_operator
      when "equal"
        query = query.where("ABS(ABS(entries.amount) - ?) <= 0.01", amount.to_f.abs)
      when "less"
        query = query.where("ABS(entries.amount) < ?", amount.to_f.abs)
      when "greater"
        query = query.where("ABS(entries.amount) > ?", amount.to_f.abs)
      end

      query
    end

    # SQL for the income / expense / transfer buckets behind the type filter,
    # shared by the global transaction list and the per-account activity feed.
    # Returns nil when the selection means "every transaction" -- nothing
    # selected, or all three transaction buckets selected -- and "FALSE" when
    # only "trade" is selected, so no transaction qualifies. Callers must have
    # `transactions` joined.
    def type_condition(types)
      return nil if types.blank?

      selected = types & TRANSACTION_TYPES
      return nil if selected.sort == TRANSACTION_TYPES.sort
      return "FALSE" if selected.empty?

      transfer = ActiveRecord::Base.sanitize_sql_array([ "transactions.kind IN (?)", TRANSFER_KINDS ])
      expense = "entries.amount >= 0"
      income = "entries.amount < 0"

      case selected.sort
      when [ "transfer" ]            then transfer
      when [ "expense" ]             then "#{expense} AND NOT (#{transfer})"
      when [ "income" ]              then "#{income} AND NOT (#{transfer})"
      when [ "expense", "transfer" ] then "#{expense} OR #{transfer}"
      when [ "income", "transfer" ]  then "#{income} OR #{transfer}"
      when [ "expense", "income" ]   then "NOT (#{transfer})"
      end
    end

    # For scopes based on `entries`, where a row may be a Trade or a Valuation as
    # well as a Transaction. Trades have their own bucket and are shown only
    # when it is selected. Valuations and mileage are balance anchors, not
    # activity of any type, so the filter leaves them visible rather than
    # bucketing them by amount sign.
    def apply_type_filter(scope, types)
      selected = Array(types) & TYPES
      return scope if selected.empty? || selected.sort == TYPES.sort

      transaction_condition = type_condition(selected)

      clauses = [ "entries.entryable_type NOT IN ('Transaction', 'Trade')" ]
      clauses << "entries.entryable_type = 'Trade'" if selected.include?("trade")

      unless transaction_condition == "FALSE"
        clauses << if transaction_condition.nil?
          "entries.entryable_type = 'Transaction'"
        else
          "(entries.entryable_type = 'Transaction' AND (#{transaction_condition}))"
        end
      end

      scope
        .joins(
          "LEFT JOIN transactions ON transactions.id = entries.entryable_id " \
          "AND entries.entryable_type = 'Transaction'"
        )
        .where(clauses.join(" OR "))
    end

    def apply_accounts_filter(scope, accounts, account_ids)
      return scope if accounts.blank? && account_ids.blank?

      query = scope
      query = query.where(accounts: { name: accounts }) if accounts.present?
      query = query.where(accounts: { id: account_ids }) if account_ids.present?
      query
    end
  end

  def build_query(scope)
    query = scope.joins(:account)
    query = self.class.apply_search_filter(query, search)
    query = self.class.apply_type_filter(query, types)
    query = self.class.apply_date_filters(query, start_date, end_date)
    query = self.class.apply_amount_filter(query, amount, amount_operator)
    query = self.class.apply_accounts_filter(query, accounts, account_ids)
    query
  end
end
