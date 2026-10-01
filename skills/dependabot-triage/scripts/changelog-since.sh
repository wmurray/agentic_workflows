#!/usr/bin/env bash
#
# changelog-since.sh: print an upstream CHANGELOG.md from the top down to a version's entry.
#
# Usage: changelog-since.sh <upstream owner/repo> <current version>
#
# Prints every entry newer than <current version>, which covers the bump's target. Headings
# like "## [1.2.3]", "## v1.2.3" and "## 1.2.3" are recognised; the match is anchored to the
# start of the heading so a compare link to an older version does not end the read early.
# Read-only.

set -u
[ $# -eq 2 ] || { echo "usage: changelog-since.sh <upstream owner/repo> <current version>" >&2; exit 2; }
gh api "repos/$1/contents/CHANGELOG.md" -H "Accept: application/vnd.github.raw" \
  | awk -v from="$2" '/^## /{ h=$0; sub(/^## \[?v?/, "", h); if (index(h, from) == 1) exit; p=1 } p'
