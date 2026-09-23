#!/usr/bin/env bash
# testing-notes.sh — write the testing-notes field ($JIRA_FIELD_TESTING_NOTES) via REST.
# The QA handoff artifact. Same rich-text-under-a-string-type quirk as the release note:
# write ADF, retry as a plain string on a 400.
# Policy: populate only when empty — REFUSES to overwrite a non-empty value unless --force.
#
#   testing-notes.sh <KEY> (--notes "text" | --file PATH) [--check] [--force]
# Env: JIRA_API_TOKEN. Exit: 0 ok/no-op/check · 2 args · 1 error
set -uo pipefail
. "$(dirname "$(readlink "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")")/env.sh"
jt_guard || exit $?
jt_need JIRA_FIELD_TESTING_NOTES JIRA_BASE JIRA_LOGIN JIRA_API_TOKEN
FIELD="$JIRA_FIELD_TESTING_NOTES"; LABEL="testing notes"

key=""; notes=""; file=""; mode="commit"; force=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) mode="check" ;;
    --force) force=1 ;;
    --notes) notes="$2"; shift ;;
    --file)  file="$2"; shift ;;
    *) if jt_is_key "$1"; then key=$(jt_key "$1"); else echo "testing-notes: unknown arg '$1'" >&2; exit 2; fi ;;
  esac
  shift
done
[ -n "$key" ] || { echo "testing-notes: need <KEY>" >&2; exit 2; }
[ -n "$file" ] && { [ -f "$file" ] || { echo "testing-notes: no file $file" >&2; exit 2; }; notes=$(cat "$file"); }
[ -n "$notes" ] || { echo "testing-notes: need --notes or --file" >&2; exit 2; }

current=$(jt_field "$key" "$FIELD")
if [ -n "$current" ] && [ "$force" != "1" ]; then
  echo "testing-notes: $key already has $LABEL (use --force to overwrite). Current starts: ${current:0:80}…"; exit 0
fi
if [ "$mode" = "check" ]; then echo "testing-notes: $key — would write (${#notes} chars): ${notes:0:120}…"; exit 0; fi

adf=$(printf '%s' "$notes" | python3 "$JT_DIR/md-to-adf.py" | jq --arg f "$FIELD" '{fields: {($f): .}}')
code=$(jt_rest PUT "/rest/api/3/issue/$key" "$adf")
if [ "$code" = "204" ]; then
  jt_worklog --ticket "$key" "$key $LABEL written"
  echo "testing-notes: $key $LABEL written as ADF (${#notes} chars)."; jt_cleanup; exit 0
fi
plain=$(jq -n --arg f "$FIELD" --arg n "$notes" '{fields: {($f): $n}}')
code2=$(jt_rest PUT "/rest/api/3/issue/$key" "$plain")
if [ "$code2" = "204" ]; then
  jt_worklog --ticket "$key" "$key $LABEL written"
  echo "testing-notes: $key $LABEL written as plain string (${#notes} chars; ADF PUT returned $code)."; jt_cleanup; exit 0
fi
echo "testing-notes: FAILED (ADF=$code, plain=$code2) for $key — $(jt_resp | head -c 300)" >&2; jt_cleanup; exit 1
