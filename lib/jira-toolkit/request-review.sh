#!/usr/bin/env bash
# request-review.sh — flip a draft PR to ready + request the reviewer team (the Gate-2
# "mark ready" action), or hand a reviewed PR back to its reviewers (re-review).
#
#   Draft PR:     mark ready, request the team.
#   Non-draft PR: re-request the prior human reviewers, those whose latest review is COMMENTED or
#                 CHANGES_REQUESTED (bots, the PR author and anyone already requested are skipped).
#                 The host drops a reviewer's request once they review, so this is what puts the
#                 PR back in their queue. With no prior human reviewer it requests the team.
#                 Refuses (exit 3, no writes) when nothing is new since the latest of those
#                 reviews: no commit after it and no reply or comment from the PR author.
#
#   request-review.sh <owner/repo> <pr-number> [--check] [--team <org/team>] [--outside-sprint]
#   request-review.sh owner/repo#123 [...]
#   --team            reviewer team (default: $GH_REVIEW_TEAM).
#   --outside-sprint  the ticket is NOT in the current sprint: add $GH_OUTSIDE_SPRINT_LABEL,
#                     but ONLY if that label exists in the repo (announced + skipped otherwise).
#   --check           read-only: print draft state, requested reviewers and what it would do;
#                     change nothing. Exits 3 when the real run would refuse.
# Exit: 0 done/no-op/check · 3 nothing new to hand back · 2 args · 1 error
set -uo pipefail
. "$(dirname "$(readlink "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")")/env.sh"
TEAM="${GH_REVIEW_TEAM:-}"; OUTSIDE_LABEL="$GH_OUTSIDE_SPRINT_LABEL"; BOTS="$GH_REVIEW_BOTS"
repo=""; num=""; mode="commit"; outside=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) mode="check" ;;
    --team)  TEAM="$2"; shift ;;
    --outside-sprint) outside=1 ;;
    *#*)     repo="${1%#*}"; num="${1#*#}" ;;
    */*)     repo="$1" ;;
    [0-9]*)  num="$1" ;;
    *) echo "request-review: unknown arg '$1'" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$repo" ] && [ -n "$num" ] || { echo "request-review: need <owner/repo> <pr-number>" >&2; exit 2; }
[ -n "$TEAM" ] || { echo "request-review: no reviewer team — set GH_REVIEW_TEAM in $JT_ENV_FILE or pass --team" >&2; exit 1; }

data=$(gh pr view "$num" -R "$repo" --json isDraft,reviewRequests,state,mergedAt,author,reviews,comments,commits 2>/dev/null)
[ -z "$data" ] && { echo "request-review: could not fetch $repo#$num" >&2; exit 1; }
isdraft=$(printf '%s' "$data" | jq -r '.isDraft')
reviewers=$(printf '%s' "$data" | jq -r '[.reviewRequests[]? | (.name // .slug // .login)] | join(", ")')
has_team=$(printf '%s' "$data" | jq -r --arg t "$TEAM" 'any(.reviewRequests[]?; (.slug // "") == $t)')   # team requests carry org/team in .slug

# Re-review plan for a non-draft PR, tab-separated: prior human reviewers not yet requested,
# those already requested, and whether anything landed after their latest review (a commit, or a
# review/thread reply/comment by the PR author). Thread replies arrive as the author's reviews.
plan=$(printf '%s' "$data" | jq -r --arg bots "$BOTS" '
  . as $pr | (.author.login // "") as $me
  | ($bots | split(" ") | map(select(. != "") | ascii_downcase)) as $bot
  | [.reviewRequests[]? | .login // empty | ascii_downcase] as $requested
  | [.reviews[]? | select(.state != "PENDING" and (.author.login // "") != "")]
  | group_by(.author.login) | map(max_by(.submittedAt))
  | map(select((.state == "COMMENTED" or .state == "CHANGES_REQUESTED") and .author.login != $me
               and ((.author.login | ascii_downcase) as $l | ($bot | index([$l]) | not) and ($l | endswith("[bot]") | not)))) as $prior
  | ($prior | map(.submittedAt) | max // "") as $since
  | [ ($prior | map(.author.login | select((ascii_downcase) as $l | $requested | index([$l]) | not)) | join(" ")),
      ($prior | map(.author.login | select((ascii_downcase) as $l | $requested | index([$l]))) | join(" ")),
      ( [ ($pr.commits[]? | .committedDate),
          ($pr.reviews[]? | select(.author.login == $me) | .submittedAt),
          ($pr.comments[]? | select(.author.login == $me) | .createdAt) ]
        | any(. > $since) | tostring ) ]
  | map(if . == "" then "-" else . end) | @tsv') || { echo "request-review: could not read the review history of $repo#$num" >&2; exit 1; }
IFS=$'\t' read -r rereq already fresh <<<"$plan"
[ "$rereq" = "-" ] && rereq=""; [ "$already" = "-" ] && already=""
rereview=0; { [ "$isdraft" != "true" ] && [ -n "$rereq$already" ]; } && rereview=1
stale=0; { [ "$rereview" = 1 ] && [ "$fresh" != "true" ]; } && stale=1
refuse_msg="request-review: REFUSE — $repo#$num has nothing new since the last review by ${rereq:+$rereq }${already}: no commit and no reply from the PR author after it. Push the fixes or reply to the threads first."

if [ "$mode" = "check" ]; then
  if [ "$stale" = 1 ]; then echo "$refuse_msg"; exit 3; fi
  if [ "$rereview" = 1 ]; then
    if [ -n "$rereq" ]; then would="re-request $rereq"; else would="nothing to re-request"; fi
    would="${would}${already:+ ($already already requested)}"
  else
    would="$([ "$isdraft" = "true" ] && echo 'mark ready, ' )$([ "$has_team" = "true" ] && echo "team $TEAM already requested" || echo "request $TEAM")"
  fi
  echo "request-review: $repo#$num — isDraft=$isdraft; reviewers=[${reviewers:-none}]; would: ${would}$([ "$outside" = "1" ] && echo ", add label '$OUTSIDE_LABEL' if repo has it")."
  exit 0
fi
[ "$stale" = 1 ] && { echo "$refuse_msg" >&2; exit 3; }

did=""
if [ "$isdraft" = "true" ]; then
  gh pr ready "$num" -R "$repo" >/dev/null 2>&1 && did="marked ready; " || { echo "request-review: gh pr ready failed for $repo#$num" >&2; exit 1; }
fi
if [ "$rereview" = 1 ]; then
  if [ -n "$rereq" ]; then
    args=(); for r in $rereq; do args+=(-f "reviewers[]=$r"); done
    gh api -X POST "repos/$repo/pulls/$num/requested_reviewers" "${args[@]}" >/dev/null 2>&1 \
      && did="re-requested ${rereq// /, }" || { echo "request-review: re-requesting $rereq failed for $repo#$num" >&2; exit 1; }
  else
    did="${already// /, } already requested"
  fi
elif [ "$has_team" != "true" ]; then
  gh pr edit "$num" -R "$repo" --add-reviewer "$TEAM" >/dev/null 2>&1 && did="${did}requested $TEAM" || { echo "request-review: --add-reviewer $TEAM failed for $repo#$num" >&2; exit 1; }
else
  did="${did}$TEAM already requested"
fi

if [ "$outside" = "1" ]; then
  if gh label list -R "$repo" --limit 500 2>/dev/null | cut -f1 | grep -qxF "$OUTSIDE_LABEL"; then
    if gh pr view "$num" -R "$repo" --json labels -q '.labels[].name' 2>/dev/null | grep -qxF "$OUTSIDE_LABEL"; then
      did="${did}; label '$OUTSIDE_LABEL' already set"
    elif gh pr edit "$num" -R "$repo" --add-label "$OUTSIDE_LABEL" >/dev/null 2>&1; then
      did="${did}; +label '$OUTSIDE_LABEL'"
    else
      echo "request-review: warn — could not add label '$OUTSIDE_LABEL' to $repo#$num" >&2
    fi
  else
    echo "request-review: NOTICE — '$OUTSIDE_LABEL' label does not exist in $repo; skipping label addition. Create it (gh label create) if this repo should carry it." >&2
    did="${did}; label '$OUTSIDE_LABEL' NOT in $repo — announced + skipped"
  fi
fi

echo "request-review: $repo#$num — ${did:-no change needed}."
[ -n "$did" ] && jt_worklog --pr "$repo#$num" --repo "$repo" "$repo#$num $did"
exit 0
