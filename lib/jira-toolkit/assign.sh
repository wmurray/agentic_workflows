#!/usr/bin/env bash
# assign.sh — claim a ticket for the default assignee (assignee-fix).
# Only ever claims an UNASSIGNED ticket. It NEVER pulls a ticket off a named colleague
# (that stays a human flag). The safety preconditions live here, in code, so the write is
# allow-listable without a raw `jira issue assign` rule and cannot drift across callers.
#
#   assign.sh <KEY> [--to <email|accountId>] [--lane <lane>] [--check]
#     --to     assignee to claim for (default: $JIRA_ASSIGNEE_DEFAULT).
#     --lane   the board lane; a GUARD that refuses the lanes where a QA person or product
#              owner is the legitimate assignee: qa / product-review / done (exit 4).
#     --check  read-only: print current assignee + what would happen, change nothing.
#   Behavior: already the target → no-op (0) · unassigned → assign (0) · assigned to someone
#   else → REFUSE (5) so the caller flags it for a human.
# Exit: 0 assigned/no-op/check · 2 bad args · 4 lane-guarded · 5 assigned-to-a-colleague · 1 error
set -uo pipefail
. "$(dirname "$(readlink "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")")/env.sh"
jt_need JIRA_ASSIGNEE_DEFAULT

key=""; lane=""; mode="commit"; to="$JIRA_ASSIGNEE_DEFAULT"; to_id="${JIRA_ASSIGNEE_DEFAULT_ID:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --check)   mode="check" ;;
    --lane)    lane="$2"; shift ;;
    --to)      to="$2"; to_id=""; shift ;;   # custom target → compared by displayName/email substring
    *) if jt_is_key "$1"; then key=$(jt_key "$1"); else echo "assign: unknown arg '$1'" >&2; exit 2; fi ;;
  esac
  shift
done
[ -n "$key" ] || { echo "assign: need <KEY>" >&2; exit 2; }

case "$lane" in
  qa|product-review|done)
    echo "assign: lane '$lane' — QA/product owns the assignee here; refusing (use a human flag if truly needed)." >&2
    exit 4 ;;
esac

raw=$(jira issue view "$key" --raw 2>/dev/null)
[ -n "$raw" ] || { echo "assign: could not fetch $key (jira issue view --raw)." >&2; exit 1; }
cur_id=$(printf '%s' "$raw"   | jq -r '.fields.assignee.accountId  // empty' 2>/dev/null)
cur_name=$(printf '%s' "$raw" | jq -r '.fields.assignee.displayName // "Unassigned"' 2>/dev/null)

# Already the target → no-op. Exact accountId match when we have one; otherwise a loose
# name/email substring match.
if { [ -n "$to_id" ] && [ "$cur_id" = "$to_id" ]; } \
   || { [ -z "$to_id" ] && [ -n "$cur_id" ] && printf '%s' "$cur_name" | grep -qiF "$to"; }; then
  echo "assign: $key already assigned to '$cur_name' — no-op."; exit 0
fi
if [ -n "$cur_id" ]; then
  echo "assign: $key is assigned to '$cur_name' — auto-claim only takes UNASSIGNED tickets; leaving it. Flag for a human to reassign if this is drift." >&2
  exit 5
fi
if [ "$mode" = "check" ]; then
  echo "assign: $key is Unassigned → would assign to '$to'."; exit 0
fi
if jira issue assign "$key" "$to" >/dev/null 2>&1; then
  echo "assign: $key Unassigned → assigned to '$to'."
  jt_worklog --ticket "$key" "$key assigned to '$to'"
  exit 0
fi
echo "assign: FAILED to assign $key to '$to' (jira issue assign)." >&2; exit 1
