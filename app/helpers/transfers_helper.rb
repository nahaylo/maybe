module TransfersHelper
  # Account choices for the transfer form, grouped the way the sidebar groups
  # them: one <optgroup> per accountable type, types in Accountable::TYPES
  # order, accounts in their user-defined position within each group.
  #
  # Disabled accounts are left out to match the sidebar. Plaid-linked accounts
  # are left out because their transactions come from the sync, not from here.
  # Each option carries data-currency for the cross-currency logic in
  # transfer_form_controller.js.
  def transfer_account_options
    Current.family.accounts.manual.visible.ordered
      .group_by(&:accountable_type)
      .sort_by { |type, _| Accountable::TYPES.index(type) || Float::INFINITY }
      .map do |type, accounts|
        [
          Accountable.from_type(type).display_name,
          accounts.map { |account| [ account.name, account.id, { "data-currency" => account.currency } ] }
        ]
      end
  end
end
