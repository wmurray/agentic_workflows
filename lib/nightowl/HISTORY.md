# How nightowl's permission profile was fixed after its first night (2026-10-13)

This file records what went wrong on the first unattended nights, what caused each refusal, and the
change that answered it. It is history, not doctrine: `README.md` and `settings.template.json` state the
current profile as fact. Nothing here changes what a pane may do.

## The first night (2026-10-12 into 2026-10-13)

Three panes ran. Every one lost the shell early, and two gave up on Bash for the rest of the night. None
of the refusals came from a missing allow rule for the work itself. Each was reproduced afterwards by
running `claude -p --permission-mode dontAsk` against that pane's own rendered `settings.effective.json`.

### Cause 1: the rtk hook rewrites commands into forms the profile never named

The maintainer's machine has a PreToolUse hook that runs `rtk rewrite`. It turns `cat` into `rtk read`,
`head`/`tail` into `rtk read --max-lines`/`--tail-lines`, `wc` into `rtk wc`, `git X` into `rtk git X`,
`gh X` into `rtk gh X`, `npx tsc` into `rtk tsc`, and `bundle exec rspec` into `rtk rspec`. rtk decides
whether to auto-allow by checking the original command against the user and project settings only, never
the pane's `--settings` file. When it does not auto-allow, Claude Code matches the rewritten `rtk ...`
command against the pane's rules, and the profile had no `rtk` rules. A research pane's
`ls ... && cat ... && wc -l ...` was refused on the `rtk wc` part.

The same rewrite opened a hole in the other direction. `git push` became `rtk git push`, which
`Bash(git push*)` does not match, and rtk could auto-allow it from the user settings.

Changes:

- The template allows the rtk form of each read-only and local-git shape it already allowed (`rtk read`,
  `rtk wc`, `rtk grep`, `rtk git status/diff/log/show/fetch/add/commit/rebase/checkout/switch/restore`,
  `rtk gh pr view/diff/list/checks`, `rtk gh run view/list`, `rtk gh issue view`).
- `render_settings` adds an `rtk` twin of every `Bash(...)` deny rule that does not start with a wildcard.
  Deny beats allow, and it also beats a hook's allow, so `rtk git push` and `rtk gh pr create` are now
  refused. A live probe confirmed both.
- Read-only pipe stages (bare `head`, `tail`, `wc`, `sed -n`, `jq`, `sort`, `uniq`, `cut`, `diff`) moved
  into the template's allow list.
- `npx tsc` and `bundle exec rspec` came from `NIGHTOWL_ALLOW_EXTRA`, so their rtk forms belong there too
  (`Bash(rtk tsc*)`, `Bash(rtk rspec*)`). The README and `example.env` say so; a maintainer's local env
  file is theirs to update.

### Cause 2: shell shapes the permission checker cannot read

- A research pane ran `cd <worktree>; for t in ...; do <tracker read> $t; done`. A `for` loop is refused
  whatever its body is.
- A draft-pr pane ran `N=<path to nightowl.sh> && $N push ... 2>&1 | tail -5 && $N draft-pr ... 2>&1 |
  tail -5`. Every part of that runs alone, and so do two plain ops joined by `&&`, and so does
  `N=... && $N push ...`. The whole compound, with the variable command word expanded twice and each
  part piped, was refused. The same pane later ran the ops as plain single commands and they succeeded.
- `cd` was not the cause. The worktree and the task dir are working dirs, so `cd` into either is allowed
  natively; `cd` anywhere else is refused, which is what we want.

Change: the brief now asks for plain commands, ops written in full one per command, no `$VAR` or `$(...)`
command words, no loops, `cd` only into the worktree or task dir, and a split-and-retry before giving up
on the shell.

### Cause 3: research could not read the tracker

Research briefs asked for ticket context, and the profile had no tracker read. The template now allows
`jira issue view`, `jira issue list` and `acli jira workitem view`. Every tracker write stays denied.

### Cause 4: Write(path) rules do nothing

Claude Code ignores `Write(path)` permission rules; only `Edit(path)` rules govern the file-editing tools.
The template's `Write(...)` rules were removed so nobody reads them as a boundary. The settings files and
the toolkit are protected by the `Edit(...)` denies, which a live probe confirmed refuse a Write to the
task dir's `settings.json`.

### Not the template's fault

- `git restore <path>` in an earlier pane was refused by a destructive-command safety hook from a
  separately installed plugin, not by the profile. That hook suggests `git stash`, which nightowl denies,
  so a pane hitting it should note it and move on.

## Other changes from the same review

- **Report dir.** The default moved from under `~/.claude` to
  `${XDG_STATE_HOME:-$HOME/.local/state}/nightowl`. Claude Code protects that tree, so a
  `dontAsk` pane could not write its `result.json` or review payload there.
- **Id length.** `confirm` refuses an id over 23 characters with exit 3. herdr pane names cap at 32, and
  the pane is `nightowl-<id>`. The README said 40.
- **Leak check on push.** When the worktree has `.mc-leak-guard`, `push` greps the added lines of
  `git diff origin/<base>...HEAD` against the denylist (`NIGHTOWL_LEAK_DENYLIST`, then `MC_DENYLIST`, then
  `~/.claude/mc-leak-denylist.txt`). A hit refuses with the count of matching lines and never prints the
  terms. A missing denylist refuses the push.
- **`drop <id>`.** An orchestrator op that closes the task's pane if one is recorded and removes the task
  from the manifest, leaving its worktree and task dir in place. A pane cannot run it.
- **Library sources.** Bash reads of an installed gem or package were already allowed, but the Read tool
  was not. `NIGHTOWL_LIBRARY_DIRS` (empty by default) grants `Read` and denies `Edit` on each listed dir.
  The dirs are not added as working dirs, so a pane cannot `cd` into them.
