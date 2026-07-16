#!/bin/bash
set -euo pipefail

export LC_ALL=C
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
unset BASH_ENV ENV CDPATH GLOBIGNORE PYTHONHOME PYTHONPATH
INCOMING_DEVELOPER_DIR="${DEVELOPER_DIR:-}"
unset DEVELOPER_DIR SDKROOT TOOLCHAINS XCODE_DEFAULT_TOOLCHAIN_OVERRIDE
umask 077

fail() {
  local category="$1"
  local status="${2:-1}"
  case "$category" in
    repository-xcodegen-missing|repository-xcodegen-mismatch|repository-xcodegen-unusable)
      printf 'toolchain verification error: %s; run ./Scripts/bootstrap-xcodegen.sh\n' "$category" >&2
      ;;
    invalid-arguments)
      printf 'toolchain verification error: invalid-arguments; expected --context ci|local\n' >&2
      ;;
    *)
      printf 'toolchain verification error: %s; use a dedicated reviewed Config/ci-toolchain.json update\n' "$category" >&2
      ;;
  esac
  exit "$status"
}

[[ "$#" -eq 2 && "$1" == '--context' ]] || fail invalid-arguments 64
CONTEXT="$2"
case "$CONTEXT" in
  ci|local) ;;
  *) fail invalid-arguments 64 ;;
esac

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

TMP="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/utterink-toolchain-verify.XXXXXX")"
cleanup() {
  local status=$?
  trap - EXIT
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
image_version = locked_string(runner["imageVersion"], r"[0-9]{8}[.][0-9]{4}(?:[.][0-9]+)?")
if runner["osVersion"] != "26.4":
    abort()
os_build = locked_string(runner["osBuild"], r"[0-9]{2}[A-Z][0-9]{1,6}[a-z]?")

if xcode != {
    "version": "26.4.1",
    "build": "17E202",
    "developerDir": "/Applications/Xcode_26.4.app/Contents/Developer",
}:
    abort()
if sdk["version"] != "26.4":
    abort()
sdk_build = locked_string(sdk["build"], r"[0-9]{2}[A-Z][0-9]{1,6}[a-z]?")
swift_version = locked_string(
    swift["version"],
    r"(?:swift-driver version: [0-9]+(?:[.][0-9]+)* )?Apple Swift version 6[.]3(?:[.][0-9]+)* [(]swiftlang-[A-Za-z0-9.]+ clang-[A-Za-z0-9.]+[)]",
)

if xcodegen["version"] != "2.45.4":
    abort()
source_commit = locked_string(xcodegen["sourceCommit"], r"[0-9a-f]{40}")
if set(source_commit) == {"0"}:
    abort()
archive_sha = locked_string(xcodegen["archiveSHA256"], r"[0-9a-f]{64}")
binary_sha = locked_string(xcodegen["binarySHA256"], r"[0-9a-f]{64}")
setting_presets_sha = locked_string(xcodegen["settingPresetsSHA256"], r"[0-9a-f]{64}")
archive_url = f"https://github.com/yonaskolb/XcodeGen/releases/download/{xcodegen['version']}/xcodegen.zip"
if xcodegen["archiveURL"] != archive_url:
    abort()
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
    "architecture": runner["architecture"],
    "binary-sha": binary_sha,
    "developer-dir": xcode["developerDir"],
    "image-os": runner["label"].replace("-", ""),
    "image-version": image_version,
    "os-build": os_build,
    "os-version": runner["osVersion"],
    "runner-label": runner["label"],
    "sdk-build": sdk_build,
    "sdk-version": sdk["version"],
    "swift-version": swift_version,
    "setting-presets-sha": setting_presets_sha,
    "xcode-build": xcode["build"],
    "xcode-version": xcode["version"],
    "xcodegen-version": xcodegen["version"],
}
for name, value in fields.items():
    (output / name).write_text(value, encoding="utf-8")
PY
then
  fail toolchain-lock-invalid
fi

locked() {
  /bin/cat "$TMP/lock/$1"
}

ARCHITECTURE="$(locked architecture)"
BINARY_SHA="$(locked binary-sha)"
DEVELOPER_DIR_LOCKED="$(locked developer-dir)"
IMAGE_OS="$(locked image-os)"
IMAGE_VERSION="$(locked image-version)"
OS_BUILD="$(locked os-build)"
OS_VERSION="$(locked os-version)"
RUNNER_LABEL="$(locked runner-label)"
SDK_BUILD="$(locked sdk-build)"
SDK_VERSION="$(locked sdk-version)"
SWIFT_VERSION="$(locked swift-version)"
SETTING_PRESETS_SHA="$(locked setting-presets-sha)"
XCODE_BUILD="$(locked xcode-build)"
XCODE_VERSION="$(locked xcode-version)"
XCODEGEN_VERSION="$(locked xcodegen-version)"

if [[ "$TEST_MODE" -eq 1 ]]; then
  TOOL_ROOT="${UTTERINK_TOOLCHAIN_TEST_TOOL_ROOT:-}"
  case "$ROOT" in
    /tmp/*|/private/tmp/*|/private/var/folders/*/T/*) ;;
    *) fail test-mode-not-allowed ;;
  esac
  [[ "$TOOL_ROOT" == /* && -d "$TOOL_ROOT" && ! -L "$TOOL_ROOT" ]] || fail invalid-test-tool-root
  TOOL_ROOT="$(cd "$TOOL_ROOT" && /bin/pwd -P)"
  [[ "$TOOL_ROOT" == "$ROOT/FixtureTools" ]] || fail invalid-test-tool-root
  [[ -f "$TOOL_ROOT/.utterink-toolchain-test-fixture" && ! -L "$TOOL_ROOT/.utterink-toolchain-test-fixture" ]] || fail invalid-test-tool-root
  [[ "$(/bin/cat "$TOOL_ROOT/.utterink-toolchain-test-fixture")" == utterink-offline-toolchain-fixture-v1 ]] || fail invalid-test-tool-root
  XCODEBUILD="$TOOL_ROOT/xcodebuild"
  SWIFT="$TOOL_ROOT/swift"
  UNAME="$TOOL_ROOT/uname"
  SW_VERS="$TOOL_ROOT/sw_vers"
  for tool in "$XCODEBUILD" "$SWIFT" "$UNAME" "$SW_VERS"; do
    [[ -f "$tool" && -x "$tool" && ! -L "$tool" ]] || fail invalid-test-tool-root
  done
else
  XCODEBUILD=/usr/bin/xcodebuild
  SWIFT="$DEVELOPER_DIR_LOCKED/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
  UNAME=/usr/bin/uname
  SW_VERS=/usr/bin/sw_vers
  [[ -x "$XCODEBUILD" && -x "$SWIFT" && -x "$UNAME" && -x "$SW_VERS" ]] || fail locked-tool-unavailable
  if ! /usr/bin/python3 -I - "$SWIFT" "$DEVELOPER_DIR_LOCKED" <<'PY' >/dev/null 2>&1
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
    fail locked-tool-unavailable
  fi
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

XCODEGEN="$ROOT/Tools/bin/xcodegen"
XCODEGEN_BUNDLE="$ROOT/Tools/bin/XcodeGen_XcodeGenKit.bundle"
XCODEGEN_SETTING_PRESETS="$XCODEGEN_BUNDLE/SettingPresets"
[[ ! -L "$ROOT/Tools" \
  && ! -L "$ROOT/Tools/bin" \
  && ! -L "$XCODEGEN" \
  && ! -L "$XCODEGEN_BUNDLE" \
  && ! -L "$XCODEGEN_SETTING_PRESETS" ]] || fail repository-xcodegen-unusable
[[ -f "$XCODEGEN" && -x "$XCODEGEN" ]] || fail repository-xcodegen-missing
[[ -d "$XCODEGEN_BUNDLE" && -d "$XCODEGEN_SETTING_PRESETS" ]] || fail repository-xcodegen-missing
ACTUAL_BINARY_SHA="$(/usr/bin/shasum -a 256 "$XCODEGEN" | /usr/bin/awk 'NR == 1 { print $1 }')" || fail repository-xcodegen-unusable
[[ "$ACTUAL_BINARY_SHA" == "$BINARY_SHA" ]] || fail repository-xcodegen-mismatch
ACTUAL_SETTING_PRESETS_SHA="$(companion_bundle_tree_hash "$XCODEGEN_BUNDLE")" || fail repository-xcodegen-unusable
[[ "$ACTUAL_SETTING_PRESETS_SHA" == "$SETTING_PRESETS_SHA" ]] || fail repository-xcodegen-mismatch
ACTUAL_XCODEGEN_VERSION="$(/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C HOME="$TMP" \
  "$XCODEGEN" --version 2>/dev/null)" || fail repository-xcodegen-unusable
[[ "$ACTUAL_XCODEGEN_VERSION" == "Version: $XCODEGEN_VERSION" ]] || fail repository-xcodegen-mismatch

ACTUAL_ARCHITECTURE="$({ "$UNAME" -m; } 2>/dev/null)" || fail architecture-unavailable
[[ "$ACTUAL_ARCHITECTURE" == "$ARCHITECTURE" ]] || fail architecture-mismatch

DEVELOPER_DIR="$DEVELOPER_DIR_LOCKED" "$XCODEBUILD" -version > "$TMP/xcode-version" 2> "$TMP/tool-error" || fail xcode-unavailable
ACTUAL_XCODE="$(/bin/cat "$TMP/xcode-version")"
[[ "$ACTUAL_XCODE" == "Xcode $XCODE_VERSION
Build version $XCODE_BUILD" ]] || fail xcode-mismatch

DEVELOPER_DIR="$DEVELOPER_DIR_LOCKED" "$XCODEBUILD" -version -sdk macosx SDKVersion > "$TMP/sdk-version" 2> "$TMP/tool-error" || fail sdk-unavailable
ACTUAL_SDK_VERSION="$(/bin/cat "$TMP/sdk-version")"
[[ "$ACTUAL_SDK_VERSION" == "$SDK_VERSION" ]] || fail sdk-mismatch
DEVELOPER_DIR="$DEVELOPER_DIR_LOCKED" "$XCODEBUILD" -version -sdk macosx ProductBuildVersion > "$TMP/sdk-build" 2> "$TMP/tool-error" || fail sdk-unavailable
ACTUAL_SDK_BUILD="$(/bin/cat "$TMP/sdk-build")"
[[ "$ACTUAL_SDK_BUILD" == "$SDK_BUILD" ]] || fail sdk-mismatch

DEVELOPER_DIR="$DEVELOPER_DIR_LOCKED" "$SWIFT" --version > "$TMP/swift-version" 2> "$TMP/tool-error" || fail swift-unavailable
ACTUAL_SWIFT_VERSION="$(/usr/bin/sed -n '1p' "$TMP/swift-version")"
[[ "$ACTUAL_SWIFT_VERSION" == "$SWIFT_VERSION" ]] || fail swift-mismatch

ACTUAL_OS_VERSION="$({ "$SW_VERS" -productVersion; } 2>/dev/null)" || fail os-version-unavailable
ACTUAL_OS_BUILD="$({ "$SW_VERS" -buildVersion; } 2>/dev/null)" || fail os-build-unavailable

if [[ "$CONTEXT" == ci ]]; then
  [[ "$INCOMING_DEVELOPER_DIR" == "$DEVELOPER_DIR_LOCKED" ]] || fail runner-environment-mismatch
  [[ "${UTTERINK_CI_RUNNER_LABEL:-}" == "$RUNNER_LABEL" ]] || fail runner-environment-mismatch
  [[ "${RUNNER_OS:-}" == macOS ]] || fail runner-environment-mismatch
  [[ "${RUNNER_ARCH:-}" == ARM64 ]] || fail runner-environment-mismatch
  [[ "${ImageOS:-}" == "$IMAGE_OS" ]] || fail runner-environment-mismatch
  [[ "${ImageVersion:-}" == "$IMAGE_VERSION" ]] || fail runner-environment-mismatch
  [[ "$ACTUAL_OS_VERSION" == "$OS_VERSION" && "$ACTUAL_OS_BUILD" == "$OS_BUILD" ]] || fail runner-environment-mismatch
  printf 'toolchain verified: context=ci runner=%s image=%s osBuild=%s architecture=%s\n' \
    "$RUNNER_LABEL" "$IMAGE_VERSION" "$ACTUAL_OS_BUILD" "$ACTUAL_ARCHITECTURE"
else
  printf 'toolchain verified: context=local osVersion=%s osBuild=%s architecture=%s\n' \
    "$ACTUAL_OS_VERSION" "$ACTUAL_OS_BUILD" "$ACTUAL_ARCHITECTURE"
fi
