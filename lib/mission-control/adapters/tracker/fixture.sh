#!/usr/bin/env bash
# fixture.sh — a file-backed tracker adapter (see ../CONTRACT.md).
#
# NOT a provider. It answers every tracker op from flat files on disk, so the engine can
# be exercised with no network, no credentials, and no live board. Two jobs:
#
#   1. It is the honesty test for the tracker boundary. If an engine script needs
#      anything beyond the five contract ops, it BREAKS here — a real second provider
#      (Linear) can then be written against a contract already proven to be sufficient,
#      rather than discovering the leak mid-integration.
#   2. It is the safe harness. Write scripts can be driven end-to-end against a scratch
#      state.json without a single call reaching the real tracker.
#
# It also simulates the CYCLE-LESS provider that consequence A reserves the seam for:
# drop `cycles` from the capabilities file and the degrade branches in mc-archive,
# mc-inbound, and mc-promote all light up, years before that adapter is written.
#
# Data dir: $MC_FIXTURES (default: <adapters>/../fixtures/example), holding
#
#   tracker/issues.tsv        key⇥status⇥assignee⇥cycle⇥vetted⇥summary
#                             cycle  = in | out   (membership of the active cycle)
#                             vetted = yes | no   (the estimate/points predicate)
#                             '#' comments and blank lines ignored
#   tracker/active_cycle.tsv  id⇥name — the open cycle. Missing/empty = no open cycle.
#   tracker/capabilities      space-separated; default "cycles vetting".
#
#   tracker list_ready "Ready for Dev" in
#   tracker list_ready "Ready for Dev" out vetted
#   tracker fields_of KEY-1 KEY-2
#   tracker in_active_cycle KEY-1 KEY-2
#   tracker active_cycle
#   tracker capabilities
set -uo pipefail

# Default data dir. NB the TWO levels up: this file sits in adapters/tracker/, so one `..`
# only reaches adapters/ — which is how the default silently pointed at a non-existent
# adapters/fixtures/example and made every op return empty (reading as "nothing ready"
# rather than "misconfigured").
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXROOT="${MC_FIXTURES:-$_here/fixtures/example}"
FIX="$FIXROOT/tracker"
# A missing data dir is a CONFIG error, not a degrade. The contract's "degrade, don't
# fail" rule covers unsupported OPS; it must not paper over fixtures that aren't there.
[ -d "$FIXROOT" ] || { echo "fixture(tracker): no fixture data dir at $FIXROOT (set MC_FIXTURES)" >&2; exit 2; }
# Whose tickets `list_ready` returns — the fixture stand-in for `currentUser()`.
ME="${MC_FIXTURE_ME:-me}"

op="${1:-}"; shift || true

# Strip comments/blanks so the data files can be annotated.
_rows() { [ -f "$FIX/issues.tsv" ] || return 0; grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$FIX/issues.tsv"; }

_caps() { if [ -f "$FIX/capabilities" ]; then tr -d '\n' < "$FIX/capabilities"; else printf 'cycles vetting'; fi; }
_has()  { case " $(_caps) " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# Normalize a space- or comma-joined key list to one key per line, for exact matching.
_keys() { printf '%s' "$*" | tr ' ,' '\n\n' | grep -v '^$'; }

case "$op" in
  list_ready)
    status="${1:-}"; cycle="${2:-any}"; vetted="${3:-}"
    [ -n "$status" ] || { echo "fixture list_ready: need a status" >&2; exit 2; }
    case "$cycle" in in|out|any) : ;; *) echo "fixture list_ready: cycle must be in|out|any" >&2; exit 2 ;; esac
    # Cycle-less degrade (contract): `in` = all ready, `out` = nothing to defer.
    if ! _has cycles; then
      [ "$cycle" = "out" ] && exit 0
      cycle=any
    fi
    # No vetting concept → the flag is ignored, per the contract.
    _has vetting || vetted=""
    _rows | awk -F'\t' -v me="$ME" -v st="$status" -v cy="$cycle" -v vt="$vetted" '
      $3 != me            { next }
      $2 != st            { next }
      cy != "any" && $4 != cy { next }
      vt == "vetted" && $5 != "yes" { next }
      { printf "%s\t%s\n", $1, $6 }'
    ;;

  fields_of)
    [ "$#" -gt 0 ] || exit 0
    _keys "$@" | sort -u > "${TMPDIR:-/tmp}/.mc-fx-keys.$$"
    _rows | awk -F'\t' 'NR==FNR{want[$0];next} ($1 in want){printf "%s\t%s\t%s\n",$1,$2,$3}' \
      "${TMPDIR:-/tmp}/.mc-fx-keys.$$" -
    rm -f "${TMPDIR:-/tmp}/.mc-fx-keys.$$"
    ;;

  in_active_cycle)
    [ "$#" -gt 0 ] || exit 0
    _has cycles || exit 0          # cycle-less → empty, so mc-promote no-ops
    _keys "$@" | sort -u > "${TMPDIR:-/tmp}/.mc-fx-keys.$$"
    _rows | awk -F'\t' 'NR==FNR{want[$0];next} ($1 in want) && $4=="in"{print $1}' \
      "${TMPDIR:-/tmp}/.mc-fx-keys.$$" -
    rm -f "${TMPDIR:-/tmp}/.mc-fx-keys.$$"
    ;;

  active_cycle)
    _has cycles || exit 0          # cycle-less → no rollover trigger
    [ -f "$FIX/active_cycle.tsv" ] || exit 0
    grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$FIX/active_cycle.tsv" | head -1
    ;;

  capabilities)
    _caps; echo
    ;;

  *)
    echo "fixture: unknown op '$op'" >&2; exit 2 ;;
esac
