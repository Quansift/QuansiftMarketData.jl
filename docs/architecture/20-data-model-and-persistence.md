---
title: Data model and persistence
type: concept
source_of_truth:
  - src/db/migrations.jl
  - src/db/schema.jl
  - src/db/operations.jl
  - src/db/parquet.jl
last_verified: 2026-08-20
---

# Data model and persistence

Four relations carry everything this package produces. Their shape is declared
once, in a manifest, and every deployed database is checked against it.

## The relations

| Relation | Key | Holds |
| --- | --- | --- |
| `us_tickers` | none — see below | The raw supported-tickers feed |
| `us_tickers_filtered` | none | The tradable subset |
| `historical_data` | `(ticker, date)` | End-of-day prices |
| `security_observations` | `(perma_ticker, observed_at, ticker, is_active)` | Security state over time |
| `fundamental_daily_metrics` | `(perma_ticker, metric_date)` | Daily fundamental metrics |

### Ticker is not a key of either universe table

This is the single most misunderstood fact in the schema, and getting it wrong
took down both exports for five days.

`us_tickers` is the raw feed. The same symbol legitimately appears under
several exchanges and asset types, so **duplicate tickers are its normal
state**, not corruption. On the production universe of 108,342 rows, 2,274
tickers were duplicated. `us_tickers_filtered` is nearly unique but not
entirely.

The canonical schema reflects this: both tables index `ticker` **without** a
unique constraint. Any validation that rejects duplicate tickers is asserting
something neither the producer nor the sink believes.

The one exception is a consumer-added foreign key. See
[80-production-operations](80-production-operations.md) for the single
supported case.

## Provenance: `fetched_at`

`historical_data` and `fundamental_daily_metrics` each carry a `fetched_at`
timestamp recording when the row was retrieved. It is `NOT NULL`, and in DuckDB
it carries a default of `make_timestamp_ms(epoch_ms(current_timestamp))`.

It is not decoration. The EOD upsert compares it:

```sql
ON CONFLICT (ticker, date) DO UPDATE SET ...
WHERE EXCLUDED.fetched_at >= historical_data.fetched_at
```

A row is replaced only by data at least as fresh. This makes re-running a
collection safe, and makes out-of-order arrival harmless. It also means a row
stamped with the epoch — which is what a backfill assigns to rows that predate
the column — is always overwritten by a real fetch. Backfilled provenance is
therefore self-correcting rather than sticky.

Collectors must supply `fetched_at` explicitly; the DuckDB default is a safety
net for other writers, not the path this library takes.

## PostgreSQL: the manifest, not the DDL

The authoritative description of the PostgreSQL schema is a **manifest** — a
structured description of relations, columns, and indexes — not a DDL string.
DDL creates; the manifest is what conformance is judged against.

Each column records name, type, nullability, generation, identity, and whether
it has a default. Each index records its columns, uniqueness, primacy,
partiality, validity, access method, opclasses, and collation agreement.

Index identity is compared **semantically**, by `(unique, primary, columns)`,
not by name. Two indexes covering the same columns with the same properties are
the same index regardless of what they are called.

Extra indexes are tolerated. Missing ones are not. A deployment may add an
index for its own query patterns without failing conformance; it may not remove
one the package depends on.

## Parquet: atomic by rename

`write_parquet` validates its result, writes to a temporary file **in the
destination directory**, then renames. Same-directory rename is atomic on
POSIX, so a concurrent reader sees either the previous file or the complete new
one, never a partial write.

Two limits worth knowing. There is no fsync, so this is reader-atomic rather
than crash-durable — a host that loses power mid-write may leave the temporary
file behind. And `write_parquet` is a generic sink: it persists the frame it is
given, duplicates included. Deduplication is the job of normalisation and of
the upsert primitives, which reject duplicate canonical keys before a sink is
touched.

PostgreSQL-to-Parquet requires DuckDB's `postgres` extension to be installed at
build time. Runtime library code never downloads extensions.

## What would make this page wrong

- A change to any relation's key, or the addition of a unique constraint on a
  universe table's `ticker`.
- A change to the `fetched_at` freshness comparison in the upsert.
- A change to index comparison from semantic to nominal, or to the tolerance
  for extra indexes.
- `write_parquet` gaining or losing its temp-and-rename publication.
