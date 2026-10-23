class Transaction < ApplicationRecord
  include Entryable, Transferable, Ruleable

  belongs_to :category, optional: true
  belongs_to :merchant, optional: true
  # The holding a cash row belongs to: a dividend, its withholding tax, a
  # trade's commission. Set by importers; nil for ordinary transactions.
  belongs_to :security, optional: true
  # The asset this spend served (a vehicle, a property). Pure metadata: the
  # money stays in the paying account and no balance changes.
  belongs_to :attributed_account, class_name: "Account", optional: true

  has_many :taggings, as: :taggable, dependent: :destroy
  has_many :tags, through: :taggings

  accepts_nested_attributes_for :taggings, allow_destroy: true

  enum :kind, {
    standard: "standard", # A regular transaction, included in budget analytics
    funds_movement: "funds_movement", # Movement of funds between accounts, excluded from budget analytics
    cc_payment: "cc_payment", # A CC payment, excluded from budget analytics (CC payments offset the sum of expense transactions)
    loan_payment: "loan_payment", # A payment to a Loan account, treated as an expense in budgets
    one_time: "one_time", # A one-time expense/income, excluded from budget analytics
    # Income and costs thrown off by an investment account's holdings: dividends,
    # withholding tax, interest, fees, commissions. Counted as ordinary income
    # and expense, but never a transfer -- see Family::AutoTransferMatchable.
    investment_activity: "investment_activity"
  }

  # Units of measure a transaction quantity can be expressed in. Keys are the
  # stored codes (short, stable, CSV-safe, and used verbatim for display);
  # values are the disambiguating labels shown in the select.
  UNITS = {
    "pcs" => "Pieces (pcs)",
    "kg" => "Kilograms (kg)",
    "g" => "Grams (g)",
    "lb" => "Pounds (lb)",
    "oz" => "Ounces (oz)",
    "l" => "Litres (l)",
    "ml" => "Millilitres (ml)",
    "gal" => "Gallons (gal)",
    "m" => "Metres (m)",
    "cm" => "Centimetres (cm)",
    "ft" => "Feet (ft)"
  }.freeze

  validates :quantity, numericality: { greater_than: 0 }, allow_nil: true
  validates :unit, inclusion: { in: UNITS.keys }, allow_nil: true

  before_validation :normalize_quantity_and_unit
  validate :attributed_account_in_same_family

  def self.unit_options
    UNITS.map { |code, label| [ label, code ] }
  end

  # "2.5 kg", "3 pcs", or nil when no quantity is recorded.
  def quantity_display
    return nil if quantity.blank?

    formatted = quantity.frac.zero? ? quantity.to_i : quantity.to_s("F")
    [ formatted, unit ].compact.join(" ")
  end

  # Overarching grouping method for all transfer-type transactions
  def transfer?
    funds_movement? || cc_payment? || loan_payment?
  end

  def set_category!(category)
    if category.is_a?(String)
      category = entry.account.family.categories.find_or_create_by!(
        name: category
      )
    end

    update!(category: category)
  end

  private
    def attributed_account_in_same_family
      return if attributed_account.nil? || entry&.account.nil?
      return if attributed_account.family_id == entry.account.family_id

      errors.add(:attributed_account, "must belong to the same family")
    end

    # The two fields are kept consistent by normalizing rather than by a
    # cross-field validation. The edit drawer auto-submits on every field
    # change, so a "both or neither" rule would 422 the moment a unit is
    # picked before a quantity is typed.
    def normalize_quantity_and_unit
      self.quantity = nil if quantity.blank?
      self.unit = unit.presence&.downcase

      if quantity.nil?
        self.unit = nil
      elsif unit.blank?
        self.unit = UNITS.keys.first
      end
    end
end
