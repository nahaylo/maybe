# Interactive Brokers import

Pulls trades, cash movements and position marks from the **Interactive Brokers
Flex Web Service** into a Maybe investment account.

Same shape as the [Monobank import](monobank-import.md): a rake task you run
when you want to catch up, not a live sync. Every row it creates is an
ordinary, fully editable entry, and every one carries IBKR's own id in
`entries.external_id`, so re-running any report is a no-op.

## Why Flex, and not one of IBKR's other APIs

IBKR exposes four APIs. Three of them need a logged-in desktop process (TWS
API, Client Portal Gateway) or vendor registration (the OAuth Web API), which
rules them out for an unattended Docker server. The **Flex Web Service** is a
report runner: you define a *Flex Query* once in Client Portal, generate a
long-lived token, and fetch the report over plain HTTPS with no login and no
2FA. It is designed for exactly this use.

Its limits shape the design:

- Data is **end of day**, published a few hours after US close. Nothing here is
  live, and running the import twice in one day gets the same report.
- The **date range is set on the query**, not the request. The task imports
  whatever the report covers; the `external_id` dedupe makes a wide range (say,
  *Last 365 Calendar Days*) safe and is the recommended setting, so a missed
  month is picked up by the next run.
- Position marks come as **one price per security per report date**, plus the
  closing price on each trade's day. Holdings between those dates carry the
  last known price forward, exactly as Maybe already does for gaps.

## Setup

**1. Create a Flex Query** in Client Portal, under *Performance & Reports >
Flex Queries > Activity Flex Query*. Format **XML**, period *Last 365 Calendar
Days* (or whatever range you want each run to cover), and tick these sections
with all fields:

| Section | What the importer reads from it |
| --- | --- |
| Trades (level: *Executions*) | one Trade entry per execution, plus a commission Transaction; conversions become transfers |
| Cash Transactions (level: *Detail*) | deposits, withdrawals, dividends, withholding tax, interest, fees |
| Open Positions (level: *Summary and Lot*) | summaries give IBKR's mark price per security on the report date; lots reveal shares that arrived without a trade |

Note the **Query ID** shown in the list afterwards.

**2. Create a token** under *Flex Queries > Flex Web Service Configuration*:
enable it and generate a token. Tokens are read-only, tied to your login, and
expire on the date you choose (up to a year).

**3. Create one Maybe account per currency** in the UI: an **Investment**
account for each currency the IBKR account books money in, for example
"Interactive Brokers USD" and "Interactive Brokers EUR". Trades need an
Investment account; the link task refuses any other type. See
[One account per currency](#one-account-per-currency) for why.

**4. Register the connection and link each currency:**

```bash
bin/rails ibkr:connect NAME=ib TOKEN=<token> QUERY=<query id>
bin/rails ibkr:accounts        # fetches the report, lists account ids + currencies
bin/rails ibkr:link ITEM=ib ID=U1234567 ACCOUNT="Interactive Brokers USD"
bin/rails ibkr:link ITEM=ib ID=U1234567 ACCOUNT="Interactive Brokers EUR"
bin/rails ibkr:items           # what is linked now
```

The link's currency is the Maybe account's currency; there is nothing to
type. `ibkr:accounts` lists every currency the report books money in and
which of them are linked, so a first CHF dividend shows up as `(not linked)`
with the link command to run.

The token is stored on `ibkr_items`, encrypted when the instance has Active
Record encryption keys configured (the same condition `PlaidItem` and
`MonobankItem` use). A Flex Query can cover several IBKR accounts; each one
has its own set of per-currency links.

`ibkr:unlink ACCOUNT="..."` stops importing into an account, and
`ibkr:disconnect NAME=ib` removes a connection and all of its links. Neither
touches entries that were already imported.

## Importing

```bash
bin/rails ibkr:import DRY_RUN=1    # fetch, report what would happen, roll back
bin/rails ibkr:import              # the real thing
```

A run prints one block per linked account:

```
Interactive Brokers (U1234567) -- 13 rows, statement 2025-09-21 .. 2026-09-19
  created_cash         5
  created_commission   3
  created_trade        4
  skipped_unsupported  1
  prices               7
    2026-09-01     -3000.0 USD  Deposit to Interactive Brokers      Deposits/Withdrawals
    ...
```

Then it queues an account sync for each account that gained rows or prices,
which recomputes holdings and balances, and queues the family's rules so new
dividends and fees are categorised.

Flags, all optional:

| Flag | Effect |
| --- | --- |
| `DRY_RUN=1` | run inside a transaction and roll back; prints the same report |
| `ONLY=U1234567` | one IBKR account (comma-separated for several) |
| `FORCE=1` | import rows that look like hand-entered duplicates (see below) |
| `REFRESH=1` | ignore today's cached report and fetch again |
| `OFFLINE=1` | never call IBKR; a cache miss is an error |

Reports are cached under `storage/ibkr/`, one file per connection, query and
**day**, so a dry run and the real run that follows it cost one request.
`storage/` is a named Docker volume, so the cache survives
`docker compose up -d`.

## One account per currency

An IBKR account is multi-currency; a Maybe account is not. The balance engine
converts a foreign-currency entry to the account's currency **on the day it
happens and never revalues it**, so 5,000 EUR deposited into a USD account is
booked at that day's rate for good, while IBKR marks the same cash at today's
rate. Holdings do not have this problem -- each day's holding is converted at
that day's rate -- only cash does, because cash is a running total of
converted flows rather than a quantity with a price.

So one IBKR account links to **one Maybe account per currency**, and every
row is routed by the currency it is booked in:

```
ibkr_items      one per token + query     family, name, access_token, query_id
ibkr_accounts   one per IBKR account      ibkr_item_id, ibkr_id, currency, account_id
                AND currency              unique on (item, ibkr_id, currency); account_id unique
```

| Row | Routed by | Lands in |
| --- | --- | --- |
| Trade in VWCE priced in EUR | `currency` | the EUR account, as a Trade |
| Trade in AAPL priced in USD | `currency` | the USD account |
| Deposit of 5,000 EUR | `currency` | the EUR account |
| Dividend from PM in USD | `currency` | the USD account |
| Commission in EUR on an EUR trade | `ibCommissionCurrency` | the EUR account |
| Conversion `EUR.USD`, sell 383.35 EUR | pair symbol | a Transfer: EUR account out, USD account in |

Each account then holds cash in its own currency, the balance sheet converts
the account total at today's rate, and a conversion has two sides to be a
transfer between. A row whose currency has no link is reported as
`skipped_no_account` with the link command to run; nothing is booked to the
wrong account.

The cost is that one IBKR account shows as two or three lines in the
sidebar. Net worth is right either way.

## Field mapping

### Trades

| Flex `<Trade>` | Maybe | Note |
| --- | --- | --- |
| `tradeID` | `entries.external_id` = `ibkr-trade-<id>` | dedupe key |
| `tradeDate` | `entries.date` | day only; IBKR's `dateTime` is in the account's own zone |
| `symbol`, `listingExchange`, `description` | `Security` | see *Securities* |
| `quantity` (signed: buy +, sell −) | `trades.qty` | same convention as Maybe |
| `tradePrice` | `trades.price` | |
| `quantity × tradePrice` | `entries.amount` | a buy is a positive cash outflow, as the trade form does it |
| `ibCommission` (negative) | a separate Transaction, `ibkr-trade-<id>-commission` | omitted when zero |
| `closePrice` | `security_prices` on `tradeDate` | that day's close |
| `assetCategory = CASH` (a conversion, symbol `EUR.USD`) | a Transfer | see below |
| `assetCategory` other than `STK`/`FUND`/`CASH` | *skipped, reported* | options, futures, bonds have no model here |

The `levelOfDetail` flag filters `EXECUTION` rows; a query that also includes
*Orders* carries `<Order>` rows and `ORDER`-level duplicates, which are ignored.

Commission is a separate row rather than folded into the trade amount because
the trade form and the trade drawer both assume `amount = qty × price`; an edit
in the UI would silently drop a folded-in commission.

### Conversions

A currency conversion is a "trade" in a pair. `quantity` is in the base
currency (EUR in `EUR.USD`), `proceeds` in the quote currency; a negative
quantity sold the base. It becomes two `funds_movement` Transactions joined by
a confirmed `Transfer`: `ibkr-trade-<id>-out` in the account of the currency
that left, `ibkr-trade-<id>-in` in the account of the currency that arrived,
with the two amounts IBKR reports. The transfer drawer shows the implied
rate. Any commission on the conversion is a third small transaction in its
own currency. Both currencies must be linked; otherwise the row is reported
as `skipped_no_account`.

### Cash

| Flex `<CashTransaction>` | Maybe | Note |
| --- | --- | --- |
| `transactionID` | `entries.external_id` = `ibkr-cash-<id>` | dedupe key |
| `dateTime` | `entries.date` | |
| `amount` (**positive = money in**) | `entries.amount` | sign flipped: Maybe is positive-for-outflow |
| `currency` | which account | the link for that currency |
| `type`, `symbol` | `entries.name` | `Deposit to …`, `Dividend: VT`, `Withholding tax: VT`, `Interest payment`, `Fee: …` |
| `description` | `entries.notes` | IBKR's own wording, kept for reference |
| `levelOfDetail = SUMMARY` | *skipped* | per-symbol totals of the detail rows |

Every cash row and every commission is a `Transaction` tagged
**`ibkr-import`**, with no category: the rules engine assigns one on the next
family sync, and the task queues that.

Deposits and withdrawals are `standard` transactions, the same as the trade
form's *Deposit* type creates, so the family's transfer auto-matching pairs
them with the bank's side when it has a matching row. Everything else --
dividends, payments in lieu, withholding tax, interest, fees, commissions and
the offsets for bonus shares -- gets the kind **`investment_activity`**. It is
counted as ordinary income and expense everywhere, but the transfer matcher
only considers `standard` rows on either side. Before that rule, a 7 USD
dividend paired with whichever 320 UAH card charge fell within four days and
5% at the day's rate, and it did so again on every sync with a fresh charge.

### Positions and prices

| Flex `<OpenPosition>` | Maybe |
| --- | --- |
| `SUMMARY` row: `markPrice` on `reportDate` | `security_prices` |
| `LOT` row with an `originatingOrderID` | *skipped* -- it is one of the trades' own lots |
| `LOT` row with **no** `originatingOrderID` | a Trade at `openPrice` on `openDateTime` for `costBasisMoney`, plus an equal inflow "Shares received: 0.219 IBKR" |

The last line is how IBKR's **stock bonuses** get in. IBKR credits them
straight into the position: they appear in no Trades, Transfers, Corporate
Actions or Statement of Funds row, only as tax lots with a cost basis and no
originating order. Booking each lot as a buy at IBKR's price with an
offsetting income row reproduces IBKR's cost basis while leaving cash
untouched. The external id is `ibkr-lot-<originatingTransactionID>`, so lots
that stay open are recognised on every later run. A lot that came from a
broker-to-broker transfer would be booked the same way; categorise the
offsetting row accordingly.

This is what makes holdings show a market value. Maybe's holdings calculator
prefers a stored price for the day, falls back to the trade price, and carries
the last price forward over gaps — so the account chart moves on the days you
import and stays flat between them. Import weekly and you get weekly marks.

### Securities

A ticker is looked up by symbol and exchange. IBKR's `listingExchange` codes
(`NYSE`, `ARCA`, `NASDAQ`, `IBIS2` …) are mapped to the ISO operating MICs Maybe
stores (`XNYS`, `XNAS`, `XETR` …) by a small table in
`IbkrImport::Statement::OPERATING_MICS`; an unmapped exchange leaves the MIC
empty, which is how a hand-entered ticker looks too. A ticker entered by hand
without an exchange is reused rather than duplicated with one.

New securities are created **offline** with the name IBKR gives, because no
market data provider is configured in this checkout — the upstream one (Synth)
has shut down. The IBKR marks are the only prices these securities will have,
which is why `Security::HealthChecker` now does nothing when there is no
provider: it used to mark every unfetchable ticker offline after a few weeks
and **delete its prices**, which would have wiped the marks this importer writes.

## Deduplication

Two layers, as in the Monobank importer:

1. **`external_id`**. Re-running any report is a no-op; a price already on
   file with the same figure is left alone and not counted, so a rerun that
   changes nothing queues no sync.
2. **Collision check** against hand-entered rows (no `external_id`) in the
   destination account: a trade for the same security, day and signed
   quantity, or a transaction for the same amount within **±1 day**. Matched
   rows are skipped and logged, not imported, and each existing row can
   explain only one statement row. Conversions are not collision-checked.

`FORCE=1` overrides layer 2.

## Testing without the API

A Flex token is personal and the report is a real brokerage statement, so
nothing is recorded against the live service.

**Unit tests** drive the parser, entry builder and importer from
`test/fixtures/files/ibkr/flex.xml` (two accounts, a buy, a sell, an option to
be skipped, a EUR.USD conversion, a EUR deposit, every cash type, positions
with lot rows including a bonus lot) and `Provider::IbkrFlex`
from WebMock stubs covering the two-step fetch, the "still generating" retry,
and IBKR's error envelope.

**End to end**, seed the cache and run with `OFFLINE=1`:

```bash
bin/rails ibkr:seed FIXTURE=test/fixtures/files/ibkr/flex.xml ITEM=ib
bin/rails ibkr:import OFFLINE=1 DRY_RUN=1
```

## Not built yet

- **Scheduling.** No cron, no background job. It is a rake task you run, like
  the Monobank one. The plumbing for a nightly job exists (`config/schedule.yml`
  is auto-loaded by sidekiq-cron) if that changes.
- **Options, futures and bonds.** Reported as skipped; record them by hand if
  they matter to the balance.
- **A single sidebar line per IBKR account.** Each currency is its own Maybe
  account; grouping them visually would be a UI change.
- **Corporate actions** (splits, mergers). Not in the sections read; a split
  would show as a wrong quantity until fixed by hand.
- **Daily price history.** Only report-date marks and trade-day closes. A
  price provider would fill the days between; none is wired up.
