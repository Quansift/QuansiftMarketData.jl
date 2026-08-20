---
title: Failure semantics
type: concept
source_of_truth:
  - src/results.jl
  - src/api.jl
  - src/db/migrations.jl
  - src/db/schema.jl
  - src/QuansiftMarketData.jl
last_verified: 2026-08-20
---

# Failure semantics

Three ways this system can fail, in descending order of how much they cost.

**Fail closed** — refuse to proceed, and say why. The best outcome. Nothing is
damaged and the operator learns something.

**Fail loudly** — raise where the caller can see it. Acceptable. The operator
learns something, though possibly at an awkward moment.

**Fail silently** — continue, having done the wrong thing or nothing. The
expensive one. The 2026-08-19 outage ran for five days not because the failures
were subtle but because nothing was watching for them.

Most of the 4.1.0 work was converting instances of the third kind into one of
the first two.

## Where the system fails closed

- **Schema conformance.** A catalog that does not match the manifest refuses
  migration, naming what differs.
- **Migration transactions.** Any failure rolls back entirely. A migration
  cancelled at five minutes by a statement timeout left production unchanged.
- **Ledger validation.** A gapped, unordered, or checksum-mismatched ledger
  refuses. A schema newer than the running build refuses.
- **Provider input.** `normalize_eod_prices` validates before persistence.
  End-of-day input without `fetched_at` is rejected rather than defaulted.
- **Duplicate canonical keys** are rejected by normalisation and by the upsert
  primitives before a sink is touched.
- **Foreign keys on universe tables.** Any consumer key other than the one
  supported by name fails the replacement, atomically.
- **Runtime extension downloads** are refused; the DuckDB `postgres` extension
  must be present at build time.

## Failure classification

`SyncFailure` carries a `category`, and the distinction is load-bearing:

| Category | Meaning | Response |
| --- | --- | --- |
| `:quota` | The provider's request quota is spent | Expected; a later cycle collects it |
| `:transient` | A retryable upstream error | Watch for repetition |
| `:no_data` | The security had nothing to give | Not a failure |
| `:permanent` | The request failed on its own merits | Investigate |

`is_quota_failure` is the predicate. Before 4.1.0 all of these collapsed into a
single `retryable` boolean, which left alerting wrong in one direction: alert on
failures and operators learn to ignore it; stay silent and real breakage goes
unseen.

**Only a status the thrower committed to earns a category.** An
`ErrorException` whose wording mentions a rate limit does not become `:quota`,
for the same reason `is_no_data_error` refuses to read messages: wording is not
a fact.

## Silent failures that were removed

Worth recording, because each was invisible by construction.

**An unrecognised `TIINGO_LOGGER` installed a `NullLogger`**, discarding every
diagnostic. It could not warn — the logger that would have carried the warning
was the one being discarded. A deployment typo made a run indistinguishable
from a quiet success. Unknown values now fall back to the console and warn;
silence requires asking for it with `none`.

**A migration guard keyed on the wrong condition.** The DuckDB `fetched_at`
migration tested whether the column was *absent*. A database left half-migrated
by an earlier failure had the column but not the constraint, so it was skipped
forever. It now tests the invariant the DDL declares, so both that state and a
hand-repaired one converge.

**A refusal that named nothing.** Schema drift failed closed — correctly — but
said only that something did not match, while instructing the operator to repair
by hand. Failing closed without saying what to repair is only half a virtue.

## Two DuckDB defects to know about

Measured against DuckDB.jl 1.5.2. Both are **process aborts**, not exceptions —
`libc++abi: Pure virtual function called!` followed by SIGABRT. Neither can be
caught, so both must be avoided by construction.

1. **Re-applying `SET NOT NULL` to a column that already carries it aborts.**
   The `fetched_at` repair therefore issues the constraint and the default
   independently rather than as a fixed pair.
2. **`COMMIT` aborts when a transaction carries only `DROP INDEX`,
   `SET DEFAULT`, and `CREATE INDEX`.** The same statements outside a
   transaction are fine, and the same transaction with `SET NOT NULL` in it is
   fine. The default-only repair consequently restores indexes in a `finally`
   rather than rolling back — a deliberate corner, marked in the source, taken
   because that branch rewrites no data.

Revisit both if a DuckDB release changes the behaviour.

## What the caller must decide

This package reports; it does not judge. Two decisions belong to the scheduler:

- **Whether a partial collection may be published.** Defaults are
  `continue_on_error = true`, `strict = false`. Given the provider quota, that
  is correct — see
  [50-provider-and-retention-constraints](50-provider-and-retention-constraints.md).
  The gate belongs in the scheduler, informed by `is_quota_failure`.
- **Whether the sink schema is ready.** Nothing in this package forces
  `migrate_postgres!` to run before writes. On 2026-08-19 the production
  PostgreSQL sat at ledger version 1 while the code wrote a column that version
  did not have, and nobody noticed until the fifth day of an outage.

## What would make this page wrong

- A change to failure categories, or to how they are derived.
- A change to the `strict` / `continue_on_error` defaults.
- A DuckDB release that fixes or changes either abort.
- New silent-failure paths, or the closing of the two open ones above.
