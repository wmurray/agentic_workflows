#!/usr/bin/env bash
# jira-status.sh — move a ticket to the status for a board lane.
# The lane→status MAP lives here, in one place, so it cannot drift across callers. Plain
# status moves only; the QA and Done transitions need REST-only screen fields and have
# their own wrappers.
#
#   jira-status.sh <KEY> <lane|status> [--check]
#     lanes: refined→$JIRA_STATUS_READY · implement/awaiting-review→$JIRA_STATUS_IN_PROGRESS ·
#            in-review/ready-to-merge/alpha-verify→$JIRA_STATUS_CODE_REVIEW ·
#            product-review→$JIRA_STATUS_PRODUCT_REVIEW. A literal status name passes through.
#     refused here (exit 4): qa → qa-transition.sh · done → done-transition.sh · kickback
#     (no move needed: a review kickback is already in code review, a QA kickback already in
#     progress).
#   --check   read-only: print current status, target and the transition that would fire.
#   The transition is chosen by its TARGET status (REST transitions list, matched on .to.name),
#   so it does not matter what the workflow names it. When $JIRA_STATUS_IN_PROGRESS is not
#   directly reachable and $JIRA_STATUS_IN_PROGRESS_VIA is set, the move steps through that
#   status first. That one hop is the only walk; any other unreachable target fails.
# Exit: 0 moved/no-op/check · 2 bad args · 4 special-cased · 1 error
set -uo pipefail
. "$(dirname "$(readlink "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")")/env.sh"

key=""; arg=""; mode="commit"
while [ $# -gt 0 ]; do
  case "$1" in
    --check) mode="check" ;;
    *) if [ -z "$key" ] && jt_is_key "$1"; then key=$(jt_key "$1"); else arg="$1"; fi ;;
  esac
  shift
done
[ -n "$key" ] && [ -n "$arg" ] || { echo "jira-status: need <KEY> <lane|status>" >&2; exit 2; }

case "$arg" in
  refined)                               jt_need JIRA_STATUS_READY;          status="$JIRA_STATUS_READY" ;;
  implement|awaiting-review)             status="$JIRA_STATUS_IN_PROGRESS" ;;
  in-review|ready-to-merge|alpha-verify) status="$JIRA_STATUS_CODE_REVIEW" ;;
  product-review)                        jt_need JIRA_STATUS_PRODUCT_REVIEW; status="$JIRA_STATUS_PRODUCT_REVIEW" ;;
  qa)   echo "jira-status: 'qa' needs transition screen fields a plain move cannot supply — use qa-transition.sh" >&2; exit 4 ;;
  done) echo "jira-status: 'done' requires resolution + release note on the transition screen — use done-transition.sh" >&2; exit 4 ;;
  kickback) echo "jira-status: 'kickback' has no auto-move — a review kickback is already in code review, a QA kickback already in progress. Pass the explicit status only if a move is truly needed." >&2; exit 4 ;;
  *) status="$arg" ;;
esac

current=$(jt_status_of "$key")
if [ "$current" = "$status" ]; then echo "jira-status: $key already '$status' — no-op."; exit 0; fi
trap jt_cleanup EXIT
# _transitions — the ticket's available transitions as "id<TAB>name<TAB>target" lines.
_transitions() {
  local code; code=$(jt_rest GET "/rest/api/2/issue/$key/transitions")
  [ "$code" = "200" ] || { echo "jira-status: could not list transitions for $key (HTTP $code)." >&2; return 1; }
  jt_resp | jq -r '.transitions[] | [.id, .name, .to.name] | @tsv'
}
# _pick STATUS LINES — the first transition whose target is STATUS (case-insensitive), or empty.
_pick() { printf '%s\n' "$2" | awk -F'\t' -v s="$1" 'tolower($3) == tolower(s) { print; exit }'; }
# _fire LINE — POST the transition; Jira answers 204.
_fire() {
  local id code; id=$(printf '%s' "$1" | cut -f1)
  code=$(jt_rest POST "/rest/api/2/issue/$key/transitions" "{\"transition\":{\"id\":\"$id\"}}")
  [ "$code" = "204" ] || { echo "jira-status: transition '$(printf '%s' "$1" | cut -f2)' ($id) on $key failed (HTTP $code): $(jt_resp | head -c 300)" >&2; return 1; }
}
_label() { printf "'%s' (%s)" "$(printf '%s' "$1" | cut -f2)" "$(printf '%s' "$1" | cut -f1)"; }

avail=$(_transitions) || exit 1
direct=$(_pick "$status" "$avail")
hop=""; via="${JIRA_STATUS_IN_PROGRESS_VIA:-}"
if [ -z "$direct" ] && [ "$status" = "$JIRA_STATUS_IN_PROGRESS" ] && [ -n "$via" ] && [ "$current" != "$via" ]; then
  hop=$(_pick "$via" "$avail")
fi
if [ -z "$direct" ] && [ -z "$hop" ]; then
  echo "jira-status: FAILED: no transition from '$current' to '$status' on $key (reachable: $(printf '%s\n' "$avail" | cut -f3 | paste -sd, - | sed 's/,/, /g'))." >&2
  exit 1
fi

if [ "$mode" = "check" ]; then
  if [ -n "$direct" ]; then echo "jira-status: $key '$current' → would move to '$status' via $(_label "$direct")."
  else echo "jira-status: $key '$current' → would move to '$via' via $(_label "$hop"), then to '$status'."; fi
  exit 0
fi

path="'$current'"
if [ -n "$hop" ]; then
  _fire "$hop" || exit 1
  jt_worklog --ticket "$key" "$key '$current' → $via"
  avail=$(_transitions) || { echo "jira-status: $key left in '$via'." >&2; exit 1; }
  direct=$(_pick "$status" "$avail")
  [ -n "$direct" ] || { echo "jira-status: FAILED: $key moved to '$via' but no transition from there to '$status'; left in '$via'." >&2; exit 1; }
  current="$via"; path="$path → '$via'"
fi
_fire "$direct" || exit 1
echo "jira-status: $key $path → '$status'."
jt_worklog --ticket "$key" "$key '$current' → $status"
exit 0
