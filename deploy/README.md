# Bounded integration-smoke assets

The files in this directory package `scripts/staging_smoke_test.jl` as a
one-shot container and retain legacy systemd/launchd wrappers for existing
users. They validate TiingoJulia in a real runtime; they are not the canonical
Quansift production scheduler.

`quansift_scheduler` owns production scheduling, cross-stage retries,
DigitalOcean Spaces publication, DigitalOcean Managed PostgreSQL loading,
notifications, and QuantScreener/TATSU sequencing.

## What the smoke validates

The bounded smoke can:

- authenticate to Tiingo;
- download and filter the ticker universe (the reusable library boundary is
  the sink-neutral `collect_ticker_universe`);
- fetch a configured number of EOD stock/ETF histories;
- persist disposable validation state in DuckDB; and
- optionally exercise the existing PostgreSQL compatibility export.

It does not run a full production ingest, publish Parquet to an object store,
load Managed PostgreSQL, or run downstream analysis.

## Host-side smoke

From the repository root:

```bash
cp .env.staging.example .env.staging
```

Set `TIINGO_API_KEY`, then run a small sample without PostgreSQL:

```bash
TIINGO_SMOKE_TICKER_LIMIT=5 \
TIINGO_SMOKE_EXPORT_POSTGRES=false \
scripts/run_staging_smoke.sh
```

To test PostgreSQL integration, point `OHLCV_PG_CONNECTION` only at an isolated
integration database and set `TIINGO_SMOKE_EXPORT_POSTGRES=true`.

The separate executable persistence gate uses
`TIINGO_TEST_PG_CONNECTION` and creates, replaces, and drops its tables:

```bash
TIINGO_TEST_PG_CONNECTION='postgresql://user:password@localhost:5432/tiingojulia_test?sslmode=disable' \
  julia --project=. test/test_postgres_integration.jl
```

PostgreSQL-to-Parquet snapshots require DuckDB's `postgres` extension to be
installed in the image or environment ahead of time. Runtime library calls
only load the preinstalled extension and never download it.

## One-shot container smoke

The compose service joins an existing Docker network and bind-mounts a
directory for its temporary DuckDB file. Choose values appropriate for the
integration host:

```bash
export TIINGO_APP_ENV_FILE="$PWD/.env.staging"
export TIINGO_DOCKER_NETWORK=integration-db-network
export TIINGO_DB_HOST_DIR=/path/to/integration-data
export TIINGO_DB_CONTAINER_DIR=/data
```

Set `OHLCV_DUCKDB_PATH=/data/staging_smoke.duckdb` in `.env.staging`, then run:

```bash
docker compose -f deploy/compose/docker-compose.pipeline.yml pull pipeline
docker compose -f deploy/compose/docker-compose.pipeline.yml run --rm \
  -e TIINGO_SMOKE_TICKER_LIMIT=5 \
  -e TIINGO_SMOKE_EXPORT_POSTGRES=false \
  pipeline
```

Pass smoke overrides with `docker compose run -e`. Prefixing the
`docker compose` command with `TIINGO_SMOKE_*` only affects Compose
interpolation; it does not override variables loaded from
`TIINGO_APP_ENV_FILE`.

If PostgreSQL export is enabled, use the database container's in-network host
and port in `OHLCV_PG_CONNECTION`, for example:

```dotenv
OHLCV_PG_CONNECTION=postgresql://USER:PASS@postgres:5432/DB?sslmode=disable
TIINGO_SMOKE_EXPORT_POSTGRES=true
```

## Low-resource integration hosts

The following settings are suitable starting points for a small smoke
container:

```dotenv
TIINGO_DUCKDB_MEMORY_LIMIT_GB=1
TIINGO_DUCKDB_THREADS=1
TIINGO_DUCKDB_WORKER_THREADS=1
TIINGO_DUCKDB_PRESERVE_INSERTION_ORDER=false
TIINGO_DUCKDB_UPSERT_CHUNK_SIZE=500
```

`TIINGO_DUCKDB_TMP` controls scratch space. `OHLCV_DUCKDB_PATH` controls the
optional local DuckDB file and should resolve inside the mounted container
directory for a container smoke.

## Legacy scheduler wrappers

The following files remain for backward compatibility:

- `deploy/systemd/tiingojulia-pipeline.service`
- `deploy/systemd/tiingojulia-pipeline.timer`
- `deploy/systemd/tiingojulia-pipeline.env.example`
- `deploy/launchd/com.example.tiingojulia.staging-smoke.plist`

They schedule the same bounded smoke, not a production data pipeline. Do not
enable them as the Quansift production scheduler. Existing users may retain
them for periodic integration monitoring, but production workflow changes
belong in `quansift_scheduler`.

Consumers should validate externally supplied EOD payloads through
`normalize_eod_prices` before persistence. The sink-neutral
`collect_fundamentals` collector supports unbounded collection with
`initial_start_date=nothing` and full Daily Metrics payloads with
`columns=nothing`; the legacy `sync_fundamentals!` workflow retains its
three-year initial-backfill default.
