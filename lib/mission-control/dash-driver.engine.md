# Mission Control — dashboard-only `/loop` driver

This loop keeps the board in `state.json` true to the tracker and the PR host, so `dash.sh` stays
current. It never pulls work in or pushes work forward: no ingest, no planners, no coders, no
reviewers, no PR adoption, no kickback replies, no field checks, no QA moves, and no tracker or host
writes. It is the main driver (`loop-driver.md`) with every intake and outward grant removed.

It runs instead of the main loop, never beside it. Step 0 stands down when the main loop is live.

`ABC-1234` is a placeholder key. The real key shape and status names come from the profile overlay.

**Start command** (`mc prompt dash` copies it; `mc prompt dash dynamic` drops the interval):

`[mc-dash] Mission-control dashboard tick. Read $MC_HOME/dash-driver.md and execute ONE tick exactly as specified. Emit one terse line, then stop.`

To stop it, end it in its pane: `ScheduleWakeup` with `stop: true` for a dynamic loop, or
`CronDelete` the `[mc-dash]` job. The `PAUSED` file belongs to the main loop and does not apply here.

## Each tick

Every tick ends with step 8, including a tick that stops early. Count `writes` as you go: each
lane or field fix in step 4, the archive commit, each promote flip and each inbox drain is one.
The `health` and `reconcile` fields are rewritten every pass and do not count.

0. **Stand down if the main loop is live.** This loop writes `.loop-heartbeat` as `<epoch> dash`;
   the main loop writes a bare epoch. Run:

   ```bash
   hb=$(cat $MC_HOME/.loop-heartbeat 2>/dev/null); nw=$(cat $MC_HOME/.loop-next-wake 2>/dev/null | tr -dc '0-9'); \
   echo "hb=[$hb] next_wake=[$nw] now=$(date +%s)"; cat $MC_HOME/PAUSED 2>/dev/null
   ```

   The main loop is live when all three hold:
   - the heartbeat has no `dash` tag;
   - now is before `heartbeat + 1500` or before `next_wake + 900` (a dynamic main loop idles up to
     an hour; while the heartbeat is untagged, `.loop-next-wake` is the main loop's);
   - `PAUSED` is absent, or it has a `mode=drain` line (a drain-paused main loop still runs; a fully
     paused one does not).

   If it is live, emit `dash @ HH:MM — ⛔ main loop live, standing down` and go to step 8 as a
   stand-down tick with `writes 0`.

1. **Profile overlay.** Read `$MC_HOME/profile.loop-driver.md`, the sections **Ticket keys** and
   **Status vocabulary** only. You need the terminal-done status and the QA status. If the overlay is
   missing, emit `dash @ HH:MM — ⛔ profile overlay missing` and go to step 8.

2. **Poll.** Run `$MC_HOME/mc-poll.sh`. It is the only board read; do not `cat state.json` whole.
   Use the board table and the `post-merge QA move` section. Ignore `background condition`,
   `background queue`, `sprint plan queue`, `plan_proposed` and the parked footer: this loop plans
   nothing. A `due` line in the QA section is not an instruction here; step 4 flags it.

3. **Heartbeat and health.**
   - `printf '%s dash\n' "$(date +%s)" > $MC_HOME/.loop-heartbeat`, every tick, outside the lock.
   - Run `$MC_HOME/mc-health.sh` for the host. The tracker is `ok` when the poll resolved tracker
     statuses, `unreachable` when every tracker column is `?(tracker-miss)` across three or more
     rows, and `auth` only when you can tell it is a credential rejection.
   - On a change from `ok` to `auth` for either service, send one `PushNotification`
     ("Mission Control dash: <svc> auth expired"). Not again while it stays `auth`.
   - Run `$MC_HOME/mc-review-sweep.sh` unless host health is `auth`/`unreachable`. It is read-only.
     Its verdict per `in-review` row gates the `ready-to-merge` move in step 4.

4. **Take the lock, then reconcile.** `$MC_HOME/mc-lock.sh check dash`. If it exits 1, a manual
   session holds the lock: run only `$MC_HOME/mc-archive.sh --check`, report what you would change in
   steps 4–6, write nothing, and go to step 7. Otherwise `acquire dash`; if that exits 1 (another
   writer took it in between), treat it the same as the check failing. Hold the lock through step 6.

   Re-read `state.json`, then apply the fixes below as one atomic write (`jq` to a tmp file, then `mv`;
   merge fields onto the existing row, never rebuild it). Also write `health` = `{tracker, host,
   checked_at, detail}`. Skip tracker-dependent fixes when the tracker is blind and host-dependent
   fixes when the host is blind. Treat `(host-miss)`, `(host-err)` and `?(tracker-miss)` as unknown,
   not clean.

   Fixes you apply. Except for the tracker-Done move, never move a `blocked` row's lane.
   - **PR merged, lane behind** (`awaiting-review`, `in-review`, `kickback`, `ready-to-merge`) →
     lane `alpha-verify`, `ci: "-"`, clear `ci_detail`.
   - **`in-review` → `ready-to-merge`** only when all hold: the sweep says `CLEAN`, DRAFT is not
     `draft`, REVIEW is `APPROVED` (not `re-review`), CI is `green` or `frozen`, and the PR is
     mergeable. `NEEDS-TRIAGE` and `NO-NEW` rows stay put; name `NEEDS-TRIAGE` rows in the tick line.
   - **`ready-to-merge` but REVIEW is `re-review` or CI is `fail`** → lane `in-review`.
   - **CI** → write the polled `ci`, and `ci_detail` as the failing check's short name only.
   - **Tracker at the terminal-done status, lane behind** (any lane before `done`, blocked or not) →
     lane `done`. Keep `result` and `release_note`.
   - **QA section line `tracker already <QA status> — set tracker_qa_at`** → set `tracker_qa_at` to
     now and `question: "in QA (tracker) · smoke on alpha, then mc qa ABC-N"`.
   - **`reconcile`** → write both arrays every pass. `drift[]` holds each fix you applied
     (`"ABC-N in-review→alpha-verify (PR merged)"`) and each flag below. `standing[]` holds at most
     three lines of pass-level facts ("archive up to date", "inbox empty"), never a per-row echo.

   Flags, computed after the fixes above (a `drift[]` line, no write):
   - Tracker status behind the board lane → `"would sync ABC-N tracker → <lane> (manual)"`. Not for
     an `alpha-verify` row whose tracker is at the QA status: the tracker is ahead there, as expected.
   - Unassigned ticket in `plan-review` through `alpha-verify` → `"ABC-N unassigned (manual)"`. Never
     for `refined`, `qa`, `product-review` or `done`.
   - QA section line `due` → `"ABC-N merged, QA move pending (manual)"`.
   - Board `done` but tracker not terminal-done → `"ABC-N done on board, tracker <status>"`.
   - A row with `worker` set → `"ABC-N worker marker <worker> (not tracked in dash mode)"`.
   - A `⚠REGRESSED` row from the poll (tracker moved backward) → name it; never move a lane back.

5. **Cycle rollover (still holding the lock, after step 4's `mv`).**
   - Run `$MC_HOME/mc-archive.sh --check`. If it says DUE and the tracker is not blind, run
     `$MC_HOME/mc-archive.sh --commit` and report `"cycle rolled → archived N done"`, plus any
     `⚠ HELD` tickets it names. Never `--force`. The commit rewrites `state.json` itself, so re-read
     the file before any later write.
   - Run `$MC_HOME/mc-promote.sh`. For each ticket it lists, set `cycle: "sprint"` on that row.

6. **Inbox: `note`, `hold`, `unblock` only (still holding the lock).** For each such line in
   `$MC_HOME/mc-inbox` whose ticket is on the board:
   - `note ABC-N: <text>` → set the row's `question` to the text.
   - `hold ABC-N: <reason>` → `blocked: true`, `question` = reason, and `blocked_on` set to the party
     when the reason names someone other than the operator.
   - `unblock ABC-N` → `blocked: false`, clear `blocked_on` and the block `question`.
   Then remove the line with `$MC_HOME/mc-inbox-drain.sh "<the full line>"`, run bare as its own
   call. Never edit the inbox any other way. A line for a ticket not on the board stays and is named
   in the tick line. Every other verb (`approve`, `plan`, `ready`, `merge`, `qa`, `changes`) stays
   queued for the main loop or the operator; give the count in the tick line.

   Then `$MC_HOME/mc-lock.sh release dash`.

7. **Report.** One line:
   `dash @ HH:MM — <applied fixes, or "board clean"> · <flags> · <archive/promote/inbox if any>`.

8. **Pace, every tick, as the last call.** Run it bare, with this loop's own log and idle streak so
   the main loop's pacing is never touched:

   `MC_TICKS_LOG=$MC_HOME/ticks.dash.jsonl MC_PACE_FILE=$MC_HOME/.dash-pace $MC_HOME/mc-pace.sh record --writes <n>`

   On a tick that ran (not a stand-down), this also writes `.loop-next-wake`, which keeps the dash
   from flagging LOOP SILENT during a long idle wait. On a stand-down tick, add
   `MC_NEXT_WAKE_FILE=$MC_HOME/.dash-next-wake` so the main loop's planned wake stays its own.
   Under a dynamic `/loop`, call `ScheduleWakeup` with the delay it prints and the start command
   above as `prompt`. Under a fixed-interval `/loop`, ignore the delay.

## Never

Spawn any agent or worker. Ingest, plan or adopt a ticket. Run any pipeline wrapper (status-sync,
assign, request-review, merge, QA, done, field). Call `gh` or the tracker to write. Move a lane
backward except `ready-to-merge → in-review`. Move a `blocked` row's lane except to `done` when the
tracker is already Done. Drain any inbox verb other than `note`, `hold` and `unblock`.
