#!/usr/bin/env bash
# Offline checks for prose-words.sh: what counts as prose, and the --check exit code.
# Run: bash prose-words.test.sh
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0
check() { # name, want, got
  if [ "$3" = "$2" ]; then pass=$((pass + 1)); echo "ok   $1"
  else fail=$((fail + 1)); printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"; fi
}
count() { printf '%b' "$1" | bash "$DIR/prose-words.sh" -; }

check "plain prose"               4 "$(count 'one two three four\n')"
check "fenced code is skipped"    1 "$(count 'one\n```\ntwo three\n```\n')"
check "a table is skipped"        1 "$(count 'one\n| a | b |\n| --- | --- |\n')"
check "a heading is skipped"      1 "$(count '## Evidence\none\n')"
check "the ticket line is skipped" 1 "$(count 'one\nTicket: ENG-1\nNo ticket: none\n')"
check "a generated-by footer is skipped" 1 "$(count 'one\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n')"
check "an html comment is skipped" 1 "$(count 'one\n<!-- two\nthree -->\n')"
check "a code span is one word"   3 "$(count 'run `a b c` now\n')"
check "a link counts its text"    2 "$(count '[two words](https://example.com/a/b)\n')"
check "list markers are not words" 2 "$(count '- one\n1. two\n')"
printf 'one two\n' | bash "$DIR/prose-words.sh" - --check 2 >/dev/null; check "at the cap passes" 0 "$?"
printf 'one two\n' | bash "$DIR/prose-words.sh" - --check 1 >/dev/null; check "over the cap fails" 1 "$?"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
