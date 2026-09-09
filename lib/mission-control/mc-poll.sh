#!/usr/bin/env bash
# mc-poll.sh — ONE-CALL board projection for the mission-control loop/orchestrator.
#
# Reads state.json FRESH and joins it with BATCHED tracker + host queries, printing a
# compact one-line-per-ticket table for the ACTIVE board + a parked/done footer.
# This is the ONLY thing the loop needs to read each tick — it preserves the
# durable-memory rule (state.json is re-read here every call) WITHOUT the loop having
# to `cat` the full file (which carries ~3.7k tokens of result/question prose + all
# the done tickets = the per-tick context burn this replaces).
#
# Replaces the old ~2N per-ticket calls with: 1 state read + 1 tracker `fields_of` +
# 1 host `list_prs` per repo. READ-ONLY, like dash.sh — NEVER writes state.json.
#
# Provider calls go through the tracker/host adapters (see adapters/CONTRACT.md); no
# provider is named here. Status→progress ranks come from the profile (MC_STATUS_RANK)
# and the CI freeze-guard name from MC_FREEZE_CHECK_PATTERN. The board-lane ranks
# (lane_rank) are the engine's OWN board vocab and stay here.
#
# Active = non-done AND not a parked-refined ticket. PARKED = a `refined` ticket
# sitting on the backlog (blocked==false AND no worker) — written but not yet pulled
# in; it is NOT polled or proposed each tick, only counted. It activates when the
# human pulls it (`mc plan <key>`), which moves it into the live flow. A `refined`
# ticket that is `blocked` OR has a worker assigned stays ACTIVE (a block always needs
# eyes; a worker on a still-`refined` lane is in-flight drift to surface, not hide).
#
#   ~/.claude/mission-control/mc-poll.sh
#   MC_STATE=/path/to/state.scratch.json ~/.claude/mission-control/mc-poll.sh
set -uo pipefail

# --- adapter dispatch (resolve this script's real dir through any symlink) ---
_mc_self="${BASH_SOURCE[0]}"
while [ -L "$_mc_self" ]; do
  _mc_ln="$(readlink "$_mc_self")"
  case "$_mc_ln" in /*) _mc_self="$_mc_ln" ;; *) _mc_self="$(dirname "$_mc_self")/$_mc_ln" ;; esac
done
_MC_LIB="$(cd "$(dirname "$_mc_self")" && pwd)"
. "$_MC_LIB/adapters/dispatch.sh"

STATE="${MC_STATE:-$HOME/.claude/mission-control/state.json}"
# status → progress-rank map (regression detection). Generic fallback if no profile.
STATUS_RANK="${MC_STATUS_RANK:-Backlog=0;To Do=1;In Progress=2;In Review=3;QA=4;Done=5}"
# CI freeze-guard name substring; empty = no freeze concept.
FREEZE_RE="${MC_FREEZE_CHECK_PATTERN:-}"
[ -f "$STATE" ] || { echo "no state at $STATE" >&2; exit 1; }

# --- board rows: ticket\tlane\tpr\tblocked(0/1)\tworker\tphase_done(0/1)\tcycle\trunner.impl\trunner.handle ---
# Sentinel "-" for empty pr/worker: IFS=$'\t' read collapses consecutive tabs
# (tab is whitespace), so empty middle fields would shift the columns.
rows=$(jq -r '.tickets[]
  | [ .ticket, .lane, (.pr // "-"),
      (if .blocked==true then "1" else "0" end),
      (.worker // "-"),
      (if .phase_done==true then "1" else "0" end),
      (.cycle // "-"),
      (.runner.impl // "-"),
      (.runner.handle // "-") ]
  | @tsv' "$STATE")

active=""; parked=""; bgqueue=""; done_ids=""; regressed_ids=""
while IFS=$'\t' read -r t lane pr blk wk pd cyc rimpl rhandle; do
  [ -z "$t" ] && continue
  if [ "$lane" = "done" ]; then
    done_ids="$done_ids $t"
  elif [ "$lane" = "refined" ] && [ "$blk" != "1" ] && [ "$wk" = "-" ]; then
    # A refined, unblocked, worker-less row splits by cycle:
    #  - cycle:background = the PLANNABLE opportunistic queue. The loop plans ONE per
    #    idle tick (background rule); it must SEE these, so surface them as an actionable
    #    section, NOT a silent parked count. (A worker-bearing refined row stays ACTIVE
    #    below — that's in-flight drift to surface, not hide.)
    #  - anything else (cycle:backlog, or «absent» which now means backlog) = truly parked;
    #    it sits until `mc plan <key>`.
    if [ "$cyc" = "background" ]; then
      bgqueue="$bgqueue $t"
    else
      parked="$parked $t"
    fi
  else
    active="$active$t	$lane	$pr	$blk	$wk	$pd	$rimpl	$rhandle"$'\n'
  fi
done <<< "$rows"

[ -z "$active" ] && { echo "no active tickets (all done or parked)"; }

# --- ONE tracker call over the ACTIVE keys only ---
jira_tmp=$(mktemp)
keys=$(printf '%s' "$active" | cut -f1 | grep -v '^$' | paste -sd, -)
if [ -n "$keys" ]; then
  # fields_of returns key⇥status⇥assignee (adapter squeezes any alignment padding, so
  # field positions are stable: key=1, status=2, assignee=3).
  tracker fields_of "$keys" > "$jira_tmp" || true
fi
jfield() { awk -F'\t' -v k="$1" -v c="$2" '$1==k{print $c}' "$jira_tmp"; }

# --- regression detection: board lane "ahead of" live tracker status ---
# Both the board lane and the tracker status map onto one workflow-progress scale. When
# the lane implies MORE progress than the tracker reflects by >=2 stages, the ticket was
# moved BACKWARD in the tracker (a QA/post-merge kickback: the tracker bounced it to a
# pre-dev status while the board still shows it in/after review or QA). Normal tracker-lag
# — the board one step ahead because a PR opened before someone dragged the card — is a
# gap of 1 and is NOT flagged. Unknown lane/status (rank -1) is never flagged.
lane_rank() { case "$1" in
  refined|plan-review) echo 1 ;;
  implement|kickback)  echo 2 ;;
  in-review|awaiting-review|ready-to-merge) echo 3 ;;
  qa|alpha-verify|product-review) echo 4 ;;
  done) echo 5 ;;
  *) echo -1 ;; esac; }
# status_rank: look the status up in MC_STATUS_RANK ("Status=rank;…"). Unknown → -1.
# Plain ';'-split loop (no associative arrays — macOS ships bash 3.2). Keys may contain
# spaces, so only ';' separates pairs.
status_rank() {
  local want="$1" pair k v oIFS="$IFS"
  IFS=';'
  for pair in $STATUS_RANK; do
    k="${pair%%=*}"; v="${pair#*=}"
    if [ "$k" = "$want" ]; then IFS="$oIFS"; echo "$v"; return; fi
  done
  IFS="$oIFS"; echo -1
}

# _repo_of <pr-url> — the owner/repo (or group/project) a PR URL belongs to.
# HOST-AGNOSTIC, replacing the old github.com-shaped grep: strip scheme+host, fold
# GitLab's `/-/` infix away, then drop the PR segment and everything after it. Handles
# /pull/N, /pulls/N, /merge_requests/N and /pull-requests/N.
#
# It deliberately does NOT consult the board's `repo` field: that field holds a BARE
# repo name with no owner, so using it as the host lookup key silently turns every
# joined PR into a miss. The URL is the only place the full slug lives.
_repo_of() {
  local url="${1:-}"
  # Emits a TRAILING NEWLINE: one caller consumes this in a pipeline, where a
  # newline-less result would concatenate one repo onto the next; the other uses $(…),
  # which strips it. One form serves both.
  printf '%s\n' "$url" \
    | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://[^/]+/##' \
    | sed -E 's#/-/#/#' \
    | sed -E 's#/(pull|pulls|merge_requests|pull-requests)/[0-9]+.*$##'
}

# --- ONE host call per repo (active PRs only) ---
repos=$(printf '%s' "$active" | cut -f3 | grep -v -e '^$' -e '^-$' \
          | while IFS= read -r _pr; do _repo_of "$_pr"; done | grep -v '^$' | sort -u)
gh_tmp=$(mktemp); echo '{}' > "$gh_tmp"
for repo in $repos; do
  data=$(host list_prs "$repo" all)
  [ -z "$data" ] && data='[]'
  jq --arg r "$repo" --argjson d "$data" '.[$r] = ($d | map({(.number|tostring): .}) | add // {})' "$gh_tmp" > "$gh_tmp.2" && mv "$gh_tmp.2" "$gh_tmp"
done

# --- active table ---
printf '%-9s %-16s %-15s %-22s %-18s %-6s %-16s %-8s %-10s %s\n' TICKET LANE STATUS ASSIGNEE PR DRAFT REVIEW CI MERGED FLAGS
while IFS=$'\t' read -r t lane pr blk wk pd rimpl rhandle; do
  [ -z "$t" ] && continue
  jstatus=$(jfield "$t" 2); [ -z "$jstatus" ] && jstatus="?(tracker-miss)"
  jassign=$(jfield "$t" 3); [ -z "$jassign" ] && jassign="-"
  prcol="-"; draft="-"; review="-"; ci="-"; merged="-"
  if [ -n "$pr" ] && [ "$pr" != "-" ]; then
    repo=$(_repo_of "$pr")
    num=$(echo "$pr" | grep -oE '[0-9]+$')
    prcol="$(echo "$repo" | sed 's#.*/##')#$num"
    row=$(jq -c -r --arg r "$repo" --arg n "$num" '.[$r][$n] // empty' "$gh_tmp")
    if [ -n "$row" ]; then
      [ "$(echo "$row" | jq -r '.isDraft')" = "true" ] && draft="draft" || draft="ready"
      review=$(echo "$row" | jq -r '.reviewDecision // "-"'); [ -z "$review" ] && review="-"
      # Stale approval: the host keeps reviewDecision==APPROVED even after new commits, so
      # an APPROVED PR with pending (re-)review requests means a change landed after the
      # approval and re-review is pending → NOT merge-ready. Surface as `re-review` so the
      # loop/orchestrator never reads sticky-APPROVED as ready-to-merge.
      # (The rarer changed-but-NOT-re-requested case is caught by the commit-vs-approval
      # timestamp check at the merge gate — depth, not this per-tick breadth read.)
      if [ "$review" = "APPROVED" ] && [ "$(echo "$row" | jq -r '(.mergedAt == null) and (((.reviewRequests // []) | length) > 0)')" = "true" ]; then
        review="re-review"
      fi
      m=$(echo "$row" | jq -r '.mergedAt // "-"'); [ "$m" != "-" ] && [ "$m" != "null" ] && merged="${m:0:10}"
      # A freeze-guard check (any check whose name matches MC_FREEZE_CHECK_PATTERN — e.g.
      # "Sprint Freeze Warning") is INTENTIONALLY red during a freeze window — it's a
      # human-coordination gate, NOT a broken build. So we partition checks into real vs.
      # freeze: a freeze-ONLY red surfaces as `frozen` (build green, merge gated elsewhere);
      # a NON-freeze failure (even alongside a freeze red) is a real `fail`. Empty pattern =
      # no freeze concept → every check is real.
      ci=$(echo "$row" | jq -r --arg frz "$FREEZE_RE" '
        (.statusCheckRollup // []) | map({ n: (.name // .context // ""), s: (.conclusion // .state // "") }) as $c
        | ($c | map(select(($frz == "") or (.n | test($frz; "i") | not))) | map(.s)) as $real
        | ($c | map(select(($frz != "") and (.n | test($frz; "i"))))      | map(.s)) as $frzchecks
        | ["FAILURE","ERROR","TIMED_OUT","CANCELLED","ACTION_REQUIRED","STARTUP_FAILURE"] as $bad
        | if ($c|length)==0 then "none"
          elif ($real | any(IN($bad[]))) then "fail"
          elif ($real | any(. == "" or IN("PENDING","IN_PROGRESS","QUEUED","EXPECTED","WAITING","REQUESTED"))) then "pending"
          elif ($frzchecks | any(IN($bad[]))) then "frozen"
          else "green" end')
    else
      prcol="$prcol(host-miss)"
    fi
  fi
  flags=""
  [ "$blk" = "1" ] && flags="${flags}⛔blocked "
  lr=$(lane_rank "$lane"); jr=$(status_rank "$jstatus")
  if [ "$lr" -ge 0 ] && [ "$jr" -ge 0 ] && [ $((lr - jr)) -ge 2 ]; then
    flags="${flags}⚠REGRESSED(status<lane) "
    regressed_ids="$regressed_ids $t($jstatus vs $lane)"
  fi
  # A worker with a `runner` on the row gets its LIVE status from the runner adapter
  # (`●coder@herdr:running`); the driver reads that instead of trusting the board's
  # worker marker. `gone` is loud: the session is missing while the board says running.
  # Rows without a runner render as before (`●coder`) — the in-process path the driver
  # confirms against its own teammate list.
  if [ "$wk" != "-" ] && [ "$pd" != "1" ]; then
    if [ "$rimpl" != "-" ] && [ "$rhandle" != "-" ]; then
      rst=$(runner "$rimpl" status "$rhandle" 2>/dev/null); [ -z "$rst" ] && rst="?"
      flags="${flags}●${wk}@${rimpl}:${rst} "
      [ "$rst" = "gone" ] && flags="${flags}⚠RUNNER-GONE "
    else
      flags="${flags}●${wk} "
    fi
  fi
  [ "$wk" != "-" ] && [ "$pd" = "1" ] && flags="${flags}${wk}✓ "
  [ -z "$flags" ] && flags="-"
  printf '%-9s %-16s %-15s %-22s %-18s %-6s %-16s %-8s %-10s %s\n' "$t" "$lane" "$jstatus" "$jassign" "$prcol" "$draft" "$review" "$ci" "$merged" "$flags"
done <<< "$active"

# --- regressions: loud, standing flag (a kickback the board hasn't caught up to) ---
# These need a human to reconcile the lane (surface, do NOT auto-move backward). Shows
# every tick, so it can't go stale the way a one-time `question` note did.
[ -n "$regressed_ids" ] && printf '\n⚠ REGRESSED — tracker moved backward vs board lane (≥2 stages; likely a QA/post-merge kickback — reconcile the lane):%s\n' "$regressed_ids"

# --- background queue: PLANNABLE now (loop acts), listed not just counted ---
bq=$(echo $bgqueue | wc -w | tr -d ' ')
[ "$bq" -gt 0 ] && printf '\nbackground queue (PLANNABLE NOW — loop spawns ONE planner per idle tick per the background opportunistic rule; do NOT wait for `mc plan`): %s —%s\n' "$bq" "$bgqueue"

# --- footer: parked (cycle:backlog) + done (counted, NOT polled) ---
pk=$(echo $parked | wc -w | tr -d ' '); dn=$(echo $done_ids | wc -w | tr -d ' ')
[ "$pk" -gt 0 ] && printf '\nparked (refined backlog, cycle:backlog — not polled; `mc plan <key>` to pull one in): %s —%s\n' "$pk" "$parked"
[ "$dn" -gt 0 ] && printf 'done (not polled): %s\n' "$dn"

rm -f "$jira_tmp" "$gh_tmp"
