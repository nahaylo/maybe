# Imports transactions from the Monobank personal API.
# See docs/development/monobank-import.md.
#
# Connections (one per API token, from https://api.monobank.ua/):
#   bin/rails monobank:items                        list connections and links
#   bin/rails monobank:connect NAME=personal TOKEN=x
#   bin/rails monobank:disconnect NAME=personal
#   bin/rails monobank:link ITEM=personal ID=<monobank_id> ACCOUNT="Mono UAH card"
#   bin/rails monobank:unlink ACCOUNT="Mono UAH card"
#
# Importing:
#   bin/rails monobank:accounts                     list API accounts + links
#   bin/rails monobank:import                       from the last entry date to today
#   bin/rails monobank:import FROM=2026-08-01 TO=2026-08-21
#   bin/rails monobank:import DRY_RUN=1             run it, report, roll back
#   bin/rails monobank:import ONLY=<monobank_id>    one account
#   bin/rails monobank:import FORCE=1               import rows that look like duplicates
#   bin/rails monobank:import REFRESH=1             ignore the cache and re-fetch
#   bin/rails monobank:import OFFLINE=1             never call the API; cache only
#
#   bin/rails monobank:seed FIXTURE=x.json ACCOUNT=<id> FROM=... TO=...
#   bin/rails monobank:seed FIXTURE=x.json ACCOUNT=client-info ITEM=personal
#
# Monobank allows ONE request per 60 seconds PER TOKEN. Responses are cached
# under storage/monobank/, so re-running a range costs nothing.
namespace :monobank do
  desc "List Monobank connections and the accounts linked to each"
  task items: :environment do
    items = MonobankItem.where(family: MonobankTask.family!).ordered

    if items.empty?
      puts "no connections -- add one with `rails monobank:connect NAME=personal TOKEN=<token>`"
      next
    end

    items.each do |item|
      links = item.monobank_accounts.includes(:account)
      puts "#{item.name} (#{links.size} linked)"
      links.each { |link| puts format("  %-24s -> %s", link.monobank_id, link.account.name) }
    end
  end

  desc "Register a Monobank API token as a connection"
  task connect: :environment do
    name = ENV.fetch("NAME", "personal")
    token = ENV["TOKEN"].presence
    abort "TOKEN is required -- get one at https://api.monobank.ua/" if token.blank?

    item = MonobankItem.create!(family: MonobankTask.family!, name: name, access_token: token)
    puts "connected #{item.name}. Next: `rails monobank:accounts` to see its account ids."
  end

  desc "Remove a Monobank connection and its links (imported entries are kept)"
  task disconnect: :environment do
    item = MonobankTask.item!(ENV["NAME"])
    count = item.monobank_accounts.count
    item.destroy!
    puts "disconnected #{item.name}, dropped #{count} link(s). Imported entries are untouched."
  end

  desc "Link a Monobank account id to a Maybe account"
  task link: :environment do
    item = MonobankTask.item!(ENV["ITEM"])
    monobank_id = ENV["ID"].presence || abort("ID is required -- see `rails monobank:accounts`")
    account = MonobankTask.account!(ENV["ACCOUNT"])

    link = MonobankAccount.create!(monobank_item: item, account: account, monobank_id: monobank_id)
    puts "linked #{link.monobank_id} -> #{account.name} (#{item.name})"
  end

  desc "Stop importing into a Maybe account"
  task unlink: :environment do
    account = MonobankTask.account!(ENV["ACCOUNT"])
    link = MonobankAccount.find_by(account: account)
    abort "#{account.name} is not linked to Monobank" if link.nil?

    link.destroy!
    puts "unlinked #{account.name}. Imported entries are untouched."
  end

  desc "List each connection's Monobank accounts and how they are linked"
  task accounts: :environment do
    MonobankTask.run { |importer| importer.accounts! }
  end

  desc "Import transactions for every linked account"
  task import: :environment do
    from = ENV["FROM"].presence&.then { |v| Date.parse(v) }
    to = ENV["TO"].presence&.then { |v| Date.parse(v) } || Date.current
    only = ENV["ONLY"].presence&.split(",")&.map(&:strip)

    reports = MonobankTask.run do |importer|
      importer.import!(from: from, to: to, force: ENV["FORCE"].present?, only: only)
    end

    # Balances are recomputed after the transaction commits, so a dry run
    # neither enqueues a sync nor leaves a half-synced account behind.
    next if ENV["DRY_RUN"].present?

    with_new_rows = Array(reports).select { |report| report.created.any? }

    with_new_rows.each do |report|
      report.account.sync_later(window_start_date: report.from - 1)
      puts "queued sync for #{report.account.name}"
    end

    # Rules only run inside a family sync, which an account sync is not, so
    # without this a fresh row stays uncategorised and unattributed until
    # something else happens to trigger one.
    if with_new_rows.any?
      MonobankTask.family!.rules.each(&:apply_later)
      puts "queued rules"
    end
  end

  desc "Place a JSON fixture in the response cache so an import can run offline"
  task seed: :environment do
    fixture = Pathname.new(ENV.fetch("FIXTURE"))
    abort "#{fixture} not found" unless fixture.exist?

    account = ENV["ACCOUNT"]
    key = if account.blank? || account == "client-info"
      # client-info is per connection, so seeding it needs to know which one.
      MonobankImport::Statement.client_info_key(MonobankTask.item!(ENV["ITEM"]).cache_scope)
    else
      zone = MonobankImport::Statement::ZONE
      from = Date.parse(ENV.fetch("FROM")).in_time_zone(zone).beginning_of_day
      to = Date.parse(ENV.fetch("TO")).in_time_zone(zone).end_of_day
      MonobankImport::Statement.cache_key(account, from, to)
    end

    target = MonobankImport::Cache.new.path_for(key)
    target.dirname.mkpath
    target.write(fixture.read)
    puts "seeded #{target} (#{target.size} bytes)"
  end
end

# Shared plumbing: resolves the family, wires up the cache flags, and honours
# DRY_RUN by rolling the whole run back.
module MonobankTask
  module_function

  def family!
    Family.first || abort("No family found -- nothing to import into.")
  end

  # Falls back to the only connection when NAME/ITEM is omitted, which is the
  # common case: most instances have exactly one token.
  def item!(name)
    scope = MonobankItem.where(family: family!)

    if name.present?
      scope.find_by(name: name) || abort("no connection named #{name.inspect} -- see `rails monobank:items`")
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

    cache = MonobankImport::Cache.new(
      refresh: ENV["REFRESH"].present?,
      offline: ENV["OFFLINE"].present?
    )

    importer = MonobankImport::Importer.new(family: family!, cache: cache)
    result = nil

    ActiveRecord::Base.transaction do
      result = yield importer
      raise ActiveRecord::Rollback if dry_run
    end

    result
  rescue MonobankImport::Error, Provider::Monobank::Error => e
    abort "monobank: #{e.message}"
  end
end
