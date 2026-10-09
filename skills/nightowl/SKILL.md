---
name: nightowl
description: End-of-day handoff of long-running tasks to background panes. /nightowl proposes candidates from the mission-control board and the backlog (plans to the first gate, bug repros, draft PRs to the second gate, review preloads, flake fixes, research drafts); the maintainer confirms the list and each confirmed task launches in its own worktree and herdr pane with a per-pane permission profile. /nightowl morning summarizes what each task did. Nothing launches unconfirmed; panes never merge, mark ready, move tickets or touch production.
---

# Nightowl

Turns the hours after the maintainer logs off into finished preparation work. The skill is
the judgement half: it picks candidates and writes briefs. `lib/nightowl/nightowl.sh` is
the mechanical half: worktrees, permission profiles, panes, the manifest and the report.
Read `lib/nightowl/README.md` for the task-list schema and the full permission profile.

`$ARGUMENTS`: empty for the evening flow, `morning` for the morning flow. Anything else is
passed through to `nightowl.sh` as flags (for example `--date 2026-01-31`).

Below, `NO` is the absolute path to `lib/nightowl/nightowl.sh` in this repo.

## The permission stance

Say this to the maintainer, in a sentence or two, before asking them to confirm a list.

- **One isolated worktree per task.** A task works in its own linked worktree, cut fresh
  from the repo. It cannot touch other work in progress: edits outside its worktree and task
  dir are not allowed, and the mission-control home, this toolkit and the report files are
  denied outright.
- **No OS sandbox, so the rules are the boundary.** Each pane runs Claude Code with its own
  `--settings` file. Deny rules win over allow rules in every settings source.
- **No production, no secrets.** The password-manager CLI, the error-tracker CLI, cloud and
  cluster CLIs, deploy CLIs, metrics and APM calls (`NIGHTOWL_DENY_EXTRA`), ssh and
  credential files are denied.
- **No gate is crossed.** Merge, `gh pr ready` and every tracker write (status moves,
  comments, edits) are denied. The only outward writes are the task pushing its own
  prefixed branch, opening one DRAFT PR, preloading a PENDING (private) review, and the
  review-toolkit wrappers, whose own allowlists and kill switch still apply.
- **Never someone else's branch.** A push must be to a branch under
  `NIGHTOWL_BRANCH_PREFIXES`. Review tasks on other people's PRs are suggest-only: they can
  preload a pending review the maintainer reads, edits and submits, and nothing else.
- **Unattended means `dontAsk`.** Anything not allowed is refused rather than waiting on a
  prompt. The brief tells the task to record a refusal and carry on.

## Evening: `/nightowl`

### 1. Gather candidates (read-only)

Read the mission-control overlay `$MC_HOME/profile.md` first for repo paths, ticket keys and
worktree helpers. Then look, without writing anything:

- **The board.** `jq` over `$MC_HOME/state.json`. Never write it; nightowl never takes the
  board lock. Tickets waiting to be planned are plan candidates; tickets with an approved
  plan and no PR are draft-PR candidates.
- **The tracker backlog.** Bugs with no repro are repro candidates. Use the tracker adapter
  or the overlay's read commands only.
- **The PR host.** The maintainer's own drafts (`list_prs <repo> open mine` through the host
  adapter) that need more work; PRs waiting on the maintainer's review (`/review-radar`) are
  review candidates.
- **CI.** Specs that failed and passed on retry in recent runs are flake candidates.
- **Open questions** the maintainer mentioned today are research candidates.

### 2. Propose

Show at most `NIGHTOWL_MAX_TASKS` (default 4) candidates, best first, as a numbered list:
kind, one-line title, the repo, and what "done" looks like by morning. Say which ones
would push a branch or open a draft PR. Then state the permission stance above.

Kinds and what each may produce:

| kind | produces | outward write |
|---|---|---|
| `plan` | a plan in the report, ready for the plan gate | none |
| `repro` | a confirmed repro and suspected cause | none |
| `draft-pr` | commits on a prefixed branch, a DRAFT PR | push own branch, draft PR |
| `flake` | a fix for one flaky spec, a DRAFT PR | push own branch, draft PR |
| `review` | a PENDING review for the maintainer to edit and submit | pending review only |
| `research` | findings in the report (and `NIGHTOWL_NOTES_DIR` if set) | none |

### 3. Confirm

**Nothing launches until the maintainer says which tasks to run.** Accept edits to the
list (drop one, change a brief, turn push off). Silence or "looks fine?" is not consent;
ask again for an explicit yes.

### 4. Write the task list and launch

Write a briefs file to a scratch path, one object per confirmed task, following the schema
in `lib/nightowl/README.md`. A brief is the whole of what the pane knows: name the ticket,
the files or PR to start from, the plan if there is one, the test command, and what to put
in the result. Do not paste secrets or production URLs into a brief.

```bash
"$NO" confirm /path/to/tasks.json
"$NO" launch
```

`confirm` exits 3 with a reason on an invalid task (an unprefixed push branch, a review
without `owner/repo#N`, a worktree that is the main checkout). Fix the list and rerun.
`launch` prints one line per task; a `launch-failed` task stays in the manifest for a
retry with `"$NO" launch <id>`.

Finish by telling the maintainer where the report will be (`"$NO" path`) and that
`/nightowl morning` gathers it.

## Morning: `/nightowl morning`

```bash
"$NO" morning --json
```

This finishes any task that wrote a result but did not call `finish`, marks a pane that
went away without a result as `stalled`, and prints the tasks. A stalled task stays open:
if the maintainer nudges its pane and it writes a result later, the next `morning` run
records it.

Summarize for the maintainer, one short paragraph per task: what it did, the draft PR or
pending review it left, what is blocked and on whom, and the next human step (approve the
plan, read the repro, mark the draft ready, edit and submit the review). Link to the report
file for detail. Then offer `"$NO" morning --teardown` to close the panes of finished tasks.

The mission-control loop does the board and tracker admin from the work log and the PR host
on its next tick. Do not move tickets or edit the board from here.

## Rules

- Nightowl writes its report and manifest under `NIGHTOWL_REPORT_DIR` and nothing else.
  No notes beyond the report; research notes only under `NIGHTOWL_NOTES_DIR`, only when set.
- Never edit a pane's `settings.json` to unblock it. A denied action is the design working.
- Never run task ops (`push`, `draft-pr`, `pending-review`, `finish`) from the orchestrator
  on a task's behalf.
