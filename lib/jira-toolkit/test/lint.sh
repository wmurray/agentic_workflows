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
expect "dependabot-merge: bad pr"  2 "$T/dependabot-merge.sh" . abc
expect "dependabot-merge: bad sha" 2 "$T/dependabot-merge.sh" . 7@not-a-sha
expect "assign: lane guard"        4 "$T/assign.sh" ABC-1 --lane qa

echo "dependabot-merge against a stub gh (no network)"
# The stub serves canned JSON from $FX and logs every call to $FX/calls. Without --paginate the
# files endpoint returns only its first 30 entries, as the REST API pages them.
DM="$(mktemp -d "${TMPDIR:-/tmp}/jt-lint-dm.XXXXXX")"
mkdir "$DM/bin"
cat > "$DM/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$FX/calls"
q=''; paginate=0
for ((i = 1; i <= $#; i++)); do
  case "${!i}" in --jq) j=$((i + 1)); q="${!j}" ;; --paginate) paginate=1 ;; esac
done
case "$1 $2" in
  "api repos/{owner}/{repo}/pulls/"*)
    f="$FX/files.json"
    [ "$paginate" = 1 ] || { jq '.[:30]' "$f" > "$FX/page.json"; f="$FX/page.json"; } ;;
  "api repos/{owner}/{repo}") f="$FX/repo.json" ;;
  "pr view") f="$FX/pr.json" ;;
  "pr review"|"pr merge") exit 0 ;;
  *) echo "stub gh: unexpected $*" >&2; exit 1 ;;
esac
if [ -n "$q" ]; then jq -r "$q" "$f"; else cat "$f"; fi
STUB
chmod +x "$DM/bin/gh"
# dm_fixture <squash> <merge> <rebase> <files (newline list)>: one green Dependabot PR, head abc1234…
dm_fixture() {
  : > "$DM/calls"
  jq -n '{author:{login:"app/dependabot"}, isDraft:false, mergeable:"MERGEABLE", state:"OPEN",
          statusCheckRollup:[{name:"test", conclusion:"SUCCESS"}], headRefOid:"abc1234def5678", title:"Bump x"}' > "$DM/pr.json"
  jq -n --argjson s "$1" --argjson m "$2" --argjson r "$3" \
    '{allow_squash_merge:$s, allow_merge_commit:$m, allow_rebase_merge:$r}' > "$DM/repo.json"
  jq -Rn '[inputs | {filename: .}]' <<<"$4" > "$DM/files.json"
}
dm() { (cd "$DM" && PATH="$DM/bin:$PATH" FX="$DM" "$T/dependabot-merge.sh" "$DM" "$@" 2>&1); }
no_approve() { if grep -q '^pr review' "$DM/calls"; then bad "$1 — approve was called"; else ok "$1"; fi; }

many="$(for i in $(seq 1 150); do if [ "$i" -eq 140 ]; then echo src/app.js; else echo yarn.lock; fi; done)"
dm_fixture true false false "$many"
says "dependabot-merge: file 140 of 150 refused (pagination)" 'touches non-manifest files: src/app.js' dm 7
no_approve "dependabot-merge: no approve after a refused file"

dm_fixture true false false $'package.json\nyarn.lock'
says "dependabot-merge: head moved is refused" 'REFUSE: head moved since triage' dm 7@fff0000
no_approve "dependabot-merge: no approve after a moved head"

dm_fixture false false false $'package.json\nyarn.lock'
says "dependabot-merge: no allowed method is skipped" 'SKIP: the repo allows no merge method' dm 7
no_approve "dependabot-merge: no approve when no method is allowed"

dm_fixture false false true $'package.json\nyarn.lock'
says "dependabot-merge: falls back from a disallowed GH_MERGE_METHOD" 'using rebase' dm 7@abc1234
if grep -q '^pr review' "$DM/calls" && grep -q '^pr merge 7 --rebase' "$DM/calls"; then ok "dependabot-merge: approves, then merges with the allowed method"
else bad "dependabot-merge: happy path calls — $(tr '\n' ';' < "$DM/calls")"; fi

rm -f "${DM:?}/bin/gh" "${DM:?}/calls" "${DM:?}/pr.json" "${DM:?}/repo.json" "${DM:?}/files.json" "${DM:?}/page.json"
rmdir "${DM:?}/bin" "${DM:?}"

echo "assign against a stub jira (no network)"
# The stub reports the ticket Unassigned and logs every call, so the assign argv is visible.
JA="$(mktemp -d "${TMPDIR:-/tmp}/jt-lint-ja.XXXXXX")"
mkdir "$JA/bin"
cat > "$JA/bin/jira" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$FX/calls"
case "$1 $2" in
  "issue view")   echo '{"fields":{"assignee":null}}' ;;
  "issue assign") exit 0 ;;
  *) echo "stub jira: unexpected $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$JA/bin/jira"
ja() { : > "$JA/calls"; (PATH="$JA/bin:$PATH" FX="$JA" "$T/assign.sh" ABC-1 >/dev/null 2>&1); }
JIRA_PROJECT=ABC ja
if grep -qx 'issue assign -p ABC ABC-1 you@your-org.com' "$JA/calls"; then ok "assign: exported JIRA_PROJECT is passed as -p"
else bad "assign: with JIRA_PROJECT — $(tr '\n' ';' < "$JA/calls")"; fi
(unset JIRA_PROJECT; ja)
if grep -qx 'issue assign ABC-1 you@your-org.com' "$JA/calls"; then ok "assign: no -p when JIRA_PROJECT is unset"
else bad "assign: without JIRA_PROJECT — $(tr '\n' ';' < "$JA/calls")"; fi
rm -f "${JA:?}/bin/jira" "${JA:?}/calls"; rmdir "${JA:?}/bin" "${JA:?}"

echo "dependabot-triage skill"
# Claude Code substitutes positional placeholders anywhere in a skill's text, so a shell or awk
# snippet using them breaks silently when the skill gets arguments; they belong in scripts/.
SK="$T/../../skills/dependabot-triage"
if grep -nE '\$[0-9]|\$\{[0-9]|\$ARGUMENTS\[' "$SK/SKILL.md" >/dev/null; then
  bad "SKILL.md has a positional placeholder: $(grep -nE '\$[0-9]|\$\{[0-9]|\$ARGUMENTS\[' "$SK/SKILL.md" | head -1 | cut -c1-80)"
else ok "SKILL.md has no positional placeholders"; fi
[ "$(grep -c '\$ARGUMENTS' "$SK/SKILL.md")" = 1 ] && ok "SKILL.md has exactly one \$ARGUMENTS line" || bad "SKILL.md \$ARGUMENTS count"
for f in "$SK"/scripts/*.sh; do bash -n "$f" && ok "$(basename "$f") parses" || bad "$(basename "$f") syntax"; done
expect "gem-parents: usage"            2 "$SK/scripts/gem-parents.sh"
expect "install-script-config: usage"  2 "$SK/scripts/install-script-config.sh"
expect "install-script-diff: usage"    2 "$SK/scripts/install-script-diff.sh" o/r
expect "install-script-diff: bad pr"   2 "$SK/scripts/install-script-diff.sh" o/r abc
expect "changelog-since: usage"        2 "$SK/scripts/changelog-since.sh" o/r
expect "compat-score: usage"           2 "$SK/scripts/compat-score.sh" o/r
expect "upstream-repo: usage"          2 "$SK/scripts/upstream-repo.sh"
rt=$(bash "$SK/scripts/test/dependency-changelog.test.sh" 2>&1)
[ $? -eq 0 ] && ok "dependency-changelog test ($(printf '%s' "$rt" | tail -1))" || bad "dependency-changelog test: $(printf '%s' "$rt" | grep -m1 FAIL)"

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
