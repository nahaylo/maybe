# Running Tests

The project uses **Minitest + fixtures** (never RSpec or factories). Since this
setup has no local Ruby toolchain, tests run inside the app image.

## Database isolation

`config/database.yml` used to read the **test** database name from the same
variable as production:

```yaml
test:
  database: <%= ENV.fetch("POSTGRES_DB") { "maybe_test" } %>
```

`POSTGRES_DB` is `maybe_production` inside the containers, so a test run
targeted the real database — and the suite truncates tables between tests.

This is now fixed. The test entry reads a **separate** variable with a safe
literal default:

```yaml
test:
  database: <%= ENV.fetch("POSTGRES_DB_TEST") { "maybe_test" } %>
```

Nothing needs to be set for this to be safe: with no `POSTGRES_DB_TEST` in the
environment it falls through to `maybe_test`. Verify any time with:

```bash
docker compose run --rm -e RAILS_ENV=test web bin/rails runner \
  'puts Rails.application.config.database_configuration["test"]["database"]'
# => maybe_test
```

> **`.env.test` does not reach the containers.** `.dockerignore` excludes
> `/.env*` from the image, and only `app/`, `lib/`, `config/`, `db/` and
> `test/` are bind-mounted — not the repo root. The file exists for running
> tests *outside* Docker, where dotenv will read it. Inside Docker, use
> `-e VAR=value` or the `environment:` block instead. See
> [local-docker.md](local-docker.md) for how environment variables reach
> containers.

## The `git` gotcha (fixed)

`config/initializers/version.rb` used to shell out to `git rev-parse HEAD`
unguarded in every non-production environment. The slim runtime image ships no
`git` binary and no `.git` directory, so every view rendering the user menu
raised `ActionView::Template::Error: No such file or directory - git` -- **65
errors** across the suite, cleared only by putting a stub `git` on `PATH`.

`Maybe.commit_sha` now degrades to `nil` instead of raising, so no stub is
needed. It resolves in this order:

1. `ENV["BUILD_COMMIT_SHA"]`, set at image build time and passthrough-able via
   `compose.yml` (see [local-docker.md](local-docker.md)).
2. `git rev-parse HEAD`, outside production only, rescued if `git` is missing.
3. `nil`, in which case the version line simply omits the SHA.

`test/lib/maybe_test.rb` pins this. If you see the stub in an older command,
drop it.

## First-time setup

Create the test database once:

```bash
docker compose run --rm -e RAILS_ENV=test web bin/rails db:prepare
```

## Running the suite

```bash
docker compose run --rm \
  -e RAILS_ENV=test \
  -e DISABLE_PARALLELIZATION=true \
  -e PLAID_CLIENT_ID=test_client_id -e PLAID_SECRET=test_secret -e PLAID_ENV=sandbox \
  web bin/rails test
```

The Plaid variables are needed because `test_helper.rb` sets its `ENV[...] ||=`
defaults *after* `config/environment` has already been loaded, so
`Rails.application.config.plaid` is `nil` and `Provider::PlaidSandbox` raises.
Passing them as real env vars avoids 6 unrelated errors.

### A single file or test

```bash
docker compose run --rm -e RAILS_ENV=test web \
  bin/rails test test/models/provider/nbu_test.rb

docker compose run --rm -e RAILS_ENV=test web \
  bin/rails test test/models/provider/nbu_test.rb:12
```

Test files are bind-mounted, so edits are picked up without rebuilding.

## Expected results

With the Plaid variables in place:

```
1039 runs, 6124 assertions, 30 failures, 0 errors, 9 skips
```

The run and assertion counts drift as features are added; **30 failures, 0
errors** is the number that matters. Those **30 failures are pre-existing** and
unrelated to any local change — they
are upstream tests that assume managed-hosting behaviour, such as
`OnboardableTest` expecting a subscription redirect that self-hosted mode does
not perform. Verified by running the same suite from a pristine `git worktree`
of `HEAD`, which produces the same counts.

When judging whether a change broke something, compare against that baseline
rather than expecting a fully green suite.

## Linting

```bash
docker compose run --rm web bin/rubocop <files>
docker compose run --rm web bin/rubocop -f github -a       # autocorrect
docker compose run --rm web bin/brakeman --no-pager        # security scan
```

Run RuboCop only on files you changed, never the whole project.

## Recording VCR cassettes

External HTTP calls are recorded into `test/vcr_cassettes/`. A test whose
cassette does not exist yet records it on first run (VCR's default `:once`
mode), which requires network access. Commit the resulting YAML so later runs
are offline and deterministic.
