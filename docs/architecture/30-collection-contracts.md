---
title: Collection contracts
type: concept
source_of_truth:
  - src/sync.jl
  - src/fundamental_sync.jl
  - src/results.jl
  - src/api.jl
last_verified: 2026-08-20
---

# Collection contracts

Every collector in this package follows the same shape: take a source, return a
typed result, and let the caller choose the sink. None of them decide whether
the run was acceptable.

## Sink-neutral collection

`collect_ticker_universe`, `collect_historical`, and `collect_fundamentals`
return canonical `DataFrame`s and a typed result. Persistence is a separate
step, performed by a writer the caller supplies or by an explicit `upsert_*`
call.

This separation is why the same collection can feed PostgreSQL, Parquet, and
DuckDB without three code paths, and why a collection can be inspected before
anything is written.

## The result is the contract

`HistoricalCollectionResult` and `FundamentalCollectionResult` report what
happened per entity: `attempted`, `updated`, `unchanged`, `unavailable`,
`failed`, a structured `failures` vector, and rows written.

**A collection that reports failures has not failed.** By default
`collect_historical` runs with `continue_on_error = true` and `strict = false`:
it records what went wrong and keeps going. Passing `strict = true` makes a
non-empty `failures` throw `SyncIncompleteError` instead.

Which is correct depends on why entities failed, and that is a scheduler
decision. See [70-failure-semantics](70-failure-semantics.md) for how to tell
an expected gap from real breakage, and
[50-provider-and-retention-constraints](50-provider-and-retention-constraints.md)
for why `strict = true` on end-of-day collection would fail every day.

## The universe contract

`collect_ticker_universe` returns two frames, `all` and `filtered`.

`all` is the whole normalised feed, sorted by `(ticker, exchange)`. **Duplicate
tickers are expected** — see
[20-data-model-and-persistence](20-data-model-and-persistence.md).

`filtered` is the tradable subset: supported exchanges and asset types, no
slash in the symbol, and an end date at or after an active cutoff. The cutoff
is derived from the data rather than configured — the maximum end date among
NYSE-listed stocks — so a stale feed narrows the universe instead of silently
admitting delisted symbols.

`replace_ticker_universe` publishes both snapshots atomically. They are exact
replacements: a symbol absent from the new feed disappears from the universe
tables. It never disappears from `historical_data`, because the canonical
schema deliberately does not make price history a child of the universe.

## The end-of-day contract

`collect_historical` takes tickers with per-ticker latest dates and fetches
only what is missing. `normalize_eod_prices` validates the provider response
before it can reach a sink.

Every row carries `fetched_at`, supplied by the collector for the whole call
rather than per row, so one collection produces one provenance stamp.
`_validate_eod_fetched_at` rejects input lacking the column outright: a row
without provenance cannot be compared for freshness, so it is refused rather
than defaulted.

Splits are detected in newly collected data, and an affected ticker has its
full history refetched rather than patched — a split changes every historical
adjusted price, so incremental repair would be wrong.

## The Fundamentals contract

`collect_fundamentals` produces security observations and daily metrics, keyed
by `perma_ticker` rather than by ticker, because a security's symbol changes
while its identity does not.

`security_observations` is keyed by
`(perma_ticker, observed_at, ticker, is_active)`. The ticker and active flag
are part of the key so that a symbol change or a delisting is a new row rather
than an overwrite — the table records state over time, not current state.

Watermarks via `get_fundamental_watermarks` let a sync resume rather than
refetch.

## Errors are typed, not matched

A provider that returns 200 with no rows throws `NoDataError`, distinct from
`ApiStatusError` for a failed request. `is_no_data_error` covers both
`NoDataError` and an `ApiStatusError` carrying 404 or 410.

The reason is stated in the source and worth repeating: an `ErrorException`
whose wording happens to mention "no data" does not qualify, **because wording
is not a fact the thrower committed to**. Callers must never classify by
matching English substrings in a message. The same principle governs
`SyncFailure.category`.

## What would make this page wrong

- A change to the canonical column set, or to the writer callback contract.
- A change to the `strict` / `continue_on_error` defaults or semantics.
- The filtered-universe cutoff becoming configured rather than derived.
- Split handling becoming incremental.
- Error classification moving to message matching.
