<!-- Keep a Changelog repeats the same section headings under every release, so
     duplicate-heading detection is scoped to siblings for this file only. -->
<!-- markdownlint-configure-file { "MD024": { "siblings_only": true } } -->

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Sink-neutral collection API: `collect_ticker_universe`, `collect_historical`, and
  `collect_fundamentals`, with the matching normalizers `normalize_eod_prices`,
  `normalize_security_observations`, and `normalize_fundamental_daily_metrics`.
- Typed collection results `HistoricalCollectionResult`, `FundamentalCollectionResult`,
  and `SyncFailure`, plus `SyncIncompleteError` for strict callers that must convert a
  partial failure into a non-successful job result.
- PostgreSQL persistence primitives: `create_tables(pg_conn)`, `replace_ticker_universe`,
  `upsert_security_observations`, `upsert_fundamental_daily_metrics`, and PostgreSQL
  overloads of `upsert_stock_data` and `upsert_stock_data_bulk`.
- Verified atomic local Parquet output via `write_parquet`, with DataFrame and
  PostgreSQL-table overloads returning `ParquetWriteResult`.
- Fundamentals surface: `get_fundamental_meta`, `get_fundamental_watermarks`,
  `sync_fundamentals!`, and a resumable market-cap backfill script.
- `scripts/refresh_postgres_via_duckdb.jl` for refreshing a local PostgreSQL
  `historical_data` table through a throwaway DuckDB working file.
- Opt-in PostgreSQL 17 integration lane in CI, Parquet sink contract tests, and
  secret-redaction tests.
- Forward-only PostgreSQL schema migrations with
  `POSTGRES_SCHEMA_VERSION == 1`, a checksummed public ledger, advisory-lock
  serialization, finite legacy-layout recognition, and rollback-safe
  PostgreSQL 17 integration coverage.
- Deterministic `micro`, `load`, and `soak` benchmark modes in an independent
  project, with bounded synthetic fixtures, metadata-only JSON results, one
  Linux/Julia 1.12 PR smoke, and scheduled PostgreSQL/local evidence jobs.
- An advisory, allowlisted live Tiingo canary that observes normalized frames
  in memory and performs zero application persistence.
- Development, exact-main-SHA release-preflight, and stable post-tag hygiene
  modes covering Project, changelog, citation, config, secrets, migrations,
  hermetic tests, PostgreSQL 17, docs/links, benchmark smoke, and image build.

### Changed

- Documented the storage responsibility boundary: system PostgreSQL is the authoritative
  relational store and Parquet is the full-history interchange/archive format. DuckDB is
  optional local analysis state and is no longer a production full-history source of
  record. This repository imposes no DuckDB retention period.
- Cross-system orchestration — DigitalOcean Spaces publication, rolling three-year
  DigitalOcean Managed PostgreSQL publication, and QuantScreener/TATSU sequencing — is
  owned by `quansift_scheduler`, not TiingoJulia.
- Prefer the `OHLCV_DUCKDB_PATH` and `OHLCV_PG_CONNECTION` environment variables.
- DuckDB historical upsert is now set-based.
- PostgreSQL `create_tables` now delegates to the versioned migration runner;
  unknown, corrupt, or newer schemas fail closed instead of being guessed or
  overwritten.
- CI, documentation, lint, and image release behavior now accepts only exact
  stable `vX.Y.Z` tags. Live-canary status and performance timing/RSS data are
  not release gates.

### Deprecated

- The DuckDB-first full-history path is deprecated and targeted for removal in 2.0.0.
  System PostgreSQL is the source of record and Parquet is the full-history archive, so
  routing full history through DuckDB duplicates both. Affected entry points:
  `export_to_postgres`, `update_historical`, `update_historical_parallel`,
  `update_historical_sequential`, `download_tickers_duckdb`, `add_historical_data`, and
  `update_split_ticker`.
- Replacements are already available: use `collect_historical` with a caller-supplied
  writer instead of `update_historical`, and `collect_ticker_universe` with
  `replace_ticker_universe` instead of `download_tickers_duckdb`. Write full history to
  PostgreSQL through the `upsert_*` overloads and archive it with `write_parquet` instead
  of bridging DuckDB to PostgreSQL through `export_to_postgres`.
- DuckDB itself is not deprecated. Connection, schema, upsert, and query primitives
  (`connect_duckdb`, `close_duckdb`, `create_tables`, `create_indexes`,
  `optimize_database`, the DuckDB `upsert_*` overloads, and `get_tickers_*`) remain
  supported for optional local analysis.

### Fixed

- Fundamentals export completes within a failure tolerance instead of failing
  all-or-nothing, and tolerates empty payloads and multi-candidate probes.
- PostgreSQL export refreshes FK-referenced tables in place via upsert rather than
  drop-and-replace.
- The `historical_data` staging table retains its `(ticker, date)` key.

## [1.0.0] - 2026-02-13

### Added

- `config.toml` and `config.example.toml` for readable, comment-friendly configuration.
- `.env.example` template for secure environment setup.
- CI release hygiene checks for tracked `.env*` files and required config keys.

### Changed

- Configuration loading now prefers `config.toml` and falls back to legacy `config.json`.
- Configuration defaults are overrideable via `TIINGO_*` environment variables.
- API/network tests run only when `TIINGO_TEST_LIVE_API=true`, keeping CI deterministic by default.

### Fixed

- `download_latest_tickers` ZIP extraction now uses compatible `ZipFile.Reader` open/close handling.
- Sequential historical update now correctly handles no-data responses.
- Parallel update no longer assumes a `ticker` column exists in API-returned DataFrames.
- `get_api_key` error output no longer leaks environment variable names.

[unreleased]: https://github.com/Quansift/TiingoJulia/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/Quansift/TiingoJulia/releases/tag/v1.0.0
