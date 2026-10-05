#!/usr/bin/env bash
# Offline checks for upstream-repo.sh (repository URL forms) and changelog-since.sh (heading
# levels and version forms), the latter against a stub `gh` serving a canned CHANGELOG.md.
# Run: bash dependency-changelog.test.sh
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0
check() { # name, want, got
  if [ "$3" = "$2" ]; then pass=$((pass + 1)); echo "ok   $1"
  else fail=$((fail + 1)); printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"; fi
}

for form in github:acme/widget acme/widget git+https://github.com/acme/widget.git \
  git://github.com/acme/widget.git git@github.com:acme/widget.git \
  git+ssh://git@github.com/acme/widget.git https://github.com/acme/widget/tree/main/packages/x; do
  check "upstream-repo: $form" "acme/widget" "$(bash "$DIR/upstream-repo.sh" --url "$form" 2>&1)"
done
bash "$DIR/upstream-repo.sh" --url gitlab:acme/widget >/dev/null 2>&1
check "upstream-repo: gitlab is refused" 1 "$?"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dependency-changelog-test.XXXXXX")"
cleanup() { rm -f "${WORK:?}/bin/gh" "${WORK:?}/CHANGELOG.md"; rmdir "${WORK:?}/bin" "${WORK:?}"; }
trap cleanup EXIT
mkdir "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$2" in */contents/CHANGELOG.md) cat "$FIXTURE" ;; *) exit 1 ;; esac
STUB
chmod +x "$WORK/bin/gh"
cat > "$WORK/CHANGELOG.md" <<'MD'
# Changelog
## [Unreleased](https://example.com/compare/v3.0.0...main)
### 3.0.0 (2026-09-01)
#### Security fixes
- fixed a thing
## [2.31.0-beta.1]
- beta
## v2.31.0 - 2026-08-01
- compare link mentions [2.30.1](https://example.com/compare/v2.30.1...v2.31.0)
# [2.30.1](https://example.com/compare/v2.30.0...v2.30.1) (2026-07-01)
- older
MD
since() { PATH="$WORK/bin:$PATH" FIXTURE="$WORK/CHANGELOG.md" bash "$DIR/changelog-since.sh" o/r "$1" | grep -E '^#' | tr '\n' '|'; }
check "changelog: stops at a level-1 [x.y.z] heading, not at a compare link" \
  "# Changelog|## [Unreleased](https://example.com/compare/v3.0.0...main)|### 3.0.0 (2026-09-01)|#### Security fixes|## [2.31.0-beta.1]|## v2.31.0 - 2026-08-01|" "$(since 2.30.1)"
check "changelog: v-prefixed heading, not stopped by a pre-release" \
  "# Changelog|## [Unreleased](https://example.com/compare/v3.0.0...main)|### 3.0.0 (2026-09-01)|#### Security fixes|## [2.31.0-beta.1]|" "$(since v2.31.0)"
check "changelog: level-3 bare heading with a date" \
  "# Changelog|## [Unreleased](https://example.com/compare/v3.0.0...main)|" "$(since 3.0.0)"

echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
