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
    [[ "$line" =~ ^finding\ category=[a-z0-9-]+\ (file|object)=[A-Za-z0-9._:@/+,-]+$ ]] || {
      echo "non-redacted diagnostic shape: $line" >&2
      exit 1
    }
  done < "$diagnostics"
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
