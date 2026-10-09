#!/usr/bin/env bash
# smoke.sh — run the whole engine against the file-backed fixture adapters.
#
# Two things it proves, both of which used to require the live board:
#
#   1. PROVIDER-AGNOSTICISM. Every engine script runs to completion with MC_TRACKER and
#      MC_HOST set to `fixture` — no Jira, no GitHub, no network, no credentials. A script
#      that reaches past the adapter contract fails here, which is the whole point: the
#      contract gets stress-tested before a real second provider is written against it.
#   2. SAFETY. It stamps every live runtime file first and re-checks them at the end. A
#      script that writes to the real board, steals the real writer lock, or moves the
#      real rollover marker turns the run red.
#
# The committed fixtures are COPIED to a temp dir per run, so the write scripts can be
# exercised for real (mc-archive --commit and friends) without dirtying the repo.
#
#   ./lib/mission-control/test/smoke.sh          # run it
#   ./lib/mission-control/test/smoke.sh -v       # also print each script's output
set -uo pipefail

VERBOSE=""; [ "${1:-}" = "-v" ] && VERBOSE=1

_MC_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIVE="$HOME/.claude/mission-control"

pass=0; fail=0
export MC_WORKLOG_DIR="${TMPDIR:-/tmp}/mc-smoke-worklog.$$"   # every producer under test logs HERE, never to the live log
red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
dim()  { printf '\033[2m%s\033[0m\n' "$*"; }

# --- 1. stamp the live runtime files, so any write to them is detectable -------------
# Format: "<path>\t<sha or ABSENT>". A file the engine must never touch during a
# fixture run is listed here; ABSENT files must stay absent.
LIVE_FILES=(
  "$LIVE/state.json" "$LIVE/state.archive.json" "$LIVE/.writer-lock"
  "$LIVE/.last-archived-sprint" "$LIVE/.loop-heartbeat" "$LIVE/mc-inbox"
  "$LIVE/PAUSED" "$LIVE/CODER_SPAWN_LIVE" "$LIVE/LOOP_GUARD_OFF" "$LIVE/GATE1_AUTO" "$LIVE/KICKBACK_AUTO"
  "$LIVE/SPRINT_PLAN_AUTO"
)
_stamp() {
  local f
  for f in "${LIVE_FILES[@]}"; do
    if [ -e "$f" ]; then printf '%s\t%s\n' "$f" "$(shasum -a 256 "$f" | cut -d' ' -f1)"
    else printf '%s\tABSENT\n' "$f"; fi
  done
}
BEFORE="$(_stamp)"

# --- 2. fresh copy of the fixtures, so writes don't dirty the repo -------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp -R "$_MC_LIB/fixtures/example/." "$WORK/"

export MC_PROFILE="$_MC_LIB/profiles/fixture.env"
export MC_FIXTURES="$WORK"
# MC_STATE and the other write targets are all derived from MC_FIXTURES inside the
# profile, so pointing that one var at the temp copy redirects everything.
unset MC_STATE MC_ARCHIVE MC_LOCK MC_CYCLE_MARKER MC_INBOX 2>/dev/null || true

# run <label> <allowed-exit-codes,csv> <cmd…>
run() {
  local label="$1" ok_codes="$2"; shift 2
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [[ ",$ok_codes," == *",$rc,"* ]]; then
    grn "  PASS  $label (exit $rc)"; pass=$((pass+1))
  else
    red "  FAIL  $label (exit $rc, expected one of $ok_codes)"
    printf '%s\n' "$out" | sed 's/^/          /'; fail=$((fail+1)); return
  fi
  [ -n "$VERBOSE" ] && printf '%s\n' "$out" | sed 's/^/          /'
  return 0
}

# says <label> <yes|no> <pattern> <cmd…> — assert the output does (or does not) match.
# Exit codes are too weak on their own: mc-poll exits 0 whether or not it managed to
# JOIN the board to the host, so a broken join would read as a pass. These pin the
# join, the tier split, and the bot filtering to actual content.
says() {
  local label="$1" want="$2" pat="$3"; shift 3
  local out; out="$("$@" 2>&1)"
  local hit=no; printf '%s' "$out" | grep -qE "$pat" && hit=yes
  if [ "$hit" = "$want" ]; then
    grn "  PASS  $label"; pass=$((pass+1))
  else
    red "  FAIL  $label (wanted match=$want for /$pat/)"
    printf '%s\n' "$out" | sed 's/^/          /'; fail=$((fail+1))
  fi
}

echo
echo "engine against the fixture adapters   (fixtures: $WORK)"
echo "────────────────────────────────────────────────────────────────"

# --- 3. adapter contract: every op answers ------------------------------------------
. "$_MC_LIB/adapters/dispatch.sh"
run "tracker capabilities"        0 tracker capabilities
run "tracker list_ready in"       0 tracker list_ready "Ready for Dev" in
run "tracker list_ready out+vet"  0 tracker list_ready "Ready for Dev" out vetted
run "tracker fields_of"           0 tracker fields_of ENG-201 ENG-202
run "tracker in_active_cycle"     0 tracker in_active_cycle ENG-204 ENG-207
run "tracker active_cycle"        0 tracker active_cycle
run "tracker detail_of"           0 tracker detail_of ENG-101
says "detail_of returns the authored body" yes 'token bucket'  tracker detail_of ENG-101
says "detail_of stubs an undetailed key"   yes 'ENG-201'       tracker detail_of ENG-201
run "host capabilities"           0 host capabilities
run "host list_prs"               0 host list_prs example-org/app all
run "host list_prs mine"          0 host list_prs example-org/app open mine
run "host get_pr"                 0 host get_pr example-org/app 201
says "get_pr returns the one PR"   yes '^\{.*"number":201[,}]'  host get_pr example-org/app 201
run "get_pr not-found → empty"     0 bash -c 'test -z "$("$0" get_pr example-org/app 299)"' "$_MC_LIB/adapters/host/fixture.sh"
run "get_pr host failure → nonzero" 1 env MC_FIXTURE_GET_PR_FAIL=1 "$_MC_LIB/adapters/host/fixture.sh" get_pr example-org/app 201
run "host review_threads"         0 host review_threads example-org/app 202
run "host whoami"                 0 host whoami

# Runner seam: selection resolves from the profile; the in-process impl round-trips a
# spawn → status → result → harvest → teardown against the temp dir; the herdr impl is
# only asked what it can answer without a pane (capabilities, a gone handle).
run  "runner_for resolves"           0 bash -c '. "$0"; [ "$(runner_for coder sprint)" = inprocess ]' "$_MC_LIB/adapters/dispatch.sh"
run  "runner_for per-cycle override" 0 bash -c '. "$0"; MC_RUNNER_PLANNER_SPRINT=herdr MC_RUNNER_PLANNER=inprocess; [ "$(runner_for planner sprint)" = herdr ] && [ "$(runner_for planner background)" = inprocess ]' "$_MC_LIB/adapters/dispatch.sh"
run  "runner_of routes handles"      0 bash -c '. "$0"; [ "$(runner_of "x|inprocess|m|r")" = inprocess ] && [ "$(runner_of "x|ws1:t2|ws1:p2|r")" = herdr ]' "$_MC_LIB/adapters/dispatch.sh"
run  "runner inprocess capabilities" 0 runner inprocess capabilities
printf 'smoke brief\n' > "$WORK/runner/brief.md"
RH="$(runner inprocess spawn coder ENG-901 "$WORK" "$WORK/runner/brief.md" "$WORK/runner/eng-901.json")"
says "inprocess spawn mints a handle"  yes '^coder-eng-901\|inprocess\|' printf '%s' "$RH"
says "inprocess status running"        yes '^running$' runner inprocess status "$RH"
run  "inprocess wait times out (2)"    2 runner inprocess wait "$RH" 1000
printf '{"verdict":"pass"}' > "$WORK/runner/eng-901.json"
says "inprocess status done"           yes '^done$'    runner inprocess status "$RH"
run  "inprocess wait returns"          0 runner inprocess wait "$RH"
says "inprocess harvest returns JSON"  yes 'verdict'   runner inprocess harvest "$RH"
run  "inprocess teardown"              0 runner inprocess teardown "$RH"
says "inprocess list is empty"         no  '.'         runner inprocess list
run  "inprocess refuses --settings"    1 runner inprocess spawn coder ENG-902 "$WORK" "$WORK/runner/brief.md" "$WORK/runner/eng-902.json" --settings "$WORK/runner/brief.md"
run  "runner herdr capabilities"       0 "$_MC_LIB/adapters/runner/herdr.sh" capabilities
# herdr is an OPTIONAL runner: the engine defaults every role to inprocess and only this
# adapter needs the CLI. Its live-ish ops are exercised only where the CLI exists.
if command -v herdr >/dev/null 2>&1; then
  says "herdr status gone for unknown"   yes '^gone$'    "$_MC_LIB/adapters/runner/herdr.sh" status 'nosuch|x|y|'
  run  "herdr spawn refuses w/o workspace" 1 env -u MC_HERDR_WS_SPRINT -u MC_HERDR_WORKSPACE "$_MC_LIB/adapters/runner/herdr.sh" spawn coder ENG-902 "$WORK" "$WORK/runner/brief.md" "$WORK/runner/x.json"
else
  dim "  SKIP  herdr CLI not installed — status/spawn assertions skipped (capabilities still checked)"
fi
# Workspace lookup by label runs against a stub herdr, so it is checked on every machine.
# herdr renumbers workspaces as they close and reopen; a label in the profile survives that.
HSTUB="$WORK/herdr-stub"; mkdir -p "$HSTUB"
cat > "$HSTUB/herdr" <<'STUB'
#!/usr/bin/env bash
[ "$1 $2" = "workspace list" ] && printf '%s' '{"result":{"workspaces":[{"workspace_id":"ws7","label":"sprint"},{"workspace_id":"ws9","label":"out of cycle"}]}}'
exit 0
STUB
chmod +x "$HSTUB/herdr"
says "herdr workspace resolves a label"       yes '^ws7$' env PATH="$HSTUB:$PATH" "$_MC_LIB/adapters/runner/herdr.sh" workspace sprint
says "herdr workspace label ignores case"     yes '^ws9$' env PATH="$HSTUB:$PATH" "$_MC_LIB/adapters/runner/herdr.sh" workspace "Out Of Cycle"
says "herdr workspace keeps a live id"        yes '^ws9$' env PATH="$HSTUB:$PATH" "$_MC_LIB/adapters/runner/herdr.sh" workspace ws9
run  "herdr workspace refuses an unknown one" 1 env PATH="$HSTUB:$PATH" "$_MC_LIB/adapters/runner/herdr.sh" workspace w11

# spawn --settings: a caller's settings file (a per-pane permission profile) reaches the
# claude start line as ONE --settings, with the auto-compact env merged in. claude takes a
# single --settings, so two flags would silently drop one of them.
SSTUB="$WORK/herdr-spawn-stub"; mkdir -p "$SSTUB"
cat > "$SSTUB/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "workspace list") printf '%s' '{"result":{"workspaces":[{"workspace_id":"ws7","label":"night"}]}}' ;;
  "tab create")     printf '%s' '{"result":{"tab":{"tab_id":"ws7:t1"},"root_pane":{"pane_id":"ws7:p1"}}}' ;;
  "agent get")      printf '%s' '{"result":{"agent":{"agent_status":"idle"}}}' ;;
  "agent start")    printf '%s\n' "$@" > "$HERDR_STUB_LOG" ;;
esac
exit 0
STUB
chmod +x "$SSTUB/herdr"
printf '%s' '{"permissions":{"deny":["Bash(op *)"]}}' > "$WORK/runner/pane.settings.json"
_hspawn() { env PATH="$SSTUB:$PATH" HERDR_STUB_LOG="$WORK/runner/start.log" MC_HERDR_WORKSPACE=night "$_MC_LIB/adapters/runner/herdr.sh" spawn nightowl t1 "$WORK" "$WORK/runner/brief.md" "$WORK/runner/t1.json" "$@"; }
run  "herdr spawn --settings mints a handle"  0 _hspawn --settings "$WORK/runner/pane.settings.json"
says "herdr spawn passes one --settings"      yes '^1$' grep -c '^--settings$' "$WORK/runner/start.log"
HSET="$(grep -A1 '^--settings$' "$WORK/runner/start.log" | tail -1)"
says "herdr spawn keeps the caller's denies"  yes 'Bash\(op \*\)' jq -c . "$HSET"
says "herdr spawn merges auto-compact env"    yes '"CLAUDE_CODE_AUTO_COMPACT_WINDOW":"200000"' jq -c . "$HSET"
says "herdr spawn leaves the caller's file"   no  'AUTO_COMPACT' cat "$WORK/runner/pane.settings.json"
run  "herdr spawn refuses a missing settings" 1 _hspawn --settings "$WORK/runner/nope.json"
run  "herdr spawn without --settings"         0 _hspawn
says "herdr spawn inline compact settings"    yes '^\{"env":\{"CLAUDE_CODE_AUTO_COMPACT_WINDOW":"200000"\}\}$' cat "$WORK/runner/start.log"

# The fixture adapters' DEFAULT data dir, with MC_FIXTURES unset. Worth pinning: the
# default is dead code in every normal run (the profile always sets MC_FIXTURES), so a
# wrong path here rots unnoticed — and it did, resolving one level too high and returning
# empty, which reads as "nothing ready" rather than "misconfigured".
run "tracker default data dir"     0 env -u MC_FIXTURES "$_MC_LIB/adapters/tracker/fixture.sh" list_ready "Ready for Dev" in
run "host default data dir"        0 env -u MC_FIXTURES "$_MC_LIB/adapters/host/fixture.sh" whoami
says "tracker default finds rows" yes 'ENG-101' env -u MC_FIXTURES "$_MC_LIB/adapters/tracker/fixture.sh" list_ready "Ready for Dev" in
# A missing data dir must be LOUD (exit 2), not an empty degrade.
run "missing data dir errors"      2 env MC_FIXTURES=/nonexistent/mc-fixtures "$_MC_LIB/adapters/tracker/fixture.sh" list_ready "Ready for Dev" in

# --- 4. the read-only detectors ------------------------------------------------------
run "mc-health"                0,10,11 "$_MC_LIB/mc-health.sh"
run "mc-poll"                    0,1   "$_MC_LIB/mc-poll.sh"
run "mc-inbound"                 0,1   "$_MC_LIB/mc-inbound.sh"
run "mc-orphans"                 0,1   "$_MC_LIB/mc-orphans.sh"
run "mc-promote (sweep)"       0,1,3,4 "$_MC_LIB/mc-promote.sh"
run "mc-promote --key"         0,1,3,4 "$_MC_LIB/mc-promote.sh" --key ENG-204
run "mc-review-check"         0,1,2,10 "$_MC_LIB/mc-review-check.sh" example-org/app 202
run "mc-archive (check)"         0,1,3 "$_MC_LIB/mc-archive.sh"

# --- 4b. content assertions: the engine actually JOINED board ↔ tracker ↔ host -------
says "mc-poll joins PRs to the host"      no  'host-miss'                "$_MC_LIB/mc-poll.sh"
says "mc-poll reads tracker status"       no  'tracker-miss'             "$_MC_LIB/mc-poll.sh"
says "mc-poll flags the regression"      yes  'REGRESSED'                "$_MC_LIB/mc-poll.sh"
says "mc-poll names no provider"          no  '(?i)jira|github|gh-'      "$_MC_LIB/mc-poll.sh"
says "mc-poll shows runner live status"  yes  '●coder[^ ]*@inprocess:running'  "$_MC_LIB/mc-poll.sh"
# An open PR older than the host's list window. MC_FIXTURE_LIST_LIMIT=2 keeps only the two
# newest PRs (301, 302) in list_prs, so every board PR falls outside it, as an old open PR
# does past the live window. ENG-221 points at a PR the host does not have at all.
jq '.tickets += [{"ticket":"ENG-221","lane":"in-review","cycle":"sprint","worker":null,"blocked":false,
  "pr":"https://example.invalid/example-org/app/pull/299"}]' "$WORK/state.json" > "$WORK/state.host-window.json"
poll_hw() { MC_STATE="$WORK/state.host-window.json" MC_FIXTURE_LIST_LIMIT=2 "$_MC_LIB/mc-poll.sh"; }
says "a PR outside the list window is not a host-miss" no  'app#20[1-3]\(host-miss\)'               poll_hw
says "  … it is joined through get_pr"                 yes '^ENG-202 .*app#202 +ready +CHANGES_REQUESTED +fail'  poll_hw
says "  … a PR the host lacks is still a host-miss"    yes '^ENG-221 .*app#299\(host-miss\)'      poll_hw
says "  … a get_pr failure is host-err, not host-miss" yes '^ENG-202 .*app#202\(host-err\)'       env MC_FIXTURE_GET_PR_FAIL=1 bash -c 'MC_STATE="$0" MC_FIXTURE_LIST_LIMIT=2 "$1"' "$WORK/state.host-window.json" "$_MC_LIB/mc-poll.sh"
says "mc-orphans sweeps runner sessions" yes  'orphan runner sessions'    env MC_RUNNER_CODER=herdr MC_HERDR_WS_SPRINT= "$_MC_LIB/mc-orphans.sh"
says "mc-health emits the host key" yes  '"host":'                  "$_MC_LIB/mc-health.sh"
says "mc-health names no provider"    no  '(?i)github|"github"'        "$_MC_LIB/mc-health.sh"
says "mc-inbound finds the sprint tier"  yes  'sprint.*ENG-101|ENG-101' "$_MC_LIB/mc-inbound.sh"
says "mc-inbound finds the bg tier"      yes  'ENG-102'                  "$_MC_LIB/mc-inbound.sh"
says "mc-inbound skips the unvetted"      no  'ENG-103'                  "$_MC_LIB/mc-inbound.sh"
says "mc-inbound skips a teammate ticket"   no  'ENG-104'                  "$_MC_LIB/mc-inbound.sh"
says "mc-orphans finds the orphan"       yes  '301'                      "$_MC_LIB/mc-orphans.sh"
says "mc-orphans skips the teammate PR"   no  '302'                      "$_MC_LIB/mc-orphans.sh"
says "mc-promote finds the promotion"    yes  'ENG-204'                  "$_MC_LIB/mc-promote.sh"
says "review-check keeps the real note"  yes  'members_controller'       "$_MC_LIB/mc-review-check.sh" example-org/app 202
says "review-check drops the bot thread"  no  'Gemfile.lock'             "$_MC_LIB/mc-review-check.sh" example-org/app 202
says "review-check drops the resolved"    no  'stray whitespace'         "$_MC_LIB/mc-review-check.sh" example-org/app 202
says "review-check drops the outdated"    no  'Superseded'               "$_MC_LIB/mc-review-check.sh" example-org/app 202
says "review-check clean on approved"     no  'NEEDS-TRIAGE'             "$_MC_LIB/mc-review-check.sh" example-org/app 203

# --- 5. the write path, against the temp board only ---------------------------------
run "mc-lock acquire"              0,1 "$_MC_LIB/mc-lock.sh" acquire loop
run "mc-lock release"              0,1 "$_MC_LIB/mc-lock.sh" release loop

# --- loop guard: manual-only wrappers refuse while the loop holds the writer lock -----
G="$_MC_LIB/mc-guard.sh"; GL="$WORK/guard.lock"; GO="$WORK/guard.off"
run  "guard allows on a free lock"          0 env MC_LOCK="$GL" MC_GUARD_OFF_FILE="$GO" "$G" check merge
printf 'loop\t%s\n' "$(date +%s)" > "$GL"
run  "guard REFUSES under a live loop lock" 4 env MC_LOCK="$GL" MC_GUARD_OFF_FILE="$GO" "$G" check merge
says "guard names the wrapper + holder"     yes "REFUSED.*merge.*'loop'" env MC_LOCK="$GL" MC_GUARD_OFF_FILE="$GO" "$G" check merge
run  "guard one-shot override (env)"        0 env MC_LOCK="$GL" MC_GUARD_OFF_FILE="$GO" MC_LOOP_GUARD=off "$G" check merge
run  "guard marker override (mc guard off)" 0 env MC_LOCK="$GL" MC_GUARD_OFF_FILE="$GO" "$G" off
run  "guard allows while marker present"    0 env MC_LOCK="$GL" MC_GUARD_OFF_FILE="$GO" "$G" check merge
says "guard says it is off, never silent"   yes 'guard is OFF' env MC_LOCK="$GL" MC_GUARD_OFF_FILE="$GO" "$G" check merge
run  "guard re-armed (mc guard on)"         0 env MC_LOCK="$GL" MC_GUARD_OFF_FILE="$GO" "$G" on
run  "guard off for ONE wrapper"            0 env MC_LOCK="$GL" MC_GUARD_OFF_FILE="$GO" "$G" off merge
run  "  … that wrapper passes"              0 env MC_LOCK="$GL" MC_GUARD_OFF_FILE="$GO" "$G" check merge
run  "  … a sibling still REFUSES"          4 env MC_LOCK="$GL" MC_GUARD_OFF_FILE="$GO" "$G" check qa-transition
says "  … status lists only that one"      yes 'OFF for: merge'  env MC_LOCK="$GL" MC_GUARD_OFF_FILE="$GO" "$G" status
run  "guard on for that wrapper"            0 env MC_LOCK="$GL" MC_GUARD_OFF_FILE="$GO" "$G" on merge
run  "  … it REFUSES again"                 4 env MC_LOCK="$GL" MC_GUARD_OFF_FILE="$GO" "$G" check merge
run  "guard off for the fields GROUP"       0 env MC_LOCK="$GL" MC_GUARD_OFF_FILE="$GO" "$G" off fields
run  "  … a field wrapper in it passes"     0 env MC_LOCK="$GL" MC_GUARD_OFF_FILE="$GO" "$G" check release-note fields
says "  … and says the group opened it"    yes 'marker: group fields' env MC_LOCK="$GL" MC_GUARD_OFF_FILE="$GO" "$G" check qa-transition fields
run  "  … merge (not in it) still REFUSES" 4 env MC_LOCK="$GL" MC_GUARD_OFF_FILE="$GO" "$G" check merge
run  "  … a groupless call still REFUSES"  4 env MC_LOCK="$GL" MC_GUARD_OFF_FILE="$GO" "$G" check release-note
run  "guard on for the group"               0 env MC_LOCK="$GL" MC_GUARD_OFF_FILE="$GO" "$G" on fields
run  "  … the field wrapper REFUSES again" 4 env MC_LOCK="$GL" MC_GUARD_OFF_FILE="$GO" "$G" check release-note fields
says "  … the refusal names the group"     yes 'mc guard off fields' env MC_LOCK="$GL" MC_GUARD_OFF_FILE="$GO" "$G" check release-note fields
printf 'loop\t%s\n' "$(( $(date +%s) - 100000 ))" > "$GL"
run  "guard allows on a STALE loop lock"    0 env MC_LOCK="$GL" MC_GUARD_OFF_FILE="$GO" "$G" check merge
printf 'manual\t%s\n' "$(date +%s)" > "$GL"
run  "guard allows a manual holder"         0 env MC_LOCK="$GL" MC_GUARD_OFF_FILE="$GO" "$G" check merge
printf 'ENG-999 a scratch inbox line\n' > "$WORK/mc-inbox"
run "mc-inbox-drain"             0,1,2 "$_MC_LIB/mc-inbox-drain.sh" ENG-999

# --- work log: append-only JSONL, one file per day --------------------------------------
WL="$_MC_LIB/worklog.sh"
run  "worklog add"                          0 "$WL" add --source smoke --ticket ENG-101 "merged the fixture PR"
run  "worklog add infers the ticket key"    0 "$WL" add --source smoke "reviewed ENG-102 for a teammate"
run  "worklog add with MC_WORKLOG=off"      0 env MC_WORKLOG=off "$WL" add "must not land"
says "worklog today lists both lines"       yes 'ENG-101.*merged'     "$WL" today
says "  … inferred key present"            yes 'ENG-102'             "$WL" today
says "  … the off line is absent"          no  'must not land'       "$WL" today
says "worklog --json is a 2-entry array"    yes '^2$'  bash -c '"$0" today --json | jq length' "$WL"
run  "worklog add without text fails"       2 "$WL" add --source smoke
printf 'approve ENG-101\n' > "$WORK/mc-inbox"
run  "drain logs what it removed"           0 env MC_INBOX="$WORK/mc-inbox" "$_MC_LIB/mc-inbox-drain.sh" "approve ENG-101"
says "  … as an orchestrator line"         yes '\[orchestrator\].*acted on: approve ENG-101' "$WL" today
rm -rf "$MC_WORKLOG_DIR"

# --- 6. dash renders the fixture board ----------------------------------------------
frame="$(MC_INTERVAL=99 MC_GATE1_FILE="$WORK/GATE1_AUTO" MC_ADDRESS_FILE="$WORK/KICKBACK_AUTO" MC_CODER_FILE="$WORK/CODER_SPAWN_LIVE" MC_PAUSE_FILE="$WORK/PAUSED" timeout 8 "$_MC_LIB/dash.sh" 2>&1)"
if printf '%s' "$frame" | grep -q 'MISSION CONTROL'; then
  grn "  PASS  dash renders ($(printf '%s' "$frame" | wc -l | tr -d ' ') lines)"; pass=$((pass+1))
  [ -n "$VERBOSE" ] && printf '%s\n' "$frame" | sed 's/^/          /'
else
  red "  FAIL  dash produced no frame"; printf '%s\n' "$frame" | sed 's/^/          /'; fail=$((fail+1))
fi

# A refined ticket committed to the sprint is a board row; only refined tickets outside
# the sprint fold into the parked footer. Rendered from a derived board so the shared
# fixture (which the detectors above assert on) stays untouched.
jq '.tickets += [{"ticket":"ENG-208","lane":"refined","cycle":"sprint","worker":null,"blocked":false,"desc":"Sprint ticket awaiting a plan"}]' \
  "$WORK/state.json" > "$WORK/state.sprint-refined.json"
dash_sr() { MC_STATE="$WORK/state.sprint-refined.json" MC_INTERVAL=99 MC_GATE1_FILE="$WORK/GATE1_AUTO" MC_ADDRESS_FILE="$WORK/KICKBACK_AUTO" MC_CODER_FILE="$WORK/CODER_SPAWN_LIVE" MC_PAUSE_FILE="$WORK/PAUSED" timeout 8 "$_MC_LIB/dash.sh"; }
says "dash rows a sprint refined ticket"     yes '^ +ENG-208 +refined '        dash_sr
says "  … and keeps it out of parked"        no  'parked.*ENG-208'             dash_sr
says "  … a non-sprint refined stays parked" yes 'parked.*: 1 — ENG-207'       dash_sr
says "  … and gets no row"                   no  '^ +ENG-207 '                 dash_sr

# --- 6b. sprint plan queue: propose planning for sprint refined tickets that are yours ---
# Another derived board. Eligible = refined + cycle:sprint + no worker + not blocked +
# assigned to the operator (tracker mine_of). The loop says "would plan" ONCE, records
# plan_proposed on the row, and clears it when the row stops being eligible.
jq '.tickets += [
  {"ticket":"ENG-208","lane":"refined","cycle":"sprint","worker":null,"blocked":false},
  {"ticket":"ENG-209","lane":"refined","cycle":"sprint","worker":null,"blocked":false},
  {"ticket":"ENG-210","lane":"refined","cycle":"sprint","worker":null,"blocked":false,"plan_proposed":true},
  {"ticket":"ENG-211","lane":"refined","cycle":"sprint","worker":null,"blocked":true},
  {"ticket":"ENG-212","lane":"refined","cycle":"sprint","worker":"critic","blocked":false},
  {"ticket":"ENG-213","lane":"refined","cycle":"background","worker":null,"blocked":false},
  {"ticket":"ENG-214","lane":"refined","cycle":"sprint","worker":null,"blocked":false,"plan_proposed":true},
  {"ticket":"ENG-215","lane":"plan-review","cycle":"sprint","worker":null,"blocked":false,"plan_proposed":true}]' \
  "$WORK/state.json" > "$WORK/state.sprint-plan.json"
poll_sp() { MC_STATE="$WORK/state.sprint-plan.json" MC_SPRINT_PLAN_FILE="$WORK/SPRINT_PLAN_AUTO" "$_MC_LIB/mc-poll.sh"; }
run  "tracker mine_of"                        0 tracker mine_of ENG-208 ENG-209 ENG-210
says "mine_of keeps the operator's ticket"   yes '^ENG-208$'                    tracker mine_of ENG-208 ENG-209 ENG-210
says "  … drops the unassigned one"           no  'ENG-209'                      tracker mine_of ENG-208 ENG-209 ENG-210
says "  … drops the teammate's"               no  'ENG-210'                      tracker mine_of ENG-208 ENG-209 ENG-210
says "poll proposes a sprint refined ticket" yes '^  would plan ENG-208 '       poll_sp
says "  … in propose mode by default"        yes 'sprint plan queue.*mode: propose'  poll_sp
says "  … not an unassigned one"              no  'would plan ENG-209'           poll_sp
says "  … which stays parked"                yes '^parked.*ENG-209\(sprint,not-yours\)'  poll_sp
says "  … not a teammate's"                   no  'would plan ENG-210'           poll_sp
says "  … which stays parked"                yes '^parked.*ENG-210\(sprint,not-yours\)'  poll_sp
says "parked count counts tickets, not words" yes '^parked.*: 3 — '  poll_sp
says "  … not a blocked one"                  no  'would plan ENG-211'           poll_sp
says "  … not one a worker holds"             no  'would plan ENG-212'           poll_sp
says "  … not a background one"               no  'would plan ENG-213'           poll_sp
says "background queue is unchanged"         yes '^background queue.*: 1 — ENG-213$'  poll_sp
says "a proposed ticket is not re-proposed"   no  'would plan ENG-214'           poll_sp
says "  … but stays listed as proposed"      yes '^  ENG-214 +proposed'         poll_sp
says "a stale proposal is cleared"           yes '^plan_proposed to clear.*ENG-210'  poll_sp
says "  … including one that left refined"   yes '^plan_proposed to clear.*ENG-215'  poll_sp
says "  … but not a live one"                 no  '^plan_proposed to clear.*ENG-214'  poll_sp
# Background condition (a): only the operator's sprint refined rows (and ones a planning
# worker already holds) put sprint planning ahead of background. A not-yours row does not.
says "condition (a) is held by the operator's sprint rows" yes '^background condition \(a\): held —.* ENG-208'  poll_sp
says "  … including a proposed one"           yes '^background condition \(a\): held —.* ENG-214'  poll_sp
says "  … and one a planning worker holds"    yes '^background condition \(a\): held —.* ENG-212'  poll_sp
says "  … but not an unassigned one"          no  '^background condition \(a\).*ENG-209'  poll_sp
says "  … nor a teammate's"                   no  '^background condition \(a\).*ENG-210'  poll_sp
says "  … nor a blocked one"                  no  '^background condition \(a\).*ENG-211'  poll_sp
jq '.tickets += [
  {"ticket":"ENG-209","lane":"refined","cycle":"sprint","worker":null,"blocked":false},
  {"ticket":"ENG-210","lane":"refined","cycle":"sprint","worker":null,"blocked":false},
  {"ticket":"ENG-213","lane":"refined","cycle":"background","worker":null,"blocked":false}]' \
  "$WORK/state.json" > "$WORK/state.cond-a.notmine.json"
jq '.tickets += [
  {"ticket":"ENG-209","lane":"refined","cycle":"sprint","worker":null,"blocked":false},
  {"ticket":"ENG-213","lane":"refined","cycle":"background","worker":null,"blocked":false},
  {"ticket":"ENG-214","lane":"refined","cycle":"sprint","worker":null,"blocked":false,"plan_proposed":true}]' \
  "$WORK/state.json" > "$WORK/state.cond-a.mine.json"
poll_ca1() { MC_STATE="$WORK/state.cond-a.notmine.json" MC_SPRINT_PLAN_FILE="$WORK/SPRINT_PLAN_AUTO" "$_MC_LIB/mc-poll.sh"; }
poll_ca2() { MC_STATE="$WORK/state.cond-a.mine.json" MC_SPRINT_PLAN_FILE="$WORK/SPRINT_PLAN_AUTO" "$_MC_LIB/mc-poll.sh"; }
says "not-yours sprint rows leave condition (a) clear" yes '^background condition \(a\): clear'  poll_ca1
says "  … so background stays plannable"      yes '^background queue.*: 1 — ENG-213$'  poll_ca1
says "a mine+proposed sprint row still holds (a)" yes '^background condition \(a\): held — ENG-214'  poll_ca2
# The second tick: the loop has set plan_proposed on ENG-208, so nothing new is proposed.
jq '(.tickets[] | select(.ticket=="ENG-208")).plan_proposed = true' "$WORK/state.sprint-plan.json" > "$WORK/state.sprint-plan.2.json"
poll_sp2() { MC_STATE="$WORK/state.sprint-plan.2.json" MC_SPRINT_PLAN_FILE="$WORK/SPRINT_PLAN_AUTO" "$_MC_LIB/mc-poll.sh"; }
says "second tick does not re-propose"        no  'would plan'                   poll_sp2
says "  … and lists it as proposed"          yes '^  ENG-208 +proposed'         poll_sp2
# Armed (the flag file present), the same row reads as an action, not a proposal.
touch "$WORK/SPRINT_PLAN_AUTO"
says "armed mode plans instead of proposing" yes '^  plan ENG-208 '             poll_sp
says "  … and says so in the header"         yes 'sprint plan queue.*mode: auto'  poll_sp
rm -f "$WORK/SPRINT_PLAN_AUTO"
dash_sp() { MC_STATE="$WORK/state.sprint-plan.2.json" MC_INTERVAL=99 MC_GATE1_FILE="$WORK/GATE1_AUTO" MC_ADDRESS_FILE="$WORK/KICKBACK_AUTO" MC_CODER_FILE="$WORK/CODER_SPAWN_LIVE" MC_PAUSE_FILE="$WORK/PAUSED" timeout 8 "$_MC_LIB/dash.sh"; }
says "dash puts a proposed ticket in NEEDS YOU" yes '^ +ENG-208 +\[refined\].*mc plan ENG-208'  dash_sp
says "  … but not an unproposed sprint one"     no  '^ +ENG-209 +\[refined\]'                    dash_sp

# --- 6c. post-merge QA move: the tracker moves at merge, the board after the smoke ------
# A derived board of alpha-verify rows. tracker_qa_at records the at-merge QA move, so the
# poller says, per row, whether the move is still due, already done (then `mc qa` is
# board-only), or must never be re-run.
jq '.tickets += [
  {"ticket":"ENG-216","lane":"alpha-verify","cycle":"sprint","worker":null,"blocked":false},
  {"ticket":"ENG-217","lane":"alpha-verify","cycle":"sprint","worker":null,"blocked":false,"tracker_qa_at":"2026-08-25T08:30:00Z"},
  {"ticket":"ENG-218","lane":"alpha-verify","cycle":"sprint","worker":null,"blocked":false},
  {"ticket":"ENG-219","lane":"alpha-verify","cycle":"sprint","worker":null,"blocked":false,"tracker_qa_at":"2026-08-24T15:00:00Z"},
  {"ticket":"ENG-220","lane":"alpha-verify","cycle":"sprint","worker":null,"blocked":true,"question":"on hold"}]' \
  "$WORK/state.json" > "$WORK/state.post-merge-qa.json"
poll_pq() { MC_STATE="$WORK/state.post-merge-qa.json" MC_SPRINT_PLAN_FILE="$WORK/SPRINT_PLAN_AUTO" "$_MC_LIB/mc-poll.sh"; }
says "poll lists the post-merge QA move"         yes '^post-merge QA move \(alpha-verify · tracker QA status: QA\)'  poll_pq
says "  … due on a merged row not yet in QA"      yes '^  ENG-216 +due — field check'                 poll_pq
says "  … in QA once the move is recorded"        yes '^  ENG-217 +in QA \(tracker\) — `mc qa ENG-217` moves the board only'  poll_pq
says "  … so it is not due again"                 no  '^  ENG-217 +due'                               poll_pq
says "  … a row moved outside the loop is marked, not moved" yes '^  ENG-218 +tracker already QA — set tracker_qa_at; run no QA move'  poll_pq
says "  … a row that left QA is flagged, never re-moved" yes '^  ENG-219 +tracker_qa_at set but tracker at In Review — flag; never re-run'  poll_pq
says "  … a blocked row waits"                     yes '^  ENG-220 +waiting \(blocked\)'               poll_pq
says "  … no other lane is listed"                no  '^  ENG-20[1-7] +(due|in QA|waiting)'           poll_pq
says "alpha-verify in the QA status is not a regression" no 'REGRESSED.*ENG-21[78]'               poll_pq
says "the default board has no post-merge QA section" no '^post-merge QA move'                      "$_MC_LIB/mc-poll.sh"
dash_pq() { MC_STATE="$WORK/state.post-merge-qa.json" MC_INTERVAL=99 MC_GATE1_FILE="$WORK/GATE1_AUTO" MC_ADDRESS_FILE="$WORK/KICKBACK_AUTO" MC_CODER_FILE="$WORK/CODER_SPAWN_LIVE" MC_PAUSE_FILE="$WORK/PAUSED" timeout 8 "$_MC_LIB/dash.sh"; }
says "dash says a moved row is in QA, awaiting the smoke" yes 'ENG-217 +\[alpha-verify\].*in QA \(tracker\) · smoke on alpha, then mc qa ENG-217'  dash_pq
says "  … and keeps the merge wording before the move"   yes 'ENG-216 +\[alpha-verify\].*merged — smoke-test on alpha'  dash_pq
says "mc usage says qa is board-only after the move" yes 'qa +ABC-X +alpha smoke passed → lane qa \(board only once the tracker moved at merge;'  env MC_INBOX="$WORK/mc-inbox" MC_PAUSE_FILE="$WORK/PAUSED" bash -c '. "$0"; mc help' "$_MC_LIB/mc"

# --- 6d. profile fills ----------------------------------------------------------------
# The driver names the org-valued fills the overlay must supply; the example profile is
# what an operator copies. A fill the driver relies on with no row in the example is a
# fill nobody knows to set, and the driver then improvises it. A row is a table row or a
# `### {FILL}` heading; a passing mention in prose does not count.
echo
echo "profile fills   (driver ↔ example profile)"
echo "────────────────────────────────────────────────────────────────"
DRIVER="$_MC_LIB/loop-driver.engine.md"
EXPROFILE="$_MC_LIB/profiles/example.profile.md"
MC_SKILL_MD="$_MC_LIB/../../skills/mission-control/SKILL.md"
TEMPLATES="$_MC_LIB/../../skills/mission-control/templates"
CREATE_PR_MD="$_MC_LIB/../../skills/create-pr/SKILL.md"
driver_fills()  { awk '/the \*\*Template fills\*\* table/{f=1} f{print} f&&/\)\./{exit}' "$DRIVER"; }
fills_missing() {
  local f section
  section="$(awk '/^## Template fills/{f=1;next} f&&/^## /{exit} f' "$EXPROFILE")"
  for f in $(driver_fills | grep -oE '\{[A-Z_]+\}' | sort -u); do
    printf '%s\n' "$section" | grep -qF -e "| \`$f\` |" -e "### \`$f\`" || echo "MISSING $f"
  done
}
driver_r1pass() { awk '/^- R1 \*\*`pass`\*\*/{f=1} f&&/^- R1 \*\*`blockers`/{exit} f' "$DRIVER"; }
says "driver lists the overlay fills"                 yes '\{STYLE_GUIDE\}' driver_fills
says "every driver fill has an example-profile row"   no  'MISSING' fills_missing
says "driver requires {PR_BODY_GUIDE} from the overlay" yes '\{PR_BODY_GUIDE\}' driver_fills
says "driver's draft-PR step uses {PR_BODY_GUIDE}"    yes '\{PR_BODY_GUIDE\}' driver_r1pass
says "driver no longer names the make-pr rules"       no  '.' grep -n 'make-pr' "$DRIVER"
says "SKILL fills list names {PR_BODY_GUIDE}"         yes '.' grep -nE 'filled from the overlay.*\{PR_BODY_GUIDE\}|\{PR_BODY_GUIDE\}.*filled from the overlay' "$MC_SKILL_MD"
says "SKILL Gate 2 no longer names make-pr"           no  '.' grep -n 'make-pr' "$MC_SKILL_MD"
says "worker briefs let {STYLE_GUIDE} name a skill"   no  '.' grep -n 'follows `{STYLE_GUIDE}`\. Read it before writing' "$TEMPLATES"/*.md
says "create-pr reads PR_DESCRIPTION_SKILL"           yes '.' grep -nF '${PR_DESCRIPTION_SKILL:-}' "$CREATE_PR_MD"
says "create-pr reads WRITING_STYLE_SKILL"            yes '.' grep -nF '${WRITING_STYLE_SKILL:-}' "$CREATE_PR_MD"

# --- 6e. kickback reply publishing ---------------------------------------------------
# Prep-write 5 publishes through {REPLY_POST_WRAPPER} when the overlay names one, and
# /reply-comments runs the same flow by hand. The wrapper's exit codes are the routing
# contract, so the doc must name each one it routes on, and both readers must agree.
echo
echo "kickback reply publishing   (driver ↔ skill ↔ templates)"
echo "────────────────────────────────────────────────────────────────"
REPLY_SKILL_MD="$_MC_LIB/../../skills/reply-comments/SKILL.md"
pw5()    { awk '/^### Prep-write 5 /{f=1} f&&/^### Prep-write 6 /{exit} f' "$DRIVER"; }
pw5_flat() { pw5 | tr '\n' ' '; }
arming() { pw5 | awk '/^\*\*Arming checklist\*\*/{f=1} f'; }
says "driver requires {REPLY_POST_WRAPPER} from the overlay" yes '\{REPLY_POST_WRAPPER\}' driver_fills
says "Prep-write 5 publishes through {REPLY_POST_WRAPPER}"   yes '\{REPLY_POST_WRAPPER\}' pw5
says "  … exit 10 falls back to drafts"           yes 'exit 10.*draft'                  pw5
says "  … exit 20 is a normal skip"               yes 'exit 20.*skip'                   pw5
says "  … exit 30 goes to the operator"           yes 'exit 30.*NEEDS YOU'              pw5
says "  … tags each reply fix, answer or decline" yes '[-]-category fix\|answer\|decline' pw5
says "  … answers and declines land in the report" yes 'answer and.*decline.*MC_AUTO_POST_REPORT|MC_AUTO_POST_REPORT.*answer and.*decline' pw5_flat
says "  … question counts both for spot-check"    yes 'auto-answered, <d> auto-declined \(spot-check\)' pw5
says "arming checklist names the reply-post wrapper" yes 'reply-post wrapper'           arming
says "  … and mc coder on"                        yes 'mc coder on'                     arming
says "  … and mc address on"                      yes 'mc address on'                   arming
says "SKILL fills list names {REPLY_POST_WRAPPER}" yes '.' grep -nE 'filled from the overlay.*\{REPLY_POST_WRAPPER\}|\{REPLY_POST_WRAPPER\}.*filled from the overlay' "$MC_SKILL_MD"
say_both_coders() { grep -c '(k) `replies`' "$TEMPLATES"/coder-rails.md "$TEMPLATES"/coder-typescript.md; }
says "both coder templates return (k) replies"    no  ':0$'                             say_both_coders
says "reply-comments skill has frontmatter"       yes '^name: reply-comments$'          cat "$REPLY_SKILL_MD"
says "  … reads REPLY_POST_WRAPPER"               yes 'REPLY_POST_WRAPPER:-\}' cat "$REPLY_SKILL_MD"
says "  … shares the decline report path"         yes 'MC_AUTO_POST_REPORT:-' cat "$REPLY_SKILL_MD"
says "  … routes exit 10, 20 and 30"              yes 'exit 10.*exit 20.*exit 30' bash -c 'tr "\n" " " < "$0"' "$REPLY_SKILL_MD"
says "  … has no positional placeholders"         no  '\$[0-9]|\$\{[0-9]|\$ARGUMENTS\[' cat "$REPLY_SKILL_MD"

# --- 7. cycle-less degrade (consequence A) ------------------------------------------
echo
echo "cycle-less tracker degrade   (capabilities without \`cycles\`)"
echo "────────────────────────────────────────────────────────────────"
printf 'vetting\n' > "$WORK/tracker/capabilities"
# NB: address the adapter SCRIPT here, not the `tracker` dispatch function — a shell
# function does not survive into the `bash -c` these assertions need, and a "command not
# found" would make every "→ empty" check pass on no output. Naming the impl is honest in
# a test whose whole subject is that impl's degrade behavior.
TR="$_MC_LIB/adapters/tracker/fixture.sh"
run "active_cycle → empty"         0 bash -c 'test -z "$("$0" active_cycle)"' "$TR"
run "in_active_cycle → empty"      0 bash -c 'test -z "$("$0" in_active_cycle ENG-204)"' "$TR"
run "list_ready out → empty"       0 bash -c 'test -z "$("$0" list_ready "Ready for Dev" out vetted)"' "$TR"
run "list_ready in → all ready"    0 bash -c 'test -n "$("$0" list_ready "Ready for Dev" in)"' "$TR"
run "mc-promote no-ops"        0,1,3,4 "$_MC_LIB/mc-promote.sh"
run "mc-archive no auto-roll"    0,1,3 "$_MC_LIB/mc-archive.sh"
run "mc-inbound single-tier"       0,1 "$_MC_LIB/mc-inbound.sh"
printf 'cycles vetting\n' > "$WORK/tracker/capabilities"

# --- 8. the safety assertion --------------------------------------------------------
echo
echo "live board untouched"
echo "────────────────────────────────────────────────────────────────"
AFTER="$(_stamp)"
if [ "$BEFORE" = "$AFTER" ]; then
  grn "  PASS  all ${#LIVE_FILES[@]} live runtime files unchanged"; pass=$((pass+1))
else
  red "  FAIL  a live runtime file CHANGED during the fixture run:"
  diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") | sed 's/^/          /'
  fail=$((fail+1))
fi

echo
if [ "$fail" -eq 0 ]; then grn "$pass passed, 0 failed"; else red "$pass passed, $fail FAILED"; fi
dim "fixtures were copied to a temp dir and discarded; the repo copy is untouched."
[ "$fail" -eq 0 ] || exit 1
