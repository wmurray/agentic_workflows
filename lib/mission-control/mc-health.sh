#!/usr/bin/env bash
# mc-health.sh — read-only host credential/reachability probe for mission-control.
#
# The unattended loop fails SILENTLY on an expired token: calls start missing, the
# board goes stale, and nothing says why. This probe gives the loop a fact to surface.
# It writes NOTHING — it prints a health JSON blob; the LOOP records it into
# `state.json.health` and the dash renders a banner from it.
#
# SCOPE: the PR HOST only (via the host adapter's `whoami`). The TRACKER is deliberately
# NOT probed here: a scoped tracker API token often has no reliable auth-gated read
# endpoint (endpoints 404-mask, or public-fall-back to 200 on a bad token), and a
# synthetic tracker probe proved UNRELIABLE — it false-flagged `unreachable` while the
# real read path (mc-poll's batched `fields_of`) was fine. So the FAITHFUL tracker signal
# is the loop's own mc-poll: if it returns and every tracker column is a miss across the
# board, the tracker is blind — the loop sets `health.jira` from THAT (see loop-driver
# "Health + heartbeat"). This script owns only the host half.
#
# The load-bearing distinction: AUTH (401 → a human must refresh the token) vs
# UNREACHABLE (network / timeout → transient, retry). Conflating them cries wolf.
#
# Output: {"github":"ok|auth|unreachable","checked_at":"<iso>","detail":"..."}
#   (the "github" key is retained for the current loop/dash consumers; genericizing the
#    health schema to a provider-neutral "host" key is deferred to the vocab/doctrine pass.)
# Exit: 0 ok · 10 host AUTH (human action needed) · 11 host UNREACHABLE (transient)
set -uo pipefail

# --- adapter dispatch (resolve this script's real dir through any symlink) ---
_mc_self="${BASH_SOURCE[0]}"
while [ -L "$_mc_self" ]; do
  _mc_ln="$(readlink "$_mc_self")"
  case "$_mc_ln" in /*) _mc_self="$_mc_ln" ;; *) _mc_self="$(dirname "$_mc_self")/$_mc_ln" ;; esac
done
_MC_LIB="$(cd "$(dirname "$_mc_self")" && pwd)"
. "$_MC_LIB/adapters/dispatch.sh"

now_iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# _bounded <secs> <cmd...> — run a command with a HARD wall-clock cap, portably (no
# dependency on coreutils `timeout`, which macOS lacks). Sets: B_RC (exit code),
# B_OUT (combined stdout+stderr), B_TIMEOUT (1 if we had to kill it). A probe must
# NEVER hang the loop's tick — a hung call is treated as `unreachable`, not `auth`.
_bounded() {
  local secs=$1; shift
  local tmp; tmp=$(mktemp)
  "$@" >"$tmp" 2>&1 & local pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null; sleep 2; kill -KILL "$pid" 2>/dev/null ) & local w=$!
  wait "$pid" 2>/dev/null; B_RC=$?
  kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
  B_OUT=$(cat "$tmp"); rm -f "$tmp"
  [ "$B_RC" -ge 128 ] && B_TIMEOUT=1 || B_TIMEOUT=0   # >=128 = killed by signal (SIGTERM→143)
}

# --- host auth/reachability probe (bounded) ---
detail=""
_bounded 12 host whoami
if [ "$B_TIMEOUT" -eq 1 ]; then
  github=unreachable; detail="host: unreachable (probe timed out)"
elif [ "$B_RC" -eq 0 ]; then
  github=ok;          detail="all ok"
elif printf '%s' "$B_OUT" | grep -qiE '401|Bad credentials|authentication|auth login|requires authentication'; then
  github=auth;        detail="host: auth (401/bad credentials)"
else
  github=unreachable; detail="host: unreachable ($(printf '%s' "$B_OUT" | head -1))"
fi

printf '{"github":"%s","checked_at":"%s","detail":"%s"}\n' "$github" "$now_iso" "$detail"

case "$github" in
  auth)        exit 10 ;;
  unreachable) exit 11 ;;
  *)           exit 0  ;;
esac
