#!/usr/bin/env bash
# mc-inbound.sh — INBOUND work detector for mission-control (read-only).
#
# Finds tickets that are ready to start but NOT yet on the board, in TWO tiers:
#
#   TIER 1 — SPRINT (committed, urgent): put in flight ASAP, eager auto-plan.
#     • assigned to me
#     • in the ready lane                   — status = $MC_INBOUND_STATUS
#     • committed to the CURRENT cycle      — in the active cycle
#
#   TIER 2 — BACKGROUND (out-of-cycle, "when I get to it"): capture onto the board,
#            plan OPPORTUNISTICALLY (only when no sprint work is queued + a planner
#            slot is free, one at a time — see loop-driver "Ingest").
#     • assigned to me + status = $MC_INBOUND_STATUS
#     • NOT in the active cycle
#     • VETTED — cleared the tracker's vetting gate (e.g. a story-point estimate)
#       (vetting means the ticket cleared estimation/grooming, so it was considered
#       before an idle agent scoops it — vs a raw groomed-to-ready ticket that isn't
#       really ready. Fails SAFE: an unvetted ready ticket is skipped, never grabbed.)
#
#   • both tiers: not already a key in state.json (diffed below).
#
# The cycle clause is no longer a hard FILTER — it's a TIER signal: sprint work is
# eager, background work is opportunistic. Capture is cheap (a refined row); the WIP
# bound lives on PLANNING (background = one-at-a-time when idle), not on capture.
#
# READ-ONLY, like mc-poll.sh / mc-orphans.sh — NEVER writes state.json or the tracker.
# It only DETECTS + prints, tagged by tier; ingest + planner-spawn (the writes) are the
# orchestrator's job under the single-writer rule.
#
# Cycle + vetting come from the tracker adapter (list_ready's in/out + vetted flags). On
# a cycle-less tracker (no `cycles` capability) the `in`/`out` split degrades to the
# whole ready set — acceptable, since the engine still diffs against the board.
#
#   ~/.claude/mission-control/mc-inbound.sh
#   MC_STATE=/path/to/state.json ~/.claude/mission-control/mc-inbound.sh
#   MC_INBOUND_STATUS="Ready for Dev" ~/.claude/mission-control/mc-inbound.sh   # override status
set -uo pipefail

# --- adapter dispatch (resolve this script's real dir through any symlink) ---
_mc_self="${BASH_SOURCE[0]}"
while [ -L "$_mc_self" ]; do
  _mc_ln="$(readlink "$_mc_self")"
  case "$_mc_ln" in /*) _mc_self="$_mc_ln" ;; *) _mc_self="$(dirname "$_mc_self")/$_mc_ln" ;; esac
done
_MC_LIB="$(cd "$(dirname "$_mc_self")" && pwd)"
. "$_MC_LIB/adapters/dispatch.sh"

STATE="${MC_STATE:-$HOME/.claude/mission-control/state.json}"
STATUS="${MC_INBOUND_STATUS:-Ready for Dev}"
[ -f "$STATE" ] || { echo "no state at $STATE" >&2; exit 1; }

# Keys already on the board (any lane, incl. done) — we don't re-ingest those.
on_board=$(jq -r '.tickets[].ticket' "$STATE" 2>/dev/null | tr '[:lower:]' '[:upper:]' | sort -u)

# _filter_offboard — reads key⇥summary TSV on stdin, echoes only rows whose key is
# NOT already on the board (case-insensitive match).
_filter_offboard() {
  while IFS=$'\t' read -r key summary; do
    [ -z "$key" ] && continue
    ukey=$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')
    printf '%s\n' "$on_board" | grep -qx "$ukey" && continue
    printf '%s\t%s\n' "$key" "$summary"
  done
}

sprint_rows=$(tracker list_ready "$STATUS" in         | _filter_offboard)
bg_rows=$(tracker list_ready "$STATUS" out vetted      | _filter_offboard)

sprint_n=$(printf '%s' "$sprint_rows" | grep -c . || true)
bg_n=$(printf '%s' "$bg_rows" | grep -c . || true)

if [ "$sprint_n" -eq 0 ] && [ "$bg_n" -eq 0 ]; then
  printf 'inbound: none (no off-board assigned "%s" tickets, sprint or background)\n' "$STATUS"
  exit 0
fi

if [ "$sprint_n" -gt 0 ]; then
  printf 'inbound (sprint): %s ticket(s) NOT on the board — ingest + plan NOW, cycle=sprint (→ Gate 1):\n' "$sprint_n"
  printf '%s\n' "$sprint_rows" | while IFS=$'\t' read -r k s; do [ -n "$k" ] && printf '  %s  —  %s\n' "$k" "$s"; done
else
  printf 'inbound (sprint): none\n'
fi

if [ "$bg_n" -gt 0 ]; then
  printf 'inbound (background): %s vetted out-of-cycle ticket(s) — capture cycle=background, plan OPPORTUNISTICALLY (idle + slot free, one at a time):\n' "$bg_n"
  printf '%s\n' "$bg_rows" | while IFS=$'\t' read -r k s; do [ -n "$k" ] && printf '  %s  —  %s\n' "$k" "$s"; done
else
  printf 'inbound (background): none\n'
fi
