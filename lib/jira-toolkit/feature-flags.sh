#!/usr/bin/env bash
# feature-flags.sh — write / verify the feature-flags field ($JIRA_FIELD_FEATURE_FLAGS, a
# LABELS field = array of tokens) via REST. A ticket can carry more than one flag. Labels
# cannot contain spaces (Jira splits on them); tokens are validated to fail loud, not silent.
# Policy: populate only when empty — REFUSES to overwrite a non-empty value unless --force.
#
#   feature-flags.sh <KEY> --flags "flag_a flag_b" [--check] [--force]
#   feature-flags.sh <KEY> --check      read-only VERIFY: exit 0 if populated, 3 if empty.
# Env: JIRA_API_TOKEN. Exit: 0 ok/no-op/populated · 2 args · 3 empty (on --check) · 1 error
set -uo pipefail
. "$(dirname "$(readlink "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")")/env.sh"
jt_guard || exit $?
jt_need JIRA_FIELD_FEATURE_FLAGS JIRA_BASE JIRA_LOGIN JIRA_API_TOKEN
FIELD="$JIRA_FIELD_FEATURE_FLAGS"

key=""; flags=""; mode="commit"; force=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) mode="check" ;;
    --force) force=1 ;;
    --flags) flags="$2"; shift ;;
    *) if jt_is_key "$1"; then key=$(jt_key "$1"); else echo "feature-flags: unknown arg '$1'" >&2; exit 2; fi ;;
  esac
  shift
done
[ -n "$key" ] || { echo "feature-flags: need <KEY>" >&2; exit 2; }

code=$(jt_rest GET "/rest/api/2/issue/$key?fields=$FIELD")
current=""; [ "$code" = "200" ] && current=$(jt_resp | jq -r ".fields.$FIELD // [] | join(\" \")")
has_current=0; [ -n "$(printf '%s' "$current" | tr -d '[:space:]')" ] && has_current=1

if [ "$mode" = "check" ]; then
  if [ "$has_current" = "1" ]; then echo "feature-flags: $key HAS feature flags: $current"; jt_cleanup; exit 0
  else echo "feature-flags: $key feature flags is EMPTY."; jt_cleanup; exit 3; fi
fi
[ -n "$flags" ] || { echo "feature-flags: need --flags \"a b c\" (or --check to verify)" >&2; exit 2; }
for f in $flags; do case "$f" in *[!A-Za-z0-9_.-]*) echo "feature-flags: '$f' has invalid label chars (flags are snake_case tokens)" >&2; exit 2;; esac; done
if [ "$has_current" = "1" ] && [ "$force" != "1" ]; then
  echo "feature-flags: $key already has feature flags ($current) — use --force to overwrite."; exit 0
fi

body=$(jq -n --arg fld "$FIELD" --arg flags "$flags" '{fields: {($fld): ($flags | split(" ") | map(select(length>0)))}}')
code=$(jt_rest PUT "/rest/api/3/issue/$key" "$body")
if [ "$code" = "204" ]; then
  jt_worklog --ticket "$key" "$key feature flags set: $flags"
  echo "feature-flags: $key feature flags set → [$flags]."; jt_cleanup; exit 0
fi
echo "feature-flags: FAILED ($code) for $key — $(jt_resp | head -c 300)" >&2; jt_cleanup; exit 1
