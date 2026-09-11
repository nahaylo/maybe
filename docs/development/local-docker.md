# Local Docker Setup

The [official hosting guide](../hosting/docker.md) runs the published image from
`ghcr.io/maybe-finance/maybe:latest`. This setup differs in one important way:
**the app image is built from this checkout**, so local code changes (new
providers, rake tasks) are actually present in the running containers.

## Files

Two files drive the setup. Both are gitignored, so neither is committed.

| File | Purpose |
| --- | --- |
| `compose.yml` | Copied from `compose.example.yml`, then modified (see below) |
| `.env` | Secrets and host-specific values |

### `.env`

```bash
SECRET_KEY_BASE="<64 random bytes, hex>"   # openssl rand -hex 64
POSTGRES_PASSWORD="<random>"
OPENAI_ACCESS_TOKEN=""                     # optional, costs money when set
APP_DOMAIN="maybe:3088"                    # used for links in outgoing email
```

## Environment variables

There are four separate ways to set environment for the containers, and they do
**not** behave the same. Picking the wrong one is why a variable can look set
and still be missing at runtime.

| Mechanism | Reaches the container? | Use for |
| --- | --- | --- |
| `.env` beside `compose.yml` | **No** — only fills `${VAR}` inside `compose.yml` | Secrets referenced as `${...}` |
| `environment:` in `compose.yml` | Yes | Values every run needs (the `x-rails-env` anchor) |
| `env_file:` in `compose.yml` | Yes — file contents injected | Loading a whole `.env`-style file |
| `-e VAR=value` on `run` / `exec` | Yes, highest precedence | One-off overrides |

Precedence: `-e` → `environment:` → `env_file:` → image `ENV`. Inside the app,
`dotenv` only fills variables that are **not already set**, so it always loses
to every mechanism above.

Two consequences worth internalising:

- **A new variable must be added in two places.** `.env` supplies the value,
  and `x-rails-env` passes it through:

  ```yaml
  x-rails-env: &rails_env
    APP_DOMAIN: ${APP_DOMAIN:-localhost:3000}
  ```

- **`.env*` files are invisible inside the containers.** `.dockerignore`
  excludes `/.env*` from the image, and only `app/`, `lib/`, `config/`, `db/`
  and `test/` are bind-mounted — not the repo root. So `.env.test` has no
  effect under Docker; it exists for running tests outside a container, where
  dotenv reads it. To check what a container actually sees:

  ```bash
  docker compose run --rm web bash -c 'echo "$APP_DOMAIN"'
  ```

### `BUILD_COMMIT_SHA`

The user menu shows the running commit next to the version number. Published
images bake it in as a build arg; this checkout builds from local source, so it
has to come from the shell instead — Compose cannot run commands, and `.env`
files do not support command substitution:

```bash
BUILD_COMMIT_SHA=$(git rev-parse HEAD) docker compose up -d
```

Two caveats:

- **`docker compose restart` does not re-read `compose.yml`**, so the value
  refreshes only on `up -d`. After the restart-based workflow in
  [Applying code changes](#applying-code-changes), the SHA is whatever it was
  at the last recreate.
- **Source is bind-mounted**, so the running code is your working tree —
  uncommitted changes included. The SHA identifies the last commit, not what is
  actually executing.

Left unset, `Maybe.commit_sha` returns `nil` and the version line simply omits
the SHA, which is usually the more honest signal locally.

### `BACKUP_HOST_ROOT`

Host folder that database backups are written to, bind-mounted into `web` and
`worker` at `/rails/backups`. Set it in `.env`:

```bash
BACKUP_HOST_ROOT=/Users/you/Library/Mobile Documents/com~apple~CloudDocs
```

It is also passed through `x-rails-env`, because a container cannot see the host
side of its own bind mount — without that, Settings > Backups could only show the
in-container path.

Two things follow from mounts being fixed at container-creation time:

- Changing this needs `docker compose up -d`, not `restart`.
- The folder *within* it is chosen in Settings > Backups and takes effect
  immediately. That is why it is worth pointing this at a parent directory
  (an iCloud Drive root, say) rather than a single backup folder.

Leaving it unset falls back to `./tmp/backups`, which keeps the stack starting
but is not a useful place for backups. The app never creates directories: create
the backup folder yourself, or the settings page will tell you it is missing.

Mounting a broad directory gives the app read/write access to everything inside
it. Point it at the narrowest folder that still gives you the choice you want.

## Changes from `compose.example.yml`

### Build from local source

The `web` service builds the image and tags it `maybe-app:local`; `worker`
reuses that tag:

```yaml
  web:
    build:
      context: .
      dockerfile: Dockerfile
    image: maybe-app:local

  worker:
    image: maybe-app:local
```

Only one service carries the `build:` block on purpose. If both build the same
tag, Compose runs them in parallel and they race to export the image:

```
failed to solve: image "docker.io/library/maybe-app:local": already exists
```

The `Dockerfile` is self-contained — it precompiles assets with
`SECRET_KEY_BASE_DUMMY=1` and needs no `RAILS_MASTER_KEY`.

**Tradeoff:** `docker compose pull` no longer fetches upstream updates. To take
new upstream code, `git pull` and rebuild.

### Source mounts

`app/`, `lib/`, `config/`, `db/` and `test/` are mounted into `web` and
`worker`, so most edits need only a restart (see
[Applying code changes](#applying-code-changes)):

```yaml
    volumes:
      - app-storage:/rails/storage
      - ${BACKUP_HOST_ROOT:-./tmp/backups}:/rails/backups
      - ./app:/rails/app
      - ./lib:/rails/lib
      - ./config:/rails/config
      - ./db:/rails/db
      - ./test:/rails/test
```

> **Both services need the same file mounts.** Jobs run on `worker` but their
> output is served by `web`, so anything written to `/rails/storage` (database
> backups, ActiveStorage attachments such as family exports) is invisible to the
> app unless `worker` shares the volume. When `worker` lacked it, exports and
> backups were silently written into that container's own filesystem and lost on
> the next `up -d`. Add file mounts to both services, or not at all.

### Custom port

```yaml
    ports:
      - 3088:3000
```

The container still listens on 3000 internally; only the host port changes. No
app config is needed for this.

### Custom hostname

Add the name to your hosts file:

```bash
echo "127.0.0.1 maybe" | sudo tee -a /etc/hosts
```

The app is then reachable at <http://maybe:3088>.

No Rails config change is required: `config.hosts` is commented out in
`config/environments/production.rb`, so host authorization does not restrict
hostnames in production (it is a development-only default).

## Applying code changes

`app/`, `lib/`, `config/`, `db/` and `test/` are bind-mounted into the containers, so
source changes are visible immediately without rebuilding. What you need to do
depends on which process runs the code.

| What you changed | What to run | Roughly |
| --- | --- | --- |
| Anything invoked via `docker compose exec` (rake tasks, `runner`, `console`) | nothing | instant |
| Ruby or views served by the web server or Sidekiq | `docker compose restart web worker` | ~6s |
| `Gemfile`, `Dockerfile`, or assets (CSS/JS) | `docker compose build web && docker compose up -d` | ~25s |

`exec` starts a **new process** that loads the current files from disk, which is
why rake tasks and console sessions never need a restart.

The web server and Sidekiq are long-running, and production sets
`config.enable_reloading = false` with `config.eager_load = true` — classes and
templates are loaded once at boot — so they need a restart to notice edits.

`public/assets` is gitignored and exists **only inside the image**, so compiled
CSS/JS is not bind-mounted and any change to it requires a rebuild.

> Mounting the whole repo at `/rails` would shadow `public/assets` and break
> styling. Mount individual source directories instead, as `compose.yml` does.

## Everyday commands

```bash
# Status and health
docker compose ps
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3088/up   # expect 200

# Rails console / runner
docker compose exec web bin/rails console
docker compose exec web bin/rails runner 'puts Family.first&.currency'
```

## Changing the base currency

The base currency is chosen during onboarding. In **Settings → Preferences** the
dropdown is rendered with `disabled: true`, but that is a UI lock only —
`UsersController` still permits `:currency`, so it can be changed from the
console:

```ruby
Family.first.update!(currency: "USD")
```
