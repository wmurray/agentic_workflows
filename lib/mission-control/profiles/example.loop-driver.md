# Profile overlay — `/loop` driver (EXAMPLE)

Copy this to **`$MC_HOME/profile.loop-driver.md`** (i.e. `~/.claude/mission-control/`, the
live runtime dir — *not* into this repo) and fill in your org's values.

It lives in the runtime dir on purpose. `local.env` has to sit in the repo because
`dispatch.sh` sources it by relative path and is kept out of git by `.gitignore`; this file
has no such constraint — the driver reads it by absolute path — so keeping it outside the
repo entirely means there is no gitignore rule to get wrong. Runtime data is already the
one thing that never enters git; the overlay joins it.

The engine doctrine is `loop-driver.engine.md`, symlinked to `$MC_HOME/loop-driver.md`.
The driver reads **this file first, then the engine**. Where the two disagree on a status,
repo, key shape, command, or policy window, **this file wins**.

Everything below is required unless marked optional.

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

> The ticket-detail command is the one tracker touch with no adapter op behind it
> (`adapters/CONTRACT.md` covers `list_ready` / `fields_of` / `in_active_cycle` /
> `active_cycle`, none of which return a description). Until a `detail_of` op exists, the
> overlay supplies the raw command.

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

## Colleagues / blocked-on parties (optional)

Names or roles the driver may set as `blocked_on` so the dash files a ticket under
⏳ AWAITING OTHERS rather than ⛔ NEEDS YOU: `product`, `qa`, `design`, or a person's name.
