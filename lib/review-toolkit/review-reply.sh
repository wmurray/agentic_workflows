#!/usr/bin/env bash
# review-reply.sh: post an agent-written reply to a review thread, or to a top-level PR
# conversation comment, on the maintainer's own PR, without the maintainer reading it first.
# Opt-in: every guard lives here, in code, and the repo allowlist defaults to empty, so an
# unconfigured install refuses everything. This script can only add a comment. It has no way
# to resolve, hide, edit or delete anything.
#
#   review-reply.sh <owner/repo> <pr> <comment-id> <body-file|-> [--category fix|decline|answer] [--dry-run]
#   review-reply.sh <owner/repo> <pr> --issue-comment <id> <body-file|-> [--category …] [--dry-run]
#
#   comment-id    any review comment in the thread; the reply goes to the thread root.
#   --issue-comment ID
#                 answer a top-level PR conversation comment instead. GitHub has no threads
#                 there, so the reply is a new PR comment: the body as given, then a last
#                 line "In reply to <login>: <comment URL>". That line is also what the
#                 reply cap counts.
#   body-file     the reply text (`-` reads stdin). Must contain AUTO_POST_HEADER.
#   --category    a short lower-case tag for the work log (fix, decline, answer, ...).
#   --dry-run     run every check, then print the API call instead of making it.
#
# Guards, in order: kill switch, body carries the header, repo allowlisted, PR author is
# AUTO_POST_SELF, the comment exists on this PR, the thread root (or the issue comment) was
# written by a human account, every commit SHA in the body is on the PR head branch, and the
# maintainer has fewer than AUTO_POST_MAX_REPLIES header-carrying replies in the thread (for
# an issue comment: header-carrying PR comments that link that comment's id).
#
# A bot is decided by the root author's account: user.type "Bot" or a login ending in
# "[bot]". Comment text is never consulted, so a person whose comment carries an automated
# header is still a person. A cited SHA is any 7 to 40 character hex word with a digit in it.
#
# Exit: 0 posted or dry run · 1 a gh call failed · 2 bad arguments
#       10 kill switch present · 11 repo not in AUTO_POST_REPOS · 12 PR author is not AUTO_POST_SELF
#       18 comment is not a review comment (with --issue-comment: an issue comment) on this PR
#       19 a cited SHA is not on the head branch
#       20 thread root (or issue comment) author is a bot · 21 body lacks AUTO_POST_HEADER
#       30 reply cap reached: escalate to a human
set -uo pipefail
. "$(dirname "$(readlink "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")")/review-env.sh"

repo=""; pr=""; cid=""; body_file=""; category=""; dry=""; issue=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  dry=1 ;;
    --category) category="${2:-}"; shift ;;
    --issue-comment)
      [ -z "$cid" ] || rt_usage "give a review comment id or --issue-comment, not both"
      issue=1; cid="${2:-}"; shift ;;
    -) if [ -n "$cid" ] && [ -z "$body_file" ]; then body_file="-"; else rt_usage "unexpected arg '-'"; fi ;;
    -*) rt_usage "unknown flag '$1'" ;;
    *) if [ -z "$repo" ]; then repo="$1"; elif [ -z "$pr" ]; then pr="$1"; elif [ -z "$cid" ]; then cid="$1"
       elif [ -z "$body_file" ]; then body_file="$1"; else rt_usage "unexpected arg '$1'"; fi ;;
  esac
  shift
done
[ -n "$body_file" ] || rt_usage "usage: review-reply.sh <owner/repo> <pr> {<comment-id>|--issue-comment <id>} <body-file|-> [--category fix|decline|answer] [--dry-run]"
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

# fetch_comment ID [KIND]: one comment's JSON, or refuse 18 when GitHub has no such comment.
# KIND is `pulls` (a review comment, the default) or `issues` (a PR conversation comment).
fetch_comment() {
  local out kind="${2:-pulls}" what="review comment"
  [ "$kind" = issues ] && what="PR comment"
  if out=$(gh api "repos/$repo/$kind/comments/$1" 2>&1); then printf '%s' "$out"; return 0; fi
  case "$out" in *"HTTP 404"*) rt_refuse "$RT_E_NO_COMMENT" "$what $1 does not exist in $repo" ;; esac
  echo "$RT_NAME: could not read $what $1: $out" >&2; exit "$RT_E_CALL"
}
if [ -n "$issue" ]; then
  target=$(fetch_comment "$cid" issues) || exit $?
  printf '%s' "$target" | jq -e --arg pr "$pr" '(.issue_url // "") | test("/issues/" + $pr + "$")' >/dev/null \
    || rt_refuse "$RT_E_NO_COMMENT" "PR comment $cid is not on $repo#$pr"
  root="$target"; root_id="$cid"
else
  target=$(fetch_comment "$cid") || exit $?
  printf '%s' "$target" | jq -e --arg pr "$pr" '(.pull_request_url // "") | test("/pulls/" + $pr + "$")' >/dev/null \
    || rt_refuse "$RT_E_NO_COMMENT" "review comment $cid is not on $repo#$pr"
  root_id=$(printf '%s' "$target" | jq -r '.in_reply_to_id // .id')
  if [ "$root_id" = "$cid" ]; then root="$target"; else root=$(fetch_comment "$root_id") || exit $?; fi
fi
root_login=$(printf '%s' "$root" | jq -r '.user.login // ""')
printf '%s' "$root" | jq -e '.user.type == "Bot" or ((.user.login // "") | endswith("[bot]"))' >/dev/null \
  && rt_refuse "$RT_E_BOT_THREAD" "$([ -n "$issue" ] && echo "PR comment" || echo thread) $root_id was written by the bot account '$root_login'"

for s in $(printf '%s' "$body" | grep -oiE '\b[0-9a-f]{7,40}\b' | grep -E '[0-9]' | sort -u); do
  st=$(gh api "repos/$repo/compare/$s...$head" --jq .status 2>/dev/null) || st=""
  case "$st" in
    identical|ahead) ;;
    *) rt_refuse "$RT_E_BAD_SHA" "cited commit $s is not on the head branch of $repo#$pr${st:+ (compare: $st)}" ;;
  esac
done

# The cap. A review thread counts my header-carrying comments in it. PR conversation
# comments have no threads, so there it counts my header-carrying PR comments that link
# this comment's id (the "In reply to" line below writes that link).
if [ -n "$issue" ]; then
  mine=$(gh api --paginate "repos/$repo/issues/$pr/comments" \
           --jq "[.[] | select((.user.login | ascii_downcase) == (\"$self\" | ascii_downcase))] | .[].body | @json" 2>/dev/null) \
    || { echo "$RT_NAME: could not list PR comments on $repo#$pr" >&2; exit "$RT_E_CALL"; }
  count=$(printf '%s\n' "$mine" | jq -s --arg h "$AUTO_POST_HEADER" --arg ref "issuecomment-$cid" \
            'map(select(contains($h) and test($ref + "([^0-9]|$)"))) | length' 2>/dev/null || echo 0)
  where="replies to PR comment $cid"
else
  mine=$(gh api --paginate "repos/$repo/pulls/$pr/comments" \
           --jq "[.[] | select((.id == $root_id or .in_reply_to_id == $root_id) and (.user.login | ascii_downcase) == (\"$self\" | ascii_downcase))] | .[].body | @json" 2>/dev/null) \
    || { echo "$RT_NAME: could not list review comments on $repo#$pr" >&2; exit "$RT_E_CALL"; }
  count=$(printf '%s\n' "$mine" | jq -s --arg h "$AUTO_POST_HEADER" 'map(select(contains($h))) | length' 2>/dev/null || echo 0)
  where="replies in thread $root_id"
fi
if [ "${count:-0}" -ge "$AUTO_POST_MAX_REPLIES" ]; then
  echo "$RT_NAME: REFUSE: $self already has $count automated $where on $repo#$pr (max $AUTO_POST_MAX_REPLIES); escalate to a human" >&2
  exit "$RT_E_ESCALATE"
fi

# --- post ---------------------------------------------------------------------------------
if [ -n "$issue" ]; then
  link=$(printf '%s' "$target" | jq -r '.html_url // ""')
  [ -n "$link" ] || link="$(printf '%s' "$pr_json" | jq -r '.html_url // ""')#issuecomment-$cid"
  body="$body"$'\n\n'"In reply to $root_login: $link"
  endpoint="repos/$repo/issues/$pr/comments"; done_msg="replied to PR comment $cid"; wl_what="to comment $cid"
else
  endpoint="repos/$repo/pulls/$pr/comments/$root_id/replies"; done_msg="replied in thread $root_id"; wl_what="in thread $root_id"
fi
payload=$(jq -n --arg b "$body" '{body: $b}')
if [ -n "$dry" ]; then
  echo "$RT_NAME: dry run, would call: gh api -X POST $endpoint --input -"
  printf '%s\n' "$payload"
  exit 0
fi
resp=$(printf '%s' "$payload" | gh api -X POST "$endpoint" --input - 2>&1) \
  || { echo "$RT_NAME: POST failed: $resp" >&2; exit "$RT_E_CALL"; }
url=$(printf '%s' "$resp" | jq -r '.html_url // ""' 2>/dev/null)
echo "$RT_NAME: $done_msg on $repo#$pr ${url}"
rt_worklog --pr "${url:-#$pr}" --repo "$repo" \
  "auto-replied${category:+ ($category)} $wl_what on $repo#$pr; $url"
exit 0
