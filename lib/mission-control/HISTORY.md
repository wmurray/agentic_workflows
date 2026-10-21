# How the loop's grants were earned (moved from the driver 2026-09-24)

This section lived at the end of `loop-driver.engine.md` until the audit of 2026-09-24. It records the order
in which the loop earned each write and the reasoning behind that order. It is history, not doctrine: the
driver now states the current grants as facts in "What you may write (current grants)". Nothing here
changes what the loop may do.

## Step 3 — coder-spawn BUILT (flag-gated 2026-07-09) + the outward ladder

You now hold FIVE internal writes (ingest → plan-review; review-triage prep → kickback; board
reconcile → mirror reality; cycle archive → trim the board on rollover; `note`/`hold` inbox drain →
apply board annotations) **PLUS TWO earned OUTWARD writes — tracker status SYNC** (the **status-sync wrapper**,
mirroring a board lane onto the tracker) **and assignee-fix** (the **assign wrapper**, claiming an UNASSIGNED our-turn
ticket for the operator) **PLUS the flag-gated coder-spawn** (Prep-write 4 — OFF by default behind
`CODER_SPAWN_LIVE` / `mc coder on`). The remaining ungranted OUTWARD writes (the tracker **field** writes,
`gh pr ready`/request-review/comment/resolve, `qa`/`done` transitions, pushing an approved review fix,
>1 concurrent coder) stay gated, and **merge stays human-AUTHORIZED** (`mc merge` only). The order
writes get earned, safest first — the dividing line is **internal (earned) vs outward (mostly gated):**
**ingest (✅) → review-triage prep (✅) → board-internal reconcile (✅) → cycle-archive `--commit` (✅,
audit pending) → board-only inbox drains `note`/`hold` (✅) → OUTWARD tracker status-sync (✅ GRANTED
2026-07-01) → OUTWARD assignee-fix (✅ GRANTED 2026-07-09, unassigned-only, `assign.sh`) → coder-spawn
at Gate-1 approval (✅ BUILT 2026-07-09, flag-gated `CODER_SPAWN_LIVE`, ≤1 coder in flight).** Each
waited for the prior to soak clean. **Coder-spawn inherits the SKILL's mandatory bounded review** —
coder → reviewer R1 (→ address → R2) → draft PR, capped at two automated rounds with an empty-address-diff
killswitch and a round-2 human gate (see SKILL "Review (implement lane)" + Prep-write 4). The loop NEVER
opens a PR on an un-reviewed or blocker-carrying diff, and NEVER auto-loops implement↔review past round 2.
(The five internal grants — board + notes-vault artifacts + a two-verb inbox drain — are reversible and no
one else sees a bug, which is why they were earned first. Archive is internal despite the "outward"
ladder position: sequenced here because it's destructive-ish (trims the live board), not because it
crosses the wall. Status-sync is the first write that crosses the wall, earned because it only *reflects*
a human-decided board lane onto the tracker. Assignee-fix crosses next: unassigned-only + our-turn-lane guard
in the **assign wrapper** keep it reversible + colleague-silent; a **colleague**-held ticket stays a FLAG.)
**Coder-spawn is the threshold rung** — the loop's first CODE write — so it is **flag-gated + supervised-
first**: build shipped OFF; the operator arms it (`mc coder on`) and watches one full Gate-1→coder→review→draft-PR
cycle before trusting it unattended; `mc coder off` reverts to propose-only next tick. It's bounded by a
Gate-1-approved plan (the operator's decision), the mandatory review, the ≤1-coder cap, and Gate 2 (nothing
readies or merges without an operator-queued `mc ready` / `mc merge`). **Still FLAG-only after this rung** (ungranted): the tracker **field** writes,
all `gh` outward except the queued-`ready` drain and a queued `merge` while `mc guard off merge` is set
(comment/resolve stay flag-only), `qa`/`done` transitions, pushing an approved
review fix, and >1 concurrent coder. **Next: soak assignee-fix + the supervised coder-spawn arm clean,
then consider widening the coder cap to 2 and draining more outward verbs.** Shared prerequisites (all BUILT):
- **Single-writer lock — BUILT + NOW IN USE (`$MC_HOME/mc-lock.sh`).** Both prep
  write-phases wrap in it (check `loop` → yield if a manual session holds it, else acquire → write →
  release). The human always wins (a `/mission-control` session holds the lock while active; a
  heartbeat older than the 15-min TTL is stale and takeable). This is what lets the loop and a manual
  session coexist; the same wrapper extends to every future write.
- **Pause switch — BUILT** (the tick-0 `PAUSED`-file check above; `mc pause`/`mc resume`). Already live.
- **Coder-spawn arm switch — BUILT** (`CODER_SPAWN_LIVE` flag; `mc coder on`/`off`/`status`). Checked at
  the coder spawn point (Prep-write 4), NOT tick-0 (it gates code-writing only, not the whole loop).
  Default OFF → the loop proposes "would spawn a coder" until the operator arms it. Toggle effective next tick.
- **Permission allow-list — DONE** (the `pipeline/` wrappers are allow-listed; a cron tick can't
  answer an interactive prompt — `mc merge` + preconditions stay the authorization gate, the
  allow-rule only drops the redundant prompt).
- **Cron-cleanup — DONE** (see "Scheduling lifecycle" above): the `[mc-loop]` prompt marker is the
  stable handle, the start procedure de-dups (CronList → delete every `[mc-loop]` → create one →
  verify exactly one) so restarts/re-arms never stack duplicate triggers, and "unschedule" is the
  documented clean teardown (delete every `[mc-loop]`, verify none remain).
- **The five internal writes soak clean** — confirm over real ticks that ingest fires only on true
  off-board cycle-committed tickets, triage-prep only on open PRs with genuinely-new feedback,
  **board reconcile advances/demotes lanes only on a correct read** (the catch-rules in steps 2–3 are
  what protect it — a misread lane is the one failure mode, and it's board-only/reversible),
  **cycle archive fires once on a true rollover and moves exactly the `done` set** (validated by the
  first-rollover audit, since it's time-gated and can't tick-soak), and **the `note`/`hold` drain
  applies exactly the right annotation and removes exactly that one inbox line** (never touches
  another verb, never drops a sibling line); that all yield to manual sessions, never double-write,
  never produce an OUTWARD action, and never cross a human gate. This is the gating evidence for the
  first OUTWARD grant.

Full checklist: **Blueprint "Phase-2 build sequence" step 3.** Grants earned so far: five internal +
tracker status-sync + assignee-fix + flag-gated coder-spawn (`CODER_SPAWN_LIVE`). Everything else outward
(tracker field writes, other host writes, `qa`/`done`, merge, colleague reassignment) stays flag/propose.

## The QA move at merge (2026-10-08)

Until this change the tracker moved to QA only when the operator queued `mc qa` after the
alpha smoke, so a merged ticket with complete fields sat out of QA's view for as long as the
smoke took. The operator's policy (2026-09-15) splits the two: once a PR merges and the Final
field check passes, the loop runs the QA transition straight away, under the same `fields`
guard as the field writes. The board lane stays `alpha-verify` until the operator confirms the
smoke, and `mc qa` on a moved row is a board-only lane change with no tracker call. A row the
tracker has not moved keeps the old `mc qa` path, which is still the only way an edited held
draft reaches the tracker. `tracker_qa_at` on the row makes the move once per ticket, and
`assign.sh` now leaves a ticket in the QA status to its QA owner, since an `alpha-verify` row
can hold one.

## The PR-body layout becomes a profile fill (2026-10-09)

The driver's draft-PR step used to say "apply the make-pr rules", which named a skill that
lived only on the maintainer's machine and was never in this repo. It now applies
`{PR_BODY_GUIDE}`, a profile fill like the others, whose example default is
`skills/create-pr/SKILL.md`. `{PR_BODY_GUIDE}` and `{STYLE_GUIDE}` each take a file path or the
name of an installed skill, so an operator can point the loop at a layout or voice skill
without the repo naming it. `/create-pr` takes the same choice from `PR_DESCRIPTION_SKILL` and
`WRITING_STYLE_SKILL`. The smoke run now checks that every fill the driver requires has a row
in the example profile.

## Kickback replies can be published (2026-10-09)

Until this change the kickback address round (Prep-write 5) fixed the clear review items and
left every reply as a private pending draft, so a PR waited on the operator to publish even when
the fix was done. A new profile fill, `{REPLY_POST_WRAPPER}`, names the guarded reply wrapper
(`lib/review-toolkit/review-reply.sh`). Empty, nothing changes. Named, the loop publishes the
replies through it: what changed and the SHA for a fix, and an answer or a decline with its
reason for the needs-a-reply and judgment items the coder now drafts replies for. The wrapper's
exit codes are the routing: 10 (kill switch) drops the round to drafts, 20 (bot thread) is a
skip, 30 (reply cap) hands the thread to the operator, and any other refusal stops publishing
on that row. Every published answer and decline goes to a spot-check report
(`MC_AUTO_POST_REPORT`). The host adapter now computes a thread's `latest` from
comments not written by `MC_REVIEW_SELF`, so a published reply leaves the `review_seen`
signature alone. An earlier draft re-stamped the signature after posting instead, which could
swallow a reviewer reply that landed between the post and the re-stamp.
`/reply-comments` runs the same flow by hand on a PR with no board row.

## The review sweep becomes a scripted step (2026-10-09)

Prep-write 2 used to tell the loop, in prose, to run `mc-review-check.sh` for every `in-review`
row with an open PR. A live loop skipped that step for five ticks in a row while it ran every
scripted step (`mc-poll`, `mc-health`, `mc-inbound`, `mc-archive --check`), so a reviewer's
comments sat untriaged. `mc-review-sweep.sh` now does the per-row loop: it reads `state.json`,
runs the check for each in-review row with a PR (passing `review_seen` as `--seen`), and prints one
line per row with its verdict and signature, `NEEDS-TRIAGE` first. It exits 10 when any row needs
triage. The tick runs it as step 1.7, beside the other scripts, and both the reconcile `CLEAN` gate
and Prep-write 2 read its lines. Prep-write 2 still acts on one row per tick under the existing
prep-write cap; the remaining rows come back on the next sweep because their `review_seen` has not
moved. The sweep is read-only, like `mc-review-check`.

## The smoke run gets its own HOME (2026-10-09)

The smoke test's safety check hashed the live runtime files under `~/.claude/mission-control`
before and after the fixture run. A running loop that wrote the real board during a smoke run
changed `state.json` and turned the run red, though no engine script had touched it. The fixture
section now runs with `HOME` set to a fresh temp dir, so every script that resolves
`$HOME/.claude/mission-control` lands in a sandbox, and the check stamps that sandbox's runtime
dir (the named files plus any new file) instead. One smoke case writes a board and a new file
into the sandbox and asserts the diff names both, so the check is shown to catch a stray write.
The old "newer than the run start" guard on the real dir was dropped: only a script that
hardcodes an absolute path could reach it now, and a live loop writing its own board looks the
same to that check. `MC_WORKLOG_DIR` and the fixture profile's redirections are unchanged.

## The loop paces itself when idle (2026-10-14)

The loop ticked every 10 minutes whether or not there was work, so a quiet board still paid for
six ticks an hour, all night. `mc-pace.sh record --writes <n>` now runs as tick step 5. It logs
one line per tick to `ticks.jsonl` (time, idle, writes, idle streak, live workers, input and output
tokens, next wake) and prints the next delay: 600 seconds after a writing tick, then 1200 and 1800
on consecutive idle ticks, and 3600 for an idle tick between 22:00 and 07:00. A row with a live
worker caps the delay at 600 so its result is harvested promptly. A dynamic `/loop` (`mc prompt
dynamic`, no interval) passes that delay to `ScheduleWakeup`; a fixed cron ignores it and keeps
the log. `mc wake` makes the next tick schedule a 10 minute wake. It cannot shorten the wake
already scheduled. The script also writes `.loop-next-wake`. dash.sh reads it so a planned 60
minute sleep does not show as LOOP SILENT. None of this changes a running loop until it is
restarted with `mc prompt dynamic`.

## merge.sh checks its own authorization (2026-10-20)

The loop drained a queued `mc merge` with `mc guard off merge`, and the auto-mode classifier
still blocked `merge.sh`. The guard and the classifier are separate gates, so letting the loop
merge needs an allow rule, and an allow rule lets any agent session run the script on any PR.
Before this change merge.sh trusted its caller for the "a human asked" part. Now, when
mission-control is installed, commit mode merges only from a terminal or when the inbox holds a
queued `merge <KEY>` for the PR's ticket, and exits 4 otherwise. While the loop holds the writer
lock it also refuses `--allow-freeze`, `--allow-rebase-stale` and `--method`, which the driver
already told the loop never to pass.

The same audit closed five holes in the checks. `--method` was spliced into `gh pr merge
--$method` unchecked, so `--method admin` became `--admin` and bypassed branch protection; it now
takes squash, merge or rebase only. The merge is pinned with `--match-head-commit`, so a push
between the checks and the merge fails it. A failed review-history read, or an APPROVED decision
with no APPROVED review in the history, used to skip the stale-approval checks; both now refuse.
A PR with no CI checks, a closed PR and a pending freeze check now refuse as well. The paginated
review read is joined with `jq -s`, since `--paginate` prints one array per page. A second repo or
PR number on the command line is an error instead of a silent overwrite.

## The loop adopts off-board open PRs (2026-10-20)

An open PR of the operator's that carried a ticket key, for a ticket with no board row, was
invisible to every detector. `mc-orphans` skips keyed PRs by design, and `mc-inbound` never asks
the host. Two failures followed from that. A ticket that reached the ready status was planned
although its PR already existed, and an overnight draft PR on a ticket that never reached the
ready status was never seen at all. `mc-adopt.sh` is the read-only detector for that half. Tick
step 2.5 runs it every tick, and Prep-write 7 adds a row for each `adopt` line at the lane the PR
implies (`awaiting-review` for a draft, `in-review` for a ready PR), with `cycle: "background"`,
`source: "adopt"` and no critic or planner. Its fences are deliberate: only the operator's own PRs, only
tickets the tracker assigns to the operator, never a done ticket, and exactly one open PR per key
(two are a stack or a duplicate, and the loop never guesses which). A teammate's PR on the
operator's ticket is not listed. `mc-inbound` moves a ready ticket with an open PR out of its
planning tiers, and the pre-plan critic asks "adopt as-is, or plan fresh?" when it finds a PR the
detector missed. Unlike every earlier write, adopt was granted with no propose-only soak, because
it is board-only and lands on a gate or waiting lane. Its switch is therefore inverted: the
`ADOPT_OFF` marker (`mc adopt off`) turns it back into "would adopt". The internal-write count went
from five to six.
