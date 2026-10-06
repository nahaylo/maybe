# Every position the family holds across its investment accounts, laid out
# for a treemap: one tile per holding, sized by what it is worth now and
# coloured by how it has done against its FIFO cost, grouped by account or by
# currency.
#
# Values are converted to the family's currency so tiles from USD and EUR
# accounts are comparable in size. The return percentage is computed in the
# holding's own currency, so an exchange rate move does not show up as a
# stock move.
class Family::PortfolioMap
  GROUPINGS = %w[account currency].freeze

  Tile = Data.define(:holding, :group, :value, :native_value, :cost, :gain, :percent) do
    def ticker = holding.ticker
    def name = holding.name
    def weight(total) = total.zero? ? 0 : (value.amount / total.amount * 100).round(1)
  end

  Group = Data.define(:name, :tiles) do
    def value = tiles.sum(&:value)
  end

  attr_reader :family, :group_by

  def initialize(family, group_by: "account")
    @family = family
    @group_by = GROUPINGS.include?(group_by.to_s) ? group_by.to_s : GROUPINGS.first
  end

  def currency = family.currency

  def accounts
    family.accounts.visible.where(accountable_type: "Investment").order(:name)
  end

  def tiles
    @tiles ||= accounts.flat_map do |account|
      account.current_holdings.includes(:security).filter_map { |holding| tile_for(account, holding) }
    end
  end

  def groups
    tiles.group_by(&:group)
         .map { |name, group_tiles| Group.new(name: name, tiles: group_tiles.sort_by { |t| -t.value.amount }) }
         .sort_by { |group| -group.value.amount }
  end

  def empty? = tiles.empty?

  def total_value = tiles.sum(money(0), &:value)
  def total_cost = tiles.sum(money(0), &:cost)
  def total_gain = total_value - total_cost

  def total_trend
    Trend.new(current: total_value, previous: total_cost)
  end

  # What the chart controller draws: groups of tiles, amounts as plain
  # numbers, labels already formatted on the server.
  def as_tree(url_for_holding:)
    total = total_value

    {
      name: "Portfolio",
      children: groups.map do |group|
        {
          name: group.name,
          value_label: group.value.format,
          children: group.tiles.map do |tile|
            {
              ticker: tile.ticker,
              name: tile.name,
              value: tile.value.amount.to_f,
              value_label: tile.value.format,
              native_label: tile.native_value.currency.iso_code == currency ? nil : tile.native_value.format,
              gain_label: tile.gain&.format,
              percent: tile.percent&.to_f,
              weight: tile.weight(total).to_f,
              url: url_for_holding.call(tile.holding)
            }
          end
        }
      end
    }
  end

  private
    def tile_for(account, holding)
      return nil if holding.amount.to_d <= 0

      native_value = holding.amount_money
      performance = holding.performance
      native_cost = performance.open? ? performance.cost_basis : nil
      percent = native_cost && native_cost.amount.positive? ? ((native_value.amount - native_cost.amount) / native_cost.amount * 100).round(1) : nil

      Tile.new(
        holding: holding,
        group: group_by == "currency" ? native_value.currency.iso_code : account.name,
        value: convert(native_value),
        native_value: native_value,
        cost: native_cost ? convert(native_cost) : convert(native_value),
        gain: native_cost ? convert(native_value - native_cost) : nil,
        percent: percent
      )
    end

    def convert(amount)
      amount.exchange_to(currency, fallback_rate: 1)
    end

    def money(amount) = Money.new(amount, currency)
end
