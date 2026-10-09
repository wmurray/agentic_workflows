#!/usr/bin/env bash
# mc-review-sweep.sh: run mc-review-check.sh for every in-review row with a PR (read-only).
#
# The gap this closes: the driver used to tell the loop, in prose inside Prep-write 2, to
# run mc-review-check for each in-review row. A live loop skipped that step for five ticks
# while every scripted step ran, so new review feedback sat untriaged. The sweep makes the
# per-row check one named command the tick runs, like mc-poll.
#
# It reads state.json, picks the rows with lane `in-review` and a `pr` URL, and runs
#   mc-review-check.sh <owner/repo> <pr#> [--seen "<review_seen>"]
# for each. It prints one line per row, NEEDS-TRIAGE rows first, then NO-NEW, CLEAN and
# ERROR in board order:
#
#   NEEDS-TRIAGE  ABC-1234  owner/repo#123  signature: d=CHANGES_REQUESTED;t=2;r=0;ts=…
#
# The signature is the one mc-review-check printed, ready to store verbatim as the row's
# review_seen. The sweep prints verdicts only; the loop re-runs mc-review-check on the one
# row it acts on to get the item list for triage.
#
# READ-ONLY: never writes state.json, the tracker, or the host. Acting on a NEEDS-TRIAGE
# row (Prep-write 2) is the loop's write, under the lock and the one-prep-write cap.
#
#   mc-review-sweep.sh
#   MC_STATE=/path/to/state.scratch.json mc-review-sweep.sh
# Exit: 10 any row NEEDS-TRIAGE · 0 none (all CLEAN / NO-NEW, or no rows)
#       1 no row needs triage but at least one check failed (ERROR), or state unreadable
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
[ -r "$STATE" ] || { echo "mc-review-sweep: cannot read $STATE" >&2; exit 1; }

# Same URL parsing as mc-poll.sh's _repo_of: the URL is the only place the full
# owner/repo slug lives (the row's `repo` field is a bare name).
_repo_of() {
  printf '%s\n' "${1:-}" \
    | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://[^/]+/##' \
    | sed -E 's#/-/#/#' \
    | sed -E 's#/(pull|pulls|merge_requests|pull-requests)/[0-9]+.*$##'
}
_num_of() {
  printf '%s\n' "${1:-}" | sed -nE 's#.*/(pull|pulls|merge_requests|pull-requests)/([0-9]+).*$#\2#p'
}

rows=$(jq -r '.tickets[]
  | select(.lane == "in-review" and (.pr // "") != "")
  | [.ticket, .pr, (.review_seen // "")] | @tsv' "$STATE") \
  || { echo "mc-review-sweep: cannot parse $STATE" >&2; exit 1; }

triage=(); nonew=(); clean=(); errs=()
while IFS=$'\t' read -r key pr seen; do
  [ -n "$key" ] || continue
  repo=$(_repo_of "$pr"); num=$(_num_of "$pr")
  if [ -z "$repo" ] || [ -z "$num" ]; then
    errs+=("$(printf '%-12s  %s  %s  (cannot parse PR URL)' ERROR "$key" "$pr")"); continue
  fi
  args=("$repo" "$num"); [ -n "$seen" ] && args+=(--seen "$seen")
  out=$("$_MC_LIB/mc-review-check.sh" "${args[@]}" 2>&1); rc=$?
  sig=$(printf '%s\n' "$out" | sed -n 's/^signature: //p' | tail -1)
  verdict=$(printf '%s\n' "$out" | sed -nE 's/^review: ([A-Z-]+) .*/\1/p' | head -1)
  line() { printf '%-12s  %s  %s#%s  signature: %s' "$1" "$key" "$repo" "$num" "${sig:--}"; }
  case "$rc:$verdict" in
    10:NEEDS-TRIAGE) triage+=("$(line NEEDS-TRIAGE)") ;;
    0:NO-NEW)        nonew+=("$(line NO-NEW)") ;;
    0:CLEAN)         clean+=("$(line CLEAN)") ;;
    *) errs+=("$(printf '%-12s  %s  %s#%s  (mc-review-check exit %s: %s)' ERROR "$key" "$repo" "$num" "$rc" \
             "$(printf '%s' "$out" | tail -1 | cut -c1-120)")") ;;
  esac
done <<< "$rows"

total=$(( ${#triage[@]} + ${#nonew[@]} + ${#clean[@]} + ${#errs[@]} ))
echo "review sweep: $total in-review row(s) with a PR · ${#triage[@]} need triage · ${#errs[@]} error(s)"
for l in ${triage[@]+"${triage[@]}"} ${nonew[@]+"${nonew[@]}"} ${clean[@]+"${clean[@]}"} ${errs[@]+"${errs[@]}"}; do
  printf '%s\n' "$l"
done

[ "${#triage[@]}" -gt 0 ] && exit 10
[ "${#errs[@]}" -gt 0 ] && exit 1
exit 0
