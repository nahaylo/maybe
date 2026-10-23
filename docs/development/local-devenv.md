# Local devenv Setup

Runs this checkout natively on macOS, without Docker: [devenv](https://devenv.sh)
starts Postgres, Redis, the web server and Sidekiq as ordinary processes, in
**production mode**, the same way the [Docker setup](local-docker.md) does.

Docker keeps working. The two setups share nothing but the source tree and
`.env`; each has its own database and `storage/`. Both serve on port 3088, so run
one at a time.

## Prerequisites

- [Nix](https://nixos.org/download) and [devenv](https://devenv.sh/getting-started/)
  (written against devenv 2.1).
- A `.env` in the repo root, the same file the Docker setup uses (see
  [`.env`](local-docker.md#env)). `SECRET_KEY_BASE` is the one value that must
  be there.

Nothing else: Ruby (the exact version in `.ruby-version`), Postgres 16, Redis,
libpq, libvips and libyaml all come from Nix.

## Files

| File | Purpose |
| --- | --- |
| `devenv.nix` | Services, environment and processes |
| `devenv.yaml` | Nix inputs (nixpkgs, nixpkgs-ruby for exact Ruby versions), `strict_ports` |
| `devenv.lock` | Pinned versions of those inputs |
| `.devenv/` | State, gitignored: the Postgres cluster, Redis data, installed gems |

The three config files are committed. `.gitignore` re-includes them explicitly,
because a global excludes file that ignores `devenv*` would otherwise hide them.

## Ports

Moved off the defaults so they never clash with another project's devenv
services (the usual 5432/6379) running at the same time:

| Service | Default | Here |
| --- | --- | --- |
| Web | 3000 | **3088** |
| Postgres | 5432 | **5582** |
| Redis | 6379 | **6529** |

Everything listens on `127.0.0.1` only. Unlike the Docker setup, which publishes
3088 on all interfaces, the app is not reachable from other devices on the
network.

`devenv.yaml` sets `strict_ports: true`. Without it devenv quietly moves a
service to the next free port when its own is taken, and `DB_PORT`/`REDIS_URL`
would then point at the wrong place.

### While Docker still holds 3088

`MAYBE_PORT` overrides the web port for one run:

```bash
MAYBE_PORT=3089 devenv up -d
```

### Hostname

The same `/etc/hosts` entry as for Docker (`127.0.0.1 maybe`) makes the app
reachable at <http://maybe:3088>. See [Custom hostname](local-docker.md#custom-hostname).

## Starting and stopping

```bash
devenv up -d                 # start everything in the background
devenv processes list        # postgres, redis, web, worker -- expect "ready"
devenv processes down        # stop everything (data is kept)
```

`devenv up` without `-d` runs in the foreground.

On start, `web` waits for Postgres, runs `db:prepare` (creates the database or
applies pending migrations, as the Docker entrypoint does) and
`assets:precompile`, then starts the server. A fresh database opens on the
registration page.

## Environment variables

| Source | What it sets |
| --- | --- |
| `env` in `devenv.nix` | `RAILS_ENV=production`, `SELF_HOSTED`, SSL flags, `DB_HOST`/`DB_PORT`, `REDIS_URL`, build settings |
| `.env`, read when a shell or process starts | Secrets and host values: `SECRET_KEY_BASE`, `APP_DOMAIN`, `BACKUP_HOST_ROOT`, ... |
| Your shell | Wins over `.env` for any variable already set |

`.env` is not loaded by Rails here: `dotenv-rails` is in the development and test
groups only. devenv has its own `dotenv` option, but it copies the values into
the Nix store, which every user on the machine can read. So `devenv.nix` reads
`.env` itself at runtime, the way Compose does: `KEY=value` per line, surrounding
quotes stripped, no shell expansion (an unquoted path with a space, such as
`BACKUP_HOST_ROOT`, works).

`BACKUP_HOST_ROOT` means the same folder in both setups, used differently.
Docker bind-mounts it at `/rails/backups`; here nothing is mounted, so
`DatabaseBackup` writes into it directly. The folder chosen in Settings >
Backups is a subfolder of it either way, so existing backups keep showing up.
If it is unset or does not exist, backups fall back to `storage/backups` and the
settings page says so.

`.env` values meant for Docker are harmless here. `POSTGRES_PASSWORD` is ignored:
the cluster uses trust authentication on `127.0.0.1`, and the role is your macOS
user (`POSTGRES_USER` defaults to it).

## Applying code changes

Production mode loads classes and templates once at boot, exactly as under
Docker, so long-running processes need a restart. The difference is that
nothing needs rebuilding: there is no image, and assets are recompiled each time
`web` starts.

| What you changed | What to run | Roughly |
| --- | --- | --- |
| Anything run through `devenv shell` (rake tasks, `runner`, `console`, tests) | nothing | instant |
| Ruby or views served by the web server | `devenv processes restart web` | ~10s |
| Code Sidekiq runs (jobs, syncs, imports queued from the UI) | `devenv processes restart worker` | ~2s |
| CSS/JS | `devenv processes restart web` | ~10s |
| `Gemfile` | `devenv shell -- bundle install`, then restart both | |
| `devenv.nix` / `devenv.yaml` | `devenv processes down && devenv up -d` | |

`restart` takes one process at a time.

## Everyday commands

```bash
# Health
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3088/up   # expect 200

# Logs (no follow mode; -n for more lines)
devenv processes logs web
devenv processes logs worker -n 200

# Rails console / runner / rake
devenv shell -- ruby bin/rails console
devenv shell -- ruby bin/rails runner 'puts Family.first&.currency'
devenv shell -- ruby bin/rails monobank:import DRY_RUN=1

# psql against the app database
devenv shell -- psql -h 127.0.0.1 -p 5582 maybe_production
```

Start Rails as `ruby bin/rails ...`, not `bin/rails ...`; see the next section.

## Running tests

The test database (`maybe_test`) lives in the same Postgres cluster. `.env.test`
is read by dotenv as usual, since `RAILS_ENV=test` loads `dotenv-rails`.

```bash
devenv shell -- bash -c 'export RAILS_ENV=test; ruby bin/rails db:test:prepare && ruby bin/rails test'
```

The suite gives the same result as inside the Docker image. See
[Running tests](testing.md) for the database-isolation rules that apply to both.

## macOS quirks handled in `devenv.nix`

Each of these cost time to find; the comments in `devenv.nix` explain them in
place.

- **libvips and `DYLD_*`.** ruby-vips loads libvips with `dlopen`, so it needs
  `DYLD_FALLBACK_LIBRARY_PATH`. macOS strips every `DYLD_*` variable when a
  process goes through a system binary, and `bin/rails`, `bundle` and `sidekiq`
  all start with `#!/usr/bin/env ruby`. The variable is therefore exported in
  the Nix shell, and Ruby is started directly: `ruby bin/rails`,
  `ruby -S bundle exec sidekiq`. Started through the shebang, Rails boots fine,
  but processing an image (a profile photo upload) fails to find libvips.
- **Bundler version.** `Gemfile.lock` pins Bundler in `BUNDLED WITH`. When the
  running Bundler differs, Bundler installs the pinned one and re-executes the
  command through its shebang, which drops `DYLD_*` again. `BUNDLER_VERSION` is
  set from `Gemfile.lock`, so the pinned version is loaded up front and
  `Gemfile.lock` is never rewritten.
- **`pg_config`.** nixpkgs ships it as a separate output of `libpq`, and a
  version manager's shim (asdf) can shadow it on `PATH`. The `pg` gem is pointed
  at it explicitly through `BUNDLE_BUILD__PG`.
- **solargraph.** devenv's Ruby module adds the solargraph language server by
  default, and it fails to build on this nixpkgs. It is disabled; the app does
  not need it.

## Data

The devenv database and `storage/` start empty and are separate from Docker's
`db-data` and `app-storage` volumes. Nothing is migrated automatically.

### Moving data from Docker

Encrypted columns (the Monobank and IBKR access tokens) stay readable only if
both setups derive the same keys. With no `ACTIVE_RECORD_ENCRYPTION_*` variables
and no `config/master.key`, the keys come from `SECRET_KEY_BASE`, so check that
it is the same on both sides before moving anything:

```bash
docker compose exec -T web sh -c 'printf %s "$SECRET_KEY_BASE" | sha256sum | cut -c1-16'
devenv shell -- bash -c 'printf %s "$SECRET_KEY_BASE" | shasum -a 256 | cut -c1-16'
```

Then, with `devenv up -d` already run once (so the cluster exists):

```bash
# 1. Stop the app on both sides, so nothing writes during the dump.
docker compose stop web worker
devenv processes stop web
devenv processes stop worker

# 2. Dump Docker's database.
docker compose exec -T db sh -c \
  'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc --no-owner --no-acl' > maybe.dump

# 3. Replace the devenv database with it. This drops maybe_production, so make
#    sure it is the empty one devenv created.
devenv shell -- bash -c '
  dropdb   -h 127.0.0.1 -p 5582 maybe_production
  createdb -h 127.0.0.1 -p 5582 maybe_production
  pg_restore -h 127.0.0.1 -p 5582 -d maybe_production --no-owner --no-acl --exit-on-error maybe.dump'

# 4. Copy storage/: statement caches, backups. Works on a stopped container.
docker compose cp web:/rails/storage/. ./storage

# 5. Start devenv on 3088 (Docker's web is stopped, so the port is free).
devenv processes down && devenv up -d
```

`--no-owner` matters: Docker's role is `maybe_user`, which does not exist in the
devenv cluster.

To check the result, compare row counts of every table on both sides, and that
the tokens decrypt:

```bash
devenv shell -- ruby bin/rails runner \
  'puts (MonobankItem.all + IbkrItem.all).all? { |item| item.access_token.present? }'
```

Docker's volumes are left as they were, so going back is `devenv processes down`
followed by `docker compose up -d`. Anything written under devenv in the
meantime is not in Docker's database.
