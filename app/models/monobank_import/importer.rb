# Orchestrates a Monobank pull: fetch, categorise, build, report.
#
# Work is organised by connection (MonobankItem), because the token is what the
# API authenticates and rate limits. Each connection gets one Provider::Monobank
# and one Statement for the whole run, so the once-a-minute throttle is tracked
# per token and two connections do not queue behind each other.
#
# Everything that touches the network goes through MonobankImport::Statement,
# which caches, so a dry run and the real run that follows it cost one API call
# between them -- see MonobankImport::Cache.
class MonobankImport::Importer
  ZONE = MonobankImport::Statement::ZONE

  # What the bank says the account held just before the first row of this
  # statement, next to what the ledger says. They should agree; drift means the
  # ledger is missing history from BEFORE the imported window, which no amount
  # of importing this window can fix.
  Boundary = Data.define(:date, :bank, :ledger) do
    def drift = bank - ledger
    def clean? = drift.zero?
  end

  Report = Data.define(:account, :link, :outcomes, :from, :to, :boundary) do
    def created = outcomes.select(&:created?)
    def by_status = outcomes.group_by(&:status).transform_values(&:size)

    # Utility bills that were just imported. Every one is filed under a default
    # property by rule, so any belonging elsewhere has to be moved by hand --
    # which only happens if the import says so out loud.
    def utilities = created.select { |o| o.row.utility? }
  end

  attr_reader :family, :io, :cache

  # @param items [Array<MonobankItem>, nil] defaults to the family's connections
  def initialize(family:, io: $stdout, cache: MonobankImport::Cache.new, items: nil)
    @family = family
    @io = io
    @cache = cache
    @items = items
    @statements = {}
  end

  def items
    @items ||= MonobankItem.where(family: family).ordered.to_a
  end

  # Every linked account across every connection, in the family's account order.
  def links
    @links ||= MonobankAccount
                 .where(monobank_item: items)
                 .joins(:account).merge(Account.ordered)
                 .preload(:account, :monobank_item)
                 .to_a
  end

  # Lists each connection's API accounts, marking the ones that are linked.
  def accounts!
    if items.empty?
      raise MonobankImport::Error,
            "no Monobank connection configured -- run `rails monobank:connect NAME=... TOKEN=...`"
    end

    items.flat_map { |item| print_accounts(item) }
  end

  # @param from [Date, nil] defaults to each account's own last entry
  # @param only [Array<String>, nil] monobank ids to restrict the run to
  # @return [Array<Report>]
  def import!(from: nil, to: Date.current, force: false, only: nil)
    targets = links
    targets = targets.select { |link| only.include?(link.monobank_id) } if only.present?

    if targets.empty?
      io.puts "nothing to import -- no linked accounts (see `rails monobank:items`)"
      return []
    end

    io.puts "monobank import #{from || 'per account'} .. #{to}#{force ? ' (FORCE)' : ''}"

    reports = targets.map { |link| import_one(link, from: from, to: to, force: force) }
    print_utility_notice(reports)
    reports
  end

  # One statement per connection, memoized: see the class comment on why sharing
  # the provider across a connection's accounts is what keeps the throttle sane.
  def statement_for(item)
    @statements[item.id] ||= MonobankImport::Statement.new(
      provider: item.provider, cache: cache, scope: item.cache_scope
    )
  end

  private
    def import_one(link, from:, to:, force:)
      account = link.account
      from ||= start_for(account)
      rows = statement_for(link.monobank_item)
               .rows(account_id: link.monobank_id, from: window_start(from), to: window_end(to))

      # Measured before anything is written, so it describes the ledger as it
      # stood going into this import.
      boundary = boundary_for(account, link, rows)

      outcomes = MonobankImport::EntryBuilder
                   .new(family: family, account: account, force: force)
                   .build!(rows: rows)

      report = Report.new(account: account, link: link, outcomes: outcomes, from: from, to: to, boundary: boundary)
      print_report(report)
      report
    end

    def print_accounts(item)
      info = statement_for(item).client_info
      api = Array(info["accounts"])
      linked = links.select { |link| link.monobank_item_id == item.id }.index_by(&:monobank_id)

      io.puts "\n#{item.name} -- #{info['name']} -- #{api.size} accounts"
      api.each do |raw|
        io.puts format(
          "  %-24s %-14s %12s %s",
          raw["id"],
          raw["type"],
          format("%.2f", own_funds(raw)),
          linked[raw["id"]] ? "-> #{linked[raw['id']].account.name}" : ""
        )
      end

      if api.size > linked.size
        io.puts "  link one with: rails monobank:link ITEM=#{item.name} ID=<id> ACCOUNT=\"<account name>\""
      end

      api
    end

    def print_report(report)
      prefix = items.size > 1 ? "#{report.link.monobank_item.name}/" : ""
      io.puts "\n#{prefix}#{report.account.name} (#{report.link.monobank_id}) -- #{report.outcomes.size} rows from #{report.from}"
      print_boundary(report.boundary)

      report.by_status.sort_by { |status, _| status.to_s }.each do |status, count|
        io.puts format("  %-20s %d", status, count)
      end

      report.created.each do |outcome|
        io.puts format(
          "    %s %12s  %-34s %s",
          outcome.row.date,
          outcome.row.amount.to_s("F"),
          outcome.row.name.truncate(34),
          outcome.detail.to_s
        )
      end
    end

    # Printed after every account, so it is the last thing on screen.
    def print_utility_notice(reports)
      utilities = reports.flat_map(&:utilities)
      return if utilities.empty?

      io.puts "\n#{'!' * 60}"
      io.puts "#{utilities.size} utility bill(s) imported, ALL filed under the default property."
      io.puts "Nothing in the Monobank payload says which property a bill belongs to,"
      io.puts "so any of these that are for other properties must be re-categorised by hand:"
      utilities.sort_by { |o| o.row.time }.each do |outcome|
        io.puts format("    %s %10s  %s", outcome.row.date, outcome.row.amount.to_s("F"), outcome.row.name)
      end
      io.puts "Find them again any time with the `utilities-guessed` tag."
      io.puts "!" * 60
    end

    def print_boundary(boundary)
      return if boundary.nil? || boundary.clean?

      io.puts format(
        "  !! opening balance on %s: bank %s, ledger %s, drift %s",
        boundary.date, boundary.bank.to_s("F"), boundary.ledger.to_s("F"), boundary.drift.to_s("F")
      )
      io.puts "     history BEFORE this window is missing -- widen FROM, this import cannot fix it"
    end

    # Every statement row carries the running balance after it, so the balance
    # before the first row is free information. Comparing it to the ledger is
    # the only check that can see a gap OUTSIDE the imported window -- a final
    # balance match cannot, because both sides move by the same amount.
    #
    # Returns nil when it cannot be computed rather than guessing: no rows, no
    # balance field, or no cached client-info to read the credit limit from.
    def boundary_for(account, link, rows)
      first = rows.first
      return nil if first.nil? || first.balance_minor.nil?

      limit = credit_limit_for(link)
      return nil if limit.nil?

      # Monobank reports balance inclusive of any credit limit; the ledger does
      # not. `balance` is the figure after the row, so undo the row to get before.
      bank = first.balance + first.amount - limit

      # Same-day entries are excluded: the bank's "before this row" is a moment
      # inside the day, which a date-only ledger cannot express.
      ledger = -account.entries.where(date: ...first.date).sum(:amount)

      Boundary.new(date: first.date, bank: bank, ledger: ledger)
    end

    def credit_limit_for(link)
      raw = client_info_accounts(link.monobank_item).find { |a| a["id"] == link.monobank_id }
      return nil if raw.nil?

      raw["creditLimit"].to_i.to_d / 100
    end

    # Read-only, straight off disk. Going through the cache's fetch path would
    # re-request under REFRESH=1, and the check must never spend one of the
    # token's once-a-minute requests.
    def client_info_accounts(item)
      @client_info_accounts ||= {}
      @client_info_accounts[item.id] ||=
        Array(cache.read(MonobankImport::Statement.client_info_key(item.cache_scope))&.dig("accounts"))
    end

    # Monobank works in unix seconds; the window is the bank's calendar day.
    def window_start(from)
      from.to_date.in_time_zone(ZONE).beginning_of_day
    end

    def window_end(to)
      to.to_date.in_time_zone(ZONE).end_of_day
    end

    # Starts ON the account's last known day, not the day after: re-fetching it
    # costs nothing (deduplication catches the overlap) and a transaction posted
    # late on that day would otherwise be missed forever.
    def start_for(account)
      account.entries.maximum(:date) || fallback_start ||
        raise(MonobankImport::Error, "no FROM given and no linked account has any entries")
    end

    # Only a fallback, for an account that has no entries of its own to start
    # from. A family-wide maximum would otherwise let the furthest-ahead account
    # decide, stranding a dormant account long after its real gap begins.
    def fallback_start
      return @fallback_start if defined?(@fallback_start)

      @fallback_start = Entry.where(account_id: links.map(&:account_id)).maximum(:date)
    end

    # The API reports `balance` inclusive of any credit limit.
    def own_funds(raw)
      (raw["balance"].to_i - raw["creditLimit"].to_i) / 100.0
    end
end
