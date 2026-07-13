#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "$#" -ne 0 ]]; then
  printf 'unknown ci-local argument: %s\n' "$1" >&2
  exit 64
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

expected_origin="${UTTERINK_EXPECTED_ORIGIN:-}"
if [[ -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_REPOSITORY:-}" ]]; then
  expected_origin="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}.git"
fi

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
    LegacyParity/Package.resolved \
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
  for package_root in "$ROOT/LegacyParity" "$ROOT/Packages/UtterInkKit"; do
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
swift Scripts/generate-legacy-defaults-map.swift \
  --check \
  --input docs/provenance/legacy-defaults-map.tsv \
  --swift-output Packages/UtterInkKit/Sources/UtterInkServices/Generated/LegacyDefaultsMap.generated.swift

swift test \
  --package-path LegacyParity \
  --scratch-path "$TMP/LegacyParity-build" \
  --disable-sandbox \
  --force-resolved-versions
swift test \
  --package-path Packages/UtterInkKit \
  --scratch-path "$TMP/UtterInkKit-build" \
  --disable-sandbox \
  --force-resolved-versions

xcodegen generate
xcodebuild \
  -project UtterInk.xcodeproj \
  -scheme UtterInk \
  -derivedDataPath "$TMP/DerivedData" \
  -clonedSourcePackagesDirPath "$TMP/SourcePackages" \
  -resolvePackageDependencies
python3 Tests/Scripts/test-check-package-resolution.py
python3 Scripts/check-package-resolution.py
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

printf 'local verification passed\n'
