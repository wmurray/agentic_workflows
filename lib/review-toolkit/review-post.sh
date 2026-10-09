#!/usr/bin/env bash
# review-post.sh: post an agent-written review on someone else's PR under the maintainer's
# account, without the maintainer reading it first. Opt-in: every guard lives here, in code,
# and the allowlists default to empty, so an unconfigured install refuses everything.
#
#   review-post.sh <owner/repo> <pr> <payload.json> [--verdict would-approve|would-not-approve] [--dry-run]
#
#   payload.json  {"head_sha": "<sha the review was computed against>", "body": "...",
#                  "comments": [{"path", "line", "side", "start_line", "start_side", "body"}, ...]}
#                 GitHub review API shape. `commit_id` is accepted in place of `head_sha`.
#                 An `event` other than COMMENT is refused.
#   --verdict     logged to the work log, never posted.
#   --dry-run     run every check, then print the API call instead of making it.
#
# Guards, in order: kill switch, event is COMMENT, every inline comment opens with a
# category label, repo allowlisted, PR author allowlisted, head has not moved, the
# maintainer is a currently requested reviewer, the maintainer has no review on this head.
#
# A category label is the first thing in a comment body, one of must-fix, should-fix, nit,
# question (any case), written `label:`, `**label:**`, `**label**:` or `[label]`.
#
# Exit: 0 posted or dry run · 1 a gh call failed · 2 bad arguments or payload
#       10 kill switch present · 11 repo not in AUTO_POST_REPOS
#       12 PR author not in AUTO_POST_AUTHORS · 13 AUTO_POST_SELF not a requested reviewer
#       14 event other than COMMENT · 15 an inline comment lacks a category label
#       16 AUTO_POST_SELF already reviewed the current head · 17 head moved since the payload
set -uo pipefail
. "$(dirname "$(readlink "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")")/review-env.sh"

LABEL_RE='^\s*(\*\*)?(\[(must-fix|should-fix|nit|question)\]|(must-fix|should-fix|nit|question)(:\*\*|\*\*:|:))'

repo=""; pr=""; payload=""; verdict=""; dry=""; event=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1 ;;
    --verdict) verdict="${2:-}"; shift ;;
    --event)   event="${2:-}"; shift ;;
    --approve) event="APPROVE" ;;
    --request-changes) event="REQUEST_CHANGES" ;;
    -*) rt_usage "unknown flag '$1'" ;;
    *) if [ -z "$repo" ]; then repo="$1"; elif [ -z "$pr" ]; then pr="$1"
       elif [ -z "$payload" ]; then payload="$1"; else rt_usage "unexpected arg '$1'"; fi ;;
  esac
  shift
done
[ -n "$payload" ] || rt_usage "usage: review-post.sh <owner/repo> <pr> <payload.json> [--verdict would-approve|would-not-approve] [--dry-run]"
printf '%s' "$repo" | grep -qE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || rt_usage "repo must be owner/repo, got '$repo'"
printf '%s' "$pr" | grep -qE '^[0-9]+$' || rt_usage "pr must be a number, got '$pr'"
case "$verdict" in ""|would-approve|would-not-approve) ;; *) rt_usage "--verdict must be would-approve or would-not-approve" ;; esac
[ -f "$payload" ] || rt_usage "payload file not found: $payload"

rt_kill_switch

# --- payload checks (local) ---------------------------------------------------------------
jq -e 'type == "object"' "$payload" >/dev/null 2>&1 || rt_usage "payload is not a JSON object: $payload"
sha=$(jq -r '(.head_sha // .commit_id // "")' "$payload")
printf '%s' "$sha" | grep -qE '^[0-9a-f]{7,40}$' || rt_usage "payload needs head_sha (the commit the review was computed against)"
jq -e '(.comments // []) | type == "array" and all(type == "object" and (.path | type == "string") and (.body | type == "string"))' "$payload" >/dev/null \
  || rt_usage "payload comments must be objects with path and body"
jq -e '((.body // "") != "") or ((.comments // []) | length > 0)' "$payload" >/dev/null || rt_usage "payload has neither a body nor comments"

[ -n "$event" ] || event=$(jq -r '.event // "COMMENT"' "$payload")
[ "$(printf '%s' "$event" | tr '[:lower:]' '[:upper:]')" = "COMMENT" ] \
  || rt_refuse "$RT_E_EVENT" "event '$event' is not allowed; this wrapper only posts COMMENT reviews"

unlabeled=$(jq -r --arg re "$LABEL_RE" '[(.comments // [])[] | select(.body | test($re; "i") | not) | "\(.path):\(.line // .position // "?")"] | join(", ")' "$payload")
[ -z "$unlabeled" ] || rt_refuse "$RT_E_UNLABELED" "inline comments without a category label (must-fix / should-fix / nit / question): $unlabeled"

rt_check_repo "$repo"

# --- PR checks (gh reads) -----------------------------------------------------------------
self=$(rt_self) || exit "$RT_E_CALL"
pr_json=$(gh api "repos/$repo/pulls/$pr" 2>/dev/null) || { echo "$RT_NAME: could not read $repo#$pr" >&2; exit "$RT_E_CALL"; }
author=$(printf '%s' "$pr_json" | jq -r '.user.login // ""')
head=$(printf '%s' "$pr_json" | jq -r '.head.sha // ""')

rt_in_list "$author" "$AUTO_POST_AUTHORS" || rt_refuse "$RT_E_AUTHOR" "$repo#$pr author '$author' is not in AUTO_POST_AUTHORS"
case "$head" in
  "$sha"*) ;;
  *) rt_refuse "$RT_E_HEAD_MOVED" "head moved: payload was computed against $sha, $repo#$pr head is now $head" ;;
esac
printf '%s' "$pr_json" | jq -e --arg me "$self" 'any(.requested_reviewers[]?; (.login | ascii_downcase) == ($me | ascii_downcase))' >/dev/null \
  || rt_refuse "$RT_E_NOT_REQUESTED" "$self is not a currently requested reviewer on $repo#$pr"
mine=$(gh api --paginate "repos/$repo/pulls/$pr/reviews" \
         --jq ".[] | select((.user.login | ascii_downcase) == (\"$self\" | ascii_downcase) and .commit_id == \"$head\") | .id" 2>/dev/null) \
  || { echo "$RT_NAME: could not list reviews on $repo#$pr" >&2; exit "$RT_E_CALL"; }
[ -z "$mine" ] || rt_refuse "$RT_E_ALREADY" "$self already reviewed $repo#$pr at ${head:0:7}"

# --- post ---------------------------------------------------------------------------------
body=$(jq --arg sha "$head" '{commit_id: $sha, body: (.body // ""), event: "COMMENT",
  comments: [(.comments // [])[] | with_entries(select(.key | IN("path","body","line","side","start_line","start_side","position","subject_type")))]}' "$payload")
counts=$(jq -r --arg re "$LABEL_RE" '[(.comments // [])[] | .body | match($re; "i").captures | ((.[2].string // .[3].string // "") | ascii_downcase)]
  as $l | ["must-fix","should-fix","nit","question"] | map(. as $c | ($l | map(select(. == $c)) | length) as $n | select($n > 0) | "\($n) \($c)")
  | if length == 0 then "no inline comments" else join(", ") end' "$payload")

if [ -n "$dry" ]; then
  echo "$RT_NAME: dry run, would call: gh api -X POST repos/$repo/pulls/$pr/reviews --input -"
  printf '%s\n' "$body"
  echo "$RT_NAME: $counts${verdict:+; verdict $verdict (not posted)}"
  exit 0
fi

resp=$(printf '%s' "$body" | gh api -X POST "repos/$repo/pulls/$pr/reviews" --input - 2>&1) \
  || { echo "$RT_NAME: POST failed: $resp" >&2; exit "$RT_E_CALL"; }
url=$(printf '%s' "$resp" | jq -r '.html_url // ""' 2>/dev/null)
echo "$RT_NAME: posted COMMENT review on $repo#$pr ($counts) ${url}"
[ -z "$verdict" ] || echo "$RT_NAME: verdict $verdict (logged, not posted)"
rt_worklog --pr "${url:-#$pr}" --repo "$repo" \
  "auto-posted review on $repo#$pr at ${head:0:7}: $counts${verdict:+; verdict $verdict (not posted)}; $url"
exit 0
