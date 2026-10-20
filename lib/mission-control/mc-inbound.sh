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
#   OPEN PR: a ticket from either tier that already has my open PR (mc-adopt.sh --keys)
#            moves to a third section. The loop adopts it at the PR's lane instead of
#            planning it; two open PRs on one key are flagged for the operator.
#            mc-adopt runs only when a tier has rows, so a quiet tick costs no host call.
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

# Pull the tickets that already have my open PR out of both tiers. If mc-adopt fails the
# tiers stand as they are; the pre-plan critic is the backstop for a PR it missed.
open_rows=""; open_err=""
adopt_keys=$("$_MC_LIB/mc-adopt.sh" --keys 2>/dev/null); [ $? -eq 1 ] && open_err=1
if [ -n "$adopt_keys" ]; then
  _by_open() {  # <in|out> <rows>: the rows whose key mc-adopt lists (in) or does not (out)
    printf '%s\n' "$2" | awk -F'\t' -v want="$1" -v ks="$(printf '%s' "$adopt_keys" | tr '\n' ' ')" '
      BEGIN { n = split(ks, a, " "); for (i = 1; i <= n; i++) k[a[i]] }
      NF && ((toupper($1) in k) == (want == "in"))'
  }
  open_rows=$(_by_open in "$sprint_rows"; _by_open in "$bg_rows")
  sprint_rows=$(_by_open out "$sprint_rows"); bg_rows=$(_by_open out "$bg_rows")
  sprint_n=$(printf '%s' "$sprint_rows" | grep -c . || true)
  bg_n=$(printf '%s' "$bg_rows" | grep -c . || true)
fi
open_n=$(printf '%s' "$open_rows" | grep -c . || true)

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

if [ "$open_n" -gt 0 ]; then
  printf 'inbound (open PR): %s ticket(s) already have your open PR; mc-adopt adopts them (or flags two PRs), do NOT plan:\n' "$open_n"
  printf '%s\n' "$open_rows" | while IFS=$'\t' read -r k s; do [ -n "$k" ] && printf '  %s  %s\n' "$k" "$s"; done
elif [ -n "$open_err" ]; then
  printf 'inbound (open PR): unknown (mc-adopt failed; the tiers above are unfiltered)\n'
fi
