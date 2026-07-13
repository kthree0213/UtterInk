#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GENERATOR="$ROOT/Scripts/generate-legacy-defaults-map.swift"
BASE_MAP="$ROOT/docs/provenance/legacy-defaults-map.tsv"
HISTORICAL_COMMIT="17f7894f3e2c27a6cedea1b272c49e29a60121dd"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/utterink-legacy-map-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/swift-module-cache" "$TMP/clang-module-cache"
export SWIFT_MODULECACHE_PATH="$TMP/swift-module-cache"
export CLANG_MODULE_CACHE_PATH="$TMP/clang-module-cache"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[[ -f "$GENERATOR" ]] || fail 'generator does not exist'
[[ -f "$BASE_MAP" ]] || fail 'authority map does not exist'

case_number=0

materialize_historical_file() {
  local path="$1"
  local destination="$CASE_ROOT/$path"
  mkdir -p "$(dirname "$destination")"
  if ! git -C "$ROOT" show "$HISTORICAL_COMMIT:$path" > "$destination"; then
    fail "cannot materialize historical evidence: $path"
  fi
}

new_case() {
  local label="$1"
  case_number=$((case_number + 1))
  CASE_ROOT="$TMP/$case_number-$label"
  mkdir -p \
    "$CASE_ROOT/docs/provenance" \
    "$CASE_ROOT/LegacyParity/Sources/FlowType/Core" \
    "$CASE_ROOT/LegacyParity/Packaging" \
    "$CASE_ROOT/LegacyParity/Scripts" \
    "$CASE_ROOT/out"
  cp "$BASE_MAP" "$CASE_ROOT/docs/provenance/legacy-defaults-map.tsv"
  cp "$ROOT/docs/provenance/legacy-source-import.tsv" "$CASE_ROOT/docs/provenance/legacy-source-import.tsv"
  materialize_historical_file LegacyParity/Sources/FlowType/Core/LLMProviderProfiles.swift
  materialize_historical_file LegacyParity/Packaging/Info.plist
  materialize_historical_file LegacyParity/Packaging/FlowType.entitlements
  materialize_historical_file LegacyParity/Scripts/package-dmg.sh
  MAP="$CASE_ROOT/docs/provenance/legacy-defaults-map.tsv"
  OUTPUT="$CASE_ROOT/out/LegacyDefaultsMap.generated.swift"
}

run_generator() {
  (cd "$CASE_ROOT" && swift "$GENERATOR" "$@")
}

emit() {
  run_generator --emit --input docs/provenance/legacy-defaults-map.tsv --swift-output "$OUTPUT"
}

check() {
  run_generator --check --input docs/provenance/legacy-defaults-map.tsv --swift-output "$OUTPUT"
}

expect_rejected() {
  local label="$1"
  local expected="$2"
  shift 2
  if "$@" > "$CASE_ROOT/stdout" 2> "$CASE_ROOT/stderr"; then
    fail "$label was accepted"
  fi
  grep -F "$expected" "$CASE_ROOT/stderr" >/dev/null || {
    printf 'missing diagnostic for %s: %s\n' "$label" "$expected" >&2
    cat "$CASE_ROOT/stderr" >&2
    exit 1
  }
}

replace_manifest_hash() {
  local destination="$1"
  local hash="$2"
  awk -v destination="$destination" -v hash="$hash" 'BEGIN { FS = OFS = "\t" } $2 == destination { $3 = hash } { print }' \
    "$CASE_ROOT/docs/provenance/legacy-source-import.tsv" > "$CASE_ROOT/manifest.new"
  mv "$CASE_ROOT/manifest.new" "$CASE_ROOT/docs/provenance/legacy-source-import.tsv"
}

replace_map_evidence_hash() {
  local hash="$1"
  awk -v hash="$hash" 'BEGIN { FS = OFS = "\t" } NR > 1 { $10 = hash } { print }' \
    "$MAP" > "$CASE_ROOT/map.new"
  mv "$CASE_ROOT/map.new" "$MAP"
}

# Happy path: deterministic emission, exact check, and a read-only output prove
# that --check never opens the checked-in source for writing.
new_case valid
emit
cp "$OUTPUT" "$CASE_ROOT/out/first.swift"
cp "$OUTPUT" "$TMP/live-generated.swift"
emit
cmp "$CASE_ROOT/out/first.swift" "$OUTPUT" >/dev/null || fail 'two emits were not byte-identical'
check
before_hash="$(shasum -a 256 "$OUTPUT" | awk '{print $1}')"
chmod 0444 "$OUTPUT"
check
after_hash="$(shasum -a 256 "$OUTPUT" | awk '{print $1}')"
[[ "$before_hash" == "$after_hash" ]] || fail '--check modified its output'
chmod 0644 "$OUTPUT"

# Stale source must be rejected without repairing or otherwise editing it.
printf '// stale\n' >> "$OUTPUT"
stale_hash="$(shasum -a 256 "$OUTPUT" | awk '{print $1}')"
expect_rejected stale-output stale check
[[ "$(shasum -a 256 "$OUTPUT" | awk '{print $1}')" == "$stale_hash" ]] || fail '--check repaired stale output'

# Once the full snapshot is retired, the checked manifest and fixed hashes still
# produce the exact same Swift source without claiming to reread deleted files.
new_case retired
rm -rf "$CASE_ROOT/LegacyParity"
emit
cmp "$TMP/live-generated.swift" "$OUTPUT" >/dev/null || fail 'retired output differs from live-evidence output'
check

# The retired path still enforces the exact canonical row set and order.
new_case noncanonical-order
rm -rf "$CASE_ROOT/LegacyParity"
{
  sed -n '1p' "$MAP"
  sed -n '3p' "$MAP"
  sed -n '2p' "$MAP"
  sed -n '4,5p' "$MAP"
} > "$CASE_ROOT/map.new"
mv "$CASE_ROOT/map.new" "$MAP"
expect_rejected noncanonical-order 'canonical row order' emit

new_case duplicate
rm -rf "$CASE_ROOT/LegacyParity"
{
  sed -n '1p' "$MAP"
  sed -n '2p' "$MAP"
  sed -n '2p' "$MAP"
  sed -n '4,5p' "$MAP"
} > "$CASE_ROOT/map.new"
mv "$CASE_ROOT/map.new" "$MAP"
expect_rejected duplicate 'duplicate mappings are not allowed' emit

new_case unknown-key
rm -rf "$CASE_ROOT/LegacyParity"
awk 'BEGIN { FS = OFS = "\t" } NR == 5 { $2 = "shadowApiKey" } { print }' "$MAP" > "$CASE_ROOT/map.new"
mv "$CASE_ROOT/map.new" "$MAP"
expect_rejected unknown-key 'unknown legacy key or pattern' emit

# Every cited/imported artifact needs complete provenance rights and evidence.
new_case incomplete-rights
rm -rf "$CASE_ROOT/LegacyParity"
awk 'BEGIN { FS = OFS = "\t" } $2 == "LegacyParity/Sources/FlowType/Core/LLMProviderProfiles.swift" { $6 = "" } { print }' \
  "$CASE_ROOT/docs/provenance/legacy-source-import.tsv" > "$CASE_ROOT/manifest.new"
mv "$CASE_ROOT/manifest.new" "$CASE_ROOT/docs/provenance/legacy-source-import.tsv"
expect_rejected incomplete-rights 'incomplete import rights' emit

new_case retired-direct-hash-drift
rm -rf "$CASE_ROOT/LegacyParity"
replace_manifest_hash 'LegacyParity/Sources/FlowType/Core/LLMProviderProfiles.swift' 0000000000000000000000000000000000000000000000000000000000000000
expect_rejected retired-direct-hash-drift 'fixed direct-key authority' emit

new_case retired-support-hash-drift
rm -rf "$CASE_ROOT/LegacyParity"
replace_manifest_hash 'LegacyParity/Packaging/Info.plist' 0000000000000000000000000000000000000000000000000000000000000000
expect_rejected retired-support-hash-drift 'fixed packaging authority' emit

# Any extant snapshot path selects live validation. A partial tree must fail
# instead of silently falling back to retired-manifest validation.
new_case partial-snapshot
rm "$CASE_ROOT/LegacyParity/Packaging/Info.plist"
expect_rejected partial-snapshot 'missing evidence artifact' emit

new_case snapshot-root-symlink
rm -rf "$CASE_ROOT/LegacyParity"
ln -s missing-snapshot "$CASE_ROOT/LegacyParity"
expect_rejected snapshot-root-symlink 'symlink evidence path' emit

new_case evidence-hash-drift
printf '\n// drift\n' >> "$CASE_ROOT/LegacyParity/Sources/FlowType/Core/LLMProviderProfiles.swift"
expect_rejected evidence-hash-drift 'evidence hash drift' emit

# Even if a malicious edit updates both local hash declarations, a new
# secret-looking UserDefaults literal is not silently admitted.
new_case undocumented-secret-key
printf '\nlet undocumented = UserDefaults.standard.string(forKey: "shadowToken")\n' \
  >> "$CASE_ROOT/LegacyParity/Sources/FlowType/Core/LLMProviderProfiles.swift"
changed_hash="$(shasum -a 256 "$CASE_ROOT/LegacyParity/Sources/FlowType/Core/LLMProviderProfiles.swift" | awk '{print $1}')"
replace_manifest_hash 'LegacyParity/Sources/FlowType/Core/LLMProviderProfiles.swift' "$changed_hash"
replace_map_evidence_hash "$changed_hash"
expect_rejected undocumented-secret-key 'undocumented secret-looking defaults literal' emit

new_case path-traversal
awk 'BEGIN { FS = OFS = "\t" } NR == 2 { $9 = "../LegacyParity/Sources/FlowType/Core/LLMProviderProfiles.swift" } { print }' \
  "$MAP" > "$CASE_ROOT/map.new"
mv "$CASE_ROOT/map.new" "$MAP"
expect_rejected path-traversal 'normal repository-relative evidence path' emit

new_case symlink-evidence
mkdir -p "$CASE_ROOT/fixture-source"
mv "$CASE_ROOT/LegacyParity/Sources/FlowType/Core/LLMProviderProfiles.swift" "$CASE_ROOT/fixture-source/LLMProviderProfiles.swift"
ln -s "$CASE_ROOT/fixture-source/LLMProviderProfiles.swift" "$CASE_ROOT/LegacyParity/Sources/FlowType/Core/LLMProviderProfiles.swift"
expect_rejected symlink-evidence 'symlink evidence path' emit

new_case bundle-id-drift
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier dev.example.Wrong' "$CASE_ROOT/LegacyParity/Packaging/Info.plist"
changed_hash="$(shasum -a 256 "$CASE_ROOT/LegacyParity/Packaging/Info.plist" | awk '{print $1}')"
replace_manifest_hash 'LegacyParity/Packaging/Info.plist' "$changed_hash"
expect_rejected bundle-id-drift 'legacy bundle identifier' emit

new_case sandbox-drift
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.app-sandbox bool true' "$CASE_ROOT/LegacyParity/Packaging/FlowType.entitlements"
changed_hash="$(shasum -a 256 "$CASE_ROOT/LegacyParity/Packaging/FlowType.entitlements" | awk '{print $1}')"
replace_manifest_hash 'LegacyParity/Packaging/FlowType.entitlements' "$changed_hash"
expect_rejected sandbox-drift 'legacy app sandbox must be absent' emit

new_case signing-drift
sed 's/--entitlements "$ENTITLEMENTS" "$APP"/"$APP"/' "$CASE_ROOT/LegacyParity/Scripts/package-dmg.sh" > "$CASE_ROOT/package.new"
mv "$CASE_ROOT/package.new" "$CASE_ROOT/LegacyParity/Scripts/package-dmg.sh"
changed_hash="$(shasum -a 256 "$CASE_ROOT/LegacyParity/Scripts/package-dmg.sh" | awk '{print $1}')"
replace_manifest_hash 'LegacyParity/Scripts/package-dmg.sh' "$changed_hash"
expect_rejected signing-drift 'signing script entitlements/runtime relationship' emit

# Exercise the same literal escaping routine used by emission with control and
# delimiter characters that cannot occur in the fixed authority vocabulary.
new_case swift-escaping
sample=$'quote"back\\slash\nline\tend'
actual="$(run_generator --escape-test "$sample")"
expected='"quote\"back\\slash\nline\tend"'
[[ "$actual" == "$expected" ]] || fail "Swift escaping mismatch: $actual"

printf 'legacy defaults generator tests passed (%d cases)\n' "$case_number"
