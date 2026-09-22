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
red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
dim()  { printf '\033[2m%s\033[0m\n' "$*"; }

# --- 1. stamp the live runtime files, so any write to them is detectable -------------
# Format: "<path>\t<sha or ABSENT>". A file the engine must never touch during a
# fixture run is listed here; ABSENT files must stay absent.
LIVE_FILES=(
  "$LIVE/state.json" "$LIVE/state.archive.json" "$LIVE/.writer-lock"
  "$LIVE/.last-archived-sprint" "$LIVE/.loop-heartbeat" "$LIVE/mc-inbox"
  "$LIVE/PAUSED" "$LIVE/CODER_SPAWN_LIVE"
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
run  "runner herdr capabilities"       0 "$_MC_LIB/adapters/runner/herdr.sh" capabilities
# herdr is an OPTIONAL runner: the engine defaults every role to inprocess and only this
# adapter needs the CLI. Its live-ish ops are exercised only where the CLI exists.
if command -v herdr >/dev/null 2>&1; then
  says "herdr status gone for unknown"   yes '^gone$'    "$_MC_LIB/adapters/runner/herdr.sh" status 'nosuch|x|y|'
  run  "herdr spawn refuses w/o workspace" 1 env -u MC_HERDR_WS_SPRINT -u MC_HERDR_WORKSPACE "$_MC_LIB/adapters/runner/herdr.sh" spawn coder ENG-902 "$WORK" "$WORK/runner/brief.md" "$WORK/runner/x.json"
else
  dim "  SKIP  herdr CLI not installed — status/spawn assertions skipped (capabilities still checked)"
fi

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
printf 'ENG-999 a scratch inbox line\n' > "$WORK/mc-inbox"
run "mc-inbox-drain"             0,1,2 "$_MC_LIB/mc-inbox-drain.sh" ENG-999

# --- 6. dash renders the fixture board ----------------------------------------------
frame="$(MC_INTERVAL=99 timeout 8 "$_MC_LIB/dash.sh" 2>&1)"
if printf '%s' "$frame" | grep -q 'MISSION CONTROL'; then
  grn "  PASS  dash renders ($(printf '%s' "$frame" | wc -l | tr -d ' ') lines)"; pass=$((pass+1))
  [ -n "$VERBOSE" ] && printf '%s\n' "$frame" | sed 's/^/          /'
else
  red "  FAIL  dash produced no frame"; printf '%s\n' "$frame" | sed 's/^/          /'; fail=$((fail+1))
fi

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
