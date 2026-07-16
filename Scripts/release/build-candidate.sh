#!/usr/bin/env -S -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u BASH_XTRACEFD -u PS4 -u POSIXLY_CORRECT -u BASH_COMPAT -u UTTERINK_BUILD_CANDIDATE_ENV_CLEAN /bin/bash -p

set +x +v
if [[ "$-" != *p* ]]; then
  printf 'build candidate error: unsafe-launch-environment\n' >&2
  exit 2
fi
if [[ "${UTTERINK_BUILD_CANDIDATE_ENV_CLEAN:-}" != 1 ]]; then
  clean_environment=(
    PATH=/usr/bin:/bin:/usr/sbin:/sbin
    LC_ALL=C
    UTTERINK_BUILD_CANDIDATE_ENV_CLEAN=1
  )
  if [[ "${UTTERINK_RELEASE_TEST_MODE:-}" == 1 ]]; then
    clean_environment+=(UTTERINK_RELEASE_TEST_MODE=1)
    if [[ -n "${UTTERINK_RELEASE_TEST_TOOL_ROOT+x}" ]]; then
      clean_environment+=("UTTERINK_RELEASE_TEST_TOOL_ROOT=${UTTERINK_RELEASE_TEST_TOOL_ROOT}")
    fi
    if [[ -n "${UTTERINK_FIXTURE_LOG+x}" ]]; then
      clean_environment+=("UTTERINK_FIXTURE_LOG=${UTTERINK_FIXTURE_LOG}")
    fi
  elif [[ -n "${UTTERINK_RELEASE_TEST_MODE+x}" ]]; then
    clean_environment+=("UTTERINK_RELEASE_TEST_MODE=${UTTERINK_RELEASE_TEST_MODE}")
  fi
  exec /usr/bin/env -i "${clean_environment[@]}" /bin/bash -p "$0" "$@"
  printf 'build candidate error: unsafe-launch-environment\n' >&2
  exit 2
fi
if [[ "$-" != hpB || "${PATH-}" != /usr/bin:/bin:/usr/sbin:/sbin || "${LC_ALL-}" != C ]]; then
  printf 'build candidate error: unsafe-launch-environment\n' >&2
  exit 2
fi
while IFS= read -r -d '' environment_entry; do
  environment_name="${environment_entry%%=*}"
  case "$environment_name" in
    PATH|LC_ALL|UTTERINK_BUILD_CANDIDATE_ENV_CLEAN|UTTERINK_RELEASE_TEST_MODE|UTTERINK_RELEASE_TEST_TOOL_ROOT|UTTERINK_FIXTURE_LOG|PWD|SHLVL|_) ;;
    *)
      printf 'build candidate error: unsafe-launch-environment\n' >&2
      exit 2
      ;;
  esac
done < <(/usr/bin/env -0)
unset UTTERINK_BUILD_CANDIDATE_ENV_CLEAN

set -euo pipefail

export LC_ALL=C
export GIT_NO_REPLACE_OBJECTS=1
export GIT_NO_LAZY_FETCH=1
export GIT_TERMINAL_PROMPT=0
export GIT_OPTIONAL_LOCKS=0
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export PYTHONDONTWRITEBYTECODE=1
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
unset \
  BASH_ENV ENV CDPATH GLOBIGNORE PYTHONHOME PYTHONPATH \
  PERL5OPT PERL5LIB PERLLIB PERL5DB \
  XCODE_XCCONFIG_FILE XCODE_DEFAULT_TOOLCHAIN_OVERRIDE SWIFT_EXEC SDKROOT \
  DEVELOPER_DIR TOOLCHAINS DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH \
  DEVELOPMENT_TEAM CODE_SIGN_IDENTITY PROVISIONING_PROFILE_SPECIFIER \
  PROVISIONING_PROFILE CODE_SIGN_INJECT_BASE_ENTITLEMENTS OTHER_CODE_SIGN_FLAGS
umask 077

readonly GIT=/usr/bin/git
readonly PYTHON=/usr/bin/python3
readonly SHASUM=/usr/bin/shasum

fail() {
  local category="$1"
  local status="${2:-1}"
  case "$category" in
    repository-xcodegen-missing|repository-xcodegen-mismatch|repository-xcodegen-unusable)
      printf 'build candidate error: %s; run ./Scripts/bootstrap-xcodegen.sh\n' "$category" >&2
      ;;
    *) printf 'build candidate error: %s\n' "$category" >&2 ;;
  esac
  exit "$status"
}

COMMIT=''
WORK_ARGUMENT=''
EXPECTED_ORIGIN=''
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --commit)
      [[ -z "$COMMIT" && "$#" -ge 2 && -n "$2" ]] || fail invalid-arguments 64
      COMMIT="$2"
      shift 2
      ;;
    --work)
      [[ -z "$WORK_ARGUMENT" && "$#" -ge 2 && -n "$2" ]] || fail invalid-arguments 64
      WORK_ARGUMENT="$2"
      shift 2
      ;;
    --expected-origin)
      [[ -z "$EXPECTED_ORIGIN" && "$#" -ge 2 && -n "$2" ]] || fail invalid-arguments 64
      EXPECTED_ORIGIN="$2"
      shift 2
      ;;
    *) fail invalid-arguments 64 ;;
  esac
done
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ && -n "$WORK_ARGUMENT" ]] || fail invalid-arguments 64

readonly SCRIPT_PATH="${BASH_SOURCE[0]}"
[[ -f "$SCRIPT_PATH" && ! -L "$SCRIPT_PATH" ]] || fail unsafe-script-path 20
SCRIPT_DIRECTORY="$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "$SCRIPT_PATH")" && /bin/pwd -P)" ||
  fail unsafe-script-path 20
ROOT="$(CDPATH= cd -P -- "$SCRIPT_DIRECTORY/../.." && /bin/pwd -P)" || fail unsafe-script-path 20
GIT_ROOT="$($GIT -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" || fail not-a-repository 20
GIT_ROOT="$(CDPATH= cd -P -- "$GIT_ROOT" && /bin/pwd -P)" || fail not-a-repository 20
[[ "$GIT_ROOT" == "$ROOT" ]] || fail repository-mismatch 20
cd "$ROOT"

readonly VERIFIER="$ROOT/Scripts/release/verify-candidate.sh"
readonly REPOSITORY_XCODEGEN="$ROOT/Tools/bin/xcodegen"
readonly XCODEGEN_RESOURCE_BUNDLE="$ROOT/Tools/bin/XcodeGen_XcodeGenKit.bundle"
readonly XCODEGEN_SETTING_PRESETS="$XCODEGEN_RESOURCE_BUNDLE/SettingPresets"
readonly RELEASE_WORK="$ROOT/.release-work"
[[ -f "$VERIFIER" && -x "$VERIFIER" && ! -L "$VERIFIER" ]] || fail candidate-verifier-unavailable 20

TEST_MODE=0
case "${UTTERINK_RELEASE_TEST_MODE:-}" in
  '') ;;
  1) TEST_MODE=1 ;;
  *) fail invalid-test-mode 20 ;;
esac
if [[ "$TEST_MODE" -eq 1 ]]; then
  case "$ROOT" in
    /private/tmp/*) ;;
    *) fail test-mode-not-allowed 20 ;;
  esac
  TOOL_ROOT="${UTTERINK_RELEASE_TEST_TOOL_ROOT:-}"
  [[ "$TOOL_ROOT" == "$ROOT/FixtureTools" && -d "$TOOL_ROOT" && ! -L "$TOOL_ROOT" ]] ||
    fail invalid-test-tool-root 20
  TEST_MARKER="$TOOL_ROOT/.utterink-build-candidate-test-fixture"
  [[ -f "$TEST_MARKER" && ! -L "$TEST_MARKER" ]] || fail invalid-test-tool-root 20
  [[ "$(/bin/cat "$TEST_MARKER")" == utterink-offline-build-candidate-fixture-v1 ]] ||
    fail invalid-test-tool-root 20
  [[ "${UTTERINK_FIXTURE_LOG:-}" == /* ]] || fail invalid-test-tool-root 20
else
  unset UTTERINK_RELEASE_TEST_TOOL_ROOT UTTERINK_FIXTURE_LOG
fi
readonly TEST_MODE

if ! WORK_NAME="$($PYTHON -I - "$ROOT" "$WORK_ARGUMENT" <<'PY' 2>/dev/null
from __future__ import annotations

import os
from pathlib import Path, PurePath
import re
import stat
import sys


def abort() -> None:
    raise SystemExit(1)


root = Path(sys.argv[1]).resolve(strict=True)
raw = sys.argv[2]
if (
    not raw
    or len(raw.encode("utf-8", errors="strict")) > 4096
    or any(ord(character) < 32 or ord(character) == 127 for character in raw)
    or "." in PurePath(raw).parts
    or ".." in PurePath(raw).parts
):
    abort()
candidate = Path(raw) if os.path.isabs(raw) else root / raw
candidate = Path(os.path.abspath(candidate))
release_work = root / ".release-work"
if candidate.parent != release_work:
    abort()
name = candidate.name
if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", name) is None:
    abort()
if name.startswith(".build-candidate."):
    abort()
try:
    root_metadata = os.lstat(root)
except OSError:
    abort()
if not stat.S_ISDIR(root_metadata.st_mode) or stat.S_ISLNK(root_metadata.st_mode):
    abort()
try:
    release_metadata = os.lstat(release_work)
except FileNotFoundError:
    release_metadata = None
except OSError:
    abort()
if release_metadata is not None and (
    not stat.S_ISDIR(release_metadata.st_mode)
    or stat.S_ISLNK(release_metadata.st_mode)
    or release_metadata.st_uid != os.geteuid()
    or stat.S_IMODE(release_metadata.st_mode) != 0o700
    or release_metadata.st_dev != root_metadata.st_dev
):
    abort()
try:
    os.lstat(candidate)
except FileNotFoundError:
    pass
except OSError:
    abort()
else:
    abort()
print(name)
PY
)"; then
  fail unsafe-work-path 29
fi
[[ -n "$WORK_NAME" ]] || fail unsafe-work-path 29
readonly WORK_NAME
readonly WORK_ABSOLUTE="$RELEASE_WORK/$WORK_NAME"
$GIT check-ignore -q -- "$WORK_ABSOLUTE/candidate/candidate.json" || fail unsafe-work-path 29

[[ ! -L "$RELEASE_WORK" ]] || fail unsafe-work-path 29
if [[ ! -e "$RELEASE_WORK" ]]; then
  /bin/mkdir -m 0700 "$RELEASE_WORK" || fail unsafe-work-path 29
fi
if ! $PYTHON -I - "$ROOT" "$RELEASE_WORK" <<'PY' >/dev/null 2>&1
import os
from pathlib import Path
import stat
import sys

root, work = map(Path, sys.argv[1:3])
try:
    root_metadata = os.lstat(root)
    work_metadata = os.lstat(work)
except OSError:
    raise SystemExit(1)
if (
    not stat.S_ISDIR(work_metadata.st_mode)
    or stat.S_ISLNK(work_metadata.st_mode)
    or work_metadata.st_uid != os.geteuid()
    or stat.S_IMODE(work_metadata.st_mode) != 0o700
    or work_metadata.st_dev != root_metadata.st_dev
):
    raise SystemExit(1)
PY
then
  fail unsafe-work-path 29
fi

STAGE="$(/usr/bin/mktemp -d "$RELEASE_WORK/.build-candidate.XXXXXX")" || fail unsafe-work-path 29
/bin/chmod 0700 "$STAGE" || fail unsafe-work-path 29
if ! STAGE_IDENTITY="$($PYTHON -I - "$RELEASE_WORK" "$STAGE" <<'PY' 2>/dev/null
import os
from pathlib import Path
import stat
import sys

parent, child = map(Path, sys.argv[1:3])
if child.parent != parent:
    raise SystemExit(1)
metadata = os.lstat(child)
parent_metadata = os.lstat(parent)
if (
    not stat.S_ISDIR(metadata.st_mode)
    or stat.S_ISLNK(metadata.st_mode)
    or metadata.st_uid != os.geteuid()
    or stat.S_IMODE(metadata.st_mode) != 0o700
    or metadata.st_dev != parent_metadata.st_dev
):
    raise SystemExit(1)
print(f"{metadata.st_dev}:{metadata.st_ino}")
PY
)"; then
  fail unsafe-work-path 29
fi
IFS=: read -r STAGE_DEVICE STAGE_INODE <<< "$STAGE_IDENTITY"
[[ "$STAGE_DEVICE" =~ ^[0-9]+$ && "$STAGE_INODE" =~ ^[0-9]+$ ]] || fail unsafe-work-path 29

safe_remove_tree() {
  local parent="$1"
  local name="$2"
  local expected_device="$3"
  local expected_inode="$4"
  local require_private_child="${5:-1}"
  $PYTHON -I - "$parent" "$name" "$expected_device" "$expected_inode" "$require_private_child" <<'PY' >/dev/null 2>&1
from __future__ import annotations

import os
from pathlib import Path
import stat
import sys


class CleanupError(Exception):
    pass


parent_path = Path(sys.argv[1])
name = sys.argv[2]
expected = (int(sys.argv[3]), int(sys.argv[4]))
require_private_child = sys.argv[5] == "1"
directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def identity(value: os.stat_result) -> tuple[int, int]:
    return value.st_dev, value.st_ino


def safe_generated_directory(value: os.stat_result, device: int) -> bool:
    return (
        stat.S_ISDIR(value.st_mode)
        and not stat.S_ISLNK(value.st_mode)
        and value.st_dev == device
        and value.st_uid == os.geteuid()
    )


def safe_private_directory(value: os.stat_result, device: int) -> bool:
    return safe_generated_directory(value, device) and value.st_mode & 0o022 == 0


def remove_contents(descriptor: int, device: int) -> None:
    for entry in os.listdir(descriptor):
        if entry in {".", ".."} or "/" in entry:
            raise CleanupError
        metadata = os.stat(entry, dir_fd=descriptor, follow_symlinks=False)
        if metadata.st_dev != device or metadata.st_uid != os.geteuid():
            raise CleanupError
        if stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode):
            child = os.open(entry, directory_flags, dir_fd=descriptor)
            try:
                opened = os.fstat(child)
                if identity(opened) != identity(metadata) or not safe_generated_directory(opened, device):
                    raise CleanupError
                remove_contents(child, device)
            finally:
                os.close(child)
            current = os.stat(entry, dir_fd=descriptor, follow_symlinks=False)
            if identity(current) != identity(metadata):
                raise CleanupError
            os.rmdir(entry, dir_fd=descriptor)
        else:
            os.unlink(entry, dir_fd=descriptor)


if not name or name in {".", ".."} or "/" in name:
    raise SystemExit(1)
parent_fd = child_fd = -1
try:
    parent_fd = os.open(parent_path, directory_flags)
    parent_metadata = os.fstat(parent_fd)
    if not safe_private_directory(parent_metadata, parent_metadata.st_dev):
        raise CleanupError
    child_fd = os.open(name, directory_flags, dir_fd=parent_fd)
    child_metadata = os.fstat(child_fd)
    if (
        identity(child_metadata) != expected
        or not safe_generated_directory(child_metadata, parent_metadata.st_dev)
        or (require_private_child and not safe_private_directory(child_metadata, parent_metadata.st_dev))
    ):
        raise CleanupError
    remove_contents(child_fd, parent_metadata.st_dev)
    current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    if identity(current) != expected or not stat.S_ISDIR(current.st_mode):
        raise CleanupError
    os.rmdir(name, dir_fd=parent_fd)
except (OSError, CleanupError, ValueError):
    raise SystemExit(1)
finally:
    if child_fd >= 0:
        os.close(child_fd)
    if parent_fd >= 0:
        os.close(parent_fd)
PY
}

PUBLISHED=0
cleanup() {
  local status=$?
  local cleanup_status=0
  trap - EXIT HUP INT TERM
  if [[ "$PUBLISHED" -eq 0 ]]; then
    if safe_remove_tree "$RELEASE_WORK" "$(/usr/bin/basename "$STAGE")" "$STAGE_DEVICE" "$STAGE_INODE" 1; then
      :
    elif safe_remove_tree "$RELEASE_WORK" "$WORK_NAME" "$STAGE_DEVICE" "$STAGE_INODE" 1; then
      :
    else
      cleanup_status=37
      printf 'build candidate error: work-cleanup-failed\n' >&2
    fi
  fi
  if [[ "$cleanup_status" -ne 0 ]]; then
    status="$cleanup_status"
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

/bin/mkdir -m 0700 "$STAGE/.transient" || fail unsafe-work-path 29
TRANSIENT="$STAGE/.transient"
if ! TRANSIENT_IDENTITY="$($PYTHON -I - "$STAGE" "$TRANSIENT" <<'PY' 2>/dev/null
import os
from pathlib import Path
import stat
import sys

parent, child = map(Path, sys.argv[1:3])
if child.parent != parent:
    raise SystemExit(1)
parent_metadata = os.lstat(parent)
metadata = os.lstat(child)
if (
    not stat.S_ISDIR(metadata.st_mode)
    or stat.S_ISLNK(metadata.st_mode)
    or metadata.st_uid != os.geteuid()
    or stat.S_IMODE(metadata.st_mode) != 0o700
    or metadata.st_dev != parent_metadata.st_dev
):
    raise SystemExit(1)
print(f"{metadata.st_dev}:{metadata.st_ino}")
PY
)"; then
  fail unsafe-work-path 29
fi
IFS=: read -r TRANSIENT_DEVICE TRANSIENT_INODE <<< "$TRANSIENT_IDENTITY"
[[ "$TRANSIENT_DEVICE" =~ ^[0-9]+$ && "$TRANSIENT_INODE" =~ ^[0-9]+$ ]] || fail unsafe-work-path 29

commit_blob_sha256() {
  local relative="$1"
  local blob
  blob="$($GIT rev-parse --verify "$COMMIT:$relative" 2>/dev/null)" || return 1
  [[ "$blob" =~ ^[0-9a-f]{40}$ ]] || return 1
  $GIT cat-file blob "$blob" | $SHASUM -a 256 | /usr/bin/awk 'NR == 1 { print $1 }'
}

file_fingerprint() {
  local mode="$1"
  local path="$2"
  local expected="$3"
  $PYTHON -I - "$mode" "$path" "$expected" <<'PY'
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import stat
import sys


mode, raw_path, expected = sys.argv[1:4]
path = Path(raw_path)


def fingerprint() -> dict[str, object]:
    before = os.lstat(path)
    if (
        not stat.S_ISREG(before.st_mode)
        or stat.S_ISLNK(before.st_mode)
        or before.st_uid != os.geteuid()
        or before.st_nlink != 1
        or before.st_mode & 0o022
        or stat.S_IMODE(before.st_mode) not in {0o400, 0o755}
    ):
        raise ValueError
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise ValueError
        digest = hashlib.sha256()
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
        after = os.fstat(descriptor)
        fields = (
            "st_dev", "st_ino", "st_mode", "st_uid", "st_nlink", "st_size",
            "st_mtime_ns", "st_ctime_ns",
        )
        if any(getattr(opened, field) != getattr(after, field) for field in fields):
            raise ValueError
        return {
            "device": after.st_dev,
            "inode": after.st_ino,
            "mode": after.st_mode,
            "uid": after.st_uid,
            "links": after.st_nlink,
            "size": after.st_size,
            "mtimeNS": after.st_mtime_ns,
            "ctimeNS": after.st_ctime_ns,
            "sha256": digest.hexdigest(),
        }
    finally:
        os.close(descriptor)


try:
    value = fingerprint()
    token = json.dumps(value, sort_keys=True, separators=(",", ":"))
    if mode == "capture":
        print(token)
    elif mode == "verify":
        if expected != token:
            raise ValueError
    else:
        raise ValueError
except (OSError, UnicodeError, ValueError, json.JSONDecodeError):
    raise SystemExit(1)
PY
}

VERIFIER_TREE_ENTRY="$($GIT ls-tree "$COMMIT" -- Scripts/release/verify-candidate.sh 2>/dev/null)" ||
  fail candidate-verifier-unavailable 28
VERIFIER_TREE_METADATA="${VERIFIER_TREE_ENTRY%%$'\t'*}"
VERIFIER_TREE_PATH="${VERIFIER_TREE_ENTRY#*$'\t'}"
read -r VERIFIER_TREE_MODE VERIFIER_TREE_TYPE VERIFIER_BLOB <<< "$VERIFIER_TREE_METADATA"
[[ "$VERIFIER_TREE_MODE" == 100755 && "$VERIFIER_TREE_TYPE" == blob && "$VERIFIER_BLOB" =~ ^[0-9a-f]{40}$ &&
  "$VERIFIER_TREE_PATH" == Scripts/release/verify-candidate.sh ]] || fail candidate-verifier-unavailable 28
CURRENT_VERIFIER_BLOB="$($GIT hash-object --no-filters -- "$VERIFIER" 2>/dev/null)" ||
  fail candidate-verifier-unavailable 28
[[ "$CURRENT_VERIFIER_BLOB" == "$VERIFIER_BLOB" ]] || fail candidate-verifier-unavailable 28
VERIFIER_FINGERPRINT="$(file_fingerprint capture "$VERIFIER" -)" || fail candidate-verifier-unavailable 28
[[ -n "$VERIFIER_FINGERPRINT" ]] || fail candidate-verifier-unavailable 28

EXPECTED_TREE="$($GIT rev-parse --verify "$COMMIT^{tree}" 2>/dev/null)" || fail candidate-evidence-invalid 28
[[ "$EXPECTED_TREE" =~ ^[0-9a-f]{40}$ ]] || fail candidate-evidence-invalid 28
EXPECTED_PACKAGE_SHA="$(commit_blob_sha256 Packages/UtterInkKit/Package.resolved)" || fail candidate-evidence-invalid 28
EXPECTED_LOCK_SHA="$(commit_blob_sha256 Config/ci-toolchain.json)" || fail toolchain-lock-missing 24
EXPECTED_METADATA_SHA="$(commit_blob_sha256 Config/release-metadata.json)" || fail candidate-evidence-invalid 28
EXPECTED_ENTITLEMENTS_SHA="$(commit_blob_sha256 Config/release-entitlements.json)" || fail candidate-evidence-invalid 28
EXPECTED_INFO_SHA="$(commit_blob_sha256 Config/release-info-policy.json)" || fail candidate-evidence-invalid 28
for expected_hash in \
  "$EXPECTED_PACKAGE_SHA" "$EXPECTED_LOCK_SHA" "$EXPECTED_METADATA_SHA" \
  "$EXPECTED_ENTITLEMENTS_SHA" "$EXPECTED_INFO_SHA"; do
  [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || fail candidate-evidence-invalid 28
done
COMMIT_LOCK_BLOB="$($GIT rev-parse --verify "$COMMIT:Config/ci-toolchain.json" 2>/dev/null)" ||
  fail toolchain-lock-missing 24
[[ "$COMMIT_LOCK_BLOB" =~ ^[0-9a-f]{40}$ ]] || fail candidate-evidence-invalid 28
$GIT cat-file blob "$COMMIT_LOCK_BLOB" > "$TRANSIENT/committed-ci-toolchain.json" ||
  fail candidate-evidence-invalid 28
/bin/chmod 0400 "$TRANSIENT/committed-ci-toolchain.json" || fail candidate-evidence-invalid 28

VERIFY_ARGS=(--commit "$COMMIT" --output "$TRANSIENT/verified-candidate")
if [[ -n "$EXPECTED_ORIGIN" ]]; then
  VERIFY_ARGS+=(--expected-origin "$EXPECTED_ORIGIN")
fi
"$VERIFIER" "${VERIFY_ARGS[@]}"
file_fingerprint verify "$VERIFIER" "$VERIFIER_FINGERPRINT" || fail candidate-verifier-changed 28
CURRENT_VERIFIER_BLOB="$($GIT hash-object --no-filters -- "$VERIFIER" 2>/dev/null)" ||
  fail candidate-verifier-changed 28
[[ "$CURRENT_VERIFIER_BLOB" == "$VERIFIER_BLOB" ]] || fail candidate-verifier-changed 28

VERIFIER_OUTPUT="$TRANSIENT/verified-candidate/candidate.json"
VERIFIED_CANDIDATE="$TRANSIENT/candidate.snapshot.json"
if ! $PYTHON -I - \
  "$VERIFIER_OUTPUT" "$VERIFIED_CANDIDATE" "$TEST_MODE" "$COMMIT" "$EXPECTED_TREE" \
  "$EXPECTED_PACKAGE_SHA" "$EXPECTED_LOCK_SHA" "$EXPECTED_METADATA_SHA" \
  "$EXPECTED_ENTITLEMENTS_SHA" "$EXPECTED_INFO_SHA" "$TRANSIENT/committed-ci-toolchain.json" <<'PY' >/dev/null 2>&1
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import stat
import sys


(
    source_path,
    snapshot_path,
    test_mode,
    commit,
    tree,
    package_hash,
    lock_hash,
    metadata_hash,
    entitlements_hash,
    info_hash,
    lock_path,
) = sys.argv[1:12]
source = Path(source_path)
snapshot = Path(snapshot_path)


def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError
        value[key] = item
    return value


def exact_object(value: object, keys: set[str]) -> dict[str, object]:
    if type(value) is not dict or set(value) != keys:
        raise ValueError
    return value


try:
    before = os.lstat(source)
    if (
        not stat.S_ISREG(before.st_mode)
        or stat.S_ISLNK(before.st_mode)
        or before.st_uid != os.geteuid()
        or before.st_nlink != 1
        or before.st_mode & 0o022
        or before.st_size <= 0
        or before.st_size > 512 * 1024
    ):
        raise ValueError
    descriptor = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise ValueError
        chunks: list[bytes] = []
        remaining = before.st_size
        while remaining:
            chunk = os.read(descriptor, min(remaining, 1024 * 1024))
            if not chunk:
                raise ValueError
            chunks.append(chunk)
            remaining -= len(chunk)
        if os.read(descriptor, 1):
            raise ValueError
        after = os.fstat(descriptor)
        fields = (
            "st_dev", "st_ino", "st_mode", "st_uid", "st_nlink", "st_size",
            "st_mtime_ns", "st_ctime_ns",
        )
        if any(getattr(opened, field) != getattr(after, field) for field in fields):
            raise ValueError
    finally:
        os.close(descriptor)
    payload = b"".join(chunks)
    value = json.loads(payload.decode("utf-8"), object_pairs_hook=unique_object)
    lock = json.loads(Path(lock_path).read_text(encoding="utf-8"), object_pairs_hook=unique_object)
    exact_object(
        value,
        {"schemaVersion", "evidenceType", "product", "source", "release", "toolchain", "packageResolution", "policies", "checks"},
    )
    if value["schemaVersion"] != 1 or type(value["schemaVersion"]) is not int or value["product"] != "UtterInk":
        raise ValueError
    expected_evidence_type = "release-candidate-test" if test_mode == "1" else "release-candidate"
    if value["evidenceType"] != expected_evidence_type:
        raise ValueError
    source_value = exact_object(value["source"], {"commit", "tree", "releaseTag", "clean"})
    if source_value != {"commit": commit, "tree": tree, "releaseTag": "v0.1.0", "clean": True}:
        raise ValueError
    release = exact_object(
        value["release"],
        {"configuration", "marketingVersion", "buildNumber", "bundleIdentifier", "deploymentTarget", "architecture", "dmgFilename"},
    )
    if release != {
        "configuration": "Release",
        "marketingVersion": "0.1.0",
        "buildNumber": "1",
        "bundleIdentifier": "dev.utterink.UtterInk",
        "deploymentTarget": "14.0",
        "architecture": "arm64",
        "dmgFilename": "UtterInk-0.1.0-arm64.dmg",
    }:
        raise ValueError
    xcode = exact_object(lock["xcode"], {"version", "build", "developerDir"})
    sdk = exact_object(lock["sdk"], {"version", "build"})
    swift = exact_object(lock["swift"], {"version"})
    xcodegen = exact_object(
        lock["xcodegen"],
        {
            "version", "sourceCommit", "archiveURL", "archiveSHA256",
            "binarySHA256", "settingPresetsSHA256",
        },
    )
    toolchain = exact_object(
        value["toolchain"],
        {"lockSHA256", "xcodeVersion", "xcodeBuild", "sdkVersion", "sdkBuild", "swiftVersion", "xcodegenVersion", "xcodegenBinarySHA256"},
    )
    if toolchain != {
        "lockSHA256": lock_hash,
        "xcodeVersion": xcode["version"],
        "xcodeBuild": xcode["build"],
        "sdkVersion": sdk["version"],
        "sdkBuild": sdk["build"],
        "swiftVersion": swift["version"],
        "xcodegenVersion": xcodegen["version"],
        "xcodegenBinarySHA256": xcodegen["binarySHA256"],
    }:
        raise ValueError
    if (
        re.fullmatch(r"[0-9a-f]{64}", str(toolchain["lockSHA256"])) is None
        or re.fullmatch(r"[0-9a-f]{64}", str(toolchain["xcodegenBinarySHA256"])) is None
    ):
        raise ValueError
    package = exact_object(value["packageResolution"], {"path", "sha256"})
    if package != {"path": "Packages/UtterInkKit/Package.resolved", "sha256": package_hash}:
        raise ValueError
    policies = exact_object(
        value["policies"],
        {"releaseMetadataSHA256", "releaseEntitlementsSHA256", "releaseInfoPolicySHA256", "ciToolchainSHA256"},
    )
    if policies != {
        "releaseMetadataSHA256": metadata_hash,
        "releaseEntitlementsSHA256": entitlements_hash,
        "releaseInfoPolicySHA256": info_hash,
        "ciToolchainSHA256": lock_hash,
    }:
        raise ValueError
    checks = exact_object(
        value["checks"],
        {"history", "metadata", "entitlements", "infoPolicy", "packageResolution", "generatedProjectClean"},
    )
    if checks != {
        "history": True,
        "metadata": True,
        "entitlements": True,
        "infoPolicy": True,
        "packageResolution": True,
        "generatedProjectClean": True,
    }:
        raise ValueError
    canonical = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    if canonical != payload:
        raise ValueError
    snapshot_fd = os.open(
        snapshot,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o400,
    )
    try:
        offset = 0
        while offset < len(payload):
            offset += os.write(snapshot_fd, payload[offset:])
        os.fsync(snapshot_fd)
        snapshot_metadata = os.fstat(snapshot_fd)
        if not stat.S_ISREG(snapshot_metadata.st_mode) or stat.S_IMODE(snapshot_metadata.st_mode) != 0o400:
            raise ValueError
    finally:
        os.close(snapshot_fd)
except (KeyError, OSError, UnicodeError, ValueError, json.JSONDecodeError):
    try:
        os.unlink(snapshot)
    except OSError:
        pass
    raise SystemExit(1)
PY
then
  fail candidate-evidence-invalid 28
fi
readonly VERIFIER_OUTPUT VERIFIED_CANDIDATE
CANDIDATE_SNAPSHOT_FINGERPRINT="$(file_fingerprint capture "$VERIFIED_CANDIDATE" -)" ||
  fail candidate-evidence-invalid 28
[[ -n "$CANDIDATE_SNAPSHOT_FINGERPRINT" ]] || fail candidate-evidence-invalid 28

EXACT_SOURCE="$TRANSIENT/exact-source"
if ! $GIT clone --quiet --no-hardlinks --no-tags --no-checkout -- "$ROOT" "$EXACT_SOURCE" \
  > "$TRANSIENT/git-clone-output" 2> "$TRANSIENT/git-clone-error"; then
  fail exact-source-unavailable 30
fi
if ! $GIT -C "$EXACT_SOURCE" checkout --quiet --detach --force "$COMMIT" \
  > "$TRANSIENT/git-checkout-output" 2> "$TRANSIENT/git-checkout-error"; then
  fail exact-source-unavailable 30
fi
EXACT_HEAD="$($GIT -C "$EXACT_SOURCE" rev-parse --verify HEAD 2>/dev/null)" || fail exact-source-unavailable 30
EXACT_STATUS="$($GIT -C "$EXACT_SOURCE" status --porcelain=v1 --untracked-files=all 2>/dev/null)" ||
  fail exact-source-unavailable 30
[[ "$EXACT_HEAD" == "$COMMIT" && -z "$EXACT_STATUS" ]] || fail exact-source-unavailable 30

EXACT_REQUIRED=(
  App/Supporting/UtterInk.entitlements
  Config/ci-toolchain.json
  Config/release-entitlements.json
  Config/release-info-policy.json
  Config/release-metadata.json
  Packages/UtterInkKit/Package.resolved
  Scripts/collect-third-party-notices.sh
  Scripts/release/read-metadata.py
  Scripts/release/verify-entitlements.py
  Scripts/release/verify-info-policy.py
  UtterInk.xcodeproj/project.pbxproj
  docs/release/evidence-schema.json
  project.yml
)
for relative in "${EXACT_REQUIRED[@]}"; do
  [[ -f "$EXACT_SOURCE/$relative" && ! -L "$EXACT_SOURCE/$relative" ]] || fail exact-source-unavailable 30
done
for relative in \
  Scripts/collect-third-party-notices.sh \
  Scripts/release/read-metadata.py \
  Scripts/release/verify-entitlements.py \
  Scripts/release/verify-info-policy.py; do
  [[ -x "$EXACT_SOURCE/$relative" ]] || fail exact-source-unavailable 30
done

LOCK="$EXACT_SOURCE/Config/ci-toolchain.json"
if ! $PYTHON -I - "$LOCK" "$TRANSIENT/lock-values" <<'PY' >/dev/null 2>&1
from __future__ import annotations

import json
from pathlib import Path
import re
import sys


def abort() -> None:
    raise SystemExit(1)


def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, item in pairs:
        if key in value:
            abort()
        value[key] = item
    return value


path, output = map(Path, sys.argv[1:3])
try:
    if path.stat().st_size > 128 * 1024:
        abort()
    lock = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
except (OSError, UnicodeError, json.JSONDecodeError):
    abort()
if type(lock) is not dict or set(lock) != {
    "schemaVersion", "runnerImage", "xcode", "sdk", "swift", "xcodegen", "sources"
}:
    abort()
if type(lock["schemaVersion"]) is not int or lock["schemaVersion"] != 1:
    abort()
xcode = lock["xcode"]
xcodegen = lock["xcodegen"]
if type(xcode) is not dict or set(xcode) != {"version", "build", "developerDir"}:
    abort()
if type(xcodegen) is not dict or set(xcodegen) != {
    "version", "sourceCommit", "archiveURL", "archiveSHA256", "binarySHA256",
    "settingPresetsSHA256",
}:
    abort()
developer_dir = xcode.get("developerDir")
version = xcodegen.get("version")
binary_digest = xcodegen.get("binarySHA256")
presets_digest = xcodegen.get("settingPresetsSHA256")
if (
    type(developer_dir) is not str
    or re.fullmatch(r"/Applications/Xcode_[A-Za-z0-9.]+[.]app/Contents/Developer", developer_dir) is None
    or type(version) is not str
    or re.fullmatch(r"[0-9]+(?:[.][0-9]+)+", version) is None
    or type(binary_digest) is not str
    or re.fullmatch(r"[0-9a-f]{64}", binary_digest) is None
    or type(presets_digest) is not str
    or re.fullmatch(r"[0-9a-f]{64}", presets_digest) is None
):
    abort()
output.write_text(
    "\n".join((developer_dir, version, binary_digest, presets_digest)) + "\n",
    encoding="utf-8",
)
PY
then
  fail toolchain-lock-invalid 24
fi
DEVELOPER_DIR_LOCKED="$(/usr/bin/sed -n '1p' "$TRANSIENT/lock-values")"
EXPECTED_XCODEGEN_VERSION="$(/usr/bin/sed -n '2p' "$TRANSIENT/lock-values")"
EXPECTED_XCODEGEN_SHA="$(/usr/bin/sed -n '3p' "$TRANSIENT/lock-values")"
EXPECTED_XCODEGEN_PRESETS_SHA="$(/usr/bin/sed -n '4p' "$TRANSIENT/lock-values")"
[[ -n "$DEVELOPER_DIR_LOCKED" && -n "$EXPECTED_XCODEGEN_VERSION" &&
  "$EXPECTED_XCODEGEN_SHA" =~ ^[0-9a-f]{64}$ && "$EXPECTED_XCODEGEN_PRESETS_SHA" =~ ^[0-9a-f]{64}$ ]] ||
  fail toolchain-lock-invalid 24

[[ ! -L "$ROOT/Tools" && ! -L "$ROOT/Tools/bin" && ! -L "$REPOSITORY_XCODEGEN" &&
  ! -L "$XCODEGEN_RESOURCE_BUNDLE" && ! -L "$XCODEGEN_SETTING_PRESETS" ]] ||
  fail repository-xcodegen-unusable 24
[[ -f "$REPOSITORY_XCODEGEN" && -x "$REPOSITORY_XCODEGEN" ]] || fail repository-xcodegen-missing 24

verify_xcodegen_setting_presets() {
  $PYTHON -I - "$1" "$2" <<'PY' >/dev/null 2>&1
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import re
import stat
import struct
import sys


root = Path(sys.argv[1])
expected = sys.argv[2]
if re.fullmatch(r"[0-9a-f]{64}", expected) is None:
    raise SystemExit(1)

flags = os.O_RDONLY | os.O_DIRECTORY
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
try:
    root_fd = os.open(root, flags)
except OSError:
    raise SystemExit(1)

files: list[tuple[bytes, bytes]] = []
directories: set[str] = {""}
total_size = 0


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


def walk(directory_fd: int, prefix: str, depth: int) -> None:
    global total_size
    if depth > 8:
        raise ValueError
    with os.scandir(directory_fd) as iterator:
        entries = list(iterator)
    if len(entries) > 256:
        raise ValueError
    for entry in entries:
        name = entry.name
        try:
            name_bytes = name.encode("utf-8", errors="strict")
        except UnicodeError:
            raise ValueError
        if not name or name in (".", "..") or b"\x00" in name_bytes or b"/" in name_bytes:
            raise ValueError
        relative = f"{prefix}/{name}" if prefix else name
        relative_bytes = relative.encode("utf-8", errors="strict")
        if len(relative_bytes) > 512:
            raise ValueError
        before = entry.stat(follow_symlinks=False)
        if stat.S_ISLNK(before.st_mode):
            raise ValueError
        if stat.S_ISDIR(before.st_mode):
            if before.st_mode & 0o022:
                raise ValueError
            child_flags = os.O_RDONLY | os.O_DIRECTORY
            if hasattr(os, "O_NOFOLLOW"):
                child_flags |= os.O_NOFOLLOW
            child_fd = os.open(name, child_flags, dir_fd=directory_fd)
            try:
                if identity(os.fstat(child_fd)) != identity(before):
                    raise ValueError
                directories.add(relative)
                walk(child_fd, relative, depth + 1)
                if identity(os.fstat(child_fd)) != identity(before):
                    raise ValueError
            finally:
                os.close(child_fd)
            continue
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_mode & 0o133:
            raise ValueError
        if before.st_size < 0 or before.st_size > 1024 * 1024:
            raise ValueError
        file_flags = os.O_RDONLY
        if hasattr(os, "O_NOFOLLOW"):
            file_flags |= os.O_NOFOLLOW
        file_fd = os.open(name, file_flags, dir_fd=directory_fd)
        try:
            current = os.fstat(file_fd)
            if identity(current) != identity(before):
                raise ValueError
            content = bytearray()
            offset = 0
            while offset < current.st_size:
                chunk = os.pread(file_fd, min(1024 * 1024, current.st_size - offset), offset)
                if not chunk:
                    raise ValueError
                content.extend(chunk)
                offset += len(chunk)
            if identity(os.fstat(file_fd)) != identity(before):
                raise ValueError
        finally:
            os.close(file_fd)
        total_size += len(content)
        if total_size > 8 * 1024 * 1024 or len(files) >= 256:
            raise ValueError
        files.append((relative_bytes, bytes(content)))


try:
    root_metadata = os.fstat(root_fd)
    if not stat.S_ISDIR(root_metadata.st_mode) or root_metadata.st_mode & 0o022:
        raise ValueError
    walk(root_fd, "", 0)
finally:
    os.close(root_fd)

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

verify_xcodegen_resource_bundle() {
  local bundle="$1"
  local expected="$2"
  if ! $PYTHON -I - "$bundle" <<'PY' >/dev/null 2>&1
from __future__ import annotations

import os
from pathlib import Path
import stat
import sys


bundle = Path(sys.argv[1])
flags = os.O_RDONLY | os.O_DIRECTORY
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW


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


bundle_fd = -1
presets_fd = -1
try:
    before = os.lstat(bundle)
    if (
        not stat.S_ISDIR(before.st_mode)
        or stat.S_ISLNK(before.st_mode)
        or before.st_uid != os.geteuid()
        or before.st_mode & 0o022
    ):
        raise ValueError
    bundle_fd = os.open(bundle, flags)
    opened = os.fstat(bundle_fd)
    if identity(opened) != identity(before):
        raise ValueError
    with os.scandir(bundle_fd) as iterator:
        entries = list(iterator)
    if len(entries) != 1 or entries[0].name != "SettingPresets":
        raise ValueError
    presets = entries[0].stat(follow_symlinks=False)
    if (
        not stat.S_ISDIR(presets.st_mode)
        or stat.S_ISLNK(presets.st_mode)
        or presets.st_uid != os.geteuid()
        or presets.st_dev != opened.st_dev
        or presets.st_mode & 0o022
    ):
        raise ValueError
    presets_fd = os.open("SettingPresets", flags, dir_fd=bundle_fd)
    if identity(os.fstat(presets_fd)) != identity(presets):
        raise ValueError
    if identity(os.fstat(bundle_fd)) != identity(opened):
        raise ValueError
except (OSError, ValueError):
    raise SystemExit(1)
finally:
    if presets_fd >= 0:
        os.close(presets_fd)
    if bundle_fd >= 0:
        os.close(bundle_fd)
PY
  then
    return 1
  fi
  if ! verify_xcodegen_setting_presets "$bundle/SettingPresets" "$expected"; then
    return 1
  fi
  return 0
}

if ! verify_xcodegen_resource_bundle "$XCODEGEN_RESOURCE_BUNDLE" "$EXPECTED_XCODEGEN_PRESETS_SHA"; then
  fail repository-xcodegen-mismatch 24
fi
VERIFIED_XCODEGEN_RESOURCE_BUNDLE="$TRANSIENT/XcodeGen_XcodeGenKit.bundle"
/usr/bin/env COPYFILE_DISABLE=1 /bin/cp -R "$XCODEGEN_RESOURCE_BUNDLE" "$VERIFIED_XCODEGEN_RESOURCE_BUNDLE" ||
  fail repository-xcodegen-unusable 24
if ! verify_xcodegen_resource_bundle "$VERIFIED_XCODEGEN_RESOURCE_BUNDLE" "$EXPECTED_XCODEGEN_PRESETS_SHA"; then
  fail repository-xcodegen-mismatch 24
fi
VERIFIED_XCODEGEN="$TRANSIENT/xcodegen"
/bin/cp "$REPOSITORY_XCODEGEN" "$VERIFIED_XCODEGEN" || fail repository-xcodegen-unusable 24
/bin/chmod 0700 "$VERIFIED_XCODEGEN" || fail repository-xcodegen-unusable 24
ACTUAL_XCODEGEN_SHA="$($SHASUM -a 256 "$VERIFIED_XCODEGEN" | /usr/bin/awk 'NR == 1 { print $1}')" ||
  fail repository-xcodegen-unusable 24
[[ "$ACTUAL_XCODEGEN_SHA" == "$EXPECTED_XCODEGEN_SHA" ]] || fail repository-xcodegen-mismatch 24
if [[ "$TEST_MODE" -eq 1 ]]; then
  ACTUAL_XCODEGEN_VERSION="$(/usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C HOME="$TRANSIENT" \
    UTTERINK_FIXTURE_LOG="$UTTERINK_FIXTURE_LOG" \
    "$VERIFIED_XCODEGEN" --version 2>/dev/null)" || fail repository-xcodegen-unusable 24
else
  ACTUAL_XCODEGEN_VERSION="$(/usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C HOME="$TRANSIENT" \
    "$VERIFIED_XCODEGEN" --version 2>/dev/null)" || fail repository-xcodegen-unusable 24
fi
[[ "$ACTUAL_XCODEGEN_VERSION" == "Version: $EXPECTED_XCODEGEN_VERSION" ]] ||
  fail repository-xcodegen-mismatch 24

if [[ "$TEST_MODE" -eq 1 ]]; then
  EXACT_TOOL_ROOT="$EXACT_SOURCE/FixtureTools"
  EXACT_TEST_MARKER="$EXACT_TOOL_ROOT/.utterink-build-candidate-test-fixture"
  [[ -d "$EXACT_TOOL_ROOT" && ! -L "$EXACT_TOOL_ROOT" && -f "$EXACT_TEST_MARKER" && ! -L "$EXACT_TEST_MARKER" ]] ||
    fail invalid-test-tool-root 24
  [[ "$(/bin/cat "$EXACT_TEST_MARKER")" == utterink-offline-build-candidate-fixture-v1 ]] ||
    fail invalid-test-tool-root 24
  XCODEBUILD="$EXACT_TOOL_ROOT/xcodebuild"
  FILE_TOOL="$EXACT_TOOL_ROOT/file"
  LIPO="$EXACT_TOOL_ROOT/lipo"
  OTOOL="$EXACT_TOOL_ROOT/otool"
  DITTO="$EXACT_TOOL_ROOT/ditto"
  MUTATION_HOOK="$EXACT_TOOL_ROOT/build-candidate-hook"
else
  XCODEBUILD=/usr/bin/xcodebuild
  FILE_TOOL=/usr/bin/file
  LIPO=/usr/bin/lipo
  OTOOL=/usr/bin/otool
  DITTO=/usr/bin/ditto
  MUTATION_HOOK=''
fi
for tool in "$XCODEBUILD" "$FILE_TOOL" "$LIPO" "$OTOOL" "$DITTO"; do
  [[ -f "$tool" && -x "$tool" && ! -L "$tool" ]] || fail toolchain-unavailable 24
done
if [[ "$TEST_MODE" -eq 1 ]]; then
  [[ -f "$MUTATION_HOOK" && -x "$MUTATION_HOOK" && ! -L "$MUTATION_HOOK" ]] ||
    fail invalid-test-tool-root 24
fi

run_test_hook() {
  if [[ "$TEST_MODE" -eq 1 ]]; then
    "$MUTATION_HOOK" "$@" || fail test-hook-failed 39
  fi
}

run_late_test_hook() {
  local descriptor="$1"
  shift
  if [[ "$TEST_MODE" -eq 1 ]]; then
    /bin/bash -p "/dev/fd/$descriptor" "$@" || fail test-hook-failed 39
  fi
}

# Xcode 26.4 creates these ignored workspace-state directories beside a local
# Swift package even when package checkouts, caches, HOME, and DerivedData are
# redirected outside the source tree.  Create the exact empty layout before
# the first source inventory so the expected tool behavior is frozen instead
# of being reported as a source mutation.  Any later entry or metadata change
# remains covered by the source inventories and the dedicated state token.
SWIFTPM_STATE_PARENT="$EXACT_SOURCE/Packages/UtterInkKit"
readonly SWIFTPM_STATE_PARENT

swiftpm_state_token() {
  local mode="$1"
  $PYTHON -I - "$mode" "$SWIFTPM_STATE_PARENT" <<'PY'
from __future__ import annotations

import hashlib
import json
import os
import stat
import sys


mode, parent_path = sys.argv[1:3]
directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
descriptors: list[int] = []


def record(
    name: str,
    descriptor: int,
    device: int,
    required_mode: int | None,
) -> list[object]:
    metadata = os.fstat(descriptor)
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_dev != device
        or metadata.st_uid != os.geteuid()
        or (
            stat.S_IMODE(metadata.st_mode) != required_mode
            if required_mode is not None
            else stat.S_IMODE(metadata.st_mode) & 0o022
        )
    ):
        raise ValueError
    return [
        name,
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_uid,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    ]


try:
    if mode not in {"create", "verify"}:
        raise ValueError
    parent = os.open(parent_path, directory_flags)
    descriptors.append(parent)
    parent_metadata = os.fstat(parent)
    if (
        not stat.S_ISDIR(parent_metadata.st_mode)
        or stat.S_ISLNK(parent_metadata.st_mode)
        or parent_metadata.st_uid != os.geteuid()
        or stat.S_IMODE(parent_metadata.st_mode) & 0o022
    ):
        raise ValueError
    if mode == "create":
        os.mkdir(".swiftpm", 0o700, dir_fd=parent)
    state = os.open(".swiftpm", directory_flags, dir_fd=parent)
    descriptors.append(state)
    records = [
        record("..", parent, parent_metadata.st_dev, None),
        record(".", state, parent_metadata.st_dev, 0o700),
    ]
    if mode == "create":
        for name in ("configuration", "xcode"):
            os.mkdir(name, 0o700, dir_fd=state)
    if sorted(os.listdir(state)) != ["configuration", "xcode"]:
        raise ValueError
    for name in ("configuration", "xcode"):
        child = os.open(name, directory_flags, dir_fd=state)
        descriptors.append(child)
        records.append(record(name, child, parent_metadata.st_dev, 0o700))
        if os.listdir(child):
            raise ValueError
    payload = json.dumps(records, separators=(",", ":")).encode("utf-8")
    print(hashlib.sha256(payload).hexdigest())
except (OSError, UnicodeError, ValueError):
    raise SystemExit(1)
finally:
    for descriptor in reversed(descriptors):
        os.close(descriptor)
PY
}

CREATED_SWIFTPM_STATE_TOKEN="$(swiftpm_state_token create)" || fail exact-source-mutated 31
[[ "$CREATED_SWIFTPM_STATE_TOKEN" =~ ^[0-9a-f]{64}$ ]] || fail exact-source-mutated 31
unset CREATED_SWIFTPM_STATE_TOKEN

EXACT_RELEASE_WORK="$EXACT_SOURCE/.release-work/build"
/bin/mkdir -p "$EXACT_SOURCE/.release-work"
/bin/chmod 0700 "$EXACT_SOURCE/.release-work"
/bin/mkdir -m 0700 "$EXACT_RELEASE_WORK"
for directory in home tmp xdg-config xdg-cache swift-module-cache clang-module-cache SourcePackages DerivedData; do
  /bin/mkdir -m 0700 "$EXACT_RELEASE_WORK/$directory"
done
export HOME="$EXACT_RELEASE_WORK/home"
export CFFIXED_USER_HOME="$EXACT_RELEASE_WORK/home"
export TMPDIR="$EXACT_RELEASE_WORK/tmp"
export XDG_CONFIG_HOME="$EXACT_RELEASE_WORK/xdg-config"
export XDG_CACHE_HOME="$EXACT_RELEASE_WORK/xdg-cache"
export SWIFT_MODULECACHE_PATH="$EXACT_RELEASE_WORK/swift-module-cache"
export CLANG_MODULE_CACHE_PATH="$EXACT_RELEASE_WORK/clang-module-cache"

exact_source_inventory() {
  local mode="$1"
  local snapshot="$2"
  local expected_token="${3:--}"
  $PYTHON -I - "$mode" "$EXACT_SOURCE" "$snapshot" "$expected_token" <<'PY'
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import stat
import sys


mode, raw_root, raw_snapshot, expected_token = sys.argv[1:5]
root = Path(raw_root)
snapshot = Path(raw_snapshot)
stat_fields = (
    "st_dev", "st_ino", "st_mode", "st_uid", "st_nlink", "st_size",
    "st_mtime_ns", "st_ctime_ns",
)


def same(left: os.stat_result, right: os.stat_result) -> bool:
    return all(getattr(left, field) == getattr(right, field) for field in stat_fields)


def metadata_record(relative: str, metadata: os.stat_result, kind: str) -> dict[str, object]:
    return {
        "path": relative,
        "kind": kind,
        "device": metadata.st_dev,
        "inode": metadata.st_ino,
        "mode": metadata.st_mode,
        "uid": metadata.st_uid,
        "links": metadata.st_nlink,
        "size": metadata.st_size,
        "mtimeNS": metadata.st_mtime_ns,
        "ctimeNS": metadata.st_ctime_ns,
    }


def collect_directory(path: Path, relative: str, device: int, records: list[dict[str, object]]) -> None:
    before = os.lstat(path)
    if (
        not stat.S_ISDIR(before.st_mode)
        or stat.S_ISLNK(before.st_mode)
        or before.st_dev != device
        or before.st_uid != os.geteuid()
    ):
        raise ValueError
    names = sorted(os.listdir(path), key=lambda value: value.encode("utf-8", errors="strict"))
    for name in names:
        if not name or name in {".", ".."} or "/" in name:
            raise ValueError
        if relative == "." and name == ".release-work":
            continue
        child = path / name
        child_relative = name if relative == "." else f"{relative}/{name}"
        child_before = os.lstat(child)
        if child_before.st_dev != device or child_before.st_uid != os.geteuid():
            raise ValueError
        if stat.S_ISDIR(child_before.st_mode) and not stat.S_ISLNK(child_before.st_mode):
            collect_directory(child, child_relative, device, records)
        elif stat.S_ISREG(child_before.st_mode):
            descriptor = os.open(child, os.O_RDONLY | os.O_NOFOLLOW)
            try:
                opened = os.fstat(descriptor)
                if not same(child_before, opened):
                    raise ValueError
                digest = hashlib.sha256()
                while True:
                    chunk = os.read(descriptor, 1024 * 1024)
                    if not chunk:
                        break
                    digest.update(chunk)
                after = os.fstat(descriptor)
                if not same(opened, after):
                    raise ValueError
            finally:
                os.close(descriptor)
            record = metadata_record(child_relative, after, "file")
            record["sha256"] = digest.hexdigest()
            records.append(record)
        elif stat.S_ISLNK(child_before.st_mode):
            target = os.readlink(child)
            child_after = os.lstat(child)
            if not same(child_before, child_after):
                raise ValueError
            record = metadata_record(child_relative, child_after, "link")
            record["target"] = target
            records.append(record)
        else:
            raise ValueError
    after = os.lstat(path)
    if not same(before, after):
        raise ValueError
    records.append(metadata_record(relative, after, "directory"))


def collect() -> bytes:
    root_metadata = os.lstat(root)
    if (
        not stat.S_ISDIR(root_metadata.st_mode)
        or stat.S_ISLNK(root_metadata.st_mode)
        or root_metadata.st_uid != os.geteuid()
    ):
        raise ValueError
    records: list[dict[str, object]] = []
    collect_directory(root, ".", root_metadata.st_dev, records)
    records.sort(key=lambda value: str(value["path"]).encode("utf-8", errors="strict"))
    return (json.dumps(records, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def snapshot_token(descriptor: int, payload: bytes) -> str:
    metadata = os.fstat(descriptor)
    values = (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_uid,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
        hashlib.sha256(payload).hexdigest(),
    )
    return ":".join(str(value) for value in values)


try:
    payload = collect()
    if mode == "capture":
        descriptor = os.open(
            snapshot,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o400,
        )
        try:
            offset = 0
            while offset < len(payload):
                offset += os.write(descriptor, payload[offset:])
            os.fsync(descriptor)
            token = snapshot_token(descriptor, payload)
        finally:
            os.close(descriptor)
        print(token)
    elif mode == "verify":
        descriptor = os.open(snapshot, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            chunks: list[bytes] = []
            while True:
                chunk = os.read(descriptor, 1024 * 1024)
                if not chunk:
                    break
                chunks.append(chunk)
            expected_payload = b"".join(chunks)
            if snapshot_token(descriptor, expected_payload) != expected_token:
                raise ValueError
        finally:
            os.close(descriptor)
        if expected_payload != payload:
            raise ValueError
    else:
        raise ValueError
except (OSError, UnicodeError, ValueError):
    raise SystemExit(1)
PY
}

INITIAL_SOURCE_INVENTORY="$TRANSIENT/exact-source-inventory-initial.json"
INITIAL_SOURCE_TOKEN="$(exact_source_inventory capture "$INITIAL_SOURCE_INVENTORY")" ||
  fail exact-source-mutated 31
[[ "$INITIAL_SOURCE_TOKEN" =~ ^[0-9:]+:[0-9a-f]{64}$ ]] || fail exact-source-mutated 31

PACKAGE_RESOLUTION="$EXACT_SOURCE/Packages/UtterInkKit/Package.resolved"
PACKAGE_HASH_BEFORE="$($SHASUM -a 256 "$PACKAGE_RESOLUTION" | /usr/bin/awk 'NR == 1 { print $1}')" ||
  fail package-resolution-mismatch 31

/bin/mkdir -m 0700 "$TRANSIENT/notice-scratch"
if [[ "$TEST_MODE" -eq 1 ]]; then
  (
    cd "$EXACT_SOURCE"
    UTTERINK_FIXTURE_LOG="$UTTERINK_FIXTURE_LOG" \
      UTTERINK_NOTICE_SCRATCH_PATH="$TRANSIENT/notice-scratch" \
      "$EXACT_SOURCE/Scripts/collect-third-party-notices.sh" --check
  ) > "$TRANSIENT/notices-output" 2> "$TRANSIENT/notices-error" || fail third-party-notice-mismatch 31
else
  (
    cd "$EXACT_SOURCE"
    PATH="$DEVELOPER_DIR_LOCKED/Toolchains/XcodeDefault.xctoolchain/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
      DEVELOPER_DIR="$DEVELOPER_DIR_LOCKED" \
      UTTERINK_NOTICE_SCRATCH_PATH="$TRANSIENT/notice-scratch" \
      "$EXACT_SOURCE/Scripts/collect-third-party-notices.sh" --check
  ) > "$TRANSIENT/notices-output" 2> "$TRANSIENT/notices-error" || fail third-party-notice-mismatch 31
fi

exact_source_inventory verify "$INITIAL_SOURCE_INVENTORY" "$INITIAL_SOURCE_TOKEN" ||
  fail exact-source-mutated 31
if ! (
  cd "$EXACT_SOURCE"
  DEVELOPER_DIR="$DEVELOPER_DIR_LOCKED" "$XCODEBUILD" \
    -resolvePackageDependencies \
    -project UtterInk.xcodeproj \
    -scheme UtterInk \
    -clonedSourcePackagesDirPath "$EXACT_RELEASE_WORK/SourcePackages" \
    -disableAutomaticPackageResolution \
    -onlyUsePackageVersionsFromResolvedFile
) > "$TRANSIENT/xcode-resolve-output" 2> "$TRANSIENT/xcode-resolve-error"; then
  fail package-resolution-mismatch 31
fi
exact_source_inventory verify "$INITIAL_SOURCE_INVENTORY" "$INITIAL_SOURCE_TOKEN" ||
  fail exact-source-mutated 31
PACKAGE_HASH_AFTER="$($SHASUM -a 256 "$PACKAGE_RESOLUTION" | /usr/bin/awk 'NR == 1 { print $1}')" ||
  fail package-resolution-mismatch 31
[[ "$PACKAGE_HASH_AFTER" == "$PACKAGE_HASH_BEFORE" ]] || fail package-resolution-mismatch 31
SWIFTPM_STATE_TOKEN="$(swiftpm_state_token verify)" || fail exact-source-mutated 31
[[ "$SWIFTPM_STATE_TOKEN" =~ ^[0-9a-f]{64}$ ]] || fail exact-source-mutated 31
readonly SWIFTPM_STATE_TOKEN

BUILD_USER="$(/usr/bin/id -un 2>/dev/null)" || fail generated-project-mismatch 32
[[ "$BUILD_USER" =~ ^[A-Za-z0-9._-]+$ ]] || fail generated-project-mismatch 32
readonly BUILD_USER
if [[ "$TEST_MODE" -eq 1 ]]; then
  (
    cd "$EXACT_SOURCE"
    /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
      HOME="$EXACT_RELEASE_WORK/home" TMPDIR="$EXACT_RELEASE_WORK/tmp" \
      USER="$BUILD_USER" LOGNAME="$BUILD_USER" \
      UTTERINK_FIXTURE_LOG="$UTTERINK_FIXTURE_LOG" \
      "$VERIFIED_XCODEGEN" generate
  ) > "$TRANSIENT/xcodegen-output" 2> "$TRANSIENT/xcodegen-error" || fail generated-project-mismatch 32
else
  (
    cd "$EXACT_SOURCE"
    /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
      HOME="$EXACT_RELEASE_WORK/home" TMPDIR="$EXACT_RELEASE_WORK/tmp" \
      USER="$BUILD_USER" LOGNAME="$BUILD_USER" \
      "$VERIFIED_XCODEGEN" generate
  ) > "$TRANSIENT/xcodegen-output" 2> "$TRANSIENT/xcodegen-error" || fail generated-project-mismatch 32
fi
[[ "$($SHASUM -a 256 "$VERIFIED_XCODEGEN" | /usr/bin/awk 'NR == 1 { print $1}')" == "$EXPECTED_XCODEGEN_SHA" ]] ||
  fail repository-xcodegen-mismatch 24
EXACT_STATUS="$($GIT -C "$EXACT_SOURCE" status --porcelain=v1 --untracked-files=all 2>/dev/null)" ||
  fail generated-project-mismatch 32
[[ -z "$EXACT_STATUS" ]] || fail generated-project-mismatch 32
CURRENT_SWIFTPM_STATE_TOKEN="$(swiftpm_state_token verify)" || fail exact-source-mutated 32
[[ "$CURRENT_SWIFTPM_STATE_TOKEN" == "$SWIFTPM_STATE_TOKEN" ]] || fail exact-source-mutated 32
FINAL_SOURCE_INVENTORY="$TRANSIENT/exact-source-inventory-final.json"
FINAL_SOURCE_TOKEN="$(exact_source_inventory capture "$FINAL_SOURCE_INVENTORY")" ||
  fail exact-source-mutated 32
[[ "$FINAL_SOURCE_TOKEN" =~ ^[0-9:]+:[0-9a-f]{64}$ ]] || fail exact-source-mutated 32

METADATA_JSON="$TRANSIENT/metadata.json"
if [[ "$TEST_MODE" -eq 1 ]]; then
  UTTERINK_FIXTURE_LOG="$UTTERINK_FIXTURE_LOG" \
    $PYTHON -I "$EXACT_SOURCE/Scripts/release/read-metadata.py" --json \
      > "$METADATA_JSON" 2> "$TRANSIENT/metadata-error" || fail metadata-mismatch 33
  UTTERINK_FIXTURE_LOG="$UTTERINK_FIXTURE_LOG" \
    $PYTHON -I "$EXACT_SOURCE/Scripts/release/verify-entitlements.py" \
      > "$TRANSIENT/entitlements-output" 2> "$TRANSIENT/entitlements-error" || fail entitlement-policy-failed 33
else
  $PYTHON -I "$EXACT_SOURCE/Scripts/release/read-metadata.py" --json \
    > "$METADATA_JSON" 2> "$TRANSIENT/metadata-error" || fail metadata-mismatch 33
  $PYTHON -I "$EXACT_SOURCE/Scripts/release/verify-entitlements.py" \
    > "$TRANSIENT/entitlements-output" 2> "$TRANSIENT/entitlements-error" || fail entitlement-policy-failed 33
fi

exact_source_inventory verify "$FINAL_SOURCE_INVENTORY" "$FINAL_SOURCE_TOKEN" ||
  fail exact-source-mutated 33
if ! (
  cd "$EXACT_SOURCE"
  DEVELOPER_DIR="$DEVELOPER_DIR_LOCKED" "$XCODEBUILD" \
    -project UtterInk.xcodeproj \
    -scheme UtterInk \
    -configuration Release \
    -showBuildSettings \
    -derivedDataPath "$EXACT_RELEASE_WORK/DerivedData" \
    -clonedSourcePackagesDirPath "$EXACT_RELEASE_WORK/SourcePackages" \
    -disableAutomaticPackageResolution \
    -onlyUsePackageVersionsFromResolvedFile
) > "$TRANSIENT/build-settings" 2> "$TRANSIENT/build-settings-error"; then
  fail metadata-mismatch 33
fi
exact_source_inventory verify "$FINAL_SOURCE_INVENTORY" "$FINAL_SOURCE_TOKEN" ||
  fail exact-source-mutated 33

if ! $PYTHON -I - "$METADATA_JSON" "$TRANSIENT/build-settings" <<'PY' >/dev/null 2>&1
from __future__ import annotations

import json
from pathlib import Path
import re
import sys

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
    metadata = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    lines = Path(sys.argv[2]).read_text(encoding="utf-8", errors="strict").splitlines()
except (OSError, UnicodeError, json.JSONDecodeError):
    raise SystemExit(1)
if metadata != expected_metadata:
    raise SystemExit(1)
keys = {
    "ARCHS",
    "CODE_SIGN_ENTITLEMENTS",
    "CURRENT_PROJECT_VERSION",
    "ENABLE_HARDENED_RUNTIME",
    "MACOSX_DEPLOYMENT_TARGET",
    "MARKETING_VERSION",
    "ONLY_ACTIVE_ARCH",
    "PRODUCT_BUNDLE_IDENTIFIER",
    "SWIFT_VERSION",
}
values: dict[str, list[str]] = {key: [] for key in keys}
active = False
blocks = 0
for line in lines:
    header = re.fullmatch(r"Build settings for action .+ and target (.+):", line)
    if header is not None:
        active = header.group(1) == "UtterInk"
        if active:
            blocks += 1
        continue
    match = re.fullmatch(r"\s+([A-Z][A-Z0-9_]*) = (.*)", line)
    if active and match is not None and match.group(1) in values:
        values[match.group(1)].append(match.group(2))
if blocks != 1 or any(len(items) != 1 for items in values.values()):
    raise SystemExit(1)
actual = {key: items[0] for key, items in values.items()}
expected = {
    "ARCHS": "arm64",
    "CODE_SIGN_ENTITLEMENTS": "App/Supporting/UtterInk.entitlements",
    "CURRENT_PROJECT_VERSION": "1",
    "ENABLE_HARDENED_RUNTIME": "YES",
    "MACOSX_DEPLOYMENT_TARGET": "14.0",
    "MARKETING_VERSION": "0.1.0",
    "ONLY_ACTIVE_ARCH": "NO",
    "PRODUCT_BUNDLE_IDENTIFIER": "dev.utterink.UtterInk",
    "SWIFT_VERSION": "5.0",
}
if actual != expected:
    raise SystemExit(1)
PY
then
  fail metadata-mismatch 33
fi

ARCHIVE_PATH="$EXACT_RELEASE_WORK/UtterInk.xcarchive"
exact_source_inventory verify "$FINAL_SOURCE_INVENTORY" "$FINAL_SOURCE_TOKEN" ||
  fail exact-source-mutated 34
if ! (
  cd "$EXACT_SOURCE"
  DEVELOPER_DIR="$DEVELOPER_DIR_LOCKED" "$XCODEBUILD" archive \
    -project UtterInk.xcodeproj \
    -scheme UtterInk \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    -derivedDataPath "$EXACT_RELEASE_WORK/DerivedData" \
    -clonedSourcePackagesDirPath "$EXACT_RELEASE_WORK/SourcePackages" \
    -disableAutomaticPackageResolution \
    -onlyUsePackageVersionsFromResolvedFile \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    OTHER_LDFLAGS=-Wl,-no_adhoc_codesign \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY= \
    DEVELOPMENT_TEAM= \
    PROVISIONING_PROFILE_SPECIFIER=
) > "$TRANSIENT/archive-output" 2> "$TRANSIENT/archive-error"; then
  fail archive-failed 34
fi
exact_source_inventory verify "$FINAL_SOURCE_INVENTORY" "$FINAL_SOURCE_TOKEN" ||
  fail exact-source-mutated 34

PACKAGE_HASH_FINAL="$($SHASUM -a 256 "$PACKAGE_RESOLUTION" | /usr/bin/awk 'NR == 1 { print $1}')" ||
  fail package-resolution-mismatch 31
[[ "$PACKAGE_HASH_FINAL" == "$PACKAGE_HASH_BEFORE" ]] || fail package-resolution-mismatch 31
EXACT_STATUS="$($GIT -C "$EXACT_SOURCE" status --porcelain=v1 --untracked-files=all 2>/dev/null)" ||
  fail generated-project-mismatch 32
[[ -z "$EXACT_STATUS" ]] || fail generated-project-mismatch 32

APP="$ARCHIVE_PATH/Products/Applications/UtterInk.app"
INFO_PLIST="$APP/Contents/Info.plist"
MAIN_EXECUTABLE="$APP/Contents/MacOS/UtterInk"
[[ -d "$ARCHIVE_PATH" && ! -L "$ARCHIVE_PATH" && -d "$APP" && ! -L "$APP" ]] || fail archive-layout-invalid 35
[[ -f "$INFO_PLIST" && ! -L "$INFO_PLIST" && -f "$MAIN_EXECUTABLE" && -x "$MAIN_EXECUTABLE" && ! -L "$MAIN_EXECUTABLE" ]] ||
  fail archive-layout-invalid 35

if [[ "$TEST_MODE" -eq 1 ]]; then
  UTTERINK_FIXTURE_LOG="$UTTERINK_FIXTURE_LOG" \
    $PYTHON -I "$EXACT_SOURCE/Scripts/release/verify-info-policy.py" --archived "$INFO_PLIST" \
      > "$TRANSIENT/info-policy-output" 2> "$TRANSIENT/info-policy-error" || fail info-policy-mismatch 35
else
  $PYTHON -I "$EXACT_SOURCE/Scripts/release/verify-info-policy.py" --archived "$INFO_PLIST" \
    > "$TRANSIENT/info-policy-output" 2> "$TRANSIENT/info-policy-error" || fail info-policy-mismatch 35
fi
exact_source_inventory verify "$FINAL_SOURCE_INVENTORY" "$FINAL_SOURCE_TOKEN" ||
  fail exact-source-mutated 35

file_fingerprint verify "$VERIFIED_CANDIDATE" "$CANDIDATE_SNAPSHOT_FINGERPRINT" ||
  fail candidate-evidence-invalid 35
if ! $PYTHON -I - "$VERIFIED_CANDIDATE" "$METADATA_JSON" "$INFO_PLIST" "$COMMIT" <<'PY' >/dev/null 2>&1
from __future__ import annotations

import json
from pathlib import Path
import plistlib
import sys


def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError
        value[key] = item
    return value


try:
    candidate = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"), object_pairs_hook=unique_object)
    metadata = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"), object_pairs_hook=unique_object)
    with Path(sys.argv[3]).open("rb") as handle:
        info = plistlib.load(handle)
except (OSError, UnicodeError, ValueError, json.JSONDecodeError, plistlib.InvalidFileException):
    raise SystemExit(1)
release = candidate.get("release")
source = candidate.get("source")
if type(release) is not dict or type(source) is not dict or source.get("commit") != sys.argv[4]:
    raise SystemExit(1)
expected_release = {
    "architecture": metadata["architecture"],
    "buildNumber": metadata["buildNumber"],
    "bundleIdentifier": metadata["bundleIdentifier"],
    "configuration": metadata["configuration"],
    "deploymentTarget": metadata["deploymentTarget"],
    "dmgFilename": metadata["dmgFilename"],
    "marketingVersion": metadata["marketingVersion"],
}
if release != expected_release:
    raise SystemExit(1)
expected_info = {
    "CFBundleDisplayName": metadata["product"],
    "CFBundleExecutable": metadata["product"],
    "CFBundleIdentifier": metadata["bundleIdentifier"],
    "CFBundleName": metadata["product"],
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": metadata["marketingVersion"],
    "CFBundleVersion": metadata["buildNumber"],
    "LSMinimumSystemVersion": metadata["deploymentTarget"],
}
if type(info) is not dict or any(info.get(key) != value for key, value in expected_info.items()):
    raise SystemExit(1)
PY
then
  fail candidate-evidence-invalid 35
fi

normalize_archive_build_marker() {
  local archive="$1"
  $PYTHON -I - "$archive" <<'PY' >/dev/null 2>&1
from __future__ import annotations

import ctypes
import os
from pathlib import Path
import stat
import sys


archive = Path(sys.argv[1])
flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
marker = b"com.apple.xcode.CreatedByBuildSystem"
provenance = b"com.apple.provenance"
stable_fields = (
    "st_dev", "st_ino", "st_mode", "st_uid", "st_nlink", "st_size", "st_mtime_ns",
)
libc = ctypes.CDLL(None, use_errno=True)
flistxattr = libc.flistxattr
flistxattr.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
flistxattr.restype = ctypes.c_ssize_t
fgetxattr = libc.fgetxattr
fgetxattr.argtypes = [
    ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int,
]
fgetxattr.restype = ctypes.c_ssize_t
fremovexattr = libc.fremovexattr
fremovexattr.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
fremovexattr.restype = ctypes.c_int


def same(left: os.stat_result, right: os.stat_result) -> bool:
    return all(getattr(left, field) == getattr(right, field) for field in stable_fields)


def xattr_names(descriptor: int) -> set[bytes]:
    ctypes.set_errno(0)
    size = flistxattr(descriptor, None, 0, 0)
    if size < 0 or size > 64 * 1024:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    if size == 0:
        return set()
    buffer = ctypes.create_string_buffer(size)
    ctypes.set_errno(0)
    actual = flistxattr(descriptor, buffer, size, 0)
    if actual < 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    if actual != size:
        raise ValueError
    return {name for name in buffer.raw[:actual].split(b"\0") if name}


def xattr_value(descriptor: int, name: bytes) -> bytes:
    ctypes.set_errno(0)
    size = fgetxattr(descriptor, name, None, 0, 0, 0)
    if size < 0 or size > 64 * 1024:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    buffer = ctypes.create_string_buffer(size)
    ctypes.set_errno(0)
    actual = fgetxattr(descriptor, name, buffer, size, 0, 0)
    if actual < 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    if actual != size:
        raise ValueError
    return buffer.raw[:actual]


def canonical_provenance(descriptor: int, names: set[bytes]) -> bool:
    if provenance not in names:
        return True
    value = xattr_value(descriptor, provenance)
    return len(value) == 11 and value[:3] == b"\x01\x02\x00"


root_fd = products_fd = -1
try:
    root_fd = os.open(archive, flags)
    root = os.fstat(root_fd)
    if not stat.S_ISDIR(root.st_mode) or root.st_uid != os.geteuid():
        raise ValueError
    products_before = os.stat("Products", dir_fd=root_fd, follow_symlinks=False)
    if (
        not stat.S_ISDIR(products_before.st_mode)
        or stat.S_ISLNK(products_before.st_mode)
        or products_before.st_dev != root.st_dev
        or products_before.st_uid != os.geteuid()
    ):
        raise ValueError
    products_fd = os.open("Products", flags, dir_fd=root_fd)
    opened = os.fstat(products_fd)
    if not same(products_before, opened):
        raise ValueError
    names = xattr_names(products_fd)
    if not names.issubset({marker, provenance}) or not canonical_provenance(products_fd, names):
        raise ValueError
    if marker in names:
        if xattr_value(products_fd, marker) != b"true":
            raise ValueError
        ctypes.set_errno(0)
        if fremovexattr(products_fd, marker, 0) != 0:
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error))
    normalized = os.fstat(products_fd)
    if not same(opened, normalized):
        raise ValueError
    names = xattr_names(products_fd)
    if names not in (set(), {provenance}) or not canonical_provenance(products_fd, names):
        raise ValueError
    current = os.stat("Products", dir_fd=root_fd, follow_symlinks=False)
    if not same(normalized, current):
        raise ValueError
except (OSError, ValueError):
    raise SystemExit(1)
finally:
    if products_fd >= 0:
        os.close(products_fd)
    if root_fd >= 0:
        os.close(root_fd)
PY
}

normalize_archive_build_marker "$ARCHIVE_PATH" || fail forbidden-archive-content 35

logical_tree_manifest() {
  local mode="$1"
  local tree="$2"
  local manifest="$3"
  $PYTHON -I - "$mode" "$tree" "$manifest" <<'PY'
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
import sys


mode, raw_root, raw_manifest = sys.argv[1:4]
root = Path(raw_root)
manifest = Path(raw_manifest)
stable_fields = (
    "st_dev", "st_ino", "st_mode", "st_uid", "st_nlink", "st_size",
    "st_mtime_ns", "st_ctime_ns",
)


def same(left: os.stat_result, right: os.stat_result) -> bool:
    return all(getattr(left, field) == getattr(right, field) for field in stable_fields)


def checked_text(value: str) -> str:
    value.encode("utf-8", errors="strict")
    if not value or any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise ValueError
    return value


def collect_directory(path: Path, relative: str, device: int, records: list[list[object]]) -> None:
    before = os.lstat(path)
    if (
        not stat.S_ISDIR(before.st_mode)
        or stat.S_ISLNK(before.st_mode)
        or before.st_dev != device
        or before.st_uid != os.geteuid()
        or before.st_mode & 0o022
    ):
        raise ValueError
    names = sorted(os.listdir(path), key=lambda value: checked_text(value).encode("utf-8"))
    for name in names:
        checked_text(name)
        if name in {".", ".."} or "/" in name:
            raise ValueError
        if mode == "hash-output" and relative == "." and name == ".transient":
            continue
        child = path / name
        child_relative = checked_text(name if relative == "." else f"{relative}/{name}")
        child_before = os.lstat(child)
        if child_before.st_dev != device or child_before.st_uid != os.geteuid():
            raise ValueError
        if stat.S_ISDIR(child_before.st_mode) and not stat.S_ISLNK(child_before.st_mode):
            if child_before.st_mode & 0o022:
                raise ValueError
            collect_directory(child, child_relative, device, records)
        elif stat.S_ISREG(child_before.st_mode):
            if child_before.st_nlink != 1 or child_before.st_mode & 0o022:
                raise ValueError
            descriptor = os.open(child, os.O_RDONLY | os.O_NOFOLLOW)
            try:
                opened = os.fstat(descriptor)
                if not same(child_before, opened):
                    raise ValueError
                digest = hashlib.sha256()
                while True:
                    chunk = os.read(descriptor, 1024 * 1024)
                    if not chunk:
                        break
                    digest.update(chunk)
                after = os.fstat(descriptor)
                if not same(opened, after):
                    raise ValueError
            finally:
                os.close(descriptor)
            records.append([child_relative, "file", stat.S_IMODE(after.st_mode), digest.hexdigest()])
        elif stat.S_ISLNK(child_before.st_mode):
            target = checked_text(os.readlink(child))
            target_path = PurePosixPath(target)
            joined = PurePosixPath(child_relative).parent.joinpath(target_path)
            if (
                not target_path.parts
                or target_path.is_absolute()
                or ".." in target_path.parts
                or joined.is_absolute()
                or ".." in joined.parts
            ):
                raise ValueError
            try:
                (child.parent / target).resolve(strict=True).relative_to(root.resolve(strict=True))
            except (OSError, RuntimeError, ValueError):
                raise ValueError
            child_after = os.lstat(child)
            if not same(child_before, child_after):
                raise ValueError
            records.append([child_relative, "symlink", stat.S_IMODE(child_after.st_mode), target])
        else:
            raise ValueError
    after = os.lstat(path)
    if not same(before, after):
        raise ValueError
    if relative != ".":
        records.append([relative, "directory", stat.S_IMODE(after.st_mode), ""])


def collect() -> bytes:
    root_metadata = os.lstat(root)
    if (
        not stat.S_ISDIR(root_metadata.st_mode)
        or stat.S_ISLNK(root_metadata.st_mode)
        or root_metadata.st_uid != os.geteuid()
        or root_metadata.st_mode & 0o022
    ):
        raise ValueError
    records: list[list[object]] = []
    collect_directory(root, ".", root_metadata.st_dev, records)
    records.sort(key=lambda value: checked_text(str(value[0])).encode("utf-8"))
    lines = [
        json.dumps(record, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8") + b"\n"
        for record in records
    ]
    return b"".join(lines)


def read_manifest() -> bytes:
    metadata = os.lstat(manifest)
    if (
        not stat.S_ISREG(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or metadata.st_nlink != 1
        or stat.S_IMODE(metadata.st_mode) != 0o400
    ):
        raise ValueError
    descriptor = os.open(manifest, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        chunks: list[bytes] = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks)
    finally:
        os.close(descriptor)


try:
    payload = collect()
    if mode == "capture":
        descriptor = os.open(
            manifest,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o400,
        )
        try:
            offset = 0
            while offset < len(payload):
                offset += os.write(descriptor, payload[offset:])
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    elif mode == "verify":
        if read_manifest() != payload:
            raise ValueError
    elif mode not in {"hash", "hash-output"}:
        raise ValueError
    print(hashlib.sha256(payload).hexdigest())
except (OSError, UnicodeError, ValueError):
    raise SystemExit(1)
PY
}

ARCHIVE_MANIFEST="$TRANSIENT/archive-manifest.jsonl"
APP_MANIFEST="$TRANSIENT/app-manifest.jsonl"
ARCHIVE_TREE_SHA256="$(logical_tree_manifest capture "$ARCHIVE_PATH" "$ARCHIVE_MANIFEST")" ||
  fail archive-inspection-failed 35
APP_TREE_SHA256="$(logical_tree_manifest capture "$APP" "$APP_MANIFEST")" ||
  fail archive-inspection-failed 35
[[ "$ARCHIVE_TREE_SHA256" =~ ^[0-9a-f]{64}$ && "$APP_TREE_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
  fail archive-inspection-failed 35

inspect_archive_content() {
  local inspected_root="$1"
  local policy_mode="$2"
  $PYTHON -I - "$inspected_root" "$policy_mode" "$TEST_MODE" "${UTTERINK_FIXTURE_LOG:--}" <<'PY' >/dev/null 2>&1
from __future__ import annotations

import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys


class ContentError(Exception):
    def __init__(self, category: str):
        super().__init__(category)
        self.category = category


archive = Path(sys.argv[1])
policy_mode = sys.argv[2]
test_mode = sys.argv[3] == "1"
fixture_log = Path(sys.argv[4]) if test_mode else None
archive_root = archive.resolve(strict=True)
if policy_mode not in {"archive", "app", "stage"}:
    raise SystemExit(1)
private_markers = (
    b"-----BEGIN " + b"PRIVATE KEY-----",
    b"-----BEGIN RSA " + b"PRIVATE KEY-----",
    b"OPENAI_API_KEY=",
    b"AWS_ACCESS_KEY_ID=",
    b'"client_secret"',
)
path_markers = (b"/" + b"Users/", b"/" + b"home/", b"C:" + b"\\Users\\")
command_markers = (
    b"xattr -d com.apple.quarantine",
    b"xattr -dr com.apple.quarantine",
    b"xattr -cr",
)
archive_debug_path_exceptions = {
    "dSYMs/UtterInk.app.dSYM/Contents/Resources/DWARF/UtterInk",
    "dSYMs/UtterInk.app.dSYM/Contents/Resources/Relocations/aarch64/UtterInk.yml",
}
if policy_mode == "archive":
    debug_path_exceptions = archive_debug_path_exceptions
elif policy_mode == "stage":
    debug_path_exceptions = {
        f"UtterInk.xcarchive/{relative}" for relative in archive_debug_path_exceptions
    }
else:
    debug_path_exceptions = set()
credential_names = {
    ".env", ".netrc", "auth.json", "credential.json", "credentials.json", "secrets.json", "token.txt"
}
credential_suffixes = {".cer", ".key", ".mobileprovision", ".p12", ".pem", ".pfx"}


def reject(category: str = "content") -> None:
    raise ContentError(category)


def reject_extended_attributes(path: Path) -> None:
    result = subprocess.run(
        ["/usr/bin/xattr", "-s", str(path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
        env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"},
    )
    if result.returncode != 0:
        reject("xattr-read")
    try:
        names = set(result.stdout.decode("utf-8", errors="strict").splitlines())
    except UnicodeError:
        reject("xattr-read")
    if not names:
        return
    if names != {"com.apple.provenance"}:
        reject("xattr-policy")
    value = subprocess.run(
        ["/usr/bin/xattr", "-s", "-px", "com.apple.provenance", str(path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
        env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"},
    )
    if value.returncode != 0:
        reject("xattr-read")
    try:
        provenance = bytes.fromhex(value.stdout.decode("ascii", errors="strict"))
    except (UnicodeError, ValueError):
        reject("xattr-read")
    if len(provenance) != 11 or provenance[:3] != b"\x01\x02\x00":
        reject("xattr-policy")


def scan(path: Path, relative: str) -> None:
    flags = os.O_RDONLY | os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            reject("content-marker")
        needles = private_markers + command_markers
        if relative not in debug_path_exceptions:
            needles += path_markers
        overlap = max(len(value) for value in needles) - 1
        tail = b""
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            sample = tail + chunk
            if any(value in sample for value in needles):
                reject()
            tail = sample[-overlap:]
        after = os.fstat(descriptor)
        if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (
            after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns
        ):
            reject("file-mutated")
    finally:
        os.close(descriptor)


try:
    root_metadata = os.lstat(archive)
    if not stat.S_ISDIR(root_metadata.st_mode) or stat.S_ISLNK(root_metadata.st_mode):
        reject("app-layout")
    for current_text, directories, files in os.walk(archive, topdown=True, followlinks=False):
        current = Path(current_text)
        reject_extended_attributes(current)
        for name in sorted(directories + files, key=lambda value: value.encode("utf-8", errors="strict")):
            path = current / name
            lower = name.lower()
            metadata = os.lstat(path)
            if lower in credential_names or Path(lower).suffix in credential_suffixes:
                reject("credential-name")
            if lower == "embedded.provisionprofile" or (lower.endswith(".dylib") and "debug" in lower):
                reject("forbidden-binary")
            reject_extended_attributes(path)
            if stat.S_ISLNK(metadata.st_mode):
                target = PurePosixPath(os.readlink(path))
                relative = PurePosixPath(path.relative_to(archive).as_posix())
                joined = relative.parent.joinpath(target)
                if (
                    target.is_absolute()
                    or not target.parts
                    or ".." in target.parts
                    or joined.is_absolute()
                    or ".." in joined.parts
                ):
                    reject("symlink-target")
                try:
                    path.resolve(strict=True).relative_to(archive_root)
                except (OSError, RuntimeError, ValueError):
                    reject("symlink-escape")
            elif stat.S_ISREG(metadata.st_mode):
                scan(path, path.relative_to(archive).as_posix())
            elif not stat.S_ISDIR(metadata.st_mode):
                reject("special-file")
except ContentError as error:
    if fixture_log is not None:
        try:
            with fixture_log.open("a", encoding="utf-8") as handle:
                handle.write(f"content-error\t{error.category}\n")
        except OSError:
            pass
    raise SystemExit(1)
except (OSError, UnicodeError, ValueError):
    if fixture_log is not None:
        try:
            with fixture_log.open("a", encoding="utf-8") as handle:
                handle.write("content-error\toperating-system\n")
        except OSError:
            pass
    raise SystemExit(1)
PY
}

if ! inspect_archive_content "$ARCHIVE_PATH" archive; then
  fail forbidden-archive-content 35
fi

MAIN_FILE_DESCRIPTION="$($FILE_TOOL -b "$MAIN_EXECUTABLE" 2> "$TRANSIENT/main-file-error")" ||
  fail archive-inspection-failed 35
case "$MAIN_FILE_DESCRIPTION" in
  *Mach-O*arm64*|*arm64*Mach-O*) ;;
  *) fail archive-main-executable-invalid 35 ;;
esac
MAIN_ARCHITECTURES="$($LIPO -archs "$MAIN_EXECUTABLE" 2> "$TRANSIENT/main-lipo-error")" ||
  fail archive-main-executable-invalid 35
[[ "$MAIN_ARCHITECTURES" == arm64 ]] || fail archive-main-executable-invalid 35
"$OTOOL" -l "$MAIN_EXECUTABLE" > "$TRANSIENT/otool-main" 2> "$TRANSIENT/main-otool-error" ||
  fail archive-main-executable-invalid 35
if /usr/bin/grep -Eq '^[[:space:]]*cmd[[:space:]]+LC_CODE_SIGNATURE[[:space:]]*$' "$TRANSIENT/otool-main"; then
  fail archive-unexpected-signature 35
fi

MACH_O_COUNT=0
while IFS= read -r -d '' candidate; do
  FILE_DESCRIPTION="$($FILE_TOOL -b "$candidate" 2> "$TRANSIENT/file-error")" || fail archive-inspection-failed 35
  case "$FILE_DESCRIPTION" in
    *Mach-O*) ;;
    *) continue ;;
  esac
  MACH_O_COUNT=$((MACH_O_COUNT + 1))
  ARCHITECTURES="$($LIPO -archs "$candidate" 2> "$TRANSIENT/lipo-error")" || fail archive-inspection-failed 35
  [[ "$ARCHITECTURES" == arm64 ]] || fail unsupported-architecture 35
  "$OTOOL" -l "$candidate" > "$TRANSIENT/otool-$MACH_O_COUNT" 2> "$TRANSIENT/otool-error" ||
    fail archive-inspection-failed 35
  if /usr/bin/grep -Eq '^[[:space:]]*cmd[[:space:]]+LC_CODE_SIGNATURE[[:space:]]*$' "$TRANSIENT/otool-$MACH_O_COUNT"; then
    fail archive-unexpected-signature 35
  fi
done < <(/usr/bin/find "$ARCHIVE_PATH" -type f -print0)
[[ "$MACH_O_COUNT" -gt 0 ]] || fail archive-inspection-failed 35
if /usr/bin/find "$ARCHIVE_PATH" \( -name _CodeSignature -o -name CodeResources \) -print -quit | /usr/bin/grep -q .; then
  fail archive-unexpected-signature 35
fi
[[ "$(logical_tree_manifest verify "$ARCHIVE_PATH" "$ARCHIVE_MANIFEST")" == "$ARCHIVE_TREE_SHA256" ]] ||
  fail archive-changed-after-inspection 35
[[ "$(logical_tree_manifest verify "$APP" "$APP_MANIFEST")" == "$APP_TREE_SHA256" ]] ||
  fail archive-changed-after-inspection 35

run_test_hook after-source-checked "$ARCHIVE_PATH" "$APP" "$VERIFIER_OUTPUT" "$STAGE"

/bin/mkdir -m 0700 "$STAGE/candidate"
"$DITTO" "$ARCHIVE_PATH" "$STAGE/UtterInk.xcarchive" > "$TRANSIENT/ditto-archive-output" 2> "$TRANSIENT/ditto-archive-error" ||
  fail staging-copy-failed 36
"$DITTO" "$APP" "$STAGE/candidate/UtterInk.app" > "$TRANSIENT/ditto-app-output" 2> "$TRANSIENT/ditto-app-error" ||
  fail staging-copy-failed 36
file_fingerprint verify "$VERIFIED_CANDIDATE" "$CANDIDATE_SNAPSHOT_FINGERPRINT" ||
  fail candidate-evidence-invalid 36
run_test_hook before-candidate-copy "$VERIFIED_CANDIDATE" "$STAGE/candidate"
if ! CANDIDATE_JSON_SHA256="$(
  $PYTHON -I - \
    "$VERIFIED_CANDIDATE" "$STAGE/candidate/candidate.json" \
    "$CANDIDATE_SNAPSHOT_FINGERPRINT" <<'PY' 2>/dev/null
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import stat
import sys


source = Path(sys.argv[1])
destination = Path(sys.argv[2])
expected_token = sys.argv[3]
stable_fields = (
    "st_dev", "st_ino", "st_mode", "st_uid", "st_nlink", "st_size",
    "st_mtime_ns", "st_ctime_ns",
)


def same(left: os.stat_result, right: os.stat_result) -> bool:
    return all(getattr(left, field) == getattr(right, field) for field in stable_fields)


def token(metadata: os.stat_result, digest: str) -> str:
    return json.dumps(
        {
            "device": metadata.st_dev,
            "inode": metadata.st_ino,
            "mode": metadata.st_mode,
            "uid": metadata.st_uid,
            "links": metadata.st_nlink,
            "size": metadata.st_size,
            "mtimeNS": metadata.st_mtime_ns,
            "ctimeNS": metadata.st_ctime_ns,
            "sha256": digest,
        },
        sort_keys=True,
        separators=(",", ":"),
    )


source_fd = parent_fd = destination_fd = -1
created = False
try:
    before = os.lstat(source)
    if (
        not stat.S_ISREG(before.st_mode)
        or stat.S_ISLNK(before.st_mode)
        or before.st_uid != os.geteuid()
        or before.st_nlink != 1
        or stat.S_IMODE(before.st_mode) != 0o400
        or before.st_size <= 0
        or before.st_size > 512 * 1024
    ):
        raise ValueError
    source_fd = os.open(
        source,
        os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0),
    )
    opened = os.fstat(source_fd)
    if not same(before, opened):
        raise ValueError
    chunks: list[bytes] = []
    digest = hashlib.sha256()
    remaining = opened.st_size
    while remaining:
        chunk = os.read(source_fd, min(remaining, 1024 * 1024))
        if not chunk:
            raise ValueError
        chunks.append(chunk)
        digest.update(chunk)
        remaining -= len(chunk)
    if os.read(source_fd, 1):
        raise ValueError
    after = os.fstat(source_fd)
    candidate_hash = digest.hexdigest()
    if not same(opened, after) or token(after, candidate_hash) != expected_token:
        raise ValueError
    payload = b"".join(chunks)

    parent_fd = os.open(
        destination.parent,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0),
    )
    parent_metadata = os.fstat(parent_fd)
    if (
        not stat.S_ISDIR(parent_metadata.st_mode)
        or parent_metadata.st_uid != os.geteuid()
        or stat.S_IMODE(parent_metadata.st_mode) != 0o700
    ):
        raise ValueError
    destination_fd = os.open(
        destination.name,
        os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0),
        0o600,
        dir_fd=parent_fd,
    )
    created = True
    offset = 0
    while offset < len(payload):
        offset += os.write(destination_fd, payload[offset:])
    os.fchmod(destination_fd, 0o644)
    os.fsync(destination_fd)
    written = os.fstat(destination_fd)
    if (
        not stat.S_ISREG(written.st_mode)
        or written.st_uid != os.geteuid()
        or written.st_nlink != 1
        or stat.S_IMODE(written.st_mode) != 0o644
        or written.st_size != len(payload)
    ):
        raise ValueError
    os.lseek(destination_fd, 0, os.SEEK_SET)
    copied = hashlib.sha256()
    while True:
        chunk = os.read(destination_fd, 1024 * 1024)
        if not chunk:
            break
        copied.update(chunk)
    copied_after = os.fstat(destination_fd)
    current = os.stat(destination.name, dir_fd=parent_fd, follow_symlinks=False)
    if (
        copied.hexdigest() != candidate_hash
        or not same(written, copied_after)
        or (current.st_dev, current.st_ino) != (written.st_dev, written.st_ino)
    ):
        raise ValueError
    print(candidate_hash)
except (OSError, UnicodeError, ValueError):
    if created and parent_fd >= 0 and destination_fd >= 0:
        try:
            opened_destination = os.fstat(destination_fd)
            current = os.stat(destination.name, dir_fd=parent_fd, follow_symlinks=False)
            if (current.st_dev, current.st_ino) == (opened_destination.st_dev, opened_destination.st_ino):
                os.unlink(destination.name, dir_fd=parent_fd)
        except OSError:
            pass
    raise SystemExit(1)
finally:
    if destination_fd >= 0:
        os.close(destination_fd)
    if parent_fd >= 0:
        os.close(parent_fd)
    if source_fd >= 0:
        os.close(source_fd)
PY
)"; then
  fail staging-copy-failed 36
fi
[[ "$CANDIDATE_JSON_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail staging-copy-failed 36

[[ "$(logical_tree_manifest verify "$STAGE/UtterInk.xcarchive" "$ARCHIVE_MANIFEST")" == "$ARCHIVE_TREE_SHA256" ]] ||
  fail staging-copy-failed 36
[[ "$(logical_tree_manifest verify "$STAGE/candidate/UtterInk.app" "$APP_MANIFEST")" == "$APP_TREE_SHA256" ]] ||
  fail staging-copy-failed 36
inspect_archive_content "$STAGE/UtterInk.xcarchive" archive || fail staging-copy-failed 36
inspect_archive_content "$STAGE/candidate/UtterInk.app" app || fail staging-copy-failed 36

UNSIGNED_BUILD_EVIDENCE="$STAGE/candidate/unsigned-build-evidence.json"
if ! UNSIGNED_BUILD_EVIDENCE_SHA256="$(
  $PYTHON -I - \
    "$UNSIGNED_BUILD_EVIDENCE" "$COMMIT" "$CANDIDATE_JSON_SHA256" \
    "$APP_TREE_SHA256" "$ARCHIVE_TREE_SHA256" <<'PY' 2>/dev/null
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys


output = Path(sys.argv[1])
commit, candidate_hash, app_hash, archive_hash = sys.argv[2:6]
if re.fullmatch(r"[0-9a-f]{40}", commit) is None:
    raise SystemExit(1)
if any(re.fullmatch(r"[0-9a-f]{64}", value) is None for value in (candidate_hash, app_hash, archive_hash)):
    raise SystemExit(1)
value = {
    "appTreeSHA256": app_hash,
    "archiveTreeSHA256": archive_hash,
    "candidateCommit": commit,
    "candidateJSONSHA256": candidate_hash,
    "evidenceType": "unsigned-build",
    "product": "UtterInk",
    "schemaVersion": 1,
    "status": "valid",
    "treeAlgorithm": "utterink-logical-tree-v1",
}
payload = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
try:
    descriptor = os.open(
        output,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o600,
    )
    try:
        offset = 0
        while offset < len(payload):
            offset += os.write(descriptor, payload[offset:])
        os.fsync(descriptor)
        os.fchmod(descriptor, 0o644)
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) != 0o644:
            raise OSError
    finally:
        os.close(descriptor)
except OSError:
    try:
        os.unlink(output)
    except OSError:
        pass
    raise SystemExit(1)
print(hashlib.sha256(payload).hexdigest())
PY
)"; then
  fail staging-copy-failed 36
fi
[[ "$UNSIGNED_BUILD_EVIDENCE_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail staging-copy-failed 36

if ! $PYTHON -I - "$STAGE" <<'PY' >/dev/null 2>&1
import os
from pathlib import Path
import stat
import sys

stage = Path(sys.argv[1])
if sorted(path.name for path in stage.iterdir()) != [".transient", "UtterInk.xcarchive", "candidate"]:
    raise SystemExit(1)
candidate = stage / "candidate"
if sorted(path.name for path in candidate.iterdir()) != [
    "UtterInk.app", "candidate.json", "unsigned-build-evidence.json"
]:
    raise SystemExit(1)
for required in (stage / "UtterInk.xcarchive", candidate, candidate / "UtterInk.app"):
    metadata = os.lstat(required)
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise SystemExit(1)
for required in (candidate / "candidate.json", candidate / "unsigned-build-evidence.json"):
    metadata = os.lstat(required)
    if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) != 0o644:
        raise SystemExit(1)
PY
then
  fail staging-copy-failed 36
fi

FINAL_STAGE_MANIFEST_SHA256="$(logical_tree_manifest hash-output "$STAGE" -)" ||
  fail staging-layout-invalid 37
[[ "$FINAL_STAGE_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail staging-layout-invalid 37
run_test_hook after-stage-checked "$STAGE" "$UNSIGNED_BUILD_EVIDENCE"

if [[ "$TEST_MODE" -eq 1 ]]; then
  exec 8< "$MUTATION_HOOK" || fail test-hook-failed 39
  exec 9< "$MUTATION_HOOK" || fail test-hook-failed 39
fi
safe_remove_tree "$STAGE" .transient "$TRANSIENT_DEVICE" "$TRANSIENT_INODE" 0 || fail work-cleanup-failed 37
inspect_archive_content "$STAGE" stage || fail staging-layout-invalid 37
if ! $PYTHON -I - "$STAGE" <<'PY' >/dev/null 2>&1
import os
from pathlib import Path
import stat
import sys

stage = Path(sys.argv[1])
if sorted(path.name for path in stage.iterdir()) != ["UtterInk.xcarchive", "candidate"]:
    raise SystemExit(1)
if any(path.is_symlink() for path in stage.iterdir()):
    raise SystemExit(1)
metadata = os.lstat(stage)
if not stat.S_ISDIR(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) != 0o700:
    raise SystemExit(1)
candidate = stage / "candidate"
if sorted(path.name for path in candidate.iterdir()) != [
    "UtterInk.app", "candidate.json", "unsigned-build-evidence.json"
]:
    raise SystemExit(1)
PY
then
  fail staging-layout-invalid 37
fi

run_late_test_hook 8 before-publish "$STAGE"

trap '' HUP INT TERM
if ! $PYTHON -I - \
  "$RELEASE_WORK" "$(/usr/bin/basename "$STAGE")" "$STAGE_DEVICE" "$STAGE_INODE" \
  "$WORK_NAME" "$FINAL_STAGE_MANIFEST_SHA256" \
  "$CANDIDATE_JSON_SHA256" "$UNSIGNED_BUILD_EVIDENCE_SHA256" \
  "$APP_TREE_SHA256" "$ARCHIVE_TREE_SHA256" "$TEST_MODE" <<'PY' >/dev/null 2>&1
from __future__ import annotations

import ctypes
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys

parent = Path(sys.argv[1])
source_name = sys.argv[2]
expected = (int(sys.argv[3]), int(sys.argv[4]))
target_name = sys.argv[5]
expected_manifest = sys.argv[6]
expected_candidate_hash = sys.argv[7]
expected_evidence_hash = sys.argv[8]
expected_app_hash = sys.argv[9]
expected_archive_hash = sys.argv[10]
if any(not name or name in {".", ".."} or "/" in name for name in (source_name, target_name)):
    raise SystemExit(1)
if any(
    re.fullmatch(r"[0-9a-f]{64}", value) is None
    for value in (
        expected_manifest,
        expected_candidate_hash,
        expected_evidence_hash,
        expected_app_hash,
        expected_archive_hash,
    )
):
    raise SystemExit(1)
flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
stable_fields = (
    "st_dev", "st_ino", "st_mode", "st_uid", "st_nlink", "st_size",
    "st_mtime_ns", "st_ctime_ns",
)
O_SYMLINK = 0x00200000
libc = ctypes.CDLL(None, use_errno=True)
flistxattr = libc.flistxattr
flistxattr.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
flistxattr.restype = ctypes.c_ssize_t
fgetxattr = libc.fgetxattr
fgetxattr.argtypes = [
    ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int,
]
fgetxattr.restype = ctypes.c_ssize_t


def same(left: os.stat_result, right: os.stat_result) -> bool:
    return all(getattr(left, field) == getattr(right, field) for field in stable_fields)


def checked_text(value: str) -> str:
    value.encode("utf-8", errors="strict")
    if not value or any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise ValueError
    return value


def reject_extended_attributes(descriptor: int) -> None:
    ctypes.set_errno(0)
    size = flistxattr(descriptor, None, 0, 0)
    if size < 0 or size > 64 * 1024:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    if size == 0:
        return
    buffer = ctypes.create_string_buffer(size)
    ctypes.set_errno(0)
    actual = flistxattr(descriptor, buffer, size, 0)
    if actual < 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    if actual != size:
        raise ValueError
    names = {name for name in buffer.raw[:actual].split(b"\0") if name}
    provenance_name = b"com.apple.provenance"
    if names != {provenance_name}:
        raise ValueError
    ctypes.set_errno(0)
    value_size = fgetxattr(descriptor, provenance_name, None, 0, 0, 0)
    if value_size != 11:
        if value_size < 0:
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error))
        raise ValueError
    value = ctypes.create_string_buffer(value_size)
    ctypes.set_errno(0)
    value_actual = fgetxattr(descriptor, provenance_name, value, value_size, 0, 0)
    if value_actual < 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    if value_actual != value_size or value.raw[:value_actual][:3] != b"\x01\x02\x00":
        raise ValueError


def collect_directory(
    descriptor: int,
    relative: str,
    device: int,
    records: list[list[object]],
) -> None:
    before = os.fstat(descriptor)
    if (
        not stat.S_ISDIR(before.st_mode)
        or before.st_dev != device
        or before.st_uid != os.geteuid()
        or before.st_mode & 0o022
    ):
        raise ValueError
    reject_extended_attributes(descriptor)
    names = sorted(os.listdir(descriptor), key=lambda value: checked_text(value).encode("utf-8"))
    for name in names:
        checked_text(name)
        if name in {".", ".."} or "/" in name:
            raise ValueError
        child_relative = checked_text(name if relative == "." else f"{relative}/{name}")
        child_before = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        if child_before.st_dev != device or child_before.st_uid != os.geteuid():
            raise ValueError
        if stat.S_ISDIR(child_before.st_mode) and not stat.S_ISLNK(child_before.st_mode):
            if child_before.st_mode & 0o022:
                raise ValueError
            child = os.open(name, flags, dir_fd=descriptor)
            try:
                opened = os.fstat(child)
                if not same(child_before, opened):
                    raise ValueError
                collect_directory(child, child_relative, device, records)
            finally:
                os.close(child)
        elif stat.S_ISREG(child_before.st_mode):
            if child_before.st_nlink != 1 or child_before.st_mode & 0o022:
                raise ValueError
            child = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=descriptor)
            try:
                opened = os.fstat(child)
                if not same(child_before, opened):
                    raise ValueError
                reject_extended_attributes(child)
                digest = hashlib.sha256()
                while True:
                    chunk = os.read(child, 1024 * 1024)
                    if not chunk:
                        break
                    digest.update(chunk)
                after = os.fstat(child)
                if not same(opened, after):
                    raise ValueError
                reject_extended_attributes(child)
                final = os.fstat(child)
                if not same(after, final):
                    raise ValueError
            finally:
                os.close(child)
            records.append([child_relative, "file", stat.S_IMODE(after.st_mode), digest.hexdigest()])
        elif stat.S_ISLNK(child_before.st_mode):
            target = checked_text(os.readlink(name, dir_fd=descriptor))
            target_path = PurePosixPath(target)
            joined = PurePosixPath(child_relative).parent.joinpath(target_path)
            if (
                not target_path.parts
                or target_path.is_absolute()
                or ".." in target_path.parts
                or joined.is_absolute()
                or ".." in joined.parts
            ):
                raise ValueError
            child = os.open(
                name,
                O_SYMLINK | getattr(os, "O_CLOEXEC", 0),
                dir_fd=descriptor,
            )
            try:
                opened = os.fstat(child)
                if not same(child_before, opened) or not stat.S_ISLNK(opened.st_mode):
                    raise ValueError
                reject_extended_attributes(child)
                opened_after = os.fstat(child)
                if not same(opened, opened_after):
                    raise ValueError
            finally:
                os.close(child)
            child_after = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
            if not same(child_before, child_after):
                raise ValueError
            records.append([child_relative, "symlink", stat.S_IMODE(child_after.st_mode), target])
        else:
            raise ValueError
    after = os.fstat(descriptor)
    if not same(before, after):
        raise ValueError
    reject_extended_attributes(descriptor)
    final = os.fstat(descriptor)
    if not same(after, final):
        raise ValueError
    if relative != ".":
        records.append([relative, "directory", stat.S_IMODE(after.st_mode), ""])


def manifest_digest(descriptor: int, device: int) -> str:
    records: list[list[object]] = []
    collect_directory(descriptor, ".", device, records)
    records.sort(key=lambda value: checked_text(str(value[0])).encode("utf-8"))
    by_path = {str(record[0]): record for record in records}
    if (
        len(by_path) != len(records)
        or by_path.get("candidate/candidate.json", [None, None, None, None])[1:] != [
            "file", 0o644, expected_candidate_hash
        ]
        or by_path.get("candidate/unsigned-build-evidence.json", [None, None, None, None])[1:] != [
            "file", 0o644, expected_evidence_hash
        ]
    ):
        raise ValueError

    def subtree_digest(prefix: str) -> str:
        normalized: list[list[object]] = []
        prefix_with_separator = f"{prefix}/"
        for record in records:
            path = str(record[0])
            if path.startswith(prefix_with_separator):
                normalized.append([path[len(prefix_with_separator):], *record[1:]])
        normalized.sort(key=lambda value: checked_text(str(value[0])).encode("utf-8"))
        if not normalized:
            raise ValueError
        payload = b"".join(
            json.dumps(record, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8") + b"\n"
            for record in normalized
        )
        return hashlib.sha256(payload).hexdigest()

    if (
        subtree_digest("candidate/UtterInk.app") != expected_app_hash
        or subtree_digest("UtterInk.xcarchive") != expected_archive_hash
    ):
        raise ValueError
    payload = b"".join(
        json.dumps(record, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8") + b"\n"
        for record in records
    )
    return hashlib.sha256(payload).hexdigest()


parent_fd = stage_fd = target_fd = -1
renamed = False
rename_exclusive = None
try:
    parent_fd = os.open(parent, flags)
    parent_metadata = os.fstat(parent_fd)
    if (
        not stat.S_ISDIR(parent_metadata.st_mode)
        or parent_metadata.st_uid != os.geteuid()
        or stat.S_IMODE(parent_metadata.st_mode) != 0o700
    ):
        raise OSError
    stage_fd = os.open(source_name, flags, dir_fd=parent_fd)
    source_metadata = os.fstat(stage_fd)
    if (
        (source_metadata.st_dev, source_metadata.st_ino) != expected
        or not stat.S_ISDIR(source_metadata.st_mode)
        or source_metadata.st_uid != os.geteuid()
        or stat.S_IMODE(source_metadata.st_mode) != 0o700
        or source_metadata.st_dev != parent_metadata.st_dev
    ):
        raise OSError
    if manifest_digest(stage_fd, source_metadata.st_dev) != expected_manifest:
        raise OSError
    try:
        os.stat(target_name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        pass
    else:
        raise OSError
    libc = ctypes.CDLL(None, use_errno=True)
    rename_exclusive = libc.renameatx_np
    rename_exclusive.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename_exclusive.restype = ctypes.c_int
    if rename_exclusive(parent_fd, os.fsencode(source_name), parent_fd, os.fsencode(target_name), 0x00000004) != 0:
        raise OSError(ctypes.get_errno(), "renameatx_np")
    renamed = True
    target_metadata = os.stat(target_name, dir_fd=parent_fd, follow_symlinks=False)
    if (target_metadata.st_dev, target_metadata.st_ino) != expected:
        raise OSError
    try:
        os.stat(source_name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        pass
    else:
        raise OSError
    if manifest_digest(stage_fd, source_metadata.st_dev) != expected_manifest:
        raise OSError
    target_fd = os.open(target_name, flags, dir_fd=parent_fd)
    opened_target = os.fstat(target_fd)
    if (opened_target.st_dev, opened_target.st_ino) != expected:
        raise OSError
    if manifest_digest(target_fd, source_metadata.st_dev) != expected_manifest:
        raise OSError
except (AttributeError, OSError, UnicodeError, ValueError):
    if renamed and parent_fd >= 0 and rename_exclusive is not None:
        try:
            current = os.stat(target_name, dir_fd=parent_fd, follow_symlinks=False)
            if (current.st_dev, current.st_ino) == expected:
                try:
                    os.stat(source_name, dir_fd=parent_fd, follow_symlinks=False)
                except FileNotFoundError:
                    if rename_exclusive(
                        parent_fd,
                        os.fsencode(target_name),
                        parent_fd,
                        os.fsencode(source_name),
                        0x00000004,
                    ) == 0:
                        renamed = False
        except OSError:
            pass
    raise SystemExit(1)
finally:
    if target_fd >= 0:
        os.close(target_fd)
    if stage_fd >= 0:
        os.close(stage_fd)
    if parent_fd >= 0:
        os.close(parent_fd)
PY
then
  fail publish-failed 38
fi
run_late_test_hook 9 after-publish-rename "$WORK_ABSOLUTE"
if [[ "$TEST_MODE" -eq 1 ]]; then
  exec 8<&-
  exec 9<&-
fi
[[ -d "$WORK_ABSOLUTE/UtterInk.xcarchive" && -f "$WORK_ABSOLUTE/candidate/candidate.json" &&
  -f "$WORK_ABSOLUTE/candidate/unsigned-build-evidence.json" && -d "$WORK_ABSOLUTE/candidate/UtterInk.app" ]] ||
  fail publish-failed 38
PUBLISHED=1
trap - HUP INT TERM
exit 0
