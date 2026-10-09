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
# maintainer is a currently requested reviewer (in person, or through a team slug listed in
# AUTO_POST_TEAMS), the maintainer has no review on this head.
#
# A category label is the first thing in a comment body after any leading blockquote and
# blank lines (an automated-review header). It is one of AUTO_POST_LABELS (any case),
# written `label:`, `**label:**`, `**label**:` or `[label]`. The colon forms take an
# optional Conventional Comments decoration: `issue (blocking):`,
# `**suggestion (non-blocking, security):**`.
#
# Exit: 0 posted or dry run · 1 a gh call failed · 2 bad arguments or payload
#       10 kill switch present · 11 repo not in AUTO_POST_REPOS
#       12 PR author not in AUTO_POST_AUTHORS · 13 AUTO_POST_SELF not a requested reviewer
#       14 event other than COMMENT · 15 an inline comment lacks a category label
#       16 AUTO_POST_SELF already reviewed the current head · 17 head moved since the payload
set -uo pipefail
. "$(dirname "$(readlink "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")")/review-env.sh"

# Label alternation from AUTO_POST_LABELS. Labels are plain words so they need no escaping.
labels_json=$(printf '%s' "$AUTO_POST_LABELS" | jq -Rc '[split(",")[] | gsub("\\s"; "") | ascii_downcase | select(. != "")] | reduce .[] as $x ([]; if index([$x]) then . else . + [$x] end)')
jq -e 'length > 0 and all(test("^[a-z0-9][a-z0-9-]*$"))' <<<"$labels_json" >/dev/null \
  || rt_usage "AUTO_POST_LABELS must be a comma list of words, got '$AUTO_POST_LABELS'"
alt=$(jq -r 'join("|")' <<<"$labels_json")
# Captures: 3 bracketed label, 4 colon-form label, 6 decoration.
LABEL_RE="^\\s*(\\*\\*)?(\\[($alt)\\]|($alt)(\\s*\\(([^)\\n]*)\\))?(:\\*\\*|\\*\\*:|:))"
# label_of: the body with leading blockquote and blank lines dropped, matched against
# LABEL_RE. Emits {label, blocking} or nothing.
LABEL_JQ='def label_of($re):
  split("\n") | until(length == 0 or (.[0] | test("^\\s*(>.*)?$") | not); .[1:]) | join("\n")
  | [match($re; "i").captures] | select(length > 0) | .[0]
  | {label: ((.[2].string // .[3].string) | ascii_downcase),
     blocking: ((.[5].string // "") | split(",") | map(gsub("\\s"; "") | ascii_downcase) | index("blocking") != null)};'

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

unlabeled=$(jq -r --arg re "$LABEL_RE" "$LABEL_JQ"' [(.comments // [])[] | select([.body | label_of($re)] | length == 0) | "\(.path):\(.line // .position // "?")"] | join(", ")' "$payload")
[ -z "$unlabeled" ] || rt_refuse "$RT_E_UNLABELED" "inline comments without a category label ($(jq -r 'join(" / ")' <<<"$labels_json")): $unlabeled"

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
# Team membership is asserted by config: AUTO_POST_TEAMS lists the maintainer's own teams.
requested=""
printf '%s' "$pr_json" | jq -e --arg me "$self" 'any(.requested_reviewers[]?; (.login | ascii_downcase) == ($me | ascii_downcase))' >/dev/null && requested=1
if [ -z "$requested" ]; then
  while IFS= read -r team; do
    rt_in_list "$team" "$AUTO_POST_TEAMS" && { requested=1; break; }
  done < <(printf '%s' "$pr_json" | jq -r '.requested_teams[]?.slug // empty')
fi
[ -n "$requested" ] || rt_refuse "$RT_E_NOT_REQUESTED" "neither $self nor a team in AUTO_POST_TEAMS is a currently requested reviewer on $repo#$pr"
mine=$(gh api --paginate "repos/$repo/pulls/$pr/reviews" \
         --jq ".[] | select((.user.login | ascii_downcase) == (\"$self\" | ascii_downcase) and .commit_id == \"$head\") | .id" 2>/dev/null) \
  || { echo "$RT_NAME: could not list reviews on $repo#$pr" >&2; exit "$RT_E_CALL"; }
[ -z "$mine" ] || rt_refuse "$RT_E_ALREADY" "$self already reviewed $repo#$pr at ${head:0:7}"

# --- post ---------------------------------------------------------------------------------
body=$(jq --arg sha "$head" '{commit_id: $sha, body: (.body // ""), event: "COMMENT",
  comments: [(.comments // [])[] | with_entries(select(.key | IN("path","body","line","side","start_line","start_side","position","subject_type")))]}' "$payload")
# Counts by label word and blocking flag, in AUTO_POST_LABELS order, blocking first.
counts=$(jq -r --arg re "$LABEL_RE" --argjson labels "$labels_json" "$LABEL_JQ"' [(.comments // [])[] | .body | label_of($re)]
  as $l | [$labels[] as $c | (true, false) as $b | ($l | map(select(.label == $c and .blocking == $b)) | length) as $n
           | select($n > 0) | "\($n) \($c)\(if $b then " (blocking)" else "" end)"]
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
