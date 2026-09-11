# Imports transactions from the Monobank personal API.
#
# Unlike LegacyImport, which was a one-time load of 20 years of spreadsheet
# history, this runs repeatedly against a live API. Two constraints shape the
# whole design:
#
#   1. Monobank allows ONE request per 60 seconds per token, globally. Raw
#      responses are cached to disk so a dry run and a real run cost one call
#      between them, not two.
#   2. Rows are matched, not trusted. Every imported entry carries the
#      Monobank transaction id so re-running any range is a no-op, and rows
#      that collide with existing manual entries are skipped rather than
#      duplicated.
#
# See docs/development/monobank-import.md.
module MonobankImport
  class Error < StandardError; end
end
