#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCANNER="$ROOT/Scripts/scan-public-history.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1

case_number=0
last_stdout=''
last_stderr=''

new_repo() {
  local name="$1"
  local repo="$TMP/$name"
  mkdir -p "$repo"
  git -c init.defaultBranch=main -C "$repo" init -q
  git -C "$repo" config user.name 'History Scanner Test'
  git -C "$repo" config user.email 'scanner@example.invalid'
  printf 'safe fixture\n' > "$repo/safe.txt"
  git -C "$repo" add safe.txt
  git -C "$repo" commit -qm 'initial fixture'
  printf '%s\n' "$repo"
}

capture_scan() {
  local repo="$1"
  shift
  case_number=$((case_number + 1))
  last_stdout="$TMP/scan-$case_number.stdout"
  last_stderr="$TMP/scan-$case_number.stderr"
  set +e
  (cd "$repo" && "$SCANNER" "$@") > "$last_stdout" 2> "$last_stderr"
  scan_status=$?
  set -e
}

assert_diagnostics_are_redacted() {
  local diagnostics="$1"
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^finding\ category=[a-z0-9-]+\ (file|object)=[A-Za-z0-9._:@/+,-]+(\ line=[1-9][0-9]*)?$ ]] || {
      echo "non-redacted diagnostic shape: $line" >&2
      exit 1
    }
  done < "$diagnostics"
}

assert_category_line() {
  local category="$1"
  local expected_line="$2"
  local found=0
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *"category=$category "* ]] || continue
    found=1
    [[ "$line" == *" line=$expected_line" ]] || {
      echo "category $category omitted its first matching line" >&2
      exit 1
    }
  done < "$last_stderr"
  [[ "$found" -eq 1 ]] || {
    echo "missing category $category for line assertion" >&2
    exit 1
  }
}

expect_pass() {
  local repo="$1"
  shift
  capture_scan "$repo" "$@"
  if [[ "$scan_status" -ne 0 ]]; then
    echo "expected clean scan to pass" >&2
    cat "$last_stdout" >&2
    cat "$last_stderr" >&2
    exit 1
  fi
  [[ ! -s "$last_stderr" ]] || {
    echo 'clean scan emitted diagnostics' >&2
    cat "$last_stderr" >&2
    exit 1
  }
}

expect_failure() {
  local repo="$1"
  local category="$2"
  shift 2
  capture_scan "$repo" "$@"
  if [[ "$scan_status" -eq 0 ]]; then
    echo "expected category $category to fail" >&2
    exit 1
  fi
  grep -F "category=$category " "$last_stderr" >/dev/null || {
    echo "missing expected category $category" >&2
    cat "$last_stderr" >&2
    exit 1
  }
  assert_diagnostics_are_redacted "$last_stderr"
}

assert_value_redacted() {
  local value="$1"
  if grep -F -- "$value" "$last_stdout" "$last_stderr" >/dev/null; then
    echo 'scanner echoed a matched value' >&2
    exit 1
  fi
}

write_manifest() {
  local repo="$1"
  local sha="$2"
  local owner="$3"
  local authority="$4"
  local reviewer="$5"
  mkdir -p "$repo/docs/provenance"
  printf 'source_path\tdestination_path\tsha256\tpurpose\tcopyright_owner\tlicense_or_authority\treviewer\n' > "$repo/docs/provenance/legacy-source-import.tsv"
  printf 'Sources/App/Main.swift\tLegacyParity/Sources/App/Main.swift\t%s\tparity-source\t%s\t%s\t%s\n' \
    "$sha" "$owner" "$authority" "$reviewer" >> "$repo/docs/provenance/legacy-source-import.tsv"
}

# A clean, single-root repository passes with no remote.
clean_repo="$(new_repo clean)"
expect_pass "$clean_repo"

# The canonical credential-bearing URL used in endpoint-rejection documentation
# is an allowed placeholder, while any non-placeholder credential URL still
# fails and remains redacted.
placeholder_repo="$(new_repo credential-url-placeholder)"
placeholder_url="$(printf '%s%s' 'https://user:' 'pass@example.com/v1')"
printf '%s\n' "$placeholder_url" > "$placeholder_repo/endpoint-rejection.txt"
git -C "$placeholder_repo" add endpoint-rejection.txt
git -C "$placeholder_repo" commit -qm 'document rejected endpoint placeholder'
expect_pass "$placeholder_repo"

credential_url_repo="$(new_repo credential-url-secret)"
credential_url="$(printf '%s%s' 'https://build-user:' 'not-a-placeholder@example.invalid/v1')"
printf '%s\n' "$credential_url" > "$credential_url_repo/endpoint.txt"
expect_failure "$credential_url_repo" common-token
assert_value_redacted "$credential_url"

# The documented API-key placeholder and an empty assignment are exact safe
# examples. Any other nonempty assignment is handled as a credential even when
# its value is too short for token-prefix heuristics.
api_key_name="$(printf '%s%s' 'api' 'Key')"
api_key_placeholder="$(printf '%s%s' '..' '.')"
api_key_examples_repo="$(new_repo api-key-examples)"
printf 'profile.%s = ""\nprofile.%s = "%s"\nprofile.%s =\n  ""\nprofile.%s =\n  "%s"\n' \
  "$api_key_name" "$api_key_name" "$api_key_placeholder" \
  "$api_key_name" "$api_key_name" "$api_key_placeholder" > "$api_key_examples_repo/examples.swift"
git -C "$api_key_examples_repo" add examples.swift
git -C "$api_key_examples_repo" commit -qm 'add safe API key examples'
expect_pass "$api_key_examples_repo"

# Splitting an assignment before its quoted value cannot bypass the hardcoded
# API-key rule. The diagnostic reports the assignment's first line.
multiline_api_key_repo="$(new_repo multiline-api-key)"
multiline_api_key="$(printf '%s%s' 'q' '7')"
printf 'safe introduction\nprofile.%s =\n  "%s"\n' \
  "$api_key_name" "$multiline_api_key" > "$multiline_api_key_repo/Profile.swift"
expect_failure "$multiline_api_key_repo" provider-credential
assert_category_line provider-credential 2
assert_value_redacted "$multiline_api_key"

# One exact synthetic provider canary is used by the diagnostics-redaction
# suite and is not a credential. A longer value with the same prefix must not
# inherit that exception.
provider_canary="$(printf '%s%s' 'sk-canary-' 'transcript-path-query')"
provider_canary_repo="$(new_repo provider-canary-placeholder)"
printf '%s\n' "$provider_canary" > "$provider_canary_repo/diagnostics-fixture.swift"
git -C "$provider_canary_repo" add diagnostics-fixture.swift
git -C "$provider_canary_repo" commit -qm 'add synthetic diagnostics canary'
expect_pass "$provider_canary_repo"

extended_provider_canary_repo="$(new_repo extended-provider-canary)"
extended_provider_canary="${provider_canary}-extra"
printf '%s\n' "$extended_provider_canary" > "$extended_provider_canary_repo/provider.txt"
expect_failure "$extended_provider_canary_repo" provider-credential
assert_value_redacted "$extended_provider_canary"

# Token matching starts at a token boundary so ordinary hyphenated prose such
# as an internal task status cannot be misclassified as an sk-prefixed key.
boundary_repo="$(new_repo provider-token-boundary)"
printf '%s\n' 'task-1-candidate-not-final' > "$boundary_repo/status.txt"
git -C "$boundary_repo" add status.txt
git -C "$boundary_repo" commit -qm 'add non-token status text'
expect_pass "$boundary_repo"

# No remote is allowed by default. Exactly one credential-free origin is allowed
# only when its canonical URL is supplied explicitly.
origin_repo="$(new_repo origin)"
origin_url='https://example.invalid/utterink.git'
git -C "$origin_repo" remote add origin "$origin_url"
expect_failure "$origin_repo" unauthorized-remote
expect_pass "$origin_repo" --expected-origin "$origin_url"
git -C "$origin_repo" remote add mirror 'https://example.invalid/mirror.git'
expect_failure "$origin_repo" unauthorized-remote --expected-origin "$origin_url"

# Forbidden/private paths are rejected even when they are only in the worktree.
private_path_repo="$(new_repo private-path)"
printf 'benign contents\n' > "$private_path_repo/.env"
expect_failure "$private_path_repo" private-path

# Forbidden path matching follows the public validator's case-folded component
# rules across worktree, index, and historical trees.
lowercase_models_repo="$(new_repo lowercase-models-path)"
mkdir -p "$lowercase_models_repo/models"
printf 'benign model fixture\n' > "$lowercase_models_repo/models/weights.bin"
expect_failure "$lowercase_models_repo" private-path

indexed_envrc_repo="$(new_repo indexed-envrc-path)"
printf 'benign environment fixture\n' > "$indexed_envrc_repo/.envrc"
git -C "$indexed_envrc_repo" add -f .envrc
rm -f "$indexed_envrc_repo/.envrc"
expect_failure "$indexed_envrc_repo" private-path

historical_xcuserdata_repo="$(new_repo historical-xcuserdata-path)"
mkdir -p "$historical_xcuserdata_repo/Example.xcodeproj/xcuserdata/example.xcuserdatad"
printf 'benign Xcode fixture\n' > "$historical_xcuserdata_repo/Example.xcodeproj/xcuserdata/example.xcuserdatad/settings.plist"
git -C "$historical_xcuserdata_repo" add Example.xcodeproj
git -C "$historical_xcuserdata_repo" commit -qm 'add private Xcode user fixture'
git -C "$historical_xcuserdata_repo" rm -qrf Example.xcodeproj
git -C "$historical_xcuserdata_repo" commit -qm 'delete private Xcode user fixture'
expect_failure "$historical_xcuserdata_repo" private-path

mixed_case_private_repo="$(new_repo mixed-case-private-path)"
mkdir -p "$mixed_case_private_repo/MoDeLs"
printf 'benign mixed-case fixture\n' > "$mixed_case_private_repo/MoDeLs/weights.bin"
expect_failure "$mixed_case_private_repo" private-path

# Local file URLs are rejected only at explicit public-facing paths. The first
# match is reported by line without echoing the URL, while a committed internal
# source fixture with the same value remains outside this path-scoped rule.
local_file_url="$(printf '%s%s' 'file' ':///private/tmp/private-note.txt')"
public_file_url_repo="$(new_repo public-file-url)"
printf 'safe public introduction\n%s\n%s\n' "$local_file_url" "$local_file_url" > "$public_file_url_repo/README.md"
expect_failure "$public_file_url_repo" file-url
assert_category_line file-url 2
assert_value_redacted "$local_file_url"

uppercase_file_url="$(printf '%s%s' 'FILE' ':///private/tmp/private-note.txt')"
uppercase_file_url_repo="$(new_repo uppercase-public-file-url)"
printf 'safe public introduction\n%s\n' "$uppercase_file_url" > "$uppercase_file_url_repo/README.md"
expect_failure "$uppercase_file_url_repo" file-url
assert_category_line file-url 2
assert_value_redacted "$uppercase_file_url"

internal_file_url_repo="$(new_repo internal-file-url)"
mkdir -p "$internal_file_url_repo/Tests/Fixtures"
printf '%s\n' "$local_file_url" > "$internal_file_url_repo/Tests/Fixtures/local-url.txt"
git -C "$internal_file_url_repo" add Tests/Fixtures/local-url.txt
git -C "$internal_file_url_repo" commit -qm 'add non-public local URL fixture'
expect_pass "$internal_file_url_repo"

# The index blob is checked with its public path even when the worktree has
# already been replaced by safe content.
indexed_file_url_repo="$(new_repo indexed-file-url)"
printf 'safe staged introduction\n%s\n' "$local_file_url" > "$indexed_file_url_repo/README.md"
git -C "$indexed_file_url_repo" add README.md
printf 'safe worktree replacement\n' > "$indexed_file_url_repo/README.md"
expect_failure "$indexed_file_url_repo" file-url
assert_category_line file-url 2
assert_value_redacted "$local_file_url"

# The index is scanned independently from the worktree.
staged_repo="$(new_repo staged)"
staged_token="$(printf '%s%s' 'ghp' '_ABCDEFGHIJKLMNOPQRSTUVWXYZ123456')"
printf '%s\n' "$staged_token" > "$staged_repo/staged.txt"
git -C "$staged_repo" add staged.txt
printf 'safe worktree replacement\n' > "$staged_repo/staged.txt"
expect_failure "$staged_repo" common-token
assert_value_redacted "$staged_token"

# Private-key PEM headers and another common token form are classified without
# printing either matched value.
signature_repo="$(new_repo signatures)"
pem_header="$(printf '%s%s%s' '-----BEGIN ' 'PRIVATE KEY' '-----')"
aws_token="$(printf '%s%s' 'AK' 'IA0123456789ABCDEF')"
printf '%s\n%s\n' "$pem_header" "$aws_token" > "$signature_repo/signatures.txt"
expect_failure "$signature_repo" private-key
grep -F 'category=common-token ' "$last_stderr" >/dev/null
assert_value_redacted "$pem_header"
assert_value_redacted "$aws_token"

# Reachable history is scanned even after a credential-bearing file is deleted.
deleted_repo="$(new_repo committed-deleted)"
provider_token="$(printf '%s%s' 'sk-or-' 'v1-0123456789abcdef0123456789abcdef')"
printf '%s\n' "$provider_token" > "$deleted_repo/provider.txt"
git -C "$deleted_repo" add provider.txt
git -C "$deleted_repo" commit -qm 'add provider fixture'
git -C "$deleted_repo" rm -q provider.txt
git -C "$deleted_repo" commit -qm 'delete provider fixture'
expect_failure "$deleted_repo" provider-credential
assert_value_redacted "$provider_token"

# A short non-placeholder API-key assignment remains detectable after the file
# is deleted from reachable history; prefix-length heuristics cannot excuse it.
deleted_api_key_repo="$(new_repo committed-deleted-api-key)"
short_api_key="$(printf '%s%s' 'q' '7')"
printf 'safe introduction\nprofile.%s = "%s"\n' "$api_key_name" "$short_api_key" > "$deleted_api_key_repo/Profile.swift"
git -C "$deleted_api_key_repo" add Profile.swift
git -C "$deleted_api_key_repo" commit -qm 'add API key fixture'
git -C "$deleted_api_key_repo" rm -q Profile.swift
git -C "$deleted_api_key_repo" commit -qm 'delete API key fixture'
expect_failure "$deleted_api_key_repo" provider-credential
assert_category_line provider-credential 2
assert_value_redacted "$short_api_key"

# A public-path local URL is likewise found in a deleted but reachable tree.
deleted_file_url_repo="$(new_repo committed-deleted-file-url)"
printf 'safe introduction\n%s\n' "$local_file_url" > "$deleted_file_url_repo/README.md"
git -C "$deleted_file_url_repo" add README.md
git -C "$deleted_file_url_repo" commit -qm 'add public local URL fixture'
git -C "$deleted_file_url_repo" rm -q README.md
git -C "$deleted_file_url_repo" commit -qm 'delete public local URL fixture'
expect_failure "$deleted_file_url_repo" file-url
assert_category_line file-url 2
assert_value_redacted "$local_file_url"

# A tree named directly by a tag is a public path root even when the same tree
# also appears as a child of a commit root.
tagged_tree_repo="$(new_repo tagged-public-tree-root)"
mkdir -p "$tagged_tree_repo/nested-public-root"
printf 'safe public introduction\n%s\n' "$local_file_url" > "$tagged_tree_repo/nested-public-root/README.md"
git -C "$tagged_tree_repo" add nested-public-root/README.md
git -C "$tagged_tree_repo" commit -qm 'add nested tree fixture'
tagged_tree_oid="$(git -C "$tagged_tree_repo" rev-parse HEAD:nested-public-root)"
git -C "$tagged_tree_repo" tag public-tree-root "$tagged_tree_oid"
expect_failure "$tagged_tree_repo" file-url
assert_category_line file-url 2
assert_value_redacted "$local_file_url"

# Unreachable loose/packed objects remain in scope after branch deletion.
unreachable_repo="$(new_repo unreachable)"
transcript_canary="$(printf '%s%s' 'TRANSCRIPT_' 'CANARY_0123456789ABCDEF')"
git -C "$unreachable_repo" checkout -qb scratch
printf '%s\n' "$transcript_canary" > "$unreachable_repo/transcript.txt"
git -C "$unreachable_repo" add transcript.txt
git -C "$unreachable_repo" commit -qm 'temporary transcript fixture'
git -C "$unreachable_repo" checkout -q main
git -C "$unreachable_repo" branch -qD scratch
git -C "$unreachable_repo" reflog expire --expire=now --all
git -C "$unreachable_repo" repack -q -a -d --keep-unreachable
git -C "$unreachable_repo" prune-packed
expect_failure "$unreachable_repo" transcript-canary
assert_value_redacted "$transcript_canary"

# A generic sk-prefixed provider token remains in scope when its commit and
# root tree become unreachable. Constructing the prefix in segments prevents
# the scanner test source from becoming its own credential fixture.
unreachable_provider_repo="$(new_repo unreachable-provider)"
generic_provider_token="$(printf '%s%s' 'sk-' 'vendor-0123456789abcdef0123456789')"
git -C "$unreachable_provider_repo" checkout -qb scratch
printf 'safe introduction\nsafe second line\n%s\n%s\n' \
  "$generic_provider_token" "$generic_provider_token" > "$unreachable_provider_repo/provider.txt"
git -C "$unreachable_provider_repo" add provider.txt
git -C "$unreachable_provider_repo" commit -qm 'temporary generic provider fixture'
git -C "$unreachable_provider_repo" checkout -q main
git -C "$unreachable_provider_repo" branch -qD scratch
git -C "$unreachable_provider_repo" reflog expire --expire=now --all
git -C "$unreachable_provider_repo" repack -q -a -d --keep-unreachable
git -C "$unreachable_provider_repo" prune-packed
expect_failure "$unreachable_provider_repo" provider-credential
assert_category_line provider-credential 3
assert_value_redacted "$generic_provider_token"

# Path recovery from an unreachable commit/root tree still identifies a local
# URL at a public-facing path without applying the rule to every blob.
unreachable_file_url_repo="$(new_repo unreachable-file-url)"
git -C "$unreachable_file_url_repo" checkout -qb scratch
printf 'safe introduction\n%s\n' "$local_file_url" > "$unreachable_file_url_repo/README.md"
git -C "$unreachable_file_url_repo" add README.md
git -C "$unreachable_file_url_repo" commit -qm 'temporary public local URL fixture'
git -C "$unreachable_file_url_repo" checkout -q main
git -C "$unreachable_file_url_repo" branch -qD scratch
git -C "$unreachable_file_url_repo" reflog expire --expire=now --all
git -C "$unreachable_file_url_repo" repack -q -a -d --keep-unreachable
git -C "$unreachable_file_url_repo" prune-packed
expect_failure "$unreachable_file_url_repo" file-url
assert_category_line file-url 2
assert_value_redacted "$local_file_url"

# Standalone unreachable tree objects are scanned recursively even when no
# commit or ref names them and the forbidden path is absent from index/worktree.
dangling_tree_repo="$(new_repo dangling-tree)"
mkdir -p "$dangling_tree_repo/orphaned/private"
printf 'benign dangling tree contents\n' > "$dangling_tree_repo/orphaned/private/.env"
git -C "$dangling_tree_repo" add -f orphaned/private/.env
dangling_tree_oid="$(git -C "$dangling_tree_repo" write-tree)"
git -C "$dangling_tree_repo" rm -qf --cached orphaned/private/.env
rm -f "$dangling_tree_repo/orphaned/private/.env"
rmdir "$dangling_tree_repo/orphaned/private" "$dangling_tree_repo/orphaned"
[[ "$(git -C "$dangling_tree_repo" cat-file -t "$dangling_tree_oid")" == tree ]]
expect_failure "$dangling_tree_repo" private-path

# Personal absolute paths are rejected without printing the path itself.
personal_repo="$(new_repo personal-path)"
personal_path="$(printf '/%s/%s/%s' 'Users' 'fixture-user' 'Documents/private.txt')"
printf '%s\n' "$personal_path" > "$personal_repo/personal.txt"
expect_failure "$personal_repo" personal-path
assert_value_redacted "$personal_path"

# Legacy-named refs and legacy remote linkage are structural failures.
legacy_ref_repo="$(new_repo legacy-ref)"
git -C "$legacy_ref_repo" branch FlowType-archive
expect_failure "$legacy_ref_repo" legacy-ref

legacy_remote_repo="$(new_repo legacy-remote)"
legacy_url='https://example.invalid/FlowType.git'
git -C "$legacy_remote_repo" remote add origin "$legacy_url"
expect_failure "$legacy_remote_repo" legacy-git-link --expected-origin "$legacy_url"

# Root counting includes unreachable commit objects, not only named refs.
second_root_repo="$(new_repo second-root)"
git -C "$second_root_repo" checkout -q --orphan discarded-root
git -C "$second_root_repo" rm -qrf .
printf 'independent root\n' > "$second_root_repo/root.txt"
git -C "$second_root_repo" add root.txt
git -C "$second_root_repo" commit -qm 'independent root fixture'
git -C "$second_root_repo" checkout -q main
git -C "$second_root_repo" branch -qD discarded-root
git -C "$second_root_repo" reflog expire --expire=now --all
expect_failure "$second_root_repo" history-root-count

# Alternates, grafts, and replace refs are never acceptable history inputs.
foreign_repo="$(new_repo alternate-source)"
alternates_repo="$(new_repo alternates)"
foreign_objects="$(cd "$foreign_repo/.git/objects" && pwd -P)"
printf '%s\n' "$foreign_objects" > "$alternates_repo/.git/objects/info/alternates"
expect_failure "$alternates_repo" git-alternates

grafts_repo="$(new_repo grafts)"
grafts_head="$(git -C "$grafts_repo" rev-parse HEAD)"
printf '%s\n' "$grafts_head" > "$grafts_repo/.git/info/grafts"
expect_failure "$grafts_repo" git-grafts

replace_repo="$(new_repo replace)"
replace_old="$(git -C "$replace_repo" rev-parse HEAD)"
printf 'second revision\n' > "$replace_repo/safe.txt"
git -C "$replace_repo" add safe.txt
git -C "$replace_repo" commit -qm 'second fixture revision'
replace_new="$(git -C "$replace_repo" rev-parse HEAD)"
git -C "$replace_repo" replace "$replace_old" "$replace_new"
expect_failure "$replace_repo" git-replace

# Oversized text is not silently skipped when bounded scanning cannot cover it.
large_text_repo="$(new_repo large-text)"
dd if=/dev/zero bs=1048577 count=1 2>/dev/null | tr '\000' a > "$large_text_repo/large.txt"
expect_failure "$large_text_repo" unscannable-text

# A tracked, immutable manifest authorizes a matching LegacyParity blob.
provenance_repo="$(new_repo provenance-match)"
mkdir -p "$provenance_repo/LegacyParity/Sources/App"
printf 'let imported = true\n' > "$provenance_repo/LegacyParity/Sources/App/Main.swift"
provenance_sha="$(shasum -a 256 "$provenance_repo/LegacyParity/Sources/App/Main.swift" | awk '{print $1}')"
write_manifest "$provenance_repo" "$provenance_sha" 'Example Owner' 'Authorized for Apache-2.0' 'Example Reviewer'
git -C "$provenance_repo" add LegacyParity docs/provenance/legacy-source-import.tsv
git -C "$provenance_repo" commit -qm 'add reviewed legacy fixture'
expect_pass "$provenance_repo"

# Updating both source and current manifest cannot retroactively authorize a
# different historical blob at the same destination.
printf 'let imported = false\n' > "$provenance_repo/LegacyParity/Sources/App/Main.swift"
provenance_v2_sha="$(shasum -a 256 "$provenance_repo/LegacyParity/Sources/App/Main.swift" | awk '{print $1}')"
write_manifest "$provenance_repo" "$provenance_v2_sha" 'Example Owner' 'Authorized for Apache-2.0' 'Example Reviewer'
git -C "$provenance_repo" add LegacyParity docs/provenance/legacy-source-import.tsv
git -C "$provenance_repo" commit -qm 'change reviewed legacy fixture'
expect_failure "$provenance_repo" legacy-provenance

# Missing or incomplete public review facts fail provenance closed.
unmanifested_repo="$(new_repo provenance-missing)"
mkdir -p "$unmanifested_repo/LegacyParity/Sources/App"
printf 'let imported = true\n' > "$unmanifested_repo/LegacyParity/Sources/App/Main.swift"
git -C "$unmanifested_repo" add LegacyParity
git -C "$unmanifested_repo" commit -qm 'add unmanifested legacy fixture'
expect_failure "$unmanifested_repo" legacy-provenance

incomplete_repo="$(new_repo provenance-incomplete)"
mkdir -p "$incomplete_repo/LegacyParity/Sources/App"
printf 'let imported = true\n' > "$incomplete_repo/LegacyParity/Sources/App/Main.swift"
incomplete_sha="$(shasum -a 256 "$incomplete_repo/LegacyParity/Sources/App/Main.swift" | awk '{print $1}')"
write_manifest "$incomplete_repo" "$incomplete_sha" 'Example Owner' 'Authorized for Apache-2.0' ''
git -C "$incomplete_repo" add LegacyParity docs/provenance/legacy-source-import.tsv
git -C "$incomplete_repo" commit -qm 'add incomplete review fixture'
expect_failure "$incomplete_repo" provenance-manifest

echo 'public history scanner tests passed'
