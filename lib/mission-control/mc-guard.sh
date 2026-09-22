#!/usr/bin/env bash
# mc-guard.sh — a structural refusal for manual-only pipeline wrappers.
#
# The loop driver is TOLD (in prose) never to run the merge, qa and done wrappers. The
# harness allow-list cannot enforce that: the loop session reads the same settings file
# as a manual session, so anything allow-listed for one is allowed for both. This script
# makes the boundary mechanical. A manual-only wrapper calls `check` first; if the loop
# currently holds the writer lock (`mc-lock.sh`, owner "loop", heartbeat within TTL) the
# wrapper exits 4 before doing anything. The loop announces itself by taking that lock
# before every write, so the check needs no cooperation from the model.
#
# It is configurable so a human can test or override deliberately:
#   $MC_HOME/LOOP_GUARD_OFF exists  → guard disabled for every caller (`mc guard off`)
#   MC_LOOP_GUARD=off in the env    → disabled for that one invocation
# Either way the wrapper prints that the guard is off, so an override is never silent.
#
#   mc-guard.sh check <wrapper-name>   # exit 0 = proceed · 4 = refused · 2 = usage
#   mc-guard.sh status                 # human-readable: on/off + who holds the lock
#   mc-guard.sh on | off               # create / remove the LOOP_GUARD_OFF marker
# Env: MC_HOME (runtime dir) · MC_GUARD_OFF_FILE (marker path) · MC_LOCK / MC_LOCK_TTL (as mc-lock.sh)
set -uo pipefail

# Resolve through the runtime-dir symlink so mc-lock.sh is found beside the REAL file.
_src="${BASH_SOURCE[0]}"; while [ -L "$_src" ]; do _src="$(readlink "$_src")"; done
_here="$(cd "$(dirname "$_src")" && pwd)"
LOCK_SH="$_here/mc-lock.sh"
MC_DIR="${MC_HOME:-$HOME/.claude/mission-control}"
OFF_FILE="${MC_GUARD_OFF_FILE:-$MC_DIR/LOOP_GUARD_OFF}"
LOCK="${MC_LOCK:-$MC_DIR/.writer-lock}"
export MC_LOCK="$LOCK"

op="${1:-status}"; name="${2:-}"

_disabled() { [ "${MC_LOOP_GUARD:-on}" = "off" ] || [ -f "$OFF_FILE" ]; }
_holder()   { [ -f "$LOCK" ] && head -1 "$LOCK" | cut -f1; }

case "$op" in
  check)
    [ -n "$name" ] || { echo "mc-guard: check needs <wrapper-name>" >&2; exit 2; }
    if _disabled; then
      echo "mc-guard: ⚠ loop guard is OFF — $name runs unguarded ($( [ -f "$OFF_FILE" ] && echo "marker $OFF_FILE" || echo "MC_LOOP_GUARD=off" ))" >&2
      exit 0
    fi
    # `check manual` exits 1 only when a LIVE lock is held by someone other than manual,
    # i.e. the loop (stale locks and manual's own lock pass). Reuses mc-lock's TTL logic.
    if "$LOCK_SH" check manual; then exit 0; fi
    echo "mc-guard: ⛔ REFUSED — $name is manual-only and the writer lock is held by '$(_holder)'." >&2
    echo "          The loop must never run this wrapper. To override for a test: \`mc guard off\` (marker) or MC_LOOP_GUARD=off (one shot)." >&2
    exit 4 ;;
  status)
    if _disabled; then echo "loop guard: OFF ($( [ -f "$OFF_FILE" ] && echo "marker $OFF_FILE" || echo "MC_LOOP_GUARD=off" ))"
    else echo "loop guard: ON"; fi
    echo "writer lock: $("$LOCK_SH" status)" ;;
  on)  rm -f "$OFF_FILE"; echo "mc-guard: loop guard ON — manual-only wrappers refuse while the loop holds the writer lock." ;;
  off) printf 'LOOP_GUARD_OFF %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" > "$OFF_FILE"
       echo "mc-guard: ⚠ loop guard OFF ($OFF_FILE) — manual-only wrappers run unguarded until \`mc guard on\`." ;;
  *) echo "usage: mc-guard.sh {check <wrapper-name>|status|on|off}" >&2; exit 2 ;;
esac
