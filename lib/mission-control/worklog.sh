#!/usr/bin/env bash
# worklog.sh — append-only, per-day work log (one JSON line per event).
#
# The journal skills (/daily, /eod, /sitrep) reconstruct the day from commits, PRs and
# tracker edits. Anything that leaves none of those — a review given, a release cut, a
# spike concluded, a board decision — is invisible to them. This file is the missing
# stream. Mechanical producers (the `mc` verbs, the inbox drain, the pipeline wrappers)
# append here so outward actions are logged whether anyone remembers or not; interactive
# sessions append a line at natural checkpoints.
#
#   worklog.sh add [--source S] [--ticket KEY] [--pr URL|#N] [--repo R] <text…>
#   worklog.sh today [--json]              # today's entries (human lines, or a JSON array)
#   worklog.sh show [--days N] [--json]    # last N days (default 1 = today)
#   worklog.sh path [YYYY-MM-DD]           # the file a day's entries live in
#
# Files:  $MC_WORKLOG_DIR/YYYY-MM-DD.jsonl  (default ~/.claude/worklog; local-time dates)
# Line:   {"ts","date","source","ticket","pr","repo","text"}  — ticket/pr/repo null if unset
# Env:    MC_WORKLOG=off  → `add` is a silent no-op (exit 0); reads still work
#         MC_WORKLOG_SOURCE → default --source (a wrapper sets its own name)
# Never fails a caller: a write error prints a warning and exits 0.
set -uo pipefail
DIR="${MC_WORKLOG_DIR:-$HOME/.claude/worklog}"
op="${1:-today}"; shift || true

_day_file() { printf '%s/%s.jsonl\n' "$DIR" "$1"; }
_today() { date +%Y-%m-%d; }
_days_ago() { date -v-"$1"d +%Y-%m-%d 2>/dev/null || date -d "$1 days ago" +%Y-%m-%d; }

_render() { # stdin: JSON lines → "HH:MM  [source]  KEY  text"
  jq -r '[(.ts | sub("^[^T]*T";"") | .[0:5]), "[" + .source + "]", (.ticket // "-"), .text] | @tsv' \
    | awk -F'\t' '{ printf "%s  %-14s %-9s %s\n", $1, $2, $3, $4 }'
}

case "$op" in
  add)
    [ "${MC_WORKLOG:-on}" = "off" ] && exit 0
    src="${MC_WORKLOG_SOURCE:-session}"; ticket=""; pr=""; repo=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --source) src="${2:-}"; shift ;;
        --ticket) ticket="${2:-}"; shift ;;
        --pr)     pr="${2:-}"; shift ;;
        --repo)   repo="${2:-}"; shift ;;
        --) shift; break ;;
        -*) echo "worklog: unknown flag '$1'" >&2; exit 2 ;;
        *) break ;;
      esac
      shift
    done
    text="$*"
    [ -n "$text" ] || { echo "worklog: add needs some text" >&2; exit 2; }
    # Infer a ticket key from the text when none was given (e.g. "merged ABC-1234 …").
    [ -n "$ticket" ] || ticket="$(printf '%s' "$text" | grep -oE '\b[A-Z][A-Z0-9]+-[0-9]+\b' | head -1 || true)"
    day="$(_today)"; f="$(_day_file "$day")"
    mkdir -p "$DIR" 2>/dev/null || { echo "worklog: cannot create $DIR" >&2; exit 0; }
    jq -cn --arg ts "$(date +%Y-%m-%dT%H:%M:%S%z)" --arg date "$day" --arg src "$src" \
           --arg ticket "$ticket" --arg pr "$pr" --arg repo "$repo" --arg text "$text" \
      '{ts:$ts, date:$date, source:$src,
        ticket:(if $ticket=="" then null else $ticket end),
        pr:(if $pr=="" then null else $pr end),
        repo:(if $repo=="" then null else $repo end),
        text:$text}' >> "$f" 2>/dev/null || { echo "worklog: write to $f failed" >&2; exit 0; }
    ;;
  today|show)
    days=1; json=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --json) json=1 ;;
        --days) days="${2:-1}"; shift ;;
        *) echo "worklog: unknown arg '$1'" >&2; exit 2 ;;
      esac
      shift
    done
    [ "$op" = today ] && days=1
    files=()
    i=$((days-1))
    while [ "$i" -ge 0 ]; do
      f="$(_day_file "$(_days_ago "$i")")"; [ -f "$f" ] && files+=("$f"); i=$((i-1))
    done
    if [ "${#files[@]}" -eq 0 ]; then
      [ -n "$json" ] && echo '[]' || echo "worklog: nothing logged."
      exit 0
    fi
    if [ -n "$json" ]; then cat "${files[@]}" | jq -s '.'; else cat "${files[@]}" | _render; fi
    ;;
  path)
    _day_file "${1:-$(_today)}"
    ;;
  -h|--help|help)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    echo "worklog: unknown op '$op' (add | today | show | path)" >&2; exit 2
    ;;
esac
