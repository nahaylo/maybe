# Exchange Rates

Maybe supports multi-currency accounts, but the only upstream rate provider was
**Synth**, and its API is gone:

```bash
$ host api.synthfinance.com
Host api.synthfinance.com not found: 3(NXDOMAIN)
```

`Provider::Registry` hardcodes `%i[synth]` for the `:exchange_rates` concept, so
on a fresh self-hosted install `ExchangeRate.provider` returns `nil`, no rates
are ever fetched, and any conversion raises `Money::ConversionError`.

This directory adds free, keyless replacements.

## How rates are used

`Money#exchange_to` looks up a rate for the **exact pair and date**:

```ruby
Money.new(100, "USD").exchange_to("UAH")
# => looks up ExchangeRate where from_currency: "USD", to_currency: "UAH", date: today
```

Two consequences worth remembering:

- **Rates are directional.** A `USD -> UAH` row does not satisfy a `UAH -> USD`
  lookup. Both rows are needed.
- **Rates are per-date.** Historical charts need a row for every day, not just
  today.

`ExchangeRate::Provided.find_or_fetch_rate` checks the database *before* calling
a provider, which is why locally imported rates work with no provider
configured at all.

## Providers

| Provider | Source | Covers | Range support |
| --- | --- | --- | --- |
| `Provider::Frankfurter` | ECB via `api.frankfurter.dev` | ~31 major currencies, **no UAH** | Whole range in one request |
| `Provider::Nbu` | National Bank of Ukraine | UAH against 45 currencies | One request per day |

Both implement `Provider::ExchangeRateConcept`, so they plug into the existing
`ExchangeRate::Importer` and inherit its gapfilling and upsert behaviour.

Two providers exist because neither alone is sufficient: the ECB reference feed
does not publish UAH, and NBU only quotes pairs involving UAH.

### NBU quirks

NBU quotes **UAH per one unit of the foreign currency**, so the UAH-based
direction is computed as the reciprocal:

```
USD -> UAH  =  44.7064          (as published)
UAH -> USD  =  1 / 44.7064      (inverted)
```

It also publishes on business days only. Non-publication days return nothing and
are skipped; `ExchangeRate::Importer` gapfills them using last-observation-
carried-forward, which is why a 91-day range yields 91 rows.

## Backfilling

`ExchangeRate::Backfiller` routes each currency pair to the first provider that
supports it. The rake task is a thin wrapper around it.

```bash
# Auto-detect the pairs the app needs, last 2 years
docker compose exec web bin/rails exchange_rates:backfill

# An explicit pair and date range
docker compose exec web bin/rails "exchange_rates:backfill[USD,UAH,2024-01-01,2024-12-31]"

# Both directions (recommended -- rates are directional)
docker compose exec -e REVERSE=true web bin/rails exchange_rates:backfill

# Overwrite existing rows instead of only filling gaps
docker compose exec -e CLEAR_CACHE=true web bin/rails exchange_rates:backfill
```

Positional arguments are `[from, to, start_date, end_date]`, all optional. Leave
`from` and `to` empty to auto-detect while still passing dates:

```bash
docker compose exec web bin/rails "exchange_rates:backfill[,,2026-05-27,2026-08-25]"
```

Auto-detection selects any account or entry denominated differently from the
currency it rolls up into, so an account in USD inside a UAH family produces the
pair `USD -> UAH`.

Example output:

```
  USD -> UAH: 91 new rate(s) via Nbu
  UAH -> USD: 91 new rate(s) via Nbu
Done.
```

The task is idempotent — a second run reports `0 new rate(s)` and skips the
provider call entirely. A pair no provider covers is reported as `SKIPPED`
rather than failing the run, and a provider error is caught per pair so one bad
pair does not abort the rest.

### Verifying

```bash
docker compose exec web bin/rails runner '
  puts ExchangeRate.count
  puts Money.new(100, "USD").exchange_to("UAH").format
'
```

## Transfers between currencies

The transfer form shows the converted destination amount whenever the two
accounts use different currencies, and lets you override it before submitting.

- `GET /exchange_rate?from=USD&to=UAH&date=…&amount=…` returns the rate plus the
  converted amount. **The multiplication and rounding happen server-side** (in
  `ExchangeRatesController`), so the prefilled value uses the same BigDecimal
  arithmetic and currency precision the server applies when the transfer is
  created — the browser never does money math.
- When the exact date has no rate, the **last published rate on or before that
  date is carried forward** (`ExchangeRate.find_rate_on_or_before`). Providers
  publish on business days only and a backfill may not reach today yet, so an
  exact-date miss is normal. The response includes `rate_date` and `stale: true`,
  and the form notes "last available rate, from <date>".
- Only when the pair has **never** been imported does the response carry
  `"rate": null` — with **HTTP 200**, not an error. The form then shows a warning
  and leaves the field empty for manual entry.
- The endpoint only serves currency pairs the family actually uses.
  `find_or_fetch_rate` can call a provider on a cache miss, and this route is not
  covered by Rack::Attack.

`Transfer::Creator` resolves the destination leg in this order:

1. currencies match → destination equals the source amount (any submitted
   destination amount is ignored);
2. a destination amount was supplied → it is used verbatim;
3. otherwise the last rate published on or before the date is applied and
   rounded to the destination currency's precision.

A rate is never carried *backwards*: a date earlier than the pair's oldest
imported rate still fails, because inventing a rate that predates the data
would be a guess.

**There is no 1:1 fallback.** `Transfer::Creator` previously passed
`fallback_rate: 1.0`, so a missing rate silently recorded 100 USD as 100 UAH.
It now fails when no rate exists at or before the date, which becomes a form
error:

> No exchange rate available from UAH to USD on 2025-01-01. Enter the destination
> amount manually.

`fallback_rate: 1` deliberately remains in `balance/sync_cache.rb`,
`holding/portfolio_cache.rb` and `UI/account/chart.rb` — those are read-side
display aggregations that persist nothing, and raising there would blank a
dashboard rather than prevent bad data.

The rate applied to a transfer is **not stored**. The transfer drawer shows it
derived as `inflow ÷ outflow` (`Transfer#derived_exchange_rate`), which is
display-only and quantized by each leg's rounding.

## Automatic refresh is not wired up

The scheduled `ImportMarketDataJob` (`config/schedule.yml`, weekdays at 22:00
UTC) resolves its provider through `Provider::Registry`, which still returns
`nil` for `:exchange_rates`. **The nightly job therefore does nothing**, and
rates stay only as current as the last manual backfill.

Two ways to close that gap:

1. Register the providers in `Provider::Registry` under the `:exchange_rates`
   concept, so the existing job picks them up.
2. Schedule the rake task separately (cron, or a `sidekiq-cron` entry).

## Adding another provider

1. Create `app/models/provider/<name>.rb` subclassing `Provider` and including
   `ExchangeRateConcept`.
2. Implement `fetch_exchange_rate` and `fetch_exchange_rates`, wrapping bodies
   in `with_provider_response` so failures return a `Provider::Response` instead
   of raising.
3. Implement `supports?(from:, to:)` so the backfiller can route pairs to it.
4. Add it to `ExchangeRate::Backfiller.providers`, ordered by preference.
5. Add a test with a VCR cassette (see [testing](testing.md)).
