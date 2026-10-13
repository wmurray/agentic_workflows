# nightowl

The mechanical half of `/nightowl` (`skills/nightowl/SKILL.md`). At the end of the day the
skill proposes long-running tasks and the maintainer confirms a list. `nightowl.sh` then
gives each confirmed task its own git worktree, its own permission profile and its own
background pane. In the morning it gathers what each task did.

```
nightowl.sh confirm tasks.json      # validate the confirmed list into tonight's manifest
nightowl.sh launch                  # worktree + settings.json + brief.md + pane per task
nightowl.sh morning [--teardown]    # reconcile panes, finish late results, print a table
nightowl.sh status                  # read-only table
nightowl.sh drop <id>               # remove a task from the manifest, closing its pane if any
```

The header of `nightowl.sh` lists every op, flag and exit code.

## Task list

`confirm` takes a JSON array. One object per task:

| field | required | meaning |
|---|---|---|
| `id` | yes | short slug, lowercase letters, digits and dashes, up to 23 chars (the pane is named `nightowl-<id>` and agent names stop at 32) |
| `kind` | yes | `plan`, `repro`, `draft-pr`, `review`, `flake` or `research` |
| `title` | yes | one line, used in the report and PR title suggestion |
| `brief` | yes | what the task should do, in full; the pane sees nothing else |
| `repo` | yes | path to a git checkout the worktree is cut from |
| `worktree` | no | defaults to `<repo>-nightowl-<id>`; never the checkout itself |
| `branch` | when `push` | must start with one of `NIGHTOWL_BRANCH_PREFIXES` |
| `base` | no | base ref for a new branch |
| `push` | no | `true` lets a `draft-pr` or `flake` task push its branch |
| `pr` | review | `owner/repo#N`, the PR the pending review goes on |
| `ticket` | no | carried into the report and the work log line |

Non-push tasks run on a detached worktree, so there is nothing for them to push.

## What a pane may do

The profile is `settings.template.json`, filled per task by `nightowl.sh settings`.

- **No OS sandbox.** Isolation is the worktree plus the permission rules.
- **Allowed without a prompt:** read and edit inside the task's worktree and task dir,
  read-only git and gh commands, read-only pipe stages (`head`, `tail`, `wc`, `sed -n`,
  `jq`, `sort`, `uniq`, `cut`, `diff`), local commits, and `NIGHTOWL_ALLOW_EXTRA` (test
  runners). The same read shapes are allowed in their `rtk` form, for machines whose rtk
  PreToolUse hook rewrites `cat` to `rtk read` or `git log` to `rtk git log`. The hook does
  not see the pane's `--settings`, so a rewritten command is matched against these rules.
  Add the rtk form of anything in `NIGHTOWL_ALLOW_EXTRA` that rtk rewrites
  (`npx tsc` becomes `rtk tsc`, `bundle exec rspec` becomes `rtk rspec`).
  Research tasks also get web search and fetch, and writes to `NIGHTOWL_NOTES_DIR` when it
  is set, plus any rules in `NIGHTOWL_RESEARCH_ALLOW` (a docs tool, say).
- **Denied, always:** `op`, `sentry-cli`, `kubectl`, `aws`, ssh, everything in
  `NIGHTOWL_DENY_EXTRA` and `NIGHTOWL_DENY_DEPLOY`, every PR merge path, `gh pr ready`,
  direct `git push` and `gh pr create`, `gh api` writes, tracker status moves, comments and
  edits, the mission-control `mc` CLI, and reads of credential files. Every `Bash(...)` deny
  rule also gets an `rtk` twin (`Bash(rtk git push*)`), because the rtk hook can auto-allow a
  rewritten command and only a deny on the rewritten form stops it. Deny wins over allow in
  every settings source, and over a hook's allow, so neither can reopen these.
- **Outward writes go through guarded ops:** `push` (the task's own prefixed branch, no
  force, and leak-checked in a repo that carries `.mc-leak-guard`; see below), `draft-pr` (DRAFT only, one per task), `pending-review` (a PENDING review, refused
  if the payload carries an `event`). `draft-pr` tasks may also call the review-toolkit
  `review-reply.sh`, and `review` tasks `review-post.sh`; both keep their own allowlists and
  kill switch.
- A pane carries `NIGHTOWL_TASK`. Orchestrator ops exit 5 inside it, and task ops act only
  for that id.

A pane cannot read the maintainer's leak denylist, so a brief cannot ask it to grep for
leaks before pushing. `push` does it instead: in a worktree with `.mc-leak-guard` at its
root, the op reads the denylist (`NIGHTOWL_LEAK_DENYLIST`, else `MC_DENYLIST`, else
`$HOME/.claude/mc-leak-denylist.txt`; blank and `#` lines skipped, one case-insensitive
extended regex per line), checks the added lines of `git diff origin/<base>...HEAD`, and
refuses the push with exit 4 on a hit. It prints how many lines matched, never the terms. A
missing denylist also refuses.

With `dontAsk` mode anything outside the allow list is refused rather than left waiting on
a prompt, and the brief tells the task to note a refusal in its result and carry on.

## Files

```
$NIGHTOWL_REPORT_DIR/<date>.manifest.json   tasks, handles, status (locked, atomic writes)
$NIGHTOWL_REPORT_DIR/<date>.md              the report: one section per finished task
$NIGHTOWL_REPORT_DIR/<date>/<id>/           settings.json, brief.md, result.json
```

`NIGHTOWL_REPORT_DIR` defaults to `${XDG_STATE_HOME:-$HOME/.local/state}/nightowl`. Keep it
out of `~/.claude`: Claude Code protects that tree, so a `dontAsk` pane cannot write its
`result.json` or a review payload there.

Each finished task also appends one line to the work log (`worklog.sh --source nightowl`).
Nothing here writes the mission-control board; its loop picks the work up from the work log
and the PR host on its next tick.

## Config

Copy `example.env` to `nightowl.env` (gitignored) or point `NIGHTOWL_ENV` at a copy. The
environment wins over the file. Every variable has a generic default.

## Tests

`test/lint.sh` runs the whole flow against a stub runner, a stub `gh` and a throwaway git
repo with a local bare origin. No network, no herdr. The jira-toolkit lint chains it as a
sibling suite.
