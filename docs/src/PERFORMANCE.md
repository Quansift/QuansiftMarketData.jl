# Tiingo performance guide

This guide covers Tiingo request concurrency and sink-specific tuning.
Tiingo does not prescribe a production scheduler or storage topology.

For Quansift production, system PostgreSQL plus Parquet is the selected path.
DuckDB tuning applies only to consumers that choose the optional local-analysis
or compatibility sink.

These sinks are technical capabilities, not permission to retain Tiingo Data.
Before using a live-data persistence example, read the canonical
[data terms and project identity](https://github.com/Quansift/Tiingo.jl#data-terms-and-project-identity)
summary and verify that the current account terms or a separate written
agreement permit the selected sink. The benchmark examples below use seeded
synthetic data.

## Measure your workload

Throughput depends on the Tiingo plan, requested date ranges, network latency,
host memory, and destination storage. Treat benchmark results as local
measurements, not package guarantees.

Record at least:

- requested, updated, unavailable, and failed ticker counts;
- rows written per sink;
- elapsed collection and persistence time;
- peak memory;
- HTTP retry/rate-limit counts; and
- destination date ranges or watermarks.

The repository benchmark is an independent Julia project. Instantiate it from
the repository root:

```bash
julia --project=benchmark -e \
  'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'
```

It uses seeded synthetic EOD frames and current normalization/persistence APIs.
It does not call Tiingo, read a Tiingo key, or depend on market payloads.

### Micro smoke

This is the exact one-sample local smoke used by pull-request CI and release
preflight. The `local` sink exercises both DuckDB and Parquet:

```bash
TIINGO_BENCH_TICKERS=1 \
TIINGO_BENCH_DAYS=2 \
TIINGO_BENCH_SAMPLES=1 \
TIINGO_BENCH_ITERATIONS=1 \
TIINGO_BENCH_MAX_ELAPSED_SECONDS=90 \
TIINGO_BENCH_SINK=local \
TIINGO_BENCH_OUTPUT=benchmark/micro-result.json \
  julia --project=benchmark benchmark/run.jl micro
```

### PostgreSQL load

Use only a dedicated disposable database. The runner refuses PostgreSQL unless
both the isolation flag and exact destructive-test acknowledgement are set:

```bash
TIINGO_BENCH_TICKERS=25 \
TIINGO_BENCH_DAYS=252 \
TIINGO_BENCH_ITERATIONS=2 \
TIINGO_BENCH_MAX_ELAPSED_SECONDS=600 \
TIINGO_BENCH_SINK=postgres \
TIINGO_BENCH_OUTPUT=benchmark/postgres-load-result.json \
TIINGO_BENCH_PG_CONNECTION="$DISPOSABLE_PG_CONNECTION" \
TIINGO_BENCH_POSTGRES_ISOLATED=true \
TIINGO_BENCH_POSTGRES_DISPOSABLE=I_ACKNOWLEDGE_THIS_DATABASE_IS_DISPOSABLE \
  julia --project=benchmark benchmark/run.jl load
```

The run invokes `migrate_postgres!`, writes only synthetic `SYN...` tickers,
checks repeat-write idempotency, and removes those owned rows in `finally`.
The acknowledgement is a guard, not a substitute for database isolation.

### Local soak

The bounded local soak repeatedly exercises DuckDB and Parquet and always
performs at least one repeat:

```bash
TIINGO_BENCH_TICKERS=10 \
TIINGO_BENCH_DAYS=60 \
TIINGO_BENCH_ITERATIONS=20 \
TIINGO_BENCH_MAX_ELAPSED_SECONDS=900 \
TIINGO_BENCH_SINK=local \
TIINGO_BENCH_OUTPUT=benchmark/local-soak-result.json \
  julia --project=benchmark benchmark/run.jl soak
```

The modes also accept explicit `duckdb` or `parquet` sinks. Configuration
fails closed outside these hard limits: 1–250 tickers, 1–5,000 trading days,
1–20 samples, 1–500 iterations, and 1–3,600 elapsed seconds.

### Interpreting results

Result schema version `1` contains status, git SHA, environment/dependency
versions, finite configuration, metrics, and correctness facts. It contains no
credentials, ticker values, or market rows. Timing, allocations, and RSS are
marked `observations_report_only=true`: compare them across stable Linux runner
history, but do not interpret them as package guarantees or release
thresholds. Correctness, idempotency, cleanup, configuration bounds, and the
elapsed timeout are enforced and may fail the run.

The scheduled/manual performance workflow keeps the local micro, PostgreSQL 17
load, and local soak in separate jobs with independent timeouts. Their
metadata-only JSON artifacts are retained for 14 days. PR CI has exactly one
Linux/Julia 1.12 micro smoke rather than duplicating the scheduled suite.

## Tiingo collection concurrency

Build the stock/ETF input universe with the sink-neutral
`collect_ticker_universe` boundary. Validate EOD payloads through
`normalize_eod_prices` before measuring or persisting them so rejected rows are
not counted as sink throughput.

Persist through an explicit writer while keeping collection sink-neutral:

```julia
writer = (ticker, frame) -> upsert_stock_data_bulk(pg, frame, ticker)
result = collect_historical(
    tickers,
    ENV["TIINGO_API_KEY"];
    latest_dates=watermarks,
    writer=writer,
    strict=true,
)
```

`collect_historical` processes the supplied frame deterministically and records
per-ticker failures while continuing by default. Select bounded ticker slices
at the caller and treat `strict=true` as the job boundary when incomplete work
must fail. Cross-batch concurrency, rate limiting, and retry scheduling belong
to the consuming scheduler; do not introduce new callers of the deprecated
DuckDB-first parallel update functions.

`TIINGO_API_MAX_RETRIES` and `TIINGO_API_RETRY_DELAY` control retries within a
Tiingo HTTP request. Job-level retry policy belongs to the consuming scheduler.

## PostgreSQL sink

Production callers can write normalized frames directly with the PostgreSQL
overloads:

```julia
pg = connect_postgres(ENV["OHLCV_PG_CONNECTION"])
try
    create_tables(pg)
    upsert_stock_data_bulk(pg, prices, "AAPL")
finally
    close_postgres(pg)
end
```

For best results:

1. Keep one connection open for a bounded batch instead of reconnecting for
   every ticker.
2. Prefer `upsert_stock_data_bulk` for multi-row frames.
3. Keep transaction and job boundaries bounded so a failed batch can be
   retried idempotently.
4. Measure database locks, write latency, and row counts at the consumer.

Tiingo provides the persistence primitive. Connection pooling, job
parallelism, retry scheduling, and replica/publication policy remain consumer
responsibilities.

## Parquet sink

`write_parquet` verifies a temporary frame or PostgreSQL-table snapshot before
publishing it atomically to a local file:

```julia
result = write_parquet(
    prices,
    "exports/aapl.parquet";
    overwrite=false,
    compression=:zstd,
)
```

Use the returned `ParquetWriteResult` fields (`path`, `rows`, `columns`,
`bytes`) for logging and downstream validation.

Practical guidance:

- keep `overwrite=false` unless replacement is intentional;
- write to storage with enough free space for the temporary and final file;
- compare `:zstd` with the other supported compression settings using your
  real columns and downstream readers; and
- let the consuming scheduler upload files and publish remote manifests only
  after required writes succeed.

Remote object-store performance and retention are outside this package's
responsibility, but remain subject to the provider account terms.
PostgreSQL snapshots require DuckDB's `postgres` extension to be preinstalled
for the matching DuckDB version and platform. Runtime collection only executes
`LOAD postgres` and does not download extensions.

## Fundamentals collection bounds

`collect_fundamentals` uses `initial_start_date=nothing` by default for an
unbounded initial collection and `columns=nothing` for the complete Daily
Metrics payload. Set an explicit initial date and column selection when
benchmarking bounded production workloads. The legacy `sync_fundamentals!`
workflow keeps its three-year initial-backfill default for compatibility.

## Optional DuckDB sink

Create and tune a local DuckDB connection only when the consumer selects it:

```julia
conn = connect_duckdb("analysis.duckdb")
try
    optimize_database(conn)
    create_indexes(conn)
    upsert_stock_data_bulk(conn, prices, "AAPL")
finally
    close_duckdb(conn)
end
```

Useful environment controls include:

```dotenv
TIINGO_DUCKDB_TMP=/tmp/duckdb
TIINGO_DUCKDB_MEMORY_LIMIT_GB=4
TIINGO_DUCKDB_THREADS=4
TIINGO_DUCKDB_WORKER_THREADS=3
TIINGO_DUCKDB_PRESERVE_INSERTION_ORDER=false
TIINGO_DUCKDB_UPSERT_CHUNK_SIZE=1000
```

On a memory-constrained host, begin with one query thread, one worker thread,
and a smaller upsert chunk. Increase one setting at a time and remeasure.

Do not open multiple writers against the same DuckDB file. Use a single writer,
close it reliably, and keep the file bounded to the consumer's local analysis
needs. DuckDB is not the Quansift production full-history source of record.

## Memory-conscious collection

For a large universe, process bounded slices and release references between
slices:

```julia
chunk_size = 250

for first_index in 1:chunk_size:nrow(tickers)
    last_index = min(first_index + chunk_size - 1, nrow(tickers))
    batch = tickers[first_index:last_index, :]

    result = collect_historical(
        batch,
        ENV["TIINGO_API_KEY"];
        latest_dates=watermarks,
        writer=(ticker, frame) -> upsert_stock_data_bulk(pg, frame, ticker),
        strict=true,
    )

    GC.gc()
end
```

The writer may instead target Parquet or optional DuckDB primitives. The
collection API itself does not introduce a persistent DuckDB dependency.

## Troubleshooting

If requests are throttled:

- reduce `max_concurrent`;
- shorten or split large date ranges; and
- inspect request retry and failure counts before increasing job retries.

If memory grows:

- reduce collection and upsert batch sizes;
- lower DuckDB thread counts when DuckDB is in use;
- avoid retaining completed frames; and
- measure peak resident memory outside Julia as well as allocations.

If persistence is slow:

- determine whether collection or the selected sink is the bottleneck;
- verify PostgreSQL indexes and lock activity;
- use the bulk upsert overload for multi-row frames; and
- benchmark Parquet compression separately from collection.

For API and responsibility details, see the repository's main README.
