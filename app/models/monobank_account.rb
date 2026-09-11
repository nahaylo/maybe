# Links one Monobank account to the Maybe account its transactions land in.
#
# Deliberately a join row rather than a column on `accounts`: Plaid puts
# `plaid_account_id` on the account because the whole app reads it (the `manual`
# scope, Account#linked?, several views). Nothing outside the importer asks
# whether an account is a Monobank one, so nothing outside the importer needs to
# carry the field.
#
# A consequence worth knowing: Account#linked? stays false for these, so balance
# editing and manual entries stay enabled in the UI. That is correct -- the
# importer writes transactions but does not own the balance.
class MonobankAccount < ApplicationRecord
  belongs_to :monobank_item
  belongs_to :account

  validates :monobank_id, presence: true
  validates :monobank_id, uniqueness: { scope: :monobank_item_id }

  validate :account_belongs_to_the_same_family

  scope :ordered, -> { joins(:account).merge(Account.ordered) }

  delegate :family, to: :monobank_item

  private
    def account_belongs_to_the_same_family
      return if monobank_item.nil? || account.nil?
      return if monobank_item.family_id == account.family_id

      errors.add(:account, "belongs to a different family than the Monobank connection")
    end
end
