#!/usr/bin/env bash
#
# gem-parents.sh: list the gems that depend on <gem> in a Gemfile.lock.
#
# Usage: gem-parents.sh <gem> <Gemfile.lock>
#
# Each dependency sits indented under the gem that needs it, so the parent is the nearest
# four-space entry above a six-space line naming <gem>. Reads the file only.

set -u
[ $# -eq 2 ] || { echo "usage: gem-parents.sh <gem> <Gemfile.lock>" >&2; exit 2; }
[ -f "$2" ] || { echo "no such file: $2" >&2; exit 2; }
awk -v g="$1" '/^    [^ ]/{p=$1} $1==g && /^      [^ ]/{print p}' "$2" | sort -u
