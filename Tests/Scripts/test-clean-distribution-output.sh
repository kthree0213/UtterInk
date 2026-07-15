#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
CLEANER="$ROOT/Scripts/clean-distribution-output.sh"

fail() {
  printf 'distribution cleanup tests failed: %s\n' "$1" >&2
  exit 1
}

[[ -f "$CLEANER" ]] || fail 'Scripts/clean-distribution-output.sh does not exist'

TMP="$(mktemp -d "${TMPDIR:-/tmp}/utterink-clean-output-tests.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

make_fixture() {
  local name="$1"
  local repository="$TMP/$name"

  mkdir -p "$repository/Scripts"
  cp "$CLEANER" "$repository/Scripts/clean-distribution-output.sh"
  chmod +x "$repository/Scripts/clean-distribution-output.sh"
  git -C "$repository" init -q
  printf '%s\n' "$repository"
}

populate_protected_paths() {
  local repository="$1"

  mkdir -p \
    "$repository/App" \
    "$repository/Config" \
    "$repository/Packages" \
    "$repository/Sources" \
    "$repository/Tests" \
    "$repository/docs"
  printf 'app source\n' > "$repository/App/App.swift"
  printf 'configuration\n' > "$repository/Config/release.json"
  printf 'package source\n' > "$repository/Packages/Package.swift"
  printf 'source\n' > "$repository/Sources/Feature.swift"
  printf 'test source\n' > "$repository/Tests/FeatureTests.swift"
  printf 'documentation\n' > "$repository/docs/RELEASING.md"
}

populate_generated_roots() {
  local repository="$1"

  mkdir -p \
    "$repository/build/archive" \
    "$repository/dist/unsigned-smoke" \
    "$repository/.release-work/evidence" \
    "$repository/Tools/bin"
  printf 'archive\n' > "$repository/build/archive/UtterInk.xcarchive"
  printf 'disk image\n' > "$repository/dist/unsigned-smoke/UtterInk.dmg"
  printf 'evidence\n' > "$repository/.release-work/evidence/candidate.json"
  printf 'tool\n' > "$repository/Tools/bin/xcodegen"
}

assert_protected_paths_exist() {
  local repository="$1"
  local path

  for path in \
    App/App.swift \
    Config/release.json \
    Packages/Package.swift \
    Sources/Feature.swift \
    Tests/FeatureTests.swift \
    docs/RELEASING.md \
    Scripts/clean-distribution-output.sh; do
    [[ -f "$repository/$path" ]] || fail "protected path was removed: $path"
  done
}

expect_refusal() {
  local repository="$1"
  local label="$2"
  shift 2
  local output

  if output="$(cd / && bash "$repository/Scripts/clean-distribution-output.sh" "$@" 2>&1)"; then
    fail "$label was accepted"
  fi
  case "$output" in
    *'distribution cleanup refused:'*) ;;
    *) fail "$label did not emit a refusal diagnostic: $output" ;;
  esac
}

# No arguments clean every enumerated root, from any current working directory,
# while leaving application, configuration, test, and documentation sources.
all_repository="$(make_fixture all-roots)"
populate_protected_paths "$all_repository"
populate_generated_roots "$all_repository"
outside_payload="$TMP/nested-symlink-payload"
mkdir -p "$outside_payload"
printf 'outside\n' > "$outside_payload/sentinel"
ln -s "$outside_payload" "$all_repository/dist/unsigned-smoke/outside-link"
(cd / && bash "$all_repository/Scripts/clean-distribution-output.sh")
for path in build dist .release-work Tools/bin; do
  [[ ! -e "$all_repository/$path" && ! -L "$all_repository/$path" ]] ||
    fail "default cleanup left generated root: $path"
done
[[ -f "$outside_payload/sentinel" ]] || fail 'cleanup followed a symlink contained inside a generated root'
[[ -d "$all_repository/Tools" ]] || fail 'cleanup removed the non-generated Tools parent'
assert_protected_paths_exist "$all_repository"

# An explicit allowlisted root limits cleanup to that root. Its canonical
# absolute spelling is accepted because it still names the exact same root.
selected_repository="$(make_fixture selected-root)"
populate_protected_paths "$selected_repository"
populate_generated_roots "$selected_repository"
(cd / && bash "$selected_repository/Scripts/clean-distribution-output.sh" "$selected_repository/dist/")
[[ ! -e "$selected_repository/dist" ]] || fail 'explicit dist cleanup did not remove dist'
for path in build .release-work Tools/bin; do
  [[ -d "$selected_repository/$path" ]] || fail "explicit dist cleanup removed another root: $path"
done
assert_protected_paths_exist "$selected_repository"

# Missing generated roots are an idempotent success.
empty_repository="$(make_fixture absent-roots)"
populate_protected_paths "$empty_repository"
(cd / && bash "$empty_repository/Scripts/clean-distribution-output.sh")
assert_protected_paths_exist "$empty_repository"

# Validate the full request set before deleting anything.
atomic_repository="$(make_fixture atomic-refusal)"
populate_protected_paths "$atomic_repository"
populate_generated_roots "$atomic_repository"
expect_refusal "$atomic_repository" 'mixed allowed and source request' dist docs
[[ -f "$atomic_repository/dist/unsigned-smoke/UtterInk.dmg" ]] ||
  fail 'an allowed root was removed before a later invalid request was rejected'
assert_protected_paths_exist "$atomic_repository"

# Source, configuration, documentation, repository-root, unknown, traversal,
# and outside-worktree requests all fail without mutation.
refusal_repository="$(make_fixture path-refusals)"
populate_protected_paths "$refusal_repository"
populate_generated_roots "$refusal_repository"
expect_refusal "$refusal_repository" 'source root' Sources
expect_refusal "$refusal_repository" 'configuration root' Config
expect_refusal "$refusal_repository" 'documentation root' docs
expect_refusal "$refusal_repository" 'repository root' "$refusal_repository"
expect_refusal "$refusal_repository" 'unknown repository path' Artifacts
expect_refusal "$refusal_repository" 'relative parent traversal' ../outside
expect_refusal "$refusal_repository" 'embedded parent traversal' dist/../docs
expect_refusal "$refusal_repository" 'outside absolute path' "$TMP/outside-output"
[[ -f "$refusal_repository/dist/unsigned-smoke/UtterInk.dmg" ]] ||
  fail 'refused path request mutated generated output'
assert_protected_paths_exist "$refusal_repository"

# A generated root may not itself be a symlink, including a dangling symlink.
symlink_repository="$(make_fixture symlink-root)"
populate_protected_paths "$symlink_repository"
symlink_payload="$TMP/symlink-root-payload"
mkdir -p "$symlink_payload"
printf 'outside\n' > "$symlink_payload/sentinel"
ln -s "$symlink_payload" "$symlink_repository/dist"
expect_refusal "$symlink_repository" 'symlink generated root' dist
[[ -L "$symlink_repository/dist" && -f "$symlink_payload/sentinel" ]] ||
  fail 'symlink root refusal mutated the link or its external target'
rm "$symlink_repository/dist"
ln -s "$TMP/does-not-exist" "$symlink_repository/dist"
expect_refusal "$symlink_repository" 'dangling symlink generated root' dist
[[ -L "$symlink_repository/dist" ]] || fail 'dangling symlink root was removed'
assert_protected_paths_exist "$symlink_repository"

# Every existing component leading to a nested allowlisted root must be a real
# directory. This prevents Tools/bin from escaping through a Tools symlink.
parent_symlink_repository="$(make_fixture symlink-parent)"
populate_protected_paths "$parent_symlink_repository"
parent_symlink_payload="$TMP/symlink-parent-payload"
mkdir -p "$parent_symlink_payload/bin"
printf 'outside tool\n' > "$parent_symlink_payload/bin/xcodegen"
ln -s "$parent_symlink_payload" "$parent_symlink_repository/Tools"
expect_refusal "$parent_symlink_repository" 'symlink parent' Tools/bin
[[ -f "$parent_symlink_payload/bin/xcodegen" ]] || fail 'symlink parent cleanup reached outside the repository'
assert_protected_paths_exist "$parent_symlink_repository"

# A non-directory object at an allowlisted name is preserved and rejected.
file_repository="$(make_fixture non-directory-root)"
populate_protected_paths "$file_repository"
printf 'not generated output\n' > "$file_repository/dist"
expect_refusal "$file_repository" 'non-directory generated root' dist
[[ -f "$file_repository/dist" ]] || fail 'non-directory allowlisted path was removed'
assert_protected_paths_exist "$file_repository"

printf 'distribution cleanup tests passed\n'
