#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IMPORTER="$ROOT/Scripts/import-legacy-parity.sh"
HEADER=$'source_path\tdestination_path\tsha256\tpurpose\tcopyright_owner\tlicense_or_authority\treviewer'
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CASE_NUMBER=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

new_case() {
  CASE_NUMBER=$((CASE_NUMBER + 1))
  CASE_ROOT="$TMP/$CASE_NUMBER-$1"
  LEGACY="$CASE_ROOT/legacy"
  REPO="$CASE_ROOT/repo"
  MANIFEST="$REPO/docs/provenance/legacy-source-import.tsv"
  mkdir -p "$LEGACY" "$(dirname "$MANIFEST")"
}

write_source() {
  local path="$1"
  local contents="$2"
  mkdir -p "$(dirname "$LEGACY/$path")"
  printf '%s' "$contents" > "$LEGACY/$path"
}

sha_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}

write_header() {
  printf '%s\n' "$HEADER" > "$MANIFEST"
}

append_row() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$MANIFEST"
}

append_valid_row() {
  local source="$1"
  append_row \
    "$source" "LegacyParity/$source" "$(sha_of "$LEGACY/$source")" \
    parity-source 'Example Owner' 'Authorized for Apache-2.0' 'Test Reviewer'
}

run_import() {
  (cd "$REPO" && "$IMPORTER" "$LEGACY" docs/provenance/legacy-source-import.tsv)
}

assert_no_staging() {
  local label="$1"
  local found
  found="$(find "$REPO" -maxdepth 1 -name '.LegacyParity.import.*' -print -quit)"
  [[ -z "$found" ]] || fail "$label left staging directory"
}

expect_rejected() {
  local label="$1"
  if run_import > "$CASE_ROOT/stdout" 2> "$CASE_ROOT/stderr"; then
    fail "$label was accepted"
  fi
  [[ ! -e "$REPO/LegacyParity" ]] || fail "$label published LegacyParity"
  assert_no_staging "$label"
}

mtime_of() {
  if stat -f '%m' "$1" >/dev/null 2>&1; then
    stat -f '%m' "$1"
  else
    stat -c '%Y' "$1"
  fi
}

# Happy path: byte/hash identity, metadata preservation, and a model-cache
# inspector source whose basename must not be mistaken for a cache directory.
new_case happy
write_source Sources/Main.swift $'let parity = true\n'
write_source Sources/WhisperModelCacheInspector.swift $'struct WhisperModelCacheInspector {}\n'
touch -t 202001020304.05 "$LEGACY/Sources/Main.swift"
write_header
append_valid_row Sources/Main.swift
append_valid_row Sources/WhisperModelCacheInspector.swift
run_import
cmp "$LEGACY/Sources/Main.swift" "$REPO/LegacyParity/Sources/Main.swift"
cmp "$LEGACY/Sources/WhisperModelCacheInspector.swift" "$REPO/LegacyParity/Sources/WhisperModelCacheInspector.swift"
[[ "$(sha_of "$REPO/LegacyParity/Sources/Main.swift")" == "$(sha_of "$LEGACY/Sources/Main.swift")" ]] || fail 'happy path changed file hash'
[[ "$(mtime_of "$REPO/LegacyParity/Sources/Main.swift")" == "$(mtime_of "$LEGACY/Sources/Main.swift")" ]] || fail 'cp -p did not preserve mtime'
assert_no_staging 'happy path'

# Destination traversal must neither publish the tree nor write elsewhere.
new_case destination-traversal
write_source payload.txt $'outside publication must be rejected\n'
write_header
append_row payload.txt LegacyParity/../outside.txt "$(sha_of "$LEGACY/payload.txt")" parity-source 'Example Owner' 'Authorized for Apache-2.0' 'Test Reviewer'
expect_rejected 'destination traversal'
[[ ! -e "$REPO/outside.txt" ]] || fail 'destination traversal wrote outside LegacyParity'

# Source traversal must not read a sibling of the declared legacy root.
new_case source-traversal
printf 'outside source must be rejected\n' > "$CASE_ROOT/outside.txt"
write_header
append_row ../outside.txt LegacyParity/Stolen.txt "$(sha_of "$CASE_ROOT/outside.txt")" parity-source 'Example Owner' 'Authorized for Apache-2.0' 'Test Reviewer'
expect_rejected 'source traversal'

# A symlinked source component that resolves outside the root must be rejected.
new_case symlink-escape
mkdir -p "$CASE_ROOT/outside"
printf 'symlink escape must be rejected\n' > "$CASE_ROOT/outside/secret.txt"
ln -s "$CASE_ROOT/outside" "$LEGACY/Escape"
write_header
append_row Escape/secret.txt LegacyParity/Escape/secret.txt "$(sha_of "$CASE_ROOT/outside/secret.txt")" parity-source 'Example Owner' 'Authorized for Apache-2.0' 'Test Reviewer'
expect_rejected 'symlink escape'

# A late bad hash must not leave the earlier valid row partially published.
new_case late-hash-failure
write_source Sources/First.swift $'let first = true\n'
write_source Sources/Second.swift $'let second = true\n'
write_header
append_valid_row Sources/First.swift
append_row Sources/Second.swift LegacyParity/Sources/Second.swift 0000000000000000000000000000000000000000000000000000000000000000 parity-source 'Example Owner' 'Authorized for Apache-2.0' 'Test Reviewer'
expect_rejected 'late-row hash failure'

# The schema is exact, every field is required, and the manifest needs a row.
new_case malformed-header
write_source Main.swift $'let value = 1\n'
printf '%s\textra_column\n' "$HEADER" > "$MANIFEST"
append_valid_row Main.swift
expect_rejected 'malformed header'

new_case malformed-column-count
write_source Main.swift $'let value = 1\n'
write_header
printf 'Main.swift\tLegacyParity/Main.swift\t%s\tparity-source\tExample Owner\tAuthorized for Apache-2.0\n' "$(sha_of "$LEGACY/Main.swift")" >> "$MANIFEST"
expect_rejected 'six-column row'

new_case empty-manifest
write_header
expect_rejected 'header-only manifest'

for empty_field in purpose owner authority reviewer; do
  new_case "empty-$empty_field"
  write_source Main.swift $'let value = 1\n'
  write_header
  purpose=parity-source
  owner='Example Owner'
  authority='Authorized for Apache-2.0'
  reviewer='Test Reviewer'
  case "$empty_field" in
    purpose) purpose= ;;
    owner) owner= ;;
    authority) authority= ;;
    reviewer) reviewer= ;;
  esac
  append_row Main.swift LegacyParity/Main.swift "$(sha_of "$LEGACY/Main.swift")" "$purpose" "$owner" "$authority" "$reviewer"
  expect_rejected "empty $empty_field"
done

new_case uppercase-digest
write_source Main.swift $'let value = 1\n'
write_header
uppercase_digest="$(sha_of "$LEGACY/Main.swift" | tr '[:lower:]' '[:upper:]')"
append_row Main.swift LegacyParity/Main.swift "$uppercase_digest" parity-source 'Example Owner' 'Authorized for Apache-2.0' 'Test Reviewer'
expect_rejected 'uppercase digest'

new_case short-digest
write_source Main.swift $'let value = 1\n'
write_header
append_row Main.swift LegacyParity/Main.swift deadbeef parity-source 'Example Owner' 'Authorized for Apache-2.0' 'Test Reviewer'
expect_rejected 'short digest'

# Duplicate source and destination entries are each rejected.
new_case duplicate-source
write_source Main.swift $'let value = 1\n'
write_header
append_valid_row Main.swift
append_valid_row Main.swift
expect_rejected 'duplicate source'

new_case duplicate-destination
write_source First.swift $'let first = true\n'
write_source Second.swift $'let second = true\n'
write_header
append_valid_row First.swift
append_row Second.swift LegacyParity/First.swift "$(sha_of "$LEGACY/Second.swift")" parity-source 'Example Owner' 'Authorized for Apache-2.0' 'Test Reviewer'
expect_rejected 'duplicate destination'

# Every forbidden category is exercised with a real file fixture. Matching is
# component/basename based so ordinary source names containing "ModelCache"
# remain valid, as covered by the happy path above.
for forbidden_path in \
  Metadata/.git/config \
  Cache/.build/object.o \
  Cache/.swiftpm/configuration \
  Artifacts/dist/application \
  Metadata/.DS_Store \
  Config/.env.production \
  secrets/api-token.txt \
  credentials.json \
  Keys/token.txt \
  Config/private-key.txt \
  Keys/private-key.pem \
  Cache/Models/model.bin \
  Cache/model-cache/model.bin \
  Installer/UtterInk.DmG
do
  new_case forbidden
  write_source "$forbidden_path" $'forbidden fixture\n'
  write_header
  append_valid_row "$forbidden_path"
  expect_rejected "forbidden path $forbidden_path"
done

printf 'legacy parity importer tests passed\n'
