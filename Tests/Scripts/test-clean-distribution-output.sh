#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
CLEANER="$ROOT/Scripts/clean-distribution-output.sh"

fail() {
  printf 'distribution cleanup tests failed: %s\n' "$1" >&2
  exit 1
}

[[ -f "$CLEANER" ]] || fail 'Scripts/clean-distribution-output.sh does not exist'
for device_guard in \
  'def remove_tree_fd(directory_fd, label, expected_device):' \
  'if before.st_dev != expected_device:' \
  'remove_tree_fd(target.target_fd, target.relative, target_device)'; do
  /usr/bin/grep -Fq "$device_guard" "$CLEANER" ||
    fail "cross-device recursion guard is missing: $device_guard"
done
for absence_guard in \
  'def verify_requested_path_absent(root_fd, root_links, relative):' \
  'generated root was recreated during cleanup:' \
  'verify_requested_path_absent(root_fd, root_links, relative)'; do
  /usr/bin/grep -Fq "$absence_guard" "$CLEANER" ||
    fail "post-removal absence guard is missing: $absence_guard"
done

# The cleaner's deterministic race hook is deliberately restricted to marked
# fixtures below the canonical private temporary directory.
TMP="$(mktemp -d "/private/tmp/utterink-clean-output-tests.XXXXXX")"
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

prepare_race_hook() {
  local repository="$1"
  local phase="${2:-before-mutation}"
  local hook="$repository/.clean-distribution-output-test-hook"

  printf 'fixture-v1\n' > "$repository/.utterink-cleanup-test-fixture"
  chmod 600 "$repository/.utterink-cleanup-test-fixture"
  mkdir "$hook"
  chmod 700 "$hook"
  printf 'race-v1\n' > "$hook/.utterink-cleanup-race-fixture"
  chmod 600 "$hook/.utterink-cleanup-race-fixture"
  printf '%s\n' "$phase" > "$hook/phase"
  chmod 600 "$hook/phase"
  printf '%s\n' "$hook"
}

wait_for_race_hook() {
  local hook="$1"
  local cleaner_pid="$2"
  local attempt

  for ((attempt = 0; attempt < 1500; attempt += 1)); do
    [[ ! -f "$hook/ready" ]] || return 0
    if ! kill -0 "$cleaner_pid" 2>/dev/null; then
      wait "$cleaner_pid" 2>/dev/null || true
      fail 'cleanup race process exited before reaching the synchronization hook'
    fi
    sleep 0.01
  done
  kill "$cleaner_pid" 2>/dev/null || true
  wait "$cleaner_pid" 2>/dev/null || true
  fail 'cleanup race synchronization hook timed out'
}

assert_race_refused() {
  local cleaner_pid="$1"
  local output_path="$2"
  local label="$3"
  local output

  if wait "$cleaner_pid"; then
    fail "$label was not refused"
  fi
  output="$(<"$output_path")"
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
# An ordinary inherited hook variable is inert. It is honored only when the
# strict /private/tmp fixture markers used by the race tests are also present.
(cd / && UTTERINK_CLEAN_TEST_HOOK_DIR="$selected_repository/.clean-distribution-output-test-hook" \
  bash "$selected_repository/Scripts/clean-distribution-output.sh" "$selected_repository/dist/")
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

# Recursive directory descriptors must be released as soon as each subtree is
# removed. With a 64-fd soft limit, retaining one fd per sibling would fail far
# before this 1,500-directory fixture is complete.
fd_stress_repository="$(make_fixture fd-stress)"
populate_protected_paths "$fd_stress_repository"
/usr/bin/python3 -I - "$fd_stress_repository/dist" <<'PY'
import os
import sys

root = sys.argv[1]
os.mkdir(root)
for index in range(1500):
    os.mkdir(os.path.join(root, "sibling-%04d" % index))
PY
(cd / && ulimit -n 64 && \
  bash "$fd_stress_repository/Scripts/clean-distribution-output.sh" dist)
[[ ! -e "$fd_stress_repository/dist" && ! -L "$fd_stress_repository/dist" ]] ||
  fail 'fd-stress cleanup left the generated root'
assert_protected_paths_exist "$fd_stress_repository"

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

# Deterministically replace a validated leaf with a symlink before mutation.
# The cleaner must detect the inode change, preserve the original directory,
# and never follow the replacement into the external payload.
leaf_race_repository="$(make_fixture leaf-symlink-race)"
populate_protected_paths "$leaf_race_repository"
mkdir -p "$leaf_race_repository/dist/generated"
printf 'generated\n' > "$leaf_race_repository/dist/generated/artifact"
leaf_race_payload="$TMP/leaf-race-outside"
mkdir -p "$leaf_race_payload"
printf 'outside leaf sentinel\n' > "$leaf_race_payload/sentinel"
leaf_race_hook="$(prepare_race_hook "$leaf_race_repository")"
leaf_race_output="$TMP/leaf-race-output"
UTTERINK_CLEAN_TEST_HOOK_DIR="$leaf_race_hook" \
  bash "$leaf_race_repository/Scripts/clean-distribution-output.sh" dist \
  > "$leaf_race_output" 2>&1 &
leaf_race_pid=$!
wait_for_race_hook "$leaf_race_hook" "$leaf_race_pid"
mv "$leaf_race_repository/dist" "$leaf_race_repository/dist-before-race"
ln -s "$leaf_race_payload" "$leaf_race_repository/dist"
printf 'continue\n' > "$leaf_race_hook/continue"
assert_race_refused "$leaf_race_pid" "$leaf_race_output" 'validated leaf replacement'
[[ -L "$leaf_race_repository/dist" ]] || fail 'leaf race changed the replacement symlink'
[[ -f "$leaf_race_repository/dist-before-race/generated/artifact" ]] ||
  fail 'leaf race removed the originally validated directory'
[[ "$(<"$leaf_race_payload/sentinel")" == 'outside leaf sentinel' ]] ||
  fail 'leaf race followed the replacement symlink outside the worktree'
assert_protected_paths_exist "$leaf_race_repository"

# Repeat the same synchronized replacement for the parent of Tools/bin. Both
# the parent and bin were fixed by fd during validation, so the changed parent
# path must fail closed without touching the external bin directory.
parent_race_repository="$(make_fixture parent-symlink-race)"
populate_protected_paths "$parent_race_repository"
mkdir -p "$parent_race_repository/Tools/bin"
printf 'generated tool\n' > "$parent_race_repository/Tools/bin/xcodegen"
parent_race_payload="$TMP/parent-race-outside"
mkdir -p "$parent_race_payload/bin"
printf 'outside parent sentinel\n' > "$parent_race_payload/bin/sentinel"
parent_race_hook="$(prepare_race_hook "$parent_race_repository")"
parent_race_output="$TMP/parent-race-output"
UTTERINK_CLEAN_TEST_HOOK_DIR="$parent_race_hook" \
  bash "$parent_race_repository/Scripts/clean-distribution-output.sh" Tools/bin \
  > "$parent_race_output" 2>&1 &
parent_race_pid=$!
wait_for_race_hook "$parent_race_hook" "$parent_race_pid"
mv "$parent_race_repository/Tools" "$parent_race_repository/Tools-before-race"
ln -s "$parent_race_payload" "$parent_race_repository/Tools"
printf 'continue\n' > "$parent_race_hook/continue"
assert_race_refused "$parent_race_pid" "$parent_race_output" 'validated parent replacement'
[[ -L "$parent_race_repository/Tools" ]] || fail 'parent race changed the replacement symlink'
[[ -f "$parent_race_repository/Tools-before-race/bin/xcodegen" ]] ||
  fail 'parent race removed the originally validated nested directory'
[[ "$(<"$parent_race_payload/bin/sentinel")" == 'outside parent sentinel' ]] ||
  fail 'parent race followed the replacement symlink outside the worktree'
assert_protected_paths_exist "$parent_race_repository"

# Recreate the original leaf after its validated directory has been moved to a
# tombstone. The tombstone may be deleted, but the replacement leaf must make
# the overall cleanup fail rather than being reported as a success.
rename_rebuild_repository="$(make_fixture rename-rebuild-race)"
populate_protected_paths "$rename_rebuild_repository"
mkdir -p "$rename_rebuild_repository/dist/original"
printf 'original\n' > "$rename_rebuild_repository/dist/original/artifact"
rename_rebuild_hook="$(prepare_race_hook "$rename_rebuild_repository" after-rename)"
rename_rebuild_output="$TMP/rename-rebuild-output"
UTTERINK_CLEAN_TEST_HOOK_DIR="$rename_rebuild_hook" \
  bash "$rename_rebuild_repository/Scripts/clean-distribution-output.sh" dist \
  > "$rename_rebuild_output" 2>&1 &
rename_rebuild_pid=$!
wait_for_race_hook "$rename_rebuild_hook" "$rename_rebuild_pid"
[[ ! -e "$rename_rebuild_repository/dist" && ! -L "$rename_rebuild_repository/dist" ]] ||
  fail 'after-rename hook ran before the original leaf moved to a tombstone'
mkdir "$rename_rebuild_repository/dist"
printf 'replacement\n' > "$rename_rebuild_repository/dist/replacement"
printf 'continue\n' > "$rename_rebuild_hook/continue"
assert_race_refused "$rename_rebuild_pid" "$rename_rebuild_output" 'rename followed by leaf rebuild'
[[ "$(<"$rename_rebuild_repository/dist/replacement")" == replacement ]] ||
  fail 'rename/rebuild refusal mutated the replacement leaf'
assert_protected_paths_exist "$rename_rebuild_repository"

# Recreate the leaf only after the first fixed-parent ENOENT verification. A
# second verification before success must observe it and fail closed.
post_absence_repository="$(make_fixture post-absence-race)"
populate_protected_paths "$post_absence_repository"
mkdir -p "$post_absence_repository/dist/original"
printf 'original\n' > "$post_absence_repository/dist/original/artifact"
post_absence_hook="$(prepare_race_hook "$post_absence_repository" after-first-absence)"
post_absence_output="$TMP/post-absence-output"
UTTERINK_CLEAN_TEST_HOOK_DIR="$post_absence_hook" \
  bash "$post_absence_repository/Scripts/clean-distribution-output.sh" dist \
  > "$post_absence_output" 2>&1 &
post_absence_pid=$!
wait_for_race_hook "$post_absence_hook" "$post_absence_pid"
[[ ! -e "$post_absence_repository/dist" && ! -L "$post_absence_repository/dist" ]] ||
  fail 'post-absence hook ran before the first fixed-parent ENOENT verification'
mkdir "$post_absence_repository/dist"
printf 'replacement\n' > "$post_absence_repository/dist/replacement"
printf 'continue\n' > "$post_absence_hook/continue"
assert_race_refused "$post_absence_pid" "$post_absence_output" 'leaf creation after absence verification'
[[ "$(<"$post_absence_repository/dist/replacement")" == replacement ]] ||
  fail 'post-absence refusal mutated the replacement leaf'
assert_protected_paths_exist "$post_absence_repository"

# Even a root that was absent during initial validation must be re-resolved from
# the pinned Git root after the hook. Creating it after the first ENOENT is a
# concurrent mutation, not an idempotent cleanup success.
initially_absent_repository="$(make_fixture initially-absent-race)"
populate_protected_paths "$initially_absent_repository"
initially_absent_hook="$(prepare_race_hook "$initially_absent_repository" after-first-absence)"
initially_absent_output="$TMP/initially-absent-output"
UTTERINK_CLEAN_TEST_HOOK_DIR="$initially_absent_hook" \
  bash "$initially_absent_repository/Scripts/clean-distribution-output.sh" dist \
  > "$initially_absent_output" 2>&1 &
initially_absent_pid=$!
wait_for_race_hook "$initially_absent_hook" "$initially_absent_pid"
[[ ! -e "$initially_absent_repository/dist" && ! -L "$initially_absent_repository/dist" ]] ||
  fail 'initially absent dist existed before the postcondition hook'
mkdir "$initially_absent_repository/dist"
printf 'replacement\n' > "$initially_absent_repository/dist/replacement"
printf 'continue\n' > "$initially_absent_hook/continue"
assert_race_refused "$initially_absent_pid" "$initially_absent_output" 'creation of initially absent dist'
[[ "$(<"$initially_absent_repository/dist/replacement")" == replacement ]] ||
  fail 'initially absent dist refusal mutated the replacement data'
assert_protected_paths_exist "$initially_absent_repository"

# The same postcondition must resolve the complete nested path. When Tools was
# initially absent, creating Tools/bin after ENOENT must still be detected.
nested_absent_repository="$(make_fixture nested-absent-race)"
populate_protected_paths "$nested_absent_repository"
nested_absent_hook="$(prepare_race_hook "$nested_absent_repository" after-first-absence)"
nested_absent_output="$TMP/nested-absent-output"
UTTERINK_CLEAN_TEST_HOOK_DIR="$nested_absent_hook" \
  bash "$nested_absent_repository/Scripts/clean-distribution-output.sh" Tools/bin \
  > "$nested_absent_output" 2>&1 &
nested_absent_pid=$!
wait_for_race_hook "$nested_absent_hook" "$nested_absent_pid"
[[ ! -e "$nested_absent_repository/Tools" && ! -L "$nested_absent_repository/Tools" ]] ||
  fail 'initially absent Tools parent existed before the postcondition hook'
mkdir -p "$nested_absent_repository/Tools/bin"
printf 'replacement\n' > "$nested_absent_repository/Tools/bin/replacement"
printf 'continue\n' > "$nested_absent_hook/continue"
assert_race_refused "$nested_absent_pid" "$nested_absent_output" 'creation of initially absent Tools/bin'
[[ "$(<"$nested_absent_repository/Tools/bin/replacement")" == replacement ]] ||
  fail 'initially absent Tools/bin refusal mutated the replacement data'
assert_protected_paths_exist "$nested_absent_repository"

printf 'distribution cleanup tests passed\n'
