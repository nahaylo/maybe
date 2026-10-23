# Development Docs

Notes for running this checkout locally, testing it, and using the custom rake
tasks added on top of upstream Maybe.

| Guide | What it covers |
| --- | --- |
| [Local Docker setup](local-docker.md) | Running your own checkout in Docker, ports, hostnames, env vars |
| [Running tests](testing.md) | Running the Minitest suite inside Docker, and the two gotchas that will bite you |
| [Exchange rates](exchange-rates.md) | Backfilling currency rates now that the upstream provider is offline |
| [Database backups](backups.md) | Taking and restoring `pg_dump` backups, and how they differ from Export data |
| [Monobank import](monobank-import.md) | Pulling card transactions from the Monobank personal API |
| [Interactive Brokers import](ibkr-import.md) | Pulling trades, cash movements and position marks from the IBKR Flex Web Service |

## Quick reference

```bash
# Most code changes need nothing -- see "Applying code changes" in the
# local Docker guide. Restart the long-running processes when they do:
docker compose restart web worker

# Rebuild only for Gemfile, Dockerfile, or asset (CSS/JS) changes
docker compose build web && docker compose up -d

# Tail logs
docker compose logs -f web

# Rails console
docker compose exec web bin/rails console

# Stop (keeps data) / stop and wipe the database
docker compose down
docker compose down -v
```
