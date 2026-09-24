#!/usr/bin/env bash
# dependabot-merge.sh — approve + squash-merge Dependabot PRs, and ONLY Dependabot PRs.
# Allow-listed for unattended use because the guard lives here in code: a PR whose author is
# not app/dependabot is refused, never approved.
#
#   dependabot-merge.sh <repo-dir> <pr-number> [<pr-number> ...]
#
# Authorization is upstream (the operator names the PR set). Each PR must be SAFE:
#   • author login == app/dependabot · not draft · mergeable == MERGEABLE
#   • CI green: every check SUCCESS/NEUTRAL/SKIPPED, none pending or failed
#   • diff touches only manifest/lockfile paths ($DEPENDABOT_ALLOWED_PATHS) — a bump that
#     rewrites source files (codemods) needs a human eye
# A failed precondition prints the reason and moves to the next PR. Exit 1 if any PR was
# skipped or failed, 0 if all merged.
set -u
. "$(dirname "$(readlink "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")")/env.sh"
jt_guard || exit $?

[ $# -ge 2 ] || { echo "usage: $0 <repo-dir> <pr-number> [<pr-number> ...]" >&2; exit 2; }
repo_dir="$1"; shift
cd "$repo_dir" || { echo "cannot cd to $repo_dir" >&2; exit 2; }
rc=0

for n in "$@"; do
  echo "== #$n"
  # GitHub recomputes mergeability after every merge to main; wait out UNKNOWN.
  for attempt in 1 2 3 4 5 6; do
    json=$(gh pr view "$n" --json author,isDraft,mergeable,state,statusCheckRollup,files,title 2>&1) || {
      echo "   SKIP: gh pr view failed: $json"; json=""; break; }
    [ "$(jq -r '.mergeable' <<<"$json")" = "UNKNOWN" ] || break
    sleep 5
  done
  [ -n "$json" ] || { rc=1; continue; }

  author=$(jq -r '.author.login' <<<"$json")
  [ "$author" = "app/dependabot" ] || { echo "   REFUSE: author is '$author', not app/dependabot"; rc=1; continue; }
  [ "$(jq -r '.state' <<<"$json")" = "OPEN" ] || { echo "   SKIP: state $(jq -r '.state' <<<"$json")"; rc=1; continue; }
  [ "$(jq -r '.isDraft' <<<"$json")" = "false" ] || { echo "   SKIP: draft"; rc=1; continue; }
  mergeable=$(jq -r '.mergeable' <<<"$json")
  [ "$mergeable" = "MERGEABLE" ] || { echo "   SKIP: mergeable=$mergeable"; rc=1; continue; }

  bad_checks=$(jq -r '[.statusCheckRollup[]? | select(((.conclusion // .state) | ascii_upcase) as $s | ($s != "SUCCESS" and $s != "NEUTRAL" and $s != "SKIPPED")) | (.name // .context) + "=" + ((.conclusion // .state)|tostring)] | join(", ")' <<<"$json")
  [ -z "$bad_checks" ] || { echo "   SKIP: CI not green: $bad_checks"; rc=1; continue; }
  bad_files=$(jq -r --arg re "$DEPENDABOT_ALLOWED_PATHS" '[.files[].path | select(test($re) | not)] | join(", ")' <<<"$json")
  [ -z "$bad_files" ] || { echo "   SKIP: touches non-manifest files: $bad_files"; rc=1; continue; }

  title=$(jq -r '.title' <<<"$json")
  echo "   $title"
  gh pr review "$n" --approve -b "Dependabot triage: green CI, manifest/lockfile-only bump." >/dev/null || { echo "   FAIL: approve failed"; rc=1; continue; }
  if gh pr merge "$n" --squash >/dev/null; then
    echo "   MERGED"
    jt_worklog --pr "#$n" --repo "$(basename "$PWD")" "dependabot #$n merged: $title"
  else
    echo "   FAIL: merge failed (approval left in place)"; rc=1
  fi
done
exit $rc
