---
title: Provider and retention constraints
type: reference
source_of_truth:
  - src/api.jl
  - src/results.jl
  - docs/architecture/80-production-operations.md
external_authority:
  - Tiingo plan terms and API documentation
  - quansift_scheduler cron configuration
last_verified: 2026-08-20
---

# Provider and retention constraints

Two limits shape this system that are not properties of its code. One says how
fast data may be fetched. The other says whether it may be kept at all. Neither
can be discovered by reading this repository, which is why they are written
here.

> **Provenance warning.** The request-quota figures below are **not derived from
> this codebase**. They come from the Tiingo plan in force and were confirmed by
> the operator on 2026-08-20. This repository's only visible trace of the quota
> is that a 429 response is classified as `:quota`. Before relying on a number
> here, verify it against Tiingo's own documentation and the account's current
> plan. Do not treat this page as authoritative for the provider's terms.

## The request quota

**10,000 tickers per clock hour, resetting at the top of the hour.** Not a
rolling window.

This single fact explains the shape of the production schedule, and not knowing
it produced a real incident.

The universe does not fit in one hour:

| Export | Tickers | Share of the hourly quota |
| --- | --- | --- |
| Stock | 8,013 | 80% |
| ETF | 4,246 | 42% |
| Combined | 12,259 | **123%** |

So the scheduler places each export in its **own clock hour** — stock at 17:35,
ETF at 18:00 — where each fits comfortably. A late cycle repeats both at 19:00
and 20:00. That second pass serves two purposes: it collects anything the early
pass missed, and it captures Tiingo's late revisions, which matter especially
for ETFs.

### The failure this prevents

On 2026-08-19, during recovery, both exports were run back to back inside a
single hour. The result: 183 ETF tickers failed in one contiguous alphabetical
block, `USFE` through `WBIL`, while everything after them succeeded — the top of
the next hour reset the quota mid-run.

The pipeline reported `completed successfully`. Nothing in the failure list
distinguished a quota rejection from a broken ticker.

Two lessons are encoded in the system as a result:

1. **`SyncFailure.category`** now separates `:quota` from `:transient`,
   `:no_data`, and `:permanent`, so a caller can tell an expected gap from
   something worth alerting on. Only an HTTP status the provider committed to
   earns the category; message wording never does.
2. **`strict = true` on end-of-day collection would be wrong.** Under the
   normal schedule each export fits its hour, but a strict run turns any quota
   rejection into a total failure. The correct posture is record and continue,
   with the late cycle collecting the remainder.

### The runway

Stock sits at **80%** of its hourly quota. The filtered universe grew by 8
tickers on 2026-08-19 alone.

When the stock universe crosses 10,000, the schedule stops fitting and fails in
exactly the shape above: a contiguous block of tail failures while the pipeline
reports success. Monitor it:

```sql
SELECT count(*) FROM us_tickers_filtered WHERE assettype = 'Stock';
```

At 9,000, start planning — splitting stock across two hours, or pacing requests.

## Retry behaviour

The API layer treats 429 and 5xx as retryable, honours a `Retry-After` header,
and backs off exponentially with additive jitter, never shrinking, capped at
300 seconds. Defaults are 3 retries with a 2-second base delay.

That is correct for a transient error and **cannot bridge a spent quota**,
which recovers only at the top of the hour. Quota exhaustion is a capacity
problem, not a transient one; it is solved by scheduling, not by retrying.

## The retention gate

Storage architecture is not permission to retain data.

Before enabling any persistent path — PostgreSQL, DuckDB, Parquet, Spaces,
files, logs, queues, archives, backups, disaster recovery — the operator must
verify that the current Tiingo plan, or a separate written agreement, permits
every enabled path. The operator must also maintain a deletion procedure
covering every copy, applicable if the paid plan expires, is cancelled or
terminated, or is downgraded.

**Starter and Trial plan users must not use these persistent paths.** The
sink-free canary path exists for that case.

This gate is not enforceable in code, which is exactly why it is written down.

## What would make this page wrong

- Any change to the Tiingo plan, its quota, or its retention terms. **This page
  cannot detect that**; it must be re-verified against the provider.
- A change to the scheduler's cron placement that breaks the one-export-per-hour
  arrangement.
- The stock universe crossing 10,000 tickers.
- A change to retry classification or backoff.
