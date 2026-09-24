#!/usr/bin/env bash
# mc-archive.sh — cycle-rollover archival for the mission-control board.
#
# Detects when the tracker's active cycle (sprint/iteration) has CHANGED since the last
# archive and, on `--commit`, moves all `done` tickets out of state.json into
# state.archive.json (preserving the shipped-work audit trail: release notes, PR links,
# result lines) so the live board stays lean. The "last archived" cycle lives in a SIDECAR
# marker file — detection never reads/writes state.json, so the read-only check is
# race-free and safe for the loop to run every tick.
#
# Symmetry with mc-inbound.sh: inbound pulls the NEW cycle's committed work IN at
# kickoff; archive pushes the OLD cycle's shipped work OUT at rollover. Together the
# board auto-rotates with the cycle.
#
# Marker format: `id⇥name` (TAB-separated) — the id drives rollover detection, the name
# is what `archivedAtSprint` is stamped with, so archive never needs a historical
# cycle-id→name lookup from the tracker (see adapters/CONTRACT.md `active_cycle`). A
# legacy id-only marker is read as an id with no name and is upgraded on the next commit.
#
# Modes:
#   (default) / --check   READ-ONLY. Prints the active cycle, the marker, whether an
#                         archive is DUE (cycle changed), and how many `done` tickets
#                         would move. Writes nothing. Safe anywhere.
#   --commit              Performs the archive: done → state.archive.json, rewrites
#                         state.json without them, stamps the marker with the active
#                         cycle. A state.json WRITE — run ONLY as the single writer (the
#                         manual orchestrator, or the loop). Never run concurrently with
#                         another writing session.
#   --force               With --commit, archive even if not "due" (manual boundary).
#
#   ~/.claude/mission-control/mc-archive.sh            # check (read-only)
#   ~/.claude/mission-control/mc-archive.sh --commit   # do it (single-writer only)
#   MC_STATE=… MC_ARCHIVE=… MC_CYCLE_MARKER=… (overridable for the scratch harness)
#
# On a tracker WITHOUT the `cycles` capability there is no rollover to detect, so
# `--check` never reports DUE and `--commit` archives only under `--force` (the human
# picks the boundary). Everything else behaves identically.
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
ARCHIVE="${MC_ARCHIVE:-${STATE%.json}.archive.json}"
MARKER="${MC_CYCLE_MARKER:-${MC_SPRINT_MARKER:-$HOME/.claude/mission-control/.last-archived-sprint}}"
# Statuses that mean SHIPPED (the pre-sweep guard below). Space-separated in the profile.
TERMINAL_DONE="${MC_TERMINAL_DONE:-Done Closed Released Resolved}"

mode="check"; force=0
for a in "$@"; do
  case "$a" in
    --check)  mode="check" ;;
    --commit) mode="commit" ;;
    --force)  force=1 ;;
    *) echo "mc-archive: unknown arg '$a'" >&2; exit 2 ;;
  esac
done

[ -f "$STATE" ] || { echo "mc-archive: no state at $STATE" >&2; exit 1; }

# --- the active cycle, from the tracker adapter (id⇥name; empty when cycle-less) ---
has_cycles=0
case " $(tracker capabilities 2>/dev/null) " in *" cycles "*) has_cycles=1 ;; esac

active_id=""; active_name=""
if [ "$has_cycles" = "1" ]; then
  IFS=$'\t' read -r active_id active_name < <(tracker active_cycle) || true
  [ -z "$active_id" ] && { echo "mc-archive: no active cycle found (tracker reachable?)" >&2; exit 1; }
fi

# --- the marker: `id⇥name` (legacy: bare id, no name) ---
marked_id=""; marked_name=""
if [ -f "$MARKER" ]; then
  IFS=$'\t' read -r marked_id marked_name < "$MARKER" || true
  marked_id=$(printf '%s' "${marked_id:-}" | tr -d '[:space:]')
  marked_name=$(printf '%s' "${marked_name:-}" | sed 's/[[:space:]]*$//')
fi

# The cycle whose work is being archived is the one the MARKER points at — the tickets on
# the board were completed under it, not under the newly-active cycle. The marker carries
# its own name, so no historical lookup is needed. Fall back to the active name only when
# the marker has no name (first run, or a legacy id-only marker).
archive_cycle="$marked_name"
[ -z "$archive_cycle" ] && archive_cycle="$active_name"

done_n=$(jq '[.tickets[] | select(.lane=="done")] | length' "$STATE")

due=0
[ "$has_cycles" = "1" ] && [ "$active_id" != "$marked_id" ] && due=1

if [ "$mode" = "check" ]; then
  if [ "$due" = "1" ]; then
    printf 'archive DUE: active cycle %s (%s) ≠ last-archived %s — %s done ticket(s) to archive (run --commit).\n' \
      "$active_id" "$active_name" "${marked_id:-<none>}" "$done_n"
  elif [ "$has_cycles" != "1" ]; then
    printf 'archive: tracker has no cycles — rollover cannot be detected; %s done on board (use --commit --force at a boundary you pick).\n' "$done_n"
  else
    printf 'archive: up to date (active cycle %s = last-archived; %s done on board).\n' "$active_id" "$done_n"
  fi
  exit 0
fi

# --- commit: single-writer only ---
if [ "$due" != "1" ] && [ "$force" != "1" ]; then
  if [ "$has_cycles" = "1" ]; then
    printf 'mc-archive: not due (active cycle %s already archived). Use --force to archive anyway.\n' "$active_id"
  else
    printf 'mc-archive: tracker has no cycles — nothing to detect. Use --force to archive at a boundary you pick.\n'
  fi
  exit 0
fi

now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
[ -f "$ARCHIVE" ] || echo '[]' > "$ARCHIVE"

# --- pre-sweep tracker guard: archive only tickets the tracker actually calls DONE ---
# Archive trusts the board lane. But a review/post-merge kickback landing right at rollover
# can leave a ticket in `done` on the board while the tracker sits at a non-done status —
# archiving it then would file un-shipped or reopened work into the shipped-work audit
# trail. A truly-shipped ticket is at one of $MC_TERMINAL_DONE; intermediate review
# statuses are NOT done. So re-check the live tracker for the done set and archive ONLY the
# terminal-done ones; HOLD everything else (a kickback to dev, or a board row marked done
# ahead of the tracker). A tracker-miss (unknown status) is UNVERIFIED, not held — archive
# it on board-lane trust (don't strand shipped work on a blind tracker) but say so.
done_keys=$(jq -r '.tickets[] | select(.lane=="done") | .ticket' "$STATE" | paste -sd, -)
tstat_tmp=$(mktemp)
[ -n "$done_keys" ] && tracker fields_of "$done_keys" > "$tstat_tmp" || true
# _is_terminal — exact match of a status against the space-separated $TERMINAL_DONE list.
_is_terminal() {
  local s="$1" t
  for t in $TERMINAL_DONE; do [ "$s" = "$t" ] && return 0; done
  return 1
}
held_keys=""; unverified=""
for k in $(jq -r '.tickets[] | select(.lane=="done") | .ticket' "$STATE"); do
  st=$(awk -F'\t' -v key="$k" '$1==key{print $2; exit}' "$tstat_tmp")
  if   [ -z "$st" ];        then unverified="$unverified $k"   # tracker-miss → archive on trust
  elif _is_terminal "$st";  then :                             # terminal done → archive
  else                           held_keys="$held_keys $k"     # anything else → HOLD
  fi
done
rm -f "$tstat_tmp"
held_json=$(jq -cn --arg s "$held_keys" '($s|split(" ")|map(select(length>0)))')
held_n=$(printf '%s' "$held_json" | jq 'length')

# Append the VERIFIED done tickets (done AND not held) — stamped with the cycle whose
# work this represents (`archive_cycle`, the marker's cycle), NOT the newly-active one.
tmp_arch=$(mktemp)
jq --slurpfile st "$STATE" --arg sprint "${archive_cycle}" --arg at "$now" --argjson held "$held_json" '
  . + ($st[0].tickets
        | map(select(.lane=="done" and ((.ticket) as $t | $held | index($t) | not)))
        | map(. + {archivedAt: $at, archivedAtSprint: $sprint}))' "$ARCHIVE" > "$tmp_arch" \
  && mv "$tmp_arch" "$ARCHIVE"

# Rewrite state.json: drop the archived (verified) done tickets; KEEP the held ones on
# the board, flagged (blocked + question) so the dash surfaces them in NEEDS YOU rather
# than letting a rollover-time kickback vanish. Bump top-level updated.
tmp_state=$(mktemp)
jq --arg at "$now" --argjson held "$held_json" '
  .tickets |= (
      map(if (.lane=="done" and ((.ticket) as $t | $held | index($t)))
            then . + {blocked: true,
                      question: ("[HOLD] board done but tracker NOT at a terminal Done status at cycle rollover — HELD from archive (not shipped, or kicked back). Confirm it shipped or reconcile. (auto-flagged " + $at + ")")}
          else . end)
    | map(select( (.lane=="done" and ((.ticket) as $t | $held | index($t) | not)) | not )))
  | .updated = $at' "$STATE" > "$tmp_state" \
  && mv "$tmp_state" "$STATE"

# Stamp the marker with the now-archived-through cycle, `id⇥name`, so this rollover
# doesn't re-fire and the NEXT archive knows which cycle's work it is sweeping. On a
# cycle-less tracker there is no cycle to stamp (and nothing to re-fire) — leave it alone.
archived_n=$(( done_n - held_n ))
if [ "$has_cycles" = "1" ]; then
  printf '%s\t%s\n' "$active_id" "$active_name" > "$MARKER"
  printf 'mc-archive: archived %s done ticket(s) → %s; state.json trimmed; marker → %s (%s).\n' \
    "$archived_n" "$ARCHIVE" "$active_id" "$active_name"
else
  printf 'mc-archive: archived %s done ticket(s) → %s; state.json trimmed; no marker stamped (tracker has no cycles).\n' \
    "$archived_n" "$ARCHIVE"
fi
[ "$held_n" -gt 0 ] && printf 'mc-archive: ⚠ HELD %s ticket(s) on the board — board `done` but tracker not at a terminal Done status (didn'\''t ship / kicked back):%s — flagged for reconcile.\n' \
  "$held_n" "$held_keys"
[ -n "$unverified" ] && printf 'mc-archive: note — tracker status UNVERIFIED for%s (tracker-miss); archived on board-lane trust.\n' "$unverified"
