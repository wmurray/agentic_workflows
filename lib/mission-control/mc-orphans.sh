#!/usr/bin/env bash
# mc-orphans.sh — the "orphan PR" reconcile check. Lists OPEN PRs in the watched
# repos that are NOT tracked on the board AND carry NO ticket key: the rare
# chore / dep-bump / hotfix / revert opened straight on the host without a tracker
# ticket. Read-only — a sibling of mc-poll.sh for the reconcile pass.
#
# The board-scoped poller (mc-poll.sh) can't see these — it only queries PRs that a
# state.json ticket already references. Orphans are by definition off the board, so
# this does an UNSCOPED open-PR sweep per repo and subtracts what's tracked/ticketed.
#
# Orphan = open PR whose URL is not the `.pr` of any state.json ticket AND whose
# title+branch match no ticket key ($MC_TICKET_KEY_REGEX). (A PR that HAS a ticket ref
# but is missing from the board is a different signal — a ticketed-but-untracked PR —
# deliberately NOT reported here, so the two never get conflated.)
#
# Scope: by default only PRs I authored (the ones I must shepherd). Set MC_ORPHAN_ALL=1
# to include every author (e.g. dependabot bumps). Override the repo set with
# MC_REPOS="owner/a owner/b"; honors MC_STATE like the other scripts.
#
# Repos + key shape come from the profile (MC_REPOS, MC_TICKET_KEY_REGEX); the PR list
# from the host adapter (list_prs). Host-agnostic — no host named here.
#
#   ~/.claude/mission-control/mc-orphans.sh
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
REPOS="${MC_REPOS:-your-org/repo-a your-org/repo-b}"
KEY_RE="${MC_TICKET_KEY_REGEX:-[A-Z]+-[0-9]+}"
[ -f "$STATE" ] || { echo "no state at $STATE" >&2; exit 1; }

# PR URLs already tracked on the board (one per line).
board=$(jq -r '.tickets[] | select(.pr != null) | .pr' "$STATE" 2>/dev/null || true)

all=""
for repo in $REPOS; do
  # MC_ORPHAN_ALL=1 → every author; default → only mine.
  if [ "${MC_ORPHAN_ALL:-0}" = "1" ]; then
    data=$(host list_prs "$repo" open)
  else
    data=$(host list_prs "$repo" open mine)
  fi
  [ -z "$data" ] && continue
  # Short repo name from the loop var (host-agnostic); PR number straight from the row.
  short="${repo##*/}"
  out=$(printf '%s' "$data" | jq -r --arg board "$board" --arg keyre "$KEY_RE" --arg repo "$short" '
    ($board | split("\n") | map(select(length > 0))) as $bp
    | .[]
    | select((.url | IN($bp[])) | not)
    | select(((.title + " " + .headRefName) | test($keyre; "i")) | not)
    | "  \($repo)#\(.number)  \(if .isDraft then "draft" else "ready" end)  @\(.author.login)  \(.title[0:60])"')
  [ -n "$out" ] && all="$all$out"$'\n'
done

all="${all%$'\n'}"
n=0; [ -n "$all" ] && n=$(printf '%s\n' "$all" | grep -c .)
if [ "$n" -eq 0 ]; then
  echo "orphan PRs: none (every open PR is on the board or carries a ticket key)"
else
  printf 'orphan PRs (%s) — open, untracked, no ticket key — pull onto the board or merge on the host:\n%s\n' "$n" "$all"
fi

# --- orphan RUNNER sessions ---------------------------------------------------------
# A worker session (see adapters/CONTRACT.md "Runner adapter") that no board row's
# `runner.handle` points at, in any runner impl the profile routes a role to. Observed
# 2026-09-08: an author session sitting at `done` in a workspace with nothing closing it.
# Report only — teardown is the loop's (under its internal-write grant), never this script's.
# Impls that cannot enumerate (in-process) print nothing from `list` and are skipped.
impls=$(printf '%s\n' "${MC_RUNNER_PLANNER:-}" "${MC_RUNNER_PLANNER_SPRINT:-}" "${MC_RUNNER_PLANNER_BACKGROUND:-}" \
                       "${MC_RUNNER_CODER:-}" "${MC_RUNNER_REVIEWER:-}" "${MC_RUNNER_INVESTIGATOR:-}" \
        | awk 'NF && $0!="inprocess" && !seen[$0]++')
if [ -n "$impls" ]; then
  handles=$(jq -r '.tickets[] | select(.runner != null) | .runner.handle // empty | split("|")[0]' "$STATE" 2>/dev/null || true)
  orph=""
  for impl in $impls; do
    [ -x "$MC_ADAPTERS/runner/$impl.sh" ] || continue
    while IFS=$'\t' read -r name st tab; do
      [ -z "$name" ] && continue
      printf '%s\n' "$handles" | grep -qxF "$name" && continue
      orph="$orph  $impl  $name  $st  $tab"$'\n'
    done < <(runner "$impl" list 2>/dev/null)
  done
  orph="${orph%$'\n'}"
  m=0; [ -n "$orph" ] && m=$(printf '%s\n' "$orph" | grep -c .)
  if [ "$m" -eq 0 ]; then
    echo "orphan runner sessions: none (every visible worker session is on the board)"
  else
    printf 'orphan runner sessions (%s) — impl · name · status · tab — no board row points at them; tear down or adopt:\n%s\n' "$m" "$orph"
  fi
fi
