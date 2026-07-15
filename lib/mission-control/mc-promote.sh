#!/usr/bin/env bash
# mc-promote.sh — OUT-OF-CYCLE promotion detector for mission-control (read-only).
#
# Closes the gap mc-inbound.sh leaves open: inbound classifies `cycle` (in-cycle vs
# background) ONLY at ingest and skips any key already on the board, so it never
# re-evaluates an on-board ticket. A ticket captured as `cycle=background` (OUT OF
# CYCLE — assigned + ready + vetted, but not in the active cycle at capture) that is
# LATER pulled into the active cycle stays stuck in OUT OF CYCLE forever. This detector
# finds those: on-board `cycle=background` tickets the tracker now places in the active
# cycle. They should be PROMOTED to `cycle=sprint` (into the main table).
#
# Symmetric to the cycle-boundary guards: like mc-inbound (inbound classification),
# mc-archive (rollover sweep), and mc-poll's regression flag, it only DETECTS + prints
# — the cycle flip is a state.json WRITE and belongs to the single writer (the manual
# orchestrator or the loop's granted-write path, lock-wrapped). READ-ONLY here.
#
# The INVERSE (demote a `cycle=sprint` ticket dropped from the cycle back to background)
# is intentionally NOT handled — auto-demoting mid-flight in-cycle work is not wanted; a
# ticket pulled from the cycle needs human eyes, not a silent shuffle.
#
# Cycle membership comes from the tracker adapter (`in_active_cycle`); the display
# status from `fields_of`. On a cycle-less tracker (no `cycles` capability)
# `in_active_cycle` returns empty → clean no-op, which is the correct degrade.
#
#   ~/.claude/mission-control/mc-promote.sh
#   MC_STATE=/path/to/state.json ~/.claude/mission-control/mc-promote.sh
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
[ -f "$STATE" ] || { echo "no state at $STATE" >&2; exit 1; }

# On-board background (OUT OF CYCLE) keys.
bg_keys=$(jq -r '.tickets[] | select(.cycle=="background") | .ticket' "$STATE" | paste -sd, -)
if [ -z "$bg_keys" ]; then
  printf 'promote: none (no cycle=background tickets on the board)\n'
  exit 0
fi

# Of those, which does the tracker now place in the active cycle? Those are promotable.
in_cycle=$(tracker in_active_cycle "$bg_keys" | grep -v '^$' || true)
n=$(printf '%s' "$in_cycle" | grep -c . || true)
if [ "$n" -eq 0 ]; then
  printf 'promote: none (no OUT OF CYCLE ticket has joined the active cycle)\n'
  exit 0
fi

# One batch call for the display status of just the promotable subset.
keys_csv=$(printf '%s' "$in_cycle" | paste -sd, -)
fields=$(tracker fields_of "$keys_csv")

printf 'promote: %s OUT OF CYCLE ticket(s) now in the active cycle — PROMOTE to cycle=sprint (single-writer flip; moves them into the main table):\n' "$n"
printf '%s\n' "$in_cycle" | while IFS= read -r k; do
  [ -z "$k" ] && continue
  s=$(awk -F'\t' -v key="$k" '$1==key{print $2; exit}' <<EOF
$fields
EOF
)
  printf '  %s  —  %s\n' "$k" "$s"
done
