#!/usr/bin/env bash
# mc-inbox-drain.sh — remove EXACTLY ONE command line from the mission-control inbox.
#
# The pinned, allow-listed "drain-one" the loop-driver requires. Every OTHER mutating
# mission-control step runs through an allow-listed wrapper so the headless /loop never
# improvises a file-mutating shell command — which the auto-mode permission classifier
# flags as a "bypass" (a coder-spawn drain of an `approve <KEY>` line gets denied
# mid-sequence for exactly this reason). Inbox line-removal was the one mutating step
# with no pinned wrapper; this closes the gap.
#
# Removes the FIRST non-comment line whose trimmed text EXACTLY equals the argument.
# Comment/blank lines and every other queued command are preserved verbatim. Atomic
# write (tmp + mv), so a concurrent reader never sees a torn file.
#
#   mc-inbox-drain.sh "approve TEAM-123"          # drain that one line
#   mc-inbox-drain.sh --check "approve TEAM-123"  # report match, change nothing
#   MC_INBOX=/path/to/inbox mc-inbox-drain.sh ... # override the inbox file
# Exit: 0 drained / no-op (not present) / check · 2 bad args · 1 error
set -uo pipefail
INBOX="${MC_INBOX:-$HOME/.claude/mission-control/mc-inbox}"
mode="commit"; target=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) mode="check" ;;
    *) if [ -z "$target" ]; then target="$1"; else echo "mc-inbox-drain: too many args (one command line only)" >&2; exit 2; fi ;;
  esac
  shift
done
[ -n "$target" ] || { echo "mc-inbox-drain: need a command line to drain, e.g. \"approve TEAM-123\"" >&2; exit 2; }
[ -f "$INBOX" ] || { echo "mc-inbox-drain: no inbox at $INBOX" >&2; exit 1; }

# Trim the target for an exact, whitespace-insensitive compare.
t_trim="$(printf '%s' "$target" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

# Is there a matching (non-comment) line?
if ! awk -v tgt="$t_trim" '
  { line=$0; sub(/^[[:space:]]+/,"",line); sub(/[[:space:]]+$/,"",line);
    if (line !~ /^#/ && line==tgt) { found=1; exit } }
  END { exit(found?0:1) }' "$INBOX"; then
  echo "mc-inbox-drain: '$t_trim' not present — no-op (already drained?)."; exit 0
fi

if [ "$mode" = "check" ]; then
  echo "mc-inbox-drain: '$t_trim' present — would remove exactly one line."; exit 0
fi

tmp="$INBOX.tmp.$$"
awk -v tgt="$t_trim" '
  BEGIN { done=0 }
  {
    line=$0; sub(/^[[:space:]]+/,"",line); sub(/[[:space:]]+$/,"",line)
    if (!done && line !~ /^#/ && line==tgt) { done=1; next }   # drop only the first match
    print $0
  }' "$INBOX" > "$tmp" && mv "$tmp" "$INBOX"
echo "mc-inbox-drain: drained '$t_trim' (one line removed)."
# Work log: a drained line means the orchestrator acted on it. Optional, never fails us.
_wl="$(dirname "$(readlink "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")")/worklog.sh"
[ -x "$_wl" ] || _wl="${MC_HOME:-$HOME/.claude/mission-control}/worklog.sh"
[ -x "$_wl" ] && "$_wl" add --source orchestrator "acted on: $t_trim" >/dev/null 2>&1 || true
exit 0
