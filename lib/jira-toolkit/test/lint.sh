#!/usr/bin/env bash
# lint.sh — no-network checks for the jira-toolkit wrappers: every script parses, every
# wrapper rejects bad arguments before touching the network, env.sh fails loudly on missing
# config, and the ADF converter handles its markdown subset.
#   ./lib/jira-toolkit/test/lint.sh
set -uo pipefail
T="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '\033[32m  PASS  %s\033[0m\n' "$*"; pass=$((pass+1)); }
bad() { printf '\033[31m  FAIL  %s\033[0m\n' "$*"; fail=$((fail+1)); }
expect() { # label, expected-exit, cmd…
  local label="$1" want="$2"; shift 2
  local out rc; out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" = "$want" ]; then ok "$label (exit $rc)"; else bad "$label — exit $rc, wanted $want: $(printf '%s' "$out" | head -1)"; fi
}
says() { # label, regex, cmd…
  local label="$1" pat="$2"; shift 2
  local out; out="$("$@" 2>&1)"
  if printf '%s' "$out" | grep -qE "$pat"; then ok "$label"; else bad "$label — no match for /$pat/ in: $(printf '%s' "$out" | head -1)"; fi
}

# Isolate from any real config, mission-control runtime and work log.
export JIRA_TOOLKIT_ENV="$T/example.env" MC_HOME="${TMPDIR:-/tmp}/jt-lint-nomc.$$" MC_WORKLOG=off
unset JIRA_API_TOKEN

echo "syntax"
for f in "$T"/*.sh; do bash -n "$f" && ok "$(basename "$f") parses" || bad "$(basename "$f") syntax"; done
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$T/md-to-adf.py" && ok "md-to-adf.py parses" || bad "md-to-adf.py parse"

echo "argument handling (exit 2 before any network call)"
expect "assign: no key"            2 "$T/assign.sh"
expect "assign: unknown arg"       2 "$T/assign.sh" ABC-1 --bogus
expect "jira-status: no lane"      2 "$T/jira-status.sh" ABC-1
expect "jira-status: qa refused"   4 "$T/jira-status.sh" ABC-1 qa
expect "jira-status: done refused" 4 "$T/jira-status.sh" ABC-1 done
expect "jira-status: kickback"     4 "$T/jira-status.sh" ABC-1 kickback
expect "sprint-add: no key"        2 "$T/sprint-add.sh"
expect "request-review: no pr"     2 "$T/request-review.sh"
expect "merge: no pr"              2 "$T/merge.sh"
expect "merge: unknown arg"        2 "$T/merge.sh" --bogus
expect "dependabot-merge: usage"   2 "$T/dependabot-merge.sh"
expect "assign: lane guard"        4 "$T/assign.sh" ABC-1 --lane qa

echo "config validation"
says "qa-transition names the missing token" 'missing config:.*JIRA_API_TOKEN' "$T/qa-transition.sh" ABC-1
expect "qa-transition exits 1 without token"  1 "$T/qa-transition.sh" ABC-1
says "release-note points at example.env"     'example.env' "$T/release-note.sh" ABC-1 --check
says "request-review needs a team"            'GH_REVIEW_TEAM|would' env JIRA_TOOLKIT_ENV=/dev/null "$T/request-review.sh" o/r 1 --check
says "key regex from config is honored"       "unknown arg 'XYZ-9'" env JIRA_TOOLKIT_ENV=/dev/null JIRA_KEY_REGEX='ABC-[0-9]+' "$T/sprint-add.sh" XYZ-9

echo "md-to-adf"
adf=$(printf '# Title\n\n- one **bold**\n- two `code`\n\n1. first\n2. second\n\npara line\\\ncontinued' | python3 "$T/md-to-adf.py")
printf '%s' "$adf" | jq -e '.type=="doc" and .version==1' >/dev/null && ok "emits a doc" || bad "doc shape"
printf '%s' "$adf" | jq -e '[.content[].type] == ["heading","bulletList","orderedList","paragraph"]' >/dev/null && ok "block order preserved" || bad "block order: $(printf '%s' "$adf" | jq -c '[.content[].type]')"
printf '%s' "$adf" | jq -e '.content[1].content[0].content[0].content | any(.marks[]?.type=="strong")' >/dev/null && ok "bold mark" || bad "bold mark"
printf '%s' "$adf" | jq -e '.content[3].content | any(.type=="hardBreak")' >/dev/null && ok "trailing backslash → hardBreak" || bad "hardBreak"
printf '' | python3 "$T/md-to-adf.py" | jq -e '.content | length == 1' >/dev/null && ok "empty input still yields one paragraph" || bad "empty input"

echo
if [ "$fail" -eq 0 ]; then printf '\033[32m%s passed, 0 failed\033[0m\n' "$pass"; else printf '\033[31m%s passed, %s FAILED\033[0m\n' "$pass" "$fail"; exit 1; fi
