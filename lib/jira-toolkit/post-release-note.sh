#!/usr/bin/env bash
# post-release-note.sh — record a post-release task (a step someone must do after the change
# ships: a backfill, a flag flip, a config change) as a comment on the ticket itself. It never
# files a sub-task. The comment starts with a fixed marker so it is findable and so a second
# run with the same text is a no-op.
#
#   post-release-note.sh <KEY> (--note "text" | --file PATH) [--check]
#   --check   read-only: say whether it would post; writes nothing.
# Env: JIRA_API_TOKEN, JIRA_POST_RELEASE_MARKER (default "Post-release task:").
# Exit: 0 posted/no-op/check · 2 args · 1 error
set -uo pipefail
. "$(dirname "$(readlink "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")")/env.sh"
MARKER="${JIRA_POST_RELEASE_MARKER:-Post-release task:}"

key=""; note=""; file=""; mode="commit"
while [ $# -gt 0 ]; do
  case "$1" in
    --check) mode="check" ;;
    --note) note="$2"; shift ;;
    --file) file="$2"; shift ;;
    *) if jt_is_key "$1"; then key=$(jt_key "$1"); else echo "post-release-note: unknown arg '$1'" >&2; exit 2; fi ;;
  esac
  shift
done
[ -n "$key" ] || { echo "post-release-note: need <KEY>" >&2; exit 2; }
[ -n "$file" ] && { [ -f "$file" ] || { echo "post-release-note: no file $file" >&2; exit 2; }; note=$(cat "$file"); }
[ -n "$(printf '%s' "$note" | tr -d '[:space:]')" ] || { echo "post-release-note: need --note or --file" >&2; exit 2; }
[ "$mode" = "check" ] || jt_guard fields || exit $?
jt_need JIRA_BASE JIRA_LOGIN JIRA_API_TOKEN

text="$MARKER $note"
code=$(jt_rest GET "/rest/api/2/issue/$key/comment?maxResults=1000")
[ "$code" = "200" ] || { echo "post-release-note: could not read comments for $key ($code) — $(jt_resp | head -c 300)" >&2; jt_cleanup; exit 1; }
norm() { tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'; }
# The tracker re-renders a comment's markup, so match on the marker plus the note's first 80
# characters rather than the exact body.
want=$(printf '%s' "$text" | norm | cut -c1-80)
if jt_resp | jq -r '.comments[]?.body // "" | gsub("\\s+"; " ")' | grep -qF -- "$want"; then
  echo "post-release-note: $key already has this post-release task — no-op."; jt_cleanup; exit 0
fi
if [ "$mode" = "check" ]; then echo "post-release-note: $key — would comment: ${text:0:160}"; jt_cleanup; exit 0; fi

body=$(printf '%s' "$text" | python3 "$JT_DIR/md-to-adf.py" | jq '{body: .}')
code=$(jt_rest POST "/rest/api/3/issue/$key/comment" "$body")
if [ "$code" = "201" ]; then
  jt_worklog --ticket "$key" "$key post-release task commented"
  echo "post-release-note: $key commented: ${text:0:160}"; jt_cleanup; exit 0
fi
echo "post-release-note: FAILED ($code) for $key — $(jt_resp | head -c 300)" >&2; jt_cleanup; exit 1
