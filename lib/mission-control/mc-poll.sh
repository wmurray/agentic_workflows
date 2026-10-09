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
# 1 host `list_prs` per repo (+ 1 `get_pr` per board PR outside its window). READ-ONLY, like dash.sh — NEVER writes state.json.
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
# Two unblocked, worker-less `refined` splits are NOT parked: cycle:background (the
# opportunistic queue) and cycle:sprint assigned to the operator (the sprint plan
# queue, which the loop proposes to plan; see that section below).
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
# The tracker status the QA transition lands on (the post-merge QA section below).
STATUS_QA="${MC_STATUS_QA:-QA}"
# CI freeze-guard name substring; empty = no freeze concept.
FREEZE_RE="${MC_FREEZE_CHECK_PATTERN:-}"
[ -f "$STATE" ] || { echo "no state at $STATE" >&2; exit 1; }

# --- board rows: ticket\tlane\tpr\tblocked(0/1)\tworker\tphase_done(0/1)\tcycle\trunner.impl\trunner.handle\tplan_proposed(0/1)\ttracker_qa_at(0/1) ---
# Sentinel "-" for empty pr/worker: IFS=$'\t' read collapses consecutive tabs
# (tab is whitespace), so empty middle fields would shift the columns.
rows=$(jq -r '.tickets[]
  | [ .ticket, .lane, (.pr // "-"),
      (if .blocked==true then "1" else "0" end),
      (.worker // "-"),
      (if .phase_done==true then "1" else "0" end),
      (.cycle // "-"),
      (.runner.impl // "-"),
      (.runner.handle // "-"),
      (if .plan_proposed==true then "1" else "0" end),
      (if (.tracker_qa_at // "") != "" then "1" else "0" end) ]
  | @tsv' "$STATE")

active=""; parked=""; bgqueue=""; sprintq=""; sprintrun=""; proposed=""; done_ids=""; regressed_ids=""
qa_moved=""; postqa=""
while IFS=$'\t' read -r t lane pr blk wk pd cyc rimpl rhandle pp tq; do
  [ -z "$t" ] && continue
  [ "$pp" = "1" ] && proposed="$proposed $t"
  [ "$tq" = "1" ] && qa_moved="$qa_moved $t"
  if [ "$lane" = "done" ]; then
    done_ids="$done_ids $t"
  elif [ "$lane" = "refined" ] && [ "$blk" != "1" ] && [ "$wk" = "-" ]; then
    # A refined, unblocked, worker-less row splits by cycle:
    #  - cycle:background = the PLANNABLE opportunistic queue. The loop plans ONE per
    #    idle tick (background rule); it must SEE these, so surface them as an actionable
    #    section, NOT a silent parked count. (A worker-bearing refined row stays ACTIVE
    #    below — that's in-flight drift to surface, not hide.)
    #  - cycle:sprint = a candidate for the sprint plan queue. Only the ones the tracker
    #    says are the operator's qualify (mine_of, below); the rest fold back into parked.
    #  - anything else (cycle:backlog, or «absent» which now means backlog) = truly parked;
    #    it sits until `mc plan <key>`.
    if [ "$cyc" = "background" ]; then
      bgqueue="$bgqueue $t"
    elif [ "$cyc" = "sprint" ]; then
      sprintq="$sprintq $t"
    else
      parked="$parked $t"
    fi
  else
    # A sprint refined row a planning worker already holds is mid-planning: it keeps
    # background condition (a) held without an assignee check (pulling it made it ours).
    [ "$lane" = "refined" ] && [ "$blk" != "1" ] && [ "$cyc" = "sprint" ] && sprintrun="$sprintrun $t"
    active="$active$t	$lane	$pr	$blk	$wk	$pd	$rimpl	$rhandle"$'\n'
  fi
done <<< "$rows"

# --- sprint plan queue: keep the candidates the tracker assigns to the operator ---
# One extra tracker call, made only when a candidate exists. A candidate that is
# unassigned or someone else's is parked, labelled so the footer says why.
eligible=""
if [ -n "$sprintq" ]; then
  mine=" $(tracker mine_of $sprintq | tr '\n' ' ') "
  for t in $sprintq; do
    case "$mine" in
      *" $t "*) eligible="$eligible $t" ;;
      *)        parked="$parked $t(sprint,not-yours)" ;;
    esac
  done
fi

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
    # Not in the list window: an old PR that is still open falls out of list_prs' newest-N
    # page. Ask for it by number before calling it a miss. One host call per miss only, so
    # a normal tick (every board PR inside the window) costs nothing extra; the worst case
    # is one call per active row with a PR, if list_prs itself came back empty.
    hosterr=0
    if [ -z "$row" ] && [ -n "$num" ]; then
      row=$(host get_pr "$repo" "$num" 2>/dev/null) || { row=""; hosterr=1; }
    fi
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
    elif [ "$hosterr" = 1 ]; then
      # get_pr could not answer (auth, network): unknown, which is not the same as absent.
      prcol="$prcol(host-err)"
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
  [ "$lane" = "alpha-verify" ] && postqa="$postqa$t	$jstatus	$blk	$wk"$'\n'
  printf '%-9s %-16s %-15s %-22s %-18s %-6s %-16s %-8s %-10s %s\n' "$t" "$lane" "$jstatus" "$jassign" "$prcol" "$draft" "$review" "$ci" "$merged" "$flags"
done <<< "$active"

# --- regressions: loud, standing flag (a kickback the board hasn't caught up to) ---
# These need a human to reconcile the lane (surface, do NOT auto-move backward). Shows
# every tick, so it can't go stale the way a one-time `question` note did.
[ -n "$regressed_ids" ] && printf '\n⚠ REGRESSED — tracker moved backward vs board lane (≥2 stages; likely a QA/post-merge kickback — reconcile the lane):%s\n' "$regressed_ids"

# --- background queue: PLANNABLE now (loop acts), listed not just counted ---
bq=$(echo $bgqueue | wc -w | tr -d ' ')
# Condition (a) of the background rule: sprint planning goes first while any of the
# operator's sprint refined rows awaits planning (eligible, proposed or not) or a planning
# worker holds one. Sprint rows that are unassigned or someone else's do not count.
cond_a=$(echo $eligible $sprintrun)
if [ "$bq" -gt 0 ]; then
  if [ -n "$cond_a" ]; then
    printf '\nbackground condition (a): held — %s (sprint planning first)\n' "$cond_a"
  else
    printf '\nbackground condition (a): clear — no sprint refined ticket of yours awaiting planning\n'
  fi
fi
[ "$bq" -gt 0 ] && printf 'background queue (PLANNABLE NOW — loop spawns ONE planner per idle tick per the background opportunistic rule; do NOT wait for `mc plan`): %s —%s\n' "$bq" "$bgqueue"

# --- sprint plan queue: PROPOSE planning, once per ticket ---
# Propose once: the loop prints "would plan <KEY>" for a row without plan_proposed, then
# sets plan_proposed:true on it; a row that already carries it is listed, not re-proposed.
# The flag is cleared (listed below) as soon as the row stops being eligible: it left
# refined, got blocked or a worker, changed cycle, or is no longer the operator's. A row
# that becomes eligible again is proposed again. MC_SPRINT_PLAN_FILE present = armed: the
# loop plans these itself instead of proposing (the gate1/address flag-file pattern).
spf="${MC_SPRINT_PLAN_FILE:-$HOME/.claude/mission-control/SPRINT_PLAN_AUTO}"
if [ -f "$spf" ]; then sp_mode="auto"; sp_verb="plan"; else sp_mode="propose"; sp_verb="would plan"; fi
sq=$(echo $eligible | wc -w | tr -d ' ')
if [ "$sq" -gt 0 ]; then
  printf '\nsprint plan queue (refined, cycle:sprint, assigned to you, no worker · mode: %s): %s\n' "$sp_mode" "$sq"
  for t in $eligible; do
    case " $proposed " in
      *" $t "*) printf '  %-9s proposed — in NEEDS YOU until `mc plan %s`\n' "$t" "$t" ;;
      *)        printf '  %s %s — new; set plan_proposed:true once said\n' "$sp_verb" "$t" ;;
    esac
  done
fi
stale=""
for t in $proposed; do
  case " $eligible " in *" $t "*) : ;; *) stale="$stale $t" ;; esac
done
[ -n "$stale" ] && printf 'plan_proposed to clear (no longer eligible):%s\n' "$stale"

# --- post-merge QA move: one line per alpha-verify row ---
# The tracker moves to its QA status at merge, once the field check passes; the board lane
# stays at alpha-verify until the operator's smoke-test `mc qa`, which is then board-only.
# tracker_qa_at on the row records the move, so the QA move runs once per ticket:
#   in QA          marker set, tracker at the QA status → nothing to do; `mc qa` is board-only
#   set marker     tracker already at the QA status, no marker → record it, run nothing
#   left QA        marker set, tracker elsewhere → flag; never re-run the QA move
#   due            no marker, tracker not in QA → the field check runs; on exit 0 the
#                  `fields` guard decides between the QA move and a proposal
#   waiting        no marker, blocked or a worker holds it → nothing this tick
if [ -n "$postqa" ]; then
  printf '\npost-merge QA move (alpha-verify · tracker QA status: %s):\n' "$STATUS_QA"
  while IFS=$'\t' read -r t jst blk wk; do
    [ -z "$t" ] && continue
    case " $qa_moved " in *" $t "*) mk=1 ;; *) mk=0 ;; esac
    if [ "$mk" = 1 ] && [ "$jst" = "$STATUS_QA" ]; then
      printf '  %-9s in QA (tracker) — `mc qa %s` moves the board only\n' "$t" "$t"
    elif [ "$jst" = "$STATUS_QA" ]; then
      printf '  %-9s tracker already %s — set tracker_qa_at; run no QA move\n' "$t" "$STATUS_QA"
    elif [ "$mk" = 1 ]; then
      printf '  %-9s tracker_qa_at set but tracker at %s — flag; never re-run the QA move\n' "$t" "$jst"
    elif [ "$blk" = "1" ] || [ "$wk" != "-" ]; then
      printf '  %-9s waiting (%s) — no QA move this tick\n' "$t" "$([ "$blk" = "1" ] && echo blocked || echo "worker $wk")"
    else
      printf '  %-9s due — field check; on exit 0 the fields guard decides the QA move\n' "$t"
    fi
  done <<< "$postqa"
fi

# --- footer: parked (cycle:backlog) + done (counted, NOT polled) ---
pk=$(echo $parked | wc -w | tr -d ' '); dn=$(echo $done_ids | wc -w | tr -d ' ')
[ "$pk" -gt 0 ] && printf '\nparked (refined backlog, cycle:backlog or sprint-not-yours — not polled; `mc plan <key>` to pull one in): %s —%s\n' "$pk" "$parked"
[ "$dn" -gt 0 ] && printf 'done (not polled): %s\n' "$dn"

rm -f "$jira_tmp" "$gh_tmp"
