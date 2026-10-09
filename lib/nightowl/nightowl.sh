#!/usr/bin/env bash
# nightowl.sh: the mechanical half of /nightowl. Hands confirmed long-running tasks to
# background panes for the night, one worktree and one permission profile per task, and
# gathers what they did in the morning. The skill proposes and the maintainer confirms;
# this script only acts on a confirmed list.
#
# Orchestrator ops (refused inside a task pane, where NIGHTOWL_TASK is set):
#   confirm  [--date D] <tasks.json>    validate a confirmed task list into the night's manifest
#   launch   [--date D] [id…]           worktree + settings + brief + pane per confirmed task
#   morning  [--date D] [--json] [--teardown]   reconcile panes, report, summarize
#   status   [--date D]                 read-only table of the night's tasks
#   settings [--date D] <id>            print the task's permission profile
#   path     [--date D]                 the night's report file
#
# Task ops (what a pane's profile allows it to run, for its own id only):
#   finish         --date D <id>                         record result.json: report + work log
#   push           --date D <id>                         push the task's own branch, no force
#   draft-pr       --date D <id> --title T --body-file F open a DRAFT PR for that branch
#   pending-review --date D <id> <payload.json>          preload a PENDING review on the task's PR
#
# Files: $NIGHTOWL_REPORT_DIR/<date>.manifest.json   the night's tasks, handles, status
#        $NIGHTOWL_REPORT_DIR/<date>.md              the report the journal tooling reads
#        $NIGHTOWL_REPORT_DIR/<date>/<id>/           settings.json, brief.md, result.json
# Nothing here writes the mission-control board.
#
# Exit: 0 ok · 1 a call failed · 2 usage · 3 invalid task or result · 4 guard refused ·
#       5 orchestrator op run from inside a task pane
set -uo pipefail

_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do
  _t="$(readlink "$_src")"
  case "$_t" in /*) _src="$_t" ;; *) _src="$(dirname "$_src")/$_t" ;; esac
done
NO_DIR="$(cd "$(dirname "$_src")" && pwd -P)"
NO_SELF="$NO_DIR/nightowl.sh"
unset _src _t

# --- config: $NIGHTOWL_ENV, else nightowl.env next to this file; environment wins -------
NO_VARS="NIGHTOWL_REPORT_DIR NIGHTOWL_NOTES_DIR NIGHTOWL_DENY_EXTRA NIGHTOWL_DENY_DEPLOY NIGHTOWL_ALLOW_EXTRA NIGHTOWL_RESEARCH_ALLOW
NIGHTOWL_BRANCH_PREFIXES NIGHTOWL_PERMISSION_MODE NIGHTOWL_RUNNER NIGHTOWL_WORKSPACE NIGHTOWL_MODEL
NIGHTOWL_WORKLOG NIGHTOWL_REVIEW_TOOLKIT NIGHTOWL_MAX_TASKS NIGHTOWL_WORKTREE_CMD"
_saved=""
for _v in $NO_VARS; do [ -n "${!_v+set}" ] && _saved="$_saved$_v=$(printf '%q' "${!_v}");"; done
_envf="${NIGHTOWL_ENV:-$NO_DIR/nightowl.env}"
# shellcheck disable=SC1090
[ -f "$_envf" ] && . "$_envf"
eval "$_saved"; unset _saved _v _envf

REPORT_DIR="${NIGHTOWL_REPORT_DIR:-$HOME/.claude/nightowl}"
NOTES_DIR="${NIGHTOWL_NOTES_DIR:-}"
DENY_EXTRA="${NIGHTOWL_DENY_EXTRA:-curl, wget}"
DENY_DEPLOY="${NIGHTOWL_DENY_DEPLOY:-terraform, pulumi, heroku, flyctl, vercel, netlify, gcloud, az}"
ALLOW_EXTRA="${NIGHTOWL_ALLOW_EXTRA:-}"
RESEARCH_ALLOW="${NIGHTOWL_RESEARCH_ALLOW:-}"
BRANCH_PREFIXES="${NIGHTOWL_BRANCH_PREFIXES:-nightowl/}"
MODE="${NIGHTOWL_PERMISSION_MODE:-dontAsk}"
RUNNER="${NIGHTOWL_RUNNER:-$NO_DIR/../mission-control/adapters/runner/herdr.sh}"
WORKSPACE="${NIGHTOWL_WORKSPACE:-${MC_HERDR_WS_BACKGROUND:-}}"
MODEL="${NIGHTOWL_MODEL:-}"
WORKLOG="${NIGHTOWL_WORKLOG:-$NO_DIR/../mission-control/worklog.sh}"
REVIEW_TOOLKIT="${NIGHTOWL_REVIEW_TOOLKIT:-$NO_DIR/../review-toolkit}"
MAX_TASKS="${NIGHTOWL_MAX_TASKS:-4}"
WORKTREE_CMD="${NIGHTOWL_WORKTREE_CMD:-}"
MC_HOME_DIR="${MC_HOME:-$HOME/.claude/mission-control}"
TEMPLATE="$NO_DIR/settings.template.json"
KINDS="plan repro draft-pr review flake research"
PUSH_KINDS="draft-pr flake"
TERMINAL="done partial blocked failed"

die()    { echo "nightowl: $2" >&2; exit "$1"; }
usage()  { die 2 "$1 (see the header of $NO_SELF)"; }
_abs()   { (cd "$1" 2>/dev/null && pwd -P); }
_in()    { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }
_list()  { printf '%s' "$1" | tr ',\n' '\n\n' | sed 's/^ *//; s/ *$//' | awk 'NF'; }

# --- argument parsing shared by every op -----------------------------------------------
DATE=""; JSON=""; TEARDOWN=""; TITLE=""; BODY_FILE=""; ARGS=()
op="${1:-}"; [ $# -gt 0 ] && shift
[ -n "$op" ] || usage "no op given"
while [ $# -gt 0 ]; do
  case "$1" in
    --date) DATE="${2:-}"; shift ;;
    --json) JSON=1 ;;
    --teardown) TEARDOWN=1 ;;
    --title) TITLE="${2:-}"; shift ;;
    --body-file) BODY_FILE="${2:-}"; shift ;;
    -*) usage "unknown flag $1" ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done
[ -z "$DATE" ] || [[ "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || usage "--date must be YYYY-MM-DD"

latest_date() {
  ls "$REPORT_DIR"/*.manifest.json 2>/dev/null | sed 's#.*/##; s#\.manifest\.json$##' | sort | tail -1
}
manifest() { printf '%s/%s.manifest.json' "$REPORT_DIR" "$DATE"; }
report()   { printf '%s/%s.md' "$REPORT_DIR" "$DATE"; }
task_dir() { printf '%s/%s/%s' "$REPORT_DIR" "$DATE" "$1"; }

# Orchestrator ops must not run from a pane: a worker never launches more workers.
orchestrator_only() { [ -z "${NIGHTOWL_TASK:-}" ] || die 5 "$op is an orchestrator op; refused inside task pane '${NIGHTOWL_TASK}'"; }
# Task ops act on their own id only when run from a pane.
own_task() { [ -z "${NIGHTOWL_TASK:-}" ] || [ "$NIGHTOWL_TASK" = "$1" ] || die 5 "pane '${NIGHTOWL_TASK}' cannot act for task '$1'"; }

# --- the manifest: one writer at a time, atomic replace --------------------------------
LOCK=""
lock() {
  LOCK="$(manifest).lock"; local i=0
  mkdir -p "$REPORT_DIR"
  until mkdir "$LOCK" 2>/dev/null; do
    i=$((i+1))
    # A lock older than a minute is from a killed process.
    if [ "$i" -gt 50 ] && [ -n "$(find "$LOCK" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rmdir "$LOCK" 2>/dev/null; fi
    [ "$i" -gt 300 ] && die 1 "manifest lock busy: $LOCK"
    sleep 0.1
  done
  trap 'rmdir "$LOCK" 2>/dev/null' EXIT
}
mput() { # mput <jq filter> [jq args…]: rewrite the manifest under the lock
  local f; f="$(manifest)"
  jq "$@" "$f" > "$f.tmp" && mv "$f.tmp" "$f" || die 1 "manifest write failed"
}
tget() { jq -r --arg id "$1" ".tasks[] | select(.id == \$id) | $2 // empty" "$(manifest)"; }
need_task() {
  [ -f "$(manifest)" ] || die 3 "no manifest for $DATE"
  [ -n "$(tget "$1" .id)" ] || die 3 "no task '$1' in the $DATE manifest"
}

# --- confirm ---------------------------------------------------------------------------
validate() { # validate <task json> <other worktrees…>: prints an error and returns 1
  local t="$1" id kind repo wt branch push pr
  id="$(jq -r '.id // ""' <<<"$t")"; kind="$(jq -r '.kind // ""' <<<"$t")"
  repo="$(jq -r '.repo // ""' <<<"$t")"; wt="$(jq -r '.worktree // ""' <<<"$t")"
  branch="$(jq -r '.branch // ""' <<<"$t")"; push="$(jq -r '.push // false' <<<"$t")"
  pr="$(jq -r '.pr // ""' <<<"$t")"
  [[ "$id" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]] || { echo "id '$id' must be lowercase letters, digits and dashes"; return 1; }
  _in "$kind" "$KINDS" || { echo "$id: kind '$kind' is not one of: $KINDS"; return 1; }
  [ -n "$(jq -r '.brief // ""' <<<"$t")" ] || { echo "$id: no brief"; return 1; }
  [ -n "$(jq -r '.title // ""' <<<"$t")" ] || { echo "$id: no title"; return 1; }
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { echo "$id: repo '$repo' is not a git checkout"; return 1; }
  if [ "$push" = true ]; then
    _in "$kind" "$PUSH_KINDS" || { echo "$id: a $kind task never pushes (push is for: $PUSH_KINDS)"; return 1; }
    [ -n "$branch" ] || { echo "$id: push needs a branch"; return 1; }
    local p okp=""
    while IFS= read -r p; do case "$branch" in "$p"*) okp=1 ;; esac; done < <(_list "$BRANCH_PREFIXES")
    [ -n "$okp" ] || { echo "$id: branch '$branch' is not yours to push (NIGHTOWL_BRANCH_PREFIXES: $BRANCH_PREFIXES)"; return 1; }
  fi
  if [ "$kind" = review ]; then
    [[ "$pr" =~ ^[^/#]+/[^/#]+#[0-9]+$ ]] || { echo "$id: a review task needs pr as owner/repo#N"; return 1; }
  fi
  local rabs; rabs="$(_abs "$repo")"
  [ "$wt" != "$repo" ] && [ "$wt" != "$rabs" ] || { echo "$id: the worktree cannot be the checkout itself"; return 1; }
  if [ -d "$wt" ]; then
    [ "$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)" != "$(cd "$wt" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ] \
      || { echo "$id: '$wt' is a main checkout, not a linked worktree"; return 1; }
  fi
  return 0
}

op_confirm() {
  orchestrator_only
  [ "${#ARGS[@]}" -eq 1 ] && [ -f "${ARGS[0]}" ] || usage "confirm needs one tasks.json file"
  DATE="${DATE:-$(date +%Y-%m-%d)}"
  local in; in="$(jq -c 'if type == "array" then . else [.] end' "${ARGS[0]}" 2>/dev/null)" || die 3 "tasks file is not JSON"
  # Fill the default worktree path: a sibling of the repo, named for the task.
  [ "$(jq 'length' <<<"$in")" -gt 0 ] || die 3 "the task list is empty"
  in="$(jq -c 'map(.worktree = (.worktree // ((.repo | sub("/+$"; "")) + "-nightowl-" + .id)) | .push = (.push // false))' <<<"$in")"
  local existing='[]'; [ -f "$(manifest)" ] && existing="$(jq -c '.tasks' "$(manifest)")"
  local all; all="$(jq -c --argjson a "$existing" '$a + .' <<<"$in")"
  [ "$(jq 'length' <<<"$all")" -le "$MAX_TASKS" ] || die 3 "more than NIGHTOWL_MAX_TASKS=$MAX_TASKS tasks for $DATE"
  [ "$(jq '[.[].id] | length' <<<"$all")" = "$(jq '[.[].id] | unique | length' <<<"$all")" ] || die 3 "duplicate task ids"
  [ "$(jq '[.[].worktree] | length' <<<"$all")" = "$(jq '[.[].worktree] | unique | length' <<<"$all")" ] || die 3 "two tasks share a worktree"
  local t err
  while IFS= read -r t; do
    err="$(validate "$t")" || die 3 "$err"
  done < <(jq -c '.[]' <<<"$in")
  lock
  if [ ! -f "$(manifest)" ]; then
    jq -n --arg d "$DATE" '{date: $d, tasks: []}' > "$(manifest)"
    printf '# Nightowl %s\n\nTasks handed to background panes overnight. One section per task is appended as it finishes.\n' "$DATE" > "$(report)"
  fi
  mput --argjson new "$in" --arg now "$(date +%Y-%m-%dT%H:%M:%S%z)" \
    '.tasks += ($new | map(. + {status: "confirmed", confirmed_at: $now}))'
  jq -r '.[] | "confirmed \(.id) (\(.kind)) \(.title)"' <<<"$in"
}

# --- settings --------------------------------------------------------------------------
render_settings() { # render_settings <id>: the filled profile on stdout
  local id="$1" kind wt branch deny_rules allow_rules notes=""
  kind="$(tget "$id" .kind)"; wt="$(tget "$id" .worktree)"; branch="$(tget "$id" .branch)"
  deny_rules="$( { _list "$DENY_EXTRA"; _list "$DENY_DEPLOY"; } | awk '{ if (index($0, "(")) print; else { print "Bash(" $0 " *)"; print "Bash(" $0 ")" } }' | jq -R . | jq -sc .)"
  allow_rules="$( { _list "$ALLOW_EXTRA"; [ "$kind" = research ] && _list "$RESEARCH_ALLOW"; } | jq -R . | jq -sc .)"
  [ -n "$NOTES_DIR" ] && notes="$(_abs "$NOTES_DIR" || printf '%s' "$NOTES_DIR")"
  jq --arg kind "$kind" --argjson deny "$deny_rules" --argjson allow "$allow_rules" --arg notes "$notes" \
     --arg WORKTREE "$wt" --arg TASK_DIR "$(task_dir "$id")" --arg NIGHTOWL "$NO_SELF" \
     --arg DATE "$DATE" --arg ID "$id" --arg BRANCH "$branch" --arg MC_HOME "$MC_HOME_DIR" \
     --arg NOTES_DIR "$notes" --arg REVIEW_TOOLKIT "$(_abs "$REVIEW_TOOLKIT" || printf '%s' "$REVIEW_TOOLKIT")" \
     --arg LIB "$NO_DIR" --arg REPORT_DIR "$REPORT_DIR" --arg MODE "$MODE" '
    def fill: reduce ([["WORKTREE",$WORKTREE],["TASK_DIR",$TASK_DIR],["NIGHTOWL",$NIGHTOWL],["DATE",$DATE],
                       ["ID",$ID],["BRANCH",$BRANCH],["MC_HOME",$MC_HOME],["NOTES_DIR",$NOTES_DIR],
                       ["REVIEW_TOOLKIT",$REVIEW_TOOLKIT],["LIB",$LIB],["REPORT_DIR",$REPORT_DIR],["MODE",$MODE]][])
                as $p (.; split("{{" + $p[0] + "}}") | join($p[1]));
    . as $t
    | .permissions.allow += (($t._nightowl_kinds[$kind].allow // []) + $allow)
    | .permissions.deny += $deny
    | if $notes != "" and ($t._nightowl_notes.kinds | index($kind)) then
        .permissions.allow += $t._nightowl_notes.allow
        | .permissions.additionalDirectories += $t._nightowl_notes.additionalDirectories
      else . end
    | with_entries(select(.key | startswith("_nightowl") | not))
    | walk(if type == "string" then fill else . end)
    | .permissions.allow |= unique | .permissions.deny |= unique
  ' "$TEMPLATE"
}

op_settings() {
  orchestrator_only
  [ "${#ARGS[@]}" -eq 1 ] || usage "settings needs one task id"
  DATE="${DATE:-$(latest_date)}"; need_task "${ARGS[0]}"
  render_settings "${ARGS[0]}"
}

# --- launch ----------------------------------------------------------------------------
make_worktree() { # make_worktree <id>
  local id="$1" repo wt branch base push kind
  repo="$(tget "$id" .repo)"; wt="$(tget "$id" .worktree)"; branch="$(tget "$id" .branch)"
  base="$(tget "$id" .base)"; push="$(tget "$id" .push)"; kind="$(tget "$id" .kind)"
  if [ -d "$wt" ]; then
    [ "$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)" != "$(cd "$wt" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ] \
      || { echo "$wt exists and is not a linked worktree"; return 1; }
    return 0
  fi
  if [ -n "$WORKTREE_CMD" ]; then
    NO_REPO="$repo" NO_WORKTREE="$wt" NO_BRANCH="$branch" NO_BASE="$base" NO_KIND="$kind" NO_PUSH="$push" \
      bash -c "$WORKTREE_CMD" >&2 || { echo "NIGHTOWL_WORKTREE_CMD failed"; return 1; }
    [ -d "$wt" ] || { echo "NIGHTOWL_WORKTREE_CMD did not create $wt"; return 1; }
    return 0
  fi
  git -C "$repo" fetch -q origin >/dev/null 2>&1 || true
  [ -n "$base" ] || base="$(git -C "$repo" rev-parse -q --verify origin/HEAD >/dev/null && echo origin/HEAD || echo HEAD)"
  local has_local="" has_remote=""
  [ -n "$branch" ] && git -C "$repo" rev-parse -q --verify "refs/heads/$branch" >/dev/null && has_local=1
  [ -n "$branch" ] && git -C "$repo" rev-parse -q --verify "refs/remotes/origin/$branch" >/dev/null && has_remote=1
  if [ "$push" = true ]; then
    if [ -n "$has_local" ]; then git -C "$repo" worktree add -q "$wt" "$branch"
    elif [ -n "$has_remote" ]; then git -C "$repo" worktree add -q --track -b "$branch" "$wt" "origin/$branch"
    else git -C "$repo" worktree add -q -b "$branch" "$wt" "$base"; fi
  else
    # A task that never pushes works detached, so it cannot move anyone's branch.
    if [ -n "$has_remote" ]; then git -C "$repo" worktree add -q --detach "$wt" "origin/$branch"
    elif [ -n "$has_local" ]; then git -C "$repo" worktree add -q --detach "$wt" "$branch"
    else git -C "$repo" worktree add -q --detach "$wt" "$base"; fi
  fi >&2 || { echo "git worktree add failed for $wt"; return 1; }
}

write_brief() { # write_brief <id> <file>
  local id="$1" kind; kind="$(tget "$id" .kind)"
  {
    printf '# Nightowl task %s (%s): %s\n\n' "$id" "$kind" "$(tget "$id" .title)"
    [ -n "$(tget "$id" .ticket)" ] && printf 'Ticket: %s\n' "$(tget "$id" .ticket)"
    [ -n "$(tget "$id" .pr)" ] && printf 'PR: %s\n' "$(tget "$id" .pr)"
    [ -n "$(tget "$id" .branch)" ] && printf 'Branch: %s\n' "$(tget "$id" .branch)"
    printf 'Worktree: %s\n\n' "$(tget "$id" .worktree)"
    tget "$id" .brief
    cat <<EOF


## How this night works

You are running unattended while the maintainer is away. Nobody will answer a question or
a permission prompt before morning, so a denied action means "not tonight": note it in your
result and carry on with what you can do.

- Work only inside your worktree. It is yours alone; other work in progress lives elsewhere.
- No production systems, no secrets, no deploys. Those commands are denied outright.
- Never merge, never mark a PR ready, never move or comment on a tracker ticket. The
  mission-control loop does that admin from the board and the work log.
- Never push to a branch the maintainer did not author.
EOF
    case "$kind" in
      draft-pr|flake) cat <<EOF
- Push only your own branch, and only with: $NO_SELF push --date $DATE $id
- Open at most one DRAFT PR, only with: $NO_SELF draft-pr --date $DATE $id --title "<title>" --body-file <file>
EOF
      ;;
      review) cat <<EOF
- Suggest only. Preload private PENDING review comments with:
  $NO_SELF pending-review --date $DATE $id <payload.json>
  where payload.json is {"body": "...", "comments": [{"path", "line", "side", "body"}]} with no "event".
EOF
      ;;
      research) [ -n "$NOTES_DIR" ] && printf -- '- Research notes may be written under %s.\n' "$NOTES_DIR" ;;
    esac
    cat <<EOF

## When you are done

Write $(task_dir "$id")/result.json:

  {"status": "done|partial|blocked|failed", "summary": "<one line>",
   "pr": "<url, if you opened or worked one>", "details": ["<what the maintainer should know>"]}

then run: $NO_SELF finish --date $DATE $id
That appends your section to the night's report and one line to the work log. Then stop.
EOF
  } > "$2"
}

op_launch() {
  orchestrator_only
  DATE="${DATE:-$(date +%Y-%m-%d)}"
  [ -f "$(manifest)" ] || die 3 "no manifest for $DATE; confirm a task list first"
  local ids=(${ARGS[@]+"${ARGS[@]}"})
  [ "${#ids[@]}" -gt 0 ] || ids=($(jq -r '.tasks[] | select(.status == "confirmed") | .id' "$(manifest)"))
  lock
  local id st td h err rc=0 model_args=()
  [ -n "$MODEL" ] && model_args=(--model "$MODEL")
  for id in ${ids[@]+"${ids[@]}"}; do
    need_task "$id"
    st="$(tget "$id" .status)"
    [ "$st" = confirmed ] || [ "$st" = launch-failed ] || { echo "skip $id ($st)"; continue; }
    td="$(task_dir "$id")"; mkdir -p "$td"
    if err="$(make_worktree "$id")" \
       && render_settings "$id" > "$td/settings.json" \
       && write_brief "$id" "$td/brief.md" \
       && h="$(MC_HERDR_WORKSPACE="$WORKSPACE" "$RUNNER" spawn nightowl "$id" "$(tget "$id" .worktree)" \
                 "$td/brief.md" "$td/result.json" --settings "$td/settings.json" ${model_args[@]+"${model_args[@]}"} 2>&1 | tail -1)" \
       && [[ "$h" == *"|"* ]]; then
      mput --arg id "$id" --arg h "$h" --arg now "$(date +%Y-%m-%dT%H:%M:%S%z)" \
        '(.tasks[] | select(.id == $id)) |= (. + {status: "running", handle: $h, launched_at: $now} | del(.error))'
      echo "launched $id → $h"
    else
      err="${err:-${h:-spawn failed}}"
      mput --arg id "$id" --arg e "$err" '(.tasks[] | select(.id == $id)) |= (. + {status: "launch-failed", error: $e})'
      echo "nightowl: launch $id failed: $err" >&2; rc=1
    fi
  done
  return "$rc"
}

# --- finish ----------------------------------------------------------------------------
record() { # record <id> <status> <summary> <pr> <details json>: report + work log + manifest
  local id="$1" st="$2" sum="$3" pr="$4" det="$5" kind ticket
  kind="$(tget "$id" .kind)"; ticket="$(tget "$id" .ticket)"
  {
    printf '\n## %s · %s · %s\n\n' "$id" "$kind" "$st"
    printf '%s\n\n' "$(tget "$id" .title)"
    printf -- '- Summary: %s\n' "$sum"
    [ -n "$ticket" ] && printf -- '- Ticket: %s\n' "$ticket"
    [ -n "$pr" ] && printf -- '- PR: %s\n' "$pr"
    printf -- '- Worktree: %s\n' "$(tget "$id" .worktree)"
    jq -r '.[]? | "- " + tostring' <<<"$det"
  } >> "$(report)"
  local wl=(--source nightowl)
  [ -n "$ticket" ] && wl+=(--ticket "$ticket")
  [ -n "$pr" ] && wl+=(--pr "$pr")
  MC_WORKLOG_SOURCE=nightowl "$WORKLOG" add "${wl[@]}" "nightowl $id ($kind) $st: $sum" || true
  mput --arg id "$id" --arg st "$st" --arg sum "$sum" --arg pr "$pr" --arg now "$(date +%Y-%m-%dT%H:%M:%S%z)" \
    --arg t "$TERMINAL" '(.tasks[] | select(.id == $id)) |= (. + {status: $st, summary: $sum}
       + (if ($t | split(" ") | index($st)) then {finished_at: $now} else {} end)
       + (if $pr != "" then {pr_url: $pr} else {} end))'
}

finish_task() { # finish_task <id>; caller holds the lock
  local id="$1" rf st sum pr det
  rf="$(task_dir "$id")/result.json"
  [ -s "$rf" ] && jq -e 'type == "object"' "$rf" >/dev/null 2>&1 || { echo "no valid result at $rf"; return 3; }
  [ -n "$(tget "$id" .finished_at)" ] && { echo "$id already finished ($(tget "$id" .status))"; return 0; }
  st="$(jq -r '.status // ""' "$rf")"
  _in "$st" "$TERMINAL" || { echo "result status '$st' is not one of: $TERMINAL"; return 3; }
  sum="$(jq -r '.summary // "(no summary)"' "$rf" | head -1)"
  pr="$(jq -r '.pr // ""' "$rf")"; [ -n "$pr" ] || pr="$(tget "$id" .pr_url)"
  det="$(jq -c '.details // []' "$rf")"
  record "$id" "$st" "$sum" "$pr" "$det"
  echo "finished $id: $st"
}

op_finish() {
  [ -n "$DATE" ] && [ "${#ARGS[@]}" -eq 1 ] || usage "finish needs --date and one task id"
  own_task "${ARGS[0]}"; need_task "${ARGS[0]}"
  lock
  local out rc; out="$(finish_task "${ARGS[0]}")"; rc=$?
  [ "$rc" -eq 0 ] && echo "$out" || die "$rc" "$out"
}

# --- task wrappers: push, draft-pr, pending-review -------------------------------------
pushable() { # pushable <id>: refuse unless this task may push its branch right now
  local id="$1" kind wt branch cur p okp=""
  kind="$(tget "$id" .kind)"; wt="$(tget "$id" .worktree)"; branch="$(tget "$id" .branch)"
  [ "$(tget "$id" .push)" = true ] && _in "$kind" "$PUSH_KINDS" || die 4 "task $id ($kind) is not allowed to push"
  while IFS= read -r p; do case "$branch" in "$p"*) okp=1 ;; esac; done < <(_list "$BRANCH_PREFIXES")
  [ -n "$okp" ] || die 4 "branch '$branch' is not one of the maintainer's prefixes"
  cur="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [ "$cur" = "$branch" ] || die 4 "worktree is on '$cur', not the task branch '$branch'"
}

op_push() {
  [ -n "$DATE" ] && [ "${#ARGS[@]}" -eq 1 ] || usage "push needs --date and one task id"
  local id="${ARGS[0]}"; own_task "$id"; need_task "$id"; pushable "$id"
  git -C "$(tget "$id" .worktree)" push -u origin "$(tget "$id" .branch)" || die 1 "git push failed"
}

op_draft_pr() {
  [ -n "$DATE" ] && [ "${#ARGS[@]}" -eq 1 ] || usage "draft-pr needs --date and one task id"
  [ -n "$TITLE" ] && [ -f "$BODY_FILE" ] || usage "draft-pr needs --title and an existing --body-file"
  local id="${ARGS[0]}" wt branch base url
  own_task "$id"; need_task "$id"; pushable "$id"
  wt="$(tget "$id" .worktree)"; branch="$(tget "$id" .branch)"; base="$(tget "$id" .base)"; base="${base#origin/}"
  if url="$(cd "$wt" && gh pr view "$branch" --json url --jq .url 2>/dev/null)" && [ -n "$url" ]; then
    echo "already open: $url"
  else
    local b=(); [ -n "$base" ] && [ "$base" != HEAD ] && b=(--base "$base")
    url="$(cd "$wt" && gh pr create --draft --head "$branch" ${b[@]+"${b[@]}"} --title "$TITLE" --body-file "$BODY_FILE" | tail -1)" \
      || die 1 "gh pr create failed"
    echo "opened draft: $url"
  fi
  lock
  mput --arg id "$id" --arg u "$url" '(.tasks[] | select(.id == $id)).pr_url = $u'
}

op_pending_review() {
  [ -n "$DATE" ] && [ "${#ARGS[@]}" -eq 2 ] || usage "pending-review needs --date, a task id and a payload file"
  local id="${ARGS[0]}" payload="${ARGS[1]}" pr repo num
  own_task "$id"; need_task "$id"
  pr="$(tget "$id" .pr)"
  [[ "$pr" =~ ^([^/#]+/[^/#]+)#([0-9]+)$ ]] || die 4 "task $id has no pr (owner/repo#N) to review"
  repo="${BASH_REMATCH[1]}"; num="${BASH_REMATCH[2]}"
  jq -e 'type == "object"' "$payload" >/dev/null 2>&1 || die 3 "payload is not a JSON object"
  # No event means GitHub keeps the review PENDING: visible to its author only.
  jq -e 'has("event") | not' "$payload" >/dev/null || die 4 "payload carries an event; nightowl only preloads PENDING reviews"
  gh api --method POST "repos/$repo/pulls/$num/reviews" --input "$payload" --jq '.html_url // .id' || die 1 "gh api failed"
}

# --- morning + status ------------------------------------------------------------------
op_morning() {
  orchestrator_only
  DATE="${DATE:-$(latest_date)}"
  [ -n "$DATE" ] && [ -f "$(manifest)" ] || die 3 "no nightowl manifest found in $REPORT_DIR"
  lock
  local id h st
  # A stalled task stays open: if the maintainer nudged its pane and it wrote a result
  # since, this run finishes it.
  for id in $(jq -r '.tasks[] | select(.status == "running" or .status == "stalled") | .id' "$(manifest)"); do
    if [ -s "$(task_dir "$id")/result.json" ]; then
      finish_task "$id" >/dev/null || true
      [ -n "$(tget "$id" .finished_at)" ] && continue
    fi
    [ "$(tget "$id" .status)" = stalled ] && continue
    h="$(tget "$id" .handle)"
    st="$("$RUNNER" status "$h" 2>/dev/null || echo gone)"
    case "$st" in
      running) ;;   # still working; leave it
      *) record "$id" stalled "pane is $st with no result; open the pane or the worktree" "" "[]" ;;
    esac
  done
  if [ -n "$TEARDOWN" ]; then
    for id in $(jq -r --arg t "$TERMINAL" '.tasks[] | select((.status as $s | $t | split(" ") | index($s)) and .handle and (.torn_down | not)) | .id' "$(manifest)"); do
      "$RUNNER" teardown "$(tget "$id" .handle)" >/dev/null 2>&1 \
        && mput --arg id "$id" '(.tasks[] | select(.id == $id)).torn_down = true'
    done
  fi
  if [ -n "$JSON" ]; then jq '.tasks' "$(manifest)"; return 0; fi
  echo "nightowl $DATE   report: $(report)"
  jq -r '.tasks[] | [.id, .kind, .status, (.summary // .error // ""), (.pr_url // "")] | @tsv' "$(manifest)" \
    | awk -F'\t' '{ printf "  %-14s %-9s %-13s %s%s\n", $1, $2, $3, $4, ($5 == "" ? "" : "  " $5) }'
}

op_status() {
  DATE="${DATE:-$(latest_date)}"
  [ -n "$DATE" ] && [ -f "$(manifest)" ] || die 3 "no nightowl manifest found in $REPORT_DIR"
  jq -r '.tasks[] | [.id, .kind, .status, (.worktree // ""), (.handle // "")] | @tsv' "$(manifest)"
}

case "$op" in
  confirm)        op_confirm ;;
  launch)         op_launch ;;
  settings)       op_settings ;;
  finish)         op_finish ;;
  push)           op_push ;;
  draft-pr)       op_draft_pr ;;
  pending-review) op_pending_review ;;
  morning)        op_morning ;;
  status)         op_status ;;
  path)           DATE="${DATE:-$(latest_date)}"; [ -n "$DATE" ] || DATE="$(date +%Y-%m-%d)"; report; echo ;;
  -h|--help|help) sed -n '2,32p' "$NO_SELF" | sed 's/^# \{0,1\}//' ;;
  *) usage "unknown op '$op'" ;;
esac
