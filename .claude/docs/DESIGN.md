# Project Design Document

> This document tracks design decisions made during conversations.
> Updated automatically by the `design-tracker` skill.

## Overview

<!-- Project overview goes here -->

## Architecture

<!-- Architecture diagram and description goes here -->

### Agent Roles

| Agent | Role | Responsibilities |
|-------|------|------------------|
| | | |

## Implementation Plan

### Patterns & Approaches

| Pattern | Purpose | Notes |
|---------|---------|-------|
| | | |

### Libraries & Roles

| Library | Role | Version | Notes |
|---------|------|---------|-------|
| | | | |

### Key Decisions

| Decision | Rationale | Alternatives Considered | Date |
|----------|-----------|------------------------|------|
| Use `systemd timer` for Linux preprod/prod scheduling | The pipeline is a oneshot Docker workload with explicit Docker/network dependencies and benefits from `systemctl`/`journalctl` operability | Cron, GitHub Actions, ad hoc shell scheduling | 2026-06-16 |
| Separate host-side compose selection from app env via `TIINGO_APP_ENV_FILE` and `/etc/default/tiingojulia-pipeline` | Avoids overloading `TIINGO_ENV_FILE` across library config, shell wrappers, and Docker Compose interpolation | Keep `TIINGO_ENV_FILE` for every layer, hardcode env file paths in units | 2026-06-16 |
| Keep the current scheduled command on `scripts/staging_smoke_test.jl` and control scope via `TIINGO_SMOKE_*` variables | Matches the code that exists today and allows gradual promotion from preprod to prod without inventing an unverified full-sync entrypoint | Document a nonexistent full-sync script, add a new production script in the same change | 2026-06-16 |
| Respect `TIINGO_DB_PATH` in container runs and reserve `/tmp` only for DuckDB scratch and downloaded ticker temp files | The DuckDB file path is valid runtime state and should come from the selected app env file; forcing it to `/tmp` hid configuration and caused droplet confusion | Keep overriding `TIINGO_DB_PATH` to `/tmp/tiingo.duckdb` in Docker Compose | 2026-06-16 |
| Bind-mount the host DuckDB directory into the pipeline container and make the image repository configurable | The droplet already has a populated intermediate DuckDB file and the published image lives under `ghcr.io/quansift/tiingojulia`; host-side configuration should be enough to reuse both without editing compose on the server | Copy the database into the container image, keep hardcoded `ghcr.io/10kpw/tiingojulia`, or re-download historical data from scratch | 2026-06-16 |
| Make DuckDB ingest tunable via env vars and commit upserts in chunks | The 3GB droplet hit DuckDB OOM during long-history `ON CONFLICT` upserts; bounded transactions and low-memory overrides reduce peak memory without changing the scheduled entrypoint | Leave tuning implicit, or require manual code edits per host | 2026-06-16 |
| Use lookup dictionaries for ticker metadata and latest dates, and parallelize split refresh fetches while keeping writes serial | The prior implementation repeatedly filtered DataFrames per ticker and fetched split full-history serially; dictionary lookups remove avoidable O(N^2) CPU overhead and concurrent API fetches reduce wall-clock time without changing split-refresh correctness | Keep per-ticker DataFrame filtering everywhere, or parallelize DB writes and risk connection contention | 2026-06-16 |

## TODO

- [ ]

## Open Questions

- [ ]

## Changelog

| Date | Changes |
|------|---------|
| 2026-06-16 | Recorded Linux deployment decisions for systemd scheduling, host-side compose env selection, bounded-sync production rollout, DuckDB path handling in containers, host DuckDB bind-mount/image repo configuration, low-memory DuckDB ingest tuning, and sync-path performance refactoring decisions. |
