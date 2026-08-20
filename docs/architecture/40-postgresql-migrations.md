---
title: PostgreSQL migrations
type: concept
source_of_truth:
  - src/db/migrations.jl
last_verified: 2026-08-20
---

# PostgreSQL migrations

The most intricate subsystem in the package, and the one that has cost the most
time when misunderstood. It answers one question: **may this code write to this
database?**

## Three things, not one

Newcomers conflate these. They are independent.

**The ledger** — `public.tiingojulia_schema_migrations` — records which
migrations have been applied. Five columns: `version`, `name`, `checksum`,
`applied_at`, `package_version`. It says what *happened*.

**The manifest** describes what each version's schema should *look like*. It
says what *should be*.

**Conformance** is the comparison. A database is migratable only when its
actual catalog matches the manifest for the version its ledger claims.

A ledger reporting version 3 does not mean the schema is correct. It means
three migrations were recorded. Those are different claims, and on 2026-08-19
the production database satisfied one while failing the other.

## Versions

`POSTGRES_SCHEMA_VERSION` is **3**.

1. `canonical_v1_baseline` — the baseline schema.
2. `eod_fetched_at_provenance` — adds `fetched_at` to `historical_data`.
3. State-discriminated observation key — widens the `security_observations`
   primary key to `(perma_ticker, observed_at, ticker, is_active)`.

Each carries a checksum over its definition text, so a migration cannot be
edited after it has been applied somewhere without the ledger noticing.

## Atomicity

`migrate_postgres!` runs everything in **one transaction**: an advisory lock,
every pending migration, and every ledger insert, then `COMMIT`. Any failure
rolls back.

There is no half-migrated state. Either the schema and the ledger both advance
or nothing changes. This has been exercised in production: a migration
cancelled by a statement timeout after five minutes left the database exactly
as it was.

The cost of that guarantee is that migration 2 holds every replaced row version
until commit. Size accordingly — see
[80-production-operations](80-production-operations.md).

## Fail-closed, and why

If the catalog does not match the manifest, `migrate_postgres!` refuses. It
does not attempt repair.

This is deliberate. A database that has drifted may have drifted for a reason
nobody present understands, and a migration written against an assumed shape
can destroy data when that assumption is wrong. Refusing costs a maintenance
window. Guessing costs the data.

Since 4.1.0 the refusal **names what differs**:

```text
PostgreSQL schema does not match the canonical target manifest for version 1;
take a backup before manual repair:
  security_observations.ticker: expected NOT NULL, found nullable
  security_observations.(ticker): expected present, found absent
```

Before that it said only that something did not match, while instructing the
operator to repair by hand — which took roughly an hour of writing throwaway
diagnostics against private internals. The drift engine and the message are one
implementation: `_manifest_matches` is *defined* as the drift report being
empty, so the predicate and the message cannot disagree.

## Readiness: asking without doing

`postgres_migration_readiness(conn; target_version)` answers the same question
without attempting the work. It takes no lock, opens no transaction, and
creates nothing.

That last point matters: `migrate_postgres!` creates the ledger as a side
effect, so it cannot serve as a dry run. Readiness can, and should be a
preflight step before any maintenance window.

States:

| State | Meaning |
| --- | --- |
| `:ready` | At the target version and conforming |
| `:migration_required` | Behind, and conforming at its current version |
| `:drift` | Catalog does not match the version it claims |
| `:newer_schema` | Migrated by a newer build than this one |
| `:unknown_layout` | No ledger, and the pre-ledger catalog is unrecognised |
| `:invalid_ledger` | The ledger itself is unreadable or inconsistent |

Two orderings are deliberate. **Drift outranks a pending migration**, because
migrating a database that does not match the version it claims is precisely
what fail-closed exists to prevent. **A newer schema outranks both**, because an
older build cannot know what a newer manifest should contain, so its drift
findings would be noise.

`postgres_schema_version` is narrower and returns `0` for both a fresh database
and an unrecognised pre-ledger one. Readiness separates them.

## Pre-ledger databases

A database predating the ledger is classified by catalog shape against a finite
set of recognised layouts, then bootstrapped. An unrecognised layout is refused
rather than guessed at.

## A known ordering defect

`migrate_postgres!` validates the ledger's **column layout before its version**:

```julia
_create_ledger!(conn)
_validate_ledger_relation!(conn; require_write=true)   # exact 5-column match
ledger = _read_ledger(conn)
from_version = _validate_ledger(ledger)                # version
```

The layout check is exact equality against a hardcoded five-column list. If a
future migration adds a sixth column, an **older** build meeting that ledger
reports `migration ledger columns do not match the canonical manifest` — which
reads as corruption — rather than "this database was migrated by a newer
build". `postgres_schema_version` has the same ordering.

This is documented rather than fixed because no migration currently adds a
ledger column. Anyone who adds one must reorder first: split
`_validate_ledger_relation!` into a pre-read safety subset and a strict layout
check, then order the work as safety, read, version, strict layout. `_read_ledger`
selects only `version`, `name`, and `checksum` — columns no trailing addition
affects — so the read stays protected while the version becomes knowable first.
The fix must ship in the same release as the migration that needs it. See
issue #658.

## What would make this page wrong

- A change to `POSTGRES_SCHEMA_VERSION`, or a new migration.
- A change to the ledger's columns, or to validation ordering.
- A change to the readiness states or their precedence.
- Migration ceasing to be a single transaction.
