# Droplet deployment (containerized pipeline)

The TiingoJulia pipeline runs as a **oneshot container** joined to the DB stack's
shared Docker network, scheduled by a systemd timer. The image is built and pushed
to GHCR by CI, so the droplet only pulls (no heavy Julia precompile on the droplet).

Environment tiers (same image, config-only difference):

| Domain | Role | Host | Image tag | Env file |
|--------|------|------|-----------|----------|
| 10kpw.com | preprod | `10kpw-non-prod` | `staging` | `.env.staging` |
| TokusenQuant.com | prod | — | `latest` (or version) | `.env` |

## One-time setup on a droplet

1. **Clone / place the repo** at `/opt/tiingojulia` (or edit `WorkingDirectory` in the
   systemd unit to point at your checkout).

2. **Authenticate to GHCR** so the droplet can pull the (private) image:

   ```bash
   echo "$GHCR_PAT" | docker login ghcr.io -u <github-user> --password-stdin
   ```

   `GHCR_PAT` is a GitHub PAT with `read:packages`. (Or make the GHCR package public,
   then no login is needed.)

3. **Create the env file** at the repo root. The PG host must be the **in-network
   alias on port 5432** (not the host-published `127.0.0.1:5433`):

   ```dotenv
   TIINGO_API_KEY=...
   TIINGO_PG_CONNECTION=postgresql://USER:PASS@postgres:5432/DB?sslmode=disable
   TIINGO_SMOKE_EXPORT_POSTGRES=true
   ```

   Preprod aliases that resolve on `db-net`: `postgres`, `postgres_db`, `pdb`.

4. **Create the host-side systemd env file** so `docker compose` gets the right
   image tag, app env file, and external network:

   ```bash
   sudo install -m 0644 deploy/systemd/tiingojulia-pipeline.env.example /etc/default/tiingojulia-pipeline
   ```

   Then edit `/etc/default/tiingojulia-pipeline`:

   ```dotenv
   TIINGO_IMAGE_TAG=staging
   TIINGO_APP_ENV_FILE=/opt/tiingojulia/.env.staging
   TIINGO_DOCKER_NETWORK=db-net
   ```

5. **Smoke test the container** (verifies the whole path, incl. the PostgreSQL export):

   ```bash
   docker compose -f deploy/compose/docker-compose.pipeline.yml run --rm pipeline
   ```

   Expect `Staging PostgreSQL export completed`.

## Schedule with systemd

```bash
sudo cp deploy/systemd/tiingojulia-pipeline.service /etc/systemd/system/
sudo cp deploy/systemd/tiingojulia-pipeline.timer   /etc/systemd/system/
# edit WorkingDirectory in the .service if not using /opt/tiingojulia
sudo systemctl daemon-reload
sudo systemctl enable --now tiingojulia-pipeline.timer
systemctl list-timers tiingojulia-pipeline.timer   # confirm next run
journalctl -u tiingojulia-pipeline.service -f      # follow run logs
```

## preprod → prod promotion

Same files. On the prod droplet:

- set `TIINGO_IMAGE_TAG=latest`
- set `TIINGO_APP_ENV_FILE=/opt/tiingojulia/.env`
- keep `TIINGO_DOCKER_NETWORK=db-net` unless the prod DB stack exposes a different name

If the prod Docker network differs, change `TIINGO_DOCKER_NETWORK` in
`/etc/default/tiingojulia-pipeline`; the compose file now reads it dynamically.

## Notes / follow-ups

- The scheduled command is currently `scripts/staging_smoke_test.jl` (a real but
  bounded sync + PG export). Control production scope with `TIINGO_SMOKE_*` variables
  in the selected app env file.
- DuckDB runs in ephemeral `/tmp` (the authoritative store is PostgreSQL). If a
  persistent local DuckDB is needed later, add a `/data` volume plus a Dockerfile
  `mkdir -p /data && chown appuser /data`.
