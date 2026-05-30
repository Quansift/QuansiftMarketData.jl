# Scheduling Approaches for Periodic Batch Jobs: Research Report

**Date:** 2026-05-25
**Context:** Two daily weekday Julia jobs (Tiingo market-data collection + QuantScreener stock screener) on a single host. Currently a custom Julia daemon spawns them as Docker containers. Evaluating migration to direct cron execution.

## Bottom-line recommendation

- **Docker is not necessary** for this case. Julia's `--project` + committed `Manifest.toml` already provide environment reproducibility. Docker adds image build/maintenance, daemon dependency, and container startup overhead without solving a real problem on a single host that already has Julia installed.
- **Cron (done properly) is the industry-accepted standard** for a small number of periodic batch jobs on a single host. Every production best-practices source reviewed confirms this.
- **The main risk of dropping Docker is environment drift** (someone upgrades Julia or runs `Pkg.update()` without testing). Mitigate by pinning the Julia version via `juliaup`, committing `Manifest.toml`, and always using `--project`.
- **Workflow orchestrators (Airflow / Dagster / Prefect) are unjustified** for 2 sequential jobs on one host. They target 10+ interdependent jobs across teams/hosts.
- **systemd timers are not available** here — the deployment discussion includes a macOS (Darwin) host; systemd is Linux-only. (On a Linux prod host they would be a strong option.)

## Dependency handling recommendation

Use a **single wrapper script** triggered by one cron entry. The wrapper runs Job 1 (collect) then Job 2 (screen) sequentially under `set -euo pipefail`. If Job 1 fails, Job 2 is skipped and the success/heartbeat ping never fires, triggering an alert. Simpler and more robust than sentinel files, separate cron entries, or inline `&&` chaining.

## Production cron hardening checklist

1. **Absolute paths** for interpreter and scripts (`/usr/local/bin/julia`, not `julia`).
2. **Explicit env vars** in the crontab header or wrapper: `SHELL`, `PATH`, `HOME`, `JULIA_DEPOT_PATH`.
3. **flock locking** to prevent overlapping runs (macOS: `brew install flock`, or `shlock`).
4. **Timeouts** to kill hung jobs (macOS: `brew install coreutils` for `gtimeout`).
5. **Logging** with stderr redirect (`>> log 2>&1`) and timestamps in the wrapper.
6. **Log rotation** via macOS `newsyslog` or `logrotate`.
7. **Exit-code capture** with `set -euo pipefail`; alert on non-zero exit.
8. **Dead man's switch** via Healthchecks.io (free tier ~20 checks) — catches both job failures AND scheduling failures.
9. **Idempotent writes** (`INSERT ... ON CONFLICT` for PostgreSQL upserts).
10. **Timezone awareness** — `CRON_TZ=America/New_York` or explicit UTC; DST shifts matter for market-hours jobs.
11. **Version-control the crontab** alongside the project in Git.

## Julia-specific considerations

- Always run with `julia --project=/path/to/project script.jl` to activate the locked environment.
- Set `JULIA_DEPOT_PATH` explicitly in the wrapper; cron does not source shell profiles.
- **Startup latency (5–30 s JIT)** is acceptable for a daily job; optimization is nice-to-have, not blocking.
- **PackageCompiler sysimage** cuts startup to ~50–350 ms but locks package versions at build time (rebuild on update) — only worth it if latency genuinely hurts.
- **DaemonMode.jl** (persistent Julia process) eliminates startup (~18 s → ~0.37 s) but is overkill for twice-daily execution.
- After any package update, run the script manually once to warm the precompilation cache.
- **Pin Julia version** via `juliaup` to prevent accidental upgrades.

## Mechanism comparison (summary)

| Mechanism | Strengths | Weaknesses | Typical scale |
|-----------|-----------|------------|---------------|
| **Plain cron** | Mature, universal, zero infra, 1 line/job | No dep mgmt, minimal env, no native logging/locking/alerting/catch-up | 1–10 simple jobs, single host |
| **systemd timers** | journald logging, `After=`/`Requires=`, `Persistent=` catch-up, cgroup limits | 2 files/job, **Linux-only** | low–moderate, Linux host |
| **Docker-based** | Env reproducibility, isolation, multi-host portability | Image build/maintenance, daemon dep, awkward env passing, startup overhead | when host lacks runtime or multi-host |
| **Airflow/Dagster/Prefect** | DAGs, web UI, retries, backfills, SLA/alerting | Heavy infra (DB+web+scheduler+workers), Python-centric, maintenance | 10+ interdependent jobs, teams |

## When containerizing a scheduled job is necessary vs overkill

- **Docker solves:** env reproducibility across hosts, runtime isolation, missing runtime on host, multi-host deployment, CI/CD parity.
- **Docker is unnecessary when:** single host with the runtime installed, no dependency conflicts, no multi-host scaling, and the language has its own env isolation (Julia `--project` + `Manifest.toml`).
- **Assessment:** unnecessary here. Julia project-level isolation already handles reproducibility; Docker adds friction without solving an unsolved problem.

## When to move to an orchestrator

5+ jobs with complex dependency graphs; backfills needed; multiple team members need web-UI visibility; jobs span multiple hosts.

## Recommended architecture (reference)

```
crontab (single entry, Mon-Fri 19:30 local/ET)
  -> flock (prevent overlap)
    -> run_pipeline.sh (set -euo pipefail)
      -> Job 1: julia --project=... collect (Tiingo incremental)
           (fails? script exits non-zero, Job 2 skipped)
      -> Job 2: julia --project=... screen (QuantScreener)
      -> curl hc-ping.com/UUID  (dead man's switch on success)
    -> Logs -> /var/log/quant/pipeline.log (with rotation)
    -> Alerts -> Slack on failure + healthchecks.io on missed run
```

**Main risk of dropping Docker:** environment drift. Mitigation: commit `Manifest.toml`, use `--project`, pin Julia via `juliaup`.

## Sources

- CronBeacon — cron job best practices: https://cronbeacon.dev/guides/cron-job-best-practices
- Cronping — cron production mistakes: https://cronping.com/blog/cron-job-production-mistakes
- DevSuitcase — cron best practices: https://devsuitcase.com/posts/cron-best-practices/
- DEV — silent cron failures: https://dev.to/deadping/5-ways-your-cron-jobs-are-failing-silently-and-how-to-catch-them-2njp
- systemd timers vs cron: https://www.commandinline.com/systemd-timers-vs-cron-guide/ ; https://blog.mikihands.com/en/whitedec/2025/12/12/linux-scheduling-cron-vs-systemd-timer/
- Docker cron jobs: https://oneuptime.com/blog/post/2026-01-06-docker-cron-jobs/view ; https://news.ycombinator.com/item?id=39343903
- Orchestrator comparison: https://engineering.freeagent.com/2025/05/29/decoding-data-orchestration-tools-comparing-prefect-dagster-airflow-and-mage/ ; https://dzone.com/articles/airflow-vs-dagster-vs-prefect-which-scheduler-fits
- Cron job chaining: https://tool.crontap.com/help/cron-job-run-script-after-another-one-finishes
- Julia + crontab: https://discourse.julialang.org/t/running-a-specific-julia-environment-from-a-crontab/58799
- Julia env vars: https://docs.julialang.org/en/v1/manual/environment-variables/
- PackageCompiler sysimages: https://julialang.github.io/PackageCompiler.jl/stable/sysimages.html
- DaemonMode.jl: https://github.com/dmolina/DaemonMode.jl
