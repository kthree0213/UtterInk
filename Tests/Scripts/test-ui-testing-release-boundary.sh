#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
cd "$ROOT"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/utterink-ui-boundary.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

python3 - \
  App/UtterInkApp.swift \
  App/AppComposition.swift \
  App/UITestSupport/UITestScenario.swift <<'PY'
from pathlib import Path
import re
import sys

markers = ("-uiTesting", "UITestScenario", ".uiTest(")
seen = {marker: 0 for marker in markers}

for raw_path in sys.argv[1:]:
    path = Path(raw_path)
    if not path.is_file():
        raise SystemExit(f"missing UI-test boundary source: {path}")

    # Each frame stores whether an outer branch is DEBUG-only and whether the
    # current directive directly selects DEBUG. This intentionally rejects
    # selector/fixture references in an #else branch of `#if DEBUG`.
    frames = []
    debug_guarded = False
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        directive = re.match(r"\s*#(if|elseif|else|endif)\b(.*)", line)
        if directive:
            kind, expression = directive.group(1), directive.group(2).strip()
            if kind == "if":
                direct_debug = expression == "DEBUG"
                frames.append((debug_guarded, direct_debug))
                debug_guarded = debug_guarded or direct_debug
            elif kind == "elseif":
                if not frames:
                    raise SystemExit(f"unbalanced #{kind} in {path}:{line_number}")
                outer, _ = frames[-1]
                direct_debug = expression == "DEBUG"
                frames[-1] = (outer, direct_debug)
                debug_guarded = outer or direct_debug
            elif kind == "else":
                if not frames:
                    raise SystemExit(f"unbalanced #else in {path}:{line_number}")
                outer, direct_debug = frames[-1]
                debug_guarded = outer if direct_debug else outer
            else:
                if not frames:
                    raise SystemExit(f"unbalanced #endif in {path}:{line_number}")
                outer, _ = frames.pop()
                debug_guarded = outer
            continue

        for marker in markers:
            if marker not in line:
                continue
            seen[marker] += 1
            if not debug_guarded:
                raise SystemExit(
                    f"UI-test selector or fixture escaped #if DEBUG in {path}:{line_number}"
                )

if seen["-uiTesting"] == 0 or seen["UITestScenario"] == 0 or seen[".uiTest("] == 0:
    raise SystemExit("UI-test source boundary is incomplete")
PY

python3 - \
  App/UITestSupport/UITestScenario.swift \
  UtterInkUITests/Support/UITestHarness.swift <<'PY'
from pathlib import Path
import re
import sys


def enum_cases(raw_path, enum_name):
    path = Path(raw_path)
    text = path.read_text(encoding="utf-8")
    declaration = re.search(rf"\benum\s+{re.escape(enum_name)}\b[^{{]*{{", text)
    if declaration is None:
        raise SystemExit(f"missing {enum_name} in {path}")

    depth = 1
    cases = []
    for line in text[declaration.end():].splitlines():
        if depth == 1:
            match = re.match(r"\s*case\s+([A-Za-z_][A-Za-z0-9_]*)\s*$", line)
            if match:
                cases.append(match.group(1))
        depth += line.count("{") - line.count("}")
        if depth == 0:
            break
    if not cases:
        raise SystemExit(f"no cases found for {enum_name} in {path}")
    return cases


app_cases = enum_cases(sys.argv[1], "UITestScenario")
harness_cases = enum_cases(sys.argv[2], "UITestScenarioName")
if app_cases != harness_cases:
    raise SystemExit(
        "UI-test scenario contract drifted:\n"
        f"  app:     {', '.join(app_cases)}\n"
        f"  harness: {', '.join(harness_cases)}"
    )
PY

DERIVED_DATA="${UTTERINK_UI_BOUNDARY_DERIVED_DATA_PATH:-$TMP/DerivedData}"
SOURCE_PACKAGES="${UTTERINK_CLONED_SOURCE_PACKAGES_DIR:-$TMP/SourcePackages}"

xcodebuild \
  -project UtterInk.xcodeproj \
  -scheme UtterInk \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
  CODE_SIGNING_ALLOWED=NO \
  build

APP="$DERIVED_DATA/Build/Products/Release/UtterInk.app"
BINARY="$APP/Contents/MacOS/UtterInk"
if [[ ! -f "$BINARY" ]]; then
  printf 'Release UtterInk binary was not produced\n' >&2
  exit 1
fi

for forbidden in \
  '-uiTesting' \
  'UITestCompositionFactory' \
  'UITestDictationController' \
  'polishFallback' \
  'targetChanged' \
  'historyActive' \
  'fixture.invalid' \
  'Deterministic polished retry' \
  '10000000-0000-0000-0000-000000000001' \
  'utterink-ui-delivering-raw-canary' \
  'utterink-ui-failed-raw-canary' \
  'utterink-ui-onboarding-raw-canary' \
  'utterink-ui-polish-fallback-raw-canary' \
  'utterink-ui-target-changed-raw-canary' \
  'utterink-ui-history-polished-canary' \
  'utterink-ui-history-fallback-canary'; do
  set +e
  LC_ALL=C grep -aFr -- "$forbidden" "$APP" >/dev/null 2>&1
  GREP_STATUS=$?
  set -e
  if [[ "$GREP_STATUS" -eq 0 ]]; then
    printf 'Release app contains a UI-test selector or fixture marker: %s\n' "$forbidden" >&2
    exit 1
  fi
  if [[ "$GREP_STATUS" -gt 1 ]]; then
    printf 'Release app scan failed while checking marker: %s\n' "$forbidden" >&2
    exit 1
  fi
done

printf 'DEBUG-only UI-test scenario contract and Release app boundary passed\n'
