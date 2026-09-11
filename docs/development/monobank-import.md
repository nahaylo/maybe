# Monobank import

Pulls card transactions from the **Monobank personal API** into Maybe accounts,
categorises what it confidently can, and tags the rest for manual review.

This is not a Plaid-style live sync. It is a rake task you run when you want to
catch up, deliberately closer to the CSV importer than to a bank connection:
every row it creates is an ordinary, fully editable transaction.

> **Status:** phase 1 is built and tested against fixtures. It has not yet been
> run against the live API — see [Not built yet](#not-built-yet).

## Why not Plaid

Plaid has no Ukrainian coverage. Monobank publishes a free personal API instead,
which returns the same data a bank statement would, with two things a CSV export
does not have: a stable transaction id, and an **MCC** code.

Both matter enough to shape the design. The id makes re-running an import safe;
the MCC is the strongest category predictor available.

## Setup

**1. Get a token** from <https://api.monobank.ua/>. It is read-only and scoped
to your own accounts.

**2. Register it as a connection:**

```bash
bin/rails monobank:connect NAME=personal TOKEN=<token>
```

The token is stored on `monobank_items`, encrypted when the instance has Active
Record encryption keys configured (the same condition `PlaidItem` uses).

The token is deliberately not an environment variable. One would tie an
instance to exactly one Monobank client, and its value would show up in
plaintext in any `docker compose config` output.

**3. Link each account:**

```bash
bin/rails monobank:accounts     # lists this connection's ids and balances
bin/rails monobank:link ITEM=personal ID=<monobank_id> ACCOUNT="Mono UAH card"
bin/rails monobank:items        # what is linked now
```

`monobank:unlink ACCOUNT="..."` stops importing into an account, and
`monobank:disconnect NAME=personal` removes a connection and all of its links.
Neither touches entries that were already imported.

## The one-request-per-minute rule

**Monobank allows one request per 60 seconds per token, across every endpoint.**
A second request inside the window returns `429`.

Everything else in this document follows from that:

- Raw responses are cached to `storage/monobank/`, so a dry run and a real run
  cost one API call between them. `storage/` is a named Docker volume, so the
  cache survives `docker compose up -d`, unlike `tmp/`.
- The importer never retries automatically. A `429` raises
  `Provider::Monobank::RateLimitedError` and tells you how long to wait, rather
  than silently blocking a rake task for a minute.
- Anything derivable from an already-fetched row is stored, not re-fetched.
  This is the argument for the `mcc` column below.

A statement request also covers **at most 31 days + 1 hour**.

## Connections and links

A Monobank token belongs to one Monobank client and can read only that client's
accounts, so the token *is* the connection — not a global setting. Two tokens (a
second person, a second client) are two `monobank_items` rows, each with its own
accounts and its own rate limit.

```
monobank_items      one per token: family, name, access_token
monobank_accounts   monobank_item_id + monobank_id -> account_id
```

**The foreign key deliberately lives on `monobank_accounts`, not on `accounts`.**
Plaid puts `plaid_account_id` on the account because the whole app reads it — the
`manual` scope, `Account#linked?`, several views, the assistant's `get_accounts`
function. Nothing outside the importer asks whether an account is a Monobank one,
so nothing outside the importer carries the field. Dropping the two tables
removes the feature without touching a core table.

A consequence worth knowing: `Account#linked?` stays **false** for these
accounts, so balance editing and manual entries stay enabled in the UI. That is
correct — the importer writes transactions but does not own the balance.

Being linked is what makes an account importable; there is no separate `enabled`
flag, and no list of accounts you have decided against. `monobank:accounts`
simply shows every account the token can see, marking the linked ones.

### Rate limiting and the cache are per connection

Each item gets **one** `Provider::Monobank` for the whole run, memoized on
`MonobankItem#provider`. The once-a-minute cooldown lives in an instance variable
on that client, so building a fresh one per request would reset it and `429` on
the second call. One client per token also means two tokens run at full speed
instead of queueing behind each other.

Statement cache keys carry Monobank's own account id, which is unique per client,
so they cannot collide. `client-info` has no id in it and **is** scoped, via
`MonobankImport::Statement.client_info_key(item.cache_scope)` — without that a
second token would overwrite the first's cached account list.

## Date range

```bash
bin/rails monobank:import                      # from = last entry date
bin/rails monobank:import FROM=2026-08-21      # explicit
bin/rails monobank:import FROM=2026-08-21 TO=2026-08-31
```

With no `FROM`, each account starts at **its own last entry date**, so an account
that has been dormant for months backfills its real gap instead of being stranded
at a date a busier sibling reached. An account with no entries at all falls back
to the latest date across every linked account. `TO` defaults to today.

The range starts *on* that date rather than the day after, so the last known day
is re-fetched and re-matched. Overlap is free: see deduplication.

## Field mapping

| Monobank | Maybe | Note |
| --- | --- | --- |
| `id` | `entries.external_id` | dedupe key |
| `time` (unix) | `entries.date` | Kyiv local date |
| `amount` (minor units, **negative = spend**) | `entries.amount` | `-amount / 100` |
| `description`, `counterName` | `entries.name` | |
| `mcc` | `transactions.mcc` + category | |
| `operationAmount`, `currencyCode` | `entries.notes` | original currency, foreign purchases |
| `hold: true` | *skipped* | unsettled; the amount can still change |
| `commissionRate`, `cashbackAmount` | *ignored*, reported when non-zero | |

Two conversions are easy to get wrong:

- **The sign flips.** Monobank uses negative for money leaving the account;
  Maybe uses **positive for outflows**. `entry.amount = -row.amount / 100`.
- **`balance` includes the credit limit.** A card with 5,000 ₴ of own funds and
  a 20,000 ₴ `creditLimit` reports a `balance` of 25,000 ₴; own funds are the
  difference. Reconciliation compares against `balance - creditLimit`.

The credit limit is deliberately **not** in the account map. It comes live from
`client-info`, which the importer calls anyway for the reconciliation, and a
hardcoded copy would silently drift when the bank changes it.

## Deduplication

Two layers, because the interesting case is not re-running the same range — it
is importing over transactions you already entered by hand.

1. **`external_id`**, unique per account. Re-running any range is a no-op.
2. **Collision check.** An existing entry in the same account for the same
   amount within **±3 days** is treated as the same transaction: skipped and
   logged, not imported. Nearest date wins, and a matched entry is consumed so
   it cannot explain a second row.
3. **Split check.** A charge whose amount equals the sum of two or three
   **same-day, same-sign** entries is treated as already recorded.

`FORCE=1` overrides layers 2 and 3.

The ±3 day window is not arbitrary. Purchases get written down when they are
noticed, not when they post: over a month of real statements a couple of larger
charges were recorded two and three days late. A ±1 day window duplicated both,
and widening past three days catches nothing further.

The split check is the narrow, reliable half of an idea that failed in its
general form. Sum-matching across a three-day spread produced a false positive —
a refund plus an unrelated purchase reproducing the arithmetic. Restricting it
to the same day *and* to components of one sign removes both degrees of freedom
that made it wrong, and it then correctly recognises, say, a 3,750.00 ₴ shop
charge that had been written down as 2,000.00 + 1,750.00.

Splits still cannot be *predicted* at import time — nothing in a statement says
a charge will be divided. They can only be *recognised* against entries that
already exist.

`external_id` is a new column rather than a reuse of the empty `entries.plaid_id`
because `Entry#linked?` is defined as `plaid_id.present?`, and the transaction
drawer disables date, amount, and nature for linked entries — locking exactly
the fields this feature exists to let you edit.

## The opening-balance check

Every statement row carries the running balance after it, so the balance *before*
the first row is free information. The importer compares it to the ledger and
reports any drift:

```
!! opening balance on 2026-07-16: bank 1200.0, ledger 1250.0, drift -50.0
   history BEFORE this window is missing -- widen FROM, this import cannot fix it
```

This is the only check that can see a gap **outside** the imported window. A
closing-balance comparison cannot: both sides move by the same amount, so an
import over a wrong starting figure still reconciles perfectly at the end and
looks clean.

It exists because "last entry date" turned out to be a poor proxy for "the
ledger is complete up to here". Picture a card whose last entries are a
hand-entered transfer and currency exchange that net to zero, while the last row
actually *sourced from the bank* is seven weeks older. Starting from the last
entry date steps straight over those seven weeks of real card activity. The
check reports the drift immediately; widening `FROM` back to the last bank-sourced
row recovers the missing rows, which sum to exactly that drift.

The credit limit is subtracted, since Monobank reports balance inclusive of it.
The check is skipped rather than guessed at when it cannot be computed -- no
rows, no balance field, or no cached `client-info` to read the limit from -- and
it never spends one of the token's once-a-minute requests.

## Categorisation and tags

Three family tags, created on first run:

| Tag | Meaning |
| --- | --- |
| `mono-import` | provenance — on every imported row, permanently |
| `utilities-guessed` | the MCC 4900 rule below fired |

**Categorisation lives in Maybe's rules engine** (Settings > Rules), not in this
importer. Merchant rules are one per name; MCC rules are grouped by outcome
using the `transaction_mcc` condition, so 16 codes are 11 rules.

Every rule carries a second condition, `category = Uncategorized`. The guard
matters: a match otherwise reaches every transaction back to the rule's
effective date, whatever category it already carries.

Two consequences of that move:

- **Rows arrive uncategorised.** Rules only run inside a *family* sync, and an
  account sync is not one, so `monobank:import` queues every rule itself after
  a run that created rows. That covers category, merchant and asset
  attribution (`attribute_to_account`) in one pass.
- **A rule can add a tag but never remove one.** `SetTransactionTags` assigns
  `tag_ids = [one]`, replacing the list rather than editing it, so there is no
  "drop this tag" action. This is why nothing tags a row as needing review —
  see below.

There is no mapping file left in the importer — every categorisation rule lives
in Settings > Rules. On a typical month of statements, MCC rules alone resolve
about half the rows and MCC + merchant rules about three quarters; the rest
arrive uncategorised. Expect worse than that on first contact with an unseen
merchant.

### Utility payments: filed under one property, then corrected by hand

When you pay utility bills for more than one property, they tend to be paid in
one sitting, and **nothing in the Monobank payload says which property a bill
belongs to** — same `description`, same MCC 4900, and the counterparty fields
are empty. The API has no per-transaction detail call either; the whole
personal API is five endpoints:

```
/bank/currency   /bank/sync   /personal/client-info
/personal/statement/{account}/{from}/{to}   /personal/webhook
```

`StatementItem` documents 18 fields but Monobank populates them selectively.
Across a few hundred real transactions, `receiptId` appeared on roughly
half the rows, `counterName`/`counterIban`/`counterEdrpou` only on own-account
transfers, `comment` almost never, `invoiceId` never — and **none** of the MCC
4900 rows carried any of them. The Monobank app shows the payment purpose, which
includes a per-property account number and address and would be a perfect key,
but neither the statement API nor the CSV export carries it.

So one rule per bill description in Settings > Rules files **every** utility
bill under the same default property, for example:

```
Холодна вода       -> Home / Water         Електроенергія -> Home / Electricity
Газ (доставлення)  -> Home / Gas delivery  Газ            -> Home / Gas
Квартплата         -> Home / Building fees
```

They match on `=`, not `contains`: `"Газ"` is a substring of
`"Газ (доставлення)"`, so a contains-match would claim both and whichever rule
ran first would win.

Every MCC 4900 row is tagged **`utilities-guessed`** at import, and the import
prints a boxed notice listing them, because half of them are wrong by design and
the only way they get fixed is if you remember to look.

An earlier version inferred the property from time clustering — utility payments
arrive in bursts, with one property's bills paid within a few seconds of each
other and the next property's starting under a minute later. It was right on
every row of the month it was built against, but that was one month of evidence
for a rule that fails silently, and it kept a whole categorisation engine alive
in the importer for one case. Amount is no substitute either: over years of
bills the best possible single threshold still misclassifies a meaningful share
of every bill type, and which property has the *larger* electricity bill can be
the opposite of what one month suggests.

**If Monobank ever exposes the payment purpose, replace these rules with one
exact match per property account number and drop the tag.**

### Split charges: not detected

One shop charge is sometimes recorded as two transactions (two items bought in
one visit). **At import time this is undetectable in principle** — the statement
has one row, and the decision to split it exists only in your head.

Sum-matching against already-entered transactions was tried and scored one true
positive against one false positive: a refunded supermarket charge plus an
unrelated purchase produced the same arithmetic as a split. Leaving them
uncategorised covers it. A tag that is wrong half the time trains you to ignore
it.

## What gets stored

Beyond the standard entry fields:

| Column | Type | Why |
| --- | --- | --- |
| `entries.external_id` | string | Dedupe. Without it, no import is safely repeatable. |
| `transactions.mcc` | integer | The category signal, and what the `transaction_mcc` rule condition matches on. Stored rather than merely consumed so a new rule reaches the back catalogue without re-fetching — which the rate limit makes expensive. |

Deliberately **not** stored as columns for now: the counterparty
(`counterName`/`counterIban`/`counterEdrpou`), the original foreign amount, and
the full raw payload. The first two go into `notes`; the raw JSON stays in the
`storage/monobank/` cache. The counterparty is the one most likely to earn a
column in phase 2 — it is the best merchant signal on business (sole-trader)
accounts, where `description` is generic.

## Testing without the API

There is no sandbox and no test token, so nothing here is exercised against the
live API. Two mechanisms cover it instead.

**Unit tests** drive the parser, categoriser and entry builder from
`test/fixtures/files/monobank/statement.json`, and `Provider::Monobank` from
WebMock stubs — the one provider test in this project that does not use VCR,
because there was no live call to record.

**End-to-end**, seed the response cache and run with `OFFLINE=1`, which makes
any cache miss an error rather than a request:

```bash
bin/rails monobank:seed FIXTURE=statement.json \
  ACCOUNT=<monobank_id> FROM=2026-08-01 TO=2026-08-21
bin/rails monobank:import OFFLINE=1 DRY_RUN=1 FROM=2026-08-01 TO=2026-08-21
```

Replaying a real statement over the ledger it was already hand-entered into is
the strongest check available. Pick a week where both sides are known to be
complete and expect every statement row to resolve, roughly like:

```
  skipped_collision    32
  skipped_split         1
  created               2
```

The only rows that should be created are ones genuinely missing from the ledger,
typically an in-and-out pass-through that was never recorded in this account.
Those net to zero, so **the account balance does not move** — which is the
property to check after any import over known-good history.

## Not built yet

Phase 1 covers a single linked account in one direction. Still open:

- **Transfers.** With one account linked, the far leg of an internal move does
  not exist, so those rows land as plain transactions until the other account is
  imported. Matching becomes possible once the remaining accounts are linked.
- **Scheduling.** No cron, no background job. It is a rake task you run.
- **The account map in the database**, with a settings screen (phase 2).
- **Jars** (`/personal/client-info` returns none today).
