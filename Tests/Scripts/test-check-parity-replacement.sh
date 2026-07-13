#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
CHECKER="$ROOT/Scripts/check-parity-replacement.sh"
EVIDENCE="$ROOT/docs/parity/utterink-parity-evidence.md"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/utterink-parity-check-test.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

fail() {
  printf 'parity checker test failed: %s\n' "$1" >&2
  exit 1
}

SOURCE_COMMIT="$(
  sed -n 's/.*`\([0-9a-f][0-9a-f]*\)` (`test: cover product states and accessibility`).*/\1/p' "$EVIDENCE"
)"
if [[ ! "$SOURCE_COMMIT" =~ ^[0-9a-f]{7,40}$ ]]; then
  fail 'cannot read the evidence baseline commit'
fi

BASE_FIXTURE="$TMP/base"
mkdir -p "$BASE_FIXTURE"
git -C "$ROOT" archive HEAD -- \
  docs/parity/flowtype-behavior-baseline.md \
  docs/parity/accessibility-matrix.md \
  Packages/UtterInkKit/Tests \
  UtterInkAppTests \
  UtterInkUITests \
  | tar -x -C "$BASE_FIXTURE"

git -C "$BASE_FIXTURE" init -q
git -C "$BASE_FIXTURE" config user.name 'UtterInk Test'
git -C "$BASE_FIXTURE" config user.email 'utterink-test@example.invalid'
git -C "$BASE_FIXTURE" add -- .
git -C "$BASE_FIXTURE" \
  -c commit.gpgsign=false \
  commit -q -m 'fixture: parity baseline'
FIXTURE_COMMIT="$(git -C "$BASE_FIXTURE" rev-parse HEAD)"

mkdir -p "$BASE_FIXTURE/Scripts" "$BASE_FIXTURE/docs/parity"
cp "$CHECKER" "$BASE_FIXTURE/Scripts/check-parity-replacement.sh"
cp "$EVIDENCE" "$BASE_FIXTURE/docs/parity/utterink-parity-evidence.md"
chmod +x "$BASE_FIXTURE/Scripts/check-parity-replacement.sh"
SOURCE_COMMIT="$SOURCE_COMMIT" FIXTURE_COMMIT="$FIXTURE_COMMIT" perl -0pi -e '
  s/\Q$ENV{SOURCE_COMMIT}\E/$ENV{FIXTURE_COMMIT}/g
' "$BASE_FIXTURE/docs/parity/utterink-parity-evidence.md"

positive_output="$(
  cd "$BASE_FIXTURE"
  ./Scripts/check-parity-replacement.sh
)"
if [[ "$positive_output" != parity\ replacement\ evidence\ passed* ]]; then
  fail 'valid evidence fixture was rejected'
fi

new_case() {
  local label="$1"
  CASE_ROOT="$TMP/$label"
  mkdir -p "$CASE_ROOT"
  cp -R "$BASE_FIXTURE/." "$CASE_ROOT"
}

expect_rejected() {
  local label="$1"
  local expected="$2"
  if (
    cd "$CASE_ROOT"
    ./Scripts/check-parity-replacement.sh \
      >"$CASE_ROOT/stdout" \
      2>"$CASE_ROOT/stderr"
  ); then
    fail "$label was accepted"
  fi
  if ! grep -F -- "$expected" "$CASE_ROOT/stderr" >/dev/null; then
    sed 's/^/  /' "$CASE_ROOT/stderr" >&2
    fail "$label did not report $expected"
  fi
}

new_case package-filter
perl -pi -e '
  if (/^- \*\*P314\*\*/) {
    s/` —/ --filter DefinitelyNoMatchingTests` —/
  }
' "$CASE_ROOT/docs/parity/utterink-parity-evidence.md"
expect_rejected package-filter "uses unsupported Swift test argument '--filter'"

new_case package-specifier
perl -pi -e '
  if (/^- \*\*P314\*\*/) {
    s/` —/ --specifier UtterInkCoreTests.DictationReducerTests` —/
  }
' "$CASE_ROOT/docs/parity/utterink-parity-evidence.md"
expect_rejected package-specifier "uses unsupported Swift test argument '--specifier'"

new_case package-list
perl -pi -e '
  if (/^- \*\*P314\*\*/) {
    s/` —/ list` —/
  }
' "$CASE_ROOT/docs/parity/utterink-parity-evidence.md"
expect_rejected package-list "uses unsupported Swift test argument 'list'"

new_case xcode-skip-testing
perl -pi -e '
  if (/^- \*\*A94\*\*/) {
    s/(-only-testing:UtterInkAppTests)`/$1 -skip-testing:UtterInkAppTests\/ProviderPresentationTests`/
  }
' "$CASE_ROOT/docs/parity/utterink-parity-evidence.md"
expect_rejected xcode-skip-testing 'may not use -skip-testing'

new_case disguised-xcode-action
perl -pi -e '
  if (/^- \*\*U1\*\*/) {
    s/ test` —/ -resultBundlePath test build` —/
  }
' "$CASE_ROOT/docs/parity/utterink-parity-evidence.md"
expect_rejected disguised-xcode-action 'must execute exactly the xcodebuild test action'

new_case cross-type-test
perl -pi -e '
  if (/^\| floating-ui \|/) {
    s/FloatingWindowControllerTests\.testPanelIsNonactivatingKeyCapableAndEscapeUsesTypedIntent/FloatingRecorderMetricsTests.testPanelIsNonactivatingKeyCapableAndEscapeUsesTypedIntent/
  }
' "$CASE_ROOT/docs/parity/utterink-parity-evidence.md"
expect_rejected cross-type-test 'no cited test source declares that class and method'

new_case missing-evidence-path
perl -pi -e '
  if (/^\| lifecycle \|/) {
    s/`UtterInkUITests\/LaunchAndNavigationTests\.swift`/`UtterInkUITests\/MissingTests.swift`/
  }
' "$CASE_ROOT/docs/parity/utterink-parity-evidence.md"
expect_rejected missing-evidence-path 'cites a missing evidence path'

new_case pending-evidence
printf '\nPENDING review marker\n' >> "$CASE_ROOT/docs/parity/utterink-parity-evidence.md"
expect_rejected pending-evidence 'pending marker found'

new_case failing-matrix
perl -pi -e '
  if (/^\| Menu-bar popover \|/) {
    s/\*\*BLOCKED /\*\*FAIL /
  }
' "$CASE_ROOT/docs/parity/accessibility-matrix.md"
expect_rejected failing-matrix 'accessibility matrix contains a FAIL result'

printf 'parity replacement checker tests passed (10 cases)\n'
