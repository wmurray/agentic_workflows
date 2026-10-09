#!/usr/bin/env bash
# review-env.sh: sourced by both review-toolkit wrappers. Loads the allowlists, resolves
# the maintainer's login, and provides the shared refusal vocabulary. Named review-env.sh,
# not env.sh, because the wrappers are symlinked into the same directory as jira-toolkit's.
#
# Config resolution: $REVIEW_TOOLKIT_ENV, else review.env next to this file (gitignored).
# Copy example.env to review.env and fill it in. Any AUTO_POST_* value already set in the
# environment (even to empty) wins over the file.
#
# Every allowlist defaults to empty, and an empty allowlist refuses everything.

# --- locate the toolkit dir through any symlink ------------------------------------------
_rt_src="${BASH_SOURCE[0]}"
while [ -L "$_rt_src" ]; do
  _rt_t="$(readlink "$_rt_src")"
  case "$_rt_t" in /*) _rt_src="$_rt_t" ;; *) _rt_src="$(dirname "$_rt_src")/$_rt_t" ;; esac
done
RT_DIR="$(cd "$(dirname "$_rt_src")" && pwd)"
unset _rt_src _rt_t

# --- load config, environment wins -------------------------------------------------------
RT_VARS="AUTO_POST_AUTHORS AUTO_POST_REPOS AUTO_POST_SELF AUTO_POST_HEADER AUTO_POST_KILL_SWITCH AUTO_POST_MAX_REPLIES AUTO_POST_TEAMS AUTO_POST_LABELS"
_rt_saved=""
for _rt_v in $RT_VARS; do
  [ -n "${!_rt_v+set}" ] && _rt_saved="$_rt_saved$_rt_v=$(printf '%q' "${!_rt_v}");"
done
RT_ENV_FILE="${REVIEW_TOOLKIT_ENV:-$RT_DIR/review.env}"
if [ -f "$RT_ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$RT_ENV_FILE"
fi
eval "$_rt_saved"
unset _rt_saved _rt_v

AUTO_POST_AUTHORS="${AUTO_POST_AUTHORS:-}"
AUTO_POST_REPOS="${AUTO_POST_REPOS:-}"
AUTO_POST_SELF="${AUTO_POST_SELF:-}"          # empty: resolved lazily from `gh api user`
AUTO_POST_TEAMS="${AUTO_POST_TEAMS:-}"        # team slugs whose review request counts as mine
# Inline comment labels: the original four plus Conventional Comments (conventionalcomments.org).
AUTO_POST_LABELS="${AUTO_POST_LABELS:-must-fix,should-fix,nit,question,issue,suggestion,nitpick,thought,todo,praise,chore,note}"
AUTO_POST_HEADER="${AUTO_POST_HEADER:-Automated review}"
AUTO_POST_KILL_SWITCH="${AUTO_POST_KILL_SWITCH:-$HOME/.claude/mission-control/auto-post.off}"
AUTO_POST_MAX_REPLIES="${AUTO_POST_MAX_REPLIES:-2}"
RT_WORKLOG="${AUTO_POST_WORKLOG:-$RT_DIR/../mission-control/worklog.sh}"

# --- exit codes, shared by both wrappers -------------------------------------------------
RT_E_CALL=1 RT_E_USAGE=2
RT_E_KILL=10 RT_E_REPO=11 RT_E_AUTHOR=12 RT_E_NOT_REQUESTED=13 RT_E_EVENT=14
RT_E_UNLABELED=15 RT_E_ALREADY=16 RT_E_HEAD_MOVED=17 RT_E_NO_COMMENT=18 RT_E_BAD_SHA=19
RT_E_BOT_THREAD=20 RT_E_NO_HEADER=21 RT_E_LAZY_QUOTE=22 RT_E_ESCALATE=30

# lazy_quote: true when a line starting with `>` is directly followed by a non-empty line
# that does not start with `>`. Markdown's lazy continuation pulls that line into the quote,
# so a quoted header with the text right under it renders as one quoted paragraph. Both
# wrappers refuse such a body (exit 22) rather than rewrite it.
RT_LAZY_QUOTE_JQ='def lazy_quote:
  split("\n") as $l | any(range(1; $l | length);
    ($l[. - 1] | test("^\\s*>")) and ($l[.] | test("^\\s*(>.*)?$") | not));'
RT_LAZY_QUOTE_FIX="add an empty line after the quoted header"

RT_NAME="${RT_NAME:-$(basename "${0:-review-toolkit}" .sh)}"

# rt_refuse CODE MESSAGE: print the refusal and exit with its code.
rt_refuse() { echo "$RT_NAME: REFUSE: $2" >&2; exit "$1"; }
rt_usage()  { echo "$RT_NAME: $1" >&2; exit "$RT_E_USAGE"; }

# rt_kill_switch: refuse while the kill-switch file exists. Runs before any gh call.
rt_kill_switch() {
  [ ! -e "$AUTO_POST_KILL_SWITCH" ] || rt_refuse "$RT_E_KILL" "kill switch present ($AUTO_POST_KILL_SWITCH)"
}

# rt_in_list VALUE LIST: is VALUE in the comma list? Case-insensitive, spaces trimmed. An
# empty list contains nothing.
rt_in_list() {
  local want item
  want="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [ -n "$want" ] || return 1
  while IFS= read -r item; do
    item="$(printf '%s' "$item" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    [ -n "$item" ] && [ "$item" = "$want" ] && return 0
  done < <(printf '%s\n' "$2" | tr ',' '\n')
  return 1
}

# rt_check_repo OWNER/REPO: refuse unless the repo is allowlisted.
rt_check_repo() {
  rt_in_list "$1" "$AUTO_POST_REPOS" || rt_refuse "$RT_E_REPO" "$1 is not in AUTO_POST_REPOS"
}

# rt_self: the maintainer's login, from config or `gh api user`. Exits 1 if neither works.
rt_self() {
  if [ -z "$AUTO_POST_SELF" ]; then
    AUTO_POST_SELF="$(gh api user --jq .login 2>/dev/null)"
    [ -n "$AUTO_POST_SELF" ] || { echo "$RT_NAME: could not resolve AUTO_POST_SELF (gh api user)" >&2; exit "$RT_E_CALL"; }
  fi
  printf '%s' "$AUTO_POST_SELF"
}

# rt_worklog [worklog.sh flags] TEXT: record a post. Never fails the caller.
rt_worklog() {
  [ -x "$RT_WORKLOG" ] && MC_WORKLOG_SOURCE="$RT_NAME" "$RT_WORKLOG" add "$@" >/dev/null 2>&1 || true
}
