#!/usr/bin/env bash
#
# install-script-config.sh: say whether a repo runs dependency install scripts.
#
# Usage: install-script-config.sh <owner/repo>
#
# Reads .yarnrc.yml, .npmrc and .yarnrc from the repo's default branch through the GitHub
# API (read-only) and prints one line for the report. Pass {owner}/{repo} literally to let
# gh resolve it from the current checkout.

set -u
[ $# -eq 1 ] || { echo "usage: install-script-config.sh <owner/repo>" >&2; exit 2; }
repo="$1"

cfg() { gh api "repos/$repo/contents/$1" -H "Accept: application/vnd.github.raw" 2>/dev/null; }

if cfg .yarnrc.yml | grep -Eq '^[[:space:]]*enableScripts:[[:space:]]*false'; then
  echo "install scripts: disabled (enableScripts: false)"
elif { cfg .npmrc; cfg .yarnrc; } | grep -Eq '^[[:space:]]*ignore-scripts[[:space:]=]+"?true'; then
  echo "install scripts: disabled (ignore-scripts)"
else
  echo "install scripts: RUN on install and in CI"
fi
