```@meta
CurrentModule = Tiingo
```

# Tiingo.jl

Tiingo is an open source Julia package for collecting Tiingo end-of-day stock
and ETF prices and Fundamentals data, normalizing responses into `DataFrame`s, and
persisting those frames through independent PostgreSQL, Parquet, or DuckDB
primitives.

## Responsibility boundary

Tiingo owns:

- Tiingo HTTP access and response validation;
- ticker, EOD price, and Fundamentals normalization into canonical `DataFrame`s;
- idempotent EOD and Fundamentals upserts for PostgreSQL and DuckDB; and
- verified atomic local Parquet writes with explicit overwrite behavior.

Tiingo does not own cron or systemd scheduling, cross-stage retries,
object-store publication, Managed PostgreSQL deployment, notifications, or
QuantScreener/TATSU sequencing.

## Storage topology

The Quansift production workflow selects system PostgreSQL as its authoritative
relational store and Parquet as its full-history interchange/archive format:

1. Tiingo collects Tiingo EOD prices and Fundamentals, normalizes them into
   `DataFrame`s, and upserts them into the system PostgreSQL source of record.
2. `quansift_scheduler` exports full history from system PostgreSQL as Parquet and
   publishes it to DigitalOcean Spaces.
3. `quansift_scheduler` publishes a rolling three-year window to DigitalOcean
   Managed PostgreSQL for downstream hosted workloads.

DuckDB remains available for local analysis and backward compatibility. It is not a
required production source of record and not a third full-history archive; this
package imposes no DuckDB retention period, so consumers bound local DuckDB state to
their own analysis needs.

## Collection and persistence API

Collection is sink-neutral. `collect_ticker_universe`, `collect_historical`, and
`collect_fundamentals` return typed results (`HistoricalCollectionResult`,
`FundamentalCollectionResult`) and accept a caller-supplied writer, so the choice of
backend belongs to the application rather than to this package.

Persistence primitives are independent and can be combined freely:

- **PostgreSQL** — `create_tables`, `replace_ticker_universe`, `upsert_stock_data`,
  `upsert_stock_data_bulk`, `upsert_security_observations`,
  `upsert_fundamental_daily_metrics`.
- **Parquet** — `write_parquet` for a `DataFrame` or a PostgreSQL table, returning
  `ParquetWriteResult`. Writes are verified and published atomically; remote upload,
  manifests, and retention belong to the calling application.
- **DuckDB** — `connect_duckdb` plus the schema, upsert, and query primitives, for
  optional local analysis.

The DuckDB-first *full-history* path — `export_to_postgres`, `update_historical`
and its parallel/sequential variants, `download_tickers_duckdb`,
`add_historical_data`, and `update_split_ticker` — is deprecated and targeted for
removal in a future major release, because system PostgreSQL and Parquet already
hold full history.
DuckDB itself is not deprecated. See `README.md` for the replacement for each entry
point.

See the repository `README.md` for runnable examples of each sink, and
[Reference](95-reference.md) for the full API.

## Contributors

```@raw html
<!-- ALL-CONTRIBUTORS-LIST:START - Do not remove or modify this section -->
<!-- prettier-ignore-start -->
<!-- markdownlint-disable -->

<!-- markdownlint-restore -->
<!-- prettier-ignore-end -->

<!-- ALL-CONTRIBUTORS-LIST:END -->
```
