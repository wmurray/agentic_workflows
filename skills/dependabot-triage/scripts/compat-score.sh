#!/usr/bin/env bash
#
# compat-score.sh: read a Dependabot PR's compatibility score.
#
# Usage: compat-score.sh <owner/repo> <pr>
#
# The score is not text in the PR body, only a badge image. This fetches the badge SVG and
# prints one line:
#   compatibility: <N>%                          a score
#   compatibility: unknown (low-confidence)      a single-package PR with no badge, or a badge
#                                                that reads "unknown" or cannot be read
#   compatibility: no badge, grouped PR (no signal)
# A grouped PR (more than one "Updates `<pkg>`" line) carries no badge by design, so its
# absence says nothing. Read-only. Pass {owner}/{repo} literally to let gh resolve it from
# the current checkout.

set -u
[ $# -eq 2 ] || { echo "usage: compat-score.sh <owner/repo> <pr>" >&2; exit 2; }
[[ "$2" =~ ^[0-9]+$ ]] || { echo "usage: compat-score.sh <owner/repo> <pr>" >&2; exit 2; }

body=$(gh api "repos/$1/pulls/$2" --jq '.body // ""') || exit 1
members=$(printf '%s\n' "$body" | grep -c '^Updates `')
badge=$(printf '%s\n' "$body" | grep -o 'https://dependabot-badges\.githubapp\.com/badges/compatibility_score[^)" ]*' | head -1)

if [ -z "$badge" ]; then
  if [ "$members" -gt 1 ]; then
    echo "compatibility: no badge, grouped PR (no signal)"
  else
    echo "compatibility: unknown (low-confidence)"
  fi
  exit 0
fi

score=$(curl -sL "$badge" | grep -o '<text[^>]*>[^<]*</text>' | sed 's/<[^>]*>//g' | grep -E '^[0-9]+%$' | head -1)
if [ -n "$score" ]; then
  echo "compatibility: $score"
else
  echo "compatibility: unknown (low-confidence)"
fi
