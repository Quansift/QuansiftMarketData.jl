# Server deployment (containerized pipeline)

The TiingoJulia pipeline runs as a **oneshot container** joined to your DB stack's
shared Docker network, scheduled by a systemd timer. The image is built and pushed
to GHCR by CI, so the deployment host only pulls (no heavy Julia precompile on the host).

Environment tiers (same image, config-only difference):

| Role | Image tag | Env file |
|------|-----------|----------|
| preprod | `staging` | `.env.staging` |
| prod | `latest` (or version) | `.env` |

## One-time setup on a host

1. **Clone / place the repo** at a deployment directory of your choice (referred to
   below as `<deploy-dir>`), and set `WorkingDirectory` in the systemd unit to match.

2. **Authenticate to GHCR** so the host can pull the (private) image:

   ```bash
   echo "$GHCR_PAT" | docker login ghcr.io -u <github-user> --password-stdin
   ```

   `GHCR_PAT` is a GitHub PAT with `read:packages`. (Or make the GHCR package public,
   then no login is needed.)

3. **Create the env file** at the repo root. The PG host must be the **in-network
   alias on port 5432** (not a port published on the host loopback):

   ```dotenv
   TIINGO_API_KEY=...
   OHLCV_PG_CONNECTION=postgresql://USER:PASS@postgres:5432/DB?sslmode=disable
   TIINGO_SMOKE_EXPORT_POSTGRES=true
   ```

   Use whatever alias your PostgreSQL container exposes on the shared Docker
   network (commonly `postgres`).

4. **Create the host-side systemd env file** so `docker compose` gets the right
   image tag, app env file, and external network:

   ```bash
   sudo install -m 0644 deploy/systemd/tiingojulia-pipeline.env.example /etc/default/tiingojulia-pipeline
   ```

   Then edit `/etc/default/tiingojulia-pipeline`:

   ```dotenv
   TIINGO_IMAGE_REPO=ghcr.io/quansift/tiingojulia
   TIINGO_IMAGE_TAG=staging
   TIINGO_APP_ENV_FILE=<deploy-dir>/.env.staging
   TIINGO_DOCKER_NETWORK=<db-network>
   TIINGO_DB_HOST_DIR=<db-host-dir>
   TIINGO_DB_CONTAINER_DIR=/data
   ```

5. **Smoke test the container** (verifies the whole path, incl. the PostgreSQL export):

   ```bash
   docker compose -f deploy/compose/docker-compose.pipeline.yml run --rm pipeline
   ```

   Expect `Staging PostgreSQL export completed`.

   For a bounded one-off smoke run, pass overrides with `run -e`:

   ```bash
   docker compose -f deploy/compose/docker-compose.pipeline.yml run --rm \
     -e TIINGO_SMOKE_TICKER_LIMIT=100 \
     -e TIINGO_SMOKE_EXPORT_POSTGRES=false \
     pipeline
   ```

   Do not use `TIINGO_SMOKE_TICKER_LIMIT=100 docker compose ...` for this.
   Prefix env vars only affect Compose interpolation and do not override values
   loaded into the container from `TIINGO_APP_ENV_FILE`.

## Schedule with systemd

```bash
sudo cp deploy/systemd/tiingojulia-pipeline.service /etc/systemd/system/
sudo cp deploy/systemd/tiingojulia-pipeline.timer   /etc/systemd/system/
# edit WorkingDirectory in the .service to point at your deployment directory
sudo systemctl daemon-reload
sudo systemctl enable --now tiingojulia-pipeline.timer
systemctl list-timers tiingojulia-pipeline.timer   # confirm next run
journalctl -u tiingojulia-pipeline.service -f      # follow run logs
```

## preprod → prod promotion

Same files. On the prod host:

- set `TIINGO_IMAGE_TAG=latest`
- set `TIINGO_IMAGE_REPO=ghcr.io/quansift/tiingojulia`
- set `TIINGO_APP_ENV_FILE=<deploy-dir>/.env`
- set `TIINGO_DOCKER_NETWORK` to the external Docker network name your prod DB stack exposes
- set `TIINGO_DB_HOST_DIR` to the host directory that already contains `tiingo_historical_data.duckdb`
- keep `TIINGO_DB_CONTAINER_DIR=/data`

If the prod Docker network differs, change `TIINGO_DOCKER_NETWORK` in
`/etc/default/tiingojulia-pipeline`; the compose file now reads it dynamically.

## Notes / follow-ups

- The scheduled command is currently `scripts/staging_smoke_test.jl` (a real but
  bounded sync + PG export). Control production scope with `TIINGO_SMOKE_*` variables
  in the selected app env file.
- `OHLCV_DUCKDB_PATH` (or legacy `TIINGO_DB_PATH`) is the DuckDB file location and now comes directly from the
  selected app env file. `TIINGO_DUCKDB_TMP` is separate and only controls DuckDB
  scratch space. The compose file pins scratch space and downloaded ticker temp
  files to `/tmp` inside the container.
- On 3GB-class hosts, set `TIINGO_DUCKDB_MEMORY_LIMIT_GB=1`,
  `TIINGO_DUCKDB_THREADS=1`, `TIINGO_DUCKDB_WORKER_THREADS=1`,
  `TIINGO_DUCKDB_PRESERVE_INSERTION_ORDER=false`, and
  `TIINGO_DUCKDB_UPSERT_CHUNK_SIZE=500` in the app env file.
- The compose file bind-mounts `TIINGO_DB_HOST_DIR` into `TIINGO_DB_CONTAINER_DIR`.
  Set `OHLCV_DUCKDB_PATH` in the app env file to a path under that mounted container
  directory, such as `/data/tiingo_historical_data.duckdb`.
- If a persistent local DuckDB file is needed later, add a container volume for the
  chosen `OHLCV_DUCKDB_PATH` location plus a writable directory owned by `appuser`.
