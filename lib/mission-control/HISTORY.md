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
