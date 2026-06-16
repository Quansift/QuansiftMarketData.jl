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

## TODO

- [ ]

## Open Questions

- [ ]

## Changelog

| Date | Changes |
|------|---------|
| 2026-06-16 | Recorded Linux deployment decisions for systemd scheduling, host-side compose env selection, and bounded-sync production rollout. |
