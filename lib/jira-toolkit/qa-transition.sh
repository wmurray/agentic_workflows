#!/usr/bin/env bash
# qa-transition.sh — move a ticket to the QA status via the REST transitions endpoint
# (the CLI does not resolve this transition by name reliably). It sets no owner or
# assignee fields itself: on many boards an automation writes those server-side on this
# transition, and passing them from a client 400s when the screen does not expose them.
# Optionally writes Testing Notes first (the QA handoff is notes + transition together).
#
# Field gate: it refuses to transition (exit 3, naming each one) unless Release Note,
# Testing Notes, Feature Flags and Story Points are all populated. --notes/--notes-file are
# written FIRST, then the gate runs. --force transitions anyway and says which were empty.
# Points are only ever checked; nothing here writes them.
#
# Transition id: the configured JIRA_TRANSITION_QA_ID is used when the issue offers it and
# it leads to $JIRA_STATUS_QA. Otherwise the id is matched by target status from the
# issue's live transitions, and a mismatch is printed with the live id so the config can
# be corrected. Leave JIRA_TRANSITION_QA_ID empty to always match by target.
#
#   qa-transition.sh <KEY> [--notes "text" | --notes-file PATH] [--check] [--force]
#   --check   read-only: report the gate and the transition it would fire; writes nothing,
#             and skips the loop guard so the loop can run it. Exit 3 when fields are empty.
# Env: JIRA_API_TOKEN. Exit: 0 ok/no-op/check passed · 2 args · 3 fields empty · 4 guard · 1 error
set -uo pipefail
. "$(dirname "$(readlink "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")")/env.sh"

key=""; notes=""; notes_file=""; mode="commit"; force=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) mode="check" ;;
    --force) force=1 ;;
    --notes) notes="$2"; shift ;;
    --notes-file) notes_file="$2"; shift ;;
    *) if jt_is_key "$1"; then key=$(jt_key "$1"); else echo "qa-transition: unknown arg '$1'" >&2; exit 2; fi ;;
  esac
  shift
done
[ -n "$key" ] || { echo "qa-transition: need <KEY>" >&2; exit 2; }
[ -z "$notes_file" ] || [ -f "$notes_file" ] || { echo "qa-transition: no file $notes_file" >&2; exit 2; }
[ "$mode" = "check" ] || jt_guard fields || exit $?
jt_need JIRA_STATUS_QA JIRA_BASE JIRA_LOGIN JIRA_API_TOKEN \
  JIRA_FIELD_RELEASE_NOTE JIRA_FIELD_TESTING_NOTES JIRA_FIELD_FEATURE_FLAGS JIRA_FIELD_STORY_POINTS

current=$(jt_status_of "$key")
if [ "$current" = "$JIRA_STATUS_QA" ]; then echo "qa-transition: $key already '$JIRA_STATUS_QA' — no-op."; exit 0; fi

# 1. Testing Notes first, via the dedicated wrapper so the field logic lives in one place.
if [ "$mode" = "commit" ]; then
  if [ -n "$notes_file" ]; then
    bash "$JT_DIR/testing-notes.sh" "$key" --file "$notes_file" --force || { echo "qa-transition: testing-notes step failed — not transitioning" >&2; exit 1; }
  elif [ -n "$notes" ]; then
    bash "$JT_DIR/testing-notes.sh" "$key" --notes "$notes" --force || { echo "qa-transition: testing-notes step failed — not transitioning" >&2; exit 1; }
  fi
fi

# 2. Field gate. In --check mode, notes passed on the command line count as written.
missing=$(jt_missing_fields "$key") || { echo "qa-transition: could not read fields for $key — $(jt_resp | head -c 300)" >&2; jt_cleanup; exit 1; }
if [ "$mode" = "check" ] && [ -n "$notes$notes_file" ]; then
  missing=$(printf '%s' "$missing" | sed 's/, /\n/g' | grep -vx 'testing notes' | paste -sd',' - | sed 's/,/, /g')
fi
if [ -n "$missing" ]; then
  if [ "$mode" = "check" ]; then
    echo "qa-transition: $key fields missing: $missing — would refuse."; jt_cleanup; exit 3
  elif [ "$force" != "1" ]; then
    echo "qa-transition: REFUSED — $key fields missing: $missing. Fill them, or pass --force to transition anyway." >&2
    jt_cleanup; exit 3
  fi
  echo "qa-transition: --force: transitioning $key with fields missing: $missing."
fi

# 3. Resolve the transition id against what the issue offers right now.
code=$(jt_rest GET "/rest/api/3/issue/$key/transitions")
[ "$code" = "200" ] || { echo "qa-transition: could not list transitions for $key ($code) — $(jt_resp | head -c 300)" >&2; jt_cleanup; exit 1; }
cfg="${JIRA_TRANSITION_QA_ID:-}"
tid=$(jt_resp | jq -r --arg id "$cfg" --arg to "$JIRA_STATUS_QA" '[.transitions[] | select(.id == $id and .to.name == $to)][0].id // empty')
if [ -z "$tid" ]; then
  tid=$(jt_resp | jq -r --arg to "$JIRA_STATUS_QA" '[.transitions[] | select(.to.name == $to)][0].id // empty')
  if [ -z "$tid" ]; then
    echo "qa-transition: no transition from '$current' to '$JIRA_STATUS_QA' for $key (reachable: $(jt_resp | jq -r '[.transitions[].to.name] | unique | join(", ")'))." >&2
    jt_cleanup; exit 1
  fi
  if [ -n "$cfg" ]; then
    echo "qa-transition: configured JIRA_TRANSITION_QA_ID=$cfg is not offered for $key; the live id is $tid. Set JIRA_TRANSITION_QA_ID=\"$tid\" in $JT_ENV_FILE." >&2
  fi
fi

if [ "$mode" = "check" ]; then
  echo "qa-transition: $key '$current' → would transition to '$JIRA_STATUS_QA' (id $tid; owner + assignee left to automation$([ -n "$notes$notes_file" ] && echo ", + Testing Notes"))."
  jt_cleanup; exit 0
fi

# 4. Bare transition.
body=$(jq -n --arg t "$tid" '{transition: {id: $t}}')
code=$(jt_rest POST "/rest/api/3/issue/$key/transitions" "$body")
if [ "$code" = "204" ]; then
  jt_worklog --ticket "$key" "$key '$current' → $JIRA_STATUS_QA$([ "$force" = 1 ] && [ -n "$missing" ] && echo " (forced; missing: $missing)")"
  echo "qa-transition: $key '$current' → '$JIRA_STATUS_QA' (owner + assignee left to automation)."; jt_cleanup; exit 0
fi
echo "qa-transition: FAILED ($code) for $key — $(jt_resp | head -c 300)" >&2; jt_cleanup; exit 1
