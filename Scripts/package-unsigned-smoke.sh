#!/usr/bin/env -S -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u BASH_XTRACEFD -u PS4 -u POSIXLY_CORRECT -u BASH_COMPAT -u UTTERINK_PACKAGE_ENV_CLEAN /bin/bash -p

set +x +v
if [[ "$-" != *p* ]]; then
  printf 'unsigned packaging error: unsafe-launch-environment\n' >&2
  exit 2
fi
if [[ "${UTTERINK_PACKAGE_ENV_CLEAN:-}" != 1 ]]; then
  clean_environment=(
    PATH=/usr/bin:/bin:/usr/sbin:/sbin
    LC_ALL=C
    UTTERINK_PACKAGE_ENV_CLEAN=1
  )
  for allowed_name in \
    UTTERINK_RELEASE_TEST_MODE \
    UTTERINK_RELEASE_TEST_TOOL_ROOT \
    UTTERINK_FIXTURE_LOG; do
    if [[ -n "${!allowed_name+x}" ]]; then
      clean_environment+=("$allowed_name=${!allowed_name}")
    fi
  done
  if [[ "${UTTERINK_RELEASE_TEST_MODE:-}" == 1 && -n "${UTTERINK_PACKAGE_TEST_PUBLISH_RACE+x}" ]]; then
    clean_environment+=("UTTERINK_PACKAGE_TEST_PUBLISH_RACE=${UTTERINK_PACKAGE_TEST_PUBLISH_RACE}")
  fi
  exec /usr/bin/env -i "${clean_environment[@]}" /bin/bash -p "$0" "$@"
  printf 'unsigned packaging error: unsafe-launch-environment\n' >&2
  exit 2
fi
if [[ "$-" != hpB || "${PATH-}" != /usr/bin:/bin:/usr/sbin:/sbin || "${LC_ALL-}" != C ]]; then
  printf 'unsigned packaging error: unsafe-launch-environment\n' >&2
  exit 2
fi
while IFS= read -r -d '' environment_entry; do
  environment_name="${environment_entry%%=*}"
  case "$environment_name" in
    PATH|LC_ALL|UTTERINK_PACKAGE_ENV_CLEAN|UTTERINK_RELEASE_TEST_MODE|UTTERINK_RELEASE_TEST_TOOL_ROOT|UTTERINK_FIXTURE_LOG|UTTERINK_PACKAGE_TEST_PUBLISH_RACE|PWD|SHLVL|_) ;;
    *)
      printf 'unsigned packaging error: unsafe-launch-environment\n' >&2
      exit 2
      ;;
  esac
done < <(/usr/bin/env -0)
unset UTTERINK_PACKAGE_ENV_CLEAN

set -euo pipefail

export LC_ALL=C
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_NO_LAZY_FETCH=1
export GIT_NO_REPLACE_OBJECTS=1
export GIT_TERMINAL_PROMPT=0
unset BASH_ENV ENV CDPATH GLOBIGNORE PYTHONHOME PYTHONPATH
unset DEVELOPER_DIR SDKROOT TOOLCHAINS XCODE_DEFAULT_TOOLCHAIN_OVERRIDE
unset XCODE_XCCONFIG_FILE SWIFT_EXEC DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH
umask 077

fail() {
  local category="$1"
  local status="${2:-1}"
  case "$category" in
    repository-xcodegen-missing|repository-xcodegen-mismatch|repository-xcodegen-unusable)
      printf 'unsigned packaging error: %s; run ./Scripts/bootstrap-xcodegen.sh\n' "$category" >&2
      ;;
    *)
      printf 'unsigned packaging error: %s\n' "$category" >&2
      ;;
  esac
  exit "$status"
}

COMMIT=''
OUTPUT=''
EXPECTED_ORIGIN=''
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --commit)
      [[ -z "$COMMIT" && "$#" -ge 2 && -n "$2" ]] || fail invalid-arguments 64
      COMMIT="$2"
      shift 2
      ;;
    --output)
      [[ -z "$OUTPUT" && "$#" -ge 2 && -n "$2" ]] || fail invalid-arguments 64
      OUTPUT="$2"
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
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ && -n "$OUTPUT" ]] || fail invalid-arguments 64

SCRIPT_PATH="${BASH_SOURCE[0]}"
[[ -f "$SCRIPT_PATH" && ! -L "$SCRIPT_PATH" ]] || fail unsafe-script-path
SCRIPT_DIRECTORY="$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "$SCRIPT_PATH")" && /bin/pwd -P)"
ROOT="$(CDPATH= cd -P -- "$SCRIPT_DIRECTORY/.." && /bin/pwd -P)"
GIT_ROOT="$(/usr/bin/git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" || fail not-a-repository
GIT_ROOT="$(CDPATH= cd -P -- "$GIT_ROOT" && /bin/pwd -P)"
[[ "$GIT_ROOT" == "$ROOT" ]] || fail repository-mismatch
cd "$ROOT"

LOCK="$ROOT/Config/ci-toolchain.json"
XCODEGEN="$ROOT/Tools/bin/xcodegen"
XCODEGEN_RESOURCE_BUNDLE="$ROOT/Tools/bin/XcodeGen_XcodeGenKit.bundle"
XCODEGEN_SETTING_PRESETS="$XCODEGEN_RESOURCE_BUNDLE/SettingPresets"
VERIFIER="$ROOT/Scripts/release/verify-candidate.sh"
CREATE_DMG="$ROOT/Scripts/create-dmg.sh"
INSPECT_DMG="$ROOT/Scripts/inspect-dmg.sh"

[[ -f "$LOCK" && ! -L "$LOCK" ]] || fail toolchain-lock-missing 24
[[ ! -L "$ROOT/Tools" && ! -L "$ROOT/Tools/bin" && ! -L "$XCODEGEN" && ! -L "$XCODEGEN_RESOURCE_BUNDLE" && ! -L "$XCODEGEN_SETTING_PRESETS" ]] || fail repository-xcodegen-unusable 24
[[ -f "$XCODEGEN" && -x "$XCODEGEN" ]] || fail repository-xcodegen-missing 24
for script in "$VERIFIER" "$CREATE_DMG" "$INSPECT_DMG"; do
  [[ -f "$script" && -x "$script" && ! -L "$script" ]] || fail required-script-unavailable
done

TEST_MODE=0
case "${UTTERINK_RELEASE_TEST_MODE:-}" in
  '') ;;
  1) TEST_MODE=1 ;;
  *) fail invalid-test-mode 24 ;;
esac

if ! OUTPUT_ABSOLUTE="$(/usr/bin/python3 -I - "$OUTPUT" "$ROOT" <<'PY'
from __future__ import annotations

import os
from pathlib import Path, PurePath
import stat
import sys

raw = sys.argv[1]
root = Path(sys.argv[2]).resolve(strict=True)
if not raw or "\x00" in raw or "\n" in raw or "\r" in raw:
    raise SystemExit(1)
raw_path = PurePath(raw)
if ".." in raw_path.parts:
    raise SystemExit(1)
candidate = Path(raw)
if not candidate.is_absolute():
    candidate = root / candidate
candidate = Path(os.path.abspath(candidate))
try:
    relative = candidate.relative_to(root)
except ValueError:
    raise SystemExit(1)
if len(relative.parts) < 2 or relative.parts[0] not in {"dist", ".release-work"}:
    raise SystemExit(1)
current = root
for component in relative.parts:
    current = current / component
    try:
        metadata = os.lstat(current)
    except FileNotFoundError:
        continue
    except OSError:
        raise SystemExit(1)
    if stat.S_ISLNK(metadata.st_mode):
        raise SystemExit(1)
    if current != candidate and not stat.S_ISDIR(metadata.st_mode):
        raise SystemExit(1)
if candidate.exists() or candidate.is_symlink():
    raise SystemExit(1)
print(candidate)
PY
)"; then
  fail unsafe-output 29
fi

[[ -d /private/tmp && ! -L /private/tmp ]] || fail unsafe-work-directory 29
PREFLIGHT_TMP="$(/usr/bin/mktemp -d /private/tmp/utterink-unsigned-preflight.XXXXXX)"
WORK=''
WORK_DEVICE=''
WORK_INODE=''
safe_remove_work() {
  local work_path="$1"
  local expected_device="$2"
  local expected_inode="$3"
  /usr/bin/python3 -I - \
    "$ROOT" "$work_path" "$expected_device" "$expected_inode" <<'PY' >/dev/null 2>&1
from __future__ import annotations

import os
from pathlib import Path
import re
import stat
import sys


class CleanupError(Exception):
    pass


root_path = Path(sys.argv[1])
work_path = Path(sys.argv[2])
try:
    expected_identity = (int(sys.argv[3]), int(sys.argv[4]))
except ValueError:
    raise SystemExit(1)
directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
root_fd = -1
release_fd = -1
work_fd = -1


def identity(metadata: os.stat_result) -> tuple[int, int]:
    return metadata.st_dev, metadata.st_ino


def safe_generated_directory(metadata: os.stat_result, root_device: int) -> bool:
    return (
        stat.S_ISDIR(metadata.st_mode)
        and metadata.st_dev == root_device
        and metadata.st_uid == os.geteuid()
    )


def safe_private_directory(metadata: os.stat_result, root_device: int) -> bool:
    return (
        safe_generated_directory(metadata, root_device)
        and metadata.st_mode & 0o022 == 0
    )


def remove_contents(descriptor: int, root_device: int) -> None:
    for name in os.listdir(descriptor):
        if not name or name in {".", ".."} or "/" in name:
            raise CleanupError
        before = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        if before.st_dev != root_device or before.st_uid != os.geteuid():
            raise CleanupError
        if stat.S_ISDIR(before.st_mode):
            child_fd = os.open(name, directory_flags, dir_fd=descriptor)
            try:
                opened = os.fstat(child_fd)
                if (
                    identity(opened) != identity(before)
                    or not safe_generated_directory(opened, root_device)
                ):
                    raise CleanupError
                remove_contents(child_fd, root_device)
                current = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
                if identity(current) != identity(opened) or not stat.S_ISDIR(current.st_mode):
                    raise CleanupError
                os.rmdir(name, dir_fd=descriptor)
            finally:
                os.close(child_fd)
        else:
            os.unlink(name, dir_fd=descriptor)


try:
    relative = work_path.relative_to(root_path)
except ValueError:
    raise SystemExit(1)
if (
    len(relative.parts) != 2
    or relative.parts[0] != ".release-work"
    or re.fullmatch(r"unsigned-package[.][A-Za-z0-9]{6,32}", relative.parts[1]) is None
):
    raise SystemExit(1)

try:
    root_fd = os.open(root_path, directory_flags)
    root_metadata = os.fstat(root_fd)
    if not safe_private_directory(root_metadata, root_metadata.st_dev):
        raise CleanupError
    release_fd = os.open(".release-work", directory_flags, dir_fd=root_fd)
    release_metadata = os.fstat(release_fd)
    if not safe_private_directory(release_metadata, root_metadata.st_dev):
        raise CleanupError
    work_fd = os.open(relative.parts[1], directory_flags, dir_fd=release_fd)
    work_metadata = os.fstat(work_fd)
    if (
        identity(work_metadata) != expected_identity
        or not safe_private_directory(work_metadata, root_metadata.st_dev)
    ):
        raise CleanupError
    remove_contents(work_fd, root_metadata.st_dev)
    current = os.stat(relative.parts[1], dir_fd=release_fd, follow_symlinks=False)
    if identity(current) != expected_identity or not stat.S_ISDIR(current.st_mode):
        raise CleanupError
    os.rmdir(relative.parts[1], dir_fd=release_fd)
except (OSError, CleanupError):
    raise SystemExit(1)
finally:
    if work_fd >= 0:
        os.close(work_fd)
    if release_fd >= 0:
        os.close(release_fd)
    if root_fd >= 0:
        os.close(root_fd)
PY
}
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [[ -n "$WORK" && -n "$WORK_DEVICE" && -n "$WORK_INODE" ]]; then
    safe_remove_work "$WORK" "$WORK_DEVICE" "$WORK_INODE" || :
  fi
  /bin/rm -rf -- "$PREFLIGHT_TMP"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Prove the exact clean candidate before parsing the worktree lock or executing
# the ignored repository-local XcodeGen binary. The verifier validates those
# files against COMMIT before it selects any repository-local build tool.
[[ ! -L "$ROOT/.release-work" ]] || fail unsafe-work-directory 29
if [[ ! -e "$ROOT/.release-work" ]]; then
  /bin/mkdir -m 0700 "$ROOT/.release-work" || fail unsafe-work-directory 29
fi
if ! /usr/bin/python3 -I - "$ROOT/.release-work" <<'PY' >/dev/null 2>&1
import os
from pathlib import Path
import stat
import sys

path = Path(sys.argv[1])
try:
    metadata = os.lstat(path)
except OSError:
    raise SystemExit(1)
if (
    not stat.S_ISDIR(metadata.st_mode)
    or stat.S_ISLNK(metadata.st_mode)
    or metadata.st_uid != os.geteuid()
    or metadata.st_mode & 0o022
):
    raise SystemExit(1)
PY
then
  fail unsafe-work-directory 29
fi
WORK="$(/usr/bin/mktemp -d "$ROOT/.release-work/unsigned-package.XXXXXX")"
if ! WORK_IDENTITY="$(/usr/bin/python3 -I - "$ROOT" "$WORK" <<'PY'
import os
from pathlib import Path
import stat
import sys

root, work = map(Path, sys.argv[1:3])
release_work = root / ".release-work"
if work.parent != release_work:
    raise SystemExit(1)
try:
    root_metadata = os.lstat(root)
    release_metadata = os.lstat(release_work)
    work_metadata = os.lstat(work)
except OSError:
    raise SystemExit(1)
for metadata in (release_metadata, work_metadata):
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or metadata.st_mode & 0o022
        or metadata.st_dev != root_metadata.st_dev
    ):
        raise SystemExit(1)
print(f"{work_metadata.st_dev}:{work_metadata.st_ino}")
PY
)"; then
  fail unsafe-work-directory 29
fi
IFS=: read -r WORK_DEVICE WORK_INODE <<< "$WORK_IDENTITY"
[[ "$WORK_DEVICE" =~ ^[0-9]+$ && "$WORK_INODE" =~ ^[0-9]+$ ]] ||
  fail unsafe-work-directory 29

VERIFY_ARGS=(--commit "$COMMIT" --output "$WORK/candidate")
if [[ -n "$EXPECTED_ORIGIN" ]]; then
  VERIFY_ARGS+=(--expected-origin "$EXPECTED_ORIGIN")
fi
"$VERIFIER" "${VERIFY_ARGS[@]}"

EXACT_SOURCE="$WORK/exact-source"
if ! /usr/bin/git clone \
  --quiet \
  --no-hardlinks \
  --no-tags \
  --no-checkout \
  -- "$ROOT" "$EXACT_SOURCE" \
  > "$WORK/git-clone-output" 2> "$WORK/git-clone-error"; then
  fail exact-source-unavailable 30
fi
if ! /usr/bin/git -C "$EXACT_SOURCE" checkout --quiet --detach --force "$COMMIT" \
  > "$WORK/git-checkout-output" 2> "$WORK/git-checkout-error"; then
  fail exact-source-unavailable 30
fi
EXACT_HEAD="$(/usr/bin/git -C "$EXACT_SOURCE" rev-parse --verify HEAD 2>/dev/null)" ||
  fail exact-source-unavailable 30
EXACT_STATUS="$(/usr/bin/git -C "$EXACT_SOURCE" status --porcelain=v1 --untracked-files=all 2>/dev/null)" ||
  fail exact-source-unavailable 30
[[ "$EXACT_HEAD" == "$COMMIT" && -z "$EXACT_STATUS" ]] || fail exact-source-unavailable 30
for exact_input in \
  Config/ci-toolchain.json \
  Scripts/create-dmg.sh \
  Scripts/inspect-dmg.sh; do
  [[ -f "$EXACT_SOURCE/$exact_input" && ! -L "$EXACT_SOURCE/$exact_input" ]] ||
    fail exact-source-unavailable 30
done
[[ -x "$EXACT_SOURCE/Scripts/create-dmg.sh" && -x "$EXACT_SOURCE/Scripts/inspect-dmg.sh" ]] ||
  fail exact-source-unavailable 30
LOCK="$EXACT_SOURCE/Config/ci-toolchain.json"

if ! /usr/bin/python3 -I - "$LOCK" "$PREFLIGHT_TMP" <<'PY' >/dev/null 2>&1
from __future__ import annotations

import json
from pathlib import Path
import re
import sys


def abort() -> None:
    raise SystemExit(1)


def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            abort()
        result[key] = value
    return result


lock_path = Path(sys.argv[1])
output = Path(sys.argv[2])
try:
    if lock_path.stat().st_size > 128 * 1024:
        abort()
    lock = json.loads(lock_path.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
except (OSError, UnicodeError, json.JSONDecodeError):
    abort()
if type(lock) is not dict or set(lock) != {"schemaVersion", "runnerImage", "xcode", "sdk", "swift", "xcodegen", "sources"}:
    abort()
if type(lock["schemaVersion"]) is not int or lock["schemaVersion"] != 1:
    abort()
xcode = lock["xcode"]
xcodegen = lock["xcodegen"]
if type(xcode) is not dict or set(xcode) != {"version", "build", "developerDir"}:
    abort()
if type(xcodegen) is not dict or set(xcodegen) != {"version", "sourceCommit", "archiveURL", "archiveSHA256", "binarySHA256", "settingPresetsSHA256"}:
    abort()
developer_dir = xcode.get("developerDir")
version = xcodegen.get("version")
binary_hash = xcodegen.get("binarySHA256")
presets_hash = xcodegen.get("settingPresetsSHA256")
if type(developer_dir) is not str or re.fullmatch(r"/Applications/Xcode_[A-Za-z0-9.]+[.]app/Contents/Developer", developer_dir) is None:
    abort()
if type(version) is not str or re.fullmatch(r"[0-9]+(?:[.][0-9]+)+", version) is None:
    abort()
if type(binary_hash) is not str or re.fullmatch(r"[0-9a-f]{64}", binary_hash) is None:
    abort()
if type(presets_hash) is not str or re.fullmatch(r"[0-9a-f]{64}", presets_hash) is None:
    abort()
(output / "developer-dir").write_text(developer_dir, encoding="utf-8")
(output / "xcodegen-version").write_text(version, encoding="utf-8")
(output / "xcodegen-sha").write_text(binary_hash, encoding="utf-8")
(output / "xcodegen-presets-sha").write_text(presets_hash, encoding="utf-8")
PY
then
  fail toolchain-lock-invalid 24
fi

DEVELOPER_DIR_LOCKED="$(/bin/cat "$PREFLIGHT_TMP/developer-dir")"
EXPECTED_XCODEGEN_VERSION="$(/bin/cat "$PREFLIGHT_TMP/xcodegen-version")"
EXPECTED_XCODEGEN_SHA="$(/bin/cat "$PREFLIGHT_TMP/xcodegen-sha")"
EXPECTED_XCODEGEN_PRESETS_SHA="$(/bin/cat "$PREFLIGHT_TMP/xcodegen-presets-sha")"

verify_xcodegen_setting_presets() {
  /usr/bin/python3 -I - "$1" "$2" <<'PY' >/dev/null 2>&1
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
  local expected_hash="$2"
  if ! /usr/bin/python3 -I - "$bundle" <<'PY' >/dev/null 2>&1
import os
import stat
import sys

bundle = sys.argv[1]
flags = os.O_RDONLY | os.O_DIRECTORY
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
try:
    descriptor = os.open(bundle, flags)
    try:
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISDIR(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
            or metadata.st_mode & 0o022
        ):
            raise ValueError
        with os.scandir(descriptor) as iterator:
            entries = list(iterator)
        if len(entries) != 1:
            raise ValueError
        entry = entries[0]
        child = entry.stat(follow_symlinks=False)
        if entry.name != "SettingPresets" or not stat.S_ISDIR(child.st_mode):
            raise ValueError
    finally:
        os.close(descriptor)
except (OSError, UnicodeError, ValueError):
    raise SystemExit(1)
PY
  then
    return 1
  fi
  verify_xcodegen_setting_presets "$bundle/SettingPresets" "$expected_hash"
}

verify_xcodegen_resource_bundle "$XCODEGEN_RESOURCE_BUNDLE" "$EXPECTED_XCODEGEN_PRESETS_SHA" ||
  fail repository-xcodegen-mismatch 24
VERIFIED_XCODEGEN_RESOURCE_BUNDLE="$PREFLIGHT_TMP/XcodeGen_XcodeGenKit.bundle"
/usr/bin/env COPYFILE_DISABLE=1 /bin/cp -R "$XCODEGEN_RESOURCE_BUNDLE" "$VERIFIED_XCODEGEN_RESOURCE_BUNDLE" ||
  fail repository-xcodegen-unusable 24
verify_xcodegen_resource_bundle "$VERIFIED_XCODEGEN_RESOURCE_BUNDLE" "$EXPECTED_XCODEGEN_PRESETS_SHA" ||
  fail repository-xcodegen-mismatch 24
VERIFIED_XCODEGEN="$PREFLIGHT_TMP/xcodegen"
/bin/cp "$XCODEGEN" "$VERIFIED_XCODEGEN" || fail repository-xcodegen-unusable 24
/bin/chmod 0700 "$VERIFIED_XCODEGEN" || fail repository-xcodegen-unusable 24
ACTUAL_XCODEGEN_SHA="$(/usr/bin/shasum -a 256 "$VERIFIED_XCODEGEN" | /usr/bin/awk 'NR == 1 { print $1 }')" || fail repository-xcodegen-unusable 24
[[ "$ACTUAL_XCODEGEN_SHA" == "$EXPECTED_XCODEGEN_SHA" ]] || fail repository-xcodegen-mismatch 24
if [[ "$TEST_MODE" -eq 1 ]]; then
  [[ "${UTTERINK_FIXTURE_LOG:-}" == /* ]] || fail invalid-test-tool-root 24
  ACTUAL_XCODEGEN_VERSION="$(/usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    LC_ALL=C \
    HOME="$PREFLIGHT_TMP" \
    UTTERINK_FIXTURE_LOG="$UTTERINK_FIXTURE_LOG" \
    "$VERIFIED_XCODEGEN" --version 2>/dev/null)" || fail repository-xcodegen-unusable 24
else
  ACTUAL_XCODEGEN_VERSION="$(/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C HOME="$PREFLIGHT_TMP" "$VERIFIED_XCODEGEN" --version 2>/dev/null)" || fail repository-xcodegen-unusable 24
fi
[[ "$ACTUAL_XCODEGEN_VERSION" == "Version: $EXPECTED_XCODEGEN_VERSION" ]] || fail repository-xcodegen-mismatch 24

if [[ "$TEST_MODE" -eq 1 ]]; then
  TOOL_ROOT="${UTTERINK_RELEASE_TEST_TOOL_ROOT:-}"
  case "$ROOT" in
    /private/tmp/*) ;;
    *) fail test-mode-not-allowed 24 ;;
  esac
  [[ "$TOOL_ROOT" == "$ROOT/FixtureTools" && -d "$TOOL_ROOT" && ! -L "$TOOL_ROOT" ]] || fail invalid-test-tool-root 24
  [[ -f "$TOOL_ROOT/.utterink-package-test-fixture" && ! -L "$TOOL_ROOT/.utterink-package-test-fixture" ]] || fail invalid-test-tool-root 24
  [[ "$(/bin/cat "$TOOL_ROOT/.utterink-package-test-fixture")" == utterink-offline-package-fixture-v1 ]] || fail invalid-test-tool-root 24
  PUBLISH_RACE=0
  case "${UTTERINK_PACKAGE_TEST_PUBLISH_RACE:-}" in
    '') ;;
    1) PUBLISH_RACE=1 ;;
    *) fail invalid-test-publish-race 24 ;;
  esac
  XCODEBUILD="$TOOL_ROOT/xcodebuild"
  FILE_TOOL="$TOOL_ROOT/file"
  LIPO="$TOOL_ROOT/lipo"
  OTOOL="$TOOL_ROOT/otool"
else
  PUBLISH_RACE=0
  XCODEBUILD=/usr/bin/xcodebuild
  FILE_TOOL=/usr/bin/file
  LIPO=/usr/bin/lipo
  OTOOL=/usr/bin/otool
fi
unset UTTERINK_PACKAGE_TEST_PUBLISH_RACE
readonly PUBLISH_RACE
for tool in "$XCODEBUILD" "$FILE_TOOL" "$LIPO" "$OTOOL"; do
  [[ -f "$tool" && -x "$tool" && ! -L "$tool" ]] || fail toolchain-unavailable 24
done

EXACT_RELEASE_WORK="$EXACT_SOURCE/.release-work"
/bin/mkdir -m 0700 "$EXACT_RELEASE_WORK" || fail exact-source-unavailable 30
for isolated_directory in \
  home \
  tmp \
  xdg-config \
  xdg-cache \
  swift-module-cache \
  clang-module-cache; do
  /bin/mkdir -m 0700 "$EXACT_RELEASE_WORK/$isolated_directory" || fail exact-source-unavailable 30
done
ARCHIVE_PATH="$EXACT_RELEASE_WORK/UtterInk.xcarchive"
if ! (
  cd "$EXACT_SOURCE"
  export HOME="$EXACT_RELEASE_WORK/home"
  export CFFIXED_USER_HOME="$EXACT_RELEASE_WORK/home"
  export TMPDIR="$EXACT_RELEASE_WORK/tmp"
  export XDG_CONFIG_HOME="$EXACT_RELEASE_WORK/xdg-config"
  export XDG_CACHE_HOME="$EXACT_RELEASE_WORK/xdg-cache"
  export SWIFT_MODULECACHE_PATH="$EXACT_RELEASE_WORK/swift-module-cache"
  export CLANG_MODULE_CACHE_PATH="$EXACT_RELEASE_WORK/clang-module-cache"
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
    CODE_SIGN_IDENTITY=
) > "$WORK/xcodebuild-archive.log" 2>&1; then
  fail archive-failed 30
fi

APP="$ARCHIVE_PATH/Products/Applications/UtterInk.app"
[[ -d "$APP" && ! -L "$APP" ]] || fail archived-app-missing 30
if ! /usr/bin/python3 -I - "$APP/Contents/MacOS/UtterInk" <<'PY' >/dev/null 2>&1
import os
from pathlib import Path
import stat
import sys

executable = Path(sys.argv[1])
try:
    metadata = os.lstat(executable)
except OSError:
    raise SystemExit(1)
if (
    not stat.S_ISREG(metadata.st_mode)
    or stat.S_ISLNK(metadata.st_mode)
    or metadata.st_uid != os.geteuid()
    or stat.S_IMODE(metadata.st_mode) != 0o755
):
    raise SystemExit(1)
PY
then
  fail archived-app-executable-invalid 31
fi
if /usr/bin/find "$APP" \( -name _CodeSignature -o -name CodeResources \) -print -quit | /usr/bin/grep -q .; then
  fail archived-app-unexpected-signature 31
fi

MACHO_COUNT=0
while IFS= read -r -d '' candidate; do
  FILE_DESCRIPTION="$($FILE_TOOL -b "$candidate" 2>/dev/null)" || fail archived-app-inspection-failed 31
  case "$FILE_DESCRIPTION" in
    *Mach-O*) ;;
    *) continue ;;
  esac
  MACHO_COUNT=$((MACHO_COUNT + 1))
  ARCHITECTURES="$($LIPO -archs "$candidate" 2>/dev/null)" || fail archived-app-inspection-failed 31
  [[ "$ARCHITECTURES" == arm64 ]] || fail archived-app-architecture-mismatch 31
  if ! "$OTOOL" -l "$candidate" > "$WORK/otool-$MACHO_COUNT.log" 2>&1; then
    fail archived-app-inspection-failed 31
  fi
  if /usr/bin/grep -Eq '^[[:space:]]*cmd[[:space:]]+LC_CODE_SIGNATURE[[:space:]]*$' "$WORK/otool-$MACHO_COUNT.log"; then
    fail archived-app-unexpected-signature 31
  fi
done < <(/usr/bin/find "$APP" -type f -print0)
[[ "$MACHO_COUNT" -gt 0 ]] || fail archived-app-mach-o-missing 31

if ! DMG_FILENAME="$(/usr/bin/python3 -I - "$WORK/candidate/candidate.json" <<'PY'
from __future__ import annotations

import json
from pathlib import Path
import re
import sys

try:
    candidate = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    release = candidate["release"]
    product = candidate["product"]
    version = release["marketingVersion"]
    architecture = release["architecture"]
except (OSError, UnicodeError, json.JSONDecodeError, KeyError, TypeError):
    raise SystemExit(1)
if product != "UtterInk" or architecture != "arm64" or type(version) is not str:
    raise SystemExit(1)
if re.fullmatch(r"(?:0|[1-9][0-9]*)[.](?:0|[1-9][0-9]*)[.](?:0|[1-9][0-9]*)", version) is None:
    raise SystemExit(1)
print(f"UtterInk-{version}-arm64-UNSIGNED-DO-NOT-DISTRIBUTE.dmg")
PY
)"; then
  fail candidate-evidence-invalid 32
fi

EXACT_DMG="$EXACT_SOURCE/dist/unsigned-smoke/$DMG_FILENAME"
if [[ "$TEST_MODE" -eq 1 ]]; then
  UTTERINK_RELEASE_TEST_TOOL_ROOT="$EXACT_SOURCE/FixtureTools" \
    "$EXACT_SOURCE/Scripts/create-dmg.sh" \
      --app "$APP" \
      --output "$EXACT_DMG" \
      --mode unsigned \
      > "$WORK/create-dmg-output"
else
  "$EXACT_SOURCE/Scripts/create-dmg.sh" \
    --app "$APP" \
    --output "$EXACT_DMG" \
    --mode unsigned \
    > "$WORK/create-dmg-output"
fi
[[ -f "$EXACT_DMG" && ! -L "$EXACT_DMG" ]] || fail dmg-creation-failed 33
(
  cd "$EXACT_SOURCE"
  "$EXACT_SOURCE/Scripts/inspect-dmg.sh" \
    --dmg "$EXACT_DMG" \
    --mode unsigned
) > "$WORK/inspection.json"
[[ -s "$WORK/inspection.json" && ! -L "$WORK/inspection.json" ]] || fail dmg-inspection-failed 33
if ! INSPECTED_DMG_SHA="$(/usr/bin/python3 -I - "$WORK/inspection.json" <<'PY'
from __future__ import annotations

import json
from pathlib import Path
import re
import sys


def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, item in pairs:
        if key in value:
            raise SystemExit(1)
        value[key] = item
    return value


path = Path(sys.argv[1])
try:
    if path.stat().st_size > 1024 * 1024:
        raise SystemExit(1)
    evidence = json.loads(
        path.read_text(encoding="utf-8"),
        object_pairs_hook=unique_object,
    )
except (OSError, UnicodeError, json.JSONDecodeError):
    raise SystemExit(1)
if type(evidence) is not dict:
    raise SystemExit(1)
digest = evidence.get("dmgSHA256")
if type(digest) is not str or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
    raise SystemExit(1)
print(digest)
PY
)"; then
  fail dmg-inspection-failed 33
fi
INSPECTION_EVIDENCE="$(/bin/cat "$WORK/inspection.json")" || fail dmg-inspection-failed 33
[[ -n "$INSPECTION_EVIDENCE" ]] || fail dmg-inspection-failed 33

# The destination did not exist during candidate verification or isolated
# build. Create every component and hard-link the inspected bytes in one
# descriptor-relative operation rooted at the repository. The output directory
# itself is no-clobber, and the complete directory chain is identity-checked
# before and after link(2).
if ! /usr/bin/python3 -I - \
  "$ROOT" "$EXACT_DMG" "$OUTPUT_ABSOLUTE" "$DMG_FILENAME" "$PUBLISH_RACE" "$INSPECTED_DMG_SHA" <<'PY' >/dev/null 2>&1
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import stat
import sys
import time


class PublishError(Exception):
    pass


root_path = Path(sys.argv[1])
source_path = Path(sys.argv[2])
output_directory_path = Path(sys.argv[3])
target_name = sys.argv[4]
race_hook = sys.argv[5] == "1"
expected_hash = sys.argv[6]
directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
file_flags = os.O_RDONLY | os.O_NOFOLLOW
root_fd = -1
root_device = -1
source_parent_fd = -1
source_fd = -1
target_fd = -1
directory_fds: list[int] = []
records: list[tuple[int, str, int, tuple[int, int], bool]] = []
published = False
source_identity: tuple[int, int] | None = None


def identity(metadata: os.stat_result) -> tuple[int, int]:
    return metadata.st_dev, metadata.st_ino


def file_fingerprint(metadata: os.stat_result) -> tuple[int, int, int, int, int]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def stable_hash(descriptor: int) -> tuple[str, os.stat_result]:
    before = os.fstat(descriptor)
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_dev != root_device
        or before.st_size <= 0
    ):
        raise PublishError
    digest = hashlib.sha256()
    offset = 0
    while True:
        chunk = os.pread(descriptor, 1024 * 1024, offset)
        if not chunk:
            break
        digest.update(chunk)
        offset += len(chunk)
    after = os.fstat(descriptor)
    if file_fingerprint(after) != file_fingerprint(before):
        raise PublishError
    return digest.hexdigest(), after


def safe_directory(metadata: os.stat_result) -> bool:
    return (
        stat.S_ISDIR(metadata.st_mode)
        and metadata.st_dev == root_device
        and metadata.st_uid == os.geteuid()
        and metadata.st_mode & 0o022 == 0
    )


def open_directory(parent_fd: int, name: str) -> int:
    if not name or name in {".", ".."} or "/" in name:
        raise PublishError
    descriptor = os.open(name, directory_flags, dir_fd=parent_fd)
    if not safe_directory(os.fstat(descriptor)):
        os.close(descriptor)
        raise PublishError
    return descriptor


def open_existing_parent(parts: tuple[str, ...]) -> int:
    descriptor = os.dup(root_fd)
    try:
        for component in parts:
            next_descriptor = open_directory(descriptor, component)
            os.close(descriptor)
            descriptor = next_descriptor
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def chain_is_current() -> bool:
    descriptor = os.dup(root_fd)
    try:
        for _, component, _, expected_identity, _ in records:
            next_descriptor = open_directory(descriptor, component)
            os.close(descriptor)
            descriptor = next_descriptor
            if identity(os.fstat(descriptor)) != expected_identity:
                return False
        return True
    except OSError:
        return False
    finally:
        os.close(descriptor)


def remove_published_target() -> None:
    if not published or not records or source_identity is None:
        return
    parent_fd = records[-1][2]
    try:
        metadata = os.stat(target_name, dir_fd=parent_fd, follow_symlinks=False)
        if identity(metadata) == source_identity:
            os.unlink(target_name, dir_fd=parent_fd)
    except OSError:
        pass


def rollback_directories() -> None:
    for parent_fd, component, _, expected_identity, created in reversed(records):
        if not created:
            continue
        try:
            current = os.stat(component, dir_fd=parent_fd, follow_symlinks=False)
            if identity(current) == expected_identity and stat.S_ISDIR(current.st_mode):
                os.rmdir(component, dir_fd=parent_fd)
        except OSError:
            pass


def exercise_race_hook() -> None:
    if not race_hook:
        return
    tool_fd = open_directory(root_fd, "FixtureTools")
    ready_name = ".utterink-package-publish-race-ready"
    go_name = ".utterink-package-publish-race-go"
    ready_identity: tuple[int, int] | None = None
    try:
        marker_fd = os.open(
            ".utterink-package-test-fixture", file_flags, dir_fd=tool_fd
        )
        try:
            marker_metadata = os.fstat(marker_fd)
            marker = os.read(marker_fd, 128)
            if (
                not stat.S_ISREG(marker_metadata.st_mode)
                or marker_metadata.st_uid != os.geteuid()
                or marker != b"utterink-offline-package-fixture-v1\n"
            ):
                raise PublishError
        finally:
            os.close(marker_fd)
        ready_fd = os.open(
            ready_name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
            dir_fd=tool_fd,
        )
        try:
            os.write(ready_fd, b"ready\n")
            ready_identity = identity(os.fstat(ready_fd))
        finally:
            os.close(ready_fd)
        deadline = time.monotonic() + 15.0
        while True:
            try:
                go_metadata = os.stat(go_name, dir_fd=tool_fd, follow_symlinks=False)
            except FileNotFoundError:
                if time.monotonic() >= deadline:
                    raise PublishError
                time.sleep(0.01)
                continue
            if not stat.S_ISREG(go_metadata.st_mode) or go_metadata.st_uid != os.geteuid():
                raise PublishError
            break
    finally:
        for name, expected in ((ready_name, ready_identity), (go_name, None)):
            try:
                metadata = os.stat(name, dir_fd=tool_fd, follow_symlinks=False)
                if expected is None or identity(metadata) == expected:
                    os.unlink(name, dir_fd=tool_fd)
            except OSError:
                pass
        os.close(tool_fd)


try:
    root_fd = os.open(root_path, directory_flags)
    root_metadata = os.fstat(root_fd)
    root_device = root_metadata.st_dev
    if not safe_directory(root_metadata):
        raise PublishError
    try:
        source_relative = source_path.relative_to(root_path)
        output_relative = output_directory_path.relative_to(root_path)
    except ValueError as error:
        raise PublishError from error
    source_parts = source_relative.parts
    output_parts = output_relative.parts
    if (
        len(source_parts) < 2
        or len(output_parts) < 2
        or output_parts[0] not in {"dist", ".release-work"}
        or "/" in target_name
        or target_name in {"", ".", ".."}
        or any(part in {"", ".", ".."} for part in source_parts + output_parts)
        or len(expected_hash) != 64
        or any(character not in "0123456789abcdef" for character in expected_hash)
    ):
        raise PublishError

    source_parent_fd = open_existing_parent(source_parts[:-1])
    source_fd = os.open(source_parts[-1], file_flags, dir_fd=source_parent_fd)
    source_digest, source_metadata = stable_hash(source_fd)
    if source_digest != expected_hash:
        raise PublishError
    source_identity = identity(source_metadata)

    directory_fds.append(root_fd)
    for index, component in enumerate(output_parts):
        parent_fd = directory_fds[-1]
        created = False
        try:
            os.mkdir(component, 0o755, dir_fd=parent_fd)
            created = True
        except FileExistsError:
            if index == len(output_parts) - 1:
                raise PublishError
        child_fd = open_directory(parent_fd, component)
        child_identity = identity(os.fstat(child_fd))
        directory_fds.append(child_fd)
        records.append((parent_fd, component, child_fd, child_identity, created))

    exercise_race_hook()
    if not chain_is_current():
        raise PublishError
    os.link(
        source_parts[-1],
        target_name,
        src_dir_fd=source_parent_fd,
        dst_dir_fd=records[-1][2],
        follow_symlinks=False,
    )
    published = True
    target_fd = os.open(target_name, file_flags, dir_fd=records[-1][2])
    target_digest, target_metadata = stable_hash(target_fd)
    if (
        target_digest != expected_hash
        or identity(target_metadata) != source_identity
        or identity(os.fstat(source_fd)) != source_identity
        or file_fingerprint(
            os.stat(target_name, dir_fd=records[-1][2], follow_symlinks=False)
        ) != file_fingerprint(target_metadata)
        or file_fingerprint(os.fstat(target_fd)) != file_fingerprint(target_metadata)
        or not chain_is_current()
    ):
        raise PublishError
except (OSError, PublishError):
    remove_published_target()
    rollback_directories()
    raise SystemExit(1)
finally:
    if target_fd >= 0:
        os.close(target_fd)
    if source_fd >= 0:
        os.close(source_fd)
    if source_parent_fd >= 0:
        os.close(source_parent_fd)
    for descriptor in reversed(directory_fds[1:]):
        os.close(descriptor)
    if root_fd >= 0:
        os.close(root_fd)
PY
then
  fail output-publish-failed 33
fi

safe_remove_work "$WORK" "$WORK_DEVICE" "$WORK_INODE" || fail work-cleanup-failed 34
WORK=''
WORK_DEVICE=''
WORK_INODE=''
printf '%s\n' "$INSPECTION_EVIDENCE"

exit 0
