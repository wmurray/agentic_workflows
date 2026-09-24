#!/usr/bin/env bash
# jira.sh — the Jira implementation of the tracker adapter contract (see ../CONTRACT.md).
#
# Every op is READ-ONLY (jira issue/sprint list). Rows come back tab-separated with the
# `--plain` alignment padding squeezed out (`tr -s '\t'`) so field positions are stable
# regardless of column widths. The engine owns all board logic; this file only speaks
# Jira. Dispatch: `tracker <op> …` → this script with $1=op.
#
#   tracker list_ready "Ready for Dev" in          # $READY_STATUS, in the active cycle
#   tracker list_ready "Ready for Dev" out vetted   # out of cycle + vetted (background tier)
#   tracker fields_of KEY-1 KEY-2 KEY-3
#   tracker in_active_cycle KEY-1 KEY-2
#   tracker active_cycle
#   tracker detail_of KEY-1
#   tracker capabilities
set -uo pipefail

POINTS_FIELD="${MC_POINTS_FIELD:-Story Points}"

op="${1:-}"; shift || true

# Join args into a Jira `key in (…)` list: accepts space- or comma-separated input.
_keylist() { printf '%s' "$*" | tr ' ' ',' | tr -s ',' | sed 's/^,//;s/,$//'; }

case "$op" in
  list_ready)
    status="${1:-}"; cycle="${2:-any}"; vetted="${3:-}"
    [ -n "$status" ] || { echo "jira list_ready: need a status" >&2; exit 2; }
    q="assignee = currentUser() AND status = \"$status\""
    case "$cycle" in
      in)  q="$q AND sprint in openSprints()" ;;
      out) q="$q AND sprint not in openSprints()" ;;
      any) : ;;
      *)   echo "jira list_ready: cycle must be in|out|any" >&2; exit 2 ;;
    esac
    [ "$vetted" = "vetted" ] && q="$q AND \"$POINTS_FIELD\" is not EMPTY"
    jira issue list -q "$q" --plain --no-headers --columns key,summary 2>/dev/null | tr -s '\t'
    ;;

  fields_of)
    keys=$(_keylist "$@"); [ -n "$keys" ] || exit 0
    jira issue list -q "key in ($keys)" --plain --no-headers \
      --columns key,status,assignee 2>/dev/null | tr -s '\t'
    ;;

  in_active_cycle)
    keys=$(_keylist "$@"); [ -n "$keys" ] || exit 0
    jira issue list -q "key in ($keys) AND sprint in openSprints()" \
      --plain --no-headers --columns key 2>/dev/null | tr -s '\t'
    ;;

  active_cycle)
    # `jira sprint list --plain` columns: ID NAME START END COMPLETE STATE. tr -s
    # collapses padding so STATE is reliably the last field even when COMPLETE is empty.
    jira sprint list --plain --no-headers 2>/dev/null | tr -s '\t' \
      | awk -F'\t' '$NF=="active"{printf "%s\t%s\n",$1,$2; exit}'
    ;;

  detail_of)
    # One ticket's full detail (description, acceptance criteria, issue type, parent) as
    # plain text. The engine reads it at ingest to classify `type` and to brief a worker;
    # it does not parse fields out of it, so the layout is the CLI's own.
    key="${1:-}"; [ -n "$key" ] || { echo "jira detail_of: need a key" >&2; exit 2; }
    jira issue view "$key" --plain 2>/dev/null
    ;;

  capabilities)
    echo "cycles vetting"
    ;;

  *)
    echo "jira: unknown op '$op'" >&2; exit 2 ;;
esac
