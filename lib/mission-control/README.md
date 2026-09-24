# mission-control

The engine behind the mission-control board: a set of read-only detectors, a single-writer
lock, and a terminal dashboard, all driven off one `state.json`. It runs several tickets
through plan → implement → review → draft-PR concurrently, stopping at two human gates.

This directory holds the **code and config**. The **runtime data** (`state.json`, the
archive, the writer lock, the heartbeat, the inbox, the pause and coder flags) lives in
`~/.claude/mission-control/`, which symlinks the scripts back here. One copy of the code,
so the repo and the running loop cannot diverge; git is the durable backup.

## Layout

```
mc-*.sh              the engine — detectors, the lock, the inbox drain
worklog.sh           append-only per-day work log (JSONL); fed by mc, the drain and the wrappers
../jira-toolkit/     the pipeline wrappers ($MC_PIPELINE): merge, status moves, QA/Done transitions,
                     field writers — org values in its own gitignored jira.env
dash.sh              the renderer (a pure function of state.json)
loop-driver.engine.md  the autonomous driver's doctrine — org-free (see "Doctrine" below)
HISTORY.md           how the loop's write grants were earned, moved out of the driver so a tick never reads it
adapters/
  CONTRACT.md        the two adapter contracts, and the decisions behind them
  mc                 the operator's shell function: inbox verbs (approve/ready/merge…), pause,
                     the coder arm switch, the loop guard, dash/health shortcuts. Source it from
                     your shell rc; every doc's `mc …` refers to it.
  dispatch.sh        sourced by every script: routes `tracker …` / `host …`
  tracker/           jira.sh · fixture.sh
  host/              github.sh · fixture.sh
profiles/
  example.env        starter template — copy to local.env and fill in
  example.profile.md  starter profile OVERLAY for both doctrine docs
  fixture.env        points the engine at the file-backed adapters (committed)
  local.env          your real values (GITIGNORED)
fixtures/example/    a board + tracker + host dataset the whole engine can run against
test/smoke.sh        runs the engine against the fixtures; asserts the live board is untouched
```

## No provider is named in the engine

Every tracker or PR-host call goes through one of two dispatchers, so swapping providers
means writing an adapter, not editing the engine:

```sh
tracker fields_of KEY-1 KEY-2      # → adapters/tracker/$MC_TRACKER.sh
host    list_prs owner/repo all    # → adapters/host/$MC_HOST.sh
```

Five tracker ops and four host ops cover the whole engine. `cycles`, `vetting` and
`review_threads` are **optional capabilities** — a provider without a sprint/cycle concept
degrades deliberately rather than breaking. See `adapters/CONTRACT.md`.

## Running it without a tracker account

```sh
./test/smoke.sh        # the whole engine against fixtures, plus the cycle-less degrade
./test/smoke.sh -v     # ... printing each script's output
```

`profiles/fixture.env` redirects every write target into the fixture directory, so nothing
touches the real board. The smoke test stamps the live runtime files first and re-checks
them at the end, so a script that escapes fails the run.

To drive one script by hand:

```sh
MC_PROFILE=profiles/fixture.env ./mc-poll.sh
```

## Setting it up for your own org

Source `lib/mission-control/mc` from your shell rc (or symlink it into a functions dir your
rc already loads). It reads `MC_INBOX`, `MC_PAUSE_FILE`, `MC_CODER_FILE`, `MC_GUARD_SCRIPT` and
friends, all defaulting to `~/.claude/mission-control/`.

1. `cp profiles/example.env profiles/local.env` and fill it in. Every value is
   `${VAR:-default}`, so an explicit environment variable always wins.
2. Point `MC_TRACKER` / `MC_HOST` at an adapter. Ship one for your provider if it isn't
   there yet — the contract is five ops and four ops.
3. Symlink the scripts into your runtime directory, and keep the runtime data out of git.

`local.env` is gitignored. This repo is public: no org value belongs in a committed file.

## The loop guard: manual-only actions refuse mechanically

The driver is told in prose never to merge or run the field-bearing `qa`/`done`
transitions. Prose is not a boundary, and the harness allow-list cannot be one either:
the loop session reads the same settings as a manual session. `mc-guard.sh` closes that.
A manual-only wrapper calls `mc-guard.sh check <name>` first and exits 4 if the loop holds
the writer lock (`mc-lock.sh`, owner `loop`, heartbeat within TTL). The loop takes that
lock before every write, so the check needs no cooperation from the model.

It is a switch, not a wall: `mc guard off merge` disables it for one wrapper, `mc guard off`
for all (a `LOOP_GUARD_OFF` marker in the runtime dir, one name per line or `*`), `mc guard
on [name…]` re-enables, and `MC_LOOP_GUARD=off` disables it for a single invocation. A
disabled wrapper always prints that it ran unguarded. `mc guard status` shows both the
switch and who holds the lock. Which wrappers are manual-only is the overlay's call; the
engine ships only the check.

The switch is also how an operator grants the loop a wrapper one at a time. The driver's
merge rule reads it: while `mc guard off merge` is set, a queued `mc merge` is executed by
the loop (the wrapper still re-checks every precondition); with the guard on, the loop only
proposes it. The same pattern extends to any other wrapper the operator decides to open.

## The pre-plan critic and Gate-1 auto-approve

Before the loop plans a ticket it spawns a read-only critic (`templates/pre-plan-critic.md`,
agent `pre-plan-critic`) that hunts for what makes the ticket un-plannable, resolves the mild
ambiguities from the overlay's `{CONTEXT_DOCS}` and returns `ready` or `needs-grill`. `ready`
grounds the planner with the critic's summary; `needs-grill` parks the ticket for the
operator with the questions and recommended answers. A plan that then has zero open
questions, a `ready` verdict and sits inside the profile's fences (`MC_GATE1_CYCLES`,
`MC_GATE1_TYPES`, `MC_GATE1_MAX_POINTS`, `MC_GATE1_PATH_DENY`) is approved by the loop
itself when `GATE1_AUTO` is present (`mc gate1 auto`). Without the file the loop only logs
"would auto-approve", which is the soak to compare against real approvals before arming.
Gate 2 and merge are unchanged.

## Kickback address

After the loop triages new review comments on an open PR it can, when `KICKBACK_AUTO` is
present (`mc address on`), run a coder address round for the mechanical and clear items, push to
the PR branch, and draft each reply as a private pending review comment the operator publishes.
Judgment items, publishing, resolving threads and marking ready stay the operator's. Without the
file the loop only logs "would address N/M", the soak that earns the switch.

## The work log

`worklog.sh` keeps one JSONL file per day (default `~/.claude/worklog/`). The `mc` verbs log
the operator's decisions, `mc-inbox-drain.sh` logs what the orchestrator acted on, and a
manual-only wrapper logs each outward transition it completes. Interactive sessions append a
line at natural checkpoints. Journal tooling reads it back with `worklog.sh show --days N
--json`; that is how a day's work that left no commit, PR or tracker edit still gets recorded.
`MC_WORKLOG=off` silences writes; `MC_WORKLOG_DIR` relocates the files.

## Doctrine: engine + overlay, read at runtime

Two agents read prose rather than config — the autonomous `/loop` driver and the manual
`/mission-control` orchestrator. Both split the same way the scripts do:

```
lib/mission-control/loop-driver.engine.md   the loop's doctrine   — public, org-free
skills/mission-control/SKILL.md             the manual playbook   — public, org-free
~/.claude/mission-control/
  loop-driver.md          -> symlink to loop-driver.engine.md
  profile.md                                the org half — never committed
  profile.loop-driver.md  -> symlink to profile.md
~/.claude/skills/mission-control/
  SKILL.md                -> symlink to skills/mission-control/SKILL.md
```

**One overlay serves both.** They need the same org facts — statuses, repos, wrapper
commands, vault paths — so two overlay files would drift, which is exactly what the
one-copy-of-the-code model exists to prevent. The SKILL's extra needs (tracker field ids,
CI recipes, the surfaces map) are additional sections in the same file.

Each engine doc reads the **overlay first, then itself**. There is no build step: the
overlay wins wherever the two name a status, repo, ticket-key shape, wrapper command, or
policy window, exactly as `local.env` wins over `example.env` at runtime.

The engine halves name *roles* ("the status-sync wrapper", "the ticket-detail command") and
use placeholder keys (`ABC-1234`); the overlay binds each role to a real command. A missing
overlay is a hard stop, not a degrade — an agent guessing its own status vocabulary is how a
wrong outward write happens.

Start from `profiles/example.profile.md`, and put your copy in the **runtime** dir rather
than here. It is the one config file with no reason to live in the repo at all: both docs
read it by absolute path, so there is no gitignore rule to get wrong.

The five worker-phase briefs the SKILL spawns live in `skills/mission-control/templates/`
and follow the same split: each names its org-valued placeholders (`{MC_HOME}`,
`{BRANCH_PREFIX}`, `{BASE_REF}`, `{WORKTREE_RECIPE}`, `{TICKET_DETAIL_CMD}`,
`{VAULT_PROJECTS_DIR}`, `{CATCH_ALL_GROUP}`, `{STYLE_GUIDE}`,
`{TEST_CONVENTIONS}`) and the overlay's **Template fills** section binds them. The runtime
dir symlinks each template into the repo, as it does the scripts.
