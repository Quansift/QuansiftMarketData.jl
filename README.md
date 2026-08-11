# Tiingo.jl

Tiingo is a Julia library for collecting Tiingo end-of-day stock and ETF
prices and Fundamentals data, normalizing responses into `DataFrame`s, and
persisting those frames through independent PostgreSQL, Parquet, or DuckDB
primitives.

[![Tests](https://img.shields.io/github/actions/workflow/status/Quansift/Tiingo.jl/CI.yml?branch=main&label=Tests)](https://github.com/Quansift/Tiingo.jl/actions)
[![Documentation](https://img.shields.io/github/actions/workflow/status/Quansift/Tiingo.jl/Docs.yml?branch=main&label=Docs)](https://quansift.github.io/Tiingo.jl/dev)
[![Lint](https://img.shields.io/github/actions/workflow/status/Quansift/Tiingo.jl/Lint.yml?branch=main&label=Lint)](https://github.com/Quansift/Tiingo.jl/actions)

## Responsibility boundary

Tiingo owns:

- Tiingo HTTP access and response validation;
- ticker, EOD price, and Fundamentals normalization;
- idempotent EOD and Fundamentals upserts for PostgreSQL and DuckDB; and
- verified atomic local Parquet writes with explicit overwrite behavior.

Tiingo does not own cron or systemd scheduling, cross-stage retries,
object-store publication, Managed PostgreSQL deployment, notifications, or
QuantScreener/TATSU sequencing.

The Quansift production workflow assigns each persisted representation a
distinct role:

- system PostgreSQL is the authoritative production query store and recovery
  baseline;
- persistent DuckDB is an analysis replica and high-performance OLAP cache; and
- off-host Parquet is the full-history archive and interchange format.

`quansift_scheduler` owns the ordered workflow and publishes Parquet to
DigitalOcean Spaces and a rolling three-year dataset to DigitalOcean Managed
PostgreSQL. DuckDB is not an additional source of record.

The rolling three-year rule applies only to DigitalOcean Managed PostgreSQL
publication. System PostgreSQL and Parquet retain full history, and Tiingo
imposes no DuckDB retention period — consumers bound local DuckDB state to their
own analysis needs. A separate three-year default exists for the `sync_fundamentals!`
initial backfill window; it is unrelated to the Managed PostgreSQL publication rule.

## Production release channel

Development changes go through a feature branch, optional `staging` integration,
and a pull request to `main`. Do not open pull requests to, or commit directly on,
`production`: it is the protected deployment pointer, not a development branch.
Merging to `main` does not deploy automatically.

For a Tiingo release, first merge and verify Tiingo on `main`. Then update the
exact Tiingo revision in all `quansift_scheduler` pin locations, merge that
scheduler pull request, and require both repositories' CI to pass. Promote the
validated pair by fast-forwarding Tiingo `production` first and scheduler
`production` second; never force-push either branch.
For a scheduler-only release, keep the Tiingo pin unchanged and promote only
scheduler `production`.

The promotion commands derive the revisions from the remote branches, so the
operator does not need to remember a commit SHA:

```bash
(
set -euo pipefail

git -C /path/to/Tiingo.jl fetch --prune origin
git -C /path/to/quansift_scheduler fetch --prune origin

TIINGO_RELEASE="$(git -C /path/to/Tiingo.jl rev-parse origin/main)"
SCHEDULER_RELEASE="$(git -C /path/to/quansift_scheduler rev-parse origin/main)"
SCHEDULER_PIN="$(
  git -C /path/to/quansift_scheduler show origin/main:Project.toml |
    awk -F'"' '/^Tiingo = \{rev = / {print $2}'
)"

test "$TIINGO_RELEASE" = "$SCHEDULER_PIN"
git -C /path/to/Tiingo.jl \
  merge-base --is-ancestor origin/production "$TIINGO_RELEASE"
git -C /path/to/quansift_scheduler \
  merge-base --is-ancestor origin/production "$SCHEDULER_RELEASE"

git -C /path/to/Tiingo.jl \
  push origin "$TIINGO_RELEASE:refs/heads/production"
git -C /path/to/quansift_scheduler \
  push origin "$SCHEDULER_RELEASE:refs/heads/production"
)
```

Do not pull either data-plane checkout unless both promotion pushes succeed.

On data-plane, pause the scheduler cron entries and prove that no pipeline,
lock, or PostgreSQL writer is active before updating. Pull Tiingo first, apply
and verify any database migration, then pull scheduler and recheck that its
Tiingo pin equals `/opt/tiingojulia` `HEAD` before restoring cron:

```bash
git -C /opt/tiingojulia pull --ff-only
git -C /home/shin/10kpw/quansift_scheduler pull --ff-only
```

Both production checkouts track `origin/production` with `pull.ff=only`.
Therefore changes on `main` remain undeployed until an explicit promotion.

## Installation

```julia
using Pkg
Pkg.add("Tiingo")
```

For repository development:

```bash
julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
```

## Configuration

Create a local env file and set the Tiingo API key:

```bash
cp .env.example .env
```

```dotenv
TIINGO_API_KEY=your_api_key_here
```

`.env` is ignored by git. Do not commit secrets. Set overrides before running
`using Tiingo`.

Common optional settings include:

- `TIINGO_CONFIG_PATH`: alternate `config.toml` path;
- `TIINGO_API_BASE_URL`: Tiingo daily API base URL;
- `TIINGO_API_MAX_RETRIES`: retries within a Tiingo HTTP request;
- `TIINGO_API_RETRY_DELAY`: request retry base delay in seconds;
- `TIINGO_SUPPORTED_EXCHANGES`: comma-separated exchange filter;
- `TIINGO_SUPPORTED_ASSET_TYPES`: comma-separated asset-type filter;
- `TIINGO_LOGGER`: `console`, `tee`, `file`, `tee-file`, or `null`; and
- `OHLCV_DUCKDB_PATH`: optional local DuckDB path.

`OHLCV_PG_CONNECTION` is used by bundled compatibility helpers and integration
smokes. Library consumers may instead pass an already-open PostgreSQL
connection. Legacy aliases remain documented in [`.env.example`](.env.example).

Spaces and Managed PostgreSQL credentials intentionally do not belong in this
repository's env templates.

## Collect Tiingo data

`collect_ticker_universe` builds the canonical stock/ETF universe without
choosing a sink. It accepts an existing `DataFrame`; its keyword/file form
loads the supported-tickers file for applications that keep universe
acquisition separate from persistence.

`get_ticker_data` fetches EOD data without selecting a storage destination.
Use `normalize_eod_prices` as the canonical schema and date-range validation
boundary before passing externally supplied payloads to a persistence writer:

```julia
using Tiingo
using DataFrames
using Dates

ticker = DataFrame(
    ticker=["AAPL"],
    start_date=[Date("2024-01-01")],
    end_date=[Date("2024-12-31")],
)[1, :]
raw_prices = get_ticker_data(
    ticker;
    start_date=Date("2024-01-01"),
    end_date=Date("2024-12-31"),
)
prices = normalize_eod_prices(
    raw_prices;
    start_date=Date("2024-01-01"),
    end_date=Date("2024-12-31"),
)
```

Fundamentals consumers can use `get_fundamental_meta`,
`get_daily_fundamental`, `normalize_security_observations`, and
`normalize_fundamental_daily_metrics` before selecting a sink.

For non-interactive batch collection, `collect_historical` returns a
`HistoricalCollectionResult` and `collect_fundamentals` returns a
`FundamentalCollectionResult`. Both retain machine-readable `SyncFailure`
details. Strict mode raises `SyncIncompleteError` when required work is
incomplete; optional writer callbacks return their persisted row counts.
Existing collection functions keep their legacy return values.

The new `collect_fundamentals` collector is unbounded by default
(`initial_start_date=nothing`) and accepts `columns=nothing` to request the
complete Daily Metrics payload. Set either keyword to bound a consumer's
request. The legacy `sync_fundamentals!` compatibility workflow retains its
three-year initial backfill default.

## Choose a persistence primitive

The sinks are independent. Applications can select PostgreSQL, Parquet,
DuckDB, or more than one without adopting a Tiingo scheduler.

### PostgreSQL

The PostgreSQL overloads use the same upsert names as the existing DuckDB API:

```julia
using Tiingo

pg = connect_postgres(ENV["OHLCV_PG_CONNECTION"])
try
    create_tables(pg)
    universe = collect_ticker_universe(source_tickers)
    replace_ticker_universe(pg, universe.all, universe.filtered)
    upsert_stock_data_bulk(pg, prices, "AAPL")
finally
    close_postgres(pg)
end
```

Available PostgreSQL persistence functions are:

- `create_tables(pg_conn)`;
- `replace_ticker_universe(pg_conn, all_tickers, filtered_tickers)`;
- `upsert_stock_data(pg_conn, data, ticker)`;
- `upsert_stock_data_bulk(pg_conn, data, ticker)`;
- `upsert_security_observations(pg_conn, data)`; and
- `upsert_fundamental_daily_metrics(pg_conn, data)`.

Upserts are keyed by each table's natural conflict key, so repeating the same
input updates rather than duplicates rows.

### Parquet

Write a normalized frame directly:

```julia
result = write_parquet(
    prices,
    "exports/aapl.parquet";
    overwrite=false,
    compression=:zstd,
)
```

Or export a PostgreSQL table without making DuckDB a persistent store:

```julia
pg = connect_postgres(ENV["OHLCV_PG_CONNECTION"])
try
    result = write_parquet(
        pg,
        "historical_data",
        "exports/historical_data.parquet";
        overwrite=false,
        compression=:zstd,
    )
finally
    close_postgres(pg)
end
```

`write_parquet` returns `ParquetWriteResult` with `path`, `rows`, `columns`, and
`bytes`. The default is no-overwrite; pass `overwrite=true` only when replacing
the target is intentional. Tiingo verifies the temporary file before an
atomic local publication; the calling application owns remote upload,
manifests, retention, and publication ordering.

PostgreSQL table snapshots use DuckDB's `postgres` extension. Tiingo only
runs `LOAD postgres` and never downloads extensions at runtime. Preinstall the
matching extension while building the deployment image or environment:

```bash
julia --project=. -e 'using DBInterface, DuckDB; conn = DBInterface.connect(DuckDB.DB); try DBInterface.execute(conn, "INSTALL postgres") finally DBInterface.close!(conn) end'
```

The bundled [`docker/Dockerfile`](docker/Dockerfile) performs this installation
during the image build.

### DuckDB local analysis and compatibility

The existing DuckDB workflow remains supported:

```julia
using Tiingo

conn = connect_duckdb("analysis.duckdb")
try
    optimize_database(conn)
    download_tickers_duckdb(conn)

    stocks = get_tickers_stock(conn)
    etfs = get_tickers_etf(conn)

    update_historical(
        conn,
        vcat(stocks[1:50, :], etfs[1:25, :]);
        use_parallel=true,
        batch_size=25,
        max_concurrent=5,
    )

    create_indexes(conn)
finally
    close_duckdb(conn)
end
```

PostgreSQL setup is not required to evaluate or analyze Tiingo data. A Tiingo
API key and a local DuckDB file are sufficient to use the workflow above.

For production applications, bound any local DuckDB data to the consumer's
analysis needs. Do not treat it as an additional required full-history archive.

#### Deprecated: the DuckDB-first full-history path

System PostgreSQL is the source of record and Parquet is the full-history
archive, so routing full history through DuckDB duplicates both. These entry
points are deprecated and targeted for removal in a future major release:

| Deprecated | Replacement |
| --- | --- |
| `update_historical`, `update_historical_parallel`, `update_historical_sequential` | `collect_historical` with a caller-supplied writer |
| `download_tickers_duckdb` | `collect_ticker_universe` + `replace_ticker_universe` |
| `export_to_postgres` | `upsert_*` overloads for ingest, `write_parquet` for archive |
| `add_historical_data`, `update_split_ticker` | `collect_historical` with a caller-supplied writer |

DuckDB itself is not deprecated. `connect_duckdb`, `close_duckdb`,
`create_tables`, `create_indexes`, `optimize_database`, the DuckDB `upsert_*`
overloads, and `get_tickers_*` remain supported for optional local analysis.

## Bounded integration smoke

The repository includes a live, bounded smoke for validating a Tiingo key and
the existing DuckDB/PostgreSQL compatibility path:

```bash
cp .env.staging.example .env.staging
TIINGO_SMOKE_TICKER_LIMIT=5 \
TIINGO_SMOKE_EXPORT_POSTGRES=false \
scripts/run_staging_smoke.sh
```

This is an integration example, not the canonical production scheduler.
[`PRODUCTION.md`](PRODUCTION.md) and
[`deploy/README.md`](deploy/README.md) describe its limited scope.

The executable PostgreSQL release gate is opt-in locally and destructive only
to its isolated test database:

```bash
TIINGO_TEST_PG_CONNECTION='postgresql://user:password@localhost:5432/tiingojulia_test?sslmode=disable' \
  julia --project=. test/test_postgres_integration.jl
```

## Public API overview

- Collection: `get_api_key`, `collect_ticker_universe`, `get_ticker_data`,
  `normalize_eod_prices`, `get_fundamental_meta`, `get_daily_fundamental`,
  `collect_historical`, `collect_fundamentals`
- Collection results: `HistoricalCollectionResult`,
  `FundamentalCollectionResult`, `SyncFailure`, `SyncIncompleteError`
- Normalization: `normalize_security_observations`,
  `normalize_fundamental_daily_metrics`
- PostgreSQL: `connect_postgres`, `close_postgres`, `create_tables`,
  `replace_ticker_universe`, and the `upsert_*` overloads
- Parquet: `write_parquet`, `ParquetWriteResult`
- DuckDB compatibility: `connect_duckdb`, `close_duckdb`,
  `download_tickers_duckdb`, `update_historical`, `optimize_database`,
  `create_indexes`

See the generated [documentation](https://quansift.github.io/Tiingo.jl/dev)
for complete signatures.

## Performance

Collection concurrency and optional DuckDB tuning are covered in the
[performance guide](docs/src/PERFORMANCE.md). Treat published numbers as
workload-specific measurements, not guarantees.

## Contributing, citation, and changes

See the [contributing guide](docs/src/90-contributing.md),
[`CITATION.cff`](CITATION.cff), and [`CHANGELOG.md`](CHANGELOG.md).
