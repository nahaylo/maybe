class Security < ApplicationRecord
  include Provided

  before_validation :upcase_symbols

  has_many :trades, dependent: :nullify, class_name: "Trade"
  has_many :prices, dependent: :destroy

  validates :ticker, presence: true
  validates :ticker, uniqueness: { scope: :exchange_operating_mic, case_sensitive: false }

  scope :online, -> { where(offline: false) }

  # Today's price when the provider has one, otherwise the latest price on
  # file. Without a provider (none is configured in this checkout) prices come
  # from imports and land on trade days and report dates, so "today" is
  # usually missing while a perfectly good mark from a few days ago exists.
  def current_price
    @current_price ||= find_or_fetch_price || latest_known_price
    return nil if @current_price.nil?
    Money.new(@current_price.price, @current_price.currency)
  end

  def to_combobox_option
    SynthComboboxOption.new(
      symbol: ticker,
      name: name,
      logo_url: logo_url,
      exchange_operating_mic: exchange_operating_mic,
      country_code: country_code
    )
  end

  private
    def latest_known_price
      prices.where(date: ..Date.current).order(date: :desc).first
    end

    def upcase_symbols
      self.ticker = ticker.upcase
      self.exchange_operating_mic = exchange_operating_mic.upcase if exchange_operating_mic.present?
    end
end
