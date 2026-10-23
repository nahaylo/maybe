# Imports trades, cash movements and position marks from the Interactive
# Brokers Flex Web Service. See docs/development/ibkr-import.md.
#
# Connections (one per Flex token + query, from Client Portal > Performance &
# Reports > Flex Queries):
#   bin/rails ibkr:items                              list connections and links
#   bin/rails ibkr:connect NAME=ib TOKEN=x QUERY=123456
#   bin/rails ibkr:disconnect NAME=ib
#   bin/rails ibkr:link ITEM=ib ID=U1234567 ACCOUNT="Interactive Brokers USD"
#   bin/rails ibkr:link ITEM=ib ID=U1234567 ACCOUNT="Interactive Brokers EUR"
#   bin/rails ibkr:unlink ACCOUNT="Interactive Brokers EUR"
#
# One link per currency the IBKR account books money in: the Maybe account's
# currency is the link's currency, and rows are routed by it. A conversion
# between two linked currencies becomes a transfer between the two accounts.
#
# Importing:
#   bin/rails ibkr:accounts                           accounts in the report + links
#   bin/rails ibkr:import                             everything the report covers
#   bin/rails ibkr:import DRY_RUN=1                   run it, report, roll back
#   bin/rails ibkr:import ONLY=U1234567               one account
#   bin/rails ibkr:import FORCE=1                     import rows that look like duplicates
#   bin/rails ibkr:import REFRESH=1                   ignore today's cached report and re-fetch
#   bin/rails ibkr:import OFFLINE=1                   never call the API; cache only
#
#   bin/rails ibkr:seed FIXTURE=flex.xml ITEM=ib [DATE=2026-09-21]
#
# The report's date range is set on the Flex Query itself, not here. Reports
# are cached per day under storage/ibkr/, so a dry run and the real run that
# follows it cost one request.
namespace :ibkr do
  desc "List IBKR connections and the accounts linked to each"
  task items: :environment do
    items = IbkrItem.where(family: IbkrTask.family!).ordered

    if items.empty?
      puts "no connections -- add one with `rails ibkr:connect NAME=ib TOKEN=<token> QUERY=<query id>`"
      next
    end

    items.each do |item|
      links = item.ibkr_accounts.includes(:account)
      puts "#{item.name} -- query #{item.query_id} (#{links.size} linked)"
      links.sort_by { |link| [ link.ibkr_id, link.currency ] }.each do |link|
        puts format("  %-12s %-4s -> %s", link.ibkr_id, link.currency, link.account.name)
      end
    end
  end

  desc "Register a Flex Web Service token and query as a connection"
  task connect: :environment do
    name = ENV.fetch("NAME", "ib")
    token = ENV["TOKEN"].presence
    query_id = ENV["QUERY"].presence
    abort "TOKEN is required -- Client Portal > Performance & Reports > Flex Queries > Flex Web Service" if token.blank?
    abort "QUERY is required -- the Query ID shown next to your Flex Query" if query_id.blank?

    item = IbkrItem.create!(family: IbkrTask.family!, name: name, access_token: token, query_id: query_id)
    puts "connected #{item.name}. Next: `rails ibkr:accounts` to see the account ids in the report."
  end

  desc "Remove an IBKR connection and its links (imported entries are kept)"
  task disconnect: :environment do
    item = IbkrTask.item!(ENV["NAME"])
    count = item.ibkr_accounts.count
    item.destroy!
    puts "disconnected #{item.name}, dropped #{count} link(s). Imported entries are untouched."
  end

  desc "Link one currency of an IBKR account to a Maybe account (the account's currency)"
  task link: :environment do
    item = IbkrTask.item!(ENV["ITEM"])
    ibkr_id = ENV["ID"].presence || abort("ID is required -- see `rails ibkr:accounts`")
    account = IbkrTask.account!(ENV["ACCOUNT"])

    unless account.accountable_type == "Investment"
      abort "#{account.name} is a #{account.accountable_type} account -- trades need an Investment account"
    end

    link = IbkrAccount.create!(ibkr_item: item, account: account, ibkr_id: ibkr_id)
    puts "linked #{link.ibkr_id} #{link.currency} -> #{account.name} (#{item.name})"
  end

  desc "Stop importing into a Maybe account"
  task unlink: :environment do
    account = IbkrTask.account!(ENV["ACCOUNT"])
    link = IbkrAccount.find_by(account: account)
    abort "#{account.name} is not linked to IBKR" if link.nil?

    link.destroy!
    puts "unlinked #{account.name}. Imported entries are untouched."
  end

  desc "List the IBKR accounts each connection's report covers and how they are linked"
  task accounts: :environment do
    IbkrTask.run { |importer| importer.accounts! }
  end

  desc "Import trades, cash movements and prices for every linked account"
  task import: :environment do
    only = ENV["ONLY"].presence&.split(",")&.map(&:strip)

    reports = IbkrTask.run do |importer|
      importer.import!(force: ENV["FORCE"].present?, only: only)
    end

    # Balances are recomputed after the transaction commits, so a dry run
    # neither enqueues a sync nor leaves a half-synced account behind.
    next if ENV["DRY_RUN"].present?

    changed = Array(reports).select(&:changed?)

    changed.each do |report|
      report.accounts.each do |account|
        account.sync_later(window_start_date: report.sync_window_start(account))
        puts "queued sync for #{account.name}"
      end
    end

    # Rules only run inside a family sync, which an account sync is not, so
    # without this a fresh dividend or fee stays uncategorised.
    if changed.any? { |report| report.created.any? }
      IbkrTask.family!.rules.each(&:apply_later)
      puts "queued rules"
    end
  end

  desc "Place a Flex XML fixture in the response cache so an import can run offline"
  task seed: :environment do
    fixture = Pathname.new(ENV.fetch("FIXTURE"))
    abort "#{fixture} not found" unless fixture.exist?

    item = IbkrTask.item!(ENV["ITEM"])
    date = ENV["DATE"].presence&.then { |v| Date.parse(v) } || Date.current
    statement = IbkrImport::Statement.new(cache: IbkrImport::Cache.new, scope: item.cache_scope)

    xml = fixture.read
    target = statement.cache.path_for(statement.key_for(item.query_id, date))
    target.dirname.mkpath
    target.write(xml)
    puts "seeded #{target} (#{target.size} bytes)"

    archived = statement.archive(item.query_id, xml)
    puts "archived #{archived}" if archived
  end
end

# Shared plumbing: resolves the family, wires up the cache flags, and honours
# DRY_RUN by rolling the whole run back.
module IbkrTask
  module_function

  def family!
    Family.first || abort("No family found -- nothing to import into.")
  end

  # Falls back to the only connection when NAME/ITEM is omitted, which is the
  # common case: most instances have exactly one token.
  def item!(name)
    scope = IbkrItem.where(family: family!)

    if name.present?
      scope.find_by(name: name) || abort("no connection named #{name.inspect} -- see `rails ibkr:items`")
    else
      scope.count == 1 ? scope.sole : abort("ITEM is required -- more than one connection exists")
    end
  end

  def account!(name)
    abort "ACCOUNT is required" if name.blank?

    matches = family!.accounts.where(name: name)
    abort "no account named #{name.inspect}" if matches.empty?
    abort "#{matches.size} accounts are named #{name.inspect} -- rename one first" if matches.size > 1

    matches.sole
  end

  def run
    dry_run = ENV["DRY_RUN"].present?
    puts "(DRY RUN -- will roll back)" if dry_run

    cache = IbkrImport::Cache.new(
      refresh: ENV["REFRESH"].present?,
      offline: ENV["OFFLINE"].present?
    )

    importer = IbkrImport::Importer.new(family: family!, cache: cache)
    result = nil

    ActiveRecord::Base.transaction do
      result = yield importer
      raise ActiveRecord::Rollback if dry_run
    end

    result
  rescue IbkrImport::Error, Provider::IbkrFlex::Error => e
    abort "ibkr: #{e.message}"
  end
end
