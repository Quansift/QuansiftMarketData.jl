---
type: Reference
title: "Architecture documentation: conventions"
description: Why these pages exist, the Open Knowledge Format page layout they follow, and the rules for changing them.
tags: [documentation, conventions, okf]
sources:
  - id: okf-spec
    resource: https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md
    title: Open Knowledge Format (OKF) v0.2
last_verified: 2026-11-07
---

# Architecture documentation: conventions

How QuansiftMarketData actually works: what it owns, what it persists, what it
promises, and what happens when a promise cannot be kept.

These documents exist because the system's most expensive failures have not
been coding errors. They have been knowledge that lived in one person's head,
in a scheduler in another repository, or in a provider's rate limit nobody had
written down. A defect is found and fixed in an afternoon. An undocumented
constraint costs days, repeatedly, to whoever meets it next.

Start from the [index](index.md); it lists every page with a one-line summary.
Security policy is [`SECURITY.md`](../../SECURITY.md) at the repository root,
where GitHub surfaces it in the repository sidebar. It is not duplicated here.

## Format

This directory is an [Open Knowledge Format](https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md)
(OKF) v0.2 bundle: Markdown files with YAML front matter, no tooling required.
[`index.md`](index.md) and [`log.md`](log.md) are reserved names (the directory
listing and the dated change history); every other `.md` file is a concept page.

```yaml
---
type: Architecture Concept   # REQUIRED. Architecture Concept | Playbook | Reference
title: PostgreSQL migrations
description: One sentence, used by the index and by search snippets.
tags: [postgresql, migrations]
sources:
  - id: migrations-jl
    resource: ../../src/db/migrations.jl
    title: src/db/migrations.jl
  - id: tiingo-terms
    resource: Tiingo plan terms and API documentation   # outside this repository
last_verified: 2026-08-20     # extension key, see below
---
```

`type` says what the page is for, and the three values are not interchangeable:

- **Architecture Concept** explains why the system is shaped the way it is.
  Read to understand, not to act.
- **Playbook** is a procedure with a beginning and an end. Read while doing.
- **Reference** is looked up, not read through.

`sources` is the point of this format. A `resource` that is a path names a file
the page was derived from, so "is this document still true?" has a mechanical
answer: if a listed file changed since `last_verified`, the page is suspect
until someone checks it. A `resource` that is plain text instead of a path
names an authority outside this repository, such as a provider's terms or a
consumer's configuration; it cannot be followed, and the page must say where
the authority actually lives. A page whose claims cannot be traced to a source
does not belong here — it belongs in an issue, a commit message, or a decision
record.

`last_verified` is not an OKF field. OKF's `verified` records who or what
confirmed a page and requires an actor (`human:<id>` or `process:<id>`), which
these pages have never recorded, so no `verified` is claimed. `last_verified`
stays as an extension key, which consumers must preserve. If a person or a
nightly check starts confirming pages, add `verified` with that actor.

Links between pages are relative (`./20-data-model-and-persistence.md`), not
bundle-absolute (`/20-...`): the link-check step in `Lint.yml` runs lychee
without `--root-dir`, so a bundle-root link is not resolved against this
directory.

## Rules for changing these documents

**Derive from the code, not from memory.** Every factual claim should be
checkable against a file named in `sources`. Where a claim comes from
outside this repository — a provider's limit, a scheduler's configuration — say
so explicitly and name where the authority actually lives. Do not launder
external knowledge into a citation of this codebase.

**Say what would make the page wrong.** Each page ends by naming the changes
that would invalidate it. That is what makes `last_verified` more than a date.

**Prefer the specific.** "Migrating a large table is slow" teaches nothing.
"Migration 2 rewrote 20,622,888 rows in 19m49s on a 4-vCPU host, against a
default timeout of 300s that cancelled it" tells the reader what to budget.

**Record the reasoning, not only the rule.** A rule without its reason is
followed until it is inconvenient and then discarded. A rule with its reason
survives contact with someone who believes they know better — including its
author, six months later.
