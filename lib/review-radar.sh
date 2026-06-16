#!/usr/bin/env bash
# review-radar.sh — team-wide "stuck waiting on review" monitor.
#
# Emits one JSON object describing the review state of every OPEN PR across your
# configured repos. The core signal — `waiting[]` — is every non-draft PR that currently has a
# pending review request, i.e. a reviewer was asked and has taken no review action
# since that (re-)request. GitHub removes a reviewer from `reviewRequests` the moment
# they submit a review and re-adds them on a re-request, so a non-empty `reviewRequests`
# list IS the "requested + no action since" signal.
#
# That signal has a blind spot: a PR that's open, not approved, but has NO reviewer
# requested isn't "waiting on a reviewer" — it's waiting on the AUTHOR to assign one
# (or to push fixes). Those are easy to lose track of, so we also emit `unrequested[]`.
# Everything else (approved-pending-merge, changes-requested, drafts, dependabot) is
# author-side / out-of-lane and is reduced to `counts` so the report can summarize
# without listing them.
#
# Per pending reviewer we compute how long they've been waiting in WORKING days
# (Sat/Sun excluded) from the most recent ReviewRequestedEvent for that reviewer.
#
# Usage:
#   review-radar.sh [--repos "A B C"] [--me <login>]
#
#   --repos   space-separated repo list under $SOURCE_DIR (default: override via REPOS env var)
#   --me      GitHub login to flag "waiting on you" / "mine" (default: override via ME env var)
#
# Output shape (arrays default to [] on failure — never errors out):
#   {
#     generatedAt, now,
#     me,                       # the login used for waitingOnMe / mine
#     waiting: [ {              # a reviewer was ASKED and hasn't acted — the core signal
#       repo, number, title, url, author, isDraft, reviewDecision,
#       pendingReviewers: [ {reviewer, type:"user"|"team", requestedAt, waitingDays} ],
#       maxWaitingDays,         # worst (longest) pending reviewer — sort key
#       waitingOnMe             # true if `me` is among pending user reviewers
#     } ],                      # sorted by maxWaitingDays desc, then repo#number
#     unrequested: [ {          # open, non-draft, NOT approved, but NO reviewer requested
#       repo, number, title, url, author, reviewDecision, ageDays, mine
#     } ],                      # ball is on the AUTHOR to request/assign — radar's blind spot.
#                               # human authors only (bots excluded); CHANGES_REQUESTED excluded
#                               # (that's address-feedback, not needs-a-reviewer). Sorted ageDays desc.
#     counts: {                 # context piles, NOT waiting-on-review — for a one-line summary
#       approvedPendingMerge,   #   approved + no pending reviewer (human) → author merges
#       changesRequested,       #   a reviewer asked for changes (human) → author addresses
#       drafts,                 #   non-bot draft PRs
#       dependabot              #   bot-authored PRs (own /dependabot-triage lane)
#     }
#   }
#
# Notes / quirks:
#   - A single GraphQL call per repo fetches open PRs + their pending reviewers +
#     the REVIEW_REQUESTED_EVENT timeline in one shot (cheap; no per-PR fan-out).
#   - Working-days math mirrors workspace-context.sh: uses strflocaltime format
#     codes (not positional array fields) to stay correct across jq/gojq builds.

set -uo pipefail

SOURCE_DIR="${SOURCE_DIR:-$HOME/Projects}"
REPOS="${REPOS:-Repo1 Repo2 Repo3 Repo4}"
ME="${ME:-$(gh api user -q .login 2>/dev/null || echo me)}"
while [ $# -gt 0 ]; do
  case "$1" in
    --repos) REPOS="$2"; shift 2 ;;
    --me)    ME="$2"; shift 2 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) shift ;;
  esac
done

NOW_EPOCH=$(date +%s)
NOW=$(date '+%-I:%M %p')
GENERATED_AT=$(date +%Y-%m-%dT%H:%M:%S%z)

read -r -d '' GQL <<'EOF'
query($owner:String!, $name:String!) {
  repository(owner:$owner, name:$name) {
    pullRequests(states:OPEN, first:80, orderBy:{field:CREATED_AT, direction:ASC}) {
      nodes {
        number title url isDraft createdAt reviewDecision
        author { __typename login }
        reviewRequests(first:20) {
          nodes { requestedReviewer { __typename ... on User { login } ... on Team { name } } }
        }
        timelineItems(itemTypes:[REVIEW_REQUESTED_EVENT], first:100) {
          nodes { ... on ReviewRequestedEvent {
            createdAt
            requestedReviewer { __typename ... on User { login } ... on Team { name } }
          } }
        }
      }
    }
  }
}
EOF

ALLPRS="[]"
for repo in $REPOS; do
  [ -d "$SOURCE_DIR/$repo/.git" ] || continue
  nwo=$( (cd "$SOURCE_DIR/$repo" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) )
  [ -n "$nwo" ] || continue
  owner="${nwo%%/*}"; name="${nwo##*/}"

  raw=$(gh api graphql -f query="$GQL" -F owner="$owner" -F name="$name" 2>/dev/null)
  [ -n "$raw" ] || continue

  # One record per OPEN PR (drafts/bots included — the final pass buckets them).
  arr=$(printf '%s' "$raw" | jq --arg repo "$repo" --argjson now "$NOW_EPOCH" '
    def secsintoday($e): ($e|strflocaltime("%H")|tonumber)*3600 + ($e|strflocaltime("%M")|tonumber)*60 + ($e|strflocaltime("%S")|tonumber);
    def localmid($e): $e - secsintoday($e);
    def isweekend($e): ($e|strflocaltime("%u")|tonumber) > 5;   # %u: 1=Mon..7=Sun
    def busdays($iso): ($iso|fromdateiso8601) as $u
      | localmid($u) as $um | localmid($now) as $nm
      | (($nm - $um) / 86400 | round) as $days
      | if $days <= 0 then 0
        else ([range(1; $days + 1) | ($um + (. * 86400) + 43200) | select(isweekend(.) | not)] | length) end;
    # normalize a requestedReviewer node to {reviewer, type}
    def ident: if .__typename == "Team" then {reviewer:(.name//""), type:"team"} else {reviewer:(.login//""), type:"user"} end;

    [ .data.repository.pullRequests.nodes[]
      | . as $pr
      | ([ .timelineItems.nodes[] | select(.requestedReviewer != null)
           | { id:(.requestedReviewer|ident), at:.createdAt } ]) as $events
      | ([ .reviewRequests.nodes[] | select(.requestedReviewer != null) | (.requestedReviewer|ident) ]) as $pending
      | ($pending | map(
          . as $p
          | ([ $events[] | select(.id == $p) | .at ] | sort | last) as $reqAt
          | ($reqAt // $pr.createdAt) as $reqAt
          | { reviewer:$p.reviewer, type:$p.type, requestedAt:$reqAt, waitingDays: busdays($reqAt) }
        )) as $pr_reviewers
      | { repo:$repo, number:$pr.number, title:$pr.title, url:$pr.url,
          author:($pr.author.login // ""),
          authorIsBot: (($pr.author.__typename // "") == "Bot"),
          isDraft:$pr.isDraft,
          reviewDecision: ($pr.reviewDecision // "NONE"),
          createdAt: $pr.createdAt,
          ageDays: busdays($pr.createdAt),
          pendingReviewers:$pr_reviewers,
          maxWaitingDays: ([ $pr_reviewers[].waitingDays ] | max // 0) }
    ]' 2>/dev/null || echo '[]')

  ALLPRS=$(jq -n --argjson a "$ALLPRS" --argjson b "${arr:-[]}" '$a + $b' 2>/dev/null || echo "$ALLPRS")
done

# Derive the buckets + counts from the full PR set.
jq -n \
  --arg generatedAt "$GENERATED_AT" --arg now "$NOW" --arg me "$ME" \
  --argjson all "${ALLPRS:-[]}" '
  ($all | map(select(.isDraft | not) | select(.pendingReviewers | length > 0))
    | map(. + { waitingOnMe: (any(.pendingReviewers[]; .type=="user" and .reviewer==$me)) })
    | map({repo, number, title, url, author, isDraft, reviewDecision, pendingReviewers, maxWaitingDays, waitingOnMe})
    | sort_by([ -(.maxWaitingDays), .repo, .number ])) as $waiting
  | ($all | map(select(.isDraft | not) | select(.authorIsBot | not)
                | select(.pendingReviewers | length == 0)
                | select(.reviewDecision != "APPROVED" and .reviewDecision != "CHANGES_REQUESTED"))
    | map({repo, number, title, url, author, reviewDecision, ageDays, mine: (.author == $me)})
    | sort_by([ -(.ageDays), .repo, .number ])) as $unrequested
  | { generatedAt:$generatedAt, now:$now, me:$me,
      waiting:$waiting,
      unrequested:$unrequested,
      counts: {
        approvedPendingMerge: ($all | map(select(.isDraft|not) | select(.authorIsBot|not) | select(.pendingReviewers|length==0) | select(.reviewDecision=="APPROVED")) | length),
        changesRequested:     ($all | map(select(.isDraft|not) | select(.authorIsBot|not) | select(.pendingReviewers|length==0) | select(.reviewDecision=="CHANGES_REQUESTED")) | length),
        drafts:               ($all | map(select(.isDraft) | select(.authorIsBot|not)) | length),
        dependabot:           ($all | map(select(.authorIsBot)) | length)
      } }'
