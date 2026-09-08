#!/usr/bin/env bash
# fixture.sh — a file-backed host adapter (see ../CONTRACT.md).
#
# The host-side twin of tracker/fixture.sh: every op answered from disk, so the engine's
# PR/review logic runs with no network, no credentials, and no live repos. Same two jobs
# — prove the host boundary is sufficient, and give the write scripts a safe harness.
#
# Data dir: $MC_FIXTURES (default: <adapters>/../fixtures/example), holding
#
#   host/prs.json        {"owner/repo": [ <PR object>, … ], …}  — the list_prs superset
#                        schema. A repo with no entry returns [], exactly as a real host
#                        with no open PRs does.
#   host/threads.json    {"owner/repo#123": {reviewDecision, threads[], reviews[]}, …}
#                        A missing key returns the contract's empty shape (→ CLEAN).
#   host/whoami          the identity to print. Failure modes for exercising mc-health's
#                        classifier — put one of these in the file instead of a login:
#                          FAIL:auth  → 401/Bad credentials on stderr, exit 1  (→ auth)
#                          FAIL:net   → a network error on stderr, exit 1      (→ unreachable)
#                          FAIL:hang  → block forever, so the bounded runner must kill it
#                                       (→ unreachable via timeout, NOT auth)
#   host/capabilities    space-separated; default "review_threads". Drop it to exercise
#                        the no-review-threads degrade.
#
#   host list_prs owner/repo all
#   host list_prs owner/repo open mine
#   host review_threads owner/repo 123
#   host whoami
#   host capabilities
set -uo pipefail

# Default data dir. NB the TWO levels up: this file sits in adapters/host/, so one `..`
# only reaches adapters/ — which is how the default silently pointed at a non-existent
# adapters/fixtures/example and made every op return empty (reading as "nothing ready"
# rather than "misconfigured").
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXROOT="${MC_FIXTURES:-$_here/fixtures/example}"
FIX="$FIXROOT/host"
# A missing data dir is a CONFIG error, not a degrade. The contract's "degrade, don't
# fail" rule covers unsupported OPS; it must not paper over fixtures that aren't there.
[ -d "$FIXROOT" ] || { echo "fixture(host): no fixture data dir at $FIXROOT (set MC_FIXTURES)" >&2; exit 2; }
# Which author counts as "me" for the `mine` filter — the stand-in for `@me`.
ME="${MC_FIXTURE_ME:-me}"

op="${1:-}"; shift || true

_caps() { if [ -f "$FIX/capabilities" ]; then tr -d '\n' < "$FIX/capabilities"; else printf 'review_threads'; fi; }
_has()  { case " $(_caps) " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

case "$op" in
  list_prs)
    repo="${1:-}"; state="${2:-all}"; mine="${3:-}"
    [ -n "$repo" ] || { echo "fixture list_prs: need <owner/repo>" >&2; exit 2; }
    [ -f "$FIX/prs.json" ] || { echo '[]'; exit 0; }
    # State + author filtering happens HERE (the real host does it server-side), so the
    # engine sees the same pre-filtered array it gets from a live host.
    jq -c --arg repo "$repo" --arg state "$state" --arg mine "$mine" --arg me "$ME" '
      (.[$repo] // [])
      | map(select($state == "all" or ((.state // "OPEN") | ascii_downcase) == ($state | ascii_downcase)))
      | map(select($mine != "mine" or ((.author.login // "") == $me)))' "$FIX/prs.json" 2>/dev/null || echo '[]'
    ;;

  review_threads)
    repo="${1:-}"; num="${2:-}"
    [ -n "$repo" ] && [ -n "$num" ] || { echo "fixture review_threads: need <owner/repo> <num>" >&2; exit 2; }
    empty='{"reviewDecision":"none","threads":[],"reviews":[]}'
    # Unsupported optional op → the contract's empty shape, never an error.
    _has review_threads || { echo "$empty"; exit 0; }
    [ -f "$FIX/threads.json" ] || { echo "$empty"; exit 0; }
    jq -c --arg k "$repo#$num" --argjson empty "$empty" '.[$k] // $empty' "$FIX/threads.json" 2>/dev/null \
      || echo "$empty"
    ;;

  whoami)
    [ -f "$FIX/whoami" ] || { echo "$ME"; exit 0; }
    who="$(tr -d '\n' < "$FIX/whoami")"
    case "$who" in
      FAIL:auth) echo "HTTP 401: Bad credentials (fixture)" >&2; exit 1 ;;
      FAIL:net)  echo "dial tcp: connect: network is unreachable (fixture)" >&2; exit 1 ;;
      FAIL:hang) while :; do sleep 5; done ;;
      *)         printf '%s\n' "$who" ;;
    esac
    ;;

  capabilities)
    _caps; echo
    ;;

  *)
    echo "fixture: unknown op '$op'" >&2; exit 2 ;;
esac
