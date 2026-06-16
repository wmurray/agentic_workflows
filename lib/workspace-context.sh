#!/usr/bin/env bash
# workspace-context.sh — single source of truth for work-context data streams.
#
# Emits one JSON object on stdout aggregating git activity, PRs (authored +
# review buckets), Jira, calendar, and the Task Backlog. Shared by /daily, /eod,
# and /sitrep so the queries (and their quirks) live in exactly one place.
#
# Usage:
#   workspace-context.sh [--since "<git-log --since arg>"] [--jira-days N] [--recent-days N] [--repos "A B C"]
#
#   --since        git-log window for "what you touched" (default: "today").
#                  e.g. "today", "2 days ago", "1 week ago"
#   --jira-days    lookback (days) for the jira_recent stream (default: 2)
#   --recent-days  lookback (days) for the prs_recent stream (default: 2). Without this,
#                  gh returns the newest N PRs regardless of age — dozens of long-merged
#                  PRs across repos. Windowing keeps prs_recent to "what got done recently".
#   --repos        space-separated repo list under $SOURCE_DIR (default: overrideable via env)
#
# Configuration (set as env vars to override defaults):
#   GIT_AUTHOR     — your name as it appears in git log (default: from git config)
#   GH_TEAM        — GitHub org/team for team review requests (e.g. my-org/my-team)
#   VAULT          — path to your notes vault (e.g. ~/Documents/Obsidian/MyVault)
#   BACKLOG_FILE   — path to your task backlog markdown file (default: $VAULT/Areas/Engineering Process/Task Backlog.md)
#   SOURCE_DIR     — path to your source directory containing repo checkouts (default: ~/Projects)
#   REPOS          — space-separated list of repo names under $SOURCE_DIR
#   JIRA_PROJECT   — Jira project key (e.g. ENG, PROJ)
#
# Output shape (all arrays default to [] on failure — never errors out):
#   {
#     today, now, git_since,
#     git:               [ {repo, line} ],
#     prs_authored:      [ {repo, number, title, url, isDraft, reviewDecision, updatedAt, staleDays, bumpedDaysAgo, bumpNote, ci} ], # open, mine; ci=passing|failing|pending|none
#                        #   staleDays    = WORKING days since last update (Sat/Sun excluded); window-independent — catches PRs slipping regardless of --recent-days
#                        #   bumpedDaysAgo/bumpNote = out-of-band bump from pr-followups.json (null if none), in WORKING days; suppress the stale nudge on the bump day only (bumpedDaysAgo == 0), re-surface next working day
#     prs_recent:        [ {repo, number, title, url, state, createdAt, updatedAt, mergedAt} ], # any state, updated within --recent-days, for "what got done"
#     prs_review_direct: [ {repo, number, title, url, author, createdAt} ],          # requested of ME, oldest first
#     prs_review_team:   [ {repo, number, title, url, author, createdAt} ],          # requested of the team, deduped vs direct
#     jira_open:         [ {key, status, summary} ],                                 # statusCategory != Done
#     jira_recent:       [ {key, status, summary} ],                                 # updated in last --jira-days
#     calendar:          [ "..." ],                                                  # today's timed events
#     backlog:           "<raw Task Backlog markdown>"                               # tier sections; callers parse
#   }
#
# Notes / hard-won quirks baked in here so callers don't rediscover them:
#   - Jira: the `--assignee me` / `--status` / `--updated-after` FLAG forms silently
#     return zero rows in this environment. Must use JQL `-q` with currentUser().
#   - `--no-headers` makes jira --plain emit clean single-tab rows (no alignment padding).
#   - PR review buckets: `user-review-requested:@me` = direct asks; `team-review-requested:<team>`
#     = team asks. A PR can be in both — we drop team entries that are also direct.

set -uo pipefail

# ── config ────────────────────────────────────────────────────────────────
GIT_AUTHOR="${GIT_AUTHOR:-$(git config user.name 2>/dev/null || echo 'Your Name')}"
GH_TEAM="${GH_TEAM:-<your-org>/<your-team>}"
VAULT="${VAULT:-$HOME/Documents/Obsidian/<your-vault>}"
BACKLOG_FILE="${BACKLOG_FILE:-$VAULT/Areas/Engineering Process/Task Backlog.md}"
SOURCE_DIR="${SOURCE_DIR:-$HOME/Projects}"

# ── args ──────────────────────────────────────────────────────────────────
SINCE="today"
JIRA_DAYS=2
RECENT_DAYS=2
REPOS="${REPOS:-Repo1 Repo2}"
while [ $# -gt 0 ]; do
  case "$1" in
    --since)       SINCE="$2"; shift 2 ;;
    --jira-days)   JIRA_DAYS="$2"; shift 2 ;;
    --recent-days) RECENT_DAYS="$2"; shift 2 ;;
    --repos)       REPOS="$2"; shift 2 ;;
    -h|--help)     sed -n '2,33p' "$0"; exit 0 ;;
    *)             shift ;;
  esac
done

TODAY=$(date +%Y-%m-%d)
NOW=$(date '+%-I:%M %p')
NOW_EPOCH=$(date +%s)

# Bump suppressions: PRs bumped out-of-band (e.g. pinged a reviewer in Slack,
# invisible to GitHub's updatedAt). pr-bump.sh writes here; we annotate each authored PR with
# how long ago it was bumped so callers can suppress the stale nudge for a fresh bump.
BUMP_FILE="$HOME/.claude/lib/pr-followups.json"
BUMPS_JSON=$(jq -c '.' "$BUMP_FILE" 2>/dev/null || echo '[]')

# ── git: commits in the window, across repos ────────────────────────
GIT_JSON="[]"
for repo in $REPOS; do
  [ -d "$SOURCE_DIR/$repo/.git" ] || continue
  lines=$(git -C "$SOURCE_DIR/$repo" log --since="$SINCE" --author="$GIT_AUTHOR" --oneline --all 2>/dev/null)
  repo_json=$(printf '%s\n' "$lines" | jq -R --arg repo "$repo" 'select(length>0) | {repo:$repo, line:.}' | jq -s '.' 2>/dev/null)
  GIT_JSON=$(jq -n --argjson a "$GIT_JSON" --argjson b "${repo_json:-[]}" '$a + $b' 2>/dev/null || echo "$GIT_JSON")
done

# ── PRs authored (open) ─────────────────────────────────────────────────
PRS_AUTHORED="[]"
for repo in $REPOS; do
  [ -d "$SOURCE_DIR/$repo/.git" ] || continue
  arr=$( (cd "$SOURCE_DIR/$repo" && gh pr list --author @me --state open --limit 30 \
          --json number,title,url,isDraft,reviewDecision,statusCheckRollup,updatedAt 2>/dev/null) )
  # roll statusCheckRollup up into a single ci value so consumers don't parse check arrays;
  # compute staleDays as WORKING days since last update (Sat/Sun excluded, so a Fri PR isn't
  # "stale" Monday) and annotate any out-of-band bump so callers can nudge slipping PRs.
  arr=$(printf '%s' "${arr:-[]}" | jq --arg repo "$repo" --argjson now "$NOW_EPOCH" --argjson bumps "$BUMPS_JSON" '
        # Calendar WORKING days (Sat/Sun excluded) from the LOCAL date of an ISO timestamp
        # through today — counts whole days date-to-date, so it is independent of clock
        # time-of-day (a Fri PR reads 0 Fri, 1 Mon, 2 Tue regardless of when checked).
        # Uses strflocaltime format codes (not positional array fields) to stay correct
        # across jq/gojq builds, which order the broken-down-time array differently.
        def secsintoday($e): ($e|strflocaltime("%H")|tonumber)*3600 + ($e|strflocaltime("%M")|tonumber)*60 + ($e|strflocaltime("%S")|tonumber);
        def localmid($e): $e - secsintoday($e);
        def isweekend($e): ($e|strflocaltime("%u")|tonumber) > 5;   # %u: 1=Mon..7=Sun
        def busdays($iso): ($iso|fromdateiso8601) as $u
          | localmid($u) as $um | localmid($now) as $nm
          | (($nm - $um) / 86400 | round) as $days
          | if $days <= 0 then 0
            else ([range(1; $days + 1) | ($um + (. * 86400) + 43200) | select(isweekend(.) | not)] | length) end;
        map(
          ("\($repo)#\(.number)") as $key
          | ($bumps | map(select(.key == $key)) | sort_by(.bumpedAt) | last) as $bump
          | {
          repo:$repo, number, title, url, isDraft, reviewDecision, updatedAt,
          staleDays: (if .updatedAt then busdays(.updatedAt) else null end),
          bumpedDaysAgo: (if $bump then busdays($bump.bumpedAt) else null end),
          bumpNote: ($bump.note // null),
          ci: ((.statusCheckRollup // []) as $c
               | if   ($c|length) == 0                                                  then "none"
                 elif any($c[]; (.conclusion // .state) == "FAILURE")                   then "failing"
                 elif any($c[]; (.status == "IN_PROGRESS") or ((.conclusion // .state) == "PENDING") or ((.conclusion == null) and (.state == null))) then "pending"
                 else "passing" end)
        })' 2>/dev/null || echo '[]')
  PRS_AUTHORED=$(jq -n --argjson a "$PRS_AUTHORED" --argjson b "${arr:-[]}" '$a + $b' 2>/dev/null || echo "$PRS_AUTHORED")
done

# ── PRs, any state, updated within the window (for "what got done" in daily/eod) ─
# gh returns newest-first regardless of age, so we fetch a generous slice and filter by
# updatedAt against a UTC cutoff. ISO-8601 UTC timestamps sort lexically, so a string >= works.
RECENT_CUTOFF=$(date -u -v-"${RECENT_DAYS}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -d "${RECENT_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
PRS_RECENT="[]"
for repo in $REPOS; do
  [ -d "$SOURCE_DIR/$repo/.git" ] || continue
  arr=$( (cd "$SOURCE_DIR/$repo" && gh pr list --author @me --state all --limit 30 \
          --json number,title,url,state,createdAt,updatedAt,mergedAt 2>/dev/null) )
  arr=$(printf '%s' "${arr:-[]}" | jq --arg repo "$repo" --arg cutoff "$RECENT_CUTOFF" 'map(
          select(($cutoff == "") or ((.updatedAt // .createdAt // "") >= $cutoff))
          + {repo:$repo})' 2>/dev/null || echo '[]')
  PRS_RECENT=$(jq -n --argjson a "$PRS_RECENT" --argjson b "${arr:-[]}" '$a + $b' 2>/dev/null || echo "$PRS_RECENT")
done

# ── PRs awaiting review — helper for a given search ─────────────────────────
collect_reviews() { # $1 = gh search string
  local search="$1" out="[]" arr
  for repo in $REPOS; do
    [ -d "$SOURCE_DIR/$repo/.git" ] || continue
    arr=$( (cd "$SOURCE_DIR/$repo" && gh pr list --search "$search" --state open --limit 30 \
            --json number,title,url,author,createdAt 2>/dev/null) )
    arr=$(printf '%s' "${arr:-[]}" | jq --arg repo "$repo" 'map({repo:$repo, number, title, url, createdAt, author: (.author.login // "")})' 2>/dev/null || echo '[]')
    out=$(jq -n --argjson a "$out" --argjson b "${arr:-[]}" '$a + $b' 2>/dev/null || echo "$out")
  done
  printf '%s' "$out"
}

PRS_REVIEW_DIRECT=$(collect_reviews "user-review-requested:@me sort:created-asc")
PRS_REVIEW_TEAM=$(collect_reviews "team-review-requested:$GH_TEAM sort:created-asc")

# dedup: a direct ask outranks a team ask — drop team entries that are also direct
PRS_REVIEW_TEAM=$(jq -n --argjson team "${PRS_REVIEW_TEAM:-[]}" --argjson direct "${PRS_REVIEW_DIRECT:-[]}" '
  ($direct | map("\(.repo)#\(.number)")) as $dk
  | $team | map(select(("\(.repo)#\(.number)") as $k | ($dk | index($k)) | not))' 2>/dev/null || echo "$PRS_REVIEW_TEAM")

# ── Jira (JQL form — the flag forms silently return nothing here) ───────────
JIRA_PROJECT="${JIRA_PROJECT:-YOUR_PROJECT}"
jira_json() { # $1 = JQL
  # jira-cli --plain pads short statuses (e.g. "Done", "To Do") with an EXTRA tab to
  # align the column, which shifts the summary into a later field. Collapse empty
  # tab-fields before positional assignment so summaries survive regardless of status width.
  jira issue list --project "$JIRA_PROJECT" -q "$1" --plain --columns key,status,summary --no-headers 2>/dev/null \
    | jq -R -s 'split("\n")
        | map(select(length>0)
              | (split("\t") | map(select(length>0))) as $f
              | {key:($f[0]//""), status:($f[1]//""), summary:($f[2:]|join(" "))})' 2>/dev/null
}
JIRA_OPEN=$(jira_json "assignee = currentUser() AND statusCategory != Done")
# NB: jira-cli's -q rejects an ORDER BY clause ("Expecting ',' but got 'ORDER'") — omit it.
JIRA_RECENT=$(jira_json "assignee = currentUser() AND updated >= -${JIRA_DAYS}d")

# ── calendar: today's timed events ──────────────────────────────────────────
JIRA_EMAIL="${JIRA_EMAIL:-}"
CAL=$(icalBuddy -f eventsToday 2>/dev/null \
  | perl -pe 's/\e\[[0-9;]*[mK]//g; s/\x{200b}//g' \
  | grep -E "^[[:space:]]*(• |[0-9]+:[0-9]+.*[AP]M)")
[ -n "$JIRA_EMAIL" ] && CAL=$(printf '%s\n' "$CAL" | sed "s/ ($JIRA_EMAIL)//")
CAL_JSON=$(printf '%s\n' "$CAL" | jq -R -s 'split("\n") | map(select(length>0))' 2>/dev/null)

# ── Task Backlog (raw markdown; callers parse the tier sections) ─────────────
BACKLOG=$(cat "$BACKLOG_FILE" 2>/dev/null)

# ── assemble ────────────────────────────────────────────────────────────────
jq -n \
  --arg today "$TODAY" --arg now "$NOW" --arg since "$SINCE" \
  --argjson git "${GIT_JSON:-[]}" \
  --argjson prs_authored "${PRS_AUTHORED:-[]}" \
  --argjson prs_recent "${PRS_RECENT:-[]}" \
  --argjson prs_review_direct "${PRS_REVIEW_DIRECT:-[]}" \
  --argjson prs_review_team "${PRS_REVIEW_TEAM:-[]}" \
  --argjson jira_open "${JIRA_OPEN:-[]}" \
  --argjson jira_recent "${JIRA_RECENT:-[]}" \
  --argjson calendar "${CAL_JSON:-[]}" \
  --arg backlog "$BACKLOG" \
  '{today:$today, now:$now, git_since:$since,
    git:$git, prs_authored:$prs_authored, prs_recent:$prs_recent,
    prs_review_direct:$prs_review_direct, prs_review_team:$prs_review_team,
    jira_open:$jira_open, jira_recent:$jira_recent,
    calendar:$calendar, backlog:$backlog}'
