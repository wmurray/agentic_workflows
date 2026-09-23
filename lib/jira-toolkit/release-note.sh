#!/usr/bin/env bash
# release-note.sh — write / verify the release-note field ($JIRA_FIELD_RELEASE_NOTE) via
# REST, at MERGE (not at Done). The code is complete and freshly delivered at merge, and
# the orchestrator hands off before Done; writing here means the field is populated by the
# normal flow and done-transition.sh only re-reads it.
# The field is typed `string` in editmeta but is rich text: the /issue PUT accepts ADF. We
# write ADF (via md-to-adf.py); on a 400 we retry as a plain string so a field-config quirk
# cannot silently drop the note.
# Policy: populate only when empty — REFUSES to overwrite a non-empty value unless --force.
#
#   release-note.sh <KEY> (--note "text" | --file PATH) [--check] [--force]
#   release-note.sh <KEY> --check      read-only VERIFY: exit 0 if populated, 3 if empty.
# Env: JIRA_API_TOKEN. Exit: 0 ok/no-op/populated · 2 args · 3 empty (on --check) · 1 error
set -uo pipefail
. "$(dirname "$(readlink "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")")/env.sh"
jt_guard || exit $?
jt_need JIRA_FIELD_RELEASE_NOTE JIRA_BASE JIRA_LOGIN JIRA_API_TOKEN
FIELD="$JIRA_FIELD_RELEASE_NOTE"; LABEL="release note"

key=""; note=""; file=""; mode="commit"; force=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) mode="check" ;;
    --force) force=1 ;;
    --note) note="$2"; shift ;;
    --file) file="$2"; shift ;;
    *) if jt_is_key "$1"; then key=$(jt_key "$1"); else echo "release-note: unknown arg '$1'" >&2; exit 2; fi ;;
  esac
  shift
done
[ -n "$key" ] || { echo "release-note: need <KEY>" >&2; exit 2; }
[ -n "$file" ] && { [ -f "$file" ] || { echo "release-note: no file $file" >&2; exit 2; }; note=$(cat "$file"); }

current=$(jt_field "$key" "$FIELD")
has_current=0; [ -n "$(printf '%s' "$current" | tr -d '[:space:]')" ] && has_current=1

if [ "$mode" = "check" ]; then
  if [ "$has_current" = "1" ]; then echo "release-note: $key HAS a $LABEL (${#current} chars): ${current:0:120}…"; exit 0
  else echo "release-note: $key $LABEL is EMPTY."; exit 3; fi
fi
[ -n "$note" ] || { echo "release-note: need --note or --file (or --check to verify)" >&2; exit 2; }
if [ "$has_current" = "1" ] && [ "$force" != "1" ]; then
  echo "release-note: $key already has a $LABEL (use --force to overwrite). Current starts: ${current:0:80}…"; exit 0
fi

adf=$(printf '%s' "$note" | python3 "$JT_DIR/md-to-adf.py" | jq --arg f "$FIELD" '{fields: {($f): .}}')
code=$(jt_rest PUT "/rest/api/3/issue/$key" "$adf")
if [ "$code" = "204" ]; then
  jt_worklog --ticket "$key" "$key $LABEL written"
  echo "release-note: $key $LABEL written as ADF (${#note} chars)."; jt_cleanup; exit 0
fi
plain=$(jq -n --arg f "$FIELD" --arg n "$note" '{fields: {($f): $n}}')
code2=$(jt_rest PUT "/rest/api/3/issue/$key" "$plain")
if [ "$code2" = "204" ]; then
  jt_worklog --ticket "$key" "$key $LABEL written"
  echo "release-note: $key $LABEL written as plain string (${#note} chars; ADF PUT returned $code)."; jt_cleanup; exit 0
fi
echo "release-note: FAILED (ADF=$code, plain=$code2) for $key — $(jt_resp | head -c 300)" >&2; jt_cleanup; exit 1
