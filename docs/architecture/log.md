# Directory Update Log

## 2026-11-21

* **Update**: [Data model](20-data-model-and-persistence.md) documents the JSON null mapping, [Provider constraints](50-provider-and-retention-constraints.md) documents `api_request_count`, and [Failure semantics](70-failure-semantics.md) documents the raised DuckDB close failure. Pages 20, 30, 50 and 70 re-verified against `src` as of 4.2.5.
* **Update**: [Deployment topology](60-deployment-topology.md) example pin changed from `v4.2.1` to `v4.2.5`.
* **Update**: [Collection contracts](30-collection-contracts.md) now documents the one-row-per-ticker rule for `filtered` (4.2.5) and the derived `available_at` for Daily Metrics (4.2.4).
* **Update**: [Failure semantics](70-failure-semantics.md) now lists `src/db/core.jl`, the file `close_duckdb` lives in, as a source.

## 2026-11-07

* **Update**: Converted the bundle to [Open Knowledge Format](https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md) v0.2. Page front matter now uses `type`, `description`, `tags` and `sources` (replacing `source_of_truth` and `external_authority`); `last_verified` is kept as an extension key. Added [index.md](index.md) and this log; the old overview and page rules are now in [README.md](README.md).
* **Update**: Repointed a dangling link in [Production operations](80-production-operations.md): it targeted a `data-terms-and-project-identity` heading that exists in no README, and now points to [Provider and retention constraints](50-provider-and-retention-constraints.md).

## 2026-10-12

* **Update**: Removed internal deployment topology from the public docs (#691), affecting [Deployment topology](60-deployment-topology.md).

## 2026-08-23

* **Update**: Refreshed [Deployment topology](60-deployment-topology.md) against the v4.2.1 deployment.

## 2026-08-20

* **Creation**: Established this directory as the system's durable knowledge, with the eight architecture pages and a README ([System boundary](10-system-boundary.md), [Data model and persistence](20-data-model-and-persistence.md), [Collection contracts](30-collection-contracts.md), [PostgreSQL migrations](40-postgresql-migrations.md), [Provider and retention constraints](50-provider-and-retention-constraints.md), [Deployment topology](60-deployment-topology.md), [Failure semantics](70-failure-semantics.md), [Production operations](80-production-operations.md)).
* **Update**: Corrected claims the code does not support, and fixed links and lint after the move to `docs/architecture`.
