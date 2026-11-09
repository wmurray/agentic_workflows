#!/usr/bin/env bash
# jira-rest.sh — one Jira REST call through the toolkit's credentials, for the writes that
# have no wrapper of their own. The point is permission plumbing: this script is
# allow-listed, a raw `curl` with the token is not, so an agent asked to make a one-off
# write runs this instead of hand-rolling curl and tripping the prompt.
#
#   jira-rest.sh <GET|POST|PUT> </rest/...> [--body <file>|-] [--allow-delete]
#
# The path is relative to JIRA_BASE and must start with /rest/, so the token never leaves
# the site. DELETE is refused unless --allow-delete is given. Writes go through jt_guard
# (manual-only while the loop holds the writer lock) and leave a work-log line. The
# response body is printed; the exit code follows the HTTP status.
# Exit: 0 2xx · 1 other status · 2 bad args · 4 guard refused
set -uo pipefail
. "$(dirname "$(readlink "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")")/env.sh"

method=""; path=""; body_src=""; allow_delete=0
while [ $# -gt 0 ]; do
  case "$1" in
    --body) shift; body_src="${1:-}"; [ -n "$body_src" ] || { echo "jira-rest: --body needs a file or -" >&2; exit 2; } ;;
    --allow-delete) allow_delete=1 ;;
    -*) echo "jira-rest: unknown arg '$1'" >&2; exit 2 ;;
    *) if [ -z "$method" ]; then method=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
       elif [ -z "$path" ]; then path="$1"
       else echo "jira-rest: unexpected arg '$1'" >&2; exit 2; fi ;;
  esac
  shift
done
case "$method" in
  GET|POST|PUT) ;;
  DELETE) [ "$allow_delete" = 1 ] || { echo "jira-rest: DELETE needs --allow-delete" >&2; exit 2; } ;;
  "") echo "jira-rest: need <METHOD> </rest/...>" >&2; exit 2 ;;
  *) echo "jira-rest: method must be GET, POST, PUT or DELETE (got '$method')" >&2; exit 2 ;;
esac
case "$path" in
  /rest/*) ;;
  "") echo "jira-rest: need </rest/...> path" >&2; exit 2 ;;
  *) echo "jira-rest: path must start with /rest/ (relative to the Jira site), got '$path'" >&2; exit 2 ;;
esac

body=""
if [ -n "$body_src" ]; then
  if [ "$body_src" = - ]; then body=$(cat); else
    [ -r "$body_src" ] || { echo "jira-rest: cannot read body file '$body_src'" >&2; exit 2; }
    body=$(cat "$body_src")
  fi
  command -v python3 >/dev/null || { echo "jira-rest: python3 is needed to check the body" >&2; exit 2; }
  printf '%s' "$body" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
    || { echo "jira-rest: body is not valid JSON" >&2; exit 2; }
fi
[ "$method" = GET ] || jt_guard || exit $?

code=$(jt_rest "$method" "$path" "$body")
jt_resp; echo
# every write attempt is on the work log, with the ticket when the path names one
if [ "$method" != GET ]; then
  key=$(jt_find_key "$path")
  jt_worklog ${key:+--ticket "$key"} "jira-rest $method $path -> HTTP ${code:-none}"
fi
case "$code" in
  2??) jt_cleanup; exit 0 ;;
  *) echo "jira-rest: $method $path -> HTTP ${code:-none}" >&2; jt_cleanup; exit 1 ;;
esac
