# Production integration checklist

TiingoJulia is a library, not the Quansift production scheduler. It owns Tiingo
collection, response validation, `DataFrame` normalization, and reusable
PostgreSQL, Parquet, and DuckDB persistence primitives.

In Quansift production:

- system PostgreSQL is the authoritative relational store;
- Parquet is the full-history interchange/archive format;
- DuckDB is optional local analysis or compatibility state, not a required
  production source of record; and
- `quansift_scheduler` owns schedules, cross-stage retries, success gating,
  DigitalOcean Spaces, DigitalOcean Managed PostgreSQL, notifications, and
  QuantScreener/TATSU sequencing.

Do not put Spaces or Managed PostgreSQL credentials in TiingoJulia env files.

## Library release verification

Before releasing or consuming a TiingoJulia build:

1. Run the hermetic test suite:

   ```bash
   julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
   ```

2. Build the Linux image used for integration validation:

   ```bash
   docker build -f docker/Dockerfile .
   ```

3. Exercise the required sink primitives independently:

   - create the PostgreSQL tables with `create_tables(pg_conn)`;
   - build a sink-neutral universe with `collect_ticker_universe` and publish
     both snapshots atomically with `replace_ticker_universe`;
   - validate EOD frames with `normalize_eod_prices` before persistence;
   - repeat an EOD and fundamentals upsert and confirm it is idempotent;
   - write Parquet with `write_parquet` and verify its
     `ParquetWriteResult`; and
   - if a consumer uses DuckDB, run the same validation against a temporary
     DuckDB file.

   `write_parquet(frame, ...)` is a generic sink and faithfully persists the
   supplied frame, including duplicate rows. Canonical Fundamentals duplicate
   keys are rejected by normalization and by the dedicated DuckDB/PostgreSQL
   upsert primitives before those sinks mutate state.

   PostgreSQL ticker-universe tables are exact, replaceable snapshots. The
   canonical schema intentionally does not make full-history price or
   Fundamentals tables children of those snapshots, so delisting a ticker from
   the latest universe never deletes its historical rows. Consumer-added
   foreign keys targeting a universe table are outside this contract: an exact
   replacement fails and rolls back atomically while the foreign key exists.
   Do not add `CASCADE` to work around that failure.

   For downloaded ticker metadata, the validated CSV is the canonical
   downstream artifact and the retained ZIP is ancillary input. Each is
   replaced atomically from a same-directory temporary file, but the two-file
   publication is not crash-transactional as a pair.

4. Validate `HistoricalCollectionResult` and `FundamentalCollectionResult`
   handling. Strict consumers should use strict mode so incomplete required
   work raises `SyncIncompleteError`; the external scheduler then decides
   whether and when the job should retry.

5. Run the PostgreSQL 17 integration gate against an isolated disposable
   database:

   ```bash
   TIINGO_TEST_PG_CONNECTION='postgresql://user:password@localhost:5432/tiingojulia_test?sslmode=disable' \
     julia --project=. test/test_postgres_integration.jl
   ```

   The test creates, replaces, and drops TiingoJulia tables. Never point it at
   a shared or production database.

For PostgreSQL-to-Parquet snapshots, preinstall DuckDB's `postgres` extension
while building the image or environment. Runtime code only executes
`LOAD postgres`; it fails closed instead of downloading an extension. The
bundled `docker/Dockerfile` installs the matching extension at build time.

`collect_fundamentals` is unbounded by default through
`initial_start_date=nothing`, while `columns=nothing` requests all Daily
Metrics columns. Production consumers should set explicit bounds when their
Tiingo plan or retention policy requires them. The legacy `sync_fundamentals!`
workflow retains its three-year initial-backfill default.

## Bounded live integration smoke

The bundled smoke scripts validate a small real Tiingo request and the existing
DuckDB/PostgreSQL compatibility path. They are not a full-universe ingest and
must not be installed as the canonical production scheduler.

1. Copy the example and set a real Tiingo API key:

   ```bash
   cp .env.staging.example .env.staging
   ```

2. Keep PostgreSQL export disabled for the first run:

   ```bash
   TIINGO_SMOKE_TICKER_LIMIT=5 \
   TIINGO_SMOKE_EXPORT_POSTGRES=false \
   scripts/run_staging_smoke.sh
   ```

3. To validate the compatibility export path, set
   `OHLCV_PG_CONNECTION` in `.env.staging`, point it only at an isolated
   integration database, and run with `TIINGO_SMOKE_EXPORT_POSTGRES=true`.

The smoke will create a local DuckDB file, download ticker metadata, fetch a
bounded price sample, and optionally export the sample to PostgreSQL. That
DuckDB file is disposable validation state.

On a small integration host, these settings reduce DuckDB memory pressure:

```dotenv
TIINGO_DUCKDB_MEMORY_LIMIT_GB=1
TIINGO_DUCKDB_THREADS=1
TIINGO_DUCKDB_WORKER_THREADS=1
TIINGO_DUCKDB_PRESERVE_INSERTION_ORDER=false
TIINGO_DUCKDB_UPSERT_CHUNK_SIZE=500
```

## One-off container smoke

The compose file currently runs `scripts/staging_smoke_test.jl`. Use it only
for a bounded integration check:

```bash
docker compose -f deploy/compose/docker-compose.pipeline.yml run --rm \
  -e TIINGO_SMOKE_TICKER_LIMIT=5 \
  -e TIINGO_SMOKE_EXPORT_POSTGRES=false \
  pipeline
```

The compose and systemd files under `deploy/` are retained as integration-smoke
examples for existing users. Enabling their timer would merely schedule the
bounded smoke; it would not create the canonical Quansift production workflow.
See [`deploy/README.md`](deploy/README.md) for their exact scope.

## Consumer integration requirements

A production consumer should:

- supply the Tiingo API key and database connections at runtime;
- keep the system PostgreSQL and any downstream serving database independently
  configured;
- treat each persistence result as a stage result and record row counts or
  watermarks;
- pass the scheduler-owned split scan range to `find_split_refresh_targets`;
  the library returns deterministic targets but stores no cross-run watermark;
- publish Parquet or other downstream artifacts only after required collection
  and PostgreSQL upserts succeed;
- make object-store publication atomic from a reader's perspective; and
- enforce its own locks, timeouts, retries, monitoring, and alerting.

Those workflow policies belong to the consuming application. TiingoJulia should
remain usable by applications that select any one of PostgreSQL, Parquet, or
DuckDB without importing Quansift deployment assumptions.

## Security and logging

- Store `TIINGO_API_KEY` and database credentials in a secret manager or a
  mode-`0600` env file.
- Use `TIINGO_LOGGER=console` when the runtime captures stdout/stderr.
- Never commit `.env` or `.env.staging`.
- Do not log PostgreSQL connection strings.
- Use a throw-away database for live integration tests.
