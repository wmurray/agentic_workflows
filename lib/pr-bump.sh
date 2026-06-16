#!/usr/bin/env bash
# pr-bump.sh — record that you nudged an open PR out-of-band (e.g. pinged a reviewer in
# Slack), which GitHub's updatedAt can't see. workspace-context.sh reads this file and the
# stale-PR nudge in /sitrep, /daily, /eod suppresses a PR on the day it's bumped
# (bumpedDaysAgo == 0), then re-surfaces it the next working day if the bump went unanswered.
#
# Usage:
#   pr-bump.sh <Repo#Number> ["note"]      e.g. pr-bump.sh MyApp#5853 "pinged reviewer in Slack"
#   pr-bump.sh --list                      show current follow-ups
#   pr-bump.sh --clear <Repo#Number>       remove a follow-up (e.g. PR merged/closed)
#
# Key format is "<Repo>#<Number>" — exactly the key workspace-context.sh builds per PR.

set -uo pipefail
FILE="$HOME/.claude/lib/pr-followups.json"
[ -f "$FILE" ] || echo '[]' > "$FILE"

case "${1:-}" in
  --list)
    jq -r 'sort_by(.bumpedAt) | .[] | "\(.key)  \(.bumpedAt)\(if .note != "" then "  — \(.note)" else "" end)"' "$FILE"
    exit 0 ;;
  --clear)
    [ -n "${2:-}" ] || { echo "usage: pr-bump.sh --clear <Repo#Number>" >&2; exit 1; }
    tmp=$(mktemp)
    jq --arg key "$2" 'map(select(.key != $key))' "$FILE" > "$tmp" && mv "$tmp" "$FILE"
    echo "Cleared $2"
    exit 0 ;;
  "" )
    echo "usage: pr-bump.sh <Repo#Number> [\"note\"] | --list | --clear <Repo#Number>" >&2
    exit 1 ;;
esac

KEY="$1"; NOTE="${2:-}"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
tmp=$(mktemp)
# upsert this key with a fresh timestamp, and prune anything older than 30 days so the file
# doesn't accumulate dead entries for long-merged PRs.
CUTOFF=$(date -u -v-30d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "30 days ago" +%Y-%m-%dT%H:%M:%SZ)
jq --arg key "$KEY" --arg at "$NOW" --arg note "$NOTE" --arg cutoff "$CUTOFF" \
  'map(select(.key != $key and .bumpedAt >= $cutoff)) + [{key:$key, bumpedAt:$at, note:$note}]' \
  "$FILE" > "$tmp" && mv "$tmp" "$FILE"
echo "Recorded bump: $KEY @ $NOW${NOTE:+ — $NOTE}"
