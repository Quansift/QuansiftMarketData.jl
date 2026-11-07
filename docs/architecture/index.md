---
okf_version: "0.2"
---

<!-- OKF section 8 index sections are top-level headings, so the one-H1 rule does not apply here. -->
<!-- markdownlint-disable MD025 -->

# Architecture

* [Architecture documentation: conventions](README.md) - why these pages exist, the page format, and the rules for changing them

# Boundary and data

* [System boundary](10-system-boundary.md) - ownership boundary between QuansiftMarketData and the consuming scheduler
* [Data model and persistence](20-data-model-and-persistence.md) - shape of the data and where it lives: PostgreSQL, verified Parquet and optional DuckDB
* [Collection contracts](30-collection-contracts.md) - what each collector promises its caller, and the result types that carry those promises

# Change and constraints

* [PostgreSQL migrations](40-postgresql-migrations.md) - how the PostgreSQL schema moves forward safely, and what a migration costs at production size
* [Provider and retention constraints](50-provider-and-retention-constraints.md) - what the data provider may refuse and what may be retained or redistributed
* [Deployment topology](60-deployment-topology.md) - how a consumer picks up a release: tags, preflight and the consumer's own pin

# Operating the system

* [Failure semantics](70-failure-semantics.md) - what happens when something goes wrong: error types, partial failure and recovery
* [Production operations](80-production-operations.md) - procedures for running a migration, a canary and a recovery in production

# History

* [Update log](log.md) - dated changes to this bundle
