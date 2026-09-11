# Turns statement rows into entries, skipping anything already in the ledger.
#
# Two things it deliberately does not do:
#
#   * enrich_attribute / lock_saved_attributes. Plaid locks the fields it owns
#     so a later sync cannot clobber a user's edit. Nothing here is ever
#     re-synced over, and the whole point of the review tags is that these rows
#     get corrected by hand, so the fields stay unlocked.
#   * bulk import. A run is on the order of a hundred rows, not the 22,000 of
#     LegacyImport, so ordinary saves are fast enough and keep validations,
#     callbacks and tag assignment working normally.
class MonobankImport::EntryBuilder
  # Every tag here carries something the database does not already know. There
  # is deliberately no "needs review" tag: an imported row that needs attention
  # is one with no category, which Transaction::Search already filters on
  # (category "Uncategorized" + tag mono-import) -- and it filters better,
  # because it excludes transfers, which never need a category.
  TAG_NAMES = {
    imported: "mono-import",
    guessed: "utilities-guessed",
    hold: "pending-hold"
  }.freeze

  # Utility bills. A rule files every one of these under a single default
  # property, because nothing in the payload says which property a bill belongs
  # to -- same description, same MCC, no counterparty. The tag marks them so
  # the misfiled ones can be moved by hand; the import report lists them so
  # they are not forgotten.
  UTILITY_MCC = 4900

  # How far apart a statement row and a hand-entered row can be and still be
  # believed to be the same transaction.
  #
  # The window is asymmetric because the underlying behaviour is. A purchase is
  # written down when it is noticed, which is on or after the day it posts.
  # Measured over a month of real statements, nearly every hand-entered row
  # fell on the posting day, a handful one to three days after it, and at most
  # one the day before.
  #
  # A symmetric +/-3 window covered the late entries but also reached three
  # days backwards, where it matched a round-figure transfer to one bank
  # against an unrelated transfer of the same amount to another. Round numbers
  # recur; the backward reach bought nothing and cost a false skip.
  COLLISION_WINDOW_AFTER = 3
  COLLISION_WINDOW_BEFORE = 1

  # How many hand-entered rows a single charge may have been broken into. One
  # shop visit is sometimes recorded as its separate items.
  MAX_SPLIT_PARTS = 3

  Outcome = Data.define(:row, :status, :entry, :detail) do
    def created? = status == :created || status == :created_hold
    def skipped? = !created?
  end

  attr_reader :family, :account, :force

  def initialize(family:, account:, force: false)
    @family = family
    @account = account
    @force = force
  end

  # @param rows [Array<MonobankImport::Statement::Row>] chronological
  # @return [Array<Outcome>]
  def build!(rows:)
    seen_external_ids = account.entries.where.not(external_id: nil).pluck(:external_id).to_set
    pool = collision_pool(rows)

    outcomes = purge_reissued_holds(rows)

    outcomes + rows.map do |row|
      if seen_external_ids.include?(row.external_id)
        if (settled = settle_hold(row))
          next Outcome.new(row: row, status: :settled, entry: settled, detail: "hold posted at #{row.amount.to_s('F')}")
        end

        next Outcome.new(row: row, status: :skipped_imported, entry: nil, detail: "already imported")
      end

      if !force && (existing = claim_collision(pool, row))
        next Outcome.new(
          row: row,
          status: :skipped_collision,
          entry: existing,
          detail: "matches existing #{existing.date} #{existing.name.inspect}"
        )
      end

      if !force && (parts = claim_split(pool, row))
        next Outcome.new(
          row: row,
          status: :skipped_split,
          entry: parts.first,
          detail: "already recorded as #{parts.map { |e| e.name.inspect }.join(' + ')}"
        )
      end

      entry = create_entry!(row)
      seen_external_ids << row.external_id

      Outcome.new(row: row, status: row.hold? ? :created_hold : :created, entry: entry,
                  detail: row.utility? ? "utility -- filed under the default property by rule" : nil)
    end
  end

  private
    def create_entry!(row)
      entry = account.entries.new(
        external_id: row.external_id,
        date: row.date,
        # Rows post in the account's currency; currency_code is only a
        # cross-check, since the API documents it as the account's currency
        # while the CSV export uses the same field name for the operation's.
        currency: account.currency,
        amount: row.amount,
        name: row.name,
        notes: notes_for(row),
        # No category: the rules engine assigns it on the next sync.
        entryable: Transaction.new(mcc: row.mcc)
      )

      entry.save!
      entry.transaction.tags = tags_for(row)
      entry
    end

    def tags_for(row)
      names = [ TAG_NAMES[:imported] ]
      names << TAG_NAMES[:hold] if row.hold?
      names << TAG_NAMES[:guessed] if row.utility?

      names.map { |name| tags.fetch(name) }
    end

    # A hold posts with a final amount that can differ from the blocked one, so
    # the existing row is updated in place rather than left stale. Keyed on the
    # Monobank id, so this only fires when the bank kept the same id.
    #
    # A row the user has edited is left alone: their figure outranks the bank's.
    def settle_hold(row)
      return nil if row.hold?

      entry = account.entries.find_by(external_id: row.external_id)
      return nil if entry.nil?

      transaction = entry.transaction
      return nil unless transaction.tags.any? { |tag| tag.name == TAG_NAMES[:hold] }
      return nil if transaction.locked_attributes.present? || entry.locked_attributes.present?

      entry.update!(date: row.date, amount: row.amount, name: row.name, notes: notes_for(row))
      transaction.tags = transaction.tags.reject { |tag| tag.name == TAG_NAMES[:hold] }
      entry
    end

    # Holds this account still has but the bank no longer reports. Either the
    # charge was cancelled, or it settled under a NEW id -- in which case the
    # settled row imports separately and this stale one would double-count.
    #
    # Deleting them is what makes holds safe to import at all: the importer owns
    # every pending-hold row outright and rebuilds them from each response.
    # Rows the user has edited are kept, because an edit means they want it.
    def purge_reissued_holds(rows)
      return [] if rows.empty?

      hold_tag = family.tags.find_by(name: TAG_NAMES[:hold])
      return [] if hold_tag.nil?

      still_reported = rows.map(&:external_id)

      stale = Transaction
                .joins(:entry, :taggings)
                .includes(:entry)
                .where(entries: { account_id: account.id, date: rows.first.date..rows.last.date })
                .where(taggings: { tag_id: hold_tag.id })
                .where.not(entries: { external_id: still_reported })
                .select { |t| t.locked_attributes.blank? && t.entry.locked_attributes.blank? }

      stale.map do |transaction|
        entry = transaction.entry
        outcome = Outcome.new(row: nil, status: :hold_dropped, entry: entry,
                              detail: "#{entry.date} #{entry.amount.to_s('F')} no longer reported")
        entry.destroy!
        outcome
      end
    end

    def notes_for(row)
      parts = []

      if row.foreign?
        parts << "Settled abroad: operation amount #{row.operation_amount.abs.to_s('F')} " \
                 "#{row.currency || "currency code #{row.currency_code}"}"
      end

      parts << "Counterparty: #{row.counter_name}" if row.counter_name
      parts << "IBAN: #{row.counter_iban}" if row.counter_iban
      parts << "EDRPOU: #{row.counter_edrpou}" if row.counter_edrpou
      parts << "Comment: #{row.comment}" if row.comment
      parts << "Cashback: #{row.cashback.to_s('F')}" if row.cashback.positive?
      parts << "Commission: #{row.commission.to_s('F')}" if row.commission.positive?
      parts << "MCC #{row.mcc} (original #{row.original_mcc})" if row.original_mcc && row.original_mcc != row.mcc

      parts.presence&.join("\n")
    end

    # Entries that could be a hand-written version of one of these rows: same
    # account, no external id of their own, within the window.
    def collision_pool(rows)
      return [] if rows.empty?

      dates = rows.map(&:date)

      account.entries
             .where(external_id: nil)
             .where(date: (dates.min - COLLISION_WINDOW_BEFORE)..(dates.max + COLLISION_WINDOW_AFTER))
             .to_a
    end

    # Removes and returns the matching entry, so two identical statement rows
    # cannot both be explained away by a single existing entry.
    #
    # Nearest date wins. With a three-day window a recurring same-amount charge
    # (a weekly top-up, say) can have more than one candidate, and pairing each
    # row with its closest neighbour keeps the assignment stable.
    def claim_collision(pool, row)
      match = pool.select { |entry| entry.amount == row.amount && within_window?(entry, row) }
                  .min_by { |entry| (entry.date - row.date).abs }

      pool.delete(match) if match
    end

    # One charge broken into several hand-entered rows -- two items bought in
    # one shop visit, written down separately.
    #
    # Restricted to the same day and to components of the same sign, which is
    # what makes it safe. An earlier attempt over a three-day spread found a
    # false match, because a refund plus an unrelated purchase reproduced the
    # arithmetic; same-day exact sums do not have that problem in practice.
    def claim_split(pool, row)
      candidates = pool.select { |entry| entry.date == row.date && same_sign?(entry, row) }
      return nil if candidates.size < 2

      (2..MAX_SPLIT_PARTS).each do |size|
        parts = candidates.combination(size).find { |combo| combo.sum(&:amount) == row.amount }
        next if parts.nil?

        parts.each { |entry| pool.delete(entry) }
        return parts
      end

      nil
    end

    def within_window?(entry, row)
      (entry.date - row.date).between?(-COLLISION_WINDOW_BEFORE, COLLISION_WINDOW_AFTER)
    end

    def same_sign?(entry, row)
      entry.amount.negative? == row.amount.negative?
    end

    def tags
      @tags ||= TAG_NAMES.values.index_with { |name| family.tags.find_or_create_by!(name: name) }
    end
end
