# Adapter contracts

Every provider-specific touch in the mission-control engine goes through one of two
dispatchers, so no engine script names a provider (`jira`, `gh`) directly:

```sh
tracker() { "$MC_ADAPTERS/tracker/${MC_TRACKER:-jira}.sh" "$@"; }
host()    { "$MC_ADAPTERS/host/${MC_HOST:-github}.sh"     "$@"; }
```

`$1` is the operation; the rest are its args. An adapter is a single script that
`case`-dispatches on `$1`. Ship one impl per provider; v1 = `jira.sh` + `github.sh`.

**Design rules**
- **Read-only.** Adapters never write tracker/host state, never touch `state.json`.
- **No board knowledge.** Adapters know the provider, not the loop. The on-board diff,
  regression ranking, bot/self filtering, and every verdict stay in the engine so they
  port for free to the next provider.
- **Stable output shape.** Flat rows → tab-separated (`tr -s '\t'` to kill `--plain`
  alignment padding). Nested data (PRs, review threads) → JSON on stdout.
- **Degrade, don't fail.** An unsupported optional op exits `0` with empty output; the
  engine already treats empty as "none." A capability an engine step depends on is
  gated via `capabilities` (below), never assumed.

---

## Tracker adapter — `tracker <op> …`

| Op | Args | Output | Consumers |
|---|---|---|---|
| `list_ready` | `<status> <cycle:in\|out\|any> [vetted]` | TSV `key⇥summary`, one per line | mc-inbound (×2 tiers) |
| `fields_of` | `<key…>` (comma- or space-joined) | TSV `key⇥status⇥assignee` | mc-poll, mc-archive |
| `in_active_cycle` | `<key…>` | bare `key` per line — the subset in the active cycle | mc-promote *(optional: `cycles`)* |
| `active_cycle` | — | TSV `id⇥name` of the open cycle (empty if none) | mc-archive *(optional: `cycles`)* |
| `detail_of` | `<key>` | one ticket's full detail (description / AC / issue type / parent) as plain text | ingest (driver + SKILL), worker briefs |
| `capabilities` | — | space-separated feature list, e.g. `cycles vetting` | any gating step |

**`list_ready`** — assigned-to-me tickets at `<status>`, filtered by cycle membership:
`in` = in the active cycle, `out` = not in it, `any` = ignore cycle. Adding `vetted`
also requires the vetting predicate (a story-point / estimate value present — the
adapter owns which field that is via `MC_POINTS_FIELD`). Tiers map cleanly:
- sprint tier → `list_ready "$READY_STATUS" in`
- background tier → `list_ready "$READY_STATUS" out vetted`

On a **cycle-less** provider `in` returns all ready, `out` returns empty — so the
two-tier inbound collapses to one tier with no contract change (consequence A).

**`fields_of`** folds the spec's separate `status_of` + `assignee_of` into one batch
call (both consumers already fetch these together). mc-archive ignores the assignee
column; mc-poll uses all three.

**`in_active_cycle`** returns bare keys. mc-promote currently prints `key — status`;
converting it, it will call `fields_of` on the returned subset for that label (one
extra, cheap call in a rarely-run detector — keeps the op orthogonal).

**`active_cycle`** is the rollover trigger. The archive sidecar marker stores `id⇥name`
(not just id), so archive never needs a historical cycle-id→name lookup — it stamps
`archivedAtSprint` from the *marker's* name and only needs the *current* cycle here.
*(Done — mc-archive converted; the live marker was backfilled with its name at cutover.
A legacy id-only marker is read as id-with-no-name and upgraded on the next commit.)*

**`detail_of`** closes the gap the doctrine split found: ingest needs a ticket's
description, acceptance criteria and issue type (to classify `type`), and no other op
returns them. Output is plain text in the provider CLI's own layout — the engine reads
it and pastes it into a worker brief, it never parses fields out of it, so no shape is
promised beyond "human-readable, one ticket". Worker briefs still carry the raw command
(the overlay's `{TICKET_DETAIL_CMD}`) because a worker has no `tracker` dispatcher in
scope; the engine itself calls the op.

### Optional capabilities (consequence A — reserve the seam now)
`cycles` and `vetting` are **optional**. Both v1 adapters (Jira, Linear) report both,
but callers must already branch on `capabilities` so a cycle-less fast-follow adapter
(`github-projects`, `trello`) drops in without reopening the contract:
- **no `cycles`** → `active_cycle`/`in_active_cycle` return empty; mc-archive archives
  only on `--force` (never auto), mc-inbound is single-tier, mc-promote is a no-op.
- **no `vetting`** → `list_ready … vetted` ignores the flag (returns all ready).

### Profile config (lives in the profile env, NOT the adapter — externalized in step 4)
| Var | Meaning | Consumer |
|---|---|---|
| `MC_READY_STATUS` | the "ready to start" status | mc-inbound |
| `MC_STATUS_RANK` | status → progress-rank table | mc-poll (regression detection) |
| `MC_TERMINAL_DONE` | statuses meaning shipped | mc-archive (pre-sweep guard) |
| `MC_TICKET_KEY_REGEX` | ticket-key shape (`[A-Z]+-[0-9]+`) | mc-orphans, dash |
| `MC_POINTS_FIELD` | the vetting field name | jira.sh `list_ready … vetted` |

---

## Host adapter — `host <op> …`

| Op | Args | Output | Consumers |
|---|---|---|---|
| `list_prs` | `<repo> <state:all\|open> [mine]` | JSON array of PR objects (superset schema) | mc-poll, mc-orphans |
| `review_threads` | `<repo> <num>` | JSON `{reviewDecision, threads[], reviews[]}` | mc-review-check *(optional: `review_threads`)* |
| `whoami` | — | prints identity on success; nonzero + stderr on failure | mc-health |
| `capabilities` | — | space-separated feature list, e.g. `review_threads` | any gating step |

**`list_prs`** returns one superset schema so both consumers `jq` what they need:
`number, title, headRefName, isDraft, author, url, state, reviewDecision, mergeable,
mergedAt, statusCheckRollup, reviewRequests`. `mine` adds an author=me filter
(mc-orphans' default; mc-poll omits it).

**`review_threads`** does the provider's threads+reviews fetch and normalizes to:
```json
{ "reviewDecision": "…",
  "threads": [ {"isResolved":false,"isOutdated":false,"path":"…","line":0,
                "author":"…","body":"…","latest":"<iso>"} ],
  "reviews": [ {"state":"COMMENTED","author":"…","body":"…","submittedAt":"<iso>"} ] }
```
The engine (mc-review-check) does bot/self filtering, the unresolved/outdated cut, the
verdict, and the `review_seen` signature — all host-agnostic. A host without this op
returns `{"reviewDecision":"none","threads":[],"reviews":[]}` (→ CLEAN) and omits
`review_threads` from `capabilities`.

**`whoami`** is the auth/reachability probe. It just makes an auth-gated call: print
identity + exit 0 on success; exit nonzero with the provider's error text on stderr.
mc-health keeps the generic bounded-runner + the auth(401)-vs-unreachable(network)
classification — the adapter only supplies the probe.

### Profile config
| Var | Meaning | Consumer |
|---|---|---|
| `MC_REPOS` | watched repos | mc-poll, mc-orphans |
| `MC_REVIEW_BOTS` | bot logins to ignore | mc-review-check |
| `MC_FREEZE_CHECK_PATTERN` | CI freeze-guard name substring (degrade to "no freeze" if unset) | mc-poll |

---

## Runner adapter — `runner <impl> <op> …`

Where a **worker** (planner, coder, reviewer, investigator) runs. The other two seams
answer "which provider"; this one answers "which process hosts the model that does the
phase". Unlike tracker/host the impl is chosen **per call** by `(role, cycle)`, so the
dispatcher takes the impl name first:

```sh
runner()     { "$MC_ADAPTERS/runner/${1}.sh" "${@:2}"; }
runner_for() { …; }   # <role> <cycle> → impl from MC_RUNNER_<ROLE>_<CYCLE>, then MC_RUNNER_<ROLE>, else inprocess
runner_of()  { …; }   # <handle> → the impl that minted it (for status/wait/harvest/teardown)
```

| Op | Args | Output | Notes |
|---|---|---|---|
| `spawn` | `<role> <ticket> <cwd> <brief-file> <result-file> [--reuse <handle>] [--model <m>]` | handle (opaque) | starts or re-prompts the worker. `cwd` MUST be the ticket's worktree, never the checkout it was cut from |
| `status` | `<handle>` | `running` `idle` `done` `blocked` `gone` | replaces the teammate-list check on board refresh |
| `wait` | `<handle> [timeout-ms]` | exit 0 when settled (not running); 2 on timeout | the loop runs this in the background |
| `harvest` | `<handle>` | the worker's JSON result on stdout; empty if absent | reads `<result-file>` |
| `teardown` | `<handle>` | — | releases the worker (closes the pane / drops the marker) |
| `capabilities` | — | space-separated list | `reuse` (same session takes another prompt) · `visible` (operator can watch/intervene) · `answer` (supports the `answer` op) |
| `answer` *(optional)* | `<handle> <key>…` | — | presses keys at a settled prompt; gated on `answer` in `capabilities` |
| `peek` *(optional)* | `<handle> [lines]` | last lines of the worker's terminal | diagnostics only, never parsed for intent |
| `list` *(optional)* | — | `<name>\t<status>\t<location>` per worker session the impl can see | mc-orphans subtracts the board's handles to find untracked sessions; an impl that cannot enumerate prints nothing |

**Result file is the canonical return for every runner.** Worker templates end with
"write your final JSON to `{RESULT_PATH}`"; `harvest` is a file read. This also replaces
the reaped-worker recovery (grepping subagent transcripts) with a plain `cat`.

**Handle shape** is impl-private, but the second `|`-field is reserved: the literal
`inprocess` for the in-process impl, a pane/tab id otherwise. `runner_of` keys on it.

**`wait` must debounce.** Interactive hosts report transient idle/done between a main
agent's subagent turns. An impl accepts a settled state only after it survives a settle
window (`MC_HERDR_SETTLE_S`, default 20 s). A present, non-empty result file short-circuits.

**In-process is asymmetric by design.** `inprocess.sh spawn` cannot launch anything: the
orchestrating model makes the Agent call. The script names the worker, clears the result
path, drops a spawn marker and prints the handle; the driver doctrine then says "make the
Agent call with this name and brief". `status` is honest via marker+result, not process
liveness. Documented so nobody expects the script to spawn.

**Who answers prompts.** `answer` exists so the orchestrator can press through a prompt
whose correct answer is already settled (profile, plan, or an operator decision). The
adapter never decides that; it only presses. Destructive-git, secrets, and outward-facing
prompts (post/push/merge) are escalated, not answered — see DESIGN.md.

### Profile config
| Var | Meaning | Consumer |
|---|---|---|
| `MC_RUNNER_<ROLE>[_<CYCLE>]` | impl per role, optionally per cycle (`PLANNER_SPRINT`, `PLANNER_BACKGROUND`, `CODER`, `REVIEWER`, `INVESTIGATOR`) | `runner_for` |
| `MC_HERDR_WS_SPRINT` / `MC_HERDR_WS_BACKGROUND` | herdr workspace id per cycle | herdr.sh spawn |
| `MC_HERDR_SETTLE_S` | debounce window for `wait` (default 20) | herdr.sh wait |
| `MC_MODEL_<ROLE>` | model flag per role (e.g. `opus`) | herdr.sh spawn |
| `MC_RUNNER_DIR` | where result files and in-process spawn markers live; relative handle paths resolve here | inprocess.sh, the driver |
| `MC_RUNNER_IDLE_TTL` / `MC_RUNNER_HOLD_TTL` | orphan-sweep thresholds (reserved; the sweep today reports every untracked session) | mc-orphans |

### Board field (additive)
```json
"runner": { "impl": "herdr", "handle": "coder-abc-1234|ws1:t3|ws1:p7|/path/result.json", "result": "/path/result.json" }
```
Rows without it behave as today. `mc-poll` renders a runner-bearing worker as `●<role>@<impl>:<status>` (plus `⚠RUNNER-GONE` when the session is missing); `mc-orphans` lists sessions no row points at.

---

## Decisions & deviations from the boundary-map

The boundary-map enumerated **6 tracker ops** (`list_ready`, `status_of`, `assignee_of`,
`in_active_cycle`, `active_cycle`, `is_vetted`) + **3 host ops**. Drafting the impls
against the live scripts collapsed the tracker side to **4 ops (+ `capabilities`)**. Each
fold is a "call shape the implementation actually needs," not a feature cut.

- **`is_vetted` → the `vetted` flag on `list_ready`.** The boundary-map imagined a
  per-key predicate: list the ready tickets, then ask `is_vetted` for each. But the live
  background tier (`mc-inbound.sh`) never does that — vetting is a single `AND` clause on
  the *same* query that fetches the out-of-cycle ready tickets (`"$POINTS_FIELD" is not
  EMPTY`), filtered server-side. A standalone `is_vetted` would force an N+1 (one list +
  one call per candidate) to re-derive what one query already returns. So it's a flag:
  `list_ready <status> <cycle> [vetted]`. The adapter still *owns how it vets* (JQL clause
  on Jira; a client-side field/checklist check on a provider that can't filter
  server-side), and `vetting` is an optional `capabilities` entry, so a tracker with no
  vetting concept degrades to a no-op flag. The one assumption we take on: vetting is
  expressible inside the ready query (true for Jira + Linear). If a future provider can't,
  it does the filter client-side in the same op — still correct, just not server-cheap.

- **`status_of` + `assignee_of` → one `fields_of`.** Both consumers (mc-poll, mc-archive)
  already fetch these in a single `jira issue list --columns key,status,assignee`; two ops
  would mean two round-trips. mc-archive ignores the assignee column.

- **`list_prs` returns one superset JSON schema** (12 fields) instead of two shapes for
  mc-poll vs. mc-orphans — each consumer `jq`s down. Keeps the host to one list op.

- **`in_active_cycle` returns bare keys** (orthogonal op). mc-promote, which currently
  prints `key — status`, will call `fields_of` on the returned subset for that label —
  one extra cheap call in a rarely-run detector.

- **`active_cycle` + marker-format change.** To avoid a historical cycle-id→name lookup
  op, the mc-archive sidecar marker stores `id⇥name` (not just `id`); archive stamps
  `archivedAtSprint` from the marker's name and only needs the *current* cycle from the
  adapter. The live marker was backfilled with its name when mc-archive converted.

- **Optional-capability seam (consequence A).** `cycles` and `vetting` are optional from
  day one — v1 adapters (Jira, Linear) report both, but callers gate on `capabilities`, so
  a cycle-less fast-follow adapter (`github-projects`, `trello`) drops in with no contract
  change. See the per-op degrade rules above.

---

## The fixture adapters

`tracker/fixture.sh` and `host/fixture.sh` answer every op from flat files instead of a
provider (data shapes are documented at the top of each). They exist for two reasons.

**They are the honesty test.** A second *real* provider is the ideal proof that the
boundary is sufficient, but it needs an account, credentials, and a cycle model to map
onto. The fixture adapter buys most of that proof for nothing: if an engine script needs
anything the contract does not offer, it fails against fixtures. Writing Linear against a
contract already proven sufficient beats discovering the leak mid-integration.

**They are the safe harness.** `profiles/fixture.env` redirects every write target
(`MC_STATE`, `MC_ARCHIVE`, `MC_LOCK`, `MC_CYCLE_MARKER`, the inbox and the sidecar flags)
into the fixture dir, so the write scripts can be driven end-to-end without a single call
reaching the real tracker, host, or board. `test/smoke.sh` stamps the live runtime files
before the run and re-checks them after, so a script that escapes turns the run red.

They also **simulate the cycle-less provider** that consequence A reserves the seam for:
drop `cycles` from the fixture's capabilities file and the degrade branches in mc-archive,
mc-inbound and mc-promote all execute — years before that adapter is written. `smoke.sh`
runs that pass on every invocation.

### What the fixture host settled

The `list_prs` consumers derived `repo`/`number` by parsing the stored PR URL with a
`github.com`-shaped grep. That was left as a known assumption "until a second host exists
to design against" — the fixture host is that second host, and it broke the parse
immediately. `mc-poll` now derives the slug host-agnostically (strip scheme+host, fold
GitLab's `/-/`, drop the `/pull|pulls|merge_requests|pull-requests/N` segment).

Two things fell out of doing it, both worth keeping in mind for the next host:

- **The board's `repo` field is a BARE repo name, no owner.** It looks like the obvious
  generic seam and it is not: preferring it over the URL turns every joined PR into a
  miss. Verified against the live board, where it is also only populated on some rows.
  The URL is the only place the full slug lives.
- **A fixture that is more generous than reality proves nothing.** The first fixture board
  carried a full `owner/repo` slug, which hid the bug above. It now carries a bare name,
  matching the live board.
