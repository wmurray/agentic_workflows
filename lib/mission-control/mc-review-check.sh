#!/usr/bin/env bash
# mc-review-check.sh — REVIEW-FEEDBACK detector for an in-review PR (read-only).
#
# The gap this closes: mc-poll.sh surfaces only `reviewDecision`, so feedback that is
# NOT a formal CHANGES_REQUESTED — inline thread comments, a COMMENTED review, post-
# APPROVED nits — is INVISIBLE to the board sweep, and the review-triage trigger can
# never fire.
#
# It pulls the PR's review threads + review summaries via the host adapter
# (`review_threads`, already normalized + host-agnostic), keeps only the UNRESOLVED,
# non-outdated, non-BOT (and optionally non-SELF) feedback, and decides whether the PR
# needs triage. It also emits a SIGNATURE for `review_seen` so a later run can tell NEW
# feedback from already-triaged feedback.
#
# A PR NEEDS TRIAGE when ANY holds:
#   • reviewDecision == CHANGES_REQUESTED, OR
#   • there are unresolved-open (non-outdated) threads by a non-bot author, OR
#   • a COMMENTED/CHANGES_REQUESTED review carries a non-empty body — a top-level review
#     note that lives outside any thread. This is the load-bearing case: an APPROVED
#     aggregate can otherwise HIDE a reviewer's COMMENTED questions and let the PR
#     advance to ready-to-merge. An APPROVED review's body (an LGTM note) is NOT feedback.
#   • the signature differs from a passed --seen (new since last triage).
# `reviewDecision` ALONE is not the test.
#
# READ-ONLY — never writes state.json, the tracker, or the host. It DETECTS; the triage
# write (plan-doc section + triage_doc + lane→kickback) is the orchestrator's job under
# the single-writer rule. Branch A (open-PR review kickback) only; a QA/post-merge
# kickback is not its concern.
#
#   mc-review-check.sh <owner/repo> <pr#>
#   mc-review-check.sh <owner/repo#pr>
#     --seen "<sig>"   compare to a stored review_seen signature → NO-NEW if it matches
#                      (a legacy prose review_seen simply won't match → surfaces, which is
#                       the safe behavior for the first pass)
#   Env: MC_REVIEW_BOTS  (space-sep bot logins to ignore; default below)
#        MC_REVIEW_SELF  (your host login — if set, threads YOU opened are ignored too)
# Exit: 0 CLEAN or NO-NEW · 10 NEEDS-TRIAGE · 2 bad args · 1 error (adapter)
set -uo pipefail

# --- adapter dispatch (resolve this script's real dir through any symlink) ---
_mc_self="${BASH_SOURCE[0]}"
while [ -L "$_mc_self" ]; do
  _mc_ln="$(readlink "$_mc_self")"
  case "$_mc_ln" in /*) _mc_self="$_mc_ln" ;; *) _mc_self="$(dirname "$_mc_self")/$_mc_ln" ;; esac
done
_MC_LIB="$(cd "$(dirname "$_mc_self")" && pwd)"
. "$_MC_LIB/adapters/dispatch.sh"

BOTS="${MC_REVIEW_BOTS:-github-actions swarmia dependabot codecov coderabbitai sonarcloud sonarqubecloud renovate}"
SELF="${MC_REVIEW_SELF:-}"

repo=""; num=""; seen=""
while [ $# -gt 0 ]; do
  case "$1" in
    --seen) shift; seen="${1:-}" ;;
    *#*)    repo="${1%%#*}"; num="${1##*#}" ;;
    */*)    repo="$1" ;;
    [0-9]*) num="$1" ;;
    *)      echo "mc-review-check: unexpected arg '$1'" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$repo" ] && [ -n "$num" ] || { echo "mc-review-check: need <owner/repo> <pr#>" >&2; exit 2; }

# ONE host call: normalized decision + review threads + review summaries. The adapter
# owns the provider fetch; the filtering + verdict below stay host-agnostic.
raw=$(host review_threads "$repo" "$num") \
  || { echo "mc-review-check: review_threads failed for $repo#$num (auth? PR exists?)" >&2; exit 1; }

# Reduce to: decision + TWO kinds of unaddressed feedback, both filtered to
# non-bot/non-self: (1) unresolved/non-outdated inline review THREADS, and
# (2) COMMENTED/CHANGES_REQUESTED review SUMMARIES with a non-empty body.
parsed=$(printf '%s' "$raw" | jq -r --arg bots "$BOTS" --arg self "$SELF" '
  ($bots | split(" ") | map(ascii_downcase)) as $bot
  | def keep($a): ($a | ascii_downcase) as $al
      | ($bot | index($al) | not) and ($al | endswith("[bot]") | not)
        and ($self=="" or $a != $self);
    (.reviewDecision // "none") as $decision
  | [ .threads[]
      | select(.isResolved==false and .isOutdated==false)
      | .author as $a
      | select(keep($a))
      | { kind:"thread", path:.path, line:(.line // 0), author:$a,
          body:(.body // ""), latest:.latest }
    ] as $threads
  | [ (.reviews // [])[]
      | select(.state=="COMMENTED" or .state=="CHANGES_REQUESTED")
      | select((.body // "") != "")
      | .author as $a
      | select(keep($a))
      | { kind:"review", state:.state, author:$a,
          body:(.body // ""), latest:.submittedAt }
    ] as $reviews
  | ($threads + $reviews) as $items
  | { decision:$decision,
      n:($threads|length), rn:($reviews|length), total:($items|length),
      latest:( [ $items[].latest ] | max // "—" ),
      authors:( [ $items[].author ] | unique | join(",") ),
      items:$items }
  | @json')

decision=$(printf '%s' "$parsed" | jq -r '.decision')
n=$(printf '%s' "$parsed" | jq -r '.n')
rn=$(printf '%s' "$parsed" | jq -r '.rn')
total=$(printf '%s' "$parsed" | jq -r '.total')
latest=$(printf '%s' "$parsed" | jq -r '.latest')
authors=$(printf '%s' "$parsed" | jq -r '.authors')

# Signature stored as review_seen: decision + thread count + review-summary count
# + latest ts. An old signature without the r= term will read as changed once and
# re-surface, which is safe.
sig="d=${decision};t=${n};r=${rn};ts=${latest}"

# Verdict — feedback = CHANGES_REQUESTED aggregate OR any unresolved thread OR any
# COMMENTED/CHANGES_REQUESTED review summary. reviewDecision ALONE is not the test.
needs=0
{ [ "$decision" = "CHANGES_REQUESTED" ] || [ "$total" -gt 0 ]; } && needs=1

if [ "$needs" = "1" ] && [ -n "$seen" ] && [ "$seen" = "$sig" ]; then
  echo "review: NO-NEW — $repo#$num unchanged since last triage ($sig)"
  echo "signature: $sig"
  exit 0
fi

if [ "$needs" = "1" ]; then
  echo "review: NEEDS-TRIAGE — $repo#$num · decision=$decision · $n thread(s) + $rn review note(s) from [$authors]"
  printf '%s' "$parsed" | jq -r '.items[] |
    if .kind=="thread" then "  • \(.path):\(.line)  [\(.author)]\n      \(.body[0:200] | gsub("\n";" "))"
    else "  • review note [\(.author)] (\(.state))\n      \(.body[0:200] | gsub("\n";" "))" end'
  echo "signature: $sig"
  exit 10
fi

echo "review: CLEAN — $repo#$num · decision=$decision · no unresolved non-bot feedback"
echo "signature: $sig"
exit 0
