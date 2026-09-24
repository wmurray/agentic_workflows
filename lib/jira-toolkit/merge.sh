#!/usr/bin/env bash
# merge.sh — guarded PR merge. The MERGE PRECONDITIONS live here, in code, not in a
# permission prompt and not in an LLM's discipline, so this can be allow-listed for
# unattended execution without weakening the safety gate.
#
# It does NOT decide to merge; authorization is upstream. A failed precondition is a no-op
# plus a printed reason, NEVER a force-merge.
#
# Preconditions (ALL must hold):
#   • not draft · reviewDecision == APPROVED · mergeable == MERGEABLE
#   • approval is CURRENT — no pending reviewRequests AND no NEW AUTHORED work after the
#     latest APPROVED review. GitHub keeps reviewDecision sticky across new commits, so a
#     post-approval change means re-review is pending. Staleness is classified by
#     authoredDate vs committedDate: a rebase rewrites committedDate but PRESERVES
#     authoredDate, so "HEAD recommitted after approval, no authoredDate after approval" =
#     rebase-only. New authored work → refuse, no override. Rebase-only → refuse unless
#     --allow-rebase-stale (flag-gated because a force-push can rewrite content while
#     preserving authoredDate).
#   • CI green — every non-freeze check SUCCESS/NEUTRAL/SKIPPED, none pending
#   • not sprint-frozen — a red check matching $GH_FREEZE_CHECK_PATTERN is the "clear with
#     QA first" gate; refuse unless --allow-freeze
#   • no blocking label ($GH_BLOCK_LABELS, case-insensitive) — an explicit human veto with
#     NO override (remove the label to merge)
#
# Post-merge cleanup (best-effort, never fails the merge): strips any $GH_SPRINT_LABELS
# label (merging pulls the ticket INTO the sprint, so the label is stale), and when one
# was stripped adds the ticket to the active sprint via sprint-add.sh, deriving the key
# from the PR branch (falling back to the title).
#
#   merge.sh <owner/repo> <pr-number> [--check] [--allow-freeze] [--allow-rebase-stale] [--method squash|merge|rebase]
#   merge.sh owner/repo#123 [...]
#   --check   dry-run: print the precondition verdict, merge nothing
#   --method  merge method (default: $GH_MERGE_METHOD)
# Exit: 0 merged (or --check pass) · 3 precondition failed · 2 bad args · 1 error
set -uo pipefail
. "$(dirname "$(readlink "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")")/env.sh"
jt_guard || exit $?

repo=""; num=""; mode="commit"; allow_freeze=0; allow_rebase_stale=0; method="$GH_MERGE_METHOD"
while [ $# -gt 0 ]; do
  case "$1" in
    --check)              mode="check" ;;
    --allow-freeze)       allow_freeze=1 ;;
    --allow-rebase-stale) allow_rebase_stale=1 ;;
    --method)             method="$2"; shift ;;
    *#*)            repo="${1%#*}"; num="${1#*#}" ;;
    */*)            repo="$1" ;;
    [0-9]*)         num="$1" ;;
    *) echo "merge: unknown arg '$1'" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$repo" ] && [ -n "$num" ] || { echo "merge: need <owner/repo> <pr-number>" >&2; exit 2; }

data=$(gh pr view "$num" -R "$repo" \
  --json number,isDraft,reviewDecision,mergeable,state,mergedAt,statusCheckRollup,reviewRequests,latestReviews,commits,labels,headRefName,title 2>/dev/null)
[ -z "$data" ] && { echo "merge: could not fetch $repo#$num (gh)" >&2; exit 1; }

# ALL reviews via REST, not latestReviews: the latter is scoped to each reviewer's most
# recent state, so an APPROVED followed by that reviewer's own COMMENTED follow-up erases
# the approval timestamp even though reviewDecision stays APPROVED.
reviews=$(gh api "repos/$repo/pulls/$num/reviews" --paginate 2>/dev/null)
[ -z "$reviews" ] && reviews="[]"

if [ "$(printf '%s' "$data" | jq -r '.mergedAt // "null"')" != "null" ]; then
  echo "merge: $repo#$num already merged — no-op."; exit 0
fi

verdict=$(printf '%s' "$data" | jq -r --argjson allow_freeze "$allow_freeze" --argjson allow_rebase_stale "$allow_rebase_stale" \
    --arg block_labels "$GH_BLOCK_LABELS" --arg freeze_re "$GH_FREEZE_CHECK_PATTERN" --argjson reviews "$reviews" '
  def norm: ascii_downcase | gsub("'"'"'";"") | gsub("^\\s+|\\s+$";"");
  ($block_labels | split(",") | map(norm) | map(select(length>0))) as $blocklist |
  def bad: ["FAILURE","ERROR","TIMED_OUT","CANCELLED","ACTION_REQUIRED","STARTUP_FAILURE"];
  def pending: ["PENDING","IN_PROGRESS","QUEUED","EXPECTED","WAITING","REQUESTED"];
  def isbad($s): (bad | index($s)) != null;
  def ispend($s): (pending | index($s)) != null or ($s == "");
  . as $pr
  | (($pr.statusCheckRollup // []) | map({n:(.name // .context // ""), s:(.conclusion // .state // "")})) as $c
  | ($c | map(select(.n | test($freeze_re;"i") | not))) as $realc
  | ($realc | map(.s)) as $real
  | ($c | map(select(.n | test($freeze_re;"i"))) | map(.s)) as $frz
  | ([ ($reviews // [])[] | select(.state=="APPROVED") | .submitted_at ] | sort | last) as $approvedAt
  | (($pr.commits // []) | last | .committedDate) as $lastCommitAt
  | (($pr.commits // []) | map(select(.authoredDate != null and $approvedAt != null and .authoredDate > $approvedAt)) | length) as $newAuthored
  | (($pr.labels // []) | map(.name | norm) | map(select(. as $l | $blocklist | index($l)))) as $blocked
  | [
      (if ($blocked | length) > 0 then "blocked by label: \($blocked | join(", "))" else empty end),
      (if $pr.isDraft then "is a draft" else empty end),
      (if $pr.reviewDecision != "APPROVED" then "not approved (reviewDecision=\($pr.reviewDecision // "none"))" else empty end),
      (if (($pr.reviewRequests // []) | length) > 0 then "re-review pending (\(($pr.reviewRequests|length)) reviewer(s) re-requested)" else empty end),
      (if ($approvedAt != null and $newAuthored > 0)
         then "stale approval (\($newAuthored) new commit(s) authored after approval \($approvedAt))" else empty end),
      (if ($approvedAt != null and $newAuthored == 0 and $lastCommitAt != null and $lastCommitAt > $approvedAt and $allow_rebase_stale == 0)
         then "stale approval (rebase-only: HEAD recommitted \($lastCommitAt) after approval \($approvedAt), no new authored work — pass --allow-rebase-stale to merge)" else empty end),
      (if ($real | any(isbad(.))) then "CI failing (\($realc | map(select(isbad(.s))) | map(.n) | join(", ")))" else empty end),
      (if ($real | any(ispend(.))) then "CI pending" else empty end),
      (if ($pr.mergeable != "MERGEABLE") then "not mergeable (mergeable=\($pr.mergeable // "UNKNOWN"))" else empty end),
      (if (($frz | any(isbad(.))) and ($allow_freeze==0)) then "sprint-frozen (clear with QA, then --allow-freeze or merge on GitHub)" else empty end)
    ] as $fails
  | if ($fails | length) == 0 then "OK" else ($fails | join("; ")) end')

if [ "$verdict" != "OK" ]; then echo "merge: REFUSED $repo#$num — $verdict"; exit 3; fi
if [ "$mode" = "check" ]; then echo "merge: $repo#$num PASSES all preconditions (would merge --$method)."; exit 0; fi

if ! gh pr merge "$num" -R "$repo" "--$method"; then
  echo "merge: gh pr merge failed for $repo#$num (preconditions passed; merge command errored)." >&2; exit 1
fi
echo "merge: $repo#$num merged (--$method)."
jt_worklog --pr "$repo#$num" --repo "$repo" "merged $repo#$num (--$method)"

# --- post-merge: strip stale outside-sprint label(s); best-effort ---
stale=$(printf '%s' "$data" | jq -r --arg sprint_labels "$GH_SPRINT_LABELS" '
  def norm: ascii_downcase | gsub("^\\s+|\\s+$";"");
  ($sprint_labels | split(",") | map(norm) | map(select(length>0))) as $sprintlist |
  (.labels // []) | map(select(.name | norm as $n | $sprintlist | index($n))) | .[].name')
if [ -n "$stale" ]; then
  while IFS= read -r label; do
    [ -z "$label" ] && continue
    if gh pr edit "$num" -R "$repo" --remove-label "$label" >/dev/null 2>&1; then
      echo "merge: removed stale label '$label' (merge pulled ticket into the sprint)."
    else
      echo "merge: WARNING — could not remove stale label '$label' (merge succeeded; remove it by hand)." >&2
    fi
  done <<< "$stale"
  ref=$(printf '%s' "$data" | jq -r '.headRefName // ""')
  ticket_key=$(jt_find_key "$ref")
  [ -z "$ticket_key" ] && ticket_key=$(jt_find_key "$(printf '%s' "$data" | jq -r '.title // ""')")
  if [ -n "$ticket_key" ]; then
    "$JT_DIR/sprint-add.sh" "$ticket_key" \
      || echo "merge: WARNING — could not add $ticket_key to the active sprint (merge succeeded; add it by hand)." >&2
  else
    echo "merge: WARNING — stripped stale label but could not derive a ticket key from PR $num (branch/title) to move the ticket into the sprint." >&2
  fi
fi
exit 0
