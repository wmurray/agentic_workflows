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
expect "assign: refined refused"    4 "$T/assign.sh" ABC-1 --lane refined
expect "post-release-note: no key"  2 "$T/post-release-note.sh"
expect "post-release-note: no note" 2 "$T/post-release-note.sh" ABC-1

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

echo "request-review against a stub gh (no network)"
# The stub serves $FX/pr.json for `pr view` and logs every call to $FX/calls; writes succeed.
# The PR author is "me"; reviewers review on the 2nd, so a commit or reply on the 3rd is new.
RR="$(mktemp -d "${TMPDIR:-/tmp}/jt-lint-rr.XXXXXX")"
mkdir "$RR/bin"
cat > "$RR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$FX/calls"
case "$1 $2" in
  "pr view") cat "$FX/pr.json" ;;
  "pr ready"|"pr edit"|"api -X") exit 0 ;;
  *) echo "stub gh: unexpected $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$RR/bin/gh"
# rr_fixture <isDraft> <requested logins, space-sep> <reviews: login:STATE …> <last commit date>
#            [<author reply date>]
rr_fixture() {
  : > "$RR/calls"
  jq -n --argjson d "$1" --arg req "$2" --arg revs "$3" --arg cd "$4" --arg reply "${5:-}" '
    {isDraft:$d, state:"OPEN", mergedAt:null, author:{login:"me"},
     reviewRequests:[$req | split(" ")[] | select(. != "") | {__typename:"User", login:.}],
     reviews:([$revs | split(" ")[] | select(. != "") | split(":") | {author:{login:.[0]}, state:.[1], submittedAt:"2026-01-02T00:00:00Z"}]
              + (if $reply == "" then [] else [{author:{login:"me"}, state:"COMMENTED", submittedAt:$reply}] end)),
     comments:[], commits:[{oid:"abc", committedDate:$cd}]}' > "$RR/pr.json"
}
rr() { (PATH="$RR/bin:$PATH" FX="$RR" "$T/request-review.sh" o/r 7 "$@" 2>&1); }
writes() { grep -E '^(pr ready|pr edit|api )' "$RR/calls" | paste -sd';' -; }

rr_fixture true "" "" 2026-01-01T00:00:00Z
rr >/dev/null
[ "$(writes)" = "pr ready 7 -R o/r;pr edit 7 -R o/r --add-reviewer your-org/your-team" ] && ok "request-review: draft marks ready + requests the team" || bad "request-review: draft writes — $(writes)"

rr_fixture false "carol" "alice:CHANGES_REQUESTED bob:COMMENTED carol:COMMENTED dave:APPROVED coderabbitai:COMMENTED copilot[bot]:COMMENTED me:COMMENTED" 2026-01-03T00:00:00Z
says "request-review: non-draft re-requests prior reviewers" 're-requested alice, bob' rr
[ "$(writes)" = "api -X POST repos/o/r/pulls/7/requested_reviewers -f reviewers[]=alice -f reviewers[]=bob" ] && ok "request-review: skips bots, author, approver, already-requested; no team, no ready" || bad "request-review: re-review writes — $(writes)"

rr_fixture false "" "alice:COMMENTED" 2026-01-01T00:00:00Z 2026-01-03T00:00:00Z
rr >/dev/null
[ "$(writes)" = "api -X POST repos/o/r/pulls/7/requested_reviewers -f reviewers[]=alice" ] && ok "request-review: an author thread reply counts as new" || bad "request-review: reply-only writes — $(writes)"

rr_fixture false "alice" "alice:COMMENTED" 2026-01-03T00:00:00Z
says "request-review: all already requested is a no-op" 'alice already requested' rr
[ -z "$(writes)" ] && ok "request-review: no-op writes nothing" || bad "request-review: no-op wrote — $(writes)"

rr_fixture false "" "dave:APPROVED swarmia:COMMENTED" 2026-01-01T00:00:00Z
rr >/dev/null
[ "$(writes)" = "pr edit 7 -R o/r --add-reviewer your-org/your-team" ] && ok "request-review: no prior human reviewers falls back to the team" || bad "request-review: fallback writes — $(writes)"

rr_fixture false "" "alice:CHANGES_REQUESTED" 2026-01-01T00:00:00Z
expect "request-review: nothing new since the review is refused" 3 rr
says   "request-review: refusal says why" 'REFUSE — o/r#7 has nothing new since the last review by alice' rr
[ -z "$(writes)" ] && ok "request-review: refusal writes nothing" || bad "request-review: refusal wrote — $(writes)"
expect "request-review: --check exits 3 when it would refuse" 3 rr --check

rr_fixture false "carol" "alice:COMMENTED carol:COMMENTED" 2026-01-03T00:00:00Z
says "request-review: --check names who it would re-request" 'would: re-request alice \(carol already requested\)' rr --check
[ -z "$(writes)" ] && ok "request-review: --check writes nothing" || bad "request-review: --check wrote — $(writes)"
rm -f "${RR:?}/bin/gh" "${RR:?}/calls" "${RR:?}/pr.json"; rmdir "${RR:?}/bin" "${RR:?}"

echo "assign against a stub jira (no network)"
# The stub reports the ticket Unassigned and logs every call, so the assign argv is visible.
JA="$(mktemp -d "${TMPDIR:-/tmp}/jt-lint-ja.XXXXXX")"
mkdir "$JA/bin"
cat > "$JA/bin/jira" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$FX/calls"
case "$1 $2" in
  "issue view")   if [ -f "$FX/view.json" ]; then cat "$FX/view.json"; else echo '{"fields":{"assignee":null}}'; fi ;;
  "issue assign") exit 0 ;;
  *) echo "stub jira: unexpected $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$JA/bin/jira"
ja() { : > "$JA/calls"; (PATH="$JA/bin:$PATH" FX="$JA" "$T/assign.sh" ABC-1 "$@" >/dev/null 2>&1); }
JIRA_PROJECT=ABC ja
if grep -qx 'issue assign -p ABC ABC-1 you@your-org.com' "$JA/calls"; then ok "assign: exported JIRA_PROJECT is passed as -p"
else bad "assign: with JIRA_PROJECT — $(tr '\n' ';' < "$JA/calls")"; fi
(unset JIRA_PROJECT; ja)
if grep -qx 'issue assign ABC-1 you@your-org.com' "$JA/calls"; then ok "assign: no -p when JIRA_PROJECT is unset"
else bad "assign: without JIRA_PROJECT — $(tr '\n' ';' < "$JA/calls")"; fi
(unset JIRA_PROJECT; ja --lane refined)
[ -s "$JA/calls" ] && bad "assign: refined still called jira — $(tr '\n' ';' < "$JA/calls")" \
  || ok "assign: an unassigned refined ticket is left alone (no jira call)"
(unset JIRA_PROJECT; ja --lane plan-review)
if grep -qx 'issue assign ABC-1 you@your-org.com' "$JA/calls"; then ok "assign: an unassigned plan-review ticket is still claimed"
else bad "assign: plan-review — $(tr '\n' ';' < "$JA/calls")"; fi
printf '%s' '{"fields":{"assignee":{"accountId":"q1","displayName":"QA Owner"},"status":{"name":"QA Review"}}}' > "$JA/view.json"; : > "$JA/calls"
expect "assign: a ticket in the QA status is refused" 4 env PATH="$JA/bin:$PATH" FX="$JA" "$T/assign.sh" ABC-1 --lane alpha-verify
says   "  … and says QA owns the assignee" "in 'QA Review' — QA owns the assignee" env PATH="$JA/bin:$PATH" FX="$JA" "$T/assign.sh" ABC-1 --lane alpha-verify
grep -q '^issue assign' "$JA/calls" && bad "assign: QA-status ticket was reassigned" || ok "assign: a QA-status ticket is never reassigned"
rm -f "${JA:?}/bin/jira" "${JA:?}/calls" "${JA:?}/view.json"; rmdir "${JA:?}/bin" "${JA:?}"

echo "jira-status against a stub jira + curl (no network)"
# A three-status workflow whose transition names do not match their targets, and with no
# direct Backlog → In Progress edge. $FX/status holds the ticket's status; a POSTed transition
# id moves it. Every REST call is logged to $FX/calls.
JS="$(mktemp -d "${TMPDIR:-/tmp}/jt-lint-js.XXXXXX")"
mkdir "$JS/bin"
cat > "$JS/flow.json" <<'JSON'
{"Backlog": [{"id":"11","name":"Backlog","to":{"name":"Backlog"}},
             {"id":"3","name":"Backlog to Done","to":{"name":"Done"}},
             {"id":"8","name":"Ready for development","to":{"name":"Selected for Development"}}],
 "Selected for Development": [{"id":"4","name":"Selected for Development to Done","to":{"name":"Done"}},
                              {"id":"9","name":"Move to In Progress","to":{"name":"In Progress"}}],
 "In Progress": [{"id":"21","name":"Start review","to":{"name":"Code Review"}}]}
JSON
cat > "$JS/bin/jira" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list") printf 'ABC-1\t%s\n' "$(cat "$FX/status")" ;;
  *) echo "stub jira: unexpected $*" >&2; exit 1 ;;
esac
STUB
cat > "$JS/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=''; method=GET; data=''
while [ $# -gt 1 ]; do
  case "$1" in -o) out="$2"; shift ;; -X) method="$2"; shift ;; --data) data="$2"; shift ;; -w|-u|-H) shift ;; esac
  shift
done
echo "$method ${1#*atlassian.net} $data" >> "$FX/calls"
cur="$(cat "$FX/status")"
if [ "$method" = GET ]; then jq --arg s "$cur" '{transitions: (.[$s] // [])}' "$FX/flow.json" > "$out"; printf 200; exit 0; fi
id=$(printf '%s' "$data" | jq -r .transition.id)
to=$(jq -r --arg s "$cur" --arg id "$id" '.[$s][]? | select(.id == $id) | .to.name' "$FX/flow.json")
[ -n "$to" ] || { echo '{"errorMessages":["bad transition"]}' > "$out"; printf 400; exit 0; }
printf '%s' "$to" > "$FX/status"; : > "$out"; printf 204
STUB
chmod +x "$JS/bin/jira" "$JS/bin/curl"
grep -v '^JIRA_STATUS_IN_PROGRESS_VIA=' "$T/example.env" > "$JS/novia.env"
stub_token=not-a-real-token
# js <start status> <args…>: run jira-status.sh against the stub from that status.
js() { printf '%s' "$1" > "$JS/status"; : > "$JS/calls"; shift
  (PATH="$JS/bin:$PATH" FX="$JS" JIRA_API_TOKEN=$stub_token "$T/jira-status.sh" ABC-1 "$@" 2>&1); }
posts() { grep '^POST' "$JS/calls" | grep -o '"id":"[0-9]*"' | tr -d '"id:' | paste -sd' ' -; }

says   "jira-status: refined from Backlog picks the transition by target" "'Backlog' → 'Selected for Development'" js Backlog refined
[ "$(posts)" = 8 ] && ok "jira-status: fired 'Ready for development' (8)" || bad "jira-status: refined posts — $(posts)"
says   "jira-status: implement from Backlog hops through the ready status" "'Backlog' → 'Selected for Development' → 'In Progress'" js Backlog implement
[ "$(posts)" = "8 9" ] && [ "$(cat "$JS/status")" = "In Progress" ] && ok "jira-status: hop fired 8 then 9" || bad "jira-status: hop posts — $(posts)"
says   "jira-status: implement from ready moves directly" "'Selected for Development' → 'In Progress'" js "Selected for Development" implement
[ "$(posts)" = 9 ] && ok "jira-status: direct move fired 9 only" || bad "jira-status: direct posts — $(posts)"
says   "jira-status: --check describes the hop" "would move to 'Selected for Development' via 'Ready for development' \(8\), then to 'In Progress'" js Backlog implement --check
[ -z "$(posts)" ] && ok "jira-status: --check posts nothing" || bad "jira-status: --check posted — $(posts)"
expect "jira-status: no hop for other targets" 1 js Backlog in-review
[ -z "$(posts)" ] && ok "jira-status: unreachable target posts nothing" || bad "jira-status: in-review posted — $(posts)"
says   "jira-status: failure names reachable statuses" 'reachable: Backlog, Done, Selected for Development' js Backlog in-review
js_novia() { JIRA_TOOLKIT_ENV="$JS/novia.env" js "$@"; }
says   "jira-status: no hop without JIRA_STATUS_IN_PROGRESS_VIA" "no transition from 'Backlog' to 'In Progress'" js_novia Backlog implement
[ -z "$(posts)" ] && ok "jira-status: unconfigured hop posts nothing" || bad "jira-status: unconfigured hop posted — $(posts)"
says   "jira-status: already there is a no-op" 'no-op' js "In Progress" implement
[ -z "$(cat "$JS/calls")" ] && ok "jira-status: no-op makes no REST call" || bad "jira-status: no-op called REST"
rm -f "${JS:?}"/bin/* "${JS:?}"/{calls,status,flow.json,novia.env}; rmdir "${JS:?}/bin" "${JS:?}"

echo "qa-transition against a stub jira + curl (no network)"
# $FX/fields.json is the issue's field values (distinct ids via qa.env); a PUT merges into it.
# $FX/trans.json is what the issue offers. Every REST call is logged to $FX/calls in order.
QA="$(mktemp -d "${TMPDIR:-/tmp}/jt-lint-qa.XXXXXX")"
mkdir "$QA/bin"
cat > "$QA/bin/jira" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list") printf 'ABC-1\t%s\n' "$(cat "$FX/status")" ;;
  *) echo "stub jira: unexpected $*" >&2; exit 1 ;;
esac
STUB
cat > "$QA/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=''; method=GET; data=''
while [ $# -gt 1 ]; do
  case "$1" in -o) out="$2"; shift ;; -X) method="$2"; shift ;; --data) data="$2"; shift ;; -w|-u|-H) shift ;; esac
  shift
done
path="${1#*atlassian.net}"
echo "$method $path $data" >> "$FX/calls"
case "$method $path" in
  "GET /rest/api/2/issue/"*)          jq '{fields: .}' "$FX/fields.json" > "$out"; printf 200 ;;
  "GET /rest/api/3/issue/"*/transitions) cp "$FX/trans.json" "$out"; printf 200 ;;
  "PUT /rest/api/3/issue/"*)
    jq --argjson d "$data" '. + $d.fields' "$FX/fields.json" > "$FX/f.tmp" && mv "$FX/f.tmp" "$FX/fields.json"
    : > "$out"; printf 204 ;;
  "POST /rest/api/3/issue/"*/transitions) printf '%s' "$data" | jq -r .transition.id > "$FX/fired"; : > "$out"; printf 204 ;;
  *) echo '{}' > "$out"; printf 404 ;;
esac
STUB
chmod +x "$QA/bin/jira" "$QA/bin/curl"
sed -e 's/^JIRA_FIELD_RELEASE_NOTE=.*/JIRA_FIELD_RELEASE_NOTE="cf_rn"/' -e 's/^JIRA_FIELD_TESTING_NOTES=.*/JIRA_FIELD_TESTING_NOTES="cf_tn"/' \
    -e 's/^JIRA_FIELD_FEATURE_FLAGS=.*/JIRA_FIELD_FEATURE_FLAGS="cf_ff"/' -e 's/^JIRA_FIELD_STORY_POINTS=.*/JIRA_FIELD_STORY_POINTS="cf_sp"/' \
    "$T/example.env" > "$QA/qa.env"
sed 's/^JIRA_TRANSITION_QA_ID=.*/JIRA_TRANSITION_QA_ID="12"/' "$QA/qa.env" > "$QA/qa-id.env"
# qa_fixture <fields json> [<transitions json>]: ticket in Code Review; default offers QA via 31.
QA_TRANS='{"transitions":[{"id":"31","to":{"name":"QA Review"}},{"id":"5","to":{"name":"Done"}}]}'
qa_fixture() {
  printf 'Code Review' > "$QA/status"; : > "$QA/calls"; rm -f "$QA/fired"
  printf '%s' "$1" > "$QA/fields.json"
  printf '%s' "${2:-$QA_TRANS}" > "$QA/trans.json"
}
qa() { (PATH="$QA/bin:$PATH" FX="$QA" JIRA_TOOLKIT_ENV="${QA_ENV:-$QA/qa.env}" JIRA_API_TOKEN=$stub_token "$T/qa-transition.sh" ABC-1 "$@" 2>&1); }
qa_writes() { grep -E '^(PUT|POST)' "$QA/calls" | cut -d' ' -f1-2 | paste -sd';' -; }
FULL='{"cf_rn":"Internal: tidy","cf_tn":"1. open it","cf_ff":["not-feature-flagged"],"cf_sp":2}'
SPARSE='{"cf_rn":null,"cf_tn":"  ","cf_ff":[],"cf_sp":3}'

qa_fixture "$SPARSE"
expect "qa-transition: empty fields refuse with exit 3" 3 qa
says   "qa-transition: refusal names each empty field" 'fields missing: release note, testing notes, feature flags\.' qa
[ -z "$(qa_writes)" ] && ok "qa-transition: refusal writes nothing" || bad "qa-transition: refusal wrote — $(qa_writes)"
qa_fixture '{"cf_rn":"x","cf_tn":"y","cf_ff":["f"],"cf_sp":null}'
says   "qa-transition: empty points refuse too" 'fields missing: story points\.' qa
[ ! -f "$QA/fired" ] && ok "qa-transition: points-empty refusal fires nothing" || bad "qa-transition: points-empty fired $(cat "$QA/fired")"

qa_fixture "$SPARSE"
says   "qa-transition: --force says what it overrode" 'force: transitioning ABC-1 with fields missing: release note, testing notes, feature flags' qa --force
[ "$(cat "$QA/fired" 2>/dev/null)" = 31 ] && ok "qa-transition: --force fires the QA transition" || bad "qa-transition: --force fired '$(cat "$QA/fired" 2>/dev/null)'"
[ -z "$(grep '^PUT' "$QA/calls")" ] && ok "qa-transition: --force writes no field" || bad "qa-transition: --force wrote a field"

qa_fixture "$SPARSE"
expect "qa-transition: --check exits 3 when fields are empty" 3 qa --check
says   "qa-transition: --check names the empty fields" 'fields missing: release note, testing notes, feature flags — would refuse' qa --check
[ -z "$(qa_writes)" ] && ok "qa-transition: --check writes nothing" || bad "qa-transition: --check wrote — $(qa_writes)"
qa_fixture "$FULL"
says   "qa-transition: --check passes when all four are set" "would transition to 'QA Review' \(id 31" qa --check
[ -z "$(qa_writes)" ] && ok "qa-transition: passing --check writes nothing" || bad "qa-transition: passing --check wrote — $(qa_writes)"
qa_fixture '{"cf_rn":"x","cf_tn":"","cf_ff":["f"],"cf_sp":1}'
expect "qa-transition: --check counts --notes as written" 0 qa --check --notes "1. open it"
[ -z "$(qa_writes)" ] && ok "qa-transition: --check --notes writes nothing" || bad "qa-transition: --check --notes wrote — $(qa_writes)"

qa_fixture '{"cf_rn":"x","cf_tn":"","cf_ff":["f"],"cf_sp":1}'
expect "qa-transition: --notes fills the only gap, then transitions" 0 qa --notes "1. open it"
put=$(grep -n '^PUT' "$QA/calls" | head -1 | cut -d: -f1)
chk=$(grep -n "^GET /rest/api/2/issue/ABC-1?fields=cf_rn,cf_tn,cf_ff,cf_sp" "$QA/calls" | head -1 | cut -d: -f1)
[ -n "$put" ] && [ -n "$chk" ] && [ "$put" -lt "$chk" ] && ok "qa-transition: notes are written before the field check" \
  || bad "qa-transition: order — $(cut -d' ' -f1-2 "$QA/calls" | paste -sd';' -)"
[ "$(cat "$QA/fired" 2>/dev/null)" = 31 ] && ok "qa-transition: transitions after the notes" || bad "qa-transition: notes path fired '$(cat "$QA/fired" 2>/dev/null)'"

qa_fixture "$FULL"
QA_ENV="$QA/qa-id.env" qa >"$QA/out"
grep -q 'JIRA_TRANSITION_QA_ID=12 is not offered for ABC-1; the live id is 31' "$QA/out" && ok "qa-transition: a stale configured id prints the live one" \
  || bad "qa-transition: stale id — $(head -1 "$QA/out")"
[ "$(cat "$QA/fired" 2>/dev/null)" = 31 ] && ok "qa-transition: fires the live id, not the stale one" || bad "qa-transition: stale id fired '$(cat "$QA/fired" 2>/dev/null)'"
qa_fixture "$FULL" '{"transitions":[{"id":"12","to":{"name":"QA Review"}}]}'
QA_ENV="$QA/qa-id.env" qa >"$QA/out"
! grep -q 'not offered' "$QA/out" && [ "$(cat "$QA/fired" 2>/dev/null)" = 12 ] && ok "qa-transition: a matching configured id is used silently" \
  || bad "qa-transition: matching id — $(head -1 "$QA/out")"
qa_fixture "$FULL" '{"transitions":[{"id":"5","to":{"name":"Done"}}]}'
expect "qa-transition: no QA transition offered fails" 1 qa
says   "qa-transition: and names what is reachable" 'reachable: Done' qa
qa_fixture "$FULL"; printf 'QA Review' > "$QA/status"
says   "qa-transition: already in QA is a no-op" 'no-op' qa
[ -z "$(cat "$QA/calls")" ] && ok "qa-transition: no-op makes no REST call" || bad "qa-transition: no-op called REST"
says   "qa-transition: --check says a ticket already in QA is a no-op" "ABC-1 already 'QA Review' — no-op" qa --check
expect "  … and exits 0" 0 qa --check
[ -z "$(cat "$QA/calls")" ] && ok "qa-transition: --check on a ticket in QA makes no REST call" || bad "qa-transition: --check in QA called REST"
rm -f "${QA:?}"/bin/* "${QA:?}"/{calls,status,fields.json,trans.json,fired,out,qa.env,qa-id.env}; rmdir "${QA:?}/bin" "${QA:?}"

echo "post-release-note against a stub curl (no network)"
# $FX/comments.json holds the ticket's comments as plain strings (REST v2 shape); a POSTed ADF
# comment is flattened to its text and appended.
PR="$(mktemp -d "${TMPDIR:-/tmp}/jt-lint-pr.XXXXXX")"
mkdir "$PR/bin"
cat > "$PR/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=''; method=GET; data=''
while [ $# -gt 1 ]; do
  case "$1" in -o) out="$2"; shift ;; -X) method="$2"; shift ;; --data) data="$2"; shift ;; -w|-u|-H) shift ;; esac
  shift
done
echo "$method ${1#*atlassian.net}" >> "$FX/calls"
case "$method" in
  GET)  cp "$FX/comments.json" "$out"; printf 200 ;;
  POST) t=$(printf '%s' "$data" | jq -r '[.body | .. | .text? // empty] | join("")')
        jq --arg t "$t" '.comments += [{body: $t}]' "$FX/comments.json" > "$FX/c.tmp" && mv "$FX/c.tmp" "$FX/comments.json"
        echo '{}' > "$out"; printf 201 ;;
esac
STUB
chmod +x "$PR/bin/curl"
echo '{"comments":[{"body":"Looks good."}]}' > "$PR/comments.json"; : > "$PR/calls"
prn() { (PATH="$PR/bin:$PATH" FX="$PR" JIRA_API_TOKEN=$stub_token "$T/post-release-note.sh" ABC-1 "$@" 2>&1); }
says   "post-release-note: --check says what it would post" 'would comment: Post-release task: run the backfill' prn --note "run the backfill" --check
! grep -q '^POST' "$PR/calls" && ok "post-release-note: --check posts nothing" || bad "post-release-note: --check posted"
says   "post-release-note: posts a marked comment" 'commented: Post-release task: run the backfill' prn --note "run the backfill"
[ "$(jq '.comments | length' "$PR/comments.json")" = 2 ] && ok "post-release-note: one comment added" || bad "post-release-note: comments — $(jq -c . "$PR/comments.json")"
says   "post-release-note: the same task again is a no-op" 'already has this post-release task' prn --note "run  the backfill"
[ "$(grep -c '^POST' "$PR/calls")" = 1 ] && ok "post-release-note: no duplicate comment" || bad "post-release-note: posted $(grep -c '^POST' "$PR/calls") times"
rm -f "${PR:?}"/bin/* "${PR:?}"/{calls,comments.json}; rmdir "${PR:?}/bin" "${PR:?}"

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

echo "review-toolkit (sibling suite)"
rt=$(bash "$T/../review-toolkit/test/lint.sh" 2>&1)
[ $? -eq 0 ] && ok "review-toolkit lint ($(printf '%s' "$rt" | tail -1 | sed 's/\x1b\[[0-9;]*m//g'))" || bad "review-toolkit lint: $(printf '%s' "$rt" | grep -m1 FAIL)"

echo "nightowl (sibling suite)"
rt=$(bash "$T/../nightowl/test/lint.sh" 2>&1)
[ $? -eq 0 ] && ok "nightowl lint ($(printf '%s' "$rt" | tail -1 | sed 's/\x1b\[[0-9;]*m//g'))" || bad "nightowl lint: $(printf '%s' "$rt" | grep -m1 FAIL)"

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
