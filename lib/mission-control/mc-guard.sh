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
# It is configurable so a human can test or override deliberately, per wrapper or all:
#   $MC_HOME/LOOP_GUARD_OFF             → one wrapper name per line, or `*` for every wrapper
#                                         (`mc guard off [name…]` writes it, `mc guard on [name…]` trims it)
#   MC_LOOP_GUARD=off in the env        → disabled for that one invocation
# Either way the wrapper prints that the guard is off, so an override is never silent.
#
#   mc-guard.sh check <wrapper-name>    # exit 0 = proceed · 4 = refused · 2 = usage
#   mc-guard.sh status                  # human-readable: on / off-for-what + who holds the lock
#   mc-guard.sh off [name…]             # disable for the named wrappers (none = all, writes `*`)
#   mc-guard.sh on  [name…]             # re-enable the named wrappers (none = all, removes the marker)
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

op="${1:-status}"; shift || true; name="${1:-}"

# Marker semantics: a line `*` disables every wrapper; a bare name disables that one.
# `#` lines and blanks are ignored, so a legacy header-only marker reads as "nothing off".
_off_list() { [ -f "$OFF_FILE" ] && grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$OFF_FILE" | sort -u; }
_off_for()  { _off_list | grep -qx -e '\*' -e "$1"; }
_disabled() { [ "${MC_LOOP_GUARD:-on}" = "off" ] || _off_for "$1"; }
_holder()   { [ -f "$LOCK" ] && head -1 "$LOCK" | cut -f1; }
_why_off()  { if [ "${MC_LOOP_GUARD:-on}" = "off" ]; then echo "MC_LOOP_GUARD=off"; elif _off_list | grep -qx '\*'; then echo "marker: all"; else echo "marker: $1"; fi; }

case "$op" in
  check)
    [ -n "$name" ] || { echo "mc-guard: check needs <wrapper-name>" >&2; exit 2; }
    if _disabled "$name"; then
      echo "mc-guard: ⚠ loop guard is OFF for $name — runs unguarded ($(_why_off "$name"))" >&2
      exit 0
    fi
    # `check manual` exits 1 only when a LIVE lock is held by someone other than manual,
    # i.e. the loop (stale locks and manual's own lock pass). Reuses mc-lock's TTL logic.
    if "$LOCK_SH" check manual; then exit 0; fi
    echo "mc-guard: ⛔ REFUSED — $name is manual-only and the writer lock is held by '$(_holder)'." >&2
    echo "          The loop must never run this wrapper. To override for a test: \`mc guard off\` (marker) or MC_LOOP_GUARD=off (one shot)." >&2
    exit 4 ;;
  status)
    if [ "${MC_LOOP_GUARD:-on}" = "off" ]; then echo "loop guard: OFF for this shell (MC_LOOP_GUARD=off)"
    elif _off_list | grep -qx '\*'; then echo "loop guard: OFF for ALL wrappers ($OFF_FILE)"
    elif [ -n "$(_off_list)" ]; then echo "loop guard: OFF for: $(_off_list | tr '\n' ' ')($OFF_FILE)"
    else echo "loop guard: ON"; fi
    echo "writer lock: $("$LOCK_SH" status)" ;;
  on)
    if [ "$#" -eq 0 ]; then rm -f "$OFF_FILE"; echo "mc-guard: loop guard ON for all wrappers."; exit 0; fi
    if [ -f "$OFF_FILE" ]; then
      keep="$(_off_list)"; for n in "$@"; do keep="$(printf '%s\n' "$keep" | grep -vx -- "$n" || true)"; done
      if [ -z "$keep" ]; then rm -f "$OFF_FILE"; else printf '# LOOP_GUARD_OFF — one wrapper per line, * = all\n%s\n' "$keep" > "$OFF_FILE"; fi
    fi
    echo "mc-guard: loop guard ON for: $*" ;;
  off)
    { [ -f "$OFF_FILE" ] && _off_list; if [ "$#" -eq 0 ]; then echo '*'; else printf '%s\n' "$@"; fi; } | sort -u > "$OFF_FILE.tmp"
    { printf '# LOOP_GUARD_OFF — one wrapper per line, * = all (%s)\n' "$(date '+%Y-%m-%dT%H:%M:%S')"; cat "$OFF_FILE.tmp"; } > "$OFF_FILE"; rm -f "$OFF_FILE.tmp"
    if [ "$#" -eq 0 ]; then echo "mc-guard: ⚠ loop guard OFF for ALL wrappers ($OFF_FILE) — until \`mc guard on\`."
    else echo "mc-guard: ⚠ loop guard OFF for: $* ($OFF_FILE) — until \`mc guard on $*\`."; fi ;;
  *) echo "usage: mc-guard.sh {check <wrapper-name>|status|on [name…]|off [name…]}" >&2; exit 2 ;;
esac
