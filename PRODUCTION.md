# Production Checklist

TiingoJulia is close to production use, but it should be shipped with the same discipline as any other data pipeline:

- Use one PostgreSQL connection source of truth. Pass the same DSN to `connect_postgres(...)` and `export_to_postgres(...; pg_connection_string=...)`.
- Keep logs on `stdout`/`stderr`. The package now defaults to `TIINGO_LOGGER=console`; use `tee-file` only if your runtime also captures process output.
- Build the exact image you plan to ship. CI now builds [`docker/Dockerfile`](docker/Dockerfile) on Linux.
- Keep required schema creation fail-fast. A startup that cannot create its tables should stop immediately.
- Swap exported PostgreSQL tables atomically. TiingoJulia now loads into staging tables and renames them inside a transaction.
- Run hermetic tests in CI. Local `.env` files should not change test outcomes.

## Recommended Deployment Shape

- Scheduler: Cron, GitHub Actions, systemd timer, or your orchestrator
- Runtime: container built from [`docker/Dockerfile`](docker/Dockerfile)
- Backing stores: DuckDB for local working state, PostgreSQL for shared serving/analytics
- Secrets: environment variables or a secret manager
- Telemetry: process logs plus request/error/row-count metrics

## Pre-Production Verification

- Run `julia --project=. test/runtests.jl`
- Build the image with `docker build -f docker/Dockerfile .`
- Exercise one real Tiingo sync in staging
- Exercise one real PostgreSQL export in staging
- Confirm log capture, alerting, and retry behavior
- Confirm DuckDB temp and data directories are writable in the target environment

## Staging Smoke Test

1. Create a staging env file from [.env.staging.example](.env.staging.example).
2. Or use the machine-specific `.env.staging` that lives in the repo root and fill in the placeholders.
3. Set `TIINGO_API_KEY`.
4. Set `TIINGO_PG_CONNECTION` only if you want to validate PostgreSQL export too.
5. Keep `TIINGO_SMOKE_EXPORT_POSTGRES=false` for the first run.
6. Run the smoke test:

```bash
/Users/otwn/Documents/TiingoJulia/scripts/run_staging_smoke.sh
```

The smoke test will:

- Create or open the DuckDB file from `TIINGO_DB_PATH`
- Optimize and index the database
- Download Tiingo ticker metadata
- Pull a bounded set of historical prices using `TIINGO_SMOKE_TICKER_LIMIT`
- Optionally export `historical_data` and `us_tickers_filtered` to PostgreSQL

## Launch Checklist

1. Build the artifact you plan to ship: `docker build -f docker/Dockerfile .`
2. Run `julia --project=. test/runtests.jl`
3. Run the staging smoke test with PostgreSQL export disabled
4. Run the staging smoke test again with `TIINGO_SMOKE_EXPORT_POSTGRES=true`
5. Compare DuckDB and PostgreSQL row counts after the export run
6. Confirm your runtime captures stdout logs
7. Put the smoke-test settings behind a production scheduler
8. Increase ticker scope gradually instead of jumping straight to the full universe

## macOS Scheduler

This repo now includes a `launchd` job definition at [`deploy/launchd/com.otwn.tiingojulia.staging-smoke.plist`](deploy/launchd/com.otwn.tiingojulia.staging-smoke.plist).

Install it with:

```bash
mkdir -p /Users/otwn/Library/LaunchAgents /Users/otwn/Documents/TiingoJulia/logs
cp /Users/otwn/Documents/TiingoJulia/deploy/launchd/com.otwn.tiingojulia.staging-smoke.plist /Users/otwn/Library/LaunchAgents/
launchctl unload /Users/otwn/Library/LaunchAgents/com.otwn.tiingojulia.staging-smoke.plist 2>/dev/null || true
launchctl load /Users/otwn/Library/LaunchAgents/com.otwn.tiingojulia.staging-smoke.plist
```

Run it immediately once with:

```bash
launchctl start com.otwn.tiingojulia.staging-smoke
```

The current schedule is daily at `06:00` local machine time. Adjust the `Hour` and `Minute` fields in the plist if you want a different schedule.

## Standards Referenced

- Docker best practices: <https://docs.docker.com/build/building/best-practices/>
- Twelve-Factor config/logs/dev-prod parity: <https://12factor.net/config>, <https://12factor.net/logs>, <https://12factor.net/dev-prod-parity>
- DuckDB PostgreSQL extension: <https://duckdb.org/docs/stable/core_extensions/postgres>
- PostgreSQL transactions: <https://www.postgresql.org/docs/current/tutorial-transactions.html>
- OpenTelemetry: <https://opentelemetry.io/docs/>
