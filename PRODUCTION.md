# Production integration checklist

QuansiftMarketData is a library, not the Quansift production scheduler. It owns
Tiingo collection, response validation, `DataFrame` normalization, and reusable
PostgreSQL, Parquet, and DuckDB persistence primitives.

In Quansift production:

- the library checkout remains `/opt/tiingojulia`, exposed to consumers as
  `TIINGO_PROJECT_ROOT=/opt/tiingojulia`;
- system PostgreSQL is the authoritative relational store;
- Parquet is the full-history interchange/archive format;
- DuckDB is optional local analysis or compatibility state, not a required
  production source of record; and
- `quansift_scheduler` owns schedules, cross-stage retries, success gating,
  DigitalOcean Spaces, DigitalOcean Managed PostgreSQL, notifications, and
  QuantScreener/TATSU sequencing.

Do not put Spaces or Managed PostgreSQL credentials in QuansiftMarketData env files.

## Provider account and data-retention gate

These storage roles describe technical architecture, not permission to retain
Tiingo Data. Before enabling any persistent flow, the operator must verify that
the current Tiingo plan or a separate written agreement permits every enabled
PostgreSQL, DuckDB, Parquet, Spaces, file, log, queue, archive, backup, and
disaster-recovery path. The operator must also maintain a deletion procedure
covering every copy if the paid plan expires, is cancelled or terminated, or is
downgraded to Starter or Trial.

Starter and Trial Plan users must not use these persistent paths under the
current Tiingo Terms. See the canonical
[data terms and project identity](README.md#data-terms-and-project-identity)
summary before using any storage or live integration example. The user's
current plan, applicable Supplemental Terms, and any separate written agreement
govern.

## Library release verification

Before releasing or consuming a QuansiftMarketData build:

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
   the latest universe never deletes its historical rows.

   One consumer foreign key is supported by name: `filtered_stocks_ticker_fkey`
   on `public.filtered_stocks`, referencing `us_tickers_filtered (ticker)`.
   `replace_ticker_universe` recognises it only when it matches an exact
   fingerprint, then drops it, reloads both snapshots, and recreates it
   verbatim — including its `ON DELETE CASCADE` — inside the replacement
   transaction, verifying the fingerprint again before committing. That cascade
   belongs to the library, not to an operator working around a failure.

   Every other consumer foreign key targeting a universe table is outside this
   contract. An exact replacement fails and rolls back atomically while such a
   key exists, and adding `CASCADE` to work around that failure is not
   supported: it would let a universe replacement delete consumer rows the
   library never inspected.

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

   The test creates, replaces, and drops QuansiftMarketData tables. Never point it at
   a shared or production database.

## PostgreSQL schema migration safety

QuansiftMarketData exposes a forward-only PostgreSQL schema contract through
`POSTGRES_SCHEMA_VERSION`, `postgres_schema_version`, and `migrate_postgres!`.
The current schema version is `3`. PostgreSQL `create_tables(pg_conn)` delegates
to this migration path, so existing databases receive the same validation as
fresh databases.

Before the first migration of an existing database, take and verify an
operator-owned backup. QuansiftMarketData validates and migrates known layouts, but it
does not create, retain, or restore database backups. Exercise the exact
upgrade first against a restored copy or other isolated database:

The backup and restored rehearsal copy are retained Tiingo Data. Create them
only after the provider account and data-retention gate passes, and include
both in the operator's deletion inventory.

```julia
pg = connect_postgres(ENV["OHLCV_PG_CONNECTION"])
try
    current = postgres_schema_version(pg)
    result = migrate_postgres!(
        pg;
        target_version=POSTGRES_SCHEMA_VERSION,
        lock_timeout_seconds=30,
        statement_timeout_seconds=3600,
    )
    @info "PostgreSQL migration complete" current result
finally
    close_postgres(pg)
end
```

`migrate_postgres!` requires an idle, caller-owned connection; do not wrap it
in another transaction. It begins one transaction, sets a transaction-local
lock timeout, and acquires PostgreSQL advisory lock `(1414089038, 1)`. A lock
timeout, validation error, or cancellation rolls the transaction back.

Size `statement_timeout_seconds` against your own `historical_data`, not
against the default. Migration 2 rewrites every row of that table inside the
one transaction: on a 20,622,888-row, 4179 MB table it took 19m49s, and the
whole migration is cancelled and rolled back if the timeout expires first.
Because the rewrite is one transaction, PostgreSQL holds every replaced row
version until it commits, so the table needs roughly twice its size in free
space plus room for the write-ahead log — budget around 10 GB free for a 4 GB
table. Confirm both before opening a maintenance window; a rehearsal against a
restored copy is the only way to know the real numbers for your host.
`InterruptException` remains a cancellation signal and is rethrown.

The ledger is `public.tiingojulia_schema_migrations`. Ledger versions must be
contiguous and their names and checksums must match this package's finite
migration catalog. A corrupt or newer ledger, a requested downgrade, an
unknown pre-ledger schema, or legacy historical rows with null/duplicate
`(ticker, date)` keys is rejected without guessing or dropping data. Stop,
preserve the database, and repair or restore it explicitly; do not edit the
ledger to bypass validation.

`postgres_schema_version(pg)` is read-only and returns `0` when no ledger
exists. `migrate_postgres!` returns `PostgresMigrationResult` with
`from_version`, `to_version`, and `applied_versions`; record those fields in
deployment logs.

## Deterministic performance evidence

The independent `benchmark/` project exercises current sink-neutral
normalization and persistence APIs with seeded synthetic data. It never calls
Tiingo or requires a Tiingo secret. Run `micro`, `load`, and `soak` only with
finite environment bounds documented in
[`docs/src/PERFORMANCE.md`](docs/src/PERFORMANCE.md).

Timing, allocation, and resident-memory observations are report-only. A run
fails only for correctness, idempotency, cleanup, configuration bounds, or
timeout violations. PostgreSQL benchmarks require an isolated disposable
database plus the explicit acknowledgement environment variable; never point
them at shared or production PostgreSQL.

CI runs one Linux/Julia 1.12 one-sample PR smoke. The scheduled/manual
performance workflow runs its bounded local smoke, PostgreSQL 17 load, and
local soak as separate jobs with independent timeouts and metadata-only JSON
artifacts.

For PostgreSQL-to-Parquet snapshots, preinstall DuckDB's `postgres` extension
while building the image or environment. Runtime code only executes
`LOAD postgres`; it fails closed instead of downloading an extension. The
bundled `docker/Dockerfile` installs the matching extension at build time.

`collect_fundamentals` is unbounded by default through
`initial_start_date=nothing`, while `columns=nothing` requests all Daily
Metrics columns. After passing the provider account and data-retention gate,
production consumers should set explicit bounds when their Tiingo plan or
retention policy requires them. Bounds do not make a persistent sink suitable
for Starter or Trial Plans. The legacy `sync_fundamentals!` workflow retains
its three-year initial-backfill default.

## Advisory zero-persistence live canary

`scripts/live_canary.jl` checks a real Tiingo response through
`collect_historical` without selecting PostgreSQL, DuckDB, or Parquet. A
mandatory in-memory observer receives each normalized frame, records only its
ticker, row count, and date bounds, and reports zero persisted rows.

The canary is restricted to the `AAPL`/`SPY` allowlist, defaults to 14 trailing
days, permits at most 30 days, and ends before the current UTC day. Run it with
the API key only in the environment:

```bash
TIINGO_API_KEY="$TIINGO_API_KEY" \
TIINGO_CANARY_TICKERS=AAPL,SPY \
TIINGO_CANARY_WINDOW_DAYS=14 \
  julia --project=. scripts/live_canary.jl
```

This is the closest provided validation path for Starter and Trial Plans
because it selects no persistent sink. Users must still comply with their
current account terms, permanently remove transient Tiingo Data immediately
after the calculation or operation completes and, in all events, before the
process, job, or user session ends, and ensure captured output does not retain
Tiingo Data.

The scheduled/manual `live-canary.yml` workflow is advisory operational
evidence. Missing credentials, quota exhaustion, unavailable symbols, or a
Tiingo outage may make that run fail, but it is never a PR, release-preflight,
Registrator, or package-release gate. Hermetic fake-fetcher tests enforce the
canary contract without live credentials.

## Bounded live integration smoke

The bundled smoke scripts validate a small real Tiingo request using disposable
DuckDB state. They are not a full-universe ingest, do not publish PostgreSQL, and
must not be installed as the canonical production scheduler.

1. Copy the example and set a real Tiingo API key:

   ```bash
   cp .env.staging.example .env.staging
   ```

2. Run a bounded sample:

   ```bash
   TIINGO_SMOKE_TICKER_LIMIT=5 \
   scripts/run_staging_smoke.sh
   ```

The smoke will create a local DuckDB file, download ticker metadata, fetch a
bounded price sample, and validate the typed collection result. That DuckDB
file is disposable validation state, but it is still persistent Tiingo
Data. Use this smoke only when the applicable account terms or a separate
written agreement permit persistence; it is not a Starter or Trial Plan path.

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
  pipeline
```

The compose and systemd files under `deploy/` are retained as integration-smoke
examples for existing users. Enabling their timer would merely schedule the
bounded smoke; it would not create the canonical Quansift production workflow.
See [`deploy/README.md`](deploy/README.md) for their exact scope.

## Consumer integration requirements

A production consumer should:

- verify that its current Tiingo plan or separate written agreement permits
  every selected sink, retained artifact, log, backup, and disaster-recovery
  copy, and operate the required deletion procedure;
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

Those workflow policies belong to the consuming application. QuansiftMarketData should
remain usable by applications that select any one of PostgreSQL, Parquet, or
DuckDB without importing Quansift deployment assumptions. That is a technical
capability only; the provider account and data-retention gate still applies.

## Security and logging

- Store `TIINGO_API_KEY` and database credentials in a secret manager or a
  mode-`0600` env file.
- Use `TIINGO_LOGGER=console` when the runtime captures stdout/stderr.
- Never commit `.env` or `.env.staging`.
- Do not log PostgreSQL connection strings.
- Use a throw-away database for live integration tests.
