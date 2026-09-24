#!/usr/bin/env bash
# github.sh — the GitHub implementation of the host adapter contract (see ../CONTRACT.md).
#
# READ-ONLY. Flat PR lists come back as a JSON array (one superset schema both consumers
# jq down to what they need); review threads come back normalized so the engine's
# bot/self filtering + verdict stay host-agnostic. The engine owns all board logic;
# this file only speaks GitHub. Dispatch: `host <op> …` → this script with $1=op.
#
#   host list_prs owner/repo all
#   host list_prs owner/repo open mine
#   host review_threads owner/repo 123
#   host whoami
#   host capabilities
set -uo pipefail

op="${1:-}"; shift || true

case "$op" in
  list_prs)
    repo="${1:-}"; state="${2:-all}"; mine="${3:-}"
    [ -n "$repo" ] || { echo "github list_prs: need <owner/repo>" >&2; exit 2; }
    # Superset field set: mc-poll reads the review/CI/merge fields, mc-orphans reads
    # title/headRefName/author/url. One call serves both.
    fields="number,title,headRefName,isDraft,author,url,state,reviewDecision,mergeable,mergedAt,statusCheckRollup,reviewRequests"
    if [ "$mine" = "mine" ]; then
      gh pr list -R "$repo" --state "$state" -L 60 --author "@me" --json "$fields" 2>/dev/null || echo '[]'
    else
      gh pr list -R "$repo" --state "$state" -L 60 --json "$fields" 2>/dev/null || echo '[]'
    fi
    ;;

  review_threads)
    repo="${1:-}"; num="${2:-}"
    [ -n "$repo" ] && [ -n "$num" ] || { echo "github review_threads: need <owner/repo> <num>" >&2; exit 2; }
    owner="${repo%%/*}"; name="${repo##*/}"
    # reviewThreads is NOT a `gh pr view --json` field — it must be graphql. Fetch the
    # decision + all threads (first comment's author/body, latest updatedAt) + all
    # review summaries, then normalize to the contract shape (no filtering — that's the
    # engine's job, so it ports to other hosts).
    raw=$(gh api graphql \
      -f query='query($owner:String!,$name:String!,$number:Int!){
        repository(owner:$owner,name:$name){
          pullRequest(number:$number){
            reviewDecision
            reviewThreads(first:100){ nodes{
              isResolved isOutdated path line
              comments(first:50){ nodes{ author{login} body updatedAt } }
            }}
            reviews(first:100){ nodes{ author{login} state body submittedAt } }
          }
        }
      }' -F owner="$owner" -F name="$name" -F number="$num" 2>/dev/null) \
      || { echo "github review_threads: graphql failed for $repo#$num (auth? PR exists?)" >&2; exit 1; }
    printf '%s' "$raw" | jq -c '
      .data.repository.pullRequest as $pr
      | { reviewDecision: ($pr.reviewDecision // "none"),
          threads: [ $pr.reviewThreads.nodes[] | {
              isResolved, isOutdated, path, line: (.line // 0),
              author: (.comments.nodes[0].author.login // ""),
              body:   (.comments.nodes[0].body // ""),
              latest: ([.comments.nodes[].updatedAt] | max) } ],
          reviews: [ ($pr.reviews.nodes // [])[] | {
              state, author: (.author.login // ""),
              body: (.body // ""), submittedAt } ] }'
    ;;

  whoami)
    # Auth/reachability probe. Print the login on success; on failure exit nonzero with
    # gh's error text on stderr — mc-health wraps this in a bounded runner and classifies
    # auth(401) vs unreachable(network). We just supply the auth-gated call.
    gh api user --jq '.login'
    ;;

  capabilities)
    echo "review_threads"
    ;;

  *)
    echo "github: unknown op '$op'" >&2; exit 2 ;;
esac
