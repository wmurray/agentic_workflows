#!/usr/bin/env bash
# review-reply.sh: post an agent-written reply to a review thread on the maintainer's own PR,
# without the maintainer reading it first. Opt-in: every guard lives here, in code, and the
# repo allowlist defaults to empty, so an unconfigured install refuses everything. This
# script can only add a reply. It has no way to resolve, hide or edit a thread.
#
#   review-reply.sh <owner/repo> <pr> <comment-id> <body-file|-> [--category fix|decline|answer] [--dry-run]
#
#   comment-id    any review comment in the thread; the reply goes to the thread root.
#   body-file     the reply text (`-` reads stdin). Must contain AUTO_POST_HEADER.
#   --category    a short lower-case tag for the work log (fix, decline, answer, ...).
#   --dry-run     run every check, then print the API call instead of making it.
#
# Guards, in order: kill switch, body carries the header, repo allowlisted, PR author is
# AUTO_POST_SELF, the comment exists on this PR, the thread root was written by a human
# account, every commit SHA in the body is on the PR head branch, and the maintainer has
# fewer than AUTO_POST_MAX_REPLIES header-carrying replies in the thread.
#
# A bot is decided by the root author's account: user.type "Bot" or a login ending in
# "[bot]". Comment text is never consulted, so a person whose comment carries an automated
# header is still a person. A cited SHA is any 7 to 40 character hex word with a digit in it.
#
# Exit: 0 posted or dry run · 1 a gh call failed · 2 bad arguments
#       10 kill switch present · 11 repo not in AUTO_POST_REPOS · 12 PR author is not AUTO_POST_SELF
#       18 comment is not a review comment on this PR · 19 a cited SHA is not on the head branch
#       20 thread root author is a bot · 21 body lacks AUTO_POST_HEADER
#       30 reply cap reached: escalate to a human
set -uo pipefail
. "$(dirname "$(readlink "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")")/review-env.sh"

repo=""; pr=""; cid=""; body_file=""; category=""; dry=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  dry=1 ;;
    --category) category="${2:-}"; shift ;;
    -) if [ -n "$cid" ] && [ -z "$body_file" ]; then body_file="-"; else rt_usage "unexpected arg '-'"; fi ;;
    -*) rt_usage "unknown flag '$1'" ;;
    *) if [ -z "$repo" ]; then repo="$1"; elif [ -z "$pr" ]; then pr="$1"; elif [ -z "$cid" ]; then cid="$1"
       elif [ -z "$body_file" ]; then body_file="$1"; else rt_usage "unexpected arg '$1'"; fi ;;
  esac
  shift
done
[ -n "$body_file" ] || rt_usage "usage: review-reply.sh <owner/repo> <pr> <comment-id> <body-file|-> [--category fix|decline|answer] [--dry-run]"
printf '%s' "$repo" | grep -qE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || rt_usage "repo must be owner/repo, got '$repo'"
printf '%s' "$pr" | grep -qE '^[0-9]+$' || rt_usage "pr must be a number, got '$pr'"
printf '%s' "$cid" | grep -qE '^[0-9]+$' || rt_usage "comment-id must be a number, got '$cid'"
[ -z "$category" ] || printf '%s' "$category" | grep -qE '^[a-z][a-z-]*$' || rt_usage "--category must be a lower-case word, got '$category'"
if [ "$body_file" = "-" ]; then body=$(cat); else
  [ -f "$body_file" ] || rt_usage "body file not found: $body_file"
  body=$(cat "$body_file")
fi
[ -n "$body" ] || rt_usage "reply body is empty"

rt_kill_switch
printf '%s' "$body" | grep -qF -- "$AUTO_POST_HEADER" || rt_refuse "$RT_E_NO_HEADER" "reply body does not contain the header '$AUTO_POST_HEADER'"
rt_check_repo "$repo"

# --- PR and thread checks (gh reads) ------------------------------------------------------
self=$(rt_self) || exit "$RT_E_CALL"
pr_json=$(gh api "repos/$repo/pulls/$pr" 2>/dev/null) || { echo "$RT_NAME: could not read $repo#$pr" >&2; exit "$RT_E_CALL"; }
author=$(printf '%s' "$pr_json" | jq -r '.user.login // ""')
head=$(printf '%s' "$pr_json" | jq -r '.head.sha // ""')
[ "$(printf '%s' "$author" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$self" | tr '[:upper:]' '[:lower:]')" ] \
  || rt_refuse "$RT_E_AUTHOR" "$repo#$pr is by '$author', not AUTO_POST_SELF ($self)"

# fetch_comment ID: one review comment's JSON, or refuse 18 when GitHub has no such comment.
fetch_comment() {
  local out
  if out=$(gh api "repos/$repo/pulls/comments/$1" 2>&1); then printf '%s' "$out"; return 0; fi
  case "$out" in *"HTTP 404"*) rt_refuse "$RT_E_NO_COMMENT" "review comment $1 does not exist in $repo" ;; esac
  echo "$RT_NAME: could not read review comment $1: $out" >&2; exit "$RT_E_CALL"
}
target=$(fetch_comment "$cid") || exit $?
printf '%s' "$target" | jq -e --arg pr "$pr" '(.pull_request_url // "") | test("/pulls/" + $pr + "$")' >/dev/null \
  || rt_refuse "$RT_E_NO_COMMENT" "review comment $cid is not on $repo#$pr"
root_id=$(printf '%s' "$target" | jq -r '.in_reply_to_id // .id')
if [ "$root_id" = "$cid" ]; then root="$target"; else root=$(fetch_comment "$root_id") || exit $?; fi
root_login=$(printf '%s' "$root" | jq -r '.user.login // ""')
printf '%s' "$root" | jq -e '.user.type == "Bot" or ((.user.login // "") | endswith("[bot]"))' >/dev/null \
  && rt_refuse "$RT_E_BOT_THREAD" "thread $root_id was started by the bot account '$root_login'"

for s in $(printf '%s' "$body" | grep -oiE '\b[0-9a-f]{7,40}\b' | grep -E '[0-9]' | sort -u); do
  st=$(gh api "repos/$repo/compare/$s...$head" --jq .status 2>/dev/null) || st=""
  case "$st" in
    identical|ahead) ;;
    *) rt_refuse "$RT_E_BAD_SHA" "cited commit $s is not on the head branch of $repo#$pr${st:+ (compare: $st)}" ;;
  esac
done

mine=$(gh api --paginate "repos/$repo/pulls/$pr/comments" \
         --jq "[.[] | select((.id == $root_id or .in_reply_to_id == $root_id) and (.user.login | ascii_downcase) == (\"$self\" | ascii_downcase))] | .[].body | @json" 2>/dev/null) \
  || { echo "$RT_NAME: could not list review comments on $repo#$pr" >&2; exit "$RT_E_CALL"; }
count=$(printf '%s\n' "$mine" | jq -s --arg h "$AUTO_POST_HEADER" 'map(select(contains($h))) | length' 2>/dev/null || echo 0)
if [ "${count:-0}" -ge "$AUTO_POST_MAX_REPLIES" ]; then
  echo "$RT_NAME: REFUSE: $self already has $count automated replies in thread $root_id on $repo#$pr (max $AUTO_POST_MAX_REPLIES); escalate to a human" >&2
  exit "$RT_E_ESCALATE"
fi

# --- post ---------------------------------------------------------------------------------
payload=$(jq -n --arg b "$body" '{body: $b}')
if [ -n "$dry" ]; then
  echo "$RT_NAME: dry run, would call: gh api -X POST repos/$repo/pulls/$pr/comments/$root_id/replies --input -"
  printf '%s\n' "$payload"
  exit 0
fi
resp=$(printf '%s' "$payload" | gh api -X POST "repos/$repo/pulls/$pr/comments/$root_id/replies" --input - 2>&1) \
  || { echo "$RT_NAME: POST failed: $resp" >&2; exit "$RT_E_CALL"; }
url=$(printf '%s' "$resp" | jq -r '.html_url // ""' 2>/dev/null)
echo "$RT_NAME: replied in thread $root_id on $repo#$pr ${url}"
rt_worklog --pr "${url:-#$pr}" --repo "$repo" \
  "auto-replied${category:+ ($category)} in thread $root_id on $repo#$pr; $url"
exit 0
