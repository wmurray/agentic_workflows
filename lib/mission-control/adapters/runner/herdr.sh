#!/usr/bin/env bash
# runner/herdr.sh — runner adapter that hosts a worker in a visible herdr pane running an
# interactive claude session. See ../CONTRACT.md "Runner adapter" and DESIGN.md.
#
#   spawn <role> <ticket> <cwd> <brief-file> <result-file> [--reuse <handle>] [--model <m>]
#   status <handle>            → running | idle | done | blocked | gone
#   wait <handle> [timeout-ms] → exit 0 when settled (not running); 2 on timeout
#   harvest <handle>           → result-file JSON on stdout (empty if absent)
#   teardown <handle>          → closes the tab
#   list                       → "<name>\t<status>\t<tab_id>" per agent in the configured workspaces
#   capabilities               → "reuse visible answer"
#
# Handle = "<agent-name>|<tab_id>|<pane_id>|<result-file>". Opaque to callers.
#
# Env (profile-set, all optional except the workspace for spawn):
#   MC_HERDR_WS_SPRINT / MC_HERDR_WS_BACKGROUND  workspace ids; MC_CYCLE picks which
#   MC_HERDR_WORKSPACE                           explicit override of the above
#   MC_HERDR_SETTLE_S                            debounce after wait returns (default 20)
#   MC_HERDR_START_TIMEOUT_MS                    agent start readiness (default 60000)
#   MC_MODEL_<ROLE>                              model per role (e.g. MC_MODEL_CODER=opus)
set -euo pipefail

op="${1:-}"; shift || true

die() { echo "runner/herdr: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }
need herdr; need python3

# --- handle helpers -------------------------------------------------------------------
h_name()   { printf '%s' "$1" | cut -d'|' -f1; }
h_tab()    { printf '%s' "$1" | cut -d'|' -f2; }
h_pane()   { printf '%s' "$1" | cut -d'|' -f3; }
h_result() { printf '%s' "$1" | cut -d'|' -f4; }

# herdr prints one JSON object per call; errors come back as {"error":{...}} with exit 0.
hj() { herdr "$@" 2>/dev/null || true; }
jget() { # jget '<python expr on d>' <<< json ; prints "" on any failure
  python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); print(eval(sys.argv[1]))
except Exception: print("")' "$1"
}

agent_status() { # raw herdr status or "gone"
  local out st
  out="$(hj agent get "$1")"
  st="$(jget 'd["result"]["agent"]["agent_status"]' <<<"$out")"
  [ -n "$st" ] && printf '%s' "$st" || printf 'gone'
}

# Map herdr's vocabulary onto the contract's. herdr: idle|working|blocked|done|unknown.
normalize() {
  case "$1" in
    working) echo running ;;
    idle)    echo idle ;;
    done)    echo done ;;
    blocked) echo blocked ;;
    gone)    echo gone ;;
    *)       echo idle ;;   # unknown → treat as settled; the result file decides
  esac
}

# --- ops -----------------------------------------------------------------------------
op_spawn() {
  local role="${1:?role}" ticket="${2:?ticket}" cwd="${3:?cwd}" brief="${4:?brief-file}" result="${5:?result-file}"
  shift 5
  local reuse="" model=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --reuse) reuse="$2"; shift 2 ;;
      --model) model="$2"; shift 2 ;;
      *) die "spawn: unknown arg $1" ;;
    esac
  done
  [ -f "$brief" ] || die "spawn: brief not found: $brief"
  [ -d "$cwd" ]   || die "spawn: cwd not found: $cwd"

  # Reuse: the author session already exists; re-prompt it and hand back the same handle
  # with the new result path.
  if [ -n "$reuse" ]; then
    local name; name="$(h_name "$reuse")"
    [ "$(agent_status "$name")" = gone ] && die "spawn --reuse: agent $name is gone"
    rm -f "$result"
    hj agent prompt "$name" "$(cat "$brief")" >/dev/null
    printf '%s|%s|%s|%s\n' "$name" "$(h_tab "$reuse")" "$(h_pane "$reuse")" "$result"
    return 0
  fi

  # Workspace: explicit override, else by cycle.
  local ws="${MC_HERDR_WORKSPACE:-}"
  if [ -z "$ws" ]; then
    case "${MC_CYCLE:-sprint}" in
      background) ws="${MC_HERDR_WS_BACKGROUND:-}" ;;
      *)          ws="${MC_HERDR_WS_SPRINT:-}" ;;
    esac
  fi
  [ -n "$ws" ] || die "spawn: no herdr workspace configured for cycle '${MC_CYCLE:-sprint}' (set MC_HERDR_WS_SPRINT / MC_HERDR_WS_BACKGROUND)"

  # Model: --model wins, else MC_MODEL_<ROLE>, else the session default.
  if [ -z "$model" ]; then
    local var; var="MC_MODEL_$(printf '%s' "$role" | tr '[:lower:]-' '[:upper:]_')"
    model="${!var:-}"
  fi

  # Agent names must be lowercase, no dots. Ticket keys like ABC-1234 → abc-1234.
  local name; name="$(printf '%s-%s' "$role" "$ticket" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-\n' '-')"

  # 1. tab, cwd pinned to the worktree (gotcha f: never the monorepo root). tab_created
  #    carries root_pane, so no second lookup is needed.
  local out tab pane
  out="$(hj tab create --workspace "$ws" --cwd "$cwd" --label "$name" --no-focus)"
  tab="$(jget 'd["result"]["tab"]["tab_id"]' <<<"$out")"
  pane="$(jget 'd["result"]["root_pane"]["pane_id"]' <<<"$out")"
  [ -n "$tab" ] && [ -n "$pane" ] || die "spawn: tab create failed: $out"

  # 2. start claude in the pane. The pane must be at its shell prompt; a just-created tab
  #    can take a second to get there, so retry a few times before giving up.
  local -a start_args=(--name "$name")
  [ -n "$model" ] && start_args+=(--model "$model")
  local try err=""
  for try in 1 2 3 4 5; do
    sleep 1
    err="$(herdr agent start "$name" --kind claude --pane "$pane" --timeout "${MC_HERDR_START_TIMEOUT_MS:-60000}" -- "${start_args[@]}" 2>&1 >/dev/null || true)"
    [ "$(agent_status "$name")" != gone ] && break
  done
  if [ "$(agent_status "$name")" = gone ]; then
    hj tab close "$tab" >/dev/null
    die "spawn: agent start failed after $try tries: ${err:-(no output)}"
  fi

  # 3. startup dialogs. A cwd this machine's claude has not opened before shows the
  #    workspace-trust prompt with "No, exit" preselected; a brief pasted onto it takes that
  #    default and kills the session (observed 2026-09-09). The cwd is a worktree the loop
  #    cut itself, so trusting it is the settled answer. Anything else that blocks startup
  #    is left for the operator and reported.
  local st
  for try in $(seq 1 20); do
    st="$(agent_status "$name")"
    case "$st" in
      idle|done) break ;;
      blocked)
        if op_peek "$name|$tab|$pane|" 30 | grep -q "trust this folder"; then
          hj agent send-keys "$name" down enter >/dev/null
        fi ;;
      gone) hj tab close "$tab" >/dev/null; die "spawn: agent $name exited during startup" ;;
    esac
    sleep 2
  done
  [ "$st" = blocked ] && echo "runner/herdr: spawn: $name is blocked at startup on something other than the trust prompt; prompting anyway" >&2

  # 4. brief from a file (dodges quoting); the template already names the result path.
  rm -f "$result"
  hj agent prompt "$name" "$(cat "$brief")" >/dev/null

  printf '%s|%s|%s|%s\n' "$name" "$tab" "$pane" "$result"
}

op_status() {
  local h="${1:?handle}"
  normalize "$(agent_status "$(h_name "$h")")"
}

# wait: block until the agent is not running, then debounce — herdr reports transient
# idle/done between a main agent's subagent turns (spike finding). Accept a settled state
# only if it survives MC_HERDR_SETTLE_S seconds. A present result file short-circuits.
op_wait() {
  local h="${1:?handle}" timeout_ms="${2:-}"
  local name settle deadline st st2
  name="$(h_name "$h")"; settle="${MC_HERDR_SETTLE_S:-20}"
  [ -n "$timeout_ms" ] && deadline=$(( $(date +%s) + timeout_ms / 1000 )) || deadline=""
  while :; do
    if [ -n "$deadline" ]; then
      local left=$(( deadline - $(date +%s) ))
      [ "$left" -le 0 ] && return 2
      hj agent wait "$name" --timeout "$(( left * 1000 ))" >/dev/null
    else
      hj agent wait "$name" >/dev/null
    fi
    st="$(agent_status "$name")"
    [ "$st" = gone ] && return 0
    [ -n "$(h_result "$h")" ] && [ -s "$(h_result "$h")" ] && return 0
    sleep "$settle"
    st2="$(agent_status "$name")"
    case "$st2" in
      working) continue ;;             # transient; re-arm
      *) return 0 ;;
    esac
  done
}

op_harvest() {
  local h="${1:?handle}" f; f="$(h_result "$h")"
  [ -n "$f" ] && [ -s "$f" ] && cat "$f"
  return 0
}

op_teardown() {
  local h="${1:?handle}" tab; tab="$(h_tab "$h")"
  [ -n "$tab" ] && hj tab close "$tab" >/dev/null
  return 0
}

# answer: press keys at a settled prompt (plan approval, a hook confirmation). The
# ORCHESTRATOR decides whether the answer is settled — see DESIGN.md "Console capability".
op_answer() {
  local h="${1:?handle}"; shift
  [ $# -gt 0 ] || die "answer: no keys"
  hj agent send-keys "$(h_name "$h")" "$@" >/dev/null
}

# peek: last N visible lines of the pane, diagnostics only (never parse intent from it —
# ghost-text prompt suggestions appear in reads).
op_peek() {
  local h="${1:?handle}" n="${2:-40}"
  herdr agent read "$(h_name "$h")" --source visible 2>/dev/null | tail -n "$n" || true
}

# list: every agent this impl can see in the configured workspaces, "<name>\t<status>\t<tab_id>"
# per line. mc-orphans subtracts the board's runner handles from this to find sessions
# nothing is tracking. Read-only.
op_list() {
  local wss out
  wss="$(printf '%s\n' ${MC_HERDR_WORKSPACE:-} ${MC_HERDR_WS_SPRINT:-} ${MC_HERDR_WS_BACKGROUND:-} | awk 'NF && !seen[$0]++' | paste -sd, -)"
  [ -n "$wss" ] || return 0
  out="$(hj agent list)"
  python3 -c 'import json,sys
wss=set(sys.argv[1].split(","))
try:
    for a in json.load(sys.stdin)["result"]["agents"]:
        if a.get("workspace_id") in wss and a.get("name"):
            print("\t".join([a["name"], a.get("agent_status","unknown"), a.get("tab_id","")]))
except Exception: pass' "$wss" <<<"$out"
}

case "$op" in
  spawn)        op_spawn "$@" ;;
  list)         op_list "$@" ;;
  status)       op_status "$@" ;;
  wait)         op_wait "$@" ;;
  harvest)      op_harvest "$@" ;;
  teardown)     op_teardown "$@" ;;
  answer)       op_answer "$@" ;;
  peek)         op_peek "$@" ;;
  capabilities) echo "reuse visible answer" ;;
  *) die "unknown op: $op" ;;
esac
