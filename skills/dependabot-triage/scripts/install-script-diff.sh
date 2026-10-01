#!/usr/bin/env bash
#
# install-script-diff.sh: report install scripts that a Dependabot PR adds or changes.
#
# Usage: install-script-diff.sh <owner/repo> <pr> [<lockfile>]
#
# Compares every package version the lockfile adds between the PR's merge-base and its head
# (direct bumps, group members and transitive packages) with the version it replaces, and
# prints each one whose preinstall, install or postinstall script differs, with the before
# and after text. <lockfile> defaults to yarn.lock (Yarn 1 or Berry); pass package-lock.json
# for npm. One `npm view` per changed package, so a large bump takes a minute or more.
# Read-only: GitHub API reads and npm registry reads. Pass {owner}/{repo} literally to let gh
# resolve it from the current checkout.

set -u
[ $# -ge 2 ] && [ $# -le 3 ] || { echo "usage: install-script-diff.sh <owner/repo> <pr> [<lockfile>]" >&2; exit 2; }
repo="$1"
n="$2"
lock="${3:-yarn.lock}"
[[ "$n" =~ ^[0-9]+$ ]] || { echo "usage: install-script-diff.sh <owner/repo> <pr> [<lockfile>]" >&2; exit 2; }

head=$(gh api "repos/$repo/pulls/$n" --jq .head.sha) || exit 1
base=$(gh api "repos/$repo/pulls/$n" --jq .base.ref) || exit 1
mb=$(gh api "repos/$repo/compare/$base...$head" --jq .merge_base_commit.sha) || exit 1

dir=$(mktemp -d)
cleanup() { rm -f "${dir:?}/old" "${dir:?}/new"; rmdir "${dir:?}"; }
trap cleanup EXIT

# versions <sha>: "<name> <version>" for every package in the lockfile at that commit.
versions() {
  if [ "$lock" = package-lock.json ]; then
    gh api "repos/$repo/contents/$lock?ref=$1" -H "Accept: application/vnd.github.raw" \
      | jq -r '.packages | to_entries[] | select(.key != "") | "\(.key | sub(".*node_modules/"; "")) \(.value.version)"'
  else
    gh api "repos/$repo/contents/$lock?ref=$1" -H "Accept: application/vnd.github.raw" \
      | awk '/^[^ #].*:$/{n=$1; gsub(/[",:]/,"",n); sub(/@[^@]*$/,"",n)} /^  version:? / && n != "__metadata" {v=$2; gsub(/"/,"",v); print n, v}'
  fi
}
versions "$mb" | LC_ALL=C sort -u > "$dir/old"
versions "$head" | LC_ALL=C sort -u > "$dir/new"

# scripts <pkg> <version>: the install-time scripts as compact JSON, or nothing.
scripts() {
  npm view "$1@$2" scripts --json 2>/dev/null \
    | jq -cS '{preinstall, install, postinstall} | with_entries(select(.value != null))' 2>/dev/null \
    | sed 's/^{}$//'
}

changed=0
while read -r name ver; do
  prev=$(awk -v n="$name" '$1 == n {print $2}' "$dir/old" | sort -V | tail -1)
  before=""
  [ -z "$prev" ] || before=$(scripts "$name" "$prev")
  after=$(scripts "$name" "$ver")
  [ "$before" = "$after" ] && continue
  changed=$((changed + 1))
  printf '%s %s -> %s\n  before: %s\n  after:  %s\n' "$name" "${prev:-(new)}" "$ver" "${before:-none}" "${after:-none}"
done < <(LC_ALL=C comm -13 "$dir/old" "$dir/new")
echo "#$n: $changed package(s) with added or changed install scripts (merge-base ${mb:0:7}, head ${head:0:7})"
