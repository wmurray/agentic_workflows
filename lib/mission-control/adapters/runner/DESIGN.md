# Runner adapter — design note

Status: design agreed 2026-09-08, nothing built. This note is the branch-off point:
the live `~/.claude/mission-control/` config stays untouched until a runner impl exists
and one sprint ticket has gone through it by hand.

## Why

The engine currently has two adapter seams, tracker and host. A third provider-shaped
coupling is unaddressed: **how a worker phase is launched, watched, and harvested.**
Today that is hard-wired to in-process `Agent` spawns with `run_in_background: true`,
completion detected by `idle_notification`, and the result pulled by a `SendMessage`
nudge. `EXTRACTION-SPEC.md` already flags `mc-gitop.sh` as belonging behind a future
"runtime adapter". The runner is that adapter.

The immediate consumer is herdr: coders (and sprint planners) should run as visible
herdr sessions in the matching workspace, per the operator's stated division of labor
(herdr = execution surface, mission-control = admin spine). Making that pluggable rather
than hard-coding it keeps the engine generic and gives the extracted repo a real feature:
the same board can drive in-process subagents, herdr panes, tmux, or `claude -p`
subprocesses by adding one adapter each.

## Scope decisions

- **Design A: the loop is the only manager.** No per-ticket "middle manager" session.
  Each phase is a worker the loop starts, waits on, and harvests. `/execute-plan` as a
  per-ticket manager was considered and rejected for v1: two state machines, gates in two
  places, the coder goes invisible again, context concentrates in the session you can
  least afford to bloat. Phase 2 (below) may revisit.
- **Loop-first.** The runner spawn path is built into `loop-driver` only. The manual
  `/mission-control` session does not grow its own herdr spawn path; in phase 2 it becomes
  a console over the loop and would lose that path anyway.
- **One author session per ticket, reviewers always fresh.** The author session spans
  planner → coder → blocker-address passes, so the coder inherits the planner's reading
  of the codebase. Review runs in a separate, context-free worker every round. Nothing
  here loosens the existing "never bundle review into the coder" rule.
- **Per-role, per-cycle selection lives in the profile**, not the engine.

## Contract (`runner <op> …`)

Dispatch mirrors the other two seams:

```sh
runner() { "$MC_ADAPTERS/runner/${1}.sh" "${@:2}"; }   # impl chosen per call, see selection
```

| Op | Args | Output | Notes |
|---|---|---|---|
| `spawn` | `<role> <ticket> <cwd> <brief-file> <result-file>` | handle (opaque string) | starts or re-prompts the worker; for an existing author session pass its handle via `--reuse <handle>` |
| `status` | `<handle>` | one of `running idle done blocked gone` | replaces the `TaskList` check on board refresh |
| `wait` | `<handle> [timeout-ms]` | exit 0 when not running; nonzero on timeout | the loop runs this in the background |
| `harvest` | `<handle>` | the structured JSON result on stdout | reads `<result-file>`; empty if absent |
| `teardown` | `<handle>` | — | close the pane / release the worker |
| `capabilities` | — | space-separated list, e.g. `reuse visible` | `reuse` = same session can take a second prompt; `visible` = operator can watch/intervene |

**Result file is the canonical return for every runner.** Worker templates end with
"write your final JSON to `{RESULT_PATH}`". This also replaces the current
reaped-worker recovery (grepping subagent transcripts) with a plain file read.

### In-process impl (`inprocess.sh`)

Asymmetric on purpose: the `Agent` tool call is made by the orchestrating model, not a
script. The adapter standardizes the handle, `status` (via the session's teammate list),
`harvest` (result file), and `teardown` (no-op). `spawn` prints the handle the driver
should use and the driver doctrine says "now make the Agent call with this name". The
runner boundary is therefore partly a prompt-level contract in the driver, not purely a
script boundary like tracker and host. Acceptable; documented so nobody expects
`inprocess.sh spawn` to launch anything.

### herdr impl (`herdr.sh`)

Fully scriptable. Sequence established 2026-08 and re-verified against `herdr --help`
on 2026-09-08:

```sh
herdr tab create --workspace <id> --cwd <worktree> --label <role>-<ticket>
herdr agent start <role>-<ticket-lower> --kind claude --pane <pane> -- --name <role>-<ticket-lower> --model <model>
herdr agent prompt <name> "$(cat brief.md)"          # brief from a file to dodge quoting
herdr agent wait <name> [--until idle|done|blocked] [--timeout <ms>]
herdr agent read <name> --lines N                    # pane snapshot, diagnostics only
herdr tab close <tab_id>                             # teardown; not blocked by the permission classifier
```

- Agent names must be lowercase.
- Handle = `<agent-name>|<tab_id>|<pane_id>`.
- Workspace choice: `cycle:sprint` → sprint workspace, `cycle:background` → out-of-cycle
  workspace. Workspace ids come from the profile (`MC_HERDR_WS_SPRINT`, `MC_HERDR_WS_BACKGROUND`).
- `herdr agent prompt` carries no reply address. With the result-file return this no
  longer matters; do not rely on the worker `SendMessage`-ing anyone.
- herdr has no compact/clear verb. Context is managed by keeping one author session per
  ticket and tight per-phase briefs, not by poking `/compact` into a pane.

## Profile config

```sh
export MC_RUNNER_PLANNER_SPRINT="${MC_RUNNER_PLANNER_SPRINT:-herdr}"
export MC_RUNNER_PLANNER_BACKGROUND="${MC_RUNNER_PLANNER_BACKGROUND:-inprocess}"
export MC_RUNNER_CODER="${MC_RUNNER_CODER:-herdr}"
export MC_RUNNER_REVIEWER="${MC_RUNNER_REVIEWER:-inprocess}"
export MC_RUNNER_INVESTIGATOR="${MC_RUNNER_INVESTIGATOR:-inprocess}"
export MC_HERDR_WS_SPRINT="${MC_HERDR_WS_SPRINT:-}"
export MC_HERDR_WS_BACKGROUND="${MC_HERDR_WS_BACKGROUND:-}"
```

Resulting matrix for the local profile:

| cycle | planner | coder | reviewer |
|---|---|---|---|
| sprint | herdr author session | same session (reuse) | fresh, one-shot |
| background | in-process | herdr session started at Gate 1 approval | fresh, one-shot |

Consequence: a background ticket's coder starts cold (plan doc + brief, no planner
context). That is today's behavior, so nothing regresses. Promotion needs no special
handling: on approve, the coder rule for the ticket's current cycle applies.

An all-in-process org sets four lines and never sees a pane.

## Board changes (additive)

One optional field per row:

```json
"runner": { "impl": "herdr", "handle": "coder-dx1924|w11:t3|w11:p7", "result": "/path/result.json" }
```

Rows without it behave exactly as today. `mc-poll` / `mc-orphans` read it for `status`
and the orphan sweep (below). `dash.sh` may render `impl` as a glyph on the row.

## Lifecycle

- **Reuse.** The author session persists from planner through R2 address. `spawn --reuse`
  re-prompts it. A revived ticket (merged then reopened) gets a fresh worktree and a
  fresh session, matching the existing "new worktree off main" rule.
- **Teardown.** When the row reaches Gate 2 with a draft PR open and a review `pass`.
  Also on abandon (`hold` older than `MC_RUNNER_HOLD_TTL`) and on `died-mid-run` once the
  result has been recovered or given up on. The worktree stays for Gate 2 inspection; only
  the session goes.
- **Orphan sweep.** `mc-orphans.sh` gains: any runner session with no board row pointing
  at it, or idle longer than `MC_RUNNER_IDLE_TTL`, is reported and (under the loop's
  internal-write grant) torn down. Observed 2026-09-08: a `sprint` claude agent sitting at
  `done` in a herdr workspace with nothing closing it. That is the case this rule targets.

## Driver changes (loop-driver.engine.md)

Two places, both additive:

1. Every "spawn a X" step becomes "select runner for (role, cycle) → `runner spawn`".
   Prep-write 4 coder-spawn stays behind `CODER_SPAWN_LIVE`; only the mechanism changes.
2. "Worker completion DETECTION" becomes `runner wait` in the background → `runner harvest`.
   The idle-notification/SendMessage paragraph survives only inside `inprocess.sh`'s doc.

The lane machine, gates, Rule A, inbox verbs, and the single-writer rule are untouched.

## Spike findings (2026-09-08, the spike ticket ABC-1234 via the single-ticket workflow in a hand-made pane)

herdr's states are usable, with one rule: **`wait` must be debounced.** Observed:

| edge | herdr reported | trustworthy? |
|---|---|---|
| prompt submitted | `idle` → `working` within 15s | yes |
| session stops at an `AskUserQuestion` | `blocked`, held indefinitely | yes |
| operator answers in the pane | `blocked` → `working` same second | yes |
| session finishes its final turn | `done`, held indefinitely | yes |
| main agent idle for <3s between a subagent returning and its next turn | **`done`** | **no**, transient |
| ~1s before settling to `blocked` | **`done`** | **no**, transient |

`herdr agent wait` with its default match (idle/done/blocked) returns on the transients.
A 3-second poller never saw them; `wait` did twice. So `runner wait` = herdr wait → sleep
a settle window (20s was clean) → re-read `status` → accept only if still non-working,
else loop. With that, `blocked` is a reliable "waiting on a human" signal and `done` a
reliable "finished" signal. No `agent read` heuristics needed.

Second data point, same day: a bare coder brief (a runtime-bump ticket, no
`/execute-plan`) ran start → `done` in 2m27s with a clean `done` at the end and wrote its
result file as instructed. The result-file return works with zero cooperation from herdr.

Also confirmed: `herdr agent prompt` with a multi-KB brief via `"$(cat brief.md)"` works;
`herdr tab create --no-focus` keeps the operator's focus; agent names must be lowercase and
must not contain `.` (used `bump-55-2`).

Gotcha: `herdr agent read` shows Claude Code's ghost-text prompt suggestion on the input
line (e.g. `❯ mark it ready for review` appeared with nothing typed). Never infer operator
intent, or trigger an action, from pane text. Another reason the return channel is the
result file, not the screen.

Gotcha: a coder in a fresh worktree has no `.env` / `node_modules`. Left to itself one
session copied `.env` from the main checkout to get specs running (gitignored, never
committed, but a secrets-adjacent step no agent should take unprompted). The runner's
`spawn` must provision the worktree environment before the first prompt, as part of the
orchestrator's deterministic glue alongside `git worktree add`: copy or symlink the env
file, install deps where cheap, and say in the brief that the environment is ready. A
brief that says "run the specs" without that is an invitation to improvise.

Two more from the same day. (a) The env file is a HUMAN step: the operator copies `.env` into
the worktree (agents never read or copy secrets), so `spawn` for a repo that needs one must
stop and ask before the first prompt rather than provision it itself. (b) A session running
in a shared checkout hit unrelated dirty files and proposed `git stash`; the stash stack is
shared across every worktree and session, so that is never safe under the loop. Worktree per
ticket is a correctness requirement, not tidiness. (c) "Open a draft PR" is not "request a
reviewer"; the Gate-2 ready step must add the reviewer team from the profile
(`MC_REVIEWERS`), or the PR sits unreviewed.

(d) Sessions started with a bare `claude` inherit the user's default model (Sonnet here);
only the `/execute-plan` session ran on Opus. `spawn` must pass `--model` per role from the
profile (`MC_MODEL_PLANNER`, `MC_MODEL_CODER`, `MC_MODEL_REVIEWER`); reviewers get the
stronger tier. (e) One reviewer cd'd from its worktree into the main checkout and read stale
files before catching itself. Every brief states the worktree path and says not to leave it.

## Build order

1. This note. (done)
2. Spike. (done, see findings above)
3. `runner/CONTRACT` section appended to `adapters/CONTRACT.md`; `dispatch.sh` gains `runner()`, `runner_for()`, `runner_of()`. (done 2026-09-09)
4. `runner/inprocess.sh` + `runner/herdr.sh`; templates gain `{RESULT_PATH}`. (done 2026-09-09; herdr impl verified live: spawn→wait→harvest→teardown in 15 s on a trivial brief. Templates live in the skills tree, not this repo — footer appended there.)
5. `profiles/example.env` gains the `MC_RUNNER_*` block; `local.env` filled in. (done 2026-09-09)
6. `loop-driver.engine.md` edits (two places). `mc-poll` / `mc-orphans` read `runner`. Runner assertions added to `test/smoke.sh`. (done 2026-09-09; smoke 70/70; adds `list` op, `MC_RUNNER_DIR`, and a "Runner seam" doctrine block that also carries the settled-prompt rule.) Built on branch `runner-adapter` in a separate worktree (`../agentic_workflows-wt-runner`) so the live loop (which reads the engine doc through a symlink into the main checkout) and the extraction worker's pending engine-doc edits are untouched until merge.
7. One sprint ticket end to end under the loop with `CODER_SPAWN_LIVE` armed. Then unpause
   the loop for real.

## Phase 2 sketch (not in scope here)

Couple the interactive `/mission-control` session to the loop as a **console**: the loop
stays the only `state.json` writer; the interactive session reads an `mc-outbox` the loop
appends at every gate, presents it, relays questions to the author session via
`runner spawn --reuse`, and translates the operator's words into inbox lines. Taking the
reins *is* `hold`; `approve` releases. The interactive session shrinks rather than grows.

## Console capability: answering settled prompts (added 2026-09-09)

herdr sessions block on permission prompts (the runtime's ask-only destructive-git hook, plan approval, etc.). `herdr agent send-keys <name> <key>` answers them. Rule agreed with Will: the orchestrator answers a prompt itself when the right answer is already settled (by profile, plan, or prior decision) and logs what it pressed; it escalates prompts that are undecided, destructive git, secrets, or outward-facing (post/push/merge). Subagents inside the pane may retry the same action, so expect to answer twice and follow up with an `agent prompt` explaining the correct action. Do not weaken the hooks themselves; the adapter owns who answers, not what is asked.

Settled-by-doctrine list (grows as decisions land): the lossless "revert two clean files → run spec → restore HEAD" red-proof pattern (verify the paths have no uncommitted changes first); a heredoc that merely mentions a git command; a scratch-worktree setup inside the worker's own scratchpad; the Gate 2 "push and open a DRAFT PR" offer (draft only: no reviewers, not ready). Never settled: mark ready, request reviewers, merge, anything touching secrets, or a restore whose target has uncommitted changes.

## Gotcha (f): cwd drift into the main checkout (2026-09-09)

The spike pane was started with cwd `~/sd` (the monorepo root) instead of the worktree and did all its work in the sibling main checkout on a fresh branch, leaving the prepared worktree unused and the main checkout occupied. `spawn` must set `--cwd` to the worktree path itself and the brief must state "work only in <worktree>; never cd to the sibling main checkout". `status` should verify `foreground_cwd` is under the worktree and flag drift.

## Gotcha (g): workspace-trust dialog kills a pasted brief (2026-09-09)

A claude started in a cwd this machine has not opened before shows the trust prompt with
"No, exit" preselected. `herdr agent start` reports the agent `blocked` + `interactive_ready`,
and a brief pasted at that moment takes the default and exits the session; the pane returns
to a shell and the agent reads as `gone`. `herdr.sh spawn` now waits for `idle|done` before
prompting and answers only that one dialog (`down enter`), because the cwd is a worktree the
loop cut itself. Any other startup block is reported and left to the operator.
