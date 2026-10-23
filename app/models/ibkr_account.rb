# Links one currency of one Interactive Brokers account to the Maybe account
# that currency's activity lands in.
#
# An IBKR account is multi-currency; a Maybe account is not. Cash in a foreign
# currency is converted on the day it arrives and never revalued, so a EUR
# deposit sitting in a USD account drifts from IBKR's figure with every move
# in the exchange rate. Splitting by currency puts each pile of cash in an
# account of its own currency, where the balance sheet marks it at today's
# rate -- and gives a currency conversion two sides to be a transfer between.
#
# Like MonobankAccount this is a join row rather than a column on `accounts`,
# and Account#linked? stays false so the account remains fully editable.
class IbkrAccount < ApplicationRecord
  belongs_to :ibkr_item
  belongs_to :account

  before_validation :default_currency_from_account

  validates :ibkr_id, :currency, presence: true
  validates :ibkr_id, uniqueness: { scope: %i[ibkr_item_id currency] }

  validate :account_belongs_to_the_same_family
  validate :account_is_in_the_linked_currency

  scope :ordered, -> { joins(:account).merge(Account.ordered) }

  delegate :family, to: :ibkr_item

  private
    # The currency is the Maybe account's; asking for it separately would only
    # invite a mismatch.
    def default_currency_from_account
      self.currency = account.currency if currency.blank? && account.present?
      self.currency = currency.upcase if currency.present?
    end

    def account_belongs_to_the_same_family
      return if ibkr_item.nil? || account.nil?
      return if ibkr_item.family_id == account.family_id

      errors.add(:account, "belongs to a different family than the IBKR connection")
    end

    def account_is_in_the_linked_currency
      return if account.nil? || currency.blank?
      return if account.currency == currency

      errors.add(:account, "is in #{account.currency}, but this link is for #{currency}")
    end
end
