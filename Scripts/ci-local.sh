#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CI_MODE=0
UNSIGNED_PACKAGE_SMOKE=0
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --ci)
      if [[ "$CI_MODE" -eq 1 ]]; then
        printf 'duplicate ci-local argument: --ci\n' >&2
        exit 64
      fi
      CI_MODE=1
      ;;
    --unsigned-package-smoke)
      if [[ "$UNSIGNED_PACKAGE_SMOKE" -eq 1 ]]; then
        printf 'duplicate ci-local argument: --unsigned-package-smoke\n' >&2
        exit 64
      fi
      UNSIGNED_PACKAGE_SMOKE=1
      ;;
    *)
      printf 'unknown ci-local argument: %s\n' "$1" >&2
      exit 64
      ;;
  esac
  shift
done

expected_origin=""
if [[ "$CI_MODE" -eq 1 ]]; then
  if [[ -z "${GITHUB_SERVER_URL:-}" || -z "${GITHUB_REPOSITORY:-}" ]]; then
    printf 'CI mode requires GITHUB_SERVER_URL and GITHUB_REPOSITORY\n' >&2
    exit 66
  fi
  expected_origin="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}.git"
else
  expected_origin="${UTTERINK_EXPECTED_ORIGIN:-}"
  # Local verification never infers repository scope from ambient GitHub
  # variables. Only the explicit local contract above may define it.
  unset GITHUB_SERVER_URL GITHUB_REPOSITORY
fi
unset UTTERINK_EXPECTED_ORIGIN
case "$expected_origin" in
  *$'\n'*|*$'\r'*)
    printf 'expected origin contains a forbidden line break\n' >&2
    exit 66
    ;;
esac

XCODEGEN=xcodegen
if [[ "$CI_MODE" -eq 1 || "$UNSIGNED_PACKAGE_SMOKE" -eq 1 ]]; then
  XCODEGEN="$ROOT/Tools/bin/xcodegen"
  if [[ ! -f "$XCODEGEN" || ! -x "$XCODEGEN" || -L "$XCODEGEN" ]]; then
    printf 'locked XcodeGen is unavailable; run ./Scripts/bootstrap-xcodegen.sh first\n' >&2
    exit 65
  fi
  if [[ ! -f "$ROOT/Scripts/verify-toolchain.sh" || ! -x "$ROOT/Scripts/verify-toolchain.sh" || -L "$ROOT/Scripts/verify-toolchain.sh" ]]; then
    printf 'toolchain verifier is unavailable\n' >&2
    exit 65
  fi
  if [[ "$CI_MODE" -eq 1 ]]; then
    "$ROOT/Scripts/verify-toolchain.sh" --context ci
  else
    "$ROOT/Scripts/verify-toolchain.sh" --context local
  fi
fi

if [[ -e LegacyParity || -L LegacyParity ]]; then
  printf 'retired LegacyParity snapshot must remain absent\n' >&2
  exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/utterink-ci.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
case "$TMP" in
  "$ROOT"/*)
    printf 'temporary CI root must be outside the repository: %s\n' "$TMP" >&2
    exit 1
    ;;
esac
mkdir -p "$TMP/swift-module-cache" "$TMP/clang-module-cache"
export SWIFT_MODULECACHE_PATH="$TMP/swift-module-cache"
export CLANG_MODULE_CACHE_PATH="$TMP/clang-module-cache"
CACHE_CLEANUP_ENABLED=0

scan_public_history() {
  if [[ -n "$expected_origin" ]]; then
    ./Scripts/scan-public-history.sh --expected-origin "$expected_origin"
  else
    ./Scripts/scan-public-history.sh
  fi
}

assert_foundation_outputs_unchanged() {
  local generated_status
  git diff --exit-code -- \
    UtterInk.xcodeproj \
    App/Supporting/Info.plist \
    App/Supporting/UtterInk.entitlements \
    Tests/ATSPolicyProbe/Info.plist \
    Packages/UtterInkKit/Package.resolved
  generated_status="$(git status --short --untracked-files=all -- \
    UtterInk.xcodeproj \
    Tests/ATSPolicyProbe/Info.plist)"
  if [[ -n "$generated_status" ]]; then
    printf 'generated Xcode output has untracked output:\n%s\n' "$generated_status" >&2
    return 1
  fi
}

assert_no_repository_build_cache() {
  local paths="$TMP/repository-build-cache-paths"
  find "$ROOT" \
    -path "$ROOT/.git" -prune -o \
    -type d \( -iname '.build' -o -iname '.swiftpm' -o -iname 'DerivedData' \) \
    -print > "$paths"
  if [[ -s "$paths" ]]; then
    printf 'repository-local build/cache path found:\n' >&2
    while IFS= read -r path || [[ -n "$path" ]]; do
      printf '%s\n' "${path#"$ROOT"/}" >&2
    done < "$paths"
    return 1
  fi
}

cleanup_generated_repository_caches() {
  local package_root
  for package_root in "$ROOT/Packages/UtterInkKit"; do
    # Xcode can create these empty local-package state directories even when
    # DerivedData and cloned packages are redirected. rmdir intentionally
    # preserves any nonempty directory or user data for the residue gate.
    rmdir -- "$package_root/.swiftpm/xcode" 2>/dev/null || :
    rmdir -- "$package_root/.swiftpm/configuration" 2>/dev/null || :
    rmdir -- "$package_root/.swiftpm" 2>/dev/null || :
  done
}

cleanup() {
  local status=$?
  local cleanup_status=0
  trap - EXIT
  if [[ "$CACHE_CLEANUP_ENABLED" -eq 1 ]]; then
    cleanup_generated_repository_caches || cleanup_status=$?
  fi
  rm -rf "$TMP" || cleanup_status=$?
  if [[ "$status" -eq 0 && "$cleanup_status" -ne 0 ]]; then
    status="$cleanup_status"
  fi
  exit "$status"
}
trap cleanup EXIT

./Scripts/check-repo-hygiene.sh
assert_no_repository_build_cache
CACHE_CLEANUP_ENABLED=1
scan_public_history
bash Tests/Scripts/test-generate-import-manifest.sh
bash Tests/Scripts/test-scan-public-history.sh
bash Tests/Scripts/test-import-legacy-parity.sh
bash Tests/Scripts/test-check-repo-hygiene.sh
bash Tests/Scripts/test-generate-legacy-defaults-map.sh
bash Tests/Scripts/test-check-parity-replacement.sh
python3 Tests/Scripts/test-check-public-docs.py
python3 Tests/Scripts/test-release-metadata.py
python3 Tests/Scripts/test-release-entitlements.py
python3 Tests/Scripts/test-release-info-policy.py
bash Tests/Scripts/test-verify-candidate.sh
bash Tests/Scripts/test-build-candidate.sh
bash Tests/Scripts/test-sign-candidate.sh
bash Tests/Scripts/test-verify-signatures.sh
python3 Tests/Scripts/test-verify-workflow.py
bash Tests/Scripts/test-bootstrap-xcodegen.sh
bash Tests/Scripts/test-clean-distribution-output.sh
bash Tests/Scripts/test-package-unsigned-smoke.sh
bash Tests/Scripts/test-inspect-dmg.sh
python3 Scripts/release/read-metadata.py --json
python3 Scripts/release/verify-entitlements.py
python3 Scripts/release/verify-info-policy.py
python3 Scripts/verify-workflow.py
swift Scripts/generate-legacy-defaults-map.swift \
  --check \
  --input docs/provenance/legacy-defaults-map.tsv \
  --swift-output Packages/UtterInkKit/Sources/UtterInkServices/Generated/LegacyDefaultsMap.generated.swift
./Scripts/check-parity-replacement.sh

swift test \
  --package-path Packages/UtterInkKit \
  --scratch-path "$TMP/UtterInkKit-build" \
  --disable-sandbox \
  --force-resolved-versions

"$XCODEGEN" generate
xcodebuild \
  -project UtterInk.xcodeproj \
  -scheme UtterInk \
  -derivedDataPath "$TMP/DerivedData" \
  -clonedSourcePackagesDirPath "$TMP/SourcePackages" \
  -resolvePackageDependencies
python3 Tests/Scripts/test-check-package-resolution.py
python3 Scripts/check-package-resolution.py
python3 Scripts/check-public-docs.py
UTTERINK_NOTICE_SCRATCH_PATH="$TMP/UtterInkKit-build" \
  ./Scripts/collect-third-party-notices.sh --check
swift run \
  --package-path Packages/UtterInkKit \
  --scratch-path "$TMP/UtterInkKit-build" \
  --disable-sandbox \
  --force-resolved-versions \
  UtterInkIdentityExporter \
  --check \
  --lock Brand/identity-lock.json \
  --asset-catalog App/Resources/Assets.xcassets
assert_foundation_outputs_unchanged

xcodebuild \
  -project UtterInk.xcodeproj \
  -scheme UtterInk \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$TMP/DerivedData" \
  -clonedSourcePackagesDirPath "$TMP/SourcePackages" \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -project UtterInk.xcodeproj \
  -scheme UtterInk \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$TMP/DerivedData" \
  -clonedSourcePackagesDirPath "$TMP/SourcePackages" \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO \
  test \
  -only-testing:UtterInkAppTests

xcodebuild \
  -project UtterInk.xcodeproj \
  -scheme UtterInk \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$TMP/DerivedData" \
  -clonedSourcePackagesDirPath "$TMP/SourcePackages" \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO \
  test \
  -only-testing:UtterInkUITests/LaunchAndNavigationTests/testIdleScenarioShowsReadyStartActionAndSettingsRoutes \
  -only-testing:UtterInkUITests/PipelineStateTests/testRecordingScenarioShowsStopAndCancelActions

UTTERINK_CLONED_SOURCE_PACKAGES_DIR="$TMP/SourcePackages" \
  bash Tests/Scripts/test-ats-policy.sh

UTTERINK_CLONED_SOURCE_PACKAGES_DIR="$TMP/SourcePackages" \
UTTERINK_UI_BOUNDARY_DERIVED_DATA_PATH="$TMP/ReleaseDerivedData" \
  bash Tests/Scripts/test-ui-testing-release-boundary.sh

if /usr/libexec/PlistBuddy \
  -c 'Print :NSAppTransportSecurity:NSAllowsArbitraryLoads' \
  App/Supporting/Info.plist >/dev/null 2>&1; then
  printf 'global arbitrary loads must be absent\n' >&2
  exit 1
fi

python3 Scripts/check-package-resolution.py
assert_foundation_outputs_unchanged
cleanup_generated_repository_caches
assert_no_repository_build_cache
git diff --check
./Scripts/check-repo-hygiene.sh
scan_public_history

if [[ "$UNSIGNED_PACKAGE_SMOKE" -eq 1 ]]; then
  package_arguments=(
    --commit "$(git rev-parse --verify HEAD)"
    --output dist/unsigned-smoke
  )
  if [[ -n "$expected_origin" ]]; then
    package_arguments+=(--expected-origin "$expected_origin")
  fi
  ./Scripts/package-unsigned-smoke.sh "${package_arguments[@]}"
fi

printf 'local verification passed\n'
