---
title: System boundary
type: concept
source_of_truth:
  - AGENTS.md
  - src/QuansiftMarketData.jl
  - scripts/live_canary.jl
  - scripts/staging_smoke_test.jl
  - deploy/README.md
last_verified: 2026-08-20
---

# System boundary

QuansiftMarketData is a **library**. It collects from Tiingo, normalises what
comes back, and persists it through primitives its caller chooses. It does not
decide when to run, what to publish, or who to tell when something breaks.

Those decisions belong to `quansift_scheduler`, a separate repository. The
split is not cosmetic: it is why this package has no cron, no notification
channel, and no knowledge of DigitalOcean.

## What this package owns

- **Collection** from Tiingo: the ticker universe, end-of-day prices, and
  Fundamentals Daily Metrics.
- **Normalisation** into canonical `DataFrame` shapes, with validation at the
  provider boundary. See [30-collection-contracts](30-collection-contracts.md).
- **Persistence primitives**: the PostgreSQL `upsert_*` family and
  `replace_ticker_universe`, verified atomic Parquet writes via
  `write_parquet`, and DuckDB connection, schema, upsert, and query helpers.
- **Schema custody** for PostgreSQL: the versioned migration ledger and the
  manifest that says what conformance means. See
  [40-postgresql-migrations](40-postgresql-migrations.md).

## What the scheduler owns

- Cron and stage sequencing, including the early/late cycle structure.
- Cross-stage retries and success gating.
- DigitalOcean Spaces, and rolling three-year publication to DigitalOcean
  Managed PostgreSQL.
- Notifications, and QuantScreener/TATSU sequencing.

A consequence worth stating plainly: **the library never decides that a
production run succeeded.** It reports what happened — including a structured
list of failures — and the scheduler decides what that means. If partial data
must not be published, that gate lives in the scheduler, not here.

The bundled scripts are the exception, and a narrow one. `live_canary.jl` and
`staging_smoke_test.jl` do evaluate their own success condition and exit
non-zero on failure, because a canary with no verdict is not a canary. That
verdict covers only the script's own bounded check, never a production
ingest.

## The role of each sink

The three sinks are not interchangeable, and confusing them has caused real
incidents.

**PostgreSQL is authoritative.** It is the relational store of record. Its
schema is versioned and its conformance is enforced.

**Parquet is interchange and archive.** It is the full-history format for
handoff. Writes are validated and published by same-directory rename, so a
reader never sees a partial file.

**DuckDB is optional local state.** It is analysis or compatibility state, not
a production source of record. This package imposes **no retention period** on
DuckDB. The rolling three-year rule belongs exclusively to Managed PostgreSQL
publication and must not be restated as a DuckDB requirement — a
misattribution that has been made before.

## Removed in 4.0.0

The DuckDB-first full-history path no longer exists. `export_to_postgres`,
`update_historical`, `update_historical_parallel`,
`update_historical_sequential`, `download_tickers_duckdb`,
`add_historical_data`, and `update_split_ticker` were removed, not deprecated.

Use `collect_historical` with a caller-supplied writer,
`collect_ticker_universe` with `replace_ticker_universe`, the PostgreSQL
`upsert_*` overloads, and `write_parquet`. DuckDB connection, schema, upsert,
and query primitives are unaffected.

A consumer still calling a removed entry point fails with `UndefVarError` at
the call site. That is the intended outcome: the alternative would be a
silently different code path.

## What would make this page wrong

- Scheduling, publication, notification, or object-storage code appearing in
  this package.
- A change to which sink is authoritative, or the introduction of a retention
  rule inside this package.
- Any of the seven removed entry points returning.
