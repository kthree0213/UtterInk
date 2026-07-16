#!/bin/bash
set -euo pipefail

export LC_ALL=C
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
unset BASH_ENV ENV CDPATH GLOBIGNORE PYTHONHOME PYTHONPATH
unset DEVELOPER_DIR SDKROOT TOOLCHAINS XCODE_DEFAULT_TOOLCHAIN_OVERRIDE
umask 077

fail() {
  printf 'XcodeGen bootstrap error: %s\n' "$1" >&2
  exit "${2:-1}"
}

[[ "$#" -eq 0 ]] || fail invalid-arguments 64

ROOT="$(cd "$(/usr/bin/dirname "$0")/.." && /bin/pwd -P)"
cd "$ROOT"
LOCK="$ROOT/Config/ci-toolchain.json"
[[ -f "$LOCK" && ! -L "$LOCK" ]] || fail toolchain-lock-missing

TEST_MODE=0
case "${UTTERINK_TOOLCHAIN_TEST_MODE:-}" in
  '') ;;
  1) TEST_MODE=1 ;;
  *) fail invalid-test-mode ;;
esac

TMP="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/utterink-xcodegen.XXXXXX")"
INSTALL_BINARY_TEMP=''
INSTALL_RESOURCE_TEMP=''
cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "$INSTALL_BINARY_TEMP" ]]; then
    /bin/rm -f "$INSTALL_BINARY_TEMP"
  fi
  if [[ -n "$INSTALL_RESOURCE_TEMP" ]]; then
    /bin/rm -rf "$INSTALL_RESOURCE_TEMP"
  fi
  /bin/rm -rf "$TMP"
  exit "$status"
}
trap cleanup EXIT
/bin/mkdir -p "$TMP/lock"

if ! /usr/bin/python3 -I - "$LOCK" "$TMP/lock" "$TEST_MODE" <<'PY'
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


def exact(value: object, keys: set[str]) -> dict[str, object]:
    if type(value) is not dict or set(value) != keys:
        abort()
    return value


def locked_string(value: object, pattern: str | None = None) -> str:
    if type(value) is not str or not value or "\x00" in value or "\n" in value or "\r" in value:
        abort()
    if pattern is not None and re.fullmatch(pattern, value) is None:
        abort()
    return value


lock_path = Path(sys.argv[1])
output = Path(sys.argv[2])
test_mode = sys.argv[3] == "1"
try:
    if lock_path.stat().st_size > 128 * 1024:
        abort()
    lock = json.loads(lock_path.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
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

if runner["label"] != "macos-26" or runner["architecture"] != "arm64":
    abort()
release_tag = locked_string(runner["releaseTag"], r"macos-26-arm64/[0-9]{8}[.][0-9]{4}")
runner_commit = locked_string(runner["commit"], r"[0-9a-f]{40}")
if set(runner_commit) == {"0"}:
    abort()
locked_string(runner["imageVersion"], r"[0-9]{8}[.][0-9]{4}(?:[.][0-9]+)?")
if runner["osVersion"] != "26.4":
    abort()
locked_string(runner["osBuild"], r"[0-9]{2}[A-Z][0-9]{1,6}[a-z]?")

if xcode != {
    "version": "26.4.1",
    "build": "17E202",
    "developerDir": "/Applications/Xcode_26.4.app/Contents/Developer",
}:
    abort()
if sdk["version"] != "26.4":
    abort()
locked_string(sdk["build"], r"[0-9]{2}[A-Z][0-9]{1,6}[a-z]?")
locked_string(
    swift["version"],
    r"(?:swift-driver version: [0-9]+(?:[.][0-9]+)* )?Apple Swift version 6[.]3(?:[.][0-9]+)* [(]swiftlang-[A-Za-z0-9.]+ clang-[A-Za-z0-9.]+[)]",
)

if xcodegen["version"] != "2.45.4":
    abort()
source_commit = locked_string(xcodegen["sourceCommit"], r"[0-9a-f]{40}")
if set(source_commit) == {"0"}:
    abort()
archive_url = f"https://github.com/yonaskolb/XcodeGen/releases/download/{xcodegen['version']}/xcodegen.zip"
if xcodegen["archiveURL"] != archive_url:
    abort()
archive_sha = locked_string(xcodegen["archiveSHA256"], r"[0-9a-f]{64}")
binary_sha = locked_string(xcodegen["binarySHA256"], r"[0-9a-f]{64}")
setting_presets_sha = locked_string(xcodegen["settingPresetsSHA256"], r"[0-9a-f]{64}")
if not test_mode:
    if source_commit != "8d3d3476a69ae3e5d68e1adccc701c410c05eb36":
        abort()
    if archive_sha != "090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef":
        abort()
    if binary_sha != "6aa2b4da95304b343bea12890c59f9655aa428c08b351d57d592cfab4e88a9f1":
        abort()
    if setting_presets_sha != "9f8dd5292ab7723927b40e836d651775e3261a30f0c05179b3b8ca7340404069":
        abort()

encoded_tag = release_tag.replace("/", "%2F")
if sources != {
    "runnerRelease": f"https://github.com/actions/runner-images/releases/tag/{encoded_tag}",
    "runnerReadme": f"https://github.com/actions/runner-images/blob/{runner_commit}/images/macos/macos-26-arm64-Readme.md",
    "xcodegenRelease": "https://github.com/yonaskolb/XcodeGen/releases/tag/2.45.4",
    "xcodegenCommit": f"https://github.com/yonaskolb/XcodeGen/commit/{source_commit}",
}:
    abort()

fields = {
    "archive-url": archive_url,
    "archive-sha": archive_sha,
    "binary-sha": binary_sha,
    "setting-presets-sha": setting_presets_sha,
    "version": xcodegen["version"],
}
for name, value in fields.items():
    (output / name).write_text(value, encoding="utf-8")
PY
then
  fail toolchain-lock-invalid
fi

ARCHIVE_URL="$(/bin/cat "$TMP/lock/archive-url")"
ARCHIVE_SHA="$(/bin/cat "$TMP/lock/archive-sha")"
BINARY_SHA="$(/bin/cat "$TMP/lock/binary-sha")"
SETTING_PRESETS_SHA="$(/bin/cat "$TMP/lock/setting-presets-sha")"
XCODEGEN_VERSION="$(/bin/cat "$TMP/lock/version")"

if [[ "$TEST_MODE" -eq 1 ]]; then
  TOOL_ROOT="${UTTERINK_TOOLCHAIN_TEST_TOOL_ROOT:-}"
  TEST_ARCHIVE="${UTTERINK_TOOLCHAIN_TEST_ARCHIVE:-}"
  case "$ROOT" in
    /tmp/*|/private/tmp/*|/private/var/folders/*/T/*) ;;
    *) fail test-mode-not-allowed ;;
  esac
  [[ "$TOOL_ROOT" == /* && -d "$TOOL_ROOT" && ! -L "$TOOL_ROOT" ]] || fail invalid-test-tool-root
  [[ "$TEST_ARCHIVE" == /* && -f "$TEST_ARCHIVE" && ! -L "$TEST_ARCHIVE" ]] || fail invalid-test-source
  TOOL_ROOT="$(cd "$TOOL_ROOT" && /bin/pwd -P)"
  TEST_ARCHIVE_PARENT="$(cd "$(/usr/bin/dirname "$TEST_ARCHIVE")" && /bin/pwd -P)"
  TEST_ARCHIVE="$TEST_ARCHIVE_PARENT/$(/usr/bin/basename "$TEST_ARCHIVE")"
  [[ "$TOOL_ROOT" == "$ROOT/FixtureTools" ]] || fail invalid-test-tool-root
  [[ -f "$TOOL_ROOT/.utterink-toolchain-test-fixture" && ! -L "$TOOL_ROOT/.utterink-toolchain-test-fixture" ]] || fail invalid-test-tool-root
  [[ "$(/bin/cat "$TOOL_ROOT/.utterink-toolchain-test-fixture")" == utterink-offline-toolchain-fixture-v1 ]] || fail invalid-test-tool-root
  case "$TEST_ARCHIVE" in "$ROOT"/FixtureArchive/*.zip) ;; *) fail invalid-test-source ;; esac
  LIPO="$TOOL_ROOT/lipo"
else
  LIPO=/usr/bin/lipo
fi
[[ -f "$LIPO" && -x "$LIPO" && ! -L "$LIPO" ]] || fail architecture-tool-unavailable

TOOLS_ROOT="$ROOT/Tools"
TOOLS_BIN="$TOOLS_ROOT/bin"
DESTINATION="$TOOLS_BIN/xcodegen"
RESOURCE_BUNDLE_NAME='XcodeGen_XcodeGenKit.bundle'
DESTINATION_BUNDLE="$TOOLS_BIN/$RESOURCE_BUNDLE_NAME"
DESTINATION_SETTING_PRESETS="$DESTINATION_BUNDLE/SettingPresets"
[[ ! -L "$TOOLS_ROOT" \
  && ! -L "$TOOLS_BIN" \
  && ! -L "$DESTINATION" \
  && ! -L "$DESTINATION_BUNDLE" \
  && ! -L "$DESTINATION_SETTING_PRESETS" ]] || fail unsafe-install-path
/bin/mkdir -p "$TOOLS_BIN"
[[ -d "$TOOLS_ROOT" \
  && -d "$TOOLS_BIN" \
  && ! -L "$TOOLS_ROOT" \
  && ! -L "$TOOLS_BIN" ]] || fail unsafe-install-path
if [[ -e "$DESTINATION_BUNDLE" && ! -d "$DESTINATION_BUNDLE" ]]; then
  fail unsafe-install-path
fi

setting_presets_tree_hash() {
  /usr/bin/python3 -I - "$1" <<'PY'
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import stat
import struct
import sys


def abort() -> None:
    raise SystemExit(1)


settings = Path(sys.argv[1])
try:
    if not stat.S_ISDIR(settings.lstat().st_mode):
        abort()

    files: list[tuple[bytes, Path, tuple[int, int, int, int]]] = []
    directories: set[bytes] = set()
    stack = [settings]
    while stack:
        directory = stack.pop()
        with os.scandir(directory) as entries:
            for entry in entries:
                path = Path(entry.path)
                info = entry.stat(follow_symlinks=False)
                if stat.S_ISDIR(info.st_mode):
                    directories.add(path.relative_to(settings).as_posix().encode("utf-8"))
                    stack.append(path)
                elif stat.S_ISREG(info.st_mode):
                    relative = path.relative_to(settings).as_posix().encode("utf-8")
                    files.append((relative, path, (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)))
                else:
                    abort()
    if not files:
        abort()
    required_directories: set[bytes] = set()
    for _, path, _ in files:
        for parent in path.relative_to(settings).parents:
            if parent == Path("."):
                break
            required_directories.add(parent.as_posix().encode("utf-8"))
    if directories != required_directories:
        abort()

    digest = hashlib.sha256()
    for relative, path, expected in sorted(files, key=lambda item: item[0]):
        flags = os.O_RDONLY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(path, flags)
        try:
            before = os.fstat(descriptor)
            actual = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
            if not stat.S_ISREG(before.st_mode) or actual != expected:
                abort()
            digest.update(struct.pack(">Q", len(relative)))
            digest.update(relative)
            digest.update(struct.pack(">Q", before.st_size))
            remaining = before.st_size
            while remaining:
                chunk = os.read(descriptor, min(1024 * 1024, remaining))
                if not chunk:
                    abort()
                digest.update(chunk)
                remaining -= len(chunk)
            if os.read(descriptor, 1):
                abort()
            after = os.fstat(descriptor)
            if (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) != actual:
                abort()
        finally:
            os.close(descriptor)
except (OSError, UnicodeError, ValueError):
    abort()

print(digest.hexdigest())
PY
}

companion_bundle_tree_hash() {
  if ! /usr/bin/python3 -I - "$1" <<'PY'
import os
from pathlib import Path
import stat
import sys

bundle = Path(sys.argv[1])
try:
    if not stat.S_ISDIR(bundle.lstat().st_mode):
        raise ValueError
    with os.scandir(bundle) as iterator:
        entries = list(iterator)
    if len(entries) != 1:
        raise ValueError
    entry = entries[0]
    if entry.name != "SettingPresets" or not stat.S_ISDIR(entry.stat(follow_symlinks=False).st_mode):
        raise ValueError
except (OSError, UnicodeError, ValueError):
    raise SystemExit(1)
PY
  then
    return 1
  fi
  setting_presets_tree_hash "$1/SettingPresets"
}

binary_architectures() {
  /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$LIPO" -archs "$1" 2>/dev/null
}

if [[ -f "$DESTINATION" && -x "$DESTINATION" && ! -L "$DESTINATION" ]]; then
  EXISTING_SHA="$(/usr/bin/shasum -a 256 "$DESTINATION" | /usr/bin/awk 'NR == 1 { print $1 }')" || fail repository-xcodegen-unreadable
  if [[ "$EXISTING_SHA" == "$BINARY_SHA" ]]; then
    EXISTING_SETTING_PRESETS_SHA="$(companion_bundle_tree_hash "$DESTINATION_BUNDLE" 2>/dev/null)" ||
      EXISTING_SETTING_PRESETS_SHA=''
    if [[ "$EXISTING_SETTING_PRESETS_SHA" == "$SETTING_PRESETS_SHA" ]]; then
      EXISTING_ARCHITECTURES="$(binary_architectures "$DESTINATION")" || EXISTING_ARCHITECTURES=''
      if [[ "$EXISTING_ARCHITECTURES" == 'x86_64 arm64' ]]; then
        EXISTING_VERSION="$(/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C HOME="$TMP" \
          "$DESTINATION" --version 2>/dev/null)" || EXISTING_VERSION=''
        if [[ "$EXISTING_VERSION" == "Version: $XCODEGEN_VERSION" ]]; then
          printf 'locked XcodeGen already installed: Tools/bin/xcodegen + Tools/bin/%s/SettingPresets\n' "$RESOURCE_BUNDLE_NAME"
          exit 0
        fi
      fi
    fi
  fi
elif [[ -e "$DESTINATION" ]]; then
  fail unsafe-install-path
fi

ARCHIVE_FILE="$TMP/xcodegen.zip"
if [[ "$TEST_MODE" -eq 1 ]]; then
  /bin/cp "$TEST_ARCHIVE" "$ARCHIVE_FILE" || fail archive-copy-failed
else
  /usr/bin/curl \
    --disable \
    --fail \
    --location \
    --proto '=https' \
    --proto-redir '=https' \
    --silent \
    --show-error \
    --output "$ARCHIVE_FILE" \
    "$ARCHIVE_URL" || fail archive-download-failed
fi

ACTUAL_ARCHIVE_SHA="$(/usr/bin/shasum -a 256 "$ARCHIVE_FILE" | /usr/bin/awk 'NR == 1 { print $1 }')" || fail archive-hash-unavailable
[[ "$ACTUAL_ARCHIVE_SHA" == "$ARCHIVE_SHA" ]] || fail archive-hash-mismatch

EXTRACTED="$TMP/extracted"
if ! /usr/bin/python3 -I - "$ARCHIVE_FILE" "$EXTRACTED" <<'PY'
from __future__ import annotations

import os
from pathlib import Path, PurePosixPath
import stat
import sys
import unicodedata
import zipfile


ARCHIVE_PATH = Path(sys.argv[1])
OUTPUT = Path(sys.argv[2])
BINARY = "xcodegen/bin/xcodegen"
PRESETS = "xcodegen/share/xcodegen/SettingPresets"
FIXED_DIRECTORIES = {
    "xcodegen",
    "xcodegen/bin",
    "xcodegen/share",
    "xcodegen/share/xcodegen",
    PRESETS,
}
FIXED_FILES = {
    "xcodegen/LICENSE",
    BINARY,
    "xcodegen/install.sh",
}
FIXED = FIXED_DIRECTORIES | FIXED_FILES
MAX_ENTRIES = 128
MAX_TOTAL_SIZE = 32 * 1024 * 1024
MAX_BINARY_SIZE = 24 * 1024 * 1024
MAX_RESOURCE_SIZE = 1024 * 1024


def abort() -> None:
    raise ValueError


def normalized_name(info: zipfile.ZipInfo) -> str:
    name = info.filename
    if (
        not name
        or len(name) > 512
        or "\x00" in name
        or "\\" in name
        or name.startswith("/")
        or unicodedata.normalize("NFC", name) != name
    ):
        abort()
    try:
        name.encode("ascii", errors="strict")
    except UnicodeError:
        abort()
    raw = name[:-1] if name.endswith("/") else name
    parts = raw.split("/")
    if not parts or any(part in ("", ".", "..") for part in parts):
        abort()
    path = PurePosixPath(*parts).as_posix()
    if info.is_dir() != name.endswith("/"):
        abort()
    return path


def unix_type(info: zipfile.ZipInfo) -> int:
    if info.create_system != 3:
        abort()
    mode = (info.external_attr >> 16) & 0xFFFF
    if mode & 0o022:
        abort()
    kind = stat.S_IFMT(mode)
    expected = stat.S_IFDIR if info.is_dir() else stat.S_IFREG
    if kind != expected:
        abort()
    if not info.is_dir() and info.filename == BINARY and not mode & 0o111:
        abort()
    return mode


def write_member(archive: zipfile.ZipFile, info: zipfile.ZipInfo, target: Path, mode: int) -> None:
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(target, flags, mode)
    written = 0
    try:
        with archive.open(info, "r") as source:
            while True:
                chunk = source.read(1024 * 1024)
                if not chunk:
                    break
                written += len(chunk)
                if written > info.file_size:
                    abort()
                view = memoryview(chunk)
                while view:
                    count = os.write(descriptor, view)
                    if count <= 0:
                        abort()
                    view = view[count:]
        if written != info.file_size:
            abort()
    finally:
        os.close(descriptor)


try:
    with zipfile.ZipFile(ARCHIVE_PATH, mode="r") as archive:
        if archive.comment:
            abort()
        entries = archive.infolist()
        if not entries or len(entries) > MAX_ENTRIES:
            abort()
        records: list[tuple[zipfile.ZipInfo, str]] = []
        names: set[str] = set()
        folded_names: set[str] = set()
        total_size = 0
        preset_file_count = 0
        for info in entries:
            name = normalized_name(info)
            folded = name.casefold()
            if name in names or folded in folded_names:
                abort()
            names.add(name)
            folded_names.add(folded)
            unix_type(info)
            if info.flag_bits & 0x1:
                abort()
            if info.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
                abort()
            if info.file_size < 0 or info.compress_size < 0:
                abort()
            if name not in FIXED and not name.startswith(PRESETS + "/"):
                abort()
            if name in FIXED_DIRECTORIES and not info.is_dir():
                abort()
            if name in FIXED_FILES and info.is_dir():
                abort()
            if info.is_dir():
                if info.file_size != 0:
                    abort()
            else:
                limit = MAX_BINARY_SIZE if name == BINARY else MAX_RESOURCE_SIZE
                if info.file_size > limit:
                    abort()
                total_size += info.file_size
                if total_size > MAX_TOTAL_SIZE:
                    abort()
                if name.startswith(PRESETS + "/"):
                    preset_file_count += 1
            records.append((info, name))
        if not FIXED.issubset(names) or preset_file_count == 0:
            abort()

        OUTPUT.mkdir(mode=0o700)
        settings_output = OUTPUT / "SettingPresets"
        settings_output.mkdir(mode=0o700)
        for info, name in records:
            if name == BINARY:
                write_member(archive, info, OUTPUT / "xcodegen", 0o700)
            elif name.startswith(PRESETS + "/"):
                relative = PurePosixPath(name).relative_to(PRESETS)
                target = settings_output.joinpath(*relative.parts)
                if info.is_dir():
                    target.mkdir(mode=0o700, parents=True, exist_ok=False)
                else:
                    write_member(archive, info, target, 0o600)
except (
    OSError,
    RuntimeError,
    UnicodeError,
    ValueError,
    zipfile.BadZipFile,
    zipfile.LargeZipFile,
):
    raise SystemExit(1)

if not (OUTPUT / "xcodegen").is_file() or not settings_output.is_dir():
    raise SystemExit(1)
PY
then
  fail unsafe-release-archive
fi

POST_EXTRACTION_ARCHIVE_SHA="$(/usr/bin/shasum -a 256 "$ARCHIVE_FILE" | /usr/bin/awk 'NR == 1 { print $1 }')" || fail archive-hash-unavailable
[[ "$POST_EXTRACTION_ARCHIVE_SHA" == "$ARCHIVE_SHA" ]] || fail archive-hash-mismatch

SOURCE_SETTING_PRESETS="$EXTRACTED/SettingPresets"
ACTUAL_SETTING_PRESETS_SHA="$(setting_presets_tree_hash "$SOURCE_SETTING_PRESETS")" || fail release-setting-presets-invalid
[[ "$ACTUAL_SETTING_PRESETS_SHA" == "$SETTING_PRESETS_SHA" ]] || fail release-setting-presets-hash-mismatch

BUILT_BINARY="$EXTRACTED/xcodegen"
[[ -f "$BUILT_BINARY" && -x "$BUILT_BINARY" && ! -L "$BUILT_BINARY" ]] || fail release-binary-missing
ACTUAL_BINARY_SHA="$(/usr/bin/shasum -a 256 "$BUILT_BINARY" | /usr/bin/awk 'NR == 1 { print $1 }')" || fail release-binary-hash-unavailable
[[ "$ACTUAL_BINARY_SHA" == "$BINARY_SHA" ]] || fail release-binary-hash-mismatch
ACTUAL_ARCHITECTURES="$(binary_architectures "$BUILT_BINARY")" || fail release-binary-architecture-unavailable
[[ "$ACTUAL_ARCHITECTURES" == 'x86_64 arm64' ]] || fail release-binary-architecture-mismatch
ACTUAL_VERSION="$(/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C HOME="$TMP" \
  "$BUILT_BINARY" --version 2>/dev/null)" || fail release-binary-version-unavailable
[[ "$ACTUAL_VERSION" == "Version: $XCODEGEN_VERSION" ]] || fail release-binary-version-mismatch

INSTALL_BINARY_TEMP="$(/usr/bin/mktemp "$TOOLS_BIN/.xcodegen.XXXXXX")"
INSTALL_RESOURCE_TEMP="$(/usr/bin/mktemp -d "$TOOLS_BIN/.xcodegen-bundle.XXXXXX")"
STAGED_BUNDLE="$INSTALL_RESOURCE_TEMP/$RESOURCE_BUNDLE_NAME"
STAGED_SETTING_PRESETS="$STAGED_BUNDLE/SettingPresets"
/bin/cp "$BUILT_BINARY" "$INSTALL_BINARY_TEMP" || fail install-copy-failed
/bin/chmod 0755 "$INSTALL_BINARY_TEMP" || fail install-mode-failed
/bin/mkdir -m 0700 "$STAGED_BUNDLE" || fail install-resource-copy-failed
COPYFILE_DISABLE=1 /bin/cp -Rp "$SOURCE_SETTING_PRESETS" "$STAGED_BUNDLE/" || fail install-resource-copy-failed
INSTALLED_TEMP_SHA="$(/usr/bin/shasum -a 256 "$INSTALL_BINARY_TEMP" | /usr/bin/awk 'NR == 1 { print $1 }')" || fail install-hash-unavailable
[[ "$INSTALLED_TEMP_SHA" == "$BINARY_SHA" ]] || fail install-hash-mismatch
STAGED_SETTING_PRESETS_SHA="$(companion_bundle_tree_hash "$STAGED_BUNDLE")" || fail install-resource-verification-failed
[[ "$STAGED_SETTING_PRESETS_SHA" == "$SETTING_PRESETS_SHA" ]] || fail install-resource-verification-failed

[[ ! -L "$DESTINATION_BUNDLE" ]] || fail unsafe-install-path
if [[ -e "$DESTINATION_BUNDLE" ]]; then
  [[ -d "$DESTINATION_BUNDLE" ]] || fail unsafe-install-path
  /bin/rm -rf "$DESTINATION_BUNDLE" || fail install-resource-replace-failed
fi
/bin/mv "$STAGED_BUNDLE" "$DESTINATION_BUNDLE" || fail install-resource-replace-failed
/bin/rmdir "$INSTALL_RESOURCE_TEMP" || fail install-resource-replace-failed
INSTALL_RESOURCE_TEMP=''
/bin/mv -f "$INSTALL_BINARY_TEMP" "$DESTINATION" || fail install-replace-failed
INSTALL_BINARY_TEMP=''
[[ -f "$DESTINATION" && -x "$DESTINATION" && ! -L "$DESTINATION" ]] || fail install-verification-failed
FINAL_SHA="$(/usr/bin/shasum -a 256 "$DESTINATION" | /usr/bin/awk 'NR == 1 { print $1 }')" || fail install-verification-failed
[[ "$FINAL_SHA" == "$BINARY_SHA" ]] || fail install-verification-failed
FINAL_SETTING_PRESETS_SHA="$(companion_bundle_tree_hash "$DESTINATION_BUNDLE")" || fail install-verification-failed
[[ "$FINAL_SETTING_PRESETS_SHA" == "$SETTING_PRESETS_SHA" ]] || fail install-verification-failed
FINAL_ARCHITECTURES="$(binary_architectures "$DESTINATION")" || fail install-verification-failed
[[ "$FINAL_ARCHITECTURES" == 'x86_64 arm64' ]] || fail install-verification-failed
FINAL_VERSION="$(/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C HOME="$TMP" \
  "$DESTINATION" --version 2>/dev/null)" || fail install-verification-failed
[[ "$FINAL_VERSION" == "Version: $XCODEGEN_VERSION" ]] || fail install-verification-failed

printf 'locked XcodeGen installed: Tools/bin/xcodegen + Tools/bin/%s/SettingPresets\n' "$RESOURCE_BUNDLE_NAME"
