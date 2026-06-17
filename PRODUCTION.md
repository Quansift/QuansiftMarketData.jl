# Production Checklist

TiingoJulia is close to production use, but it should be shipped with the same discipline as any other data pipeline:

- Use one PostgreSQL connection source of truth. Pass the same DSN to `connect_postgres(...)` and `export_to_postgres(...; pg_connection_string=...)`.
- Keep logs on `stdout`/`stderr`. The package now defaults to `TIINGO_LOGGER=console`; use `tee-file` only if your runtime also captures process output.
- Build the exact image you plan to ship. CI now builds [`docker/Dockerfile`](docker/Dockerfile) on Linux.
- Keep required schema creation fail-fast. A startup that cannot create its tables should stop immediately.
- Swap exported PostgreSQL tables atomically. TiingoJulia now loads into staging tables and renames them inside a transaction.
- Run hermetic tests in CI. Local `.env` files should not change test outcomes.

## Recommended Deployment Shape

- Scheduler: systemd timer
- Runtime: container built from [`docker/Dockerfile`](docker/Dockerfile)
- Backing stores: DuckDB for local working state, PostgreSQL for shared serving/analytics
- Secrets: environment variables or a secret manager
- Telemetry: process logs plus request/error/row-count metrics

`systemd timer` is the recommended scheduler for both `10kpw-non-prod` and `tokusenquant.com`.
It fits the existing repository assets, handles Docker/network dependencies cleanly,
and is easier to inspect than `cron` with `systemctl` and `journalctl`.

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
6. Run the smoke test.
   Inline `TIINGO_SMOKE_*` overrides now take precedence over values in the env file:

```bash
TIINGO_SMOKE_TICKER_LIMIT=5 TIINGO_SMOKE_EXPORT_POSTGRES=false scripts/run_staging_smoke.sh
```

The smoke test will:

- Create or open the DuckDB file from `TIINGO_DB_PATH`
- Optimize and index the database
- Download Tiingo ticker metadata
- Pull a bounded set of historical prices using `TIINGO_SMOKE_TICKER_LIMIT`
- Optionally export `historical_data` and `us_tickers_filtered` to PostgreSQL

`TIINGO_DB_PATH` is the actual intermediate DuckDB file path.
`TIINGO_DUCKDB_TMP` is separate and only controls DuckDB scratch space.
The containerized deployment keeps scratch space and downloaded ticker temp files in `/tmp`
but no longer overrides `TIINGO_DB_PATH`.
On 3GB-class droplets, set `TIINGO_DUCKDB_MEMORY_LIMIT_GB=1`, `TIINGO_DUCKDB_THREADS=1`,
`TIINGO_DUCKDB_WORKER_THREADS=1`, `TIINGO_DUCKDB_PRESERVE_INSERTION_ORDER=false`,
and `TIINGO_DUCKDB_UPSERT_CHUNK_SIZE=500` in the app env file.

## Launch Checklist

1. Build the artifact you plan to ship: `docker build -f docker/Dockerfile .`
2. Run `julia --project=. test/runtests.jl`
3. Run the staging smoke test with PostgreSQL export disabled
4. Run the staging smoke test again with `TIINGO_SMOKE_EXPORT_POSTGRES=true`
5. Compare DuckDB and PostgreSQL row counts after the export run
6. Confirm your runtime captures stdout logs
7. Put the smoke-test settings behind a production scheduler
8. Increase ticker scope gradually instead of jumping straight to the full universe

## Linux Deployment

This repo ships Linux deployment assets for Docker + `systemd`:

- [`deploy/compose/docker-compose.pipeline.yml`](deploy/compose/docker-compose.pipeline.yml)
- [`deploy/systemd/tiingojulia-pipeline.service`](deploy/systemd/tiingojulia-pipeline.service)
- [`deploy/systemd/tiingojulia-pipeline.timer`](deploy/systemd/tiingojulia-pipeline.timer)
- [`deploy/systemd/tiingojulia-pipeline.env.example`](deploy/systemd/tiingojulia-pipeline.env.example)

The current scheduled container command is still [`scripts/staging_smoke_test.jl`](scripts/staging_smoke_test.jl).
Production scope is therefore controlled by `TIINGO_SMOKE_*` variables in the app env file.
Container runs respect `TIINGO_DB_PATH` from the selected app env file.
The compose file bind-mounts a host DuckDB directory into the container, so `TIINGO_DB_PATH`
should point at the container-side mount location, such as `/data/tiingo_historical_data.duckdb`.

### 10kpw Preprod (`10kpw-non-prod`)

```bash
sudo mkdir -p /opt/tiingojulia
sudo chown "$USER":"$USER" /opt/tiingojulia
git clone https://github.com/10kpw/TiingoJulia.git /opt/tiingojulia
cd /opt/tiingojulia

cp .env.staging.example .env.staging

cat >/tmp/tiingojulia-pipeline <<'EOF'
TIINGO_IMAGE_REPO=ghcr.io/quansift/tiingojulia
TIINGO_IMAGE_TAG=staging
TIINGO_APP_ENV_FILE=/opt/tiingojulia/.env.staging
TIINGO_DOCKER_NETWORK=db-net
TIINGO_DB_HOST_DIR=/home/shin/tiingo/data
TIINGO_DB_CONTAINER_DIR=/data
EOF

sudo install -m 0644 /tmp/tiingojulia-pipeline /etc/default/tiingojulia-pipeline
sudo cp deploy/systemd/tiingojulia-pipeline.service /etc/systemd/system/
sudo cp deploy/systemd/tiingojulia-pipeline.timer /etc/systemd/system/
sudo systemctl daemon-reload

echo "$GHCR_PAT" | docker login ghcr.io -u <github-user> --password-stdin

docker compose -f deploy/compose/docker-compose.pipeline.yml pull pipeline
docker compose -f deploy/compose/docker-compose.pipeline.yml run --rm pipeline

sudo systemctl enable --now tiingojulia-pipeline.timer
systemctl list-timers tiingojulia-pipeline.timer
journalctl -u tiingojulia-pipeline.service -f
```

For a bounded one-off Docker smoke run, pass overrides with `run -e`:

```bash
docker compose -f deploy/compose/docker-compose.pipeline.yml run --rm \
  -e TIINGO_SMOKE_TICKER_LIMIT=100 \
  -e TIINGO_SMOKE_EXPORT_POSTGRES=false \
  pipeline
```

Do not use `TIINGO_SMOKE_TICKER_LIMIT=100 docker compose ...` for this. Prefix env vars only affect Compose interpolation and do not override values loaded into the container from `TIINGO_APP_ENV_FILE`.

### TokusenQuant Prod (`tokusenquant.com`)

```bash
sudo mkdir -p /opt/tiingojulia
sudo chown "$USER":"$USER" /opt/tiingojulia
git clone https://github.com/10kpw/TiingoJulia.git /opt/tiingojulia
cd /opt/tiingojulia

cp .env.example .env

cat >/tmp/tiingojulia-pipeline <<'EOF'
TIINGO_IMAGE_REPO=ghcr.io/quansift/tiingojulia
TIINGO_IMAGE_TAG=latest
TIINGO_APP_ENV_FILE=/opt/tiingojulia/.env
TIINGO_DOCKER_NETWORK=db-net
TIINGO_DB_HOST_DIR=/home/shin/tiingo/data
TIINGO_DB_CONTAINER_DIR=/data
EOF

sudo install -m 0644 /tmp/tiingojulia-pipeline /etc/default/tiingojulia-pipeline
sudo cp deploy/systemd/tiingojulia-pipeline.service /etc/systemd/system/
sudo cp deploy/systemd/tiingojulia-pipeline.timer /etc/systemd/system/
sudo systemctl daemon-reload

echo "$GHCR_PAT" | docker login ghcr.io -u <github-user> --password-stdin

docker compose -f deploy/compose/docker-compose.pipeline.yml pull pipeline
docker compose -f deploy/compose/docker-compose.pipeline.yml run --rm pipeline

sudo systemctl enable --now tiingojulia-pipeline.timer
systemctl list-timers tiingojulia-pipeline.timer
journalctl -u tiingojulia-pipeline.service -f
```

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
