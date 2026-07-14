#!/usr/bin/env bash
# mc-lock.sh — single-writer coordination for the mission-control board.
#
# At Step 3 the /loop driver becomes a WRITER of state.json. To keep it from racing
# a manual /mission-control session, both call this lock before writing. The HUMAN
# always wins: a manual session holds the lock while active; the loop yields its
# write-phase whenever the lock is held by a live owner. A heartbeat older than the
# TTL is considered stale (a crashed/closed session) and may be taken over, so a dead
# holder never freezes the loop permanently.
#
# It guards ONLY the lock file — it never touches state.json — so it's safe to build,
# test, and call freely. (Read-only Step-2 loop has no write-phase, so it doesn't
# call `check`/`acquire` yet; this is the primitive Step 3 turns on.)
#
# Lock file format (one line): "<owner>\t<epoch-seconds>"
#
#   mc-lock.sh status                 # human-readable state
#   mc-lock.sh check   <owner>        # exit 0 = <owner> MAY write (free/stale/mine); 1 = blocked
#   mc-lock.sh acquire <owner>        # take it (if free/stale/mine); exit 1 if held by another
#   mc-lock.sh refresh <owner>        # bump my heartbeat (call each turn while holding)
#   mc-lock.sh release <owner>        # drop it (only if I hold it)
#   Owners by convention: "manual" (a /mission-control session) · "loop" (the /loop driver)
#   Env: MC_LOCK (path), MC_LOCK_TTL (staleness seconds, default 900 = 15 min)
set -uo pipefail
LOCK="${MC_LOCK:-$HOME/.claude/mission-control/.writer-lock}"
TTL="${MC_LOCK_TTL:-900}"
op="${1:-status}"; owner="${2:-}"
now=$(date +%s)

cur=""; [ -f "$LOCK" ] && cur=$(head -1 "$LOCK" 2>/dev/null)
cur_owner=$(printf '%s' "$cur" | cut -f1)
cur_ts=$(printf '%s' "$cur" | cut -f2)
age=""; held_live=0
if [ -n "$cur_owner" ] && [ -n "$cur_ts" ]; then
  age=$((now - cur_ts))
  [ "$age" -lt "$TTL" ] && held_live=1
fi

need_owner() { [ -n "$owner" ] || { echo "mc-lock: '$op' needs <owner>" >&2; exit 2; }; }

case "$op" in
  status)
    if [ "$held_live" = "1" ]; then echo "held by '$cur_owner' (${age}s ago; TTL ${TTL}s)"
    elif [ -n "$cur_owner" ]; then echo "free (stale lock from '$cur_owner', ${age}s ago — takeable)"
    else echo "free"; fi ;;
  check)
    need_owner
    if [ "$held_live" = "1" ] && [ "$cur_owner" != "$owner" ]; then exit 1; else exit 0; fi ;;
  acquire)
    need_owner
    if [ "$held_live" = "1" ] && [ "$cur_owner" != "$owner" ]; then
      echo "mc-lock: DENIED — held by '$cur_owner' (${age}s ago)"; exit 1; fi
    printf '%s\t%s\n' "$owner" "$now" > "$LOCK"; echo "mc-lock: acquired by '$owner'"; exit 0 ;;
  refresh)
    need_owner
    if [ "$cur_owner" = "$owner" ] || [ "$held_live" != "1" ]; then
      printf '%s\t%s\n' "$owner" "$now" > "$LOCK"; echo "mc-lock: refreshed by '$owner'"; exit 0
    else echo "mc-lock: DENIED refresh — held by '$cur_owner'"; exit 1; fi ;;
  release)
    need_owner
    if [ "$cur_owner" = "$owner" ] || [ -z "$cur_owner" ]; then rm -f "$LOCK"; echo "mc-lock: released"; exit 0
    else echo "mc-lock: NOT releasing — '$cur_owner' holds it, not '$owner'"; exit 1; fi ;;
  *) echo "usage: mc-lock.sh {status|check <owner>|acquire <owner>|refresh <owner>|release <owner>}" >&2; exit 2 ;;
esac
