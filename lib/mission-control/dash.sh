#!/usr/bin/env bash
# mission-control dashboard — a glanceable, self-refreshing view of state.json.
# `watch` isn't on macOS by default, so this loops itself.
#
#   Run in a second terminal pane/tab:  ~/.claude/mission-control/dash.sh
#   Override:  MC_STATE=/path/to/state.json MC_INTERVAL=5 ~/.claude/mission-control/dash.sh
#
# The view is a pure function of state.json — the orchestrator owns the file,
# this only reads it. Any future surface (webapp, Trello) fills this same slot.
set -uo pipefail

# --- profile config (resolve this script's real dir through any symlink) ---
# dash makes no provider CALLS — it is a pure state.json renderer. It sources dispatch
# only to pick up the active profile (ticket-key shape, note path, provider labels), so
# the same values drive the renderer and the pollers. No profile → generic defaults.
_mc_self="${BASH_SOURCE[0]}"
while [ -L "$_mc_self" ]; do
  _mc_ln="$(readlink "$_mc_self")"
  case "$_mc_ln" in /*) _mc_self="$_mc_ln" ;; *) _mc_self="$(dirname "$_mc_self")/$_mc_ln" ;; esac
done
_MC_LIB="$(cd "$(dirname "$_mc_self")" && pwd)"
_MC_SELF_REAL="$_mc_self"   # fully-resolved path to THIS file (see the hot-reload note)
. "$_MC_LIB/adapters/dispatch.sh"

STATE="${MC_STATE:-$HOME/.claude/mission-control/state.json}"
INTERVAL="${MC_INTERVAL:-3}"
# Ticket-key shape, for scraping keys out of the daily note.
KEY_RE="${MC_TICKET_KEY_REGEX:-[A-Z]+-[0-9]+}"
# Provider display labels for the health banner. Default = the adapter name, capitalized.
TRACKER_LABEL="${MC_TRACKER_LABEL:-$(printf %s "${MC_TRACKER:-tracker}" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')}"
HOST_LABEL="${MC_HOST_LABEL:-$(printf %s "${MC_HOST:-host}" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')}"

# Hot-reload. Bash parses this script ONCE at launch, so editing dash.sh would not
# update a running pane — only state.json is re-read each tick, the renderer LOGIC is
# frozen (the long-standing "restart the dash pane after editing" friction). We watch
# our own mtime and re-exec when it changes, so a save takes effect on the next tick
# with no manual restart. exec preserves the environment (MC_STATE/MC_INTERVAL carry).
SELF="${BASH_SOURCE[0]:-$0}"
# Watch the RESOLVED path, not $SELF. macOS `stat` is lstat by default, so when this
# file is reached through a symlink (the live ~/.claude entry points into the repo)
# `stat -f %m "$SELF"` returns the SYMLINK's mtime — which never changes when the repo
# file is edited, silently killing the reload. $_MC_SELF_REAL is the real file.
self_mtime() { stat -f %m "${_MC_SELF_REAL:-$SELF}" 2>/dev/null; }
LAUNCH_MTIME="$(self_mtime)"

# Flicker-free + scrollback-safe rendering. On a TTY we draw on the terminal's
# ALTERNATE screen buffer (so the dash never scrolls into / fills history) and repaint
# IN PLACE each cycle (cursor-home + per-line erase, see paint()) instead of `clear`
# (which blanks the screen → a visible flash). Both are restored on exit.
IS_TTY=""; [[ -t 1 ]] && IS_TTY=1

# Per-render snapshot temp (see render): clean it up on exit. Cleanup goes on EXIT
# only; INT/TERM just `exit` (which fires EXIT) so Ctrl-C/kill still STOP the dash —
# trapping them without exiting would make the loop unkillable. exec-on-hot-reload
# keeps the same PID, so the snapshot path stays valid across a re-exec. The EXIT trap
# also leaves the alt screen + restores the cursor so the terminal is clean on quit.
trap 'rm -f "${TMPDIR:-/tmp}/.mc-dash-snap.$$"; [[ -n "$IS_TTY" ]] && printf "\033[?25h\033[?1049l"' EXIT
trap 'exit' INT TERM

# Today's-plan overlay. The daily note's "plan to accomplish today" section is a
# priority-ORDERED checkbox list (highest first, per the daily-note workflow). We read it
# as just another read-only priority source — like the poller reads the tracker — and
# overlay its ticket keys on the board (a TODAY strip + a ⭐ on those rows). The note is
# NEVER written; state.json stays the work-state truth, the plan is an ephemeral daily
# lens re-derived each render (so it tracks note edits + the date rollover).
# Note path: MC_DAILY_NOTE_FMT is a strftime TEMPLATE (the profile sets it) expanded on
# EVERY render, so the path tracks the date rollover — a dash left running past midnight
# picks up the new day. MC_DAILY_NOTE overrides with a literal path (spike/testing).
# Both empty = no TODAY overlay, the correct degrade if you keep no such note.
today_plan_keys() {
  local note="${MC_DAILY_NOTE:-}"
  if [[ -z "$note" && -n "${MC_DAILY_NOTE_FMT:-}" ]]; then
    note="$(date +"$MC_DAILY_NOTE_FMT")"
  fi
  [[ -n "$note" && -f "$note" ]] || return 0
  # From the plan header to the next "struggling" header, pull ticket keys in order,
  # de-duped preserving first appearance (= priority order).
  awk '/plan to accomplish today/{f=1;next} /struggling with today/{f=0} f' "$note" \
    | grep -oE "$KEY_RE" | awk '!seen[$0]++'
}

render() {
  if [[ ! -f "$STATE" ]]; then
    printf '  no state file at %s\n' "$STATE"; return
  fi
  # Torn-read tolerant via a SINGLE validated snapshot. A writer may be mid-save when
  # we read (non-atomic write → a half-written file). We can't just guard the first
  # read: render makes several jq calls, and any LATER one can catch a fresh tear and
  # error raw mid-screen. So snapshot ONCE into a temp, retry until it's valid, then
  # point EVERY read at that stable copy (local STATE shadows the global for this render).
  local src="$STATE" snap i ok=""
  snap="${TMPDIR:-/tmp}/.mc-dash-snap.$$"
  for i in 1 2 3 4 5; do
    cp "$src" "$snap" 2>/dev/null && jq -e . "$snap" >/dev/null 2>&1 && { ok=1; break; }
    sleep 0.08
  done
  if [[ -z "$ok" ]]; then
    printf '  \033[2m⟳ state updating…\033[0m (%s)\n' "$src"; rm -f "$snap"; return
  fi
  local STATE="$snap"   # all reads below hit the stable snapshot, never the live file

  local now cap active needs plan_keys plan_jq
  now=$(date '+%H:%M:%S')
  # Today's prioritized plan (space-joined keys, priority order) → table ⭐ + strip.
  plan_keys="$(today_plan_keys | tr '\n' ' ')"
  plan_jq="${plan_keys% }"
  cap=$(jq -r '.concurrency // 3' "$STATE")
  active=$(jq '[.tickets[] | select(.worker != null and (.phase_done | not))] | length' "$STATE")

  # "Needs you" = any state where the ball is in the operator's court: an explicit
  # block, OR sitting in a gate lane (plan-review = Gate 1, awaiting-review =
  # Gate 2), OR the escape-hatch lane. This is separate from the pipeline lane —
  # a ticket can be mid-pipeline and still be the human's turn.
  local NEEDS_FILTER='(.blocked == true) or (.lane == "plan-review") or (.lane == "awaiting-review") or (.lane == "ready-to-merge") or (.lane == "kickback") or (.lane == "alpha-verify") or (.lane == "needs-me")'
  # AWAITING OTHERS: a blocked ticket whose hold is on someone else (blocked_on set to
  # a non-"me" party — product/qa/reviewer/…). `blocked_on` defaults to "me" when absent,
  # so legacy holds stay in NEEDS YOU (backward-compatible). These split OUT of NEEDS YOU
  # into their own calmer band — they don't need YOUR action, just visibility.
  local AWAIT_FILTER='(.blocked == true) and ((.blocked_on // "me") != "me")'
  needs=$(jq "[.tickets[] | select(($NEEDS_FILTER) and (($AWAIT_FILTER) | not))] | length" "$STATE")
  local awaiting; awaiting=$(jq "[.tickets[] | select($AWAIT_FILTER)] | length" "$STATE")

  # Coder-spawn arm state (red light / green light) — the loop's autonomous code-writing
  # switch (`mc coder on`/`off`; flag file `CODER_SPAWN_LIVE`). Green 🟢 = armed (loop spawns
  # coders on Gate-1 approvals); red 🔴 = off (default — loop only proposes). Honors MC_CODER_FILE.
  local coderf coder_badge
  coderf="${MC_CODER_FILE:-$HOME/.claude/mission-control/CODER_SPAWN_LIVE}"
  if [[ -f "$coderf" ]]; then
    coder_badge=$'\033[1;32mCoder 🟢 ON\033[0m'
  else
    coder_badge=$'\033[2;31mCoder 🔴 off\033[0m'
  fi
  # Gate-1 auto-approve badge (`mc gate1 auto`/`manual`; flag file `GATE1_AUTO`). Honors MC_GATE1_FILE.
  local g1f gate1_badge
  g1f="${MC_GATE1_FILE:-$HOME/.claude/mission-control/GATE1_AUTO}"
  if [[ -f "$g1f" ]]; then
    gate1_badge=$'   \033[1;32mGate1 🟢 AUTO\033[0m'
  else
    gate1_badge=$'   \033[2mGate1 ⚪ manual\033[0m'
  fi
  # Pause badge — none while running; ⏸ PAUSED (full freeze) or ⏸ DRAIN (no new intake, in-flight
  # still finishing to its next gate) read from the PAUSED flag (`mc pause [--drain]`). Honors MC_PAUSE_FILE.
  local pf pause_badge=""
  pf="${MC_PAUSE_FILE:-$HOME/.claude/mission-control/PAUSED}"
  if [[ -f "$pf" ]]; then
    if grep -q 'mode=drain' "$pf" 2>/dev/null; then
      pause_badge=$'   \033[1;33m⏸ DRAIN\033[0m'
    else
      pause_badge=$'   \033[1;33m⏸ PAUSED\033[0m'
    fi
  fi
  printf '\033[1m  MISSION CONTROL\033[0m   %s   workers %s/%s   %b%b%b\n' "$now" "$active" "$cap" "$coder_badge" "$gate1_badge" "$pause_badge"
  printf '  ────────────────────────────────────────────────────────────────\n'

  # ⚠ HEALTH banner — credential / reachability failures the loop hit, + a
  # heartbeat-staleness check. Floats ABOVE everything: a blind or dead loop is the
  # most urgent thing to see. All fields optional — absent = healthy (defensive).
  #  • .health.{tracker,host}: "ok"|"auth"|"unreachable" (written by the loop from
  #    mc-health.sh, which emits the "host" key). The provider-named legacy keys are still
  #    read as a fallback so a board written by a pre-rename loop keeps rendering.
  #  • heartbeat: `.loop-heartbeat` sidecar (loop stamps unix secs every tick, lock-free);
  #    falls back to .last_tick_epoch in state for older loops
  local htr hhost hdetail
  htr=$(jq -r '.health.tracker // .health.jira // "ok"' "$STATE")
  hhost=$(jq -r '.health.host // .health.github // "ok"' "$STATE")
  hdetail=$(jq -r '.health.detail // ""' "$STATE")
  # Which provider(s) to name in the banner, using the profile labels.
  _hlabel() {  # $1 = the state value to match ("auth" | "unreachable")
    if [[ "$htr" == "$1" && "$hhost" == "$1" ]]; then printf '%s + %s' "$TRACKER_LABEL" "$HOST_LABEL"
    elif [[ "$htr" == "$1" ]]; then printf '%s' "$TRACKER_LABEL"
    else printf '%s' "$HOST_LABEL"; fi
  }
  if [[ "$htr" == "auth" || "$hhost" == "auth" ]]; then
    printf '\033[1;41;97m  ⚠ ACTION NEEDED — CREDENTIALS \033[0m\033[1;31m %s auth failed; refresh it (the loop is BLIND until you do)\033[0m\n' \
      "$(_hlabel auth)"
    [[ -n "$hdetail" ]] && printf '     \033[2m%s\033[0m\n' "$hdetail"
    printf '  ────────────────────────────────────────────────────────────────\n'
  elif [[ "$htr" == "unreachable" || "$hhost" == "unreachable" ]]; then
    printf '\033[1;33m  ⚠ %s unreachable — transient (loop retrying); check if it persists\033[0m\n' \
      "$(_hlabel unreachable)"
    printf '  ────────────────────────────────────────────────────────────────\n'
  fi
  # Heartbeat: read the SIDECAR file first (`.loop-heartbeat` — the loop stamps it
  # EVERY tick, outside the state-lock, so "loop is alive" is decoupled from "loop owns
  # the state write"; without this, a long manual session holding the lock would starve
  # last_tick_epoch and false-fire LOOP SILENT). Fall back to state.last_tick_epoch for
  # transition / older loops that haven't adopted the sidecar yet.
  local hbfile ltick stale_secs now_s age pausef
  hbfile="${MC_HEARTBEAT_FILE:-$HOME/.claude/mission-control/.loop-heartbeat}"
  ltick=$(cat "$hbfile" 2>/dev/null | tr -dc '0-9')
  [[ -z "$ltick" ]] && ltick=$(jq -r '.last_tick_epoch // empty' "$STATE")
  stale_secs="${MC_LOOP_STALE_SECS:-1500}"   # ~2.5× a 10-min tick
  pausef="${MC_PAUSE_FILE:-$HOME/.claude/mission-control/PAUSED}"
  # Suppress the silent-alarm when the loop is intentionally paused (idle ≠ dead).
  if [[ -n "$ltick" && ! -f "$pausef" ]]; then
    now_s=$(date +%s); age=$(( now_s - ltick ))
    if [[ "$age" -gt "$stale_secs" ]]; then
      printf '\033[1;33m  ⚠ LOOP SILENT for %dm (last tick %s) — cron stopped / session died? check the loop pane\033[0m\n' \
        "$(( age / 60 ))" "$(date -r "$ltick" '+%H:%M' 2>/dev/null || echo '?')"
      printf '  ────────────────────────────────────────────────────────────────\n'
    fi
  fi

  # Reconcile headline — board ↔ tracker ↔ host state from the orchestrator's
  # last reconcile pass (orchestrator writes .reconcile; the view only renders).
  # TWO fields, deliberately separate: `.drift` = genuine disagreement the pass
  # ACTED on or FLAGGED (a lane moved, or a would-fix-manual) — this is what
  # "reconcile" literally means, so the ⚠ banner fires ONLY on this. `.standing`
  # = held/quiet echoes (blocked tickets, "board unchanged", "inbox empty") where
  # board and reality AGREE — narration, not drift, rendered dim so it never
  # cries wolf. Empty `.drift` == actually clean.
  local rdrift rstanding
  rdrift=$(jq -r '(.reconcile.drift // []) | length' "$STATE")
  if [[ "$rdrift" -gt 0 ]]; then
    printf '\033[1;33m  ⚠ RECONCILE (%s drift)\033[0m\n' "$rdrift"
    jq -r '.reconcile.drift[] | "     • \(.)"' "$STATE"
    printf '  ────────────────────────────────────────────────────────────────\n'
  fi
  rstanding=$(jq -r '(.reconcile.standing // []) | length' "$STATE")
  if [[ "$rstanding" -gt 0 ]]; then
    printf '\033[2m  · reconcile standing (%s, no drift):\033[0m\n' "$rstanding"
    jq -r '.reconcile.standing[] | "[2m     · \(.)[0m"' "$STATE"
    printf '  ────────────────────────────────────────────────────────────────\n'
  fi

  # ⛔ Needs-you banner floats to the very top — the supervisor's first glance.
  # Excludes AWAITING-OTHERS holds (rendered separately below) so this band is
  # strictly "your move."
  if [[ "$needs" -gt 0 ]]; then
    printf '\033[1;31m  ⛔ NEEDS YOU (%s)\033[0m\n' "$needs"
    jq -r "
      def reason:
        if .blocked then (.question // \"blocked — see session\")
        elif .lane == \"plan-review\"      then \"approve plan (Gate 1)\"
        elif .lane == \"awaiting-review\"  then \"walk diff in difit → mark ready (Gate 2)\"
        elif .lane == \"ready-to-merge\"   then \"approved + CI green → merge (yours)\"
        elif .lane == \"kickback\" then (if (.triage_doc // \"\") != \"\" then \"📝 triage ready in notes → \" + (.triage_doc | split(\"/\") | last) else (.question // \"kicked back (QA or review) — triage & address\") end)
        elif .lane == \"alpha-verify\"     then (.question // \"merged — smoke-test on alpha before QA handoff\")
        elif .lane == \"needs-me\"         then (.question // \"needs you\")
        else \"needs you\" end;
      .tickets[] | select(($NEEDS_FILTER) and (($AWAIT_FILTER) | not))
      | (reason) as \$r
      | (\$r[0:140] + (if (\$r | length) > 140 then \" … (full context in session)\" else \"\" end)) as \$short
      | \"     \(.ticket)  [\(.lane)]\(if .blocked then \" 🚫BLOCKED\" else \"\" end)  — \(\$short)\"" "$STATE"
    printf '  ────────────────────────────────────────────────────────────────\n'
  fi

  # ⏳ Awaiting-others band — held tickets whose blocker is someone else (product,
  # QA, a reviewer). Informational, not your move; amber not red. Keeps the
  # "waiting on another team" class out of NEEDS YOU so your queue reads true.
  if [[ "$awaiting" -gt 0 ]]; then
    printf '\033[1;33m  ⏳ AWAITING OTHERS (%s)\033[0m\n' "$awaiting"
    jq -r "
      .tickets[] | select($AWAIT_FILTER)
      | (.blocked_on // \"someone\") as \$who
      | (.question // \"held\") as \$q
      | (\$q[0:120] + (if (\$q | length) > 120 then \" …\" else \"\" end)) as \$short
      | \"     \(.ticket)  [\(.lane)]  ⏳ \(\$who) — \(\$short)\"" "$STATE"
    printf '  ────────────────────────────────────────────────────────────────\n'
  fi

  # 🎯 TODAY strip — the daily plan's ticket keys in priority order, each annotated
  # with its current board lane (or flagged inbound if planned but not yet on the
  # board — the bridge to mc-inbound.sh). A planning lens, distinct from the urgent
  # NEEDS-YOU lens above; it does NOT re-sort the table (that stays attention-ranked).
  if [[ -n "$plan_jq" ]]; then
    printf '\033[1;36m  🎯 TODAY (by priority)\033[0m\n'
    local k st
    for k in $plan_jq; do
      st=$(jq -r --arg k "$k" '
        (.tickets[] | select(.ticket == $k)
          | "[" + (.lane // "⚠ no-lane") + "]"
            + (if .blocked then " 🚫" elif (.worker != null and (.phase_done|not)) then " ●" else "" end))
        // "not on board — inbound? (mc-inbound.sh)"' "$STATE")
      printf '     • %-9s %s\n' "$k" "$st"
    done
    printf '  ────────────────────────────────────────────────────────────────\n'
  fi

  # Table, sorted so what needs attention is highest: BLOCKED first (out-of-band
  # stuck — its lane no longer reflects the real next action), then needs-me /
  # gates, then in-flight work, then done. Markers: 🚫 blocked · ⛔ your turn
  # (gate) · ● worker running. Blocked is distinct from a gate turn on purpose —
  # a 🚫 row needs UNBLOCKING, not the action its lane implies.
  printf '    \033[2m🚫 blocked · ⛔ your turn · ● working · ⭐ today · 📝 triage in notes · ❄ frozen · ✗ CI fail · ◴ CI pending\033[0m\n'
  printf '     %-9s %-18s %-6s %s\n' "TICKET" "LANE" "PR" "DESC"
  # Columns are padded INSIDE jq (pure ASCII → deterministic width). The only
  # display-width assumption: each marker is exactly 2 cells (🚫/⛔ are 2-cell
  # emoji; "● " and "  " are 2 ASCII cells), so the ticket column starts at the
  # same place on every row. printf widths can't be trusted with the markers
  # because emoji span 2 cells but count as 1 char.
  jq -r '
    def rank: {"needs-me":0,"ready-to-merge":1,"alpha-verify":2,"kickback":3,"awaiting-review":4,
               "plan-review":5,"in-review":6,"qa":7,"product-review":8,"implement":9,"refined":10,"done":12}[. // ""] // 11;
    def rpad($n): ((. // "")[0:$n]) as $s | $s + (" " * ([($n - ($s | length)), 0] | max));
    .tickets
    | map(.lane //= "⚠ no-lane")
    | map(select(.cycle != "background"))
    | map(select((.lane == "refined" and (.blocked | not) and .worker == null) | not))
    | sort_by([(if .blocked then 0 else 1 end), (.lane | rank), .ticket])
    | .[]
    | (if .blocked then "🚫"
       elif (.lane == "plan-review" or .lane == "awaiting-review" or .lane == "ready-to-merge" or .lane == "kickback" or .lane == "alpha-verify" or .lane == "needs-me") then "⛔"
       elif (.worker != null and (.phase_done | not)) then "● "
       else "  " end) as $m
    | (if .ci == "frozen" then "❄ "
       elif .ci == "fail" then "✗" + (if (.ci_detail // "") != "" then ":" + (.ci_detail[0:18]) else "" end) + " "
       elif .ci == "pending" then "◴ "
       else "" end) as $ci
    | (.ticket as $tk | $plan | split(" ") | index($tk)) as $hit
    | (if $hit then "⭐ " else "" end) as $star
    | (if (.triage_doc // "") != "" then "📝 " else "" end) as $tg
    | $m + " " + (.ticket | rpad(9)) + " " + (.lane | rpad(18)) + " "
      + ((if .pr then "#" + (.pr | split("/") | last) else "" end) | rpad(6)) + " "
      + $ci + $star + $tg + ((.desc // "")[0:48])' --arg plan "$plan_jq" "$STATE" \
  | while IFS= read -r line; do printf '  %s\n' "$line"; done

  # ⌾ OUT OF CYCLE — a full MIRROR of the main table for everything NOT in the sprint
  # (cycle=="background": assigned + at the ready status + vetted, but not in an open
  # cycle). Same columns, markers, and attention-rank as the sprint board above — a
  # background ticket in ANY lane lives here (planned, in review, kicked back), NOT just
  # the not-yet-started ones, so it never leaks into the sprint view. Plans made
  # opportunistically land here at plan-review for your Gate-1 review. `refined` renders
  # as `selected` (captured, awaiting plan). `source` tags origin (the tracker today; flake
  # bridge later). Merge separation from the sprint table is a spacing nicety, deferred.
  local ooc_n
  ooc_n=$(jq '[.tickets[] | select(.cycle == "background")] | length' "$STATE")
  if [[ "$ooc_n" -gt 0 ]]; then
    printf '\033[1;35m  ⌾ OUT OF CYCLE (%s) \033[0m\033[2m— not in sprint · plans land at Gate 1 · mc plan <KEY> to jump one\033[0m\n' "$ooc_n"
    printf '     %-9s %-18s %-6s %s\n' "TICKET" "LANE" "PR" "DESC"
    jq -r '
      def rank: {"needs-me":0,"ready-to-merge":1,"alpha-verify":2,"kickback":3,"awaiting-review":4,
                 "plan-review":5,"in-review":6,"qa":7,"product-review":8,"implement":9,"refined":10,"done":12}[. // ""] // 11;
      def rpad($n): ((. // "")[0:$n]) as $s | $s + (" " * ([($n - ($s | length)), 0] | max));
      .tickets
      | map(.lane //= "⚠ no-lane")
      | map(select(.cycle == "background"))
      | sort_by([(if .blocked then 0 else 1 end), (.lane | rank), .ticket])
      | .[]
      | (if .blocked then "🚫"
         elif (.lane == "plan-review" or .lane == "awaiting-review" or .lane == "ready-to-merge" or .lane == "kickback" or .lane == "alpha-verify" or .lane == "needs-me") then "⛔"
         elif (.worker != null and (.phase_done | not)) then "● "
         else "  " end) as $m
      | (if .ci == "frozen" then "❄ "
         elif .ci == "fail" then "✗" + (if (.ci_detail // "") != "" then ":" + (.ci_detail[0:18]) else "" end) + " "
         elif .ci == "pending" then "◴ "
         else "" end) as $ci
      | (.ticket as $tk | $plan | split(" ") | index($tk)) as $hit
      | (if $hit then "⭐ " else "" end) as $star
      | (if (.triage_doc // "") != "" then "📝 " else "" end) as $tg
      | (if .lane == "refined" then "selected" else .lane end) as $lane
      | ((.source // $tracker) | if . == $tracker then "" else "[" + . + "] " end) as $src
      | $m + " " + (.ticket | rpad(9)) + " " + ($lane | rpad(18)) + " "
        + ((if .pr then "#" + (.pr | split("/") | last) else "" end) | rpad(6)) + " "
        + $ci + $star + $tg + $src + ((.desc // "")[0:48])' --arg plan "$plan_jq" --arg tracker "${MC_TRACKER:-jira}" "$STATE" \
    | while IFS= read -r line; do printf '  %s\n' "$line"; done
    printf '  ────────────────────────────────────────────────────────────────\n'
  fi

  # Parked refined backlog — collapsed to a one-line count (mirrors mc-poll.sh).
  # A refined ticket that's blocked or has a worker is NOT parked (it stays in the
  # table above); a cycle=="background" one lives in OUT OF CYCLE above, not here —
  # so this footer is the RAW, not-yet-vetted backlog (unvetted / not at the ready status).
  local parked_ids parked_n
  parked_ids=$(jq -r '[.tickets[] | select(.lane == "refined" and (.blocked | not) and .worker == null and (.cycle != "background")) | .ticket] | join(" ")' "$STATE")
  if [[ -n "$parked_ids" ]]; then
    parked_n=$(printf '%s' "$parked_ids" | wc -w | tr -d ' ')
    printf '  \033[2mparked (raw backlog · mc plan <KEY> to pull in): %s — %s\033[0m\n' "$parked_n" "$parked_ids"
  fi

  rm -f "$snap"   # drop this render's snapshot (next render takes a fresh one)
}

# paint — draw a captured frame in place. Home the cursor, print each line cleared to
# end-of-line (\033[K, so a line that shrank leaves no stale tail), then erase everything
# below (\033[J, so a shorter frame leaves no leftover rows). No `clear`, so no flash.
# Off a TTY (piped/redirected) it degrades to a plain dump.
paint() {
  if [[ -z "$IS_TTY" ]]; then printf '%s\n' "$1"; return; fi
  printf '\033[H'
  printf '%s\n' "$1" | while IFS= read -r ln || [[ -n "$ln" ]]; do
    printf '%s\033[K\n' "$ln"
  done
  printf '\033[J'
}

[[ -n "$IS_TTY" ]] && printf '\033[?1049h\033[?25l'   # enter alt screen, hide cursor

while true; do
  # Capture the whole frame, then paint it atomically — the screen never shows a
  # half-built frame (part of the old flicker) and never blanks between frames.
  frame="$(render)"
  paint "$frame"
  sleep "$INTERVAL"
  # If this script changed on disk, re-exec to load the new renderer logic. exec keeps
  # the PID and does NOT fire the EXIT trap, so we stay on the alt screen across reload.
  if [[ -n "$LAUNCH_MTIME" && "$(self_mtime)" != "$LAUNCH_MTIME" ]]; then
    exec "$SELF"
  fi
done
