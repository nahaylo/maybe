# Imports trades, cash movements and position marks from the Interactive
# Brokers Flex Web Service.
#
# Same shape as MonobankImport: a rake task you run, not a live sync. Every
# row it creates is an ordinary, fully editable entry carrying the IBKR id in
# `external_id`, so re-running any report is a no-op.
#
# See docs/development/ibkr-import.md.
module IbkrImport
  class Error < StandardError; end
end
