---
name: commit-changes
description: Commit staged changes following logical commit organization and message formatting rules. Includes debug artifact scan and test gate before committing.
disable-model-invocation: true
---

# Commit Changes

Commit the currently STAGED changes following the "Rules: Commit Organization and Message Formatting" below.

## Before committing:

- If unstaged changes exist, examine them only to determine whether any are likely required for the same logical intent
  as the staged changes (e.g., missing tests, updated snapshots, related imports, schema changes).
- If such changes are detected, explicitly ask whether to include them.
- Do NOT include unstaged changes without explicit confirmation.
- Scan the STAGED diff for likely debug artifacts. If found, list them and ask what to do.
  - JS/TS: console.log / console.debug / console.warn / console.error, debugger, alert(
  - Ruby/Rails: binding.pry, byebug, debugger, puts, p, pp, ap
- Do NOT modify code or staging unless explicitly requested.

## Then:

- If the staged changes should be split, create a split plan and proceed commit-by-commit.

## Rules: Commit Organization and Message Formatting

### When committing

- Commits MUST be logical: one coherent intent ("one why") per commit.
- If the current change set includes multiple independent concerns, it MUST be split into multiple commits.
- Prefer multiple small commits over one large commit.
- Do NOT include unrelated refactors/formatting/chore changes in the same commit as behavior changes unless strictly required.
- Pure formatting or lint-only changes are allowed only as standalone commits.
- Summary lines MUST start with one of the following verbs: Add, Fix, Refactor, Remove, Update.

### Test gate (do not commit on failure)

- Before committing, run the relevant test command(s) for the repo.
- If tests fail, DO NOT commit. Instead:
  1. report the failing command(s) and key failure output,
  2. propose the minimal fix,
  3. re-run tests, then commit only after they pass.

### Commit message format

- Summary line: imperative mood, ≤ 72 chars, no trailing period.
- If more detail is useful, add:
  - a blank line
  - a bulleted list focused on _why_ / notable behavior changes / edge cases / migration notes.
