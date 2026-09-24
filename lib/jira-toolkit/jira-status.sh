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
#   --check   read-only: print current status + target, move nothing.
#   Some issue-type workflows label the forward transition "Move to <status>" instead of the
#   bare status name; a failed bare-name move is retried once with that alias.
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
if [ "$mode" = "check" ]; then echo "jira-status: $key '$current' → would move to '$status'."; exit 0; fi

if jira issue move "$key" "$status" >/dev/null 2>&1; then
  echo "jira-status: $key '$current' → '$status'."
  jt_worklog --ticket "$key" "$key '$current' → $status"; exit 0
fi
if jira issue move "$key" "Move to $status" >/dev/null 2>&1; then
  echo "jira-status: $key '$current' → '$status' (via 'Move to $status' transition)."
  jt_worklog --ticket "$key" "$key '$current' → $status"; exit 0
fi
echo "jira-status: FAILED to move $key '$current' → '$status' (tried '$status' and 'Move to $status'). Check the transition is valid from the current status." >&2
exit 1
