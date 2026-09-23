#!/usr/bin/env bash
# request-review.sh — flip a draft PR to ready + request the reviewer team. The Gate-2
# "mark ready" action.
#
#   request-review.sh <owner/repo> <pr-number> [--check] [--team <org/team>] [--outside-sprint]
#   request-review.sh owner/repo#123 [...]
#   --team            reviewer team (default: $GH_REVIEW_TEAM).
#   --outside-sprint  the ticket is NOT in the current sprint: add $GH_OUTSIDE_SPRINT_LABEL,
#                     but ONLY if that label exists in the repo (announced + skipped otherwise).
#   --check           read-only: print draft state + requested reviewers, change nothing.
# Exit: 0 done/no-op/check · 2 args · 1 error
set -uo pipefail
. "$(dirname "$(readlink "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")")/env.sh"
TEAM="${GH_REVIEW_TEAM:-}"; OUTSIDE_LABEL="$GH_OUTSIDE_SPRINT_LABEL"
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

data=$(gh pr view "$num" -R "$repo" --json isDraft,reviewRequests,state,mergedAt 2>/dev/null)
[ -z "$data" ] && { echo "request-review: could not fetch $repo#$num" >&2; exit 1; }
isdraft=$(printf '%s' "$data" | jq -r '.isDraft')
reviewers=$(printf '%s' "$data" | jq -r '[.reviewRequests[]? | (.name // .slug // .login)] | join(", ")')
has_team=$(printf '%s' "$data" | jq -r --arg t "$TEAM" 'any(.reviewRequests[]?; (.slug // "") == $t)')   # team requests carry org/team in .slug

if [ "$mode" = "check" ]; then
  echo "request-review: $repo#$num — isDraft=$isdraft; reviewers=[${reviewers:-none}]; would: $([ "$isdraft" = "true" ] && echo 'mark ready, ' )$([ "$has_team" = "true" ] && echo "team $TEAM already requested" || echo "request $TEAM")$([ "$outside" = "1" ] && echo ", add label '$OUTSIDE_LABEL' if repo has it")."
  exit 0
fi

did=""
if [ "$isdraft" = "true" ]; then
  gh pr ready "$num" -R "$repo" >/dev/null 2>&1 && did="marked ready; " || { echo "request-review: gh pr ready failed for $repo#$num" >&2; exit 1; }
fi
if [ "$has_team" != "true" ]; then
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
