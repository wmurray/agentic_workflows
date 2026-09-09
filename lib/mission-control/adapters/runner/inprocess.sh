#!/usr/bin/env bash
# runner/inprocess.sh — runner adapter for workers that run as in-process subagents of
# the orchestrating session (the Agent tool). See ../CONTRACT.md "Runner adapter".
#
# Asymmetric on purpose: a script cannot make the Agent call — the orchestrating MODEL
# does. So `spawn` here does the deterministic half (names the worker, clears the result
# path, prints the handle) and the driver doctrine says "now make the Agent call with
# this name and this brief". Everything else is a plain file/marker protocol:
#
#   spawn <role> <ticket> <cwd> <brief-file> <result-file>  → handle
#   status <handle>            → running | done | gone
#   wait <handle> [timeout-ms] → exit 0 once the result file exists; 2 on timeout
#   harvest <handle>           → result-file JSON on stdout (empty if absent)
#   teardown <handle>          → removes the marker (the subagent exits on its own)
#   capabilities               → "" (no reuse: each spawn is a fresh subagent; not visible)
#
# Handle = "<worker-name>|inprocess|<marker-file>|<result-file>".
#
# The spawn marker (a file beside the result) is what makes `status` honest without a
# teammate list: marker present + no result = running; result present = done; neither =
# gone (never spawned, or torn down). The driver may still consult its own teammate list
# for liveness; this adapter never claims to know whether the subagent process is alive.
set -euo pipefail

op="${1:-}"; shift || true
die() { echo "runner/inprocess: $*" >&2; exit 1; }

h_name()   { printf '%s' "$1" | cut -d'|' -f1; }
h_marker() { printf '%s' "$1" | cut -d'|' -f3; }
h_result() { printf '%s' "$1" | cut -d'|' -f4; }

op_spawn() {
  local role="${1:?role}" ticket="${2:?ticket}" cwd="${3:?cwd}" brief="${4:?brief-file}" result="${5:?result-file}"
  shift 5
  while [ $# -gt 0 ]; do
    case "$1" in
      --reuse) die "spawn: inprocess has no reuse; spawn a fresh worker" ;;
      --model) shift 2 ;;   # accepted for symmetry; the Agent call carries the model
      *) die "spawn: unknown arg $1" ;;
    esac
  done
  [ -f "$brief" ] || die "spawn: brief not found: $brief"
  local name marker
  name="$(printf '%s-%s' "$role" "$ticket" | tr '[:upper:]' '[:lower:]')"
  marker="${result}.spawned"
  rm -f "$result"
  printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ) $name cwd=$cwd brief=$brief" > "$marker"
  printf '%s|inprocess|%s|%s\n' "$name" "$marker" "$result"
}

op_status() {
  local h="${1:?handle}"
  if [ -s "$(h_result "$h")" ]; then echo done
  elif [ -f "$(h_marker "$h")" ]; then echo running
  else echo gone; fi
}

op_wait() {
  local h="${1:?handle}" timeout_ms="${2:-}" deadline=""
  [ -n "$timeout_ms" ] && deadline=$(( $(date +%s) + timeout_ms / 1000 ))
  while [ ! -s "$(h_result "$h")" ]; do
    [ -f "$(h_marker "$h")" ] || return 0            # gone: nothing to wait for
    [ -n "$deadline" ] && [ "$(date +%s)" -ge "$deadline" ] && return 2
    sleep 5
  done
  return 0
}

op_harvest() {
  local f; f="$(h_result "${1:?handle}")"
  [ -s "$f" ] && cat "$f"
  return 0
}

op_teardown() { rm -f "$(h_marker "${1:?handle}")"; return 0; }

case "$op" in
  spawn)        op_spawn "$@" ;;
  status)       op_status "$@" ;;
  wait)         op_wait "$@" ;;
  harvest)      op_harvest "$@" ;;
  teardown)     op_teardown "$@" ;;
  capabilities) echo "" ;;
  *) die "unknown op: $op" ;;
esac
