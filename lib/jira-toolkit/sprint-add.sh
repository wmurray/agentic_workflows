#!/usr/bin/env bash
# sprint-add.sh — add a ticket to the current ACTIVE sprint. Idempotent.
# Merging a PR pulls its ticket into the current sprint; that is why the "outside current
# sprint" label goes stale at merge (see merge.sh). Removing the label without moving the
# ticket just hides the contradiction; this makes the tracker match. Its own wrapper so it
# is independently allow-listable, --check-able, and reusable standalone.
#
#   sprint-add.sh <KEY> [--check]
# Exit: 0 added/no-op/check · 2 bad args · 5 no active sprint · 1 error
set -uo pipefail
. "$(dirname "$(readlink "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")")/env.sh"
jt_guard || exit $?   # manual-only: refuses while the loop holds the writer lock

key=""; mode="commit"
while [ $# -gt 0 ]; do
  case "$1" in
    --check) mode="check" ;;
    *) if jt_is_key "$1"; then key=$(jt_key "$1"); else echo "sprint-add: unknown arg '$1'" >&2; exit 2; fi ;;
  esac
  shift
done
[ -n "$key" ] || { echo "sprint-add: need <KEY>" >&2; exit 2; }

sprint_line=$(jira sprint list --state active --plain --no-headers --columns ID,NAME 2>/dev/null | head -1)
sprint_id=$(printf '%s' "$sprint_line" | cut -f1 | tr -d '[:space:]')
sprint_name=$(printf '%s' "$sprint_line" | cut -f2- | sed 's/[[:space:]]*$//')
[ -n "$sprint_id" ] || { echo "sprint-add: no active sprint found (jira sprint list --state active)" >&2; exit 5; }

if jira sprint list "$sprint_id" --plain --no-headers --columns KEY --show-all-issues 2>/dev/null \
     | tr -s '\t' ' ' | awk '{print $1}' | grep -qx "$key"; then
  echo "sprint-add: $key already in active sprint '$sprint_name' (#$sprint_id) — no-op."; exit 0
fi
if [ "$mode" = "check" ]; then
  echo "sprint-add: $key NOT in active sprint — would add to '$sprint_name' (#$sprint_id)."; exit 0
fi
if jira sprint add "$sprint_id" "$key" >/dev/null 2>&1; then
  echo "sprint-add: $key added to active sprint '$sprint_name' (#$sprint_id)."
  jt_worklog --ticket "$key" "$key added to sprint '$sprint_name'"; exit 0
fi
echo "sprint-add: FAILED to add $key to sprint '$sprint_name' (#$sprint_id) (jira sprint add)." >&2; exit 1
