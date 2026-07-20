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
