class Holding < ApplicationRecord
  include Monetizable, Gapfillable

  monetize :amount

  belongs_to :account
  belongs_to :security

  validates :qty, :currency, :date, :price, :amount, presence: true
  validates :qty, :price, :amount, numericality: { greater_than_or_equal_to: 0 }

  scope :chronological, -> { order(:date) }
  scope :for, ->(security) { where(security_id: security).order(:date) }

  delegate :ticker, to: :security

  def name
    security.name || ticker
  end

  def weight
    return nil unless amount
    return 0 if amount.zero?

    account.balance.zero? ? 1 : amount / account.balance * 100
  end

  # FIFO lots, realised and unrealised gains, dividends and fees for this
  # security in this account -- see Holding::Performance.
  def performance
    @performance ||= Holding::Performance.new(account, security)
  end

  # Cost per share of the shares actually held, FIFO. The previous figure was
  # the plain average of every buy price ever, which blended sold lots into
  # the current position.
  def avg_cost
    performance.open? ? performance.cost_basis_per_share : Money.new(price, currency)
  end

  # Unrealised gain on the current position.
  def trend
    performance.unrealized
  end

  def trades
    account.entries.where(entryable: account.trades.where(security: security)).reverse_chronological
  end

  def destroy_holding_and_entries!
    transaction do
      account.entries.where(entryable: account.trades.where(security: security)).destroy_all
      destroy
    end

    account.sync_later
  end
end
