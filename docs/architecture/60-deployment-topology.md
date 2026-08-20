---
title: Deployment topology
type: concept
source_of_truth:
  - .github/workflows/release-preflight.yml
  - CHANGELOG.md
  - Project.toml
external_authority:
  - quansift_scheduler Project.toml and Manifest.toml
last_verified: 2026-08-20
---

# Deployment topology

How a commit becomes running code on the data plane. This is the least
intuitive part of the system and the one that cost the most time to work out,
because the obvious answer is wrong.

> **The obvious answer is wrong.** `/opt/tiingojulia` is a checkout of this
> repository on the data-plane host. **The pipeline does not use it.** Deploying
> there changes nothing about what runs.

## What actually runs

`quansift_scheduler` declares this package in its own `Project.toml`:

```toml
[sources]
QuansiftMarketData = {rev = "v4.1.0", url = "https://github.com/Quansift/QuansiftMarketData.jl.git"}
```

`Pkg` fetches that revision from GitHub into
`~/.julia/packages/QuansiftMarketData/<hash>/`, and that copy is what the
pipeline loads. The `<hash>` is derived from the source tree and changes
whenever the pinned revision does.

So the chain is:

```
commit on main  →  tag  →  scheduler [sources] rev  →  Pkg cache  →  pipeline
```

`/opt/tiingojulia` appears nowhere in it.

## Shipping a change

1. Merge to `main`.
2. Run the `release-preflight` workflow with the version and the exact `main`
   SHA. It verifies the ref equals `origin/main`, runs the hermetic suite, the
   PostgreSQL 17 integration suite, docs and link checks, a benchmark smoke, and
   an image build, then records a commit status on that SHA.
3. Tag the verified commit and push the tag.
4. Update the scheduler's pin **to the tag**:

   ```bash
   cd /path/to/quansift_scheduler
   julia --project=. -e 'using Pkg; Pkg.add(url="https://github.com/Quansift/QuansiftMarketData.jl.git", rev="v4.1.0")'
   julia --project=. -e 'using QuansiftMarketData; println(pathof(QuansiftMarketData))'
   ```

   The cache hash in that path **must change**. If it does not, the fetch did
   not happen.

5. Commit the scheduler's `Project.toml` **and** `Manifest.toml`, and push.
   Uncommitted, the next clone or reset silently reverts to the previous pin.

`Pkg.update` is a no-op against a pinned revision — a fixed rev has exactly one
allowed version. It must be `Pkg.add` with an explicit `rev`.

## Pin to a tag, not a bare SHA

The scheduler once pinned a bare SHA. Combined with an unreleased version
number, this produced a failure that took hours to diagnose: four different
commits all reported `pkgversion` **4.0.0**, so the version could not
distinguish them.

| Commit | What it was |
| --- | --- |
| `dc7b935` | pinned by the scheduler; pre-fix |
| `ff9f8ae` | `production` tip before a rollback |
| `9138ac0` | `production` tip after promoting the fix |
| `c98e494` | `main`, later tagged `v4.0.0` |

During the incident a fix was merged, promoted to `production`, and deployed to
`/opt/tiingojulia` while the pipeline kept running the old pinned revision —
with no signal that anything was stale, because every candidate called itself
4.0.0.

A tag names one tree, and the scheduler's `Project.toml` shows which. **Pin
tags.**

## Determining what is actually loaded

When a fix appears not to have taken effect, do not reason from what was
deployed. Read what is loaded:

```bash
julia --project=. -e 'using QuansiftMarketData; println(pathof(QuansiftMarketData))'
```

Any stack trace also carries the path of the file that raised. During the
incident, a stack trace pointing into the old cache directory was the evidence
that settled the question after hours of inference.

## Rolling back does not roll back the schema

Reverting the package to an older revision does **not** revert the database.
Migrations are forward-only.

An older build meeting a newer schema fails closed — see
[40-postgresql-migrations](40-postgresql-migrations.md). This was observed: a
rollback to a 3.0.0-era revision left a build expecting schema version 1 against
a database at version 3, which refused to run at all. The rollback also did not
fix the defect it was intended to address, because that build carried the same
one.

**Roll forward.** If a change must be undone, revert it on `main`, tag, and pin
the new tag.

## What would make this page wrong

- The scheduler changing how it declares this dependency.
- The release workflow changing what it verifies or attests.
- `/opt/tiingojulia` becoming load-bearing.
