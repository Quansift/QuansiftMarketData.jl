---
title: Architecture documentation
type: reference
source_of_truth:
  - docs/architecture/
last_verified: 2026-08-20
---

# Architecture documentation

How QuansiftMarketData actually works: what it owns, what it persists, what it
promises, and what happens when a promise cannot be kept.

These documents exist because the system's most expensive failures have not
been coding errors. They have been knowledge that lived in one person's head,
in a scheduler in another repository, or in a provider's rate limit nobody had
written down. A defect is found and fixed in an afternoon. An undocumented
constraint costs days, repeatedly, to whoever meets it next.

## Which document answers which question

| Question | Document |
| --- | --- |
| Who owns this — this package, or the scheduler? | [10-system-boundary](10-system-boundary.md) |
| What shape is the data, and where does it live? | [20-data-model-and-persistence](20-data-model-and-persistence.md) |
| What does a collector promise its caller? | [30-collection-contracts](30-collection-contracts.md) |
| How does the PostgreSQL schema move forward safely? | [40-postgresql-migrations](40-postgresql-migrations.md) |
| What may the provider refuse, and what may we keep? | [50-provider-and-retention-constraints](50-provider-and-retention-constraints.md) |
| How does code get from a commit to the data plane? | [60-deployment-topology](60-deployment-topology.md) |
| What happens when something goes wrong? | [70-failure-semantics](70-failure-semantics.md) |
| How do I run a migration, a canary, a recovery? | [80-production-operations](80-production-operations.md) |

Security policy is [`SECURITY.md`](../../SECURITY.md) at the repository root,
where GitHub surfaces it in the repository sidebar. It is not duplicated here.

## Page conventions

Every page carries front matter:

```yaml
---
title: PostgreSQL migrations
type: concept          # concept | task | reference
source_of_truth:
  - src/db/migrations.jl
last_verified: 2026-08-20
---
```

`type` says what the page is for, and the three are not interchangeable:

- **concept** explains why the system is shaped the way it is. Read to
  understand, not to act.
- **task** is a procedure with a beginning and an end. Read while doing.
- **reference** is looked up, not read through.

`source_of_truth` is the point of this format. It names the files the page was
derived from, so "is this document still true?" has a mechanical answer: if a
listed file changed since `last_verified`, the page is suspect until someone
checks it. A page whose claims cannot be traced to a file does not belong
here — it belongs in an issue, a commit message, or a decision record.

## Rules for changing these documents

**Derive from the code, not from memory.** Every factual claim should be
checkable against a file named in `source_of_truth`. Where a claim comes from
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
