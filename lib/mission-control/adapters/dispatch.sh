#!/usr/bin/env bash
# dispatch.sh — sourced by engine scripts to route every provider call through the
# active adapter, so no engine script names a provider directly. See CONTRACT.md.
#
#   tracker <op> …  → $MC_ADAPTERS/tracker/${MC_TRACKER:-jira}.sh <op> …
#   host    <op> …  → $MC_ADAPTERS/host/${MC_HOST:-github}.sh    <op> …
#
# Provider selection (MC_TRACKER / MC_HOST) and the adapters dir (MC_ADAPTERS) are
# env-overridable — the profile sets them; the scratch harness can point elsewhere.

# This file lives in the adapters dir. Default MC_ADAPTERS to its own real location,
# resolving through any symlink (engine scripts symlinked into ~/.claude still find it).
if [ -z "${MC_ADAPTERS:-}" ]; then
  _mc_d="${BASH_SOURCE[0]}"
  while [ -L "$_mc_d" ]; do
    _mc_t="$(readlink "$_mc_d")"
    case "$_mc_t" in /*) _mc_d="$_mc_t" ;; *) _mc_d="$(dirname "$_mc_d")/$_mc_t" ;; esac
  done
  MC_ADAPTERS="$(cd "$(dirname "$_mc_d")" && pwd)"
  unset _mc_d _mc_t
fi

# Load the active profile (config vars) if present. MC_PROFILE selects the file;
# default = profiles/local.env (the local, gitignored profile), a sibling of the adapters
# dir. Absent (e.g. a fresh clone) → skipped, and engine scripts fall back to their own
# generic defaults. Profile lines use `export VAR="${VAR:-…}"`, so an explicit env value
# still wins and the vars reach adapter subprocesses.
_mc_profiles="$(dirname "$MC_ADAPTERS")/profiles"
MC_PROFILE="${MC_PROFILE:-$_mc_profiles/local.env}"
[ -f "$MC_PROFILE" ] && . "$MC_PROFILE"
unset _mc_profiles

tracker() { "$MC_ADAPTERS/tracker/${MC_TRACKER:-jira}.sh" "$@"; }
host()    { "$MC_ADAPTERS/host/${MC_HOST:-github}.sh"     "$@"; }

# runner: where a WORKER runs (in-process subagent vs. a visible herdr pane). Unlike
# tracker/host, the impl is chosen per call by (role, cycle) — see runner_for — so the
# dispatcher takes the impl name first: `runner herdr spawn …`, `runner inprocess status …`.
# A handle's first field after the name says which impl minted it (herdr handles carry a
# tab id; inprocess handles carry the literal "inprocess"), so `runner_of <handle>` routes
# status/wait/harvest/teardown without the caller remembering.
runner()     { "$MC_ADAPTERS/runner/${1}.sh" "${@:2}"; }
runner_for() { # runner_for <role> <cycle> → impl name from MC_RUNNER_<ROLE>[_<CYCLE>]
  local role cycle v1 v2
  role="$(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_')"
  cycle="$(printf '%s' "${2:-sprint}" | tr '[:lower:]-' '[:upper:]_')"
  v1="MC_RUNNER_${role}_${cycle}"; v2="MC_RUNNER_${role}"
  printf '%s\n' "${!v1:-${!v2:-inprocess}}"
}
runner_of()  { # runner_of <handle> → impl name that minted it
  case "$(printf '%s' "$1" | cut -d'|' -f2)" in inprocess) echo inprocess ;; *) echo herdr ;; esac
}
