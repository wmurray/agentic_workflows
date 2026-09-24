#!/usr/bin/env bash
# qa-transition.sh — move a ticket to the QA status via the REST transitions endpoint
# (the CLI does not resolve this transition by name reliably). It sets no owner or
# assignee fields itself: on many boards an automation writes those server-side on this
# transition, and passing them from a client 400s when the screen does not expose them.
# Optionally writes Testing Notes first (the QA handoff is notes + transition together).
#
#   qa-transition.sh <KEY> [--notes "text" | --notes-file PATH] [--check]
# Env: JIRA_API_TOKEN. Exit: 0 ok/no-op/check · 2 args · 1 error
set -uo pipefail
. "$(dirname "$(readlink "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")")/env.sh"
jt_guard || exit $?
jt_need JIRA_STATUS_QA JIRA_TRANSITION_QA_ID JIRA_BASE JIRA_LOGIN JIRA_API_TOKEN

key=""; notes=""; notes_file=""; mode="commit"
while [ $# -gt 0 ]; do
  case "$1" in
    --check) mode="check" ;;
    --notes) notes="$2"; shift ;;
    --notes-file) notes_file="$2"; shift ;;
    *) if jt_is_key "$1"; then key=$(jt_key "$1"); else echo "qa-transition: unknown arg '$1'" >&2; exit 2; fi ;;
  esac
  shift
done
[ -n "$key" ] || { echo "qa-transition: need <KEY>" >&2; exit 2; }

current=$(jt_status_of "$key")
if [ "$current" = "$JIRA_STATUS_QA" ]; then echo "qa-transition: $key already '$JIRA_STATUS_QA' — no-op."; exit 0; fi
if [ "$mode" = "check" ]; then
  echo "qa-transition: $key '$current' → would transition to '$JIRA_STATUS_QA' (id $JIRA_TRANSITION_QA_ID; owner + assignee left to automation$([ -n "$notes$notes_file" ] && echo ", + Testing Notes"))."
  exit 0
fi

# 1. Testing Notes first, via the dedicated wrapper so the field logic lives in one place.
if [ -n "$notes_file" ]; then
  bash "$JT_DIR/testing-notes.sh" "$key" --file "$notes_file" --force || { echo "qa-transition: testing-notes step failed — not transitioning" >&2; exit 1; }
elif [ -n "$notes" ]; then
  bash "$JT_DIR/testing-notes.sh" "$key" --notes "$notes" --force || { echo "qa-transition: testing-notes step failed — not transitioning" >&2; exit 1; }
fi

# 2. Bare transition.
body=$(jq -n --arg t "$JIRA_TRANSITION_QA_ID" '{transition: {id: $t}}')
code=$(jt_rest POST "/rest/api/3/issue/$key/transitions" "$body")
if [ "$code" = "204" ]; then
  jt_worklog --ticket "$key" "$key '$current' → $JIRA_STATUS_QA"
  echo "qa-transition: $key '$current' → '$JIRA_STATUS_QA' (owner + assignee left to automation)."; jt_cleanup; exit 0
fi
echo "qa-transition: FAILED ($code) for $key — $(jt_resp | head -c 300)" >&2; jt_cleanup; exit 1
