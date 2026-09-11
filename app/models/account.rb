class Account < ApplicationRecord
  include AASM, Syncable, Monetizable, Chartable, Linkable, Enrichable, Anchorable, Reconcileable

  SEPARATOR = " · ".freeze

  # Icons a user can pick for an account, from the vendored lucide set. Ordered
  # banking-first, since that is what most accounts are. A nil pick falls back
  # to the accountable type's own icon -- see #icon.
  ICON_CODES = %w[
    landmark building-2 vault wallet wallet-minimal wallet-cards banknote coins
    piggy-bank credit-card hand-coins badge-dollar-sign circle-dollar-sign receipt
    chart-line chart-candlestick chart-pie trending-up bitcoin gem briefcase target rocket
    house building car-front bike bus train-front plane ship fuel wrench hammer
    smartphone laptop monitor shield star heart gift graduation-cap baby dog cat
    users user id-card key lock umbrella sprout leaf trees sun zap plug droplet
    flame cloud globe flag bookmark tag utensils shopping-cart pill dumbbell
    ticket music gamepad-2 book
  ].freeze

  # Colors a user can pick for an account: the design system's 500-level ramp
  # (maybe-design-system.css), which is where most of the Accountable defaults
  # already come from. A nil pick falls back to the type's own color -- see #color.
  COLORS = %w[
    #737373 #F13636 #FF4405 #F79009 #12B76A #06AED4
    #2E90FA #6172F3 #875BF7 #D444F1 #F23E94
  ].freeze

  # "" comes back from each picker's "use the default" radio; store it as NULL so
  # #icon and #color's presence checks are the only place the fallback lives.
  normalizes :lucide_icon, with: ->(code) { code.presence }
  normalizes :custom_color, with: ->(hex) { hex.presence }

  validates :name, :balance, :currency, presence: true
  validates :lucide_icon, inclusion: { in: ICON_CODES }, allow_nil: true
  validates :custom_color, inclusion: { in: COLORS }, allow_nil: true

  belongs_to :family
  belongs_to :import, optional: true

  has_many :import_mappings, as: :mappable, dependent: :destroy, class_name: "Import::Mapping"
  has_many :entries, dependent: :destroy
  has_many :transactions, through: :entries, source: :entryable, source_type: "Transaction"
  has_many :valuations, through: :entries, source: :entryable, source_type: "Valuation"
  has_many :trades, through: :entries, source: :entryable, source_type: "Trade"
  # Spending elsewhere that served this asset (see Transaction#attributed_account).
  has_many :attributed_transactions, class_name: "Transaction", foreign_key: :attributed_account_id, dependent: :nullify
  has_many :holdings, dependent: :destroy
  has_many :balances, dependent: :destroy

  monetize :balance, :cash_balance

  enum :classification, { asset: "asset", liability: "liability" }, validate: { allow_nil: true }

  scope :visible, -> { where(status: [ "draft", "active" ]) }
  scope :assets, -> { where(classification: "asset") }
  scope :liabilities, -> { where(classification: "liability") }

  # The order accounts are listed in everywhere. `position` is user-controlled
  # (drag to reorder on /accounts); :name only breaks ties for rows that have no
  # position yet.
  scope :ordered, -> { order(:position, :name) }

  scope :alphabetically, -> {
    order(
      Arel.sql(ActiveRecord::Base.sanitize_sql_array([ <<~SQL.squish, SEPARATOR ])) # rubocop:disable Rails/RelationExplicitOrder
        split_part(accounts.name, ?, 1) ASC,
        (accounts.currency <> (SELECT families.currency FROM families WHERE families.id = accounts.family_id)) ASC,
        accounts.currency ASC,
        accounts.name ASC
      SQL
    )
  }
  scope :manual, -> { where(plaid_account_id: nil) }
  # Assets that spending can be attributed to.
  scope :attributable, -> { visible.where(accountable_type: %w[Vehicle Property]) }

  has_one_attached :logo

  # New accounts land at the end of the family's manual order rather than at a
  # NULL position, which would sort them last-but-untracked.
  before_create :assign_default_position

  delegated_type :accountable, types: Accountable::TYPES, dependent: :destroy

  accepts_nested_attributes_for :accountable, update_only: true

  # Account state machine
  aasm column: :status, timestamps: true do
    state :active, initial: true
    state :draft
    state :disabled
    state :pending_deletion

    event :activate do
      transitions from: [ :draft, :disabled ], to: :active
    end

    event :disable do
      transitions from: [ :draft, :active ], to: :disabled
    end

    event :enable do
      transitions from: :disabled, to: :active
    end

    event :mark_for_deletion do
      transitions from: [ :draft, :active, :disabled ], to: :pending_deletion
    end
  end

  class << self
    def create_and_sync(attributes)
      attributes[:accountable_attributes] ||= {} # Ensure accountable is created, even if empty
      account = new(attributes.merge(cash_balance: attributes[:balance]))
      initial_balance = attributes.dig(:accountable_attributes, :initial_balance)&.to_d

      transaction do
        account.save!

        manager = Account::OpeningBalanceManager.new(account)
        result = manager.set_opening_balance(balance: initial_balance || account.balance)
        raise result.error if result.error
      end

      account.sync_later
      account
    end
  end

  # The glyph to draw for this account: the user's pick, else the accountable
  # type's default (Depository -> "landmark", Vehicle -> "car-front").
  def icon
    lucide_icon.presence || accountable.icon
  end

  # The hex to tint this account with: the user's pick, else the accountable
  # type's default (Depository -> "#875BF7").
  #
  # The raw pick lives in `custom_color` rather than a `color` column on purpose.
  # Naming the column `color` would force this method to shadow the attribute
  # reader, and `validates :color, inclusion:` reads through the reader -- so
  # every account with no pick would validate its *type default* against COLORS
  # and fail.
  def color
    custom_color.presence || accountable.color
  end

  def institution_domain
    url_string = plaid_account&.plaid_item&.institution_url
    return nil unless url_string.present?

    begin
      uri = URI.parse(url_string)
      # Use safe navigation on .host before calling gsub
      uri.host&.gsub(/^www\./, "")
    rescue URI::InvalidURIError
      # Log a warning if the URL is invalid and return nil
      Rails.logger.warn("Invalid institution URL encountered for account #{id}: #{url_string}")
      nil
    end
  end

  def destroy_later
    mark_for_deletion!
    DestroyJob.perform_later(self)
  end

  # Override destroy to handle error recovery for accounts
  def destroy
    super
  rescue => e
    # If destruction fails, transition back to disabled state
    # This provides a cleaner recovery path than the generic scheduled_for_deletion flag
    disable! if may_disable?
    raise e
  end

  def current_holdings
    holdings.where(currency: currency)
            .where.not(qty: 0)
            .where(
              id: holdings.select("DISTINCT ON (security_id) id")
                          .where(currency: currency)
                          .order(:security_id, date: :desc)
            )
            .order(amount: :desc)
  end

  def start_date
    first_entry_date = entries.minimum(:date) || Date.current
    first_entry_date - 1.day
  end

  def lock_saved_attributes!
    super
    accountable.lock_saved_attributes!
  end

  def first_valuation
    entries.valuations.order(:date).first
  end

  def first_valuation_amount
    first_valuation&.amount_money || balance_money
  end

  # Get short version of the subtype label
  # Moves an account to a different accountable type. Nothing real lives on the
  # accountable -- entries, balances and holdings all belong to the account -- so
  # this swaps the type row and keeps the entire history.
  #
  # Subtype is cleared because subtypes are defined per accountable type, and a
  # value from the old type would silently fall back to the type's display name.
  def convert_to!(new_accountable_type)
    raise ArgumentError, "Unknown account type: #{new_accountable_type}" unless Accountable::TYPES.include?(new_accountable_type)
    raise ArgumentError, "Cannot change the type of a linked account" if linked?
    return false if accountable_type == new_accountable_type

    previous = accountable

    transaction do
      update!(accountable: new_accountable_type.constantize.new, subtype: nil)
      previous.destroy!
    end

    true
  end

  def convertible?
    !linked?
  end

  def short_subtype_label
    accountable_class.short_subtype_label_for(subtype) || accountable_class.display_name
  end

  # Get long version of the subtype label
  def long_subtype_label
    accountable_class.long_subtype_label_for(subtype) || accountable_class.display_name
  end

  # The balance type determines which "component" of balance is being tracked.
  # This is primarily used for balance related calculations and updates.
  #
  # "Cash" = "Liquid"
  # "Non-cash" = "Illiquid"
  # "Investment" = A mix of both, including brokerage cash (liquid) and holdings (illiquid)
  def balance_type
    case accountable_type
    when "Depository", "Deposit", "Business", "CreditCard"
      :cash
    when "Property", "Vehicle", "OtherAsset", "Loan", "OtherLiability"
      :non_cash
    when "Investment", "Crypto"
      :investment
    else
      raise "Unknown account type: #{accountable_type}"
    end
  end

  private
    def assign_default_position
      self.position ||= (family&.accounts&.maximum(:position) || 0) + 1
    end
end
