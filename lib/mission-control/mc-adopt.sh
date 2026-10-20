#!/usr/bin/env bash
# mc-adopt.sh: find my open PRs whose ticket is not on the board (read-only).
#
# The ticketed half of the off-board PR sweep. mc-orphans.sh reports the keyless PRs;
# this reports the ones that carry a ticket key but no board row: a PR opened outside the
# loop (by hand, or by an overnight agent) for a ticket the board never ingested. The loop
# adopts these (Prep-write 7) instead of planning the ticket from scratch.
#
# Per repo in $MC_REPOS it lists my open PRs, drops the ones whose URL is a board `pr`,
# keys the rest by the first $MC_TICKET_KEY_REGEX match in the title (else the branch),
# drops keys already on the board in any lane, then asks the tracker once for status and
# once for which keys are assigned to me. One line per key:
#
#   adopt      ABC-1  <url>  draft  lane=awaiting-review  status=To Do
#   adopt      ABC-2  <url>  ready  lane=in-review  status=In Progress
#   ambiguous  ABC-3  <url1>  <url2>  (stacked or duplicate: never guess)
#   skip       ABC-4  <url>  reason=tracker-done|not-yours|tracker-miss
#
# Fences: only my PRs, only tickets assigned to me, never a terminal-done ticket
# ($MC_TERMINAL_DONE), and exactly one open PR per key. A teammate's PR on my ticket is
# never listed: it is not mine to shepherd.
#
# READ-ONLY: never writes state.json, the tracker, or the host. Adopting is the loop's
# write, under the lock and the one-prep-write cap.
#
#   mc-adopt.sh            # the report
#   mc-adopt.sh --keys     # only the adopt + ambiguous keys, one per line (for mc-inbound)
# Exit: 10 any `adopt` line · 0 none · 1 host error or state unreadable
set -uo pipefail

# --- adapter dispatch (resolve this script's real dir through any symlink) ---
_mc_self="${BASH_SOURCE[0]}"
while [ -L "$_mc_self" ]; do
  _mc_ln="$(readlink "$_mc_self")"
  case "$_mc_ln" in /*) _mc_self="$_mc_ln" ;; *) _mc_self="$(dirname "$_mc_self")/$_mc_ln" ;; esac
done
_MC_LIB="$(cd "$(dirname "$_mc_self")" && pwd)"
. "$_MC_LIB/adapters/dispatch.sh"

KEYS_ONLY=""; [ "${1:-}" = "--keys" ] && KEYS_ONLY=1
STATE="${MC_STATE:-$HOME/.claude/mission-control/state.json}"
REPOS="${MC_REPOS:-your-org/repo-a your-org/repo-b}"
KEY_RE="${MC_TICKET_KEY_REGEX:-[A-Z]+-[0-9]+}"
TERMINAL_DONE="${MC_TERMINAL_DONE:-Done Closed Released Resolved}"
[ -r "$STATE" ] || { echo "mc-adopt: cannot read $STATE" >&2; exit 1; }

board_prs=$(jq -r '.tickets[] | select(.pr != null) | .pr' "$STATE" 2>/dev/null) \
  || { echo "mc-adopt: cannot parse $STATE" >&2; exit 1; }
# Space-joined: BSD awk rejects a newline inside a -v value.
board_keys=$(jq -r '[.tickets[].ticket | ascii_upcase] | join(" ")' "$STATE" 2>/dev/null)

# key⇥url⇥draft|ready, one line per candidate PR.
cands=""
for repo in $REPOS; do
  data=$(host list_prs "$repo" open mine); rc=$?
  if [ "$rc" -ne 0 ] || ! printf '%s' "$data" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "mc-adopt: host list_prs failed for $repo (exit $rc)" >&2; exit 1
  fi
  out=$(printf '%s' "$data" | jq -r --arg board "$board_prs" --arg keyre "$KEY_RE" '
    ($board | split("\n") | map(select(length > 0))) as $bp
    | .[]
    | select((.url | IN($bp[])) | not)
    | ((first(.title | match($keyre; "i") | .string)
        // first((.headRefName // "") | match($keyre; "i") | .string)) // "") as $k
    | select($k != "")
    | [($k | ascii_upcase), .url, (if .isDraft then "draft" else "ready" end)] | @tsv')
  [ -n "$out" ] && cands="$cands$out"$'\n'
done

# Gotcha: a key already on the board in ANY lane (done included) is not adoptable; its PR
# is the board row's business (reconcile), even when the row's `pr` is unset or different.
cands=$(printf '%s' "$cands" | awk -F'\t' -v onb="$board_keys" '
  BEGIN { n = split(onb, a, " "); for (i = 1; i <= n; i++) if (a[i] != "") b[a[i]] }
  NF && !($1 in b)')
keys=$(printf '%s\n' "$cands" | cut -f1 | awk 'NF' | sort -u)

if [ -z "$keys" ]; then
  [ -z "$KEYS_ONLY" ] && echo "adopt: none (no off-board open PR of yours carries a ticket key)"
  exit 0
fi

klist=$(printf '%s\n' "$keys" | paste -sd, -)
fields=$(tracker fields_of "$klist" 2>/dev/null || true)
mine=$(tracker mine_of "$klist" 2>/dev/null | tr '[:lower:]' '[:upper:]' || true)

_is_terminal() {
  local s="$1" t
  for t in $TERMINAL_DONE; do [ "$s" = "$t" ] && return 0; done
  return 1
}

adopted=0
while IFS= read -r k; do
  [ -n "$k" ] || continue
  rows=$(printf '%s\n' "$cands" | awk -F'\t' -v k="$k" '$1 == k')
  n=$(printf '%s\n' "$rows" | grep -c .)
  urls=$(printf '%s\n' "$rows" | cut -f2 | paste -sd' ' - | sed 's/ /  /g')
  st=$(printf '%s\n' "$fields" | awk -F'\t' -v k="$k" 'toupper($1) == k { print $2; exit }')
  if   [ -z "$st" ];                             then line="skip       $k  $urls  reason=tracker-miss"
  elif ! printf '%s\n' "$mine" | grep -qxF "$k"; then line="skip       $k  $urls  reason=not-yours"
  elif _is_terminal "$st";                       then line="skip       $k  $urls  reason=tracker-done"
  elif [ "$n" -gt 1 ]; then
    line="ambiguous  $k  $urls  (stacked or duplicate: never guess)"
    [ -n "$KEYS_ONLY" ] && echo "$k"
  else
    kind=$(printf '%s\n' "$rows" | cut -f3)
    lane=in-review; [ "$kind" = draft ] && lane=awaiting-review
    line="adopt      $k  $urls  $kind  lane=$lane  status=$st"
    adopted=$((adopted + 1))
    [ -n "$KEYS_ONLY" ] && echo "$k"
  fi
  [ -z "$KEYS_ONLY" ] && echo "$line"
done <<< "$keys"

[ "$adopted" -gt 0 ] && exit 10
exit 0
