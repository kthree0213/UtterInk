#!/usr/bin/env -S -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u BASH_XTRACEFD -u PS4 -u POSIXLY_CORRECT -u BASH_COMPAT -u UTTERINK_RELEASE_ENV_CLEAN /bin/bash -p

set +x +v
if [[ "$-" != *p* ]]; then
  printf 'release candidate error: unsafe-launch-environment\n' >&2
  exit 2
fi
if [[ "${UTTERINK_RELEASE_ENV_CLEAN:-}" != 1 ]]; then
  clean_environment=(
    PATH=/usr/bin:/bin:/usr/sbin:/sbin
    LC_ALL=C
    UTTERINK_RELEASE_ENV_CLEAN=1
  )
  if [[ -n "${UTTERINK_RELEASE_TEST_MODE+x}" ]]; then
    clean_environment+=("UTTERINK_RELEASE_TEST_MODE=${UTTERINK_RELEASE_TEST_MODE}")
  fi
  if [[ -n "${UTTERINK_RELEASE_TEST_TOOL_ROOT+x}" ]]; then
    clean_environment+=("UTTERINK_RELEASE_TEST_TOOL_ROOT=${UTTERINK_RELEASE_TEST_TOOL_ROOT}")
  fi
  if [[ -n "${UTTERINK_FIXTURE_LOG+x}" ]]; then
    clean_environment+=("UTTERINK_FIXTURE_LOG=${UTTERINK_FIXTURE_LOG}")
  fi
  exec /usr/bin/env -i "${clean_environment[@]}" /bin/bash -p "$0" "$@"
  printf 'release candidate error: unsafe-launch-environment\n' >&2
  exit 2
fi
if [[ "$-" != hpB || "${PATH-}" != /usr/bin:/bin:/usr/sbin:/sbin || "${LC_ALL-}" != C ]]; then
  printf 'release candidate error: unsafe-launch-environment\n' >&2
  exit 2
fi
while IFS= read -r -d '' environment_entry; do
  environment_name="${environment_entry%%=*}"
  case "$environment_name" in
    PATH|LC_ALL|UTTERINK_RELEASE_ENV_CLEAN|UTTERINK_RELEASE_TEST_MODE|UTTERINK_RELEASE_TEST_TOOL_ROOT|UTTERINK_FIXTURE_LOG|UTTERINK_COMMIT_BOUND_SELF_FD|UTTERINK_COMMIT_BOUND_ROOT|FIXTURE_VERIFY_ENV_CLEAN|PWD|SHLVL|_) ;;
    *)
      printf 'release candidate error: unsafe-launch-environment\n' >&2
      exit 2
      ;;
  esac
done < <(/usr/bin/env -0)
COMMIT_BOUND_SELF_FD="${UTTERINK_COMMIT_BOUND_SELF_FD:-}"
COMMIT_BOUND_ROOT="${UTTERINK_COMMIT_BOUND_ROOT:-}"
unset UTTERINK_RELEASE_ENV_CLEAN
unset UTTERINK_COMMIT_BOUND_SELF_FD UTTERINK_COMMIT_BOUND_ROOT FIXTURE_VERIFY_ENV_CLEAN

set -euo pipefail

export LC_ALL=C
export GIT_NO_REPLACE_OBJECTS=1
export GIT_NO_LAZY_FETCH=1
export GIT_TERMINAL_PROMPT=0
export PYTHONDONTWRITEBYTECODE=1
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
unset \
  BASH_ENV ENV CDPATH GLOBIGNORE PYTHONHOME PYTHONPATH \
  PERL5OPT PERL5LIB PERLLIB PERL5DB
umask 077

GIT=/usr/bin/git
PYTHON=/usr/bin/python3
SHASUM=/usr/bin/shasum
PACKAGE_RESOLUTION=Packages/UtterInkKit/Package.resolved

fail() {
  local category="$1"
  local status="${2:-1}"
  printf 'release candidate error: %s\n' "$category" >&2
  exit "$status"
}

COMMIT=''
OUTPUT=''
OUTPUT_DIR_FD=''
EXPECTED_ORIGIN=''
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --commit)
      [[ -z "$COMMIT" && "$#" -ge 2 && -n "$2" ]] || fail invalid-arguments 2
      COMMIT="$2"
      shift 2
      ;;
    --output)
      [[ -z "$OUTPUT" && "$#" -ge 2 && -n "$2" ]] || fail invalid-arguments 2
      OUTPUT="$2"
      shift 2
      ;;
    --output-dir-fd)
      [[ -z "$OUTPUT_DIR_FD" && "$#" -ge 2 && "$2" =~ ^[0-9]+$ ]] || fail invalid-arguments 2
      OUTPUT_DIR_FD="$2"
      shift 2
      ;;
    --expected-origin)
      [[ -z "$EXPECTED_ORIGIN" && "$#" -ge 2 && -n "$2" ]] || fail invalid-arguments 2
      EXPECTED_ORIGIN="$2"
      shift 2
      ;;
    *) fail invalid-arguments 2 ;;
  esac
done

[[ "$COMMIT" =~ ^[0-9a-f]{40}$ && -n "$OUTPUT" ]] || fail invalid-arguments 2
if [[ -n "$OUTPUT_DIR_FD" ]]; then
  [[ "$OUTPUT_DIR_FD" -ge 3 && "$OUTPUT_DIR_FD" -le 255 ]] || fail invalid-arguments 2
  case "$OUTPUT_DIR_FD" in
    40|41|50|51|52|53|54|55|56|57|58|59|60|61)
      exec 39<&"$OUTPUT_DIR_FD" || fail invalid-arguments 2
      OUTPUT_DIR_FD=39
      ;;
  esac
fi

for unsafe_name in \
  GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_NAMESPACE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_REPLACE_REF_BASE GIT_GRAFT_FILE \
  GIT_COMMON_DIR GIT_CONFIG GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_COUNT \
  GIT_CONFIG_PARAMETERS GIT_EXEC_PATH GIT_CEILING_DIRECTORIES \
  GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_ATTR_NOSYSTEM GIT_SSH GIT_SSH_COMMAND \
  GIT_ASKPASS GIT_PROXY_COMMAND SSH_ASKPASS \
  XCODE_XCCONFIG_FILE XCODE_DEFAULT_TOOLCHAIN_OVERRIDE SWIFT_EXEC SDKROOT \
  DEVELOPER_DIR TOOLCHAINS DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH; do
  if [[ -n "${!unsafe_name-}" ]]; then
    fail unsafe-git-environment
  fi
done
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

if [[ -n "$COMMIT_BOUND_SELF_FD" || -n "$COMMIT_BOUND_ROOT" ]]; then
  [[ "$COMMIT_BOUND_SELF_FD" =~ ^[0-9]+$ && "$COMMIT_BOUND_SELF_FD" -ge 3 && "$COMMIT_BOUND_SELF_FD" -le 255 ]] || fail unsafe-launch-environment 2
  [[ "$COMMIT_BOUND_ROOT" == /* && -d "$COMMIT_BOUND_ROOT" && ! -L "$COMMIT_BOUND_ROOT" ]] || fail unsafe-launch-environment 2
  ROOT="$COMMIT_BOUND_ROOT"
  cd "$ROOT"
  [[ "$($GIT rev-parse --show-toplevel 2>/dev/null)" == "$ROOT" ]] || fail repository-mismatch
  EXPECTED_SELF_BLOB="$($GIT rev-parse "$COMMIT:Scripts/release/verify-candidate.sh" 2>/dev/null)" || fail required-input-mismatch
  EXPECTED_SELF_MODE="$($GIT ls-tree "$COMMIT" -- Scripts/release/verify-candidate.sh | /usr/bin/awk 'NR == 1 { print $1 }')" || fail required-input-mismatch
  [[ "$EXPECTED_SELF_MODE" == 100755 ]] || fail required-input-mismatch
  if ! "$PYTHON" -I - "$COMMIT_BOUND_SELF_FD" "$EXPECTED_SELF_BLOB" <<'PY' >/dev/null 2>&1
import hashlib
import os
import stat
import sys

descriptor = int(sys.argv[1])
expected = sys.argv[2]
try:
    metadata = os.fstat(descriptor)
except OSError:
    raise SystemExit(1)
if not stat.S_ISREG(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) != 0o755:
    raise SystemExit(1)
content = bytearray()
offset = 0
while offset < metadata.st_size:
    chunk = os.pread(descriptor, min(1024 * 1024, metadata.st_size - offset), offset)
    if not chunk:
        raise SystemExit(1)
    content.extend(chunk)
    offset += len(chunk)
digest = hashlib.sha1()
digest.update(f"blob {len(content)}\0".encode("ascii"))
digest.update(content)
def fingerprint(value):
    return (
        value.st_dev, value.st_ino, value.st_mode, value.st_uid, value.st_gid,
        value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns,
    )


if digest.hexdigest() != expected or fingerprint(os.fstat(descriptor)) != fingerprint(metadata):
    raise SystemExit(1)
PY
  then
    fail required-input-mismatch
  fi
else
  ROOT="$($GIT rev-parse --show-toplevel 2>/dev/null)" || fail not-a-repository
  SCRIPT_ROOT="$(cd "$(/usr/bin/dirname "$0")/../.." && pwd -P)"
  [[ "$ROOT" == "$SCRIPT_ROOT" ]] || fail repository-mismatch
  cd "$ROOT"
fi

TMP="$(/usr/bin/mktemp -d /tmp/utterink-release-candidate.XXXXXX)"
TMP_PARENT="${TMP%/*}"
TMP_NAME="${TMP##*/}"
exec 40< "$TMP_PARENT" || fail temporary-directory-failed
exec 41< "$TMP" || fail temporary-directory-failed
if ! TMP_RECORD="$($PYTHON -I - 40 41 "$TMP_NAME" <<'PY' 2>/dev/null
import os
import stat
import sys

parent_fd = int(sys.argv[1])
temporary_fd = int(sys.argv[2])
name = sys.argv[3]
try:
    opened = os.fstat(temporary_fd)
    named = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
except OSError:
    raise SystemExit(1)
if (
    not stat.S_ISDIR(opened.st_mode)
    or stat.S_ISLNK(named.st_mode)
    or opened.st_uid != os.geteuid()
    or stat.S_IMODE(opened.st_mode) != 0o700
    or (opened.st_dev, opened.st_ino) != (named.st_dev, named.st_ino)
):
    raise SystemExit(1)
print(opened.st_dev, opened.st_ino)
PY
)"; then
  fail temporary-directory-failed
fi
IFS=' ' read -r TMP_DEV TMP_INO <<< "$TMP_RECORD"
[[ "$TMP_DEV" =~ ^[0-9]+$ && "$TMP_INO" =~ ^[0-9]+$ ]] || fail temporary-directory-failed
OUTPUT_PUBLISHED=0
cleanup() {
  local status=$?
  trap - EXIT
  set +e
  if [[ "$status" -ne 0 && "$OUTPUT_PUBLISHED" -eq 1 ]] && declare -F rollback_candidate_output >/dev/null; then
    rollback_candidate_output
  fi
  "$PYTHON" -I - 40 41 "$TMP_NAME" "$TMP_DEV" "$TMP_INO" <<'PY' >/dev/null 2>&1
import os
import stat
import sys

parent_fd = int(sys.argv[1])
temporary_fd = int(sys.argv[2])
name = sys.argv[3]
expected = (int(sys.argv[4]), int(sys.argv[5]))
directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def identity(value):
    return value.st_dev, value.st_ino


def clear_directory(descriptor, device):
    try:
        names = os.listdir(descriptor)
    except OSError:
        return
    for child_name in names:
        try:
            before = os.stat(child_name, dir_fd=descriptor, follow_symlinks=False)
        except OSError:
            continue
        if stat.S_ISDIR(before.st_mode) and not stat.S_ISLNK(before.st_mode) and before.st_dev == device:
            try:
                child = os.open(child_name, directory_flags, dir_fd=descriptor)
            except OSError:
                continue
            try:
                opened = os.fstat(child)
                if identity(opened) != identity(before):
                    continue
                clear_directory(child, device)
            finally:
                os.close(child)
            try:
                current = os.stat(child_name, dir_fd=descriptor, follow_symlinks=False)
                if identity(current) == identity(before):
                    os.rmdir(child_name, dir_fd=descriptor)
            except OSError:
                pass
        else:
            try:
                current = os.stat(child_name, dir_fd=descriptor, follow_symlinks=False)
                if identity(current) == identity(before):
                    os.unlink(child_name, dir_fd=descriptor)
            except OSError:
                pass


try:
    opened = os.fstat(temporary_fd)
except OSError:
    raise SystemExit(0)
if identity(opened) != expected or not stat.S_ISDIR(opened.st_mode):
    raise SystemExit(0)
clear_directory(temporary_fd, opened.st_dev)
try:
    named = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    if identity(named) == expected and stat.S_ISDIR(named.st_mode):
        os.rmdir(name, dir_fd=parent_fd)
        os.fsync(parent_fd)
except OSError:
    pass
PY
  exec 41<&-
  exec 40<&-
  exit "$status"
}
trap cleanup EXIT
/bin/mkdir -p "$TMP/empty-home" "$TMP/tool-tmp"
export HOME="$TMP/empty-home"
export XDG_CONFIG_HOME="$TMP/empty-home"
export TMPDIR="$TMP/tool-tmp"

validate_checkout_worktree_config() {
  local worktree_config="$ROOT/.git/config.worktree"
  local config_keys="$TMP/worktree-git-config-keys"
  local config_values="$TMP/worktree-git-config-values"
  local expected_value="$TMP/worktree-git-config-expected"
  local key
  if [[ ! -e "$worktree_config" && ! -L "$worktree_config" ]]; then
    return
  fi
  [[ -f "$worktree_config" && ! -L "$worktree_config" ]] || fail unsafe-git-config 20
  $GIT config --file "$worktree_config" --no-includes --name-only --list -z > "$config_keys" 2>/dev/null ||
    fail unsafe-git-config 20
  while IFS= read -r -d '' key; do
    case "$key" in
      core.sparsecheckout|core.sparsecheckoutcone|index.sparse) ;;
      *) fail unsafe-git-config 20 ;;
    esac
  done < "$config_keys"
  /usr/bin/printf 'false\0' > "$expected_value" || fail unsafe-git-config 20
  for key in core.sparsecheckout core.sparsecheckoutcone index.sparse; do
    $GIT config --file "$worktree_config" --no-includes --get-all -z "$key" > "$config_values" 2>/dev/null ||
      fail unsafe-git-config 20
    /usr/bin/cmp -s "$config_values" "$expected_value" || fail unsafe-git-config 20
  done
}

validate_local_git_config() {
  local config_keys="$TMP/local-git-config-keys"
  local gc_auto_values="$TMP/local-git-gc-auto-values"
  local gc_auto_expected="$TMP/local-git-gc-auto-expected"
  local key
  [[ -d "$ROOT/.git" && ! -L "$ROOT/.git" ]] || fail unsafe-git-config 20
  [[ -f "$ROOT/.git/config" && ! -L "$ROOT/.git/config" ]] || fail unsafe-git-config 20
  [[ ! -e "$ROOT/.git/commondir" && ! -L "$ROOT/.git/commondir" ]] || fail unsafe-git-config 20
  $GIT config --local --no-includes --name-only --list -z > "$config_keys" 2>/dev/null || fail unsafe-git-config 20
  while IFS= read -r -d '' key; do
    case "$key" in
      core.repositoryformatversion|core.filemode|core.bare|core.logallrefupdates|core.ignorecase|core.precomposeunicode|user.name|user.email) ;;
      gc.auto)
        $GIT config --local --no-includes --get-all -z gc.auto > "$gc_auto_values" 2>/dev/null ||
          fail unsafe-git-config 20
        /usr/bin/printf '0\0' > "$gc_auto_expected" || fail unsafe-git-config 20
        /usr/bin/cmp -s "$gc_auto_values" "$gc_auto_expected" || fail unsafe-git-config 20
        ;;
      remote.*.url|remote.*.fetch)
        [[ "$key" =~ ^remote\.[A-Za-z0-9._-]+\.(url|fetch)$ ]] || fail unsafe-git-config 20
        ;;
      branch.*.remote|branch.*.merge)
        [[ "$key" =~ ^branch\.[A-Za-z0-9._/-]+\.(remote|merge)$ ]] || fail unsafe-git-config 20
        ;;
      *) fail unsafe-git-config 20 ;;
    esac
  done < "$config_keys"
  validate_checkout_worktree_config
}

worktree_matches_commit() {
  local tree_inventory="$TMP/commit-tree-inventory"
  local index_inventory="$TMP/index-inventory"
  $GIT ls-tree -r -z "$COMMIT" > "$tree_inventory" 2>/dev/null || return 1
  $GIT ls-files --stage -z > "$index_inventory" 2>/dev/null || return 1
  "$PYTHON" -I - "$ROOT" "$tree_inventory" "$index_inventory" <<'PY' >/dev/null 2>&1
from __future__ import annotations

import hashlib
import os
from pathlib import Path, PurePosixPath
import stat
import sys


def abort() -> None:
    raise SystemExit(1)


def records(path: Path) -> list[bytes]:
    try:
        data = path.read_bytes()
    except OSError:
        abort()
    if not data.endswith(b"\0"):
        abort()
    return data[:-1].split(b"\0")


root = Path(sys.argv[1])
tree: dict[str, tuple[str, str]] = {}
for record in records(Path(sys.argv[2])):
    try:
        header, raw_path = record.split(b"\t", 1)
        mode, kind, object_id = header.decode("ascii").split(" ")
        path = raw_path.decode("utf-8", errors="strict")
    except (UnicodeDecodeError, ValueError):
        abort()
    pure = PurePosixPath(path)
    if (
        kind != "blob"
        or mode not in {"100644", "100755"}
        or len(object_id) != 40
        or any(character < " " for character in path)
        or pure.is_absolute()
        or not pure.parts
        or ".." in pure.parts
        or path in tree
    ):
        abort()
    tree[path] = (mode, object_id)

index: dict[str, tuple[str, str]] = {}
for record in records(Path(sys.argv[3])):
    try:
        header, raw_path = record.split(b"\t", 1)
        mode, object_id, stage = header.decode("ascii").split(" ")
        path = raw_path.decode("utf-8", errors="strict")
    except (UnicodeDecodeError, ValueError):
        abort()
    if stage != "0" or path in index:
        abort()
    index[path] = (mode, object_id)
if index != tree:
    abort()

for relative, (mode, expected_hash) in tree.items():
    parts = PurePosixPath(relative).parts
    current = root
    for component in parts[:-1]:
        current = current / component
        try:
            parent_metadata = os.lstat(current)
        except OSError:
            abort()
        if not stat.S_ISDIR(parent_metadata.st_mode) or stat.S_ISLNK(parent_metadata.st_mode):
            abort()
    path = root.joinpath(*parts)
    try:
        metadata = os.lstat(path)
    except OSError:
        abort()
    if not stat.S_ISREG(metadata.st_mode):
        abort()
    executable = bool(metadata.st_mode & stat.S_IXUSR)
    if executable != (mode == "100755"):
        abort()
    digest = hashlib.sha1()
    digest.update(f"blob {metadata.st_size}\0".encode("ascii"))
    try:
        with path.open("rb") as handle:
            while chunk := handle.read(1024 * 1024):
                digest.update(chunk)
    except OSError:
        abort()
    if digest.hexdigest() != expected_hash:
        abort()
PY
}

safe_git_status() {
  $GIT -c core.fsmonitor=false -c core.untrackedCache=false status --porcelain=v1 --untracked-files=all
}

generated_tree_is_clean() {
  local status
  worktree_matches_commit || return 1
  $GIT -c core.fsmonitor=false -c core.untrackedCache=false --no-pager diff --no-ext-diff --quiet --exit-code || return 1
  status="$(safe_git_status 2>/dev/null)" || return 1
  [[ -z "$status" ]]
}

assert_clean_index() {
  local index_state="$TMP/index-state"
  local status head object_type resolved_commit
  validate_local_git_config
  $GIT ls-files -v -z > "$index_state" 2>/dev/null || fail git-status-failed
  while IFS= read -r -d '' entry; do
    [[ "$entry" == H\ * ]] || fail dirty-checkout 20
  done < "$index_state"
  object_type="$($GIT cat-file -t "$COMMIT" 2>/dev/null)" || fail commit-mismatch 21
  [[ "$object_type" == commit ]] || fail commit-mismatch 21
  resolved_commit="$($GIT rev-parse --verify "$COMMIT^{commit}" 2>/dev/null)" || fail commit-mismatch 21
  [[ "$resolved_commit" == "$COMMIT" ]] || fail commit-mismatch 21
  head="$($GIT rev-parse HEAD 2>/dev/null)" || fail commit-mismatch 21
  [[ "$head" == "$COMMIT" ]] || fail commit-mismatch 21
  worktree_matches_commit || fail dirty-checkout 20
  status="$(safe_git_status 2>/dev/null)" || fail git-status-failed
  [[ -z "$status" ]] || fail dirty-checkout 20
}

assert_ignored_inventory() {
  local ignored="$TMP/ignored-files"
  local path
  $GIT ls-files --others --ignored --exclude-standard -z > "$ignored" 2>/dev/null || fail git-status-failed
  while IFS= read -r -d '' path; do
    case "$path" in
      .superpowers/*|Config/legacy-rights.local.tsv|Tools/bin/xcodegen|Tools/bin/XcodeGen_XcodeGenKit.bundle/SettingPresets/*|.release-work/*) ;;
      *) fail dirty-checkout 20 ;;
    esac
  done < "$ignored"
}

verify_commit_file() {
  local path="$1"
  local expected_blob actual_blob mode
  [[ -f "$path" && ! -L "$path" ]] || return 1
  $GIT ls-files --error-unmatch -- "$path" >/dev/null 2>&1 || return 1
  expected_blob="$($GIT rev-parse "$COMMIT:$path" 2>/dev/null)" || return 1
  actual_blob="$($GIT hash-object --no-filters -- "$path" 2>/dev/null)" || return 1
  [[ "$actual_blob" == "$expected_blob" ]] || return 1
  mode="$($GIT ls-tree "$COMMIT" -- "$path" | /usr/bin/awk 'NR == 1 { print $1 }')" || return 1
  case "$mode" in
    100644) [[ ! -x "$path" ]] ;;
    100755) [[ -x "$path" ]] ;;
    *) return 1 ;;
  esac
}

assert_clean_index

if ! verify_commit_file "$PACKAGE_RESOLUTION"; then
  fail missing-package-resolution 22
fi

REQUIRED_INPUTS=(
  Config/ci-toolchain.json
  Config/release-metadata.json
  Config/release-entitlements.json
  Config/release-info-policy.json
  Scripts/scan-public-history.sh
  Scripts/release/read-metadata.py
  Scripts/release/verify-entitlements.py
  Scripts/release/verify-info-policy.py
  docs/release/evidence-schema.json
  Scripts/release/verify-candidate.sh
  App/Supporting/UtterInk.entitlements
  App/Supporting/Info.plist
  Tests/ATSPolicyProbe/Info.plist
  Packages/UtterInkKit/Package.swift
  project.yml
  UtterInk.xcodeproj/project.pbxproj
  UtterInk.xcodeproj/project.xcworkspace/contents.xcworkspacedata
  UtterInk.xcodeproj/xcshareddata/xcschemes/UtterInk.xcscheme
)
for required in "${REQUIRED_INPUTS[@]}"; do
  verify_commit_file "$required" || {
    if [[ "$required" == Config/ci-toolchain.json ]]; then
      fail toolchain-lock-missing 24
    fi
    fail required-input-mismatch
  }
done
assert_ignored_inventory

# Keep every tracked helper and direct policy/schema input used below open for
# the duration of verification.  The worktree name must continue to identify
# the same commit-bound inode, while execution and reads use the held FD.
HISTORY_FD=50
READ_METADATA_FD=51
VERIFY_ENTITLEMENTS_FD=52
VERIFY_INFO_FD=53
TOOLCHAIN_LOCK_FD=54
RELEASE_METADATA_FD=55
RELEASE_ENTITLEMENTS_FD=56
RELEASE_INFO_FD=57
EVIDENCE_SCHEMA_FD=58
PACKAGE_RESOLUTION_FD=59
exec 50< Scripts/scan-public-history.sh
exec 51< Scripts/release/read-metadata.py
exec 52< Scripts/release/verify-entitlements.py
exec 53< Scripts/release/verify-info-policy.py
exec 54< Config/ci-toolchain.json
exec 55< Config/release-metadata.json
exec 56< Config/release-entitlements.json
exec 57< Config/release-info-policy.json
exec 58< docs/release/evidence-schema.json
exec 59< "$PACKAGE_RESOLUTION"

HELD_INPUT_PATHS=(
  Scripts/scan-public-history.sh
  Scripts/release/read-metadata.py
  Scripts/release/verify-entitlements.py
  Scripts/release/verify-info-policy.py
  Config/ci-toolchain.json
  Config/release-metadata.json
  Config/release-entitlements.json
  Config/release-info-policy.json
  docs/release/evidence-schema.json
  "$PACKAGE_RESOLUTION"
)
HELD_INPUT_FDS=(
  "$HISTORY_FD"
  "$READ_METADATA_FD"
  "$VERIFY_ENTITLEMENTS_FD"
  "$VERIFY_INFO_FD"
  "$TOOLCHAIN_LOCK_FD"
  "$RELEASE_METADATA_FD"
  "$RELEASE_ENTITLEMENTS_FD"
  "$RELEASE_INFO_FD"
  "$EVIDENCE_SCHEMA_FD"
  "$PACKAGE_RESOLUTION_FD"
)

assert_commit_bound_fd() {
  local path="$1"
  local descriptor="$2"
  local expected_blob expected_mode
  expected_blob="$($GIT rev-parse "$COMMIT:$path" 2>/dev/null)" || return 1
  expected_mode="$($GIT ls-tree "$COMMIT" -- "$path" | /usr/bin/awk 'NR == 1 { print $1 }')" || return 1
  "$PYTHON" -I - "$ROOT/$path" "$descriptor" "$expected_blob" "$expected_mode" <<'PY' >/dev/null 2>&1
import hashlib
import os
import stat
import sys

path, descriptor_text, expected_blob, expected_mode = sys.argv[1:]
descriptor = int(descriptor_text)
try:
    before = os.fstat(descriptor)
    named = os.lstat(path)
except OSError:
    raise SystemExit(1)
if (
    not stat.S_ISREG(before.st_mode)
    or stat.S_ISLNK(named.st_mode)
    or before.st_uid != os.geteuid()
    or before.st_nlink != 1
    or (before.st_dev, before.st_ino) != (named.st_dev, named.st_ino)
):
    raise SystemExit(1)
mode = "100755" if before.st_mode & stat.S_IXUSR else "100644"
if mode != expected_mode:
    raise SystemExit(1)
content = bytearray()
offset = 0
while offset < before.st_size:
    chunk = os.pread(descriptor, min(1024 * 1024, before.st_size - offset), offset)
    if not chunk:
        raise SystemExit(1)
    content.extend(chunk)
    offset += len(chunk)
after = os.fstat(descriptor)
digest = hashlib.sha1()
digest.update(f"blob {len(content)}\0".encode("ascii"))
digest.update(content)
def fingerprint(value):
    return (
        value.st_dev, value.st_ino, value.st_mode, value.st_uid, value.st_gid,
        value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns,
    )


if fingerprint(before) != fingerprint(after) or digest.hexdigest() != expected_blob:
    raise SystemExit(1)
PY
}

assert_held_inputs() {
  local index
  for ((index = 0; index < ${#HELD_INPUT_PATHS[@]}; index++)); do
    assert_commit_bound_fd "${HELD_INPUT_PATHS[$index]}" "${HELD_INPUT_FDS[$index]}" || fail required-input-mismatch
  done
}

rewind_held_fd() {
  "$PYTHON" -I - "$1" <<'PY' >/dev/null 2>&1
import os
import sys
os.lseek(int(sys.argv[1]), 0, os.SEEK_SET)
PY
}

assert_held_inputs

rewind_held_fd "$TOOLCHAIN_LOCK_FD"
if ! "$PYTHON" -I - "/dev/fd/$TOOLCHAIN_LOCK_FD" "$TMP/expected-xcodegen-sha" <<'PY' > "$TMP/lock-preflight-output" 2>&1
from __future__ import annotations

import json
from pathlib import Path
import re
import sys


def abort() -> None:
    raise SystemExit(1)


def duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            abort()
        result[key] = value
    return result


def exact(value: object, keys: set[str]) -> dict[str, object]:
    if type(value) is not dict or set(value) != keys:
        abort()
    return value


lock_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
try:
    if lock_path.stat().st_size > 128 * 1024:
        abort()
    lock = json.loads(lock_path.read_text(encoding="utf-8"), object_pairs_hook=duplicate_keys)
except (OSError, UnicodeError, json.JSONDecodeError):
    abort()
top = exact(lock, {"schemaVersion", "runnerImage", "xcode", "sdk", "swift", "xcodegen", "sources"})
if type(top["schemaVersion"]) is not int or top["schemaVersion"] != 1:
    abort()
runner = exact(top["runnerImage"], {"label", "releaseTag", "commit", "imageVersion", "osVersion", "osBuild", "architecture"})
xcode = exact(top["xcode"], {"version", "build", "developerDir"})
sdk = exact(top["sdk"], {"version", "build"})
swift = exact(top["swift"], {"version"})
xcodegen = exact(
    top["xcodegen"],
    {"version", "sourceCommit", "archiveURL", "archiveSHA256", "binarySHA256", "settingPresetsSHA256"},
)
sources = exact(top["sources"], {"runnerRelease", "runnerReadme", "xcodegenRelease", "xcodegenCommit"})
if runner != {
    "label": "macos-26",
    "releaseTag": "macos-26-arm64/20260630.0213",
    "commit": "afadebc447d1a69fc726b50cd5aba055c0cfdf82",
    "imageVersion": "20260630.0213.1",
    "osVersion": "26.4",
    "osBuild": "25E246",
    "architecture": "arm64",
}:
    abort()
if xcode != {
    "version": "26.4.1",
    "build": "17E202",
    "developerDir": "/Applications/Xcode_26.4.app/Contents/Developer",
}:
    abort()
if sdk.get("version") != "26.4" or type(sdk.get("build")) is not str or re.fullmatch(r"[0-9]{2}[A-Z][0-9]{1,6}[a-z]?", sdk["build"]) is None:
    abort()
if type(swift.get("version")) is not str or re.fullmatch(r"(?:swift-driver version: [0-9]+(?:[.][0-9]+)* )?Apple Swift version 6[.]3(?:[.][0-9]+)* [(]swiftlang-[A-Za-z0-9.]+ clang-[A-Za-z0-9.]+[)]", swift["version"]) is None:
    abort()
if xcodegen != {
    "version": "2.45.4",
    "sourceCommit": "8d3d3476a69ae3e5d68e1adccc701c410c05eb36",
    "archiveURL": "https://github.com/yonaskolb/XcodeGen/archive/8d3d3476a69ae3e5d68e1adccc701c410c05eb36.tar.gz",
    "archiveSHA256": "afe64a4e9b14a91a113ae7bd2c156666ee9be51dfa84c9a6e89c89797e5d871c",
    "binarySHA256": xcodegen.get("binarySHA256"),
    "settingPresetsSHA256": xcodegen.get("settingPresetsSHA256"),
}:
    abort()
binary_hash = xcodegen.get("binarySHA256")
if type(binary_hash) is not str or re.fullmatch(r"[0-9a-f]{64}", binary_hash) is None:
    abort()
presets_hash = xcodegen.get("settingPresetsSHA256")
if type(presets_hash) is not str or re.fullmatch(r"[0-9a-f]{64}", presets_hash) is None:
    abort()
if sources != {
    "runnerRelease": "https://github.com/actions/runner-images/releases/tag/macos-26-arm64%2F20260630.0213",
    "runnerReadme": "https://github.com/actions/runner-images/blob/afadebc447d1a69fc726b50cd5aba055c0cfdf82/images/macos/macos-26-arm64-Readme.md",
    "xcodegenRelease": "https://github.com/yonaskolb/XcodeGen/releases/tag/2.45.4",
    "xcodegenCommit": "https://github.com/yonaskolb/XcodeGen/commit/8d3d3476a69ae3e5d68e1adccc701c410c05eb36",
}:
    abort()
output_path.write_text(binary_hash + "\n" + presets_hash + "\n", encoding="utf-8")
PY
then
  fail toolchain-lock-invalid 24
fi

TEST_MODE=0
if [[ "${UTTERINK_RELEASE_TEST_MODE:-}" == 1 ]]; then
  TEST_MODE=1
elif [[ -n "${UTTERINK_RELEASE_TEST_MODE:-}" ]]; then
  fail invalid-test-mode 24
fi

if [[ "$TEST_MODE" -eq 1 ]]; then
  TOOL_ROOT="${UTTERINK_RELEASE_TEST_TOOL_ROOT:-}"
  [[ "$TOOL_ROOT" == /* && -d "$TOOL_ROOT" && ! -L "$TOOL_ROOT" ]] || fail invalid-test-tool-root 24
  case "$TOOL_ROOT" in
    "$ROOT"/*) TOOL_ROOT_REL="${TOOL_ROOT#"$ROOT"/}" ;;
    *) fail invalid-test-tool-root 24 ;;
  esac
  XCODEBUILD="$TOOL_ROOT/xcodebuild"
  SWIFT="$TOOL_ROOT/swift"
  XCODEGEN_SOURCE="$TOOL_ROOT/xcodegen"
  XCODEGEN_RESOURCE_BUNDLE_SOURCE="$TOOL_ROOT/XcodeGen_XcodeGenKit.bundle"
else
  DEVELOPER_DIR_LOCKED=/Applications/Xcode_26.4.app/Contents/Developer
  XCODEBUILD=/usr/bin/xcodebuild
  SWIFT="$DEVELOPER_DIR_LOCKED/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
  XCODEGEN_SOURCE="$ROOT/Tools/bin/xcodegen"
  XCODEGEN_RESOURCE_BUNDLE_SOURCE="$ROOT/Tools/bin/XcodeGen_XcodeGenKit.bundle"
fi
if [[ "$TEST_MODE" -eq 1 ]]; then
  for tool in "$XCODEBUILD" "$SWIFT" "$XCODEGEN_SOURCE"; do
    [[ -f "$tool" && -x "$tool" && ! -L "$tool" ]] || fail toolchain-unavailable 24
  done
  for tool in "$TOOL_ROOT_REL/xcodebuild" "$TOOL_ROOT_REL/swift" "$TOOL_ROOT_REL/xcodegen"; do
    verify_commit_file "$tool" || fail invalid-test-tool-root 24
  done
else
  [[ ! -L "$ROOT/Tools" && ! -L "$ROOT/Tools/bin" ]] || fail toolchain-unavailable 24
  [[ -f "$XCODEBUILD" && -x "$XCODEBUILD" && ! -L "$XCODEBUILD" ]] || fail toolchain-unavailable 24
  [[ -f "$XCODEGEN_SOURCE" && -x "$XCODEGEN_SOURCE" && ! -L "$XCODEGEN_SOURCE" ]] || fail toolchain-unavailable 24
  [[ -f "$SWIFT" && -x "$SWIFT" ]] || fail toolchain-unavailable 24
  if ! "$PYTHON" -I - "$SWIFT" "$DEVELOPER_DIR_LOCKED" <<'PY' > /dev/null 2>&1
from pathlib import Path
import sys

try:
    tool = Path(sys.argv[1]).resolve(strict=True)
    developer = Path(sys.argv[2]).resolve(strict=True)
    tool.relative_to(developer)
except (OSError, ValueError):
    raise SystemExit(1)
if not tool.is_file():
    raise SystemExit(1)
PY
  then
    fail toolchain-unavailable 24
  fi
fi

EXPECTED_XCODEGEN_HASH="$(/usr/bin/sed -n '1p' "$TMP/expected-xcodegen-sha")"
EXPECTED_XCODEGEN_PRESETS_SHA="$(/usr/bin/sed -n '2p' "$TMP/expected-xcodegen-sha")"
[[ "$EXPECTED_XCODEGEN_HASH" =~ ^[0-9a-f]{64}$ && "$EXPECTED_XCODEGEN_PRESETS_SHA" =~ ^[0-9a-f]{64}$ ]] ||
  fail toolchain-lock-invalid 24

verify_xcodegen_resource_bundle() {
  $PYTHON -I - "$1" "$2" <<'PY' >/dev/null 2>&1
from __future__ import annotations

import hashlib
import os
import re
import stat
import struct
import sys


bundle = sys.argv[1]
expected = sys.argv[2]
if re.fullmatch(r"[0-9a-f]{64}", expected) is None:
    raise SystemExit(1)

directory_flags = os.O_RDONLY | os.O_DIRECTORY
file_flags = os.O_RDONLY
if hasattr(os, "O_NOFOLLOW"):
    directory_flags |= os.O_NOFOLLOW
    file_flags |= os.O_NOFOLLOW


def identity(value: os.stat_result) -> tuple[int, ...]:
    return (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_uid,
        value.st_gid,
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def safe_directory(value: os.stat_result, device: int) -> bool:
    return (
        stat.S_ISDIR(value.st_mode)
        and value.st_dev == device
        and value.st_uid == os.geteuid()
        and value.st_mode & 0o022 == 0
    )


files: list[tuple[bytes, bytes]] = []
directories: set[str] = {""}
total_size = 0


def walk(directory_fd: int, prefix: str, depth: int, device: int) -> None:
    global total_size
    if depth > 8:
        raise ValueError
    opened_directory = os.fstat(directory_fd)
    if not safe_directory(opened_directory, device):
        raise ValueError
    with os.scandir(directory_fd) as iterator:
        entries = list(iterator)
    if len(entries) > 256:
        raise ValueError
    for entry in entries:
        name = entry.name
        name_bytes = name.encode("utf-8", errors="strict")
        if not name or name in {".", ".."} or b"\x00" in name_bytes or b"/" in name_bytes:
            raise ValueError
        relative = f"{prefix}/{name}" if prefix else name
        relative_bytes = relative.encode("utf-8", errors="strict")
        if len(relative_bytes) > 512:
            raise ValueError
        before = entry.stat(follow_symlinks=False)
        if stat.S_ISLNK(before.st_mode):
            raise ValueError
        if stat.S_ISDIR(before.st_mode):
            if not safe_directory(before, device):
                raise ValueError
            child_fd = os.open(name, directory_flags, dir_fd=directory_fd)
            try:
                opened = os.fstat(child_fd)
                if identity(opened) != identity(before):
                    raise ValueError
                directories.add(relative)
                walk(child_fd, relative, depth + 1, device)
                if identity(os.fstat(child_fd)) != identity(opened):
                    raise ValueError
            finally:
                os.close(child_fd)
            continue
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_dev != device
            or before.st_uid != os.geteuid()
            or before.st_nlink != 1
            or before.st_mode & 0o133
            or before.st_size < 0
            or before.st_size > 1024 * 1024
        ):
            raise ValueError
        descriptor = os.open(name, file_flags, dir_fd=directory_fd)
        try:
            opened = os.fstat(descriptor)
            if identity(opened) != identity(before):
                raise ValueError
            content = bytearray()
            offset = 0
            while offset < opened.st_size:
                chunk = os.pread(descriptor, min(1024 * 1024, opened.st_size - offset), offset)
                if not chunk:
                    raise ValueError
                content.extend(chunk)
                offset += len(chunk)
            if identity(os.fstat(descriptor)) != identity(opened):
                raise ValueError
        finally:
            os.close(descriptor)
        total_size += len(content)
        if total_size > 8 * 1024 * 1024 or len(files) >= 256:
            raise ValueError
        files.append((relative_bytes, bytes(content)))


bundle_fd = -1
presets_fd = -1
try:
    named_bundle = os.lstat(bundle)
    if not stat.S_ISDIR(named_bundle.st_mode) or stat.S_ISLNK(named_bundle.st_mode):
        raise ValueError
    bundle_fd = os.open(bundle, directory_flags)
    opened_bundle = os.fstat(bundle_fd)
    device = opened_bundle.st_dev
    if identity(opened_bundle) != identity(named_bundle) or not safe_directory(opened_bundle, device):
        raise ValueError
    with os.scandir(bundle_fd) as iterator:
        entries = list(iterator)
    if len(entries) != 1 or entries[0].name != "SettingPresets":
        raise ValueError
    named_presets = entries[0].stat(follow_symlinks=False)
    if not safe_directory(named_presets, device):
        raise ValueError
    presets_fd = os.open("SettingPresets", directory_flags, dir_fd=bundle_fd)
    opened_presets = os.fstat(presets_fd)
    if identity(opened_presets) != identity(named_presets):
        raise ValueError
    walk(presets_fd, "", 0, device)
    if identity(os.fstat(presets_fd)) != identity(opened_presets):
        raise ValueError
    if identity(os.fstat(bundle_fd)) != identity(opened_bundle):
        raise ValueError
except (OSError, UnicodeError, ValueError):
    raise SystemExit(1)
finally:
    if presets_fd >= 0:
        os.close(presets_fd)
    if bundle_fd >= 0:
        os.close(bundle_fd)

if not files:
    raise SystemExit(1)
required_directories = {""}
for path_bytes, _ in files:
    parts = path_bytes.decode("utf-8").split("/")
    required_directories.update("/".join(parts[:index]) for index in range(1, len(parts)))
if directories != required_directories:
    raise SystemExit(1)

digest = hashlib.sha256()
for relative_bytes, content in sorted(files, key=lambda value: value[0]):
    digest.update(struct.pack(">Q", len(relative_bytes)))
    digest.update(relative_bytes)
    digest.update(struct.pack(">Q", len(content)))
    digest.update(content)
if digest.hexdigest() != expected:
    raise SystemExit(1)
PY
}

verify_xcodegen_resource_bundle "$XCODEGEN_RESOURCE_BUNDLE_SOURCE" "$EXPECTED_XCODEGEN_PRESETS_SHA" ||
  fail toolchain-mismatch 24
XCODEGEN_RESOURCE_BUNDLE="$TMP/XcodeGen_XcodeGenKit.bundle"
/usr/bin/env COPYFILE_DISABLE=1 /bin/cp -R "$XCODEGEN_RESOURCE_BUNDLE_SOURCE" "$XCODEGEN_RESOURCE_BUNDLE" ||
  fail toolchain-unavailable 24
verify_xcodegen_resource_bundle "$XCODEGEN_RESOURCE_BUNDLE" "$EXPECTED_XCODEGEN_PRESETS_SHA" ||
  fail toolchain-mismatch 24

XCODEGEN="$TMP/xcodegen"
/bin/cp "$XCODEGEN_SOURCE" "$XCODEGEN" || fail toolchain-unavailable 24
/bin/chmod 0700 "$XCODEGEN" || fail toolchain-unavailable 24
ACTUAL_XCODEGEN_HASH="$($SHASUM -a 256 "$XCODEGEN" | /usr/bin/awk '{print $1}')" || fail toolchain-mismatch 24
[[ "$ACTUAL_XCODEGEN_HASH" == "$EXPECTED_XCODEGEN_HASH" ]] || fail toolchain-mismatch 24

if [[ "$TEST_MODE" -eq 1 ]]; then
  DEVELOPER_DIR_VALUE=/Applications/Xcode_26.4.app/Contents/Developer
else
  DEVELOPER_DIR_VALUE="$DEVELOPER_DIR_LOCKED"
fi

/bin/mkdir -p "$TMP/empty-home" "$TMP/history-tmp"
run_history_scan() {
  local output="$1"
  local status=0
  shift
  assert_commit_bound_fd Scripts/scan-public-history.sh "$HISTORY_FD" || return 1
  rewind_held_fd "$HISTORY_FD" || return 1
  if [[ "$TEST_MODE" -eq 1 ]]; then
    [[ "${UTTERINK_FIXTURE_LOG:-}" == /* ]] || return 1
    /usr/bin/env -i \
      PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      HOME="$TMP/empty-home" \
      TMPDIR="$TMP/history-tmp" \
      LC_ALL=C \
      UTTERINK_FIXTURE_LOG="$UTTERINK_FIXTURE_LOG" \
      /bin/bash "/dev/fd/$HISTORY_FD" "$@" > "$output" 2>&1 || status=$?
  else
    /usr/bin/env -i \
      PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      HOME="$TMP/empty-home" \
      TMPDIR="$TMP/history-tmp" \
      LC_ALL=C \
      /bin/bash "/dev/fd/$HISTORY_FD" "$@" > "$output" 2>&1 || status=$?
  fi
  assert_commit_bound_fd Scripts/scan-public-history.sh "$HISTORY_FD" || return 1
  return "$status"
}

run_held_python() {
  local descriptor="$1"
  local logical_path="$2"
  shift 2
  "$PYTHON" -I - "$descriptor" "$logical_path" "$@" <<'PY'
import os
import stat
import sys

descriptor = int(sys.argv[1])
logical_path = sys.argv[2]
arguments = sys.argv[3:]
before = os.fstat(descriptor)
if not stat.S_ISREG(before.st_mode):
    raise SystemExit(1)
content = bytearray()
offset = 0
while offset < before.st_size:
    chunk = os.pread(descriptor, min(1024 * 1024, before.st_size - offset), offset)
    if not chunk:
        raise SystemExit(1)
    content.extend(chunk)
    offset += len(chunk)
def fingerprint(value):
    return (
        value.st_dev, value.st_ino, value.st_mode, value.st_uid, value.st_gid,
        value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns,
    )


if fingerprint(os.fstat(descriptor)) != fingerprint(before):
    raise SystemExit(1)
try:
    source = bytes(content).decode("utf-8", errors="strict")
except UnicodeDecodeError:
    raise SystemExit(1)
sys.argv = [logical_path, *arguments]
namespace = {
    "__name__": "__main__",
    "__file__": logical_path,
    "__package__": None,
    "__cached__": None,
}
exec(compile(source, logical_path, "exec"), namespace, namespace)
PY
}

if ! DEVELOPER_DIR="$DEVELOPER_DIR_VALUE" "$XCODEBUILD" -version > "$TMP/xcode-version" 2> "$TMP/tool-error"; then
  fail toolchain-mismatch 24
fi
if ! DEVELOPER_DIR="$DEVELOPER_DIR_VALUE" "$XCODEBUILD" -version -sdk macosx SDKVersion > "$TMP/sdk-version" 2> "$TMP/tool-error"; then
  fail toolchain-mismatch 24
fi
if ! DEVELOPER_DIR="$DEVELOPER_DIR_VALUE" "$XCODEBUILD" -version -sdk macosx ProductBuildVersion > "$TMP/sdk-build" 2> "$TMP/tool-error"; then
  fail toolchain-mismatch 24
fi
if ! DEVELOPER_DIR="$DEVELOPER_DIR_VALUE" "$SWIFT" --version > "$TMP/swift-version" 2> "$TMP/tool-error"; then
  fail toolchain-mismatch 24
fi
if ! "$XCODEGEN" --version > "$TMP/xcodegen-version" 2> "$TMP/tool-error"; then
  fail toolchain-mismatch 24
fi
if ! "$SHASUM" -a 256 "$XCODEGEN" > "$TMP/xcodegen-sha" 2> "$TMP/tool-error"; then
  fail toolchain-mismatch 24
fi
[[ "$(/usr/bin/awk 'NR == 1 { print $1 }' "$TMP/xcodegen-sha")" == "$EXPECTED_XCODEGEN_HASH" ]] || fail toolchain-mismatch 24

rewind_held_fd "$TOOLCHAIN_LOCK_FD"
if ! "$PYTHON" -I - \
  "/dev/fd/$TOOLCHAIN_LOCK_FD" \
  "$TMP/xcode-version" \
  "$TMP/sdk-version" \
  "$TMP/sdk-build" \
  "$TMP/swift-version" \
  "$TMP/xcodegen-version" \
  "$TMP/xcodegen-sha" \
  "$TMP/toolchain.json" <<'PY' > "$TMP/tool-validation-output" 2>&1
from __future__ import annotations

import json
from pathlib import Path
import re
import sys
from urllib.parse import urlparse


def abort() -> None:
    raise SystemExit(1)


def duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, item in pairs:
        if key in value:
            abort()
        value[key] = item
    return value


def exact_object(value: object, keys: set[str]) -> dict[str, object]:
    if type(value) is not dict or set(value) != keys:
        abort()
    return value


def string(value: object, pattern: str | None = None) -> str:
    if type(value) is not str or not value or len(value) > 1024:
        abort()
    if pattern is not None and re.fullmatch(pattern, value) is None:
        abort()
    return value


arguments = [Path(item) for item in sys.argv[1:]]
lock_path, xcode_path, sdk_version_path, sdk_build_path, swift_path, xcodegen_path, sha_path, output_path = arguments
try:
    lock = json.loads(lock_path.read_text(encoding="utf-8"), object_pairs_hook=duplicate_keys)
except (OSError, UnicodeError, json.JSONDecodeError):
    abort()

top = exact_object(
    lock,
    {"schemaVersion", "runnerImage", "xcode", "sdk", "swift", "xcodegen", "sources"},
)
if type(top["schemaVersion"]) is not int or top["schemaVersion"] != 1:
    abort()
runner = exact_object(
    top["runnerImage"],
    {"label", "releaseTag", "commit", "imageVersion", "osVersion", "osBuild", "architecture"},
)
xcode = exact_object(top["xcode"], {"version", "build", "developerDir"})
sdk = exact_object(top["sdk"], {"version", "build"})
swift = exact_object(top["swift"], {"version"})
xcodegen = exact_object(
    top["xcodegen"],
    {"version", "sourceCommit", "archiveURL", "archiveSHA256", "binarySHA256", "settingPresetsSHA256"},
)
sources = exact_object(
    top["sources"],
    {"runnerRelease", "runnerReadme", "xcodegenRelease", "xcodegenCommit"},
)

if runner["label"] != "macos-26" or runner["architecture"] != "arm64":
    abort()
string(runner["releaseTag"], r"macos-26-arm64/[0-9]{8}[.][0-9]{4}")
string(runner["commit"], r"[0-9a-f]{40}")
string(runner["imageVersion"], r"[0-9]{8}[.][0-9]{4}[.][0-9]+")
string(runner["osVersion"], r"[0-9]+[.][0-9]+(?:[.][0-9]+)?")
string(runner["osBuild"], r"[0-9]{2}[A-Z][0-9]{1,6}[a-z]?")
if xcode != {
    "version": "26.4.1",
    "build": "17E202",
    "developerDir": "/Applications/Xcode_26.4.app/Contents/Developer",
}:
    abort()
if sdk["version"] != "26.4":
    abort()
string(sdk["build"], r"[0-9]{2}[A-Z][0-9]{1,6}[a-z]?")
string(swift["version"], r"(?:swift-driver version: [0-9]+(?:[.][0-9]+)* )?Apple Swift version 6[.]3(?:[.][0-9]+)* [(]swiftlang-[A-Za-z0-9.]+ clang-[A-Za-z0-9.]+[)]")
if xcodegen["version"] != "2.45.4":
    abort()
string(xcodegen["sourceCommit"], r"[0-9a-f]{40}")
string(xcodegen["archiveSHA256"], r"[0-9a-f]{64}")
string(xcodegen["binarySHA256"], r"[0-9a-f]{64}")
string(xcodegen["settingPresetsSHA256"], r"[0-9a-f]{64}")
archive_url = string(xcodegen["archiveURL"])
parsed_archive = urlparse(archive_url)
if (
    parsed_archive.scheme != "https"
    or parsed_archive.netloc != "github.com"
    or parsed_archive.username is not None
    or parsed_archive.password is not None
    or parsed_archive.query
    or parsed_archive.fragment
    or not parsed_archive.path.startswith("/yonaskolb/XcodeGen/archive/")
):
    abort()
for key, value in sources.items():
    parsed = urlparse(string(value))
    expected_prefix = "/actions/runner-images/" if key.startswith("runner") else "/yonaskolb/XcodeGen/"
    if (
        parsed.scheme != "https"
        or parsed.netloc != "github.com"
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or not parsed.path.startswith(expected_prefix)
    ):
        abort()

xcode_lines = xcode_path.read_text(encoding="utf-8").splitlines()
if xcode_lines != [f"Xcode {xcode['version']}", f"Build version {xcode['build']}"]:
    abort()
sdk_version = sdk_version_path.read_text(encoding="utf-8").strip()
sdk_build = sdk_build_path.read_text(encoding="utf-8").strip()
if sdk_version != sdk["version"] or sdk_build != sdk["build"]:
    abort()
swift_lines = [line.strip() for line in swift_path.read_text(encoding="utf-8").splitlines() if line.strip()]
version_lines = [line for line in swift_lines if "Apple Swift version" in line]
if len(version_lines) != 1 or version_lines[0] != swift["version"]:
    abort()
xcodegen_output = xcodegen_path.read_text(encoding="utf-8").strip()
match = re.fullmatch(r"(?:Version: )?([0-9]+(?:[.][0-9]+)*)", xcodegen_output)
if match is None or match.group(1) != xcodegen["version"]:
    abort()
binary_hash_parts = sha_path.read_text(encoding="utf-8").split()
if len(binary_hash_parts) < 1 or binary_hash_parts[0] != xcodegen["binarySHA256"]:
    abort()

normalized = {
    "xcodeVersion": xcode["version"],
    "xcodeBuild": xcode["build"],
    "sdkVersion": sdk["version"],
    "sdkBuild": sdk["build"],
    "swiftVersion": swift["version"],
    "xcodegenVersion": xcodegen["version"],
    "xcodegenBinarySHA256": xcodegen["binarySHA256"],
}
output_path.write_text(json.dumps(normalized, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
then
  fail toolchain-mismatch 24
fi

if [[ -n "$EXPECTED_ORIGIN" ]]; then
  if ! run_history_scan "$TMP/history-output" --expected-origin "$EXPECTED_ORIGIN"; then
    fail history-verification-failed 25
  fi
else
  if ! run_history_scan "$TMP/history-output"; then
    fail history-verification-failed 25
  fi
fi

assert_commit_bound_fd Scripts/release/read-metadata.py "$READ_METADATA_FD" || fail required-input-mismatch
if ! run_held_python "$READ_METADATA_FD" "$ROOT/Scripts/release/read-metadata.py" --json > "$TMP/metadata.json" 2> "$TMP/metadata-error"; then
  fail metadata-mismatch 23
fi
assert_commit_bound_fd Scripts/release/read-metadata.py "$READ_METADATA_FD" || fail required-input-mismatch
assert_commit_bound_fd Scripts/release/verify-entitlements.py "$VERIFY_ENTITLEMENTS_FD" || fail required-input-mismatch
if ! run_held_python "$VERIFY_ENTITLEMENTS_FD" "$ROOT/Scripts/release/verify-entitlements.py" > "$TMP/entitlements-output" 2> "$TMP/entitlements-error"; then
  fail entitlement-policy-failed 26
fi
assert_commit_bound_fd Scripts/release/verify-entitlements.py "$VERIFY_ENTITLEMENTS_FD" || fail required-input-mismatch
assert_commit_bound_fd Scripts/release/verify-info-policy.py "$VERIFY_INFO_FD" || fail required-input-mismatch
if ! run_held_python "$VERIFY_INFO_FD" "$ROOT/Scripts/release/verify-info-policy.py" > "$TMP/info-output" 2> "$TMP/info-error"; then
  fail info-policy-failed 26
fi
assert_commit_bound_fd Scripts/release/verify-info-policy.py "$VERIFY_INFO_FD" || fail required-input-mismatch

rewind_held_fd "$PACKAGE_RESOLUTION_FD"
PACKAGE_HASH_BEFORE="$($SHASUM -a 256 "/dev/fd/$PACKAGE_RESOLUTION_FD" | /usr/bin/awk '{print $1}')" || fail package-resolution-mismatch 22
if ! DEVELOPER_DIR="$DEVELOPER_DIR_VALUE" "$SWIFT" package \
  --package-path Packages/UtterInkKit \
  --scratch-path "$TMP/SwiftPM" \
  resolve > "$TMP/swift-resolve-output" 2> "$TMP/swift-resolve-error"; then
  fail package-resolution-mismatch 22
fi
if ! DEVELOPER_DIR="$DEVELOPER_DIR_VALUE" "$XCODEBUILD" \
  -resolvePackageDependencies \
  -project UtterInk.xcodeproj \
  -scheme UtterInk \
  -clonedSourcePackagesDirPath "$TMP/SourcePackages" \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile > "$TMP/xcode-resolve-output" 2> "$TMP/xcode-resolve-error"; then
  fail package-resolution-mismatch 22
fi
if [[ ! -f "$TMP/SourcePackages/workspace-state.json" || -L "$TMP/SourcePackages/workspace-state.json" ]]; then
  fail package-resolution-mismatch 22
fi
if ! "$PYTHON" -I - "$PACKAGE_RESOLUTION" "$TMP/SourcePackages/workspace-state.json" <<'PY' > "$TMP/workspace-state-output" 2>&1
from __future__ import annotations

import json
from pathlib import Path
import sys


def abort() -> None:
    raise SystemExit(1)


def duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, item in pairs:
        if key in value:
            abort()
        value[key] = item
    return value


def read(path: Path) -> object:
    try:
        if path.stat().st_size > 2 * 1024 * 1024:
            abort()
        return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=duplicate_keys)
    except (OSError, UnicodeError, json.JSONDecodeError):
        abort()


package = read(Path(sys.argv[1]))
workspace = read(Path(sys.argv[2]))
if type(package) is not dict or set(package) != {"pins", "version"} or type(package["pins"]) is not list:
    abort()
package_graph: dict[str, tuple[str, str, str, str]] = {}
for pin in package["pins"]:
    if type(pin) is not dict or set(pin) != {"identity", "kind", "location", "state"}:
        abort()
    state = pin["state"]
    if type(state) is not dict or set(state) != {"revision", "version"}:
        abort()
    values = (pin["kind"], pin["location"], state["revision"], state["version"])
    if type(pin["identity"]) is not str or any(type(item) is not str or not item for item in values):
        abort()
    if pin["identity"] in package_graph:
        abort()
    package_graph[pin["identity"]] = values

if type(workspace) is not dict or set(workspace) != {"object", "version"} or type(workspace["version"]) is not int:
    abort()
body = workspace["object"]
if type(body) is not dict or set(body) != {"artifacts", "dependencies", "prebuilts"}:
    abort()
if body["artifacts"] != [] or body["prebuilts"] != [] or type(body["dependencies"]) is not list:
    abort()
workspace_graph: dict[str, tuple[str, str, str, str]] = {}
for dependency in body["dependencies"]:
    if type(dependency) is not dict or set(dependency) != {"basedOn", "packageRef", "state", "subpath"}:
        abort()
    if dependency["basedOn"] is not None or type(dependency["subpath"]) is not str:
        abort()
    reference = dependency["packageRef"]
    state = dependency["state"]
    if type(reference) is not dict or set(reference) != {"identity", "kind", "location", "name"}:
        abort()
    if type(state) is not dict or set(state) != {"checkoutState", "name"} or state["name"] != "sourceControlCheckout":
        abort()
    checkout = state["checkoutState"]
    if type(checkout) is not dict or set(checkout) != {"revision", "version"}:
        abort()
    values = (reference["kind"], reference["location"], checkout["revision"], checkout["version"])
    if type(reference["identity"]) is not str or type(reference["name"]) is not str or any(type(item) is not str or not item for item in values):
        abort()
    if reference["identity"] in workspace_graph:
        abort()
    workspace_graph[reference["identity"]] = values
if workspace_graph != package_graph:
    abort()
PY
then
  fail package-resolution-mismatch 22
fi
assert_commit_bound_fd "$PACKAGE_RESOLUTION" "$PACKAGE_RESOLUTION_FD" || fail package-resolution-mismatch 22
rewind_held_fd "$PACKAGE_RESOLUTION_FD"
PACKAGE_HASH_AFTER="$($SHASUM -a 256 "/dev/fd/$PACKAGE_RESOLUTION_FD" | /usr/bin/awk '{print $1}')" || fail package-resolution-mismatch 22
[[ "$PACKAGE_HASH_AFTER" == "$PACKAGE_HASH_BEFORE" ]] || fail package-resolution-mismatch 22
generated_tree_is_clean || fail package-resolution-mismatch 22

[[ "$($SHASUM -a 256 "$XCODEGEN" | /usr/bin/awk '{print $1}')" == "$EXPECTED_XCODEGEN_HASH" ]] || fail toolchain-mismatch 24
verify_xcodegen_resource_bundle "$XCODEGEN_RESOURCE_BUNDLE" "$EXPECTED_XCODEGEN_PRESETS_SHA" ||
  fail toolchain-mismatch 24
if ! "$XCODEGEN" generate > "$TMP/xcodegen-output" 2> "$TMP/xcodegen-error"; then
  fail generated-project-mismatch 27
fi
[[ "$($SHASUM -a 256 "$XCODEGEN" | /usr/bin/awk '{print $1}')" == "$EXPECTED_XCODEGEN_HASH" ]] || fail toolchain-mismatch 24
verify_xcodegen_resource_bundle "$XCODEGEN_RESOURCE_BUNDLE" "$EXPECTED_XCODEGEN_PRESETS_SHA" ||
  fail toolchain-mismatch 24
if ! generated_tree_is_clean; then
  fail generated-project-mismatch 27
fi

if ! DEVELOPER_DIR="$DEVELOPER_DIR_VALUE" "$XCODEBUILD" \
  -project UtterInk.xcodeproj \
  -scheme UtterInk \
  -configuration Release \
  -showBuildSettings \
  -derivedDataPath "$TMP/DerivedData" \
  -clonedSourcePackagesDirPath "$TMP/SourcePackages" \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile > "$TMP/build-settings" 2> "$TMP/build-settings-error"; then
  fail metadata-mismatch 23
fi

if ! "$PYTHON" -I - "$TMP/metadata.json" "$TMP/build-settings" <<'PY' > "$TMP/metadata-validation-output" 2>&1
from __future__ import annotations

import json
from pathlib import Path
import re
import sys

metadata_path = Path(sys.argv[1])
settings_path = Path(sys.argv[2])
expected_metadata = {
    "product": "UtterInk",
    "marketingVersion": "0.1.0",
    "buildNumber": "1",
    "bundleIdentifier": "dev.utterink.UtterInk",
    "deploymentTarget": "14.0",
    "architecture": "arm64",
    "configuration": "Release",
    "dmgFilename": "UtterInk-0.1.0-arm64.dmg",
    "releaseTag": "v0.1.0",
}
try:
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError):
    raise SystemExit(1)
if metadata != expected_metadata:
    raise SystemExit(1)

keys = {
    "ARCHS",
    "CURRENT_PROJECT_VERSION",
    "ENABLE_HARDENED_RUNTIME",
    "MACOSX_DEPLOYMENT_TARGET",
    "MARKETING_VERSION",
    "ONLY_ACTIVE_ARCH",
    "PRODUCT_BUNDLE_IDENTIFIER",
    "SWIFT_VERSION",
}
settings: dict[str, list[str]] = {key: [] for key in keys}
target_blocks = 0
active = False
for line in settings_path.read_text(encoding="utf-8", errors="strict").splitlines():
    header = re.fullmatch(r"Build settings for action .+ and target (.+):", line)
    if header is not None:
        active = header.group(1) == "UtterInk"
        if active:
            target_blocks += 1
        continue
    match = re.fullmatch(r"\s+([A-Z][A-Z0-9_]*) = (.*)", line)
    if active and match is not None and match.group(1) in settings:
        settings[match.group(1)].append(match.group(2))
if target_blocks != 1:
    raise SystemExit(1)
if any(len(values) != 1 for values in settings.values()):
    raise SystemExit(1)
actual = {key: values[0] for key, values in settings.items()}
expected = {
    "ARCHS": metadata["architecture"],
    "CURRENT_PROJECT_VERSION": metadata["buildNumber"],
    "ENABLE_HARDENED_RUNTIME": "YES",
    "MACOSX_DEPLOYMENT_TARGET": metadata["deploymentTarget"],
    "MARKETING_VERSION": metadata["marketingVersion"],
    "ONLY_ACTIVE_ARCH": "NO",
    "PRODUCT_BUNDLE_IDENTIFIER": metadata["bundleIdentifier"],
    "SWIFT_VERSION": "5.0",
}
if actual != expected:
    raise SystemExit(1)
PY
then
  fail metadata-mismatch 23
fi

if ! generated_tree_is_clean; then
  fail generated-project-mismatch 27
fi
if [[ -n "$EXPECTED_ORIGIN" ]]; then
  if ! run_history_scan "$TMP/final-history-output" --expected-origin "$EXPECTED_ORIGIN"; then
    fail generated-project-mismatch 27
  fi
else
  if ! run_history_scan "$TMP/final-history-output"; then
    fail generated-project-mismatch 27
  fi
fi

assert_clean_index
assert_ignored_inventory
verify_commit_file "$PACKAGE_RESOLUTION" || fail package-resolution-mismatch 22
for required in "${REQUIRED_INPUTS[@]}"; do
  verify_commit_file "$required" || fail required-input-mismatch
done
assert_held_inputs
TREE="$($GIT rev-parse "$COMMIT^{tree}")" || fail source-identity-failed
rewind_held_fd "$TOOLCHAIN_LOCK_FD"
LOCK_HASH="$($SHASUM -a 256 "/dev/fd/$TOOLCHAIN_LOCK_FD" | /usr/bin/awk '{print $1}')" || fail evidence-generation-failed
rewind_held_fd "$RELEASE_METADATA_FD"
METADATA_POLICY_HASH="$($SHASUM -a 256 "/dev/fd/$RELEASE_METADATA_FD" | /usr/bin/awk '{print $1}')" || fail evidence-generation-failed
rewind_held_fd "$RELEASE_ENTITLEMENTS_FD"
ENTITLEMENTS_POLICY_HASH="$($SHASUM -a 256 "/dev/fd/$RELEASE_ENTITLEMENTS_FD" | /usr/bin/awk '{print $1}')" || fail evidence-generation-failed
rewind_held_fd "$RELEASE_INFO_FD"
INFO_POLICY_HASH="$($SHASUM -a 256 "/dev/fd/$RELEASE_INFO_FD" | /usr/bin/awk '{print $1}')" || fail evidence-generation-failed

rewind_held_fd "$EVIDENCE_SCHEMA_FD"
if ! "$PYTHON" -I - \
  "/dev/fd/$EVIDENCE_SCHEMA_FD" \
  "$TMP/metadata.json" \
  "$TMP/toolchain.json" \
  "$TMP/candidate.json" \
  "$COMMIT" \
  "$TREE" \
  "$PACKAGE_HASH_AFTER" \
  "$LOCK_HASH" \
  "$METADATA_POLICY_HASH" \
  "$ENTITLEMENTS_POLICY_HASH" \
  "$INFO_POLICY_HASH" \
  "$TEST_MODE" <<'PY' > "$TMP/evidence-error" 2>&1
from __future__ import annotations

import json
from pathlib import Path
import re
import sys

schema_path = Path(sys.argv[1])
metadata_path = Path(sys.argv[2])
toolchain_path = Path(sys.argv[3])
output_path = Path(sys.argv[4])
commit, tree, package_hash, lock_hash, metadata_hash, entitlements_hash, info_hash, test_mode = sys.argv[5:]


def duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate-key")
        result[key] = value
    return result


def validate_schema_definition(schema: object, *, root: bool = False) -> None:
    if type(schema) is not dict:
        raise ValueError("schema-object")
    if root:
        allowed = {"$schema", "title", "description", "type", "additionalProperties", "required", "properties"}
        if set(schema) != allowed:
            raise ValueError("root-keywords")
        if schema["$schema"] != "https://json-schema.org/draft/2020-12/schema":
            raise ValueError("schema-draft")
        if type(schema["title"]) is not str or type(schema["description"]) is not str:
            raise ValueError("schema-label")
    if "const" in schema:
        if set(schema) != {"const"} or type(schema["const"]) not in {str, int, bool}:
            raise ValueError("const-schema")
        return
    schema_type = schema.get("type")
    if schema_type == "object":
        allowed = {"type", "additionalProperties", "required", "properties"}
        if root:
            allowed |= {"$schema", "title", "description"}
        if set(schema) != allowed or schema.get("additionalProperties") is not False:
            raise ValueError("object-schema")
        required = schema.get("required")
        properties = schema.get("properties")
        if (
            type(required) is not list
            or any(type(key) is not str for key in required)
            or len(required) != len(set(required))
            or type(properties) is not dict
            or set(required) != set(properties)
        ):
            raise ValueError("required-schema")
        for child in properties.values():
            validate_schema_definition(child)
        return
    if schema_type == "string":
        if not set(schema).issubset({"type", "pattern", "minLength", "maxLength"}):
            raise ValueError("string-schema")
        for key in ("minLength", "maxLength"):
            if key in schema and (type(schema[key]) is not int or schema[key] < 0):
                raise ValueError("length-schema")
        if "minLength" in schema and "maxLength" in schema and schema["minLength"] > schema["maxLength"]:
            raise ValueError("length-order")
        if "pattern" in schema:
            if type(schema["pattern"]) is not str:
                raise ValueError("pattern-schema")
            re.compile(schema["pattern"])
        return
    raise ValueError("unsupported-schema")


def validate(instance: object, schema: dict[str, object]) -> None:
    if "const" in schema:
        expected = schema["const"]
        if type(instance) is not type(expected) or instance != expected:
            raise ValueError("const")
        return
    expected_type = schema.get("type")
    if expected_type == "object":
        if type(instance) is not dict:
            raise ValueError("object")
        properties = schema.get("properties")
        required = schema.get("required")
        if type(properties) is not dict or type(required) is not list:
            raise ValueError("schema")
        if set(instance) != set(required):
            raise ValueError("keys")
        if schema.get("additionalProperties") is not False:
            raise ValueError("open-object")
        for key, value in instance.items():
            child = properties.get(key)
            if type(child) is not dict:
                raise ValueError("property")
            validate(value, child)
    elif expected_type == "string":
        if type(instance) is not str:
            raise ValueError("string")
        minimum = schema.get("minLength")
        maximum = schema.get("maxLength")
        if type(minimum) is int and len(instance) < minimum:
            raise ValueError("min-length")
        if type(maximum) is int and len(instance) > maximum:
            raise ValueError("max-length")
        pattern = schema.get("pattern")
        if type(pattern) is str and re.fullmatch(pattern, instance) is None:
            raise ValueError("pattern")


try:
    schema = json.loads(schema_path.read_text(encoding="utf-8"), object_pairs_hook=duplicate_keys)
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"), object_pairs_hook=duplicate_keys)
    toolchain = json.loads(toolchain_path.read_text(encoding="utf-8"), object_pairs_hook=duplicate_keys)
    validate_schema_definition(schema, root=True)
except (OSError, UnicodeError, json.JSONDecodeError, TypeError, ValueError, re.error):
    raise SystemExit(1)

if test_mode == "0":
    evidence_type = "release-candidate"
elif test_mode == "1":
    evidence_type = "release-candidate-test"
else:
    raise SystemExit(1)

candidate = {
    "schemaVersion": 1,
    "evidenceType": evidence_type,
    "product": metadata["product"],
    "source": {
        "commit": commit,
        "tree": tree,
        "releaseTag": metadata["releaseTag"],
        "clean": True,
    },
    "release": {
        "configuration": metadata["configuration"],
        "marketingVersion": metadata["marketingVersion"],
        "buildNumber": metadata["buildNumber"],
        "bundleIdentifier": metadata["bundleIdentifier"],
        "deploymentTarget": metadata["deploymentTarget"],
        "architecture": metadata["architecture"],
        "dmgFilename": metadata["dmgFilename"],
    },
    "toolchain": {"lockSHA256": lock_hash, **toolchain},
    "packageResolution": {
        "path": "Packages/UtterInkKit/Package.resolved",
        "sha256": package_hash,
    },
    "policies": {
        "releaseMetadataSHA256": metadata_hash,
        "releaseEntitlementsSHA256": entitlements_hash,
        "releaseInfoPolicySHA256": info_hash,
        "ciToolchainSHA256": lock_hash,
    },
    "checks": {
        "history": True,
        "metadata": True,
        "entitlements": True,
        "infoPolicy": True,
        "packageResolution": True,
        "generatedProjectClean": True,
    },
}
try:
    validate(candidate, schema)
except (KeyError, TypeError, ValueError):
    raise SystemExit(1)
serialized = json.dumps(candidate, sort_keys=True, separators=(",", ":")) + "\n"
users_prefix = "/" + "Users" + "/"
home_prefix = "/" + "home" + "/"
windows_users = "C:" + "\\" + "Users" + "\\"
for forbidden in (users_prefix, home_prefix, windows_users, "FixtureTools", "BEGIN CERTIFICATE", "PRIVATE KEY"):
    if forbidden in serialized:
        raise SystemExit(1)
output_path.write_text(serialized, encoding="utf-8")
PY
then
  fail evidence-schema-mismatch 28
fi
assert_held_inputs
CANDIDATE_SOURCE_FD=60
exec 60< "$TMP/candidate.json" || fail evidence-generation-failed

if ! OUTPUT_ABSOLUTE="$($PYTHON -I - "$OUTPUT" "$ROOT" <<'PY' 2>/dev/null
from __future__ import annotations

import os
from pathlib import Path
import sys

raw = sys.argv[1]
root = Path(sys.argv[2]).resolve(strict=True)
if not raw or "\x00" in raw:
    raise SystemExit(1)
candidate = Path(raw)
if not candidate.is_absolute():
    candidate = root / candidate
candidate = Path(os.path.abspath(candidate))
current = Path(candidate.anchor)
for part in candidate.parts[1:]:
    current = current / part
    if current.exists() or current.is_symlink():
        if current.is_symlink():
            raise SystemExit(1)
if candidate == root:
    raise SystemExit(1)
print(candidate)
PY
)"; then
  fail unsafe-output 29
fi

case "$OUTPUT_ABSOLUTE" in
  "$ROOT"/.release-work/*)
    $GIT check-ignore -q -- "$OUTPUT_ABSOLUTE/candidate.json" || fail unsafe-output 29
    ;;
  "$ROOT"/*) fail unsafe-output 29 ;;
esac
assert_clean_index
assert_ignored_inventory
verify_commit_file "$PACKAGE_RESOLUTION" || fail package-resolution-mismatch 22
for required in "${REQUIRED_INPUTS[@]}"; do
  verify_commit_file "$required" || fail required-input-mismatch
done
assert_held_inputs
if ! OUTPUT_DIRECTORY_RECORD="$($PYTHON -I - "$OUTPUT_ABSOLUTE" "$OUTPUT_DIR_FD" <<'PY' 2>/dev/null
import os
from pathlib import Path
import stat
import sys

output = Path(sys.argv[1])
inherited = sys.argv[2]
flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
if inherited:
    try:
        directory_fd = os.dup(int(inherited, 10))
        opened = os.fstat(directory_fd)
        named = os.lstat(output)
    except (OSError, ValueError):
        raise SystemExit(1)
    if (opened.st_dev, opened.st_ino) != (named.st_dev, named.st_ino):
        raise SystemExit(1)
else:
    directory_fd = os.open(output.anchor, flags)
    try:
        for component in output.parts[1:]:
            try:
                next_fd = os.open(component, flags, dir_fd=directory_fd)
            except FileNotFoundError:
                parent = os.fstat(directory_fd)
                if parent.st_uid != os.geteuid() or parent.st_mode & 0o022:
                    raise SystemExit(1)
                os.mkdir(component, 0o755, dir_fd=directory_fd)
                next_fd = os.open(component, flags, dir_fd=directory_fd)
                os.fsync(directory_fd)
            os.close(directory_fd)
            directory_fd = next_fd
    except BaseException:
        os.close(directory_fd)
        raise
opened = os.fstat(directory_fd)
if (
    not stat.S_ISDIR(opened.st_mode)
    or opened.st_uid != os.geteuid()
    or opened.st_mode & 0o022
    or opened.st_nlink < 2
):
    raise SystemExit(1)
print(opened.st_dev, opened.st_ino)
os.close(directory_fd)
PY
)"; then
  fail unsafe-output 29
fi
IFS=' ' read -r OUTPUT_DIRECTORY_DEV OUTPUT_DIRECTORY_INO <<< "$OUTPUT_DIRECTORY_RECORD"
[[ "$OUTPUT_DIRECTORY_DEV" =~ ^[0-9]+$ && "$OUTPUT_DIRECTORY_INO" =~ ^[0-9]+$ ]] || fail unsafe-output 29
OUTPUT_HOLD_FD=61
exec 61< "$OUTPUT_ABSOLUTE" || fail unsafe-output 29
if ! "$PYTHON" -I - "$OUTPUT_ABSOLUTE" "$OUTPUT_HOLD_FD" "$OUTPUT_DIRECTORY_DEV" "$OUTPUT_DIRECTORY_INO" <<'PY' >/dev/null 2>&1
import os
import stat
import sys
path, descriptor_text, device_text, inode_text = sys.argv[1:]
descriptor = int(descriptor_text)
opened = os.fstat(descriptor)
named = os.lstat(path)
if (
    not stat.S_ISDIR(opened.st_mode)
    or stat.S_ISLNK(named.st_mode)
    or (opened.st_dev, opened.st_ino) != (int(device_text), int(inode_text))
    or (named.st_dev, named.st_ino) != (opened.st_dev, opened.st_ino)
):
    raise SystemExit(1)
PY
then
  fail unsafe-output 29
fi

if ! OUTPUT_RECORD="$($PYTHON -I - "$OUTPUT_ABSOLUTE" "$CANDIDATE_SOURCE_FD" "$OUTPUT_HOLD_FD" <<'PY' 2>/dev/null
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import secrets
import stat
import sys


def abort() -> None:
    raise SystemExit(1)


output = Path(sys.argv[1])
source_number = int(sys.argv[2])
inherited_directory = sys.argv[3]
if not output.is_absolute() or output == Path(output.anchor):
    abort()

try:
    source_fd = os.dup(source_number)
except OSError:
    abort()
try:
    metadata = os.fstat(source_fd)
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid() or metadata.st_size > 1024 * 1024:
        abort()
    chunks: list[bytes] = []
    remaining = metadata.st_size
    while remaining:
        chunk = os.read(source_fd, min(remaining, 1024 * 1024))
        if not chunk:
            abort()
        chunks.append(chunk)
        remaining -= len(chunk)
    content = b"".join(chunks)
    def fingerprint(value):
        return (
            value.st_dev, value.st_ino, value.st_mode, value.st_uid, value.st_gid,
            value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns,
        )
    if fingerprint(os.fstat(source_fd)) != fingerprint(metadata) or os.pread(source_fd, 1, metadata.st_size):
        abort()
finally:
    os.close(source_fd)

directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
created = False
if inherited_directory:
    try:
        inherited_number = int(inherited_directory, 10)
        if inherited_number < 3 or inherited_number > 255:
            abort()
        directory_fd = os.dup(inherited_number)
        directory = os.fstat(directory_fd)
        named = os.lstat(output)
    except (OSError, ValueError):
        abort()
    if (
        not stat.S_ISDIR(directory.st_mode)
        or not stat.S_ISDIR(named.st_mode)
        or stat.S_ISLNK(named.st_mode)
        or directory.st_uid != os.geteuid()
        or directory.st_mode & 0o022
        or directory.st_nlink < 2
        or (directory.st_dev, directory.st_ino) != (named.st_dev, named.st_ino)
    ):
        os.close(directory_fd)
        abort()
else:
    try:
        directory_fd = os.open(output.anchor, directory_flags)
    except OSError:
        abort()
    try:
        for component in output.parts[1:]:
            try:
                next_fd = os.open(component, directory_flags, dir_fd=directory_fd)
            except FileNotFoundError:
                parent = os.fstat(directory_fd)
                if parent.st_uid != os.geteuid() or parent.st_mode & 0o022:
                    abort()
                try:
                    os.mkdir(component, 0o755, dir_fd=directory_fd)
                    next_fd = os.open(component, directory_flags, dir_fd=directory_fd)
                except OSError:
                    abort()
                created = True
            except OSError:
                abort()
            os.close(directory_fd)
            directory_fd = next_fd
    except BaseException:
        os.close(directory_fd)
        raise

temporary_name: str | None = None
try:
    directory = os.fstat(directory_fd)
    if (
        not stat.S_ISDIR(directory.st_mode)
        or directory.st_uid != os.geteuid()
        or directory.st_mode & 0o022
        or directory.st_nlink < 2
    ):
        abort()
    if created:
        os.fchmod(directory_fd, 0o755)

    try:
        existing = os.stat("candidate.json", dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        existing = None
    except OSError:
        abort()
    # candidate.json is immutable release evidence.  Never replace an existing
    # name: a later repository/input check could fail after publication, and
    # deleting the new inode would otherwise destroy the prior evidence.
    if existing is not None:
        abort()

    for _ in range(32):
        candidate_name = f".candidate.json.{secrets.token_hex(12)}"
        try:
            temporary_fd = os.open(
                candidate_name,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                0o600,
                dir_fd=directory_fd,
            )
        except FileExistsError:
            continue
        except OSError:
            abort()
        temporary_name = candidate_name
        break
    else:
        abort()

    try:
        view = memoryview(content)
        while view:
            written = os.write(temporary_fd, view)
            if written <= 0:
                abort()
            view = view[written:]
        os.fsync(temporary_fd)
        os.fchmod(temporary_fd, 0o644)
    finally:
        os.close(temporary_fd)

    linked = False
    try:
        os.link(
            temporary_name,
            "candidate.json",
            src_dir_fd=directory_fd,
            dst_dir_fd=directory_fd,
            follow_symlinks=False,
        )
        linked = True
        temporary_entry = os.stat(temporary_name, dir_fd=directory_fd, follow_symlinks=False)
        published_entry = os.stat("candidate.json", dir_fd=directory_fd, follow_symlinks=False)
        if (
            not stat.S_ISREG(temporary_entry.st_mode)
            or (temporary_entry.st_dev, temporary_entry.st_ino)
            != (published_entry.st_dev, published_entry.st_ino)
        ):
            abort()
        os.unlink(temporary_name, dir_fd=directory_fd)
        temporary_name = None
    except BaseException:
        if linked:
            try:
                current = os.stat("candidate.json", dir_fd=directory_fd, follow_symlinks=False)
                temporary_entry = os.stat(temporary_name, dir_fd=directory_fd, follow_symlinks=False)
                if (current.st_dev, current.st_ino) == (temporary_entry.st_dev, temporary_entry.st_ino):
                    os.unlink("candidate.json", dir_fd=directory_fd)
            except OSError:
                pass
        raise
    os.fsync(directory_fd)
    final = os.stat("candidate.json", dir_fd=directory_fd, follow_symlinks=False)
    if (
        not stat.S_ISREG(final.st_mode)
        or final.st_uid != os.geteuid()
        or final.st_nlink != 1
        or stat.S_IMODE(final.st_mode) != 0o644
        or final.st_size != len(content)
    ):
        abort()
    directory = os.fstat(directory_fd)
    print(
        directory.st_dev,
        directory.st_ino,
        final.st_dev,
        final.st_ino,
        hashlib.sha256(content).hexdigest(),
    )
finally:
    if temporary_name is not None:
        try:
            os.unlink(temporary_name, dir_fd=directory_fd)
        except OSError:
            pass
    os.close(directory_fd)
PY
)"; then
  fail unsafe-output 29
fi

IFS=' ' read -r \
  OUTPUT_DIRECTORY_DEV_AFTER OUTPUT_DIRECTORY_INO_AFTER \
  OUTPUT_FILE_DEV OUTPUT_FILE_INO OUTPUT_FILE_SHA256 <<< "$OUTPUT_RECORD"
[[ \
  "$OUTPUT_DIRECTORY_DEV_AFTER" == "$OUTPUT_DIRECTORY_DEV" && \
  "$OUTPUT_DIRECTORY_INO_AFTER" == "$OUTPUT_DIRECTORY_INO" && \
  "$OUTPUT_FILE_DEV" =~ ^[0-9]+$ && "$OUTPUT_FILE_INO" =~ ^[0-9]+$ && \
  "$OUTPUT_FILE_SHA256" =~ ^[0-9a-f]{64}$ \
]] || fail unsafe-output 29
OUTPUT_PUBLISHED=1

rollback_candidate_output() {
  "$PYTHON" -I - "$OUTPUT_HOLD_FD" "$OUTPUT_FILE_DEV" "$OUTPUT_FILE_INO" <<'PY' >/dev/null 2>&1 || true
import os
import stat
import sys
directory_fd = int(sys.argv[1])
expected = (int(sys.argv[2]), int(sys.argv[3]))
try:
    current = os.stat("candidate.json", dir_fd=directory_fd, follow_symlinks=False)
    if (
        (current.st_dev, current.st_ino) == expected
        and stat.S_ISREG(current.st_mode)
        and not stat.S_ISLNK(current.st_mode)
    ):
        os.unlink("candidate.json", dir_fd=directory_fd)
        os.fsync(directory_fd)
except OSError:
    pass
PY
}

assert_candidate_output_bound() {
  "$PYTHON" -I - \
    "$OUTPUT_ABSOLUTE" "$OUTPUT_HOLD_FD" \
    "$OUTPUT_DIRECTORY_DEV" "$OUTPUT_DIRECTORY_INO" \
    "$OUTPUT_FILE_DEV" "$OUTPUT_FILE_INO" "$OUTPUT_FILE_SHA256" \
    "$CANDIDATE_SOURCE_FD" <<'PY' >/dev/null 2>&1
import hashlib
import os
import stat
import sys

path = sys.argv[1]
directory_fd = int(sys.argv[2])
expected_directory = (int(sys.argv[3]), int(sys.argv[4]))
expected_file = (int(sys.argv[5]), int(sys.argv[6]))
expected_hash = sys.argv[7]
source_fd = int(sys.argv[8])
opened_directory = os.fstat(directory_fd)
named_directory = os.lstat(path)
if (
    (opened_directory.st_dev, opened_directory.st_ino) != expected_directory
    or (named_directory.st_dev, named_directory.st_ino) != expected_directory
    or not stat.S_ISDIR(opened_directory.st_mode)
    or stat.S_ISLNK(named_directory.st_mode)
):
    raise SystemExit(1)
named_file = os.stat("candidate.json", dir_fd=directory_fd, follow_symlinks=False)
if (
    (named_file.st_dev, named_file.st_ino) != expected_file
    or not stat.S_ISREG(named_file.st_mode)
    or stat.S_ISLNK(named_file.st_mode)
    or named_file.st_nlink != 1
    or stat.S_IMODE(named_file.st_mode) != 0o644
):
    raise SystemExit(1)
output_fd = os.open("candidate.json", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory_fd)
try:
    if (os.fstat(output_fd).st_dev, os.fstat(output_fd).st_ino) != expected_file:
        raise SystemExit(1)
    digests = []
    for descriptor in (output_fd, source_fd):
        value = hashlib.sha256()
        metadata = os.fstat(descriptor)
        offset = 0
        while offset < metadata.st_size:
            chunk = os.pread(descriptor, min(1024 * 1024, metadata.st_size - offset), offset)
            if not chunk:
                raise SystemExit(1)
            value.update(chunk)
            offset += len(chunk)
        current = os.fstat(descriptor)
        fingerprint = lambda value: (
            value.st_dev, value.st_ino, value.st_mode, value.st_uid, value.st_gid,
            value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns,
        )
        if fingerprint(current) != fingerprint(metadata):
            raise SystemExit(1)
        digests.append(value.hexdigest())
    if digests != [expected_hash, expected_hash]:
        raise SystemExit(1)
finally:
    os.close(output_fd)
PY
}

assert_candidate_output_bound || fail unsafe-output 29
assert_clean_index
assert_ignored_inventory
verify_commit_file "$PACKAGE_RESOLUTION" || fail package-resolution-mismatch 22
for required in "${REQUIRED_INPUTS[@]}"; do
  verify_commit_file "$required" || fail required-input-mismatch
done
assert_held_inputs
assert_candidate_output_bound || fail unsafe-output 29

exit 0
