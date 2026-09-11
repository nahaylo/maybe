# Changelog

All notable changes to this fork are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.7.0] - 2026-09-11

A self-hosted fork of Maybe tuned for a Ukrainian household: UAH as the default
currency, free exchange-rate providers, a Monobank statement importer, and a
set of asset-tracking features (vehicles, deposits, businesses) on top of the
stock account types.

### Added

#### Multi-currency and exchange rates
- Two free, keyless exchange-rate providers replacing the defunct Synth API:
  `Provider::Frankfurter` (ECB reference rates, 30 currencies) and
  `Provider::Nbu` (National Bank of Ukraine, any pair involving UAH).
  `ExchangeRate.provider_for(from:, to:)` picks whichever covers the pair.
- `ExchangeRate.find_rate_on_or_before` fetches the rate for the exact date
  and otherwise carries the last published rate forward over weekends and
  holidays instead of failing.
- `bin/rails exchange_rates:backfill` seeds historical rates for every pair
  the family uses. Optional positional arguments `[from,to,start_date,end_date]`
  restrict it to one pair and range; `REVERSE=1` also imports the inverse
  direction and `CLEAR_CACHE=1` overwrites rates already stored instead of
  only filling gaps.
- The account sidebar warns when the app cannot fetch rates or today's rates
  are missing (the balance sheet silently converts at parity otherwise), with
  a **Fetch latest rates** button that queues a snapshot import.
- Cross-currency transfers: the transfer form shows the market rate for the
  pair and date, lets you override the destination amount, and the transfer
  drawer shows the derived rate. `GET /exchange_rate` serves the lookup and
  `POST /exchange_rate` imports a missing pair on demand (the **Fetch rate**
  button); both accept only currencies the family actually uses.
- A cross-currency transfer with no rate on file and no destination amount is
  rejected with an explanatory error instead of being booked 1:1.
- UAH is now the top-priority currency in every currency dropdown.
- Docs: `docs/development/exchange-rates.md`.

#### Monobank import
- Statement importer for the Monobank personal API, run as rake tasks:
  `monobank:connect`, `monobank:link`, `monobank:accounts`, `monobank:import`
  (with `FROM`, `TO`, `DRY_RUN`, `FORCE`, `REFRESH`, `OFFLINE`, `ONLY`),
  `monobank:seed`, `monobank:items`, `monobank:unlink`, `monobank:disconnect`.
- New tables `monobank_items` (one per API token, encrypted at rest) and
  `monobank_accounts` (token account → Maybe account link).
- New columns `entries.external_id` (dedupe key) and `transactions.mcc`
  (merchant category code).
- Deduplication against hand-entered rows: exact id, same-amount collision
  within an asymmetric date window, and same-day split detection.
- Opening-balance reconciliation that reports drift when the ledger is missing
  history before the imported window; credit limits are netted out.
- Response cache under `storage/monobank/` so the one-request-per-minute API
  limit is respected across dry runs and re-runs.
- Imported rows carry the `mono-import` tag, utility bills additionally
  `utilities-guessed`, and unsettled holds `pending-hold`.
- After a run that created rows the importer queues every family rule, so
  categorisation and asset attribution happen without a full family sync.
- Transaction and transfer drawers show a copyable record id. Copying works
  over plain HTTP too, which is how most self-hosted instances are reached.
- Docs: `docs/development/monobank-import.md`.

#### Rules engine
- New conditions: **Transaction category** (including "Uncategorized", so a
  rule can fill in only what nothing else set), **Transaction MCC** (numeric,
  with range operators), and **Transaction date** (before / on or before /
  after / on or after / on).
- New action **Attribute to account**, which tags spending as belonging to a
  vehicle or property without moving money.
- The rule editor dialog is wider.

#### Vehicles
- Odometer readings as a new `Mileage` entryable on vehicle accounts, entered
  with the **New mileage** button on the activity feed. One reading per day,
  vehicle accounts only, and readings must move forward. The vehicle's cached
  mileage refreshes from the latest reading.
- Optional **fuel category** per vehicle. The overview shows fuel spend,
  litres, and fuel economy (l/100 km), plus a per-interval economy series
  between consecutive readings.
- Cost tracking via `transactions.attributed_account_id`: running costs,
  purchase price, sale proceeds, total cost of ownership, and cost per km,
  each converted to the account currency at the rate on the row's own date.
  A row whose currency has no rate for that date is left out of the total
  rather than counted at parity.
- A **Costs** tab on the vehicle page listing every attributed and fuel
  transaction, paginated independently of the Activity tab. Vehicle pages open
  on the Overview tab.
- "Attributed to" selector in the transaction drawer and in bulk edit.

#### Accounts
- New account types **Deposit** and **Business**, both counted as cash on the
  balance sheet.
- Accounts can be converted between types, keeping their full history
  (`PATCH /accounts/:id/convert`).
- Manual drag-and-drop ordering of accounts (`accounts.position`), applied to
  the sidebar, the accounts page, the balance sheet, transaction filters and
  `GET /api/v1/accounts`. Reordering expires the cached balance sheet.
- Per-account custom icon (from the vendored Lucide set) and colour, falling
  back to the type defaults. A chosen icon takes precedence over an uploaded
  or institution logo.
- Naming convention `Name · Currency`: accounts sharing a base name sort
  together, with the family currency first.
- Income / expense / transfer type filter on the per-account activity feed,
  mirroring the global transaction list, with removable filter chips.
- The account sidebar keeps its scroll position across navigation, on desktop
  and mobile.

#### Transactions and categories
- Per-transaction **quantity and unit** (pcs, kg, g, lb, oz, l, ml, gal, m,
  cm, ft) on the form, drawer, row display and API v1. CSV imports map
  **Quantity** and **Unit** columns in the configuration step; a row with a
  non-positive quantity or unknown unit is flagged for cleaning.
- Transaction rows show a direction glyph and an Income / Expense / Transfer
  label, and income amounts carry a leading `+`.
- Two-step category picker (category, then subcategory) replacing a single
  grouped select that stopped being usable at a few hundred categories.
- Category and subcategory filters in transaction search, with a searchable
  checkbox list that hides groups with no matches.

#### Backups
- Settings > Backups (self-hosted; the page is admin-only): `pg_dump` of the
  whole database in PostgreSQL custom format to a folder under a host mount
  configured by `BACKUP_HOST_ROOT`, with listing, download and delete. Path
  handling is constrained to the mount; filenames are generated, never
  user-supplied.
- Docs: `docs/development/backups.md`.

#### Changelog and version
- The **What's new** page renders this file (`docs/CHANGELOG.md`) instead of
  upstream's latest GitHub release, so it always describes the code that is
  running. Each `##` heading becomes one release block.
- The version in the user menu links to the in-app changelog, and the commit
  link points at this fork.
- A test asserts the newest changelog entry matches `Maybe.version`, so the
  two cannot drift apart.

#### Developer experience
- `compose.yml` is tracked in the repository and is the reference Docker
  setup: it builds `web` and `worker` from the local source as
  `maybe-app:local`, publishes the app on host port **3088**, bind-mounts
  `app/`, `lib/`, `config/`, `db/`, `test/` and `docs/` so Ruby changes need
  only a restart, and threads `BUILD_COMMIT_SHA` into the image.
- `docs/development/` with `local-docker.md`, `testing.md` and a README index,
  and a CLAUDE.md section on working against the production-mode Docker stack.
- The commit SHA in the user menu degrades to nil when git is unavailable
  instead of taking down every page.

### Changed
- Version bumped to 0.7.0.
- Default currency is UAH.
- `Account.alphabetically` groups by base name and prefers the family currency;
  `Account.ordered` (position, then name) is the canonical list order.
- Accounts without a logo show their type's icon instead of the first letter
  of their name.
- The **New** dropdown on the account activity feed is replaced by plain
  buttons. **New balance** is offered on vehicle accounts only.
- Mileage is no longer edited on the vehicle form; it comes from odometer
  readings.
- The Docker image installs `postgresql-client-16` from the PostgreSQL apt
  repository so `pg_dump` matches the PostgreSQL 16 server.

### Fixed
- The test database no longer reads `POSTGRES_DB`, so a containerised test run
  cannot truncate the production database. It reads `POSTGRES_DB_TEST`
  (default `maybe_test`).
- Self-hosting settings no longer warn about a missing Synth key when a keyless
  provider is configured.
- Opening-balance detection ignores mileage readings when finding the first
  real entry.
- A vehicle bought through transfers reports its real purchase price instead
  of the zero opening anchor.
- Zero-amount transactions no longer match both the income and the expense
  type filter.
- A category whose parent is missing from a list stays visible as its own
  group instead of disappearing from the picker and filter.
- A failed deposit or withdrawal transfer on the trade form shows its error
  instead of raising.
- Selected options in multi-selects are readable in dark mode, and the What's
  new page's headings, inline code and code blocks render in both themes.

### Upgrade notes
- Run `bin/rails db:migrate`. Migrations added, in order:
  `add_quantity_and_unit_to_transactions`, `add_unit_to_imports`,
  `add_position_to_accounts`, `create_deposits_and_businesses`,
  `add_external_id_to_entries`, `add_mcc_to_transactions`,
  `create_monobank_items_and_accounts`, `add_fuel_category_to_vehicles`,
  `create_mileages`, `add_attributed_account_to_transactions`,
  `add_lucide_icon_to_accounts`, `add_color_to_accounts`.
- New environment variables, all optional: `BACKUP_HOST_ROOT` (backups mount,
  in `.env.example`), `BACKUP_SUBDIRECTORY` (initial backup folder, default
  `maybe-backups`) and `POSTGRES_DB_TEST` (test database name, default
  `maybe_test`).
- Rebuild the image once for this release: `docker compose build web` then
  `docker compose up -d`. The Dockerfile and the compiled stylesheet changed,
  and `compose.yml` gained bind mounts that are fixed at container creation.
  After that, Ruby and view changes need only `docker compose restart web
  worker`; Gemfile, Dockerfile or asset changes need a rebuild.
- After the first deploy run `bin/rails exchange_rates:backfill`, or use the
  **Fetch latest rates** button in the account sidebar, so foreign-currency
  balances stop converting at parity.
- `GET /api/v1/accounts` now returns accounts in the user's manual order
  rather than alphabetically.
