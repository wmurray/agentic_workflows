#!/usr/bin/env bash
# env.sh — sourced by every jira-toolkit wrapper. Loads the org config, validates it, and
# provides the small shared vocabulary (key matching, status lookup, REST calls, the
# optional mission-control guard + work log). No wrapper names an org value directly.
#
# Config resolution: $JIRA_TOOLKIT_ENV, else jira.env next to this file (gitignored).
# Copy example.env to jira.env and fill it in. JIRA_API_TOKEN may come from the shell
# environment or from jira.env; the environment wins.
#
# Mission-control integration is OPTIONAL: if $MC_HOME/mc-guard.sh or worklog.sh exist
# they are used (manual-only wrappers refuse while the loop holds the writer lock; every
# outward write is logged). Without them the wrappers simply run.

# --- locate the toolkit dir through any symlink ------------------------------------------
_jt_src="${BASH_SOURCE[0]}"
while [ -L "$_jt_src" ]; do
  _jt_t="$(readlink "$_jt_src")"
  case "$_jt_t" in /*) _jt_src="$_jt_t" ;; *) _jt_src="$(dirname "$_jt_src")/$_jt_t" ;; esac
done
JT_DIR="$(cd "$(dirname "$_jt_src")" && pwd)"
unset _jt_src _jt_t

# --- load config ------------------------------------------------------------------------
_jt_saved_token="${JIRA_API_TOKEN:-}"
JT_ENV_FILE="${JIRA_TOOLKIT_ENV:-$JT_DIR/jira.env}"
if [ -f "$JT_ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$JT_ENV_FILE"
fi
if [ -n "$_jt_saved_token" ]; then JIRA_API_TOKEN=$_jt_saved_token; fi   # environment wins over the file
unset _jt_saved_token

# Defaults for the values that have a sensible generic answer.
JIRA_KEY_REGEX="${JIRA_KEY_REGEX:-[A-Z][A-Z0-9]+-[0-9]+}"
JIRA_STATUS_IN_PROGRESS="${JIRA_STATUS_IN_PROGRESS:-In Progress}"
JIRA_STATUS_CODE_REVIEW="${JIRA_STATUS_CODE_REVIEW:-Code Review}"
JIRA_STATUS_DONE="${JIRA_STATUS_DONE:-Done}"
JIRA_DONE_RESOLUTION="${JIRA_DONE_RESOLUTION:-Done}"
GH_MERGE_METHOD="${GH_MERGE_METHOD:-squash}"
GH_OUTSIDE_SPRINT_LABEL="${GH_OUTSIDE_SPRINT_LABEL:-outside current sprint}"
GH_BLOCK_LABELS="${MC_BLOCK_LABELS:-${GH_BLOCK_LABELS:-do not merge,dont merge,do-not-merge,dnm,hold,wip}}"
GH_SPRINT_LABELS="${MC_SPRINT_LABELS:-${GH_SPRINT_LABELS:-$GH_OUTSIDE_SPRINT_LABEL}}"
GH_FREEZE_CHECK_PATTERN="${MC_FREEZE_CHECK_PATTERN:-${GH_FREEZE_CHECK_PATTERN:-freeze}}"
DEPENDABOT_ALLOWED_PATHS="${DEPENDABOT_ALLOWED_PATHS:-^(package\.json|yarn\.lock|package-lock\.json|Gemfile|Gemfile\.lock)$}"

# --- helpers ----------------------------------------------------------------------------
JT_NAME="${JT_NAME:-$(basename "${0:-jira-toolkit}" .sh)}"

# jt_need VAR…  — fail loudly when an org value the wrapper depends on is unset.
jt_need() {
  local v missing=""
  for v in "$@"; do [ -n "${!v:-}" ] || missing="$missing $v"; done
  [ -z "$missing" ] || {
    echo "$JT_NAME: missing config:${missing} — copy $JT_DIR/example.env to $JT_ENV_FILE and fill it in" >&2
    exit 1; }
}

# jt_is_key STR — does STR look like a ticket key (case-insensitive)?
jt_is_key() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | grep -qxE "$JIRA_KEY_REGEX"; }
# jt_key STR — normalize to upper case.
jt_key() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }
# jt_find_key TEXT — first key-looking token in TEXT (upper-cased), or empty.
jt_find_key() { printf '%s\n' "$1" | tr '[:lower:]' '[:upper:]' | grep -oE "$JIRA_KEY_REGEX" | head -1 || true; }

# jt_status_of KEY — current status name via the jira CLI (the CLI prefixes the key
# column even when only `status` is requested, so take field 2 onward).
jt_status_of() {
  jira issue list -q "key = $1" --plain --no-headers --columns status 2>/dev/null \
    | tr -s '\t' | head -1 | cut -f2- | sed 's/[[:space:]]*$//'
}

# jt_rest METHOD PATH [BODY] — authenticated REST call; prints the HTTP code, body to $JT_RESP.
JT_RESP="${TMPDIR:-/tmp}/jt-resp.$$"
jt_rest() {
  jt_need JIRA_BASE JIRA_LOGIN JIRA_API_TOKEN
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -s -o "$JT_RESP" -w '%{http_code}' -X "$method" -u "$JIRA_LOGIN:$JIRA_API_TOKEN" \
      -H 'Content-Type: application/json' --data "$body" "$JIRA_BASE$path" 2>/dev/null
  else
    curl -s -o "$JT_RESP" -w '%{http_code}' -X "$method" -u "$JIRA_LOGIN:$JIRA_API_TOKEN" "$JIRA_BASE$path" 2>/dev/null
  fi
}
jt_resp() { cat "$JT_RESP" 2>/dev/null; }
jt_cleanup() { rm -f "$JT_RESP"; }
# jt_field KEY FIELD — a field's value via REST v2 (rich-text fields come back as plain strings).
jt_field() {
  local code; code=$(jt_rest GET "/rest/api/2/issue/$1?fields=$2")
  [ "$code" = "200" ] && jt_resp | jq -r ".fields.$2 // \"\""
}

# Mission-control seams, both optional.
jt_guard() {   # jt_guard — refuse while the loop holds the writer lock (manual-only wrappers)
  local g="${MC_HOME:-$HOME/.claude/mission-control}/mc-guard.sh"
  [ -x "$g" ] || return 0
  "$g" check "$JT_NAME"
}
jt_worklog() { # jt_worklog [--ticket K] [--pr P] [--repo R] TEXT — record an outward write
  local w="${MC_HOME:-$HOME/.claude/mission-control}/worklog.sh"
  [ -x "$w" ] && MC_WORKLOG_SOURCE="$JT_NAME" "$w" add "$@" >/dev/null 2>&1 || true
}
