# Orchestrates an IBKR pull: fetch the Flex report, split it per IBKR account,
# route each row to the Maybe account of its currency, build, report.
#
# Work is organised by connection (IbkrItem): one token runs one query, and
# that query's report carries every IBKR account the query covers. The report
# is fetched once per connection; each IBKR account takes its own slice, and
# its links (one per currency) say where the rows go.
#
# Everything that touches the network goes through IbkrImport::Statement,
# which caches by day, so a dry run and the real run that follows it cost one
# request between them -- see IbkrImport::Cache.
class IbkrImport::Importer
  Report = Data.define(:ibkr_id, :links, :outcomes, :prices, :from, :to, :anchored) do
    def accounts = links.map(&:account)
    def created = outcomes.select(&:created?)
    def by_status = outcomes.group_by(&:status).transform_values(&:size)
    def unsupported = outcomes.select { |o| o.status == :skipped_unsupported }

    # Currencies the report books money in that have no account to go to.
    def missing_currencies
      outcomes.select { |o| o.status == :skipped_no_account }
              .map { |o| o.detail[/no (\w+) account/, 1] }
              .compact.uniq.sort
    end

    # Whether the accounts need a sync afterwards: new entries, new prices
    # that revalue the holdings they already have, or an opening anchor that
    # moved to let older history count.
    def changed? = created.any? || prices.positive? || anchored.any?

    # A sync after the anchor moved must start from it, not from the report.
    def sync_window_start(account) = anchored.key?(account) ? nil : (from && from - 1)
  end

  attr_reader :family, :io, :cache, :date

  # @param items [Array<IbkrItem>, nil] defaults to the family's connections
  # @param date [Date] the day the report is cached under; today in practice
  def initialize(family:, io: $stdout, cache: IbkrImport::Cache.new, items: nil, date: Date.current)
    @family = family
    @io = io
    @cache = cache
    @items = items
    @date = date
    @statements = {}
    @parsed = {}
  end

  def items
    @items ||= IbkrItem.where(family: family).ordered.to_a
  end

  # Every link across every connection, in the family's account order.
  def links
    @links ||= IbkrAccount
                 .where(ibkr_item: items)
                 .joins(:account).merge(Account.ordered)
                 .preload(:account, :ibkr_item)
                 .to_a
  end

  # Lists the IBKR accounts each connection's report covers, the currencies
  # they book money in, and which of those are linked.
  def accounts!
    if items.empty?
      raise IbkrImport::Error,
            "no IBKR connection configured -- run `rails ibkr:connect NAME=... TOKEN=... QUERY=...`"
    end

    items.flat_map { |item| print_accounts(item) }
  end

  # @param only [Array<String>, nil] IBKR account ids to restrict the run to
  # @return [Array<Report>] one per IBKR account that has at least one link
  def import!(force: false, only: nil)
    groups = links.group_by { |link| [ link.ibkr_item, link.ibkr_id ] }
    groups = groups.select { |(_, ibkr_id), _| only.include?(ibkr_id) } if only.present?

    if groups.empty?
      io.puts "nothing to import -- no linked accounts (see `rails ibkr:items`)"
      return []
    end

    io.puts "ibkr import#{force ? ' (FORCE)' : ''}"

    reports = groups.map { |(item, ibkr_id), group_links| import_one(item, ibkr_id, group_links, force: force) }
    print_unsupported_notice(reports)
    reports
  end

  def statement_for(item)
    @statements[item.id] ||= IbkrImport::Statement.new(
      provider: item.provider, cache: cache, scope: item.cache_scope
    )
  end

  # One report per connection per run, however many accounts it covers.
  def parsed_for(item)
    @parsed[item.id] ||= statement_for(item).fetch(query_id: item.query_id, date: date)
  end

  private
    def import_one(item, ibkr_id, group_links, force:)
      parsed = parsed_for(item).for_account(ibkr_id)
      statement_account = parsed.accounts.first

      if statement_account.nil?
        io.puts "\n#{ibkr_id} -- not in this report. " \
                "Check the Flex Query includes the account, or the id (see `rails ibkr:accounts`)."
        return Report.new(ibkr_id: ibkr_id, links: group_links, outcomes: [], prices: 0, from: nil, to: nil, anchored: {})
      end

      builder = IbkrImport::EntryBuilder.new(
        family: family,
        accounts: group_links.to_h { |link| [ link.currency, link.account ] },
        force: force
      )
      # Prices first: a split in the same statement carries the last price
      # across the split day, and the trade-day closes are that last price.
      prices = builder.record_prices!(positions: parsed.positions, trades: parsed.trades)
      outcomes = builder.build!(trades: parsed.trades, cash: parsed.cash, lots: parsed.lots,
                                corporate_actions: parsed.corporate_actions)

      report = Report.new(
        ibkr_id: ibkr_id, links: group_links, outcomes: outcomes, prices: prices,
        from: statement_account.from, to: statement_account.to,
        anchored: realign_anchors(group_links.map(&:account))
      )
      print_report(report, item)
      report
    end

    # The balance engine starts at the account's opening anchor and ignores
    # everything before it. An account created in the UI gets a zero anchor
    # dated two years back, so history imported from before that would drop
    # out of the balance, and cash on the anchor day would read as minus the
    # holdings held that day. Move the anchor to the eve of the oldest entry.
    #
    # @return [Hash{Account => Date}] the accounts moved and where to
    def realign_anchors(accounts)
      accounts.each_with_object({}) do |account, moved|
        oldest = account.entries.where.not(entryable_type: "Valuation").minimum(:date)
        next if oldest.nil? || account.opening_anchor_date < oldest

        manager = Account::OpeningBalanceManager.new(account)
        moved[account] = oldest.prev_day if manager.set_opening_balance(balance: manager.opening_balance, date: oldest.prev_day).changes_made?
      end
    end

    def print_accounts(item)
      parsed = parsed_for(item)
      linked = links.select { |link| link.ibkr_item_id == item.id }.group_by(&:ibkr_id)

      io.puts "\n#{item.name} -- query #{item.query_id} -- #{parsed.accounts.size} account(s)"
      parsed.accounts.each do |raw|
        slice = parsed.for_account(raw.id)
        io.puts "  #{raw.id}  #{raw.from} .. #{raw.to}#{raw.name ? "  #{raw.name}" : ''}"

        by_currency = Array(linked[raw.id]).index_by(&:currency)
        slice.currencies.each do |currency|
          target = by_currency[currency]
          io.puts format("    %-4s %s", currency, target ? "-> #{target.account.name}" : "(not linked)")
        end

        unlinked = slice.currencies - by_currency.keys
        if unlinked.any?
          io.puts "    link one with: rails ibkr:link ITEM=#{item.name} ID=#{raw.id} ACCOUNT=\"<#{unlinked.first} account name>\""
        end
      end

      parsed.accounts
    end

    def print_report(report, item)
      prefix = items.size > 1 ? "#{item.name}/" : ""
      targets = report.links.map { |link| "#{link.currency}: #{link.account.name}" }.join(", ")
      io.puts "\n#{prefix}#{report.ibkr_id} -> #{targets}"
      io.puts "  #{report.outcomes.size} rows, statement #{report.from} .. #{report.to}"

      report.by_status.sort_by { |status, _| status.to_s }.each do |status, count|
        io.puts format("  %-20s %d", status, count)
      end
      io.puts format("  %-20s %d", "prices", report.prices)

      report.created.each do |outcome|
        io.puts format(
          "    %s %12s %-4s %-34s %s",
          outcome.entry.date, outcome.entry.amount.to_s("F"), outcome.entry.currency,
          outcome.entry.name.truncate(34), outcome.detail.to_s
        )
      end

      report.anchored.each do |account, date|
        io.puts "  opening anchor of #{account.name} moved to #{date} so the older history counts"
      end

      report.missing_currencies.each do |currency|
        io.puts "  !! rows in #{currency} skipped: no #{currency} account is linked to #{report.ibkr_id}. " \
                "Create one and run `rails ibkr:link ITEM=#{item.name} ID=#{report.ibkr_id} ACCOUNT=\"...\"`"
      end
    end

    # Printed after every account, so it is the last thing on screen.
    def print_unsupported_notice(reports)
      unsupported = reports.flat_map(&:unsupported)
      return if unsupported.empty?

      io.puts "\n#{'!' * 60}"
      io.puts "#{unsupported.size} row(s) skipped: options, futures and bonds have no home in Maybe."
      unsupported.each do |outcome|
        io.puts format("    %s %-5s %-10s %s", outcome.row.date, outcome.row.asset_category,
                       outcome.row.symbol, outcome.row.name)
      end
      io.puts "Record these by hand if they matter to the balance."
      io.puts "!" * 60
    end
end
