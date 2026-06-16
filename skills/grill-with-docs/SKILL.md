---
name: grill-with-docs
description: Grilling session that challenges a feature idea against the project's domain model, sharpens terminology, and updates documentation (CONTEXT.md, ADRs) inline as decisions crystallise. Use when the user wants to stress-test a plan — or a pre-plan idea — against the project's language and documented decisions. Typically runs before feature-planner via /implement.
upstream: Adapted from Matt Pocock's grill-with-docs skill (https://github.com/mattpocock/skills), MIT License.
---

<what-to-do>

Interview the user relentlessly about every aspect of the idea or plan until you reach a shared understanding. Walk down each branch of the design tree, resolving dependencies between decisions one-by-one. For each question, provide your recommended answer.

Ask the questions one at a time, waiting for feedback on each before continuing.

If a question can be answered by exploring the codebase, explore the codebase instead of asking.

When the grill runs before planning (the default in `/implement`), the output you owe is:
- An updated `CONTEXT.md` (or per-pack `CONTEXT.md`s) reflecting any term resolutions
- Any ADRs that genuinely qualify (see "Offer ADRs sparingly" below)
- A short summary the next step (`feature-planner`) can use as input — open questions resolved, terms agreed, scenarios stress-tested

</what-to-do>

<supporting-info>

## Project context

This skill runs against your project's codebase. Conventions differ per project — adapt as needed.

### Org-wide glossary (if it exists)

Before creating or editing any `CONTEXT.md`, check if your project has an org-wide glossary (e.g., `org-glossary.md` or `GLOSSARY.md`). If one exists, read it first.

Rules:
- **Never duplicate** an org-glossary term into a project `CONTEXT.md`. If the user uses one, defer to the org definition.
- A project `CONTEXT.md` only holds **project-local** terms — concepts the org glossary doesn't cover, or that have a project-specific narrowing.
- If a project's usage **conflicts** with the org glossary, surface it. Either the project should adopt the org term, or the org glossary needs an update — don't silently fork.

### Staging vs shipped

CONTEXT.md and ADR files have two possible locations:

- **Staging** (drafts): your notes vault, e.g. `$VAULT/Resources/<Project>/...`
- **Shipped** (committed in repo): `<project>/...` in the repo

**All new writes from this skill go to staging.** Never write directly into the repo — the user promotes mature files manually via `cp` + commit.

**When reading**, check both locations:
- If a file exists in the repo, it is **authoritative** — read it
- Also read the staging copy if one exists (drafts in progress that may extend the shipped version)
- If a term appears in both with different definitions, treat the repo version as the source of truth and flag the staging copy as needing reconciliation

### Per-project structure (paths shown relative; prepend staging or repo root)

| Project type | CONTEXT path | ADR path |
|--------------|--------------|----------|
| Multi-pack (e.g. Packwerk Rails app) | One `CONTEXT.md` per pack at `packs/<pack>/CONTEXT.md`, plus `CONTEXT-MAP.md` at the project root | `docs/adr/` |
| Single context | `CONTEXT.md` at project root | `docs/adr/` |

For **multi-pack** projects:
- Infer which pack the topic belongs to from the files being discussed. If ambiguous, ask.
- The root `CONTEXT-MAP.md` lists packs that have a `CONTEXT.md` and how they relate. Keep it updated when a new pack-level glossary is created.
- Do **not** create a pack `CONTEXT.md` until the first real project-local term needs resolving.

For **single-context** projects:
- Single `CONTEXT.md` at the project root. Don't subdivide unless the project itself grows packs/modules.

### Read-only dependencies

Third-party libraries, shared gems, and external packages in your dependency tree are read-only here — do not create `CONTEXT.md` or ADRs in them.

## Domain awareness

During codebase exploration, also look for existing documentation:

```
<project>/
├── CONTEXT.md              (or CONTEXT-MAP.md + packs/*/CONTEXT.md for multi-pack projects)
├── docs/
│   └── adr/
│       ├── 0001-event-sourced-orders.md
│       └── 0002-postgres-for-write-model.md
└── (project source)
```

Create files lazily — only when you have something to write. If no `CONTEXT.md` exists, create one when the first term is resolved. If no `docs/adr/` exists, create it when the first ADR is needed.

## During the session

### Challenge against the glossary

When the user uses a term that conflicts with the existing language in `CONTEXT.md` (or the org glossary), call it out immediately. "The org glossary defines 'X' as A, but you seem to mean B — which is it?"

### Sharpen fuzzy language

When the user uses vague or overloaded terms, propose a precise canonical term. "You're saying '<term>' — do you mean the <concept-A> record or the <concept-B> session? Those are different things."

### Discuss concrete scenarios

When domain relationships are being discussed, stress-test them with specific scenarios. Invent scenarios that probe edge cases and force the user to be precise about boundaries — especially across pack or service boundaries.

### Cross-reference with code

When the user states how something works, check whether the code agrees. If you find a contradiction, surface it: "The code cancels the entire record, but you just said partial cancellation is possible — which is right?"

### Update CONTEXT.md inline

When a term is resolved, update the appropriate **staged** `CONTEXT.md` right there (in your notes vault staging area). Don't batch these up — capture them as they happen. Use the format in [CONTEXT-FORMAT.md](./CONTEXT-FORMAT.md).

If a shipped version exists in the repo, update the staging copy as a supplement — do not edit the shipped file directly. Note in your handoff summary that the staged copy has extensions ready for review.

`CONTEXT.md` should be totally devoid of implementation details. It is a glossary and nothing else — not a spec, not a scratch pad, not a place for implementation decisions.

### Offer ADRs sparingly

Only offer to create an ADR when all three are true:

1. **Hard to reverse** — the cost of changing your mind later is meaningful
2. **Surprising without context** — a future reader will wonder "why did they do it this way?"
3. **The result of a real trade-off** — there were genuine alternatives and you picked one for specific reasons

If any of the three is missing, skip the ADR. Use the format in [ADR-FORMAT.md](./ADR-FORMAT.md).

## Handoff (when used before /implement's feature-planner)

When grilling is complete, summarise for the next step:
- Terms resolved (and which staged `CONTEXT.md` path they landed in)
- ADRs created (staged paths)
- Files ready for graduation to the repo (if any feel mature enough to ship)
- Open questions still unresolved that the planner needs to flag
- Any scenarios the planner should explicitly cover in `## Test Strategy`

</supporting-info>
