#!/usr/bin/env bash
# dependabot-merge.sh — approve + merge Dependabot PRs, and ONLY Dependabot PRs.
# Allow-listed for unattended use because the guard lives here in code: a PR whose author is
# not app/dependabot is refused, never approved.
#
#   dependabot-merge.sh <repo-dir> <pr>[@<head-sha>] [<pr>[@<head-sha>] ...]
#
# Authorization is upstream (the operator names the PR set). Each PR must be SAFE:
#   • author login == app/dependabot · not draft · mergeable == MERGEABLE
#   • CI green: every check SUCCESS/NEUTRAL/SKIPPED, none pending or failed
#   • diff touches only manifest/lockfile paths ($DEPENDABOT_ALLOWED_PATHS), read from the
#     paginated REST files endpoint (gh pr view --json files stops at 100) — a bump that
#     rewrites source files (codemods) or workflow files needs a human eye
#   • with @<head-sha>, the head still starts with that SHA (nothing merges unseen by triage)
#   • a merge method the repo allows: $GH_MERGE_METHOD if allowed, else the first allowed of
#     squash, merge, rebase; checked BEFORE approving, so a PR never gets a stray approval
# A failed precondition prints the reason and moves to the next PR. Exit 1 if any PR was
# skipped or failed, 0 if all merged, 2 on bad arguments (before any network call).
set -u
. "$(dirname "$(readlink "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")")/env.sh"
usage() { echo "usage: $0 <repo-dir> <pr>[@<head-sha>] [<pr>[@<head-sha>] ...]" >&2; exit 2; }
[ $# -ge 2 ] || usage
for arg in "${@:2}"; do [[ "$arg" =~ ^[0-9]+(@[0-9a-f]{7,40})?$ ]] || usage; done
jt_guard || exit $?

repo_dir="$1"; shift
cd "$repo_dir" || { echo "cannot cd to $repo_dir" >&2; exit 2; }
rc=0

# The repo's allowed merge methods, in preference order; checked before any approval.
allowed=$(gh api 'repos/{owner}/{repo}' --jq '[
    (if .allow_squash_merge then "squash" else empty end),
    (if .allow_merge_commit then "merge" else empty end),
    (if .allow_rebase_merge then "rebase" else empty end)] | join(" ")') || {
  echo "cannot read the repo's merge settings" >&2; exit 1; }
method="${allowed%% *}"
case " $allowed " in
  *" $GH_MERGE_METHOD "*) method="$GH_MERGE_METHOD" ;;
  *) [ -z "$method" ] || echo "note: GH_MERGE_METHOD=$GH_MERGE_METHOD is not allowed here; using $method" ;;
esac

for arg in "$@"; do
  n="${arg%%@*}"; want=""
  case "$arg" in *@*) want="${arg#*@}" ;; esac
  echo "== #$n"
  # GitHub recomputes mergeability after every merge to main; wait out UNKNOWN.
  for attempt in 1 2 3 4 5 6; do
    json=$(gh pr view "$n" --json author,isDraft,mergeable,state,statusCheckRollup,headRefOid,title 2>&1) || {
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

  bad_checks=$(jq -r '[.statusCheckRollup[]?
      | ((if (.conclusion // "") != "" then .conclusion else (.state // .status // "PENDING") end)
          | tostring | ascii_upcase) as $s
      | select($s != "SUCCESS" and $s != "NEUTRAL" and $s != "SKIPPED")
      | (.name // .context) + "=" + $s] | join(", ")' <<<"$json") || bad_checks="could not read checks"
  [ "$(jq '.statusCheckRollup | length' <<<"$json")" -gt 0 ] || bad_checks="no checks reported"
  [ -z "$bad_checks" ] || { echo "   SKIP: CI not green: $bad_checks"; rc=1; continue; }
  files=$(gh api "repos/{owner}/{repo}/pulls/$n/files" --paginate --jq '.[].filename') || {
    echo "   SKIP: could not list changed files"; rc=1; continue; }
  [ -n "$files" ] || { echo "   SKIP: no changed files listed"; rc=1; continue; }
  bad_files=$(jq -Rr --arg re "$DEPENDABOT_ALLOWED_PATHS" 'select(test($re) | not)' <<<"$files" | paste -sd, - | sed 's/,/, /g')
  [ -z "$bad_files" ] || { echo "   SKIP: touches non-manifest files: $bad_files"; rc=1; continue; }

  head=$(jq -r '.headRefOid' <<<"$json")
  if [ -n "$want" ]; then
    case "$head" in
      "$want"*) ;;
      *) echo "   REFUSE: head moved since triage (triaged $want, now ${head:0:12})"; rc=1; continue ;;
    esac
  fi
  [ -n "$method" ] || { echo "   SKIP: the repo allows no merge method"; rc=1; continue; }

  title=$(jq -r '.title' <<<"$json")
  echo "   $title"
  gh pr review "$n" --approve -b "Dependabot triage: green CI, manifest/lockfile-only bump." >/dev/null || { echo "   FAIL: approve failed"; rc=1; continue; }
  if gh pr merge "$n" "--$method" >/dev/null; then
    echo "   MERGED ($method)"
    jt_worklog --pr "#$n" --repo "$(basename "$PWD")" "dependabot #$n merged: $title"
  else
    echo "   FAIL: merge failed (approval left in place)"; rc=1
  fi
done
exit $rc
