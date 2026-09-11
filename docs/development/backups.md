# Database backups

Settings > Backups (self-hosted, admin only) takes a `pg_dump` of the whole
database and writes it to a folder on the host.

This is **not** the same thing as Settings > Profile > Export data:

| | Export data | Backups |
| --- | --- | --- |
| Scope | One family's financial data | The entire database, all tables |
| Format | Zip of CSVs + `all.ndjson` | PostgreSQL custom format (`.dump`) |
| Contains | Accounts, transactions, trades, categories | The above plus users, sessions, API keys, settings, OAuth tokens, exchange rates |
| Restores | Nothing automatically; partial CSV re-import | The whole app, via `pg_restore` |
| For | Reading your data, leaving the app | Disaster recovery |

## Setup

Backups are written to `/rails/backups/<folder>` inside the container. That
mount comes from `BACKUP_HOST_ROOT` (see
[local-docker.md](local-docker.md#backup_host_root)):

```bash
# .env
BACKUP_HOST_ROOT=/Users/you/Library/Mobile Documents/com~apple~CloudDocs
```

```bash
docker compose up -d   # not `restart`: mounts are fixed at container creation
```

Then pick the folder in Settings > Backups. The page shows the resolved host
path, so you can confirm where files actually land.

Two deliberate restrictions:

- **The app never creates directories.** Create the backup folder yourself; the
  page reports it as missing until you do. Auto-creating would quietly make a
  directory inside the container that disappears on the next rebuild.
- **A folder name is required.** Backups are never written to the root of the
  mount, which is shared with unrelated files.

The page also warns when the chosen folder is not on a mounted filesystem — it
compares device ids against `/`, so it can tell a bind mount or volume from the
container's own ephemeral layer, where backups would be destroyed by
`docker compose up -d`.

## Restoring

The dump is PostgreSQL custom format, so `pg_restore`, not `psql`:

```bash
docker compose cp "<file>.dump" db:/tmp/restore.dump

# Into a throwaway database first, to check the dump before trusting it
docker compose exec db psql -U maybe_user -d postgres \
  -c "DROP DATABASE IF EXISTS restore_check;" -c "CREATE DATABASE restore_check;"
docker compose exec db pg_restore -U maybe_user -d restore_check --no-owner --no-acl /tmp/restore.dump
docker compose exec db psql -U maybe_user -d restore_check -c "SELECT count(*) FROM entries;"

# Over the real database, once you are satisfied
docker compose exec db psql -U maybe_user -d postgres \
  -c "DROP DATABASE maybe_production;" -c "CREATE DATABASE maybe_production;"
docker compose exec db pg_restore -U maybe_user -d maybe_production --no-owner --no-acl /tmp/restore.dump
docker compose restart web worker
```

There is no restore button in the UI on purpose: it drops and recreates the
database, which is too destructive for a web control.

## Known limitations

- **Attachments are not included.** A dump captures the
  `active_storage_blobs`/`attachments` rows but not the files, which live under
  `/rails/storage` on disk. After a restore those rows point at files that are
  not there. Today that means account logos and previously generated export
  zips; the financial data itself is unaffected.
- **No retention policy.** Backups accumulate (~8.5 MB each) until deleted from
  the page.
- **No scheduling.** Each backup is triggered manually.
- **`pg_dump` must not be older than the server.** The image pins
  `postgresql-client-16` from PGDG for this reason; bump it alongside the
  `postgres` image in `compose.yml` or backups will fail outright with
  `aborting because of server version mismatch`.
