# Profile overlay (EXAMPLE)

Copy this to **`$MC_HOME/profile.md`** (i.e. `~/.claude/mission-control/`, the live runtime
dir — *not* into this repo) and fill in your org's values.

**One overlay serves both readers**: the `/loop` driver (`loop-driver.engine.md`) and the
manual orchestrator (`skills/mission-control/SKILL.md`). They need the same org facts, so
two files would drift. The driver currently reads it via the path
`$MC_HOME/profile.loop-driver.md` — keep that as a symlink to `profile.md` until the
driver doc is updated to the shared name.

It lives in the runtime dir on purpose. `local.env` has to sit in the repo because
`dispatch.sh` sources it by relative path and is kept out of git by `.gitignore`; this file
has no such constraint — the driver reads it by absolute path — so keeping it outside the
repo entirely means there is no gitignore rule to get wrong. Runtime data is already the
one thing that never enters git; the overlay joins it.

Both engine docs are symlinked into the runtime dir and read **this file first**. Where an
engine doc and this file disagree on a status, repo, key shape, command, or policy window,
**this file wins**.

Sections up to the divider are shared. Everything after it is what the SKILL needs and the
driver does not. Everything is required unless marked optional.

---

## Ticket keys

- **Shape:** `ABC-[0-9]+` (must match `MC_TICKET_KEY_REGEX` in `local.env`).
- **Example of a real key:** `ABC-1234`.

## Status vocabulary

Must agree with `MC_READY_STATUS` / `MC_TERMINAL_DONE` / `MC_STATUS_RANK` in `local.env` —
those drive the scripts, this table tells the *driver* what the names mean.

| Engine term | Your tracker's status |
|---|---|
| ready status (start signal) | `Ready for Dev` |
| in-progress status | `In Progress` |
| review status | `In Review` |
| QA status | `QA` |
| terminal-done statuses | `Done` `Closed` `Released` `Resolved` |

## Repo → coder-template map

| Repo | Coder template | Worktree helper |
|---|---|---|
| `your-org/api` | `coder-rails` | `bin/create-worktree` |
| `your-org/web` | `coder-typescript` | hand-rolled (`git worktree add`) |

- **Branch prefix:** `xy-` (e.g. `xy-ABC-1234`).

## Pipeline wrappers

The engine names roles; these are the commands. All are invoked **BARE** (no pipe, no
compound) so the permission allow-prefix matches.

| Role | Command |
|---|---|
| status-sync wrapper | `~/.claude/lib/pipeline/tracker-status.sh <KEY> <lane>` |
| assign wrapper | `~/.claude/lib/pipeline/assign.sh <KEY> --lane <lane>` |
| qa-transition wrapper | `~/.claude/lib/pipeline/qa-transition.sh` — **manual only, never the loop's** |
| done-transition wrapper | `~/.claude/lib/pipeline/done-transition.sh` — **manual only, never the loop's** |
| ticket-detail command | `<your tracker CLI> issue view <KEY> --plain` |

> The engine reads ticket detail through `tracker detail_of <KEY>`. The raw command is
> still listed because worker briefs receive it as `{TICKET_DETAIL_CMD}` — a worker has no
> `tracker` dispatcher in scope.

## Release-freeze window (optional)

Set `MC_FREEZE_CHECK_PATTERN` in `local.env` to the substring of the CI check name.
Describe the policy here so the driver reports it correctly rather than as a broken build:

- **Check name:** `Release Freeze Warning`
- **Window:** the last two working days of each cycle.
- **Meaning:** intentionally red, so work clears QA before merging. A frozen PR that is
  otherwise approved + green + mergeable is **ready-to-merge, pending the freeze** — never
  "CI failing."

Leave this section out entirely if your org has no freeze concept.

## Notes vault

- **Path:** `~/Documents/notes` (any directory of markdown files; Obsidian is the common case).
- **Plan / triage docs:** `<vault>/Projects/<Project Group>/<KEY> <Title> Plan.md`

## Template fills

The worker templates under `$MC_SKILL_DIR/templates/` name these placeholders; the
orchestrator (loop or manual session) substitutes the values below when it builds a brief.

| Placeholder | Value |
|---|---|
| `{MC_HOME}` | `/home/you/.claude/mission-control` (the runtime dir, absolute) |
| `{BRANCH_PREFIX}` | `xy-` (must match the branch prefix above) |
| `{BASE_REF}` | `origin/main`; per ticket, the `origin/<branch>` it stacks on |
| `{TICKET_DETAIL_CMD}` | the ticket-detail command above |
| `{VAULT_PROJECTS_DIR}` | `<vault>/Projects` |
| `{CATCH_ALL_GROUP}` | `Standalone Tickets` (the catch-all folder below) |
| `{STYLE_GUIDE}` | path to your prose style guide, or `(none)` |

### `{TEST_CONVENTIONS}` per repo (optional)

- `your-org/api`: ` (arrange/act/assert layout, no shared `let`/`before`, real objects over mocks, factories)`
- `your-org/web`: omit — `AGENTS.md` covers it.

### `{WORKTREE_RECIPE}` per Rails repo

The exact block the `coder-rails` template pastes. One per repo that uses it; a repo with
a shared test database MUST isolate it here.

`your-org/api`:
```
cd /path/to/api
git fetch origin && git merge --ff-only {BASE_REF} 2>/dev/null || true
WT=$(bin/create-worktree {BRANCH_PREFIX}{TICKET_SLUG})    # isolates the test DB per worktree
cd "$WT"
[ "{BASE_REF}" = origin/main ] || {MC_HOME}/mc-gitop.sh reset-hard {BASE_REF}   # stacked base
```
Add the helper's caveats (a seed step that needs a sibling service, assets a worktree does
not inherit) as comment lines inside the block.

## Colleagues / blocked-on parties (optional)

Names or roles the driver may set as `blocked_on` so the dash files a ticket under
⏳ AWAITING OTHERS rather than ⛔ NEEDS YOU: `product`, `qa`, `design`, or a person's name.

---

# Additions for the `/mission-control` SKILL

## Tracker instance specifics

Per-instance ids — the main reason this file is unpublishable.

| Thing | Value |
|---|---|
| Release Note field | `customfield_NNNNN` (rich text / ADF; a plain string may be rejected) |
| Testing Notes field | `customfield_NNNNN` |
| Feature Flags field | `customfield_NNNNN` (a labels field, so multi-value is native) |
| Engineering Owner field | `customfield_NNNNN` |
| QA transition id | `NN` (and the fields it requires) |
| Done transition id | `N` (and the fields it requires) |
| Operator account id | `<opaque id>` |
| Operator email | `<you@example.com>` |

## Lane → tracker status map

The authoritative map for your workflow. `jira-status.sh` encodes the same one in code —
keep them in step.

| Lane | Status |
|---|---|
| `refined` | `Ready for Dev` |
| `implement` / `awaiting-review` | `In Progress` |
| `in-review` / `ready-to-merge` | `In Review` |
| `kickback` | no move (already at the right status from either entry path) |
| `alpha-verify` | `In Review` (board-only lane) |
| `qa` | `QA` (via the qa-transition wrapper) |
| `product-review` | `Product Review` |
| `done` | `Done` (via the done-transition wrapper) |

## Default reviewer team

`your-org/your-team`. Note which repos define the `outside current sprint` label, so
`request-review.sh --outside-sprint` knows when it must skip.

## Known CI failure modes (check here before debugging from scratch)

The recurring, repo-specific failures worth pattern-matching rather than debugging. One
entry per failure: how to recognise it, and the exact fix command. Example shape:

- **`<check name>` fail** = <what it means> → `<exact fix command>` (<what the fix does>).
- **A fresh worktree can't boot `<tool>`** until `<gitignored file>` is copied from the
  main checkout: `<command>`.

## Surfaces — which app renders what (for QA test cases)

Only needed when more than one app shares view names. Map the CODE signal to the app, so a
tester is never sent to the wrong surface:

| Code signal | Surface |
|---|---|
| `<namespace / pack / spec prefix>` | `<app>` → `<path to the view>` |

One app? Say so here; naming the path is then enough.

## Worktree helpers

| Repo | Create | Remove |
|---|---|---|
| `your-org/api` | `bin/create-worktree <name>` (isolates the test DB) | `bin/cleanup-worktree <name>` |
| `your-org/web` | `git worktree add -b <branch>` | `git worktree remove` |

Note any caveat (a helper that also seeds a shared dev DB, or needs a sibling service up).

## Vault specifics

- **Catch-all project folder:** `Standalone Tickets` — the fallback when no existing
  project group fits. The loop cannot ask, so it uses this rather than inventing a folder.
- **Shipped log:** `<vault>/Resources/Shipped Log.md`.
  Append format: `- YYYY-MM-DD [KEY](url) — <note>` (prefix internal ones `Internal:`).

## Review bots to ignore

Mirror `MC_REVIEW_BOTS` from `local.env` here for the reader's benefit.
