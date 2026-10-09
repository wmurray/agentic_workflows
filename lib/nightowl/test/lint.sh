#!/usr/bin/env bash
# lint.sh: no-network, no-herdr checks for lib/nightowl. The runner and `gh` are stubs on
# PATH that log every call; git runs for real against a throwaway repo whose origin is a
# local bare repo. Nothing here touches the real report dir, work log or board.
#   ./lib/nightowl/test/lint.sh
set -uo pipefail
T="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NO="$T/nightowl.sh"
pass=0; fail=0
ok()  { printf '\033[32m  PASS  %s\033[0m\n' "$*"; pass=$((pass+1)); }
bad() { printf '\033[31m  FAIL  %s\033[0m\n' "$*"; fail=$((fail+1)); }
expect() { # label, expected-exit, cmd…
  local label="$1" want="$2"; shift 2
  local out rc; out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" = "$want" ]; then ok "$label (exit $rc)"; else bad "$label: exit $rc, wanted $want: $(printf '%s' "$out" | tail -1)"; fi
}
says() { # label, regex, cmd…
  local label="$1" pat="$2"; shift 2
  local out; out="$("$@" 2>&1)"
  if printf '%s' "$out" | grep -qE -- "$pat"; then ok "$label"; else bad "$label: no match for /$pat/ in: $(printf '%s' "$out" | tail -1)"; fi
}
lacks() { # label, regex, cmd…
  local label="$1" pat="$2"; shift 2
  local out; out="$("$@" 2>&1)"
  if printf '%s' "$out" | grep -qE -- "$pat"; then bad "$label: unexpected /$pat/: $(printf '%s' "$out" | grep -E -- "$pat" | head -1)"; else ok "$label"; fi
}

FX="$(mktemp -d "${TMPDIR:-/tmp}/nightowl-lint.XXXXXX")"
FX="$(cd "$FX" && pwd -P)"
trap 'rm -rf "${FX:?}"' EXIT
mkdir -p "$FX/bin" "$FX/report" "$FX/worklog" "$FX/notes"

# Isolate from any real config. Environment values win over the env file.
export NIGHTOWL_ENV=/dev/null FX
export NIGHTOWL_REPORT_DIR="$FX/report" MC_WORKLOG_DIR="$FX/worklog" NIGHTOWL_NOTES_DIR=""
export NIGHTOWL_RUNNER="$FX/bin/runner" NIGHTOWL_WORKSPACE="night" NIGHTOWL_MODEL=""
export NIGHTOWL_BRANCH_PREFIXES="nightowl/, me/" NIGHTOWL_DENY_EXTRA="curl, Bash(dogcli *)"
export NIGHTOWL_DENY_DEPLOY="shipit" NIGHTOWL_ALLOW_EXTRA="Bash(make test*)"
export NIGHTOWL_WORKTREE_CMD="" MC_HOME="$FX/mc-home"
unset MC_WORKLOG NIGHTOWL_DATE NIGHTOWL_TASK
D=2026-01-02

# The runner stub: spawn prints a handle and logs argv (one arg per line); status reads
# $FX/runner-status (default running); teardown logs.
cat > "$FX/bin/runner" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FX/runner-calls"
case "$1" in
  spawn) printf '%s\n' "$@" > "$FX/spawn-$3.args"; echo "ws=${MC_HERDR_WORKSPACE:-}" >> "$FX/spawn-$3.args"
         [ -e "$FX/runner-fail" ] && { echo "stub: spawn failed" >&2; exit 1; }
         printf '%s|ws:t|ws:p|%s\n' "nightowl-$3" "$6" ;;
  status) cat "$FX/runner-status" 2>/dev/null || echo running ;;
  teardown) ;;
  *) echo "stub runner: unexpected $*" >&2; exit 1 ;;
esac
STUB
# The gh stub: logs argv, answers pr view from $FX/pr-exists, POSTs log their input.
cat > "$FX/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FX/gh-calls"
case "$1 $2" in
  "pr view") [ -e "$FX/pr-exists" ] && { echo "https://github.example/o/r/pull/10"; exit 0; }; echo "no pull requests found" >&2; exit 1 ;;
  "pr create") echo "https://github.example/o/r/pull/10" ;;
  "api user") echo '{"login":"me"}' ;;
  api*)
    for a in "$@"; do [ "$prev" = --input ] && cp "$a" "$FX/posted"; prev="$a"; done
    echo '{"id":77,"state":"PENDING","html_url":"https://github.example/o/r/pull/7#pullrequestreview-77"}' ;;
  *) echo "stub gh: unexpected $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$FX/bin/runner" "$FX/bin/gh"
export PATH="$FX/bin:$PATH"

# A repo with a local bare origin, so worktree add and push run for real, offline.
git init -q --bare "$FX/origin.git"
git init -q -b main "$FX/repo"
git -C "$FX/repo" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
git -C "$FX/repo" remote add origin "$FX/origin.git"
git -C "$FX/repo" push -q origin main
git -C "$FX/repo" fetch -q origin
git -C "$FX/repo" branch -q someone-else/feature
git -C "$FX/repo" push -q origin someone-else/feature

task() { # task <id> <kind> [jq overrides]
  jq -n --arg id "$1" --arg kind "$2" --arg repo "$FX/repo" --arg wt "$FX/wt-$1" "{id:\$id, kind:\$kind, title:(\"t \" + \$id), repo:\$repo, worktree:\$wt, base:\"origin/main\", brief:(\"Do the \" + \$kind + \" task.\")} ${3:-}"
}
tasks() { jq -s . > "$FX/tasks.json"; echo "$FX/tasks.json"; }
M="$FX/report/$D.manifest.json"

echo "parse + usage"
for f in "$T"/*.sh "$T"/test/*.sh; do bash -n "$f" && ok "$(basename "$f") parses" || bad "$(basename "$f") syntax"; done
jq -e . "$T/settings.template.json" >/dev/null && ok "settings.template.json is JSON" || bad "settings.template.json is not JSON"
expect "no op is usage"            2 "$NO"
expect "unknown op is usage"       2 "$NO" frob
expect "confirm needs a file"      2 "$NO" confirm --date "$D"
expect "an empty list is refused"  3 "$NO" confirm --date "$D" "$(printf '' | tasks)"
expect "bad date is usage"         2 "$NO" status --date 2026-1-2

echo "confirm: the human-gated task list"
expect "bad kind refused"          3 "$NO" confirm --date "$D" "$(task a deploy | tasks)"
expect "bad id refused"            3 "$NO" confirm --date "$D" "$(task 'A B' plan | tasks)"
expect "missing brief refused"     3 "$NO" confirm --date "$D" "$(task a plan '| del(.brief)' | tasks)"
expect "repo not git refused"      3 "$NO" confirm --date "$D" "$(task a plan "| .repo=\"$FX/notes\"" | tasks)"
expect "push on review refused"    3 "$NO" confirm --date "$D" "$(task a review '| .push=true | .branch="nightowl/x" | .pr="o/r#7"' | tasks)"
expect "push on plan refused"      3 "$NO" confirm --date "$D" "$(task a plan '| .push=true | .branch="nightowl/x"' | tasks)"
expect "push to a foreign branch"  3 "$NO" confirm --date "$D" "$(task a draft-pr '| .push=true | .branch="someone-else/feature"' | tasks)"
expect "review needs a pr"         3 "$NO" confirm --date "$D" "$(task a review | tasks)"
expect "worktree = main checkout"  3 "$NO" confirm --date "$D" "$(task a plan "| .worktree=\"$FX/repo\"" | tasks)"
expect "duplicate ids refused"     3 "$NO" confirm --date "$D" "$( (task a plan; task a repro) | tasks)"
expect "shared worktree refused"   3 "$NO" confirm --date "$D" "$( (task a plan; task b repro "| .worktree=\"$FX/wt-a\"") | tasks)"
expect "over the task cap"         3 env NIGHTOWL_MAX_TASKS=1 "$NO" confirm --date "$D" "$( (task a plan; task b repro) | tasks)"
[ ! -e "$M" ] && ok "a refused list writes no manifest" || bad "a refused list wrote $M"

TL="$( (task pr1 draft-pr '| .push=true | .branch="nightowl/pr1" | .ticket="ABC-1"'
        task rev1 review '| .branch="someone-else/feature" | .pr="o/r#7"'
        task res1 research) | tasks)"
expect "a valid list is confirmed" 0 "$NO" confirm --date "$D" "$TL"
says "manifest holds three tasks"  '^3$' jq '.tasks | length' "$M"
says "every task starts confirmed" '^confirmed$' jq -r '[.tasks[].status] | unique | .[]' "$M"
says "report file has a header"    "^# Nightowl $D" cat "$FX/report/$D.md"
expect "re-confirming an id refused" 3 "$NO" confirm --date "$D" "$(task pr1 plan | tasks)"

echo "settings: the per-pane permission profile"
S="$("$NO" settings --date "$D" pr1)"
printf '%s' "$S" | jq -e . >/dev/null && ok "settings is JSON" || bad "settings is not JSON"
for rule in 'Bash(op *)' 'Bash(sentry-cli *)' 'Bash(kubectl *)' 'Bash(aws *)' 'Bash(gh pr merge*)' \
            'Bash(gh pr ready*)' 'Bash(git push*)' 'Bash(curl *)' 'Bash(dogcli *)' 'Bash(shipit *)' \
            'Bash(*merge.sh*)'; do
  says "denies $rule" "$(printf '%s' "$rule" | sed 's/[][()*.]/\\&/g')" jq -r '.permissions.deny[]' <<<"$S"
done
says "no OS sandbox"               '^false$' jq '.sandbox.enabled' <<<"$S"
says "unattended mode is dontAsk"  '^dontAsk$' jq -r '.permissions.defaultMode' <<<"$S"
says "edits scoped to the worktree" "^Edit\(/$FX/wt-pr1/\*\*\)$" jq -r '.permissions.allow[]' <<<"$S"
says "mc home writes denied"       "^Edit\(/$FX/mc-home/\*\*\)$" jq -r '.permissions.deny[]' <<<"$S"
says "push wrapper allowed"        "nightowl\.sh push" jq -r '.permissions.allow[]' <<<"$S"
says "draft-pr wrapper allowed"    "nightowl\.sh draft-pr" jq -r '.permissions.allow[]' <<<"$S"
says "allow extra applied"         '^Bash\(make test\*\)$' jq -r '.permissions.allow[]' <<<"$S"
says "task env carries date + id"  "^$D pr1$" jq -r '"\(.env.NIGHTOWL_DATE) \(.env.NIGHTOWL_TASK)"' <<<"$S"
lacks "no placeholder left"        '\{\{' printf '%s' "$S"
lacks "no private key left"        '_nightowl' printf '%s' "$S"
R="$("$NO" settings --date "$D" rev1)"
lacks "review cannot push"         'nightowl\.sh (push|draft-pr)' jq -r '.permissions.allow[]' <<<"$R"
says "review may preload pending"  'nightowl\.sh pending-review' jq -r '.permissions.allow[]' <<<"$R"
says "review may use review-post"  'review-post\.sh' jq -r '.permissions.allow[]' <<<"$R"
X="$("$NO" settings --date "$D" res1)"
lacks "research without notes dir" "$FX/notes" printf '%s' "$X"
says "research may search the web" '^WebSearch$' jq -r '.permissions.allow[]' <<<"$X"
X="$(NIGHTOWL_NOTES_DIR="$FX/notes" "$NO" settings --date "$D" res1)"
says "research writes the notes dir" "^Write\(/$FX/notes/\*\*\)$" jq -r '.permissions.allow[]' <<<"$X"
lacks "notes dir only for research" "$FX/notes" env NIGHTOWL_NOTES_DIR="$FX/notes" "$NO" settings --date "$D" pr1
expect "settings for unknown task" 3 "$NO" settings --date "$D" nope

echo "launch: worktree + pane per task"
expect "launch runs"               0 "$NO" launch --date "$D"
[ -d "$FX/wt-pr1" ] && ok "draft-pr worktree created" || bad "no worktree for pr1"
says "draft-pr worktree on its branch" '^nightowl/pr1$' git -C "$FX/wt-pr1" rev-parse --abbrev-ref HEAD
says "review worktree is detached"     '^HEAD$' git -C "$FX/wt-rev1" rev-parse --abbrev-ref HEAD
says "spawned in its own worktree"     "^$FX/wt-pr1$" sed -n 4p "$FX/spawn-pr1.args"
says "spawned with --settings"         '^--settings$' cat "$FX/spawn-pr1.args"
says "spawned into the night workspace" '^ws=night$' cat "$FX/spawn-pr1.args"
SF="$(grep -A1 '^--settings$' "$FX/spawn-pr1.args" | tail -1)"
says "settings file is the profile"    'Bash\(op \*\)' cat "$SF"
BF="$(sed -n 5p "$FX/spawn-pr1.args")"
says "brief carries the task"          'Do the draft-pr task' cat "$BF"
says "brief names the finish command"  "nightowl\.sh finish --date $D pr1" cat "$BF"
says "brief states the stance"         '[Nn]ever merge' cat "$BF"
says "every task is running"           '^running$' jq -r '[.tasks[].status] | unique | .[]' "$M"
says "handle recorded"                 '^nightowl-pr1\|' jq -r '.tasks[] | select(.id=="pr1") | .handle' "$M"
: > "$FX/runner-calls"
expect "relaunch is a no-op"           0 "$NO" launch --date "$D"
[ ! -s "$FX/runner-calls" ] && ok "running tasks are not respawned" || bad "relaunch spawned: $(cat "$FX/runner-calls")"
expect "worker cannot launch"          5 env NIGHTOWL_TASK=pr1 "$NO" launch --date "$D"

echo "launch failure is recorded, not fatal"
"$NO" confirm --date "$D" "$(task bad1 plan | tasks)" >/dev/null 2>&1
touch "$FX/runner-fail"
expect "launch reports a failed spawn" 1 "$NO" launch --date "$D" bad1
rm -f "$FX/runner-fail"
says "failed spawn marked"             '^launch-failed$' jq -r '.tasks[] | select(.id=="bad1") | .status' "$M"

echo "push / draft-pr / pending-review wrappers"
git -C "$FX/wt-pr1" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m work
expect "push own branch"               0 "$NO" push --date "$D" pr1
says "branch reached origin"           'nightowl/pr1' git -C "$FX/origin.git" branch --list 'nightowl/pr1'
expect "review task cannot push"       4 "$NO" push --date "$D" rev1
git -C "$FX/wt-pr1" checkout -q -b nightowl/other
expect "push refuses a switched branch" 4 "$NO" push --date "$D" pr1
git -C "$FX/wt-pr1" checkout -q nightowl/pr1
printf 'body\n' > "$FX/body.md"
expect "draft-pr opens a draft"        0 "$NO" draft-pr --date "$D" pr1 --title "ABC-1 thing" --body-file "$FX/body.md"
says "gh pr create got --draft"        '^pr create .*--draft' cat "$FX/gh-calls"
says "draft pr recorded"               'pull/10' jq -r '.tasks[] | select(.id=="pr1") | .pr_url' "$M"
touch "$FX/pr-exists"; : > "$FX/gh-calls"
expect "draft-pr is idempotent"        0 "$NO" draft-pr --date "$D" pr1 --title x --body-file "$FX/body.md"
lacks "no second pr create"            'pr create' cat "$FX/gh-calls"
rm -f "$FX/pr-exists"
expect "review task cannot open a pr"  4 "$NO" draft-pr --date "$D" rev1 --title x --body-file "$FX/body.md"
printf '{"body":"s","comments":[{"path":"a","line":1,"body":"nit: x"}]}' > "$FX/review.json"
expect "pending review preloads"       0 "$NO" pending-review --date "$D" rev1 "$FX/review.json"
says "posted to the task's pr"         '^api .*repos/o/r/pulls/7/reviews' cat "$FX/gh-calls"
lacks "posted payload has no event"    '"event"' cat "$FX/posted"
printf '{"event":"APPROVE","body":"s"}' > "$FX/approve.json"
expect "an event is refused"           4 "$NO" pending-review --date "$D" rev1 "$FX/approve.json"
expect "pending review needs a pr"     4 "$NO" pending-review --date "$D" pr1 "$FX/review.json"

echo "finish: report + work log"
expect "finish needs a result file"    3 "$NO" finish --date "$D" res1
mkdir -p "$FX/report/$D/pr1"
printf '{"status":"done","summary":"opened a draft","details":["tests green"]}' > "$FX/report/$D/pr1/result.json"
expect "finish records the result"     0 "$NO" finish --date "$D" pr1
says "status from the result"          '^done$' jq -r '.tasks[] | select(.id=="pr1") | .status' "$M"
says "report has the task section"     '^## pr1 · draft-pr · done' cat "$FX/report/$D.md"
says "report has the pr link"          'pull/10' cat "$FX/report/$D.md"
says "work log line written"           'nightowl pr1 \(draft-pr\) done: opened a draft' cat "$FX/worklog/"*.jsonl
says "work log carries the ticket"     '"ticket":"ABC-1"' cat "$FX/worklog/"*.jsonl
says "work log source is nightowl"     '"source":"nightowl"' cat "$FX/worklog/"*.jsonl
N1="$(grep -c '^## pr1' "$FX/report/$D.md")"
"$NO" finish --date "$D" pr1 >/dev/null 2>&1
[ "$(grep -c '^## pr1' "$FX/report/$D.md")" = "$N1" ] && ok "finish is idempotent" || bad "finish appended twice"
printf '{"status":"shipped","summary":"x"}' > "$FX/report/$D/pr1/result.json"
mkdir -p "$FX/report/$D/res1"; printf '{"status":"shipped","summary":"x"}' > "$FX/report/$D/res1/result.json"
expect "unknown result status refused" 3 "$NO" finish --date "$D" res1
rm -f "$FX/report/$D/res1/result.json"

echo "morning: summarize for the orchestrator"
echo gone > "$FX/runner-status"
says "morning lists every task"        'pr1.*done' "$NO" morning --date "$D"
says "a gone pane without result is stalled" '^stalled$' jq -r '.tasks[] | select(.id=="res1") | .status' "$M"
says "stalled task in the report"      '^## res1 · research · stalled' cat "$FX/report/$D.md"
says "stalled task in the work log"    'nightowl res1 \(research\) stalled' cat "$FX/worklog/"*.jsonl
mkdir -p "$FX/report/$D/rev1"
printf '{"status":"done","summary":"3 pending comments"}' > "$FX/report/$D/rev1/result.json"
"$NO" morning --date "$D" >/dev/null 2>&1
says "morning finishes an unreported result" '^done$' jq -r '.tasks[] | select(.id=="rev1") | .status' "$M"
says "morning defaults to the latest night" 'rev1' "$NO" morning
says "morning --json is the task list" '^4$' sh -c "'$NO' morning --date $D --json | jq length"
: > "$FX/runner-calls"
expect "morning --teardown"            0 "$NO" morning --date "$D" --teardown
says "teardown closed finished panes"  '^teardown nightowl-pr1' cat "$FX/runner-calls"
lacks "teardown skips unlaunched"      'teardown .*bad1' cat "$FX/runner-calls"

echo "mission-control state untouched"
[ ! -e "$MC_HOME" ] && ok "nothing written under MC_HOME" || bad "MC_HOME was written: $(ls -R "$MC_HOME")"

echo
if [ "$fail" -eq 0 ]; then printf '\033[32m%s passed, 0 failed\033[0m\n' "$pass"; else printf '\033[31m%s passed, %s FAILED\033[0m\n' "$pass" "$fail"; fi
[ "$fail" -eq 0 ]
