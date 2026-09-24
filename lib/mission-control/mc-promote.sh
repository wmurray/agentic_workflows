#!/usr/bin/env bash
# mc-promote.sh — OUT-OF-CYCLE promotion detector for mission-control (read-only).
#
# Closes the gap mc-inbound.sh leaves open: inbound classifies `cycle` (in-cycle vs
# background) ONLY at ingest and skips any key already on the board, so it never
# re-evaluates an on-board ticket. A ticket captured with any non-sprint cycle stamp
# (`background` = OUT OF CYCLE, `backlog` = parked raw backlog, etc.) that is LATER
# pulled into the active cycle stays stuck under its stale stamp forever. This detector
# finds those: on-board `cycle != "sprint"` tickets the tracker now places in the active
# cycle. They should be PROMOTED to `cycle=sprint` (into the main table).
# (2026-08-10: widened from `cycle=="background"` only — a ticket stamped `backlog`
# at capture got pulled into the sprint, and the old scan never saw it, so its PR was
# mislabeled "outside current sprint".)
#
# Symmetric to the cycle-boundary guards: like mc-inbound (inbound classification),
# mc-archive (rollover sweep), and mc-poll's regression flag, it only DETECTS + prints
# — the cycle flip is a state.json WRITE and belongs to the single writer (the manual
# orchestrator or the loop's granted-write path, lock-wrapped). READ-ONLY here.
#
# The INVERSE (demote a `cycle=sprint` ticket dropped from the cycle back to background)
# is intentionally NOT handled — auto-demoting mid-flight in-cycle work is not wanted; a
# ticket pulled from the cycle needs human eyes, not a silent shuffle. (`--key` mode
# reports that case explicitly so a lane transition can surface it.)
#
# Cycle membership comes from the tracker adapter (`in_active_cycle`); the display
# status from `fields_of`. On a cycle-less tracker (no `cycles` capability)
# `in_active_cycle` returns empty → clean no-op, which is the correct degrade.
#
#   ~/.claude/mission-control/mc-promote.sh                 # board-wide sweep (every tick)
#   ~/.claude/mission-control/mc-promote.sh --key DX-XXXX   # per-ticket check at a lane
#       transition: exit 0 = ticket is in the active cycle and its board cycle != sprint
#       → the caller's state write should flip cycle:"sprint" in the same edit;
#       exit 3 = no change needed (already consistent, or legitimately out of cycle);
#       exit 4 = cycle:"sprint" ticket has LEFT the active cycle → do NOT demote, flag
#       to the operator. Read-only in every mode.
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

# --- per-key mode: lane-transition cycle refresh check --------------------------------
if [ "${1:-}" = "--key" ]; then
  key="${2:-}"
  [ -n "$key" ] || { echo "mc-promote: --key needs a ticket key" >&2; exit 2; }
  cur=$(jq -r --arg k "$key" '.tickets[] | select(.ticket==$k) | .cycle // empty' "$STATE")
  [ -n "$cur" ] || { echo "mc-promote: $key not on the board" >&2; exit 2; }
  in_cycle=$(tracker in_active_cycle "$key" | grep -c . || true)
  if [ "$in_cycle" -gt 0 ]; then
    if [ "$cur" = "sprint" ]; then
      printf '%s: cycle consistent (sprint, in active cycle) — no change\n' "$key"
      exit 3
    fi
    printf '%s: IN active cycle but board cycle=%s — flip to cycle:"sprint" in your state write\n' "$key" "$cur"
    exit 0
  else
    if [ "$cur" = "sprint" ]; then
      printf '%s: cycle:"sprint" but NO LONGER in the active cycle — do NOT demote; flag to the operator\n' "$key"
      exit 4
    fi
    printf '%s: cycle consistent (%s, not in active cycle) — no change\n' "$key" "$cur"
    exit 3
  fi
fi

# --- board-wide sweep (original mode) -------------------------------------------------
# On-board keys with any non-sprint cycle stamp (background = OUT OF CYCLE, backlog = parked).
bg_keys=$(jq -r '.tickets[] | select(.cycle != "sprint") | .ticket' "$STATE" | paste -sd, -)
if [ -z "$bg_keys" ]; then
  printf 'promote: none (no non-sprint-cycle tickets on the board)\n'
  exit 0
fi

# Of those, which does the tracker now place in the active cycle? Those are promotable.
in_cycle=$(tracker in_active_cycle "$bg_keys" | grep -v '^$' || true)
n=$(printf '%s' "$in_cycle" | grep -c . || true)
if [ "$n" -eq 0 ]; then
  printf 'promote: none (no non-sprint ticket has joined the active cycle)\n'
  exit 0
fi

# One batch call for the display status of just the promotable subset.
keys_csv=$(printf '%s' "$in_cycle" | paste -sd, -)
fields=$(tracker fields_of "$keys_csv")

printf 'promote: %s non-sprint ticket(s) now in the active cycle — PROMOTE to cycle=sprint (single-writer flip; moves them into the main table):\n' "$n"
printf '%s\n' "$in_cycle" | while IFS= read -r k; do
  [ -z "$k" ] && continue
  s=$(awk -F'\t' -v key="$k" '$1==key{print $2; exit}' <<EOF
$fields
EOF
)
  printf '  %s  —  %s\n' "$k" "$s"
done
