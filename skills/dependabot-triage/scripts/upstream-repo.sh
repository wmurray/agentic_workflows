#!/usr/bin/env bash
#
# upstream-repo.sh: print the GitHub owner/repo an npm package's source lives in.
#
# Usage: upstream-repo.sh <npm package>
#        upstream-repo.sh --url <repository url or shorthand>
#
# Reads the package's `repository` field from the npm registry (a string or an object with
# .url) and normalises the forms npm allows: github:owner/repo, owner/repo,
# git+https://github.com/owner/repo.git, git://github.com/owner/repo.git,
# git+ssh://git@github.com/owner/repo.git, and git@github.com:owner/repo.git. Exit 1 with a
# message when the source is not on GitHub or the field is missing. Read-only.

set -u
usage() { echo "usage: upstream-repo.sh <npm package> | --url <repository url>" >&2; exit 2; }
[ $# -ge 1 ] || usage

if [ "$1" = --url ]; then
  [ $# -eq 2 ] || usage
  url="$2"
else
  [ $# -eq 1 ] || usage
  url=$(npm view "$1" repository --json 2>/dev/null |
    jq -r 'if type == "object" then (.url // empty) elif type == "string" then . else empty end' 2>/dev/null)
  [ -n "$url" ] || { echo "no repository field for $1" >&2; exit 1; }
fi

case "$url" in
  github:*) path="${url#github:}" ;;
  gitlab:* | bitbucket:* | gist:*) echo "not on GitHub: $url" >&2; exit 1 ;;
  *github.com[/:]*) path="${url#*github.com}"; path="${path#[/:]}" ;;
  *://* | *@*) echo "not on GitHub: $url" >&2; exit 1 ;;
  */*) path="$url" ;;
  *) echo "unrecognised repository: $url" >&2; exit 1 ;;
esac
path="${path%%#*}"
path="${path%.git}"
owner="${path%%/*}"
rest="${path#*/}"
name="${rest%%/*}"
name="${name%.git}"
[[ "$owner/$name" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "unrecognised repository: $url" >&2; exit 1; }
echo "$owner/$name"
