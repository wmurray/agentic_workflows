#!/usr/bin/env bash
#
# changelog-since.sh: print an upstream changelog from the top down to a version's entry.
#
# Usage: changelog-since.sh <upstream owner/repo> <current version>
#
# Prints every entry newer than <current version>, which covers the bump's target. Tries
# CHANGELOG.md, CHANGES.md, HISTORY.md and History.md in that order. A version heading can be
# at any markdown level (# to ######) and read 2.31.0, v2.31.0 or [2.31.0], with or without a
# link or date after it. The match is anchored to the start of the heading and must end at a
# version boundary, so a compare link to an older version, or 2.31.0-beta, does not end the
# read early. Read-only.

set -u
[ $# -eq 2 ] || { echo "usage: changelog-since.sh <upstream owner/repo> <current version>" >&2; exit 2; }
repo="$1"
from="${2#v}"

for f in CHANGELOG.md CHANGES.md HISTORY.md History.md; do
  text=$(gh api "repos/$repo/contents/$f" -H "Accept: application/vnd.github.raw" 2>/dev/null) || continue
  printf '%s\n' "$text" | awk -v from="$from" '
    /^#+[ \t]/ {
      h = $0
      sub(/^#+[ \t]+/, "", h); sub(/^\[/, "", h); sub(/^[vV]/, "", h)
      if (index(h, from) == 1 && substr(h, length(from) + 1, 1) !~ /[0-9A-Za-z.-]/) exit
    }
    { print }'
  exit 0
done
echo "no CHANGELOG.md, CHANGES.md, HISTORY.md or History.md in $repo" >&2
exit 1
