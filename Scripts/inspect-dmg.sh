#!/usr/bin/env -S -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u BASH_XTRACEFD -u PS4 -u POSIXLY_CORRECT -u BASH_COMPAT -u UTTERINK_DMG_INSPECT_ENV_CLEAN /bin/bash -p

set +x +v
if [[ "$-" != *p* ]]; then
  printf 'DMG inspection error: unsafe-launch-environment\n' >&2
  exit 2
fi
if [[ "${UTTERINK_DMG_INSPECT_ENV_CLEAN:-}" != 1 ]]; then
  clean_environment=(
    PATH=/usr/bin:/bin:/usr/sbin:/sbin
    LC_ALL=C
    UTTERINK_DMG_INSPECT_ENV_CLEAN=1
  )
  if [[ -n "${UTTERINK_DMG_INSPECT_TEST_MODE+x}" ]]; then
    clean_environment+=("UTTERINK_DMG_INSPECT_TEST_MODE=${UTTERINK_DMG_INSPECT_TEST_MODE}")
  fi
  if [[ -n "${UTTERINK_DMG_INSPECT_TEST_TOOL_ROOT+x}" ]]; then
    clean_environment+=("UTTERINK_DMG_INSPECT_TEST_TOOL_ROOT=${UTTERINK_DMG_INSPECT_TEST_TOOL_ROOT}")
  fi
  exec /usr/bin/env -i "${clean_environment[@]}" /bin/bash -p "$0" "$@"
  printf 'DMG inspection error: unsafe-launch-environment\n' >&2
  exit 2
fi
if [[ "$-" != hpB || "${PATH-}" != /usr/bin:/bin:/usr/sbin:/sbin || "${LC_ALL-}" != C ]]; then
  printf 'DMG inspection error: unsafe-launch-environment\n' >&2
  exit 2
fi
while IFS= read -r -d '' environment_entry; do
  environment_name="${environment_entry%%=*}"
  case "$environment_name" in
    PATH|LC_ALL|UTTERINK_DMG_INSPECT_ENV_CLEAN|UTTERINK_DMG_INSPECT_TEST_MODE|UTTERINK_DMG_INSPECT_TEST_TOOL_ROOT|PWD|SHLVL|_) ;;
    *)
      printf 'DMG inspection error: unsafe-launch-environment\n' >&2
      exit 2
      ;;
  esac
done < <(/usr/bin/env -0)
unset UTTERINK_DMG_INSPECT_ENV_CLEAN

set -euo pipefail

export LC_ALL=C
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PYTHONDONTWRITEBYTECODE=1
unset BASH_ENV ENV CDPATH GLOBIGNORE PYTHONHOME PYTHONPATH PERL5OPT PERL5LIB PERLLIB PERL5DB
umask 077

PYTHON=/usr/bin/python3

fail() {
  local category="$1"
  local status="${2:-1}"
  printf 'DMG inspection error: %s\n' "$category" >&2
  exit "$status"
}

DMG=''
MODE=''
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dmg)
      [[ -z "$DMG" && "$#" -ge 2 && -n "$2" && "$2" != --* ]] || fail invalid-arguments 2
      DMG="$2"
      shift 2
      ;;
    --mode)
      [[ -z "$MODE" && "$#" -ge 2 && -n "$2" && "$2" != --* ]] || fail invalid-arguments 2
      MODE="$2"
      shift 2
      ;;
    *) fail invalid-arguments 2 ;;
  esac
done
[[ -n "$DMG" && "$MODE" =~ ^(unsigned|signed|final)$ ]] || fail invalid-arguments 2

readonly SCRIPT_PATH="${BASH_SOURCE[0]}"
[[ -f "$SCRIPT_PATH" && ! -L "$SCRIPT_PATH" ]] || fail unsafe-repository
SCRIPT_DIRECTORY="$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "$SCRIPT_PATH")" && /bin/pwd -P)" ||
  fail unsafe-repository
readonly SCRIPT_DIRECTORY
SCRIPT_ROOT="$(CDPATH= cd -P -- "$SCRIPT_DIRECTORY/.." && /bin/pwd -P)" || fail unsafe-repository
readonly SCRIPT_ROOT
[[ -d "$SCRIPT_ROOT/Config" && ! -L "$SCRIPT_ROOT/Config" ]] || fail unsafe-repository
GIT_ROOT="$(/usr/bin/git -C "$SCRIPT_ROOT" rev-parse --show-toplevel 2>/dev/null)" || fail unsafe-repository
GIT_ROOT="$(CDPATH= cd -P -- "$GIT_ROOT" && /bin/pwd -P)" || fail unsafe-repository
[[ "$GIT_ROOT" == "$SCRIPT_ROOT" ]] || fail unsafe-repository
for policy_script in Scripts/release/read-metadata.py Scripts/release/verify-info-policy.py; do
  [[ -f "$SCRIPT_ROOT/$policy_script" && ! -L "$SCRIPT_ROOT/$policy_script" ]] || fail unsafe-repository
done
cd "$SCRIPT_ROOT"

TEST_MODE=0
if [[ "${UTTERINK_DMG_INSPECT_TEST_MODE:-}" == 1 ]]; then
  TEST_MODE=1
elif [[ -n "${UTTERINK_DMG_INSPECT_TEST_MODE:-}" ]]; then
  fail invalid-test-mode 2
fi

if [[ "$TEST_MODE" -eq 1 ]]; then
  if ! "$PYTHON" -I - "$SCRIPT_ROOT" <<'PY' >/dev/null 2>&1
from __future__ import annotations

import os
from pathlib import Path
import stat
import sys


root = Path(sys.argv[1])
try:
    if (
        root != Path(os.path.abspath(root))
        or not root.as_posix().startswith("/private/tmp/")
        or root.is_symlink()
        or root.resolve(strict=True) != root
    ):
        raise ValueError
    metadata = os.lstat(root)
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_mode & 0o022:
        raise ValueError
    git_directory = root / ".git"
    git_metadata = os.lstat(git_directory)
    if (
        not stat.S_ISDIR(git_metadata.st_mode)
        or stat.S_ISLNK(git_metadata.st_mode)
        or git_metadata.st_mode & 0o022
        or git_directory.resolve(strict=True) != git_directory
    ):
        raise ValueError
    marker = root / ".utterink-dmg-inspect-test-repository"
    marker_metadata = os.lstat(marker)
    if (
        not stat.S_ISREG(marker_metadata.st_mode)
        or stat.S_ISLNK(marker_metadata.st_mode)
        or marker_metadata.st_mode & 0o022
        or marker.read_bytes() != b"utterink-dmg-inspect-test-repository-v1\n"
    ):
        raise ValueError
except (OSError, ValueError):
    raise SystemExit(1)
PY
  then
    fail invalid-test-repository 2
  fi
  TOOL_ROOT="${UTTERINK_DMG_INSPECT_TEST_TOOL_ROOT:-}"
  [[ "$TOOL_ROOT" == "$SCRIPT_ROOT/FixtureTools" ]] || fail invalid-test-tool-root 2
  if ! "$PYTHON" -I - "$TOOL_ROOT" <<'PY' >/dev/null 2>&1
from __future__ import annotations

import os
from pathlib import Path
import stat
import sys


root = Path(sys.argv[1])
try:
    if root != Path(os.path.abspath(root)) or root.is_symlink() or root.resolve(strict=True) != root:
        raise ValueError
    metadata = os.lstat(root)
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_mode & 0o022:
        raise ValueError
    marker = root / ".utterink-dmg-inspect-test-tools"
    marker_metadata = os.lstat(marker)
    if (
        not stat.S_ISREG(marker_metadata.st_mode)
        or stat.S_ISLNK(marker_metadata.st_mode)
        or marker_metadata.st_mode & 0o022
        or marker.read_bytes() != b"utterink-dmg-inspect-test-tools-v1\n"
    ):
        raise ValueError
    for name in ("hdiutil", "codesign", "file", "lipo"):
        tool = root / name
        tool_metadata = os.lstat(tool)
        if (
            not stat.S_ISREG(tool_metadata.st_mode)
            or stat.S_ISLNK(tool_metadata.st_mode)
            or not tool_metadata.st_mode & stat.S_IXUSR
            or tool_metadata.st_mode & 0o022
        ):
            raise ValueError
except (OSError, ValueError):
    raise SystemExit(1)
PY
  then
    fail invalid-test-tool-root 2
  fi
  HDIUTIL="$TOOL_ROOT/hdiutil"
  CODESIGN="$TOOL_ROOT/codesign"
  FILE_TOOL="$TOOL_ROOT/file"
  LIPO="$TOOL_ROOT/lipo"
else
  HDIUTIL=/usr/bin/hdiutil
  CODESIGN=/usr/bin/codesign
  FILE_TOOL=/usr/bin/file
  LIPO=/usr/bin/lipo
fi
for tool in "$HDIUTIL" "$CODESIGN" "$FILE_TOOL" "$LIPO"; do
  [[ -f "$tool" && -x "$tool" && ! -L "$tool" ]] || fail tool-unavailable
done

if ! "$PYTHON" -I - Config/dmg-allowed-content.txt <<'PY' >/dev/null 2>&1
from __future__ import annotations

import os
from pathlib import Path
import stat
import sys


path = Path(sys.argv[1])
try:
    metadata = os.lstat(path)
    if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise ValueError
    if path.read_bytes() != b"Applications -> /Applications\nUtterInk.app directory\n":
        raise ValueError
except (OSError, ValueError):
    raise SystemExit(1)
PY
then
  fail invalid-manifest-policy
fi

if ! DMG_ABSOLUTE="$($PYTHON -I - "$DMG" "$TEST_MODE" <<'PY' 2>/dev/null
from __future__ import annotations

import os
from pathlib import Path
import stat
import sys


argument = sys.argv[1]
test_mode = sys.argv[2] == "1"
try:
    if not argument or "\x00" in argument or any(ord(character) < 32 or ord(character) == 127 for character in argument):
        raise ValueError
    path = Path(os.path.abspath(argument))
    if path.suffix != ".dmg":
        raise ValueError
    metadata = os.lstat(path)
    resolved = path.resolve(strict=True)
    if (
        not stat.S_ISREG(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or resolved != path
        or metadata.st_size <= 0
        or metadata.st_size > 16 * 1024 * 1024 * 1024
    ):
        raise ValueError
    if test_mode:
        if not path.as_posix().startswith("/private/tmp/"):
            raise ValueError
        marker = path.parent / ".utterink-dmg-inspect-fixture"
        marker_metadata = os.lstat(marker)
        if (
            not stat.S_ISREG(marker_metadata.st_mode)
            or stat.S_ISLNK(marker_metadata.st_mode)
            or marker.read_bytes() != b"utterink-dmg-inspect-fixture-v1\n"
        ):
            raise ValueError
    print(path)
except (OSError, UnicodeError, ValueError):
    raise SystemExit(1)
PY
)"; then
  fail unsafe-dmg
fi
[[ -n "$DMG_ABSOLUTE" ]] || fail unsafe-dmg

WORK="$(/usr/bin/mktemp -d /private/tmp/utterink-dmg-inspection.XXXXXX)" || fail workspace-unavailable
MOUNT_ROOT="$WORK/mount-root"
PINNED_ROOT="$WORK/pinned"
PINNED_DMG="$PINNED_ROOT/${DMG_ABSOLUTE##*/}"
MOUNT_POINT=''
ATTACH_DEVICE=''
ATTACHED=0

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [[ "$ATTACHED" -eq 1 ]]; then
    if [[ "$ATTACH_DEVICE" =~ ^/dev/disk[0-9]+$ ]]; then
      "$HDIUTIL" detach "$ATTACH_DEVICE" -force >/dev/null 2>&1 || true
    elif [[ -d "$MOUNT_ROOT" && ! -L "$MOUNT_ROOT" ]]; then
      while IFS= read -r -d '' fallback_mount; do
        "$HDIUTIL" detach "$fallback_mount" -force >/dev/null 2>&1 || true
      done < <(/usr/bin/find "$MOUNT_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
    fi
  fi
  /bin/rm -rf "$WORK"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
/bin/chmod 0700 "$WORK" || fail workspace-unavailable
/bin/mkdir -m 0700 "$MOUNT_ROOT" "$PINNED_ROOT" || fail workspace-unavailable

# Freeze the input through an O_NOFOLLOW descriptor into a private, read-only
# snapshot. Hashing, hdiutil, codesign, and evidence all consume this same
# snapshot, so replacing and later restoring the caller-visible pathname
# cannot make the recorded hash describe bytes other than those inspected.
if ! DMG_SHA256_BEFORE="$($PYTHON -I - \
  "$DMG_ABSOLUTE" "$PINNED_DMG" "$WORK/source-fingerprint.json" <<'PY' 2>/dev/null
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import stat
import sys


def abort() -> None:
    raise SystemExit(1)


source = Path(sys.argv[1])
snapshot = Path(sys.argv[2])
state_path = Path(sys.argv[3])
read_flags = os.O_RDONLY | os.O_NOFOLLOW
write_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
source_fd = -1
snapshot_fd = -1


def fingerprint(value: os.stat_result) -> tuple[int, ...]:
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
        getattr(value, "st_flags", 0),
    )


try:
    path_before = os.lstat(source)
    source_fd = os.open(source, read_flags)
    source_before = os.fstat(source_fd)
    if (
        not stat.S_ISREG(source_before.st_mode)
        or fingerprint(path_before) != fingerprint(source_before)
        or source_before.st_size <= 0
        or source_before.st_size > 16 * 1024 * 1024 * 1024
    ):
        abort()
    snapshot_fd = os.open(snapshot, write_flags, 0o400)
    digest = hashlib.sha256()
    remaining = source_before.st_size
    while remaining:
        chunk = os.read(source_fd, min(1024 * 1024, remaining))
        if not chunk:
            abort()
        digest.update(chunk)
        view = memoryview(chunk)
        while view:
            written = os.write(snapshot_fd, view)
            if written <= 0:
                abort()
            view = view[written:]
        remaining -= len(chunk)
    if os.read(source_fd, 1):
        abort()
    os.fsync(snapshot_fd)
    source_after = os.fstat(source_fd)
    path_after = os.lstat(source)
    snapshot_after = os.fstat(snapshot_fd)
    if (
        fingerprint(source_after) != fingerprint(source_before)
        or fingerprint(path_after) != fingerprint(source_before)
        or not stat.S_ISREG(snapshot_after.st_mode)
        or snapshot_after.st_uid != os.geteuid()
        or snapshot_after.st_nlink != 1
        or snapshot_after.st_size != source_before.st_size
    ):
        abort()
    value = digest.hexdigest()
    state_path.write_text(
        json.dumps(
            {"sha256": value, "sourceFingerprint": list(fingerprint(source_before))},
            sort_keys=True,
            separators=(",", ":"),
        ) + "\n",
        encoding="utf-8",
    )
    print(value)
except (OSError, ValueError):
    abort()
finally:
    if snapshot_fd >= 0:
        os.close(snapshot_fd)
    if source_fd >= 0:
        os.close(source_fd)
PY
)"; then
  fail hash-inspection-failed
fi
[[ "$DMG_SHA256_BEFORE" =~ ^[0-9a-f]{64}$ ]] || fail hash-inspection-failed
[[ -f "$PINNED_DMG" && ! -L "$PINNED_DMG" ]] || fail hash-inspection-failed

if ! "$HDIUTIL" attach \
  -readonly \
  -nobrowse \
  -noautoopen \
  -owners on \
  -mountroot "$MOUNT_ROOT" \
  -plist \
  "$PINNED_DMG" \
  > "$WORK/attach-output" 2> "$WORK/attach-error"; then
  fail attach-failed
fi
ATTACHED=1
if ! "$PYTHON" -I - \
  "$WORK/attach-output" \
  "$MOUNT_ROOT" \
  "$WORK/attach-device" \
  "$WORK/mount-point" \
  "$TEST_MODE" <<'PY' >/dev/null 2>&1
from __future__ import annotations

import os
from pathlib import Path
import plistlib
import re
import stat
import sys


def abort() -> None:
    raise SystemExit(1)


plist_path = Path(sys.argv[1])
mount_root = Path(sys.argv[2])
device_output = Path(sys.argv[3])
mount_output = Path(sys.argv[4])
test_mode = sys.argv[5] == "1"
try:
    if plist_path.stat().st_size > 1024 * 1024:
        abort()
    with plist_path.open("rb") as handle:
        value = plistlib.load(handle)
except (OSError, plistlib.InvalidFileException):
    abort()
if type(value) is not dict or type(value.get("system-entities")) is not list:
    abort()
entities = value["system-entities"]
if not 1 <= len(entities) <= 16 or any(type(entity) is not dict for entity in entities):
    abort()

device_pattern = re.compile(r"/dev/(disk[0-9]+)(?:s[0-9]+)?")
whole_devices: list[str] = []
devices: list[str] = []
device_bases: list[str] = []
mounted_entities: list[dict[str, object]] = []
for entity in entities:
    device = entity.get("dev-entry")
    if type(device) is not str:
        abort()
    match = device_pattern.fullmatch(device)
    if match is None:
        abort()
    devices.append(device)
    device_bases.append(match.group(1))
    if device == f"/dev/{match.group(1)}":
        whole_devices.append(device)
    mount = entity.get("mount-point")
    if mount is not None:
        if type(mount) is not str or not mount:
            abort()
        mounted_entities.append(entity)

if len(devices) != len(set(devices)) or len(whole_devices) != 1 or len(set(device_bases)) != 1:
    abort()
whole_device = whole_devices[0]
# Persist the validated whole device before checking mount cardinality so the
# shell trap can still detach a multi-volume image that is about to be rejected.
device_output.write_text(whole_device + "\n", encoding="ascii")
if len(mounted_entities) != 1:
    abort()
mounted_entity = mounted_entities[0]
if mounted_entity.get("content-hint") not in {"Apple_HFS", "Apple_HFSX"}:
    abort()

try:
    mount_root = mount_root.resolve(strict=True)
    mounted = Path(str(mounted_entity["mount-point"]))
    if (
        mounted != Path(os.path.abspath(mounted))
        or mounted.parent != mount_root
        or mounted.name != "UtterInk"
    ):
        abort()
    mounted_metadata = os.lstat(mounted)
    if stat.S_ISLNK(mounted_metadata.st_mode) or not stat.S_ISDIR(mounted_metadata.st_mode):
        abort()
    if mounted.resolve(strict=True) != mounted:
        abort()
    if not test_mode and not os.path.ismount(mounted):
        abort()
except (OSError, RuntimeError, ValueError):
    abort()
mount_output.write_text(str(mounted) + "\n", encoding="utf-8")
PY
then
  if [[ -f "$WORK/attach-device" && ! -L "$WORK/attach-device" ]]; then
    ATTACH_DEVICE="$(/bin/cat "$WORK/attach-device")"
  fi
  fail attachment-layout-invalid
fi
ATTACH_DEVICE="$(/bin/cat "$WORK/attach-device")"
MOUNT_POINT="$(/bin/cat "$WORK/mount-point")"
[[ "$ATTACH_DEVICE" =~ ^/dev/disk[0-9]+$ ]] || fail attachment-layout-invalid
[[ -d "$MOUNT_POINT" && ! -L "$MOUNT_POINT" ]] || fail mount-invalid

if ! scan_result="$($PYTHON -I - "$MOUNT_POINT" "$WORK/files.nul" "$WORK/signables.nul" "$WORK/manifest.txt" "$TEST_MODE" <<'PY' 2>/dev/null
from __future__ import annotations

import ctypes
import os
from pathlib import Path, PurePosixPath
import plistlib
import stat
import sys


class InspectionError(Exception):
    def __init__(self, category: str):
        super().__init__(category)
        self.category = category


def reject(category: str) -> None:
    raise InspectionError(category)


mount = Path(sys.argv[1])
files_output = Path(sys.argv[2])
signables_output = Path(sys.argv[3])
manifest_output = Path(sys.argv[4])
test_mode = sys.argv[5] == "1"
expected_manifest = ["Applications -> /Applications", "UtterInk.app directory"]
source_suffixes = {
    ".c", ".cc", ".command", ".cpp", ".h", ".hpp", ".js", ".jsx", ".m", ".mm",
    ".py", ".rb", ".sh", ".swift", ".ts", ".tsx", ".xcactivitylog", ".xcodeproj",
    ".xcworkspace",
}
log_suffixes = {".log", ".trace"}
credential_names = {
    ".env", ".netrc", ".npmrc", "api-key.txt", "apikey.txt", "auth.json", "credential.json",
    "credentials", "credentials.json", "id_ed25519", "id_rsa", "secrets.json", "token.txt",
}
credential_suffixes = {".key", ".mobileprovision", ".p12", ".pem", ".pfx"}
code_bundle_suffixes = {".app", ".appex", ".framework", ".plugin", ".xpc"}
private_key_prefix = b"-----BEGIN "
private_markers = (
    private_key_prefix + b"PRIVATE KEY-----",
    private_key_prefix + b"RSA PRIVATE KEY-----",
    private_key_prefix + b"OPENSSH PRIVATE KEY-----",
    b"AWS_ACCESS_KEY_ID=",
    b"OPENAI_API_KEY=",
    b'"client_secret"',
)
try:
    libc = ctypes.CDLL(None, use_errno=True)
    list_xattr = libc.listxattr
    list_xattr.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
    list_xattr.restype = ctypes.c_ssize_t
    get_xattr = libc.getxattr
    get_xattr.argtypes = [
        ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t,
        ctypes.c_uint32, ctypes.c_int,
    ]
    get_xattr.restype = ctypes.c_ssize_t
except (AttributeError, OSError, TypeError):
    list_xattr = None
    get_xattr = None
xattr_nofollow = 0x0001


def unsafe_name(name: str) -> bool:
    return (
        not name
        or name in {".", ".."}
        or any(ord(character) < 32 or ord(character) == 127 for character in name)
        or name.startswith(".")
    )


def inspect_name(path: Path) -> None:
    lower = path.name.lower()
    suffix = path.suffix.lower()
    if (
        suffix in source_suffixes
        or suffix in log_suffixes
        or lower in {"log", "logs", "package.swift", "package.resolved"}
    ):
        reject("forbidden-content")
    if (
        lower in credential_names
        or suffix in credential_suffixes
        or lower.startswith("credential.")
        or lower.startswith("credentials.")
        or lower.startswith("secret.")
    ):
        reject("forbidden-content")
    if "unquarantine" in lower or "remove-quarantine" in lower or "gatekeeper-bypass" in lower:
        reject("quarantine-helper")


def reject_extended_attributes(path: Path) -> None:
    if list_xattr is None or get_xattr is None:
        reject("unsafe-bundle-content")
    try:
        encoded = os.fsencode(path)
    except (TypeError, UnicodeError):
        reject("unsafe-bundle-content")
    ctypes.set_errno(0)
    attribute_bytes = list_xattr(encoded, None, 0, xattr_nofollow)
    if attribute_bytes < 0:
        reject("unsafe-bundle-content")
    if attribute_bytes == 0:
        return
    if attribute_bytes > 64 * 1024:
        reject("unsafe-bundle-content")
    buffer = ctypes.create_string_buffer(attribute_bytes)
    ctypes.set_errno(0)
    actual_bytes = list_xattr(encoded, buffer, attribute_bytes, xattr_nofollow)
    if actual_bytes != attribute_bytes:
        reject("unsafe-bundle-content")
    raw_names = bytes(buffer.raw[:actual_bytes])
    names = raw_names.split(b"\0")
    if not names or names[-1] != b"" or any(not name for name in names[:-1]):
        reject("unsafe-bundle-content")
    attributes = names[:-1]
    provenance_name = b"com.apple.provenance"
    if attributes != [provenance_name]:
        reject("forbidden-content")
    ctypes.set_errno(0)
    value_size = get_xattr(encoded, provenance_name, None, 0, 0, xattr_nofollow)
    if value_size != 11:
        reject("forbidden-content" if value_size >= 0 else "unsafe-bundle-content")
    value = ctypes.create_string_buffer(value_size)
    ctypes.set_errno(0)
    value_actual = get_xattr(
        encoded, provenance_name, value, value_size, 0, xattr_nofollow,
    )
    if value_actual != value_size:
        reject("unsafe-bundle-content")
    if value.raw[:value_actual][:3] != b"\x01\x02\x00":
        reject("forbidden-content")


def inspect_regular(path: Path) -> None:
    inspect_name(path)
    descriptor = -1
    try:
        metadata = os.lstat(path)
        flags = os.O_RDONLY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(path, flags)
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or (opened.st_dev, opened.st_ino, opened.st_size)
            != (metadata.st_dev, metadata.st_ino, metadata.st_size)
        ):
            reject("unsafe-bundle-content")
        private_tail = b""
        lower_tail = b""
        saw_quarantine = False
        saw_xattr = False
        saw_delete = False
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            private_window = private_tail + chunk
            if any(marker in private_window for marker in private_markers):
                reject("forbidden-content")
            private_tail = private_window[-128:]
            lower_window = (lower_tail + chunk).lower()
            saw_quarantine = saw_quarantine or b"com.apple.quarantine" in lower_window
            saw_xattr = saw_xattr or b"xattr" in lower_window
            saw_delete = saw_delete or any(
                marker in lower_window for marker in (b" -d", b" --delete", b" -c", b" -r")
            )
            lower_tail = lower_window[-4096:]
    except OSError:
        reject("unsafe-bundle-content")
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if saw_quarantine and saw_xattr and saw_delete:
        reject("quarantine-helper")


def resource_bundle_ancestor(path: Path, app: Path) -> Path | None:
    return next(
        (parent for parent in path.parents if parent != app and parent.suffix == ".bundle"),
        None,
    )


def read_small_regular(path: Path, maximum_size: int = 1024 * 1024) -> bytes:
    descriptor = -1
    try:
        before = os.lstat(path)
        if (
            not stat.S_ISREG(before.st_mode)
            or stat.S_ISLNK(before.st_mode)
            or before.st_nlink != 1
            or before.st_size > maximum_size
        ):
            reject("unsafe-bundle-content")
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        opened = os.fstat(descriptor)
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, 65536)
            if not chunk:
                break
            total += len(chunk)
            if total > maximum_size:
                reject("unsafe-bundle-content")
            chunks.append(chunk)
        after = os.fstat(descriptor)
        fingerprint = lambda item: (
            item.st_dev, item.st_ino, item.st_mode, item.st_uid, item.st_nlink,
            item.st_size, item.st_mtime_ns, item.st_ctime_ns,
        )
        if fingerprint(before) != fingerprint(opened) or fingerprint(opened) != fingerprint(after):
            reject("unsafe-bundle-content")
        return b"".join(chunks)
    except OSError:
        reject("unsafe-bundle-content")
    finally:
        if descriptor >= 0:
            os.close(descriptor)


try:
    if mount.is_symlink() or not mount.is_dir():
        reject("mount-invalid")
    reject_extended_attributes(mount)
    entries = sorted(os.scandir(mount), key=lambda entry: entry.name.encode("utf-8", errors="strict"))
    actual_manifest: list[str] = []
    for entry in entries:
        if unsafe_name(entry.name):
            reject("forbidden-content")
        metadata = entry.stat(follow_symlinks=False)
        if stat.S_ISLNK(metadata.st_mode):
            actual_manifest.append(f"{entry.name} -> {os.readlink(entry.path)}")
        elif stat.S_ISDIR(metadata.st_mode):
            actual_manifest.append(f"{entry.name} directory")
        else:
            actual_manifest.append(f"{entry.name} file")
    manifest_output.write_text("\n".join(actual_manifest) + "\n", encoding="utf-8")
    if actual_manifest != expected_manifest:
        reject("content-manifest-mismatch")

    applications = mount / "Applications"
    if not applications.is_symlink() or os.readlink(applications) != "/Applications":
        reject("applications-link-mismatch")
    reject_extended_attributes(applications)
    app = mount / "UtterInk.app"
    app_metadata = os.lstat(app)
    if not stat.S_ISDIR(app_metadata.st_mode) or stat.S_ISLNK(app_metadata.st_mode):
        reject("unsafe-bundle-content")
    reject_extended_attributes(app)

    regular_files: list[Path] = []
    signables: list[Path] = [app]
    directory_paths: set[Path] = set()
    resource_bundles: set[Path] = set()
    for current_text, directories, filenames in os.walk(app, topdown=True, followlinks=False):
        current = Path(current_text)
        reject_extended_attributes(current)
        for name in sorted(directories + filenames, key=lambda value: value.encode("utf-8", errors="strict")):
            if unsafe_name(name):
                reject("forbidden-content")
            path = current / name
            try:
                metadata = os.lstat(path)
            except OSError:
                reject("unsafe-bundle-content")
            reject_extended_attributes(path)
            inspect_name(path)
            if stat.S_ISLNK(metadata.st_mode):
                if path.suffix.lower() == ".bundle" or resource_bundle_ancestor(path, app) is not None:
                    reject("unsafe-symlink")
                try:
                    target_text = os.readlink(path)
                    target = Path(target_text)
                    if target.is_absolute() or not target.parts:
                        reject("unsafe-symlink")
                    resolved = path.resolve(strict=True)
                    resolved.relative_to(app.resolve(strict=True))
                except (OSError, RuntimeError, ValueError):
                    reject("unsafe-symlink")
                continue
            if stat.S_ISDIR(metadata.st_mode):
                directory_paths.add(path)
                suffix = path.suffix
                bundle_ancestor = resource_bundle_ancestor(path, app)
                if suffix == ".bundle":
                    if bundle_ancestor is not None or path.parent != app / "Contents" / "Resources":
                        reject("unsafe-bundle-content")
                    resource_bundles.add(path)
                elif bundle_ancestor is not None:
                    bundle_contents = bundle_ancestor / "Contents"
                    bundle_resources = bundle_contents / "Resources"
                    if path == bundle_contents or path == bundle_resources:
                        pass
                    elif suffix == ".lproj" and path.parent == bundle_resources:
                        pass
                    else:
                        reject("unsafe-bundle-content")
                elif suffix.lower() == ".bundle":
                    reject("unsafe-bundle-content")
                elif suffix.lower() in code_bundle_suffixes:
                    signables.append(path)
                continue
            if not stat.S_ISREG(metadata.st_mode):
                reject("unsafe-bundle-content")
            if path.suffix.lower() == ".bundle":
                reject("unsafe-bundle-content")
            bundle_ancestor = resource_bundle_ancestor(path, app)
            if bundle_ancestor is not None:
                bundle_contents = bundle_ancestor / "Contents"
                bundle_resources = bundle_contents / "Resources"
                if path != bundle_contents / "Info.plist" and bundle_resources not in path.parents:
                    reject("unsafe-bundle-content")
                if metadata.st_nlink != 1 or stat.S_IMODE(metadata.st_mode) & 0o111:
                    reject("forbidden-content")
            inspect_regular(path)
            regular_files.append(path)

    for resource_bundle in resource_bundles:
        bundle_contents = resource_bundle / "Contents"
        bundle_resources = bundle_contents / "Resources"
        if bundle_contents not in directory_paths or bundle_resources not in directory_paths:
            reject("unsafe-bundle-content")
        info_path = bundle_contents / "Info.plist"
        try:
            properties = plistlib.loads(read_small_regular(info_path))
        except (plistlib.InvalidFileException, ValueError):
            reject("unsafe-bundle-content")
        if (
            not isinstance(properties, dict)
            or properties.get("CFBundlePackageType") != "BNDL"
            or "CFBundleExecutable" in properties
        ):
            reject("forbidden-content")

    info = app / "Contents" / "Info.plist"
    executable = app / "Contents" / "MacOS" / "UtterInk"
    for required in (info, executable):
        metadata = os.lstat(required)
        if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
            reject("bundle-layout-mismatch")
    executable_metadata = os.lstat(executable)
    if stat.S_IMODE(executable_metadata.st_mode) != 0o755:
        reject("bundle-layout-mismatch")

    with files_output.open("wb") as handle:
        for path in sorted(regular_files, key=lambda value: value.relative_to(app).as_posix().encode("utf-8")):
            handle.write(os.fsencode(path) + b"\0")
    with signables_output.open("wb") as handle:
        for path in sorted(set(signables), key=lambda value: value.relative_to(mount).as_posix().encode("utf-8")):
            handle.write(os.fsencode(path) + b"\0")
except InspectionError as error:
    print(error.category)
    raise SystemExit(1)
except (OSError, UnicodeError, ValueError):
    print("unsafe-bundle-content")
    raise SystemExit(1)
PY
)"; then
  case "$scan_result" in
    applications-link-mismatch|bundle-layout-mismatch|content-manifest-mismatch|forbidden-content|mount-invalid|quarantine-helper|unsafe-bundle-content|unsafe-symlink) fail "$scan_result" ;;
    *) fail unsafe-bundle-content ;;
  esac
fi

if ! "$PYTHON" -I Scripts/release/read-metadata.py --json > "$WORK/metadata.json" 2> "$WORK/metadata-error"; then
  fail metadata-policy-invalid
fi
INFO_PLIST="$MOUNT_POINT/UtterInk.app/Contents/Info.plist"
if ! "$PYTHON" -I - "$INFO_PLIST" "$WORK/metadata.json" "$DMG_ABSOLUTE" "$MODE" "$WORK/dmg-filename" <<'PY' >/dev/null 2>&1
from __future__ import annotations

import json
from pathlib import Path
import plistlib
import sys


try:
    with Path(sys.argv[1]).open("rb") as handle:
        info = plistlib.load(handle)
    metadata = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
    expected = {
        "CFBundleDisplayName": metadata["product"],
        "CFBundleExecutable": metadata["product"],
        "CFBundleIdentifier": metadata["bundleIdentifier"],
        "CFBundleName": metadata["product"],
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": metadata["marketingVersion"],
        "CFBundleVersion": metadata["buildNumber"],
        "LSMinimumSystemVersion": metadata["deploymentTarget"],
    }
    if type(info) is not dict:
        raise ValueError
    for key, expected_value in expected.items():
        value = info.get(key)
        if type(value) is not str or value != expected_value:
            raise ValueError
    expected_filename = metadata["dmgFilename"]
    if sys.argv[4] == "unsigned":
        expected_filename = expected_filename.removesuffix(".dmg") + "-UNSIGNED-DO-NOT-DISTRIBUTE.dmg"
    if Path(sys.argv[3]).name != expected_filename:
        raise ValueError
    Path(sys.argv[5]).write_text(expected_filename + "\n", encoding="utf-8")
except (OSError, UnicodeError, ValueError, KeyError, json.JSONDecodeError, plistlib.InvalidFileException):
    raise SystemExit(1)
PY
then
  fail metadata-mismatch
fi
if ! "$PYTHON" -I Scripts/release/verify-info-policy.py --archived "$INFO_PLIST" > "$WORK/info-policy-output" 2> "$WORK/info-policy-error"; then
  fail info-policy-mismatch
fi

signature_unsigned() {
  local target="$1"
  local label="$2"
  local display="$WORK/codesign-display-$label"
  if "$CODESIGN" -d --verbose=4 "$target" > /dev/null 2> "$display"; then
    fail signature-mode-mismatch
  fi
  if ! "$PYTHON" -I - "$display" <<'PY' >/dev/null 2>&1
from pathlib import Path
import sys

try:
    value = Path(sys.argv[1]).read_text(encoding="utf-8", errors="strict").lower()
except (OSError, UnicodeError):
    raise SystemExit(1)
if "not signed at all" not in value and "errseccsunsigned" not in value:
    raise SystemExit(1)
PY
  then
    fail signature-invalid
  fi
}

signature_developer_id() {
  local target="$1"
  local label="$2"
  local expected_identifier="$3"
  local require_runtime="$4"
  local display="$WORK/codesign-display-$label"
  local team_file="$WORK/codesign-team-$label"
  if ! "$CODESIGN" --verify --strict --verbose=4 "$target" > /dev/null 2> "$WORK/codesign-verify-$label"; then
    fail signature-invalid
  fi
  if ! "$CODESIGN" -d --verbose=4 "$target" > /dev/null 2> "$display"; then
    fail signature-invalid
  fi
  if ! "$PYTHON" -I - "$display" "$expected_identifier" "$require_runtime" "$team_file" <<'PY' >/dev/null 2>&1
from __future__ import annotations

from pathlib import Path
import re
import sys


try:
    lines = Path(sys.argv[1]).read_text(encoding="utf-8", errors="strict").splitlines()
except (OSError, UnicodeError):
    raise SystemExit(1)
expected_identifier = sys.argv[2]
require_runtime = sys.argv[3] == "1"
values: dict[str, list[str]] = {}
for line in lines:
    if "=" in line:
        key, value = line.split("=", 1)
        values.setdefault(key, []).append(value)
authorities = values.get("Authority", [])
if len([value for value in authorities if value.startswith("Developer ID Application:")]) != 1:
    raise SystemExit(1)
team_values = values.get("TeamIdentifier", [])
if len(team_values) != 1 or re.fullmatch(r"[A-Z0-9]{10}", team_values[0]) is None:
    raise SystemExit(1)
if expected_identifier != "-" and values.get("Identifier") != [expected_identifier]:
    raise SystemExit(1)
timestamp_values = values.get("Timestamp", [])
if len(timestamp_values) != 1 or not timestamp_values[0] or timestamp_values[0].lower() in {"none", "no"}:
    raise SystemExit(1)
if require_runtime:
    joined = "\n".join(lines).lower()
    if "(runtime)" not in joined and "runtime version=" not in joined:
        raise SystemExit(1)
Path(sys.argv[4]).write_text(team_values[0] + "\n", encoding="ascii")
PY
  then
    fail signature-mode-mismatch
  fi
  local team
  team="$(/bin/cat "$team_file")"
  if [[ -z "${SIGNING_TEAM:-}" ]]; then
    SIGNING_TEAM="$team"
  elif [[ "$SIGNING_TEAM" != "$team" ]]; then
    fail signature-team-mismatch
  fi
}

MACH_O_COUNT=0
MAIN_EXECUTABLE_SEEN=0
SIGNING_TEAM=''
while IFS= read -r -d '' path; do
  if ! description="$($FILE_TOOL -b "$path" 2> "$WORK/file-error")"; then
    fail architecture-inspection-failed
  fi
  if [[ "$description" == *Mach-O* ]]; then
    case "$path" in
      "$MOUNT_POINT/UtterInk.app/Contents/Resources/"*.bundle/*) fail forbidden-content ;;
    esac
    MACH_O_COUNT=$((MACH_O_COUNT + 1))
    if ! architectures="$($LIPO -archs "$path" 2> "$WORK/lipo-error")"; then
      fail architecture-inspection-failed
    fi
    [[ "$architectures" == arm64 ]] || fail unsupported-architecture
    if [[ "$path" == "$MOUNT_POINT/UtterInk.app/Contents/MacOS/UtterInk" ]]; then
      MAIN_EXECUTABLE_SEEN=1
    fi
    if [[ "$MODE" == unsigned ]]; then
      signature_unsigned "$path" "mach-o-$MACH_O_COUNT"
    else
      signature_developer_id "$path" "mach-o-$MACH_O_COUNT" - 1
    fi
  fi
done < "$WORK/files.nul"
[[ "$MACH_O_COUNT" -ge 1 && "$MAIN_EXECUTABLE_SEEN" -eq 1 ]] || fail unsupported-architecture

SIGNABLE_COUNT=0
while IFS= read -r -d '' path; do
  SIGNABLE_COUNT=$((SIGNABLE_COUNT + 1))
  if [[ "$MODE" == unsigned ]]; then
    signature_unsigned "$path" "bundle-$SIGNABLE_COUNT"
  else
    if [[ "$path" == "$MOUNT_POINT/UtterInk.app" ]]; then
      signature_developer_id "$path" "bundle-$SIGNABLE_COUNT" dev.utterink.UtterInk 1
    else
      signature_developer_id "$path" "bundle-$SIGNABLE_COUNT" - 1
    fi
  fi
done < "$WORK/signables.nul"
[[ "$SIGNABLE_COUNT" -ge 1 ]] || fail bundle-layout-mismatch

if [[ "$MODE" == unsigned ]]; then
  signature_unsigned "$PINNED_DMG" dmg
  SIGNATURE_KIND=unsigned
else
  signature_developer_id "$PINNED_DMG" dmg - 0
  SIGNATURE_KIND=developer-id
fi

DMG_FILENAME="$(/bin/cat "$WORK/dmg-filename")"
if ! "$PYTHON" -I - "$WORK/metadata.json" "$MODE" "$SIGNATURE_KIND" "$MACH_O_COUNT" "$DMG_FILENAME" "$DMG_SHA256_BEFORE" "$WORK/evidence.json" <<'PY' >/dev/null 2>&1
from __future__ import annotations

import json
from pathlib import Path
import sys


try:
    metadata = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    evidence = {
        "architecture": metadata["architecture"],
        "buildNumber": metadata["buildNumber"],
        "bundleIdentifier": metadata["bundleIdentifier"],
        "dmgFilename": sys.argv[5],
        "dmgSHA256": sys.argv[6],
        "machOCount": int(sys.argv[4]),
        "manifest": ["Applications -> /Applications", "UtterInk.app directory"],
        "minimumSystemVersion": metadata["deploymentTarget"],
        "mode": sys.argv[2],
        "product": metadata["product"],
        "signature": sys.argv[3],
        "status": "valid",
        "version": metadata["marketingVersion"],
    }
    if evidence["architecture"] != "arm64" or evidence["product"] != "UtterInk":
        raise ValueError
    serialized = json.dumps(evidence, sort_keys=True, separators=(",", ":")) + "\n"
    if "/Users/" in serialized or "/private/tmp/" in serialized or "Authority=" in serialized or "TeamIdentifier=" in serialized:
        raise ValueError
    Path(sys.argv[7]).write_text(serialized, encoding="utf-8")
except (OSError, UnicodeError, ValueError, KeyError, json.JSONDecodeError):
    raise SystemExit(1)
PY
then
  fail evidence-generation-failed
fi

if ! "$HDIUTIL" detach "$ATTACH_DEVICE" > "$WORK/detach-output" 2> "$WORK/detach-error"; then
  fail detach-failed
fi
ATTACHED=0
if ! "$PYTHON" -I - \
  "$DMG_ABSOLUTE" "$PINNED_DMG" "$WORK/source-fingerprint.json" <<'PY' >/dev/null 2>&1
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import stat
import sys


def abort() -> None:
    raise SystemExit(1)


source = Path(sys.argv[1])
snapshot = Path(sys.argv[2])
state_path = Path(sys.argv[3])
read_flags = os.O_RDONLY | os.O_NOFOLLOW


def fingerprint(value: os.stat_result) -> tuple[int, ...]:
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
        getattr(value, "st_flags", 0),
    )


def stable_hash(path: Path, expected_fingerprint: tuple[int, ...] | None) -> str:
    descriptor = -1
    try:
        path_before = os.lstat(path)
        descriptor = os.open(path, read_flags)
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or fingerprint(path_before) != fingerprint(before)
            or (expected_fingerprint is not None and fingerprint(before) != expected_fingerprint)
        ):
            abort()
        digest = hashlib.sha256()
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
        after = os.fstat(descriptor)
        path_after = os.lstat(path)
        if fingerprint(after) != fingerprint(before) or fingerprint(path_after) != fingerprint(before):
            abort()
        return digest.hexdigest()
    finally:
        if descriptor >= 0:
            os.close(descriptor)


try:
    state = json.loads(state_path.read_text(encoding="utf-8"))
    if type(state) is not dict or set(state) != {"sha256", "sourceFingerprint"}:
        abort()
    expected_hash = state["sha256"]
    raw_fingerprint = state["sourceFingerprint"]
    if (
        type(expected_hash) is not str
        or len(expected_hash) != 64
        or any(character not in "0123456789abcdef" for character in expected_hash)
        or type(raw_fingerprint) is not list
        or len(raw_fingerprint) != 10
        or any(type(value) is not int for value in raw_fingerprint)
    ):
        abort()
    expected_fingerprint = tuple(raw_fingerprint)
    source_hash = stable_hash(source, expected_fingerprint)
    snapshot_hash = stable_hash(snapshot, None)
    if source_hash != expected_hash or snapshot_hash != expected_hash:
        abort()
except (OSError, UnicodeError, ValueError, json.JSONDecodeError):
    abort()
PY
then
  fail dmg-mutated-during-inspection
fi
/bin/cat "$WORK/evidence.json"
