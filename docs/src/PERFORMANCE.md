# TiingoJulia performance guide

This guide covers Tiingo request concurrency and sink-specific tuning.
TiingoJulia does not prescribe a production scheduler or storage topology.

For Quansift production, system PostgreSQL plus Parquet is the selected path.
DuckDB tuning applies only to consumers that choose the optional local-analysis
or compatibility sink.

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

Run the repository comparison script from the repository root:

```bash
julia --project=. test/performance_comparison.jl
```

The script is a benchmark aid rather than part of the hermetic unit-test suite.

## Tiingo collection concurrency

Build the stock/ETF input universe with the sink-neutral
`collect_ticker_universe` boundary. Validate EOD payloads through
`normalize_eod_prices` before measuring or persisting them so rejected rows are
not counted as sink throughput.

For the backward-compatible DuckDB workflow, `update_historical` can fetch
multiple tickers concurrently:

```julia
update_historical(
    conn,
    tickers;
    use_parallel=true,
    batch_size=50,
    max_concurrent=10,
    add_missing=true,
)
```

Start conservatively:

| Workload | Suggested `batch_size` | Suggested `max_concurrent` |
|---|---:|---:|
| Small validation | 10–25 | 2–5 |
| Routine collection | 25–50 | 5–10 |
| Measured high-capacity host | 50–100 | 10–15 |

Higher concurrency is not automatically faster. It can increase rate-limit
responses, memory pressure, and contention in a selected sink. Tune against the
actual Tiingo plan and fail the calling job when required entities remain
incomplete.

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

TiingoJulia provides the persistence primitive. Connection pooling, job
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

Remote object-store performance and retention are outside TiingoJulia.
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

    update_historical(
        conn,
        batch;
        use_parallel=true,
        batch_size=25,
        max_concurrent=5,
    )

    GC.gc()
end
```

Use this legacy DuckDB example only when DuckDB is the selected sink. A
PostgreSQL-first consumer should instead collect a bounded frame and pass it to
the PostgreSQL overload without introducing a persistent DuckDB dependency.

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
