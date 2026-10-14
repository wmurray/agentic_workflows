#!/usr/bin/env bash
# mc-pace.sh: pick the loop's next wake and log the tick to ticks.jsonl.
#
# The loop calls `record` once at the end of every tick. It appends one line to
# ticks.jsonl and prints the delay, in seconds, to pass to ScheduleWakeup when the loop
# runs as a dynamic /loop (no fixed interval). Under a fixed-interval cron the loop still
# records, for the log, and ignores the delay.
#
# Backoff, from the writes the tick reports:
#   a tick that wrote anything        -> 600  (10 min), idle streak back to 0
#   1st idle tick in a row            -> 1200 (20 min)
#   2nd and later idle ticks in a row -> 1800 (30 min)
#   an idle tick inside the night window (default 22:00-07:00) -> 3600 (60 min)
#   any row with a live worker caps the delay at 600, so its result is harvested promptly
#
# A writing tick always gets 600, night or day: whatever it started may need a follow-up.
#
#   mc-pace.sh record --writes <n> [--in-tokens <n>] [--out-tokens <n>]
#   mc-pace.sh reset      the next record schedules 600 whatever the tick did (`mc wake`)
#   mc-pace.sh show       the last ticks.jsonl line
#
# Token counts are optional. Without the flags they come from the newest transcript in
# MC_LOOP_TRANSCRIPT_DIR (usage summed per message id since the previous tick), and are
# null when that dir is unset or holds no transcript.
#
# MC_PACE_NOW (an epoch) stands in for the clock, for tests.
#
# Writes only its own files: $MC_HOME/.loop-pace (the idle streak), $MC_HOME/.loop-next-wake
# (epoch of the planned wake, read by dash.sh) and $MC_HOME/ticks.jsonl. Never state.json.
# Exit: 0 ok · 2 usage
set -uo pipefail

MC_HOME="${MC_HOME:-$HOME/.claude/mission-control}"
STATE="${MC_STATE:-$MC_HOME/state.json}"
TICKS="${MC_TICKS_LOG:-$MC_HOME/ticks.jsonl}"
PACE="${MC_PACE_FILE:-$MC_HOME/.loop-pace}"
NEXT="${MC_NEXT_WAKE_FILE:-$MC_HOME/.loop-next-wake}"
NIGHT_START="${MC_LOOP_NIGHT_START:-22}"
NIGHT_END="${MC_LOOP_NIGHT_END:-7}"

usage() { echo "usage: mc-pace.sh record --writes <n> [--in-tokens <n>] [--out-tokens <n>] | reset | show" >&2; exit 2; }

is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }

in_night() {
  local h=$((10#$1))
  if (( NIGHT_START > NIGHT_END )); then (( h >= NIGHT_START || h < NIGHT_END ))
  else (( h >= NIGHT_START && h < NIGHT_END )); fi
}

live_workers() {
  [ -r "$STATE" ] || { echo 0; return; }
  jq '[.tickets[]? | select(.lane != "done" and (.worker // null) != null)] | length' "$STATE" 2>/dev/null || echo 0
}

# Prints "<in> <out>", or "null null" when no transcript is readable.
transcript_tokens() {
  local since="$1" dir="${MC_LOOP_TRANSCRIPT_DIR:-}" f
  [ -n "$dir" ] && [ -d "$dir" ] || { echo "null null"; return; }
  f=$(ls -t "$dir"/*.jsonl 2>/dev/null | head -1)
  [ -n "$f" ] || { echo "null null"; return; }
  # Gotcha: a transcript repeats one message's usage on every content block it splits into,
  # so usage is summed once per message id.
  jq -rs --arg since "$since" '
    [ .[] | select(.type == "assistant" and (.timestamp // "") > $since and .message.usage != null) ]
    | unique_by(.message.id)
    | [ (map(.message.usage | (.input_tokens // 0) + (.cache_creation_input_tokens // 0)
                              + (.cache_read_input_tokens // 0)) | add // 0),
        (map(.message.usage.output_tokens // 0) | add // 0) ]
    | "\(.[0]) \(.[1])"' "$f" 2>/dev/null || echo "null null"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  reset)
    mkdir -p "$(dirname "$PACE")"
    echo reset > "$PACE"
    echo "mc-pace: the loop's next tick schedules a 10 min wake; the wake already scheduled stands"
    exit 0 ;;
  show)
    [ -r "$TICKS" ] && tail -1 "$TICKS" || echo "mc-pace: no ticks logged yet at $TICKS"
    exit 0 ;;
  record) ;;
  *) usage ;;
esac

writes="" tin="" tout=""
while [ $# -gt 0 ]; do
  case "$1" in
    --writes)     writes="${2:-}"; shift 2 ;;
    --in-tokens)  tin="${2:-}";    shift 2 ;;
    --out-tokens) tout="${2:-}";   shift 2 ;;
    *) usage ;;
  esac
done
is_int "$writes" || usage
[ -z "$tin" ] || is_int "$tin" || usage
[ -z "$tout" ] || is_int "$tout" || usage

mkdir -p "$(dirname "$TICKS")" "$(dirname "$PACE")" "$(dirname "$NEXT")"
now="${MC_PACE_NOW:-$(date +%s)}"
at=$(date -u -r "$now" '+%Y-%m-%dT%H:%M:%SZ')
hour=$(date -r "$now" '+%H')

pace=$(cat "$PACE" 2>/dev/null)
streak=$(printf '%s' "$pace" | tr -dc '0-9'); streak=${streak:-0}
workers=$(live_workers)

if (( writes > 0 )) || [ "$pace" = "reset" ]; then
  streak=0; delay=600
else
  streak=$((streak + 1))
  if in_night "$hour"; then delay=3600
  elif (( streak >= 2 )); then delay=1800
  else delay=1200; fi
fi
(( workers > 0 && delay > 600 )) && delay=600

if [ -z "$tin" ] || [ -z "$tout" ]; then
  since=$(tail -1 "$TICKS" 2>/dev/null | jq -r '.at // empty' 2>/dev/null)
  if [ -n "$since" ]; then read -r t_in t_out <<< "$(transcript_tokens "$since")"
  else t_in=null; t_out=null; fi
  tin="${tin:-$t_in}"; tout="${tout:-$t_out}"
fi

next=$((now + delay))
echo "$streak" > "$PACE"
echo "$next" > "$NEXT"
jq -cn --arg at "$at" --argjson writes "$writes" --argjson streak "$streak" \
  --argjson workers "$workers" --argjson tin "$tin" --argjson tout "$tout" \
  --argjson delay "$delay" --arg next "$(date -u -r "$next" '+%Y-%m-%dT%H:%M:%SZ')" \
  '{at:$at, idle:($writes == 0), writes:$writes, idle_streak:$streak, live_workers:$workers,
    in_tokens:$tin, out_tokens:$tout, next_wake_s:$delay, next_wake:$next}' >> "$TICKS"
echo "$delay"
