#!/usr/bin/env bash
# done-transition.sh — move a ticket to Done via its REST transition. The CLI (and so
# `jira-status.sh done`) cannot do it: the transition screen REQUIRES two fields or it 400s:
#   • resolution = {"name": $JIRA_DONE_RESOLUTION}
#   • the release-note field ($JIRA_FIELD_RELEASE_NOTE) submitted as ADF — the field is typed
#     `string` in editmeta but the transition endpoint demands an Atlassian Document.
# Release-note source: --note / --note-file if given; otherwise the ticket's CURRENT release
# note is read and re-submitted (the screen requires the field even when populated). Refuses
# if the note ends up empty — never reach Done with no release note.
#
#   done-transition.sh <KEY> [--note "text" | --note-file PATH] [--check]
# Env: JIRA_API_TOKEN. Exit: 0 ok/no-op/check · 2 args · 3 refused (empty note) · 1 error
set -uo pipefail
. "$(dirname "$(readlink "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")")/env.sh"
jt_guard || exit $?
jt_need JIRA_TRANSITION_DONE_ID JIRA_FIELD_RELEASE_NOTE JIRA_BASE JIRA_LOGIN JIRA_API_TOKEN
FIELD="$JIRA_FIELD_RELEASE_NOTE"

key=""; note=""; note_file=""; mode="commit"
while [ $# -gt 0 ]; do
  case "$1" in
    --check) mode="check" ;;
    --note) note="$2"; shift ;;
    --note-file) note_file="$2"; shift ;;
    *) if jt_is_key "$1"; then key=$(jt_key "$1"); else echo "done-transition: unknown arg '$1'" >&2; exit 2; fi ;;
  esac
  shift
done
[ -n "$key" ] || { echo "done-transition: need <KEY>" >&2; exit 2; }

current=$(jt_status_of "$key")
if [ "$current" = "$JIRA_STATUS_DONE" ]; then echo "done-transition: $key already '$JIRA_STATUS_DONE' — no-op."; exit 0; fi

if [ -n "$note_file" ]; then
  note=$(cat "$note_file" 2>/dev/null) || { echo "done-transition: cannot read $note_file" >&2; exit 1; }
elif [ -z "$note" ]; then
  note=$(jt_field "$key" "$FIELD")
fi
[ -n "$(printf '%s' "$note" | tr -d '[:space:]')" ] || {
  echo "done-transition: release note is empty for $key — Done requires it. Pass --note/--note-file or set the field first." >&2
  exit 3; }
if [ "$mode" = "check" ]; then
  echo "done-transition: $key '$current' → would transition to '$JIRA_STATUS_DONE' (id $JIRA_TRANSITION_DONE_ID, resolution=$JIRA_DONE_RESOLUTION, release note: \"$(printf '%s' "$note" | head -c 60)…\")."
  exit 0
fi

body=$(jq -n --arg t "$JIRA_TRANSITION_DONE_ID" --arg f "$FIELD" --arg n "$note" --arg r "$JIRA_DONE_RESOLUTION" '
  ($n | split("\n") | map(select(length>0) | {type:"paragraph", content:[{type:"text", text:.}]})) as $paras
  | {transition: {id: $t},
     fields: {
       resolution: {name: $r},
       ($f): {type:"doc", version:1,
              content: (if ($paras|length)>0 then $paras
                        else [{type:"paragraph", content:[{type:"text", text:$n}]}] end)}
     }}')
code=$(jt_rest POST "/rest/api/3/issue/$key/transitions" "$body")
if [ "$code" = "204" ]; then
  jt_worklog --ticket "$key" "$key '$current' → $JIRA_STATUS_DONE"
  echo "done-transition: $key '$current' → '$JIRA_STATUS_DONE' (resolution=$JIRA_DONE_RESOLUTION, release note set)."; jt_cleanup; exit 0
fi
echo "done-transition: FAILED ($code) for $key — $(jt_resp | head -c 300)" >&2; jt_cleanup; exit 1
