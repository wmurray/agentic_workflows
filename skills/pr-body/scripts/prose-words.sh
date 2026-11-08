#!/usr/bin/env bash
# Count the prose words in a PR body: everything outside fenced code, tables, headings,
# HTML comments and the closing Ticket / No ticket line. Inline code spans count as one
# word; a link counts its text, not its URL.
#
#   prose-words.sh <file|->               print the count
#   prose-words.sh <file|-> --check <n>   print it; exit 1 when over n
set -uo pipefail
src="${1:--}"; cap=""
[ "${2:-}" = --check ] && cap="${3:?--check needs a number}"
n=$(cat -- "$src" | awk '
  /^[ \t]*(```|~~~)/ { fence = !fence; next }
  fence { next }
  /<!--/ { comment = 1 }
  comment { if (/-->/) comment = 0; next }
  /^[ \t]*\|/ { next }
  /^#+[ \t]/ { next }
  /^(Ticket|No ticket):/ { next }
  { print }' |
  sed -E 's/`[^`]*`/CODE/g; s/!?\[([^]]*)\]\([^)]*\)/\1/g; s/https?:\/\/[^ )]+//g; s/^[ \t]*([-*+]|[0-9]+\.)[ \t]+//' |
  tr -s '[:space:]' '\n' | grep -cE '[[:alnum:]]')
echo "$n"
[ -z "$cap" ] || [ "$n" -le "$cap" ]
