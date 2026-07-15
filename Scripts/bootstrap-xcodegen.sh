#!/bin/bash
set -euo pipefail

export LC_ALL=C
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
unset BASH_ENV ENV CDPATH GLOBIGNORE PYTHONHOME PYTHONPATH
unset DEVELOPER_DIR SDKROOT TOOLCHAINS XCODE_DEFAULT_TOOLCHAIN_OVERRIDE
umask 077

fail() {
  if [[ "$1" == canonical-build-root-busy && -n "${CANONICAL_ROOT:-}" && -n "${CANONICAL_LOCK:-}" ]]; then
    printf 'XcodeGen bootstrap error: canonical-build-root-busy; after confirming no bootstrap is running, inspect the exact stale paths %s and %s\n' \
      "$CANONICAL_ROOT" "$CANONICAL_LOCK" >&2
  else
    printf 'XcodeGen bootstrap error: %s\n' "$1" >&2
  fi
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
INSTALL_TEMP=''
CANONICAL_ROOT=''
CANONICAL_LOCK=''
CANONICAL_OWNED=0
CANONICAL_LOCK_OWNED=0
cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "$INSTALL_TEMP" ]]; then
    /bin/rm -f "$INSTALL_TEMP"
  fi
  if [[ "$CANONICAL_OWNED" -eq 1 && "$CANONICAL_ROOT" == /private/tmp/utterink-xcodegen-bootstrap-* && ! -L "$CANONICAL_ROOT" ]]; then
    /bin/rm -rf "$CANONICAL_ROOT"
  fi
  if [[ "$CANONICAL_LOCK_OWNED" -eq 1 && "$CANONICAL_LOCK" == /private/tmp/utterink-xcodegen-bootstrap-*.lock && ! -L "$CANONICAL_LOCK" ]]; then
    /bin/rmdir "$CANONICAL_LOCK" 2>/dev/null || :
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
xcodegen = exact(top["xcodegen"], {"version", "sourceCommit", "archiveURL", "archiveSHA256", "binarySHA256"})
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
archive_url = f"https://github.com/yonaskolb/XcodeGen/archive/{source_commit}.tar.gz"
if xcodegen["archiveURL"] != archive_url:
    abort()
archive_sha = locked_string(xcodegen["archiveSHA256"], r"[0-9a-f]{64}")
binary_sha = locked_string(xcodegen["binarySHA256"], r"[0-9a-f]{64}")
if not test_mode:
    if source_commit != "8d3d3476a69ae3e5d68e1adccc701c410c05eb36":
        abort()
    if archive_sha != "afe64a4e9b14a91a113ae7bd2c156666ee9be51dfa84c9a6e89c89797e5d871c":
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
    "developer-dir": xcode["developerDir"],
    "source-commit": source_commit,
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
DEVELOPER_DIR_LOCKED="$(/bin/cat "$TMP/lock/developer-dir")"
SOURCE_COMMIT="$(/bin/cat "$TMP/lock/source-commit")"
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
  case "$TEST_ARCHIVE" in "$ROOT"/FixtureSource/*.tar.gz) ;; *) fail invalid-test-source ;; esac
  SWIFT="$TOOL_ROOT/swift"
  [[ -f "$SWIFT" && -x "$SWIFT" && ! -L "$SWIFT" ]] || fail swift-unavailable
else
  SWIFT="$DEVELOPER_DIR_LOCKED/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
  [[ -x "$SWIFT" ]] || fail swift-unavailable
  if ! /usr/bin/python3 -I - "$SWIFT" "$DEVELOPER_DIR_LOCKED" <<'PY' >/dev/null 2>&1
from pathlib import Path
import os
import sys

try:
    tool = Path(sys.argv[1]).resolve(strict=True)
    developer = Path(sys.argv[2]).resolve(strict=True)
    tool.relative_to(developer)
except (OSError, ValueError):
    raise SystemExit(1)
if not tool.is_file() or not os.access(tool, os.X_OK):
    raise SystemExit(1)
PY
  then
    fail swift-unavailable
  fi
fi

TOOLS_ROOT="$ROOT/Tools"
TOOLS_BIN="$TOOLS_ROOT/bin"
DESTINATION="$TOOLS_BIN/xcodegen"
[[ ! -L "$TOOLS_ROOT" && ! -L "$TOOLS_BIN" && ! -L "$DESTINATION" ]] || fail unsafe-install-path
/bin/mkdir -p "$TOOLS_BIN"
[[ -d "$TOOLS_ROOT" && -d "$TOOLS_BIN" && ! -L "$TOOLS_ROOT" && ! -L "$TOOLS_BIN" ]] || fail unsafe-install-path

if [[ -f "$DESTINATION" && -x "$DESTINATION" && ! -L "$DESTINATION" ]]; then
  EXISTING_SHA="$(/usr/bin/shasum -a 256 "$DESTINATION" | /usr/bin/awk 'NR == 1 { print $1 }')" || fail repository-xcodegen-unreadable
  EXISTING_VERSION="$(/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C HOME="$TMP" \
    "$DESTINATION" --version 2>/dev/null)" || EXISTING_VERSION=''
  if [[ "$EXISTING_SHA" == "$BINARY_SHA" && "$EXISTING_VERSION" == "Version: $XCODEGEN_VERSION" ]]; then
    printf 'locked XcodeGen already installed: Tools/bin/xcodegen\n'
    exit 0
  fi
elif [[ -e "$DESTINATION" ]]; then
  fail unsafe-install-path
fi

[[ -d /private/tmp && ! -L /private/tmp ]] || fail canonical-build-root-unavailable
# XcodeGen 2.45.4 uses #file at runtime, and Swift keeps that absolute source
# path in the Mach-O even with prefix-map flags. A commit-derived canonical
# root is therefore part of the reproducible binary-hash contract; the lock
# prevents two builds from sharing it, and the trap removes only roots created
# by this process.
CANONICAL_ROOT="/private/tmp/utterink-xcodegen-bootstrap-$SOURCE_COMMIT"
CANONICAL_LOCK="$CANONICAL_ROOT.lock"
if ! /bin/mkdir -m 0700 "$CANONICAL_LOCK" 2>/dev/null; then
  fail canonical-build-root-busy
fi
CANONICAL_LOCK_OWNED=1
[[ ! -e "$CANONICAL_ROOT" && ! -L "$CANONICAL_ROOT" ]] || fail canonical-build-root-busy
/bin/mkdir -m 0700 "$CANONICAL_ROOT" || fail canonical-build-root-unavailable
CANONICAL_OWNED=1
/bin/mkdir -m 0700 \
  "$CANONICAL_ROOT/source" \
  "$CANONICAL_ROOT/build" \
  "$CANONICAL_ROOT/home" \
  "$CANONICAL_ROOT/tmp" \
  "$CANONICAL_ROOT/swift-module-cache" \
  "$CANONICAL_ROOT/clang-module-cache" \
  "$CANONICAL_ROOT/swiftpm-cache" \
  "$CANONICAL_ROOT/swiftpm-config" \
  "$CANONICAL_ROOT/swiftpm-security" || fail canonical-build-root-unavailable
SOURCE_MAP="$CANONICAL_ROOT=/__UTTERINK_XCODEGEN_BUILD__"
SWIFT_BUILD_ENV=(
  PATH=/usr/bin:/bin:/usr/sbin:/sbin
  LC_ALL=C
  HOME="$CANONICAL_ROOT/home"
  XDG_CONFIG_HOME="$CANONICAL_ROOT/home"
  XDG_CACHE_HOME="$CANONICAL_ROOT/home/cache"
  TMPDIR="$CANONICAL_ROOT/tmp"
  DEVELOPER_DIR="$DEVELOPER_DIR_LOCKED"
  SWIFT_MODULECACHE_PATH="$CANONICAL_ROOT/swift-module-cache"
  CLANG_MODULE_CACHE_PATH="$CANONICAL_ROOT/clang-module-cache"
  SOURCE_DATE_EPOCH=0
  ZERO_AR_DATE=1
  GIT_CONFIG_GLOBAL=/dev/null
  GIT_CONFIG_SYSTEM=/dev/null
  GIT_TERMINAL_PROMPT=0
  GIT_NO_LAZY_FETCH=1
)

ARCHIVE_FILE="$TMP/XcodeGen.tar.gz"
if [[ "$TEST_MODE" -eq 1 ]]; then
  /bin/cp "$TEST_ARCHIVE" "$ARCHIVE_FILE" || fail source-copy-failed
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
    "$ARCHIVE_URL" || fail source-download-failed
fi

ACTUAL_ARCHIVE_SHA="$(/usr/bin/shasum -a 256 "$ARCHIVE_FILE" | /usr/bin/awk 'NR == 1 { print $1 }')" || fail archive-hash-unavailable
[[ "$ACTUAL_ARCHIVE_SHA" == "$ARCHIVE_SHA" ]] || fail archive-hash-mismatch

if ! /usr/bin/python3 -I - "$ARCHIVE_FILE" "XcodeGen-$SOURCE_COMMIT" <<'PY'
from __future__ import annotations

from pathlib import PurePosixPath
import sys
import tarfile


def normalized(path: PurePosixPath) -> PurePosixPath:
    parts: list[str] = []
    for part in path.parts:
        if part in ("", "."):
            continue
        if part == "..":
            if not parts:
                raise ValueError
            parts.pop()
        else:
            parts.append(part)
    return PurePosixPath(*parts)


archive_path, expected_root = sys.argv[1:]
try:
    with tarfile.open(archive_path, mode="r:gz") as archive:
        members = archive.getmembers()
        if not members or len(members) > 100_000:
            raise ValueError
        total_size = 0
        names: set[str] = set()
        for member in members:
            if "\x00" in member.name or member.name.startswith("/"):
                raise ValueError
            raw_member_path = PurePosixPath(member.name)
            if ".." in raw_member_path.parts:
                raise ValueError
            member_path = normalized(raw_member_path)
            normalized_name = member_path.as_posix()
            if normalized_name in names:
                raise ValueError
            names.add(normalized_name)
            if not member_path.parts or member_path.parts[0] != expected_root:
                raise ValueError
            if not (member.isdir() or member.isfile() or member.issym() or member.islnk()):
                raise ValueError
            if member.size < 0 or member.size > 128 * 1024 * 1024:
                raise ValueError
            total_size += member.size
            if total_size > 512 * 1024 * 1024:
                raise ValueError
            if member.issym() or member.islnk():
                if not member.linkname or member.linkname.startswith("/") or "\x00" in member.linkname:
                    raise ValueError
                if member.issym():
                    target = normalized(member_path.parent / PurePosixPath(member.linkname))
                else:
                    target = normalized(PurePosixPath(member.linkname))
                if not target.parts or target.parts[0] != expected_root:
                    raise ValueError
except (OSError, tarfile.TarError, ValueError):
    raise SystemExit(1)
PY
then
  fail unsafe-source-archive
fi

COPYFILE_DISABLE=1 /usr/bin/tar -xzf "$ARCHIVE_FILE" -C "$CANONICAL_ROOT/source" || fail source-extraction-failed
SOURCE_ROOT="$CANONICAL_ROOT/source/XcodeGen-$SOURCE_COMMIT"
[[ -d "$SOURCE_ROOT" && ! -L "$SOURCE_ROOT" && -f "$SOURCE_ROOT/Package.swift" && ! -L "$SOURCE_ROOT/Package.swift" ]] || fail source-layout-mismatch
[[ -f "$SOURCE_ROOT/Package.resolved" && ! -L "$SOURCE_ROOT/Package.resolved" ]] || fail source-resolution-missing

/usr/bin/env -i "${SWIFT_BUILD_ENV[@]}" \
  "$SWIFT" build \
    --package-path "$SOURCE_ROOT" \
    --cache-path "$CANONICAL_ROOT/swiftpm-cache" \
    --config-path "$CANONICAL_ROOT/swiftpm-config" \
    --security-path "$CANONICAL_ROOT/swiftpm-security" \
    --disable-dependency-cache \
    --configuration release \
    --product xcodegen \
    --scratch-path "$CANONICAL_ROOT/build" \
    --disable-sandbox \
    --force-resolved-versions \
    -Xswiftc -debug-prefix-map \
    -Xswiftc "$SOURCE_MAP" \
    -Xswiftc -file-prefix-map \
    -Xswiftc "$SOURCE_MAP" \
    -Xcc "-fdebug-prefix-map=$SOURCE_MAP" \
    -Xcc "-ffile-prefix-map=$SOURCE_MAP" || fail source-build-failed

BUILT_BIN_DIR="$(
  /usr/bin/env -i "${SWIFT_BUILD_ENV[@]}" \
    "$SWIFT" build \
      --package-path "$SOURCE_ROOT" \
      --cache-path "$CANONICAL_ROOT/swiftpm-cache" \
      --config-path "$CANONICAL_ROOT/swiftpm-config" \
      --security-path "$CANONICAL_ROOT/swiftpm-security" \
      --disable-dependency-cache \
      --configuration release \
      --product xcodegen \
      --scratch-path "$CANONICAL_ROOT/build" \
      --disable-sandbox \
      --force-resolved-versions \
      -Xswiftc -debug-prefix-map \
      -Xswiftc "$SOURCE_MAP" \
      -Xswiftc -file-prefix-map \
      -Xswiftc "$SOURCE_MAP" \
      -Xcc "-fdebug-prefix-map=$SOURCE_MAP" \
      -Xcc "-ffile-prefix-map=$SOURCE_MAP" \
      --show-bin-path
)" || fail built-binary-path-unavailable
[[ "$BUILT_BIN_DIR" == "$CANONICAL_ROOT/build"/* && -d "$BUILT_BIN_DIR" && ! -L "$BUILT_BIN_DIR" ]] || fail built-binary-path-invalid
BUILT_BINARY="$BUILT_BIN_DIR/xcodegen"
[[ -f "$BUILT_BINARY" && -x "$BUILT_BINARY" && ! -L "$BUILT_BINARY" ]] || fail built-binary-missing

ACTUAL_BINARY_SHA="$(/usr/bin/shasum -a 256 "$BUILT_BINARY" | /usr/bin/awk 'NR == 1 { print $1 }')" || fail built-binary-hash-unavailable
[[ "$ACTUAL_BINARY_SHA" == "$BINARY_SHA" ]] || fail built-binary-hash-mismatch
ACTUAL_VERSION="$(/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C HOME="$CANONICAL_ROOT/home" \
  "$BUILT_BINARY" --version 2>/dev/null)" || fail built-binary-version-unavailable
[[ "$ACTUAL_VERSION" == "Version: $XCODEGEN_VERSION" ]] || fail built-binary-version-mismatch

INSTALL_TEMP="$(/usr/bin/mktemp "$TOOLS_BIN/.xcodegen.XXXXXX")"
/bin/cp "$BUILT_BINARY" "$INSTALL_TEMP" || fail install-copy-failed
/bin/chmod 0755 "$INSTALL_TEMP" || fail install-mode-failed
INSTALLED_TEMP_SHA="$(/usr/bin/shasum -a 256 "$INSTALL_TEMP" | /usr/bin/awk 'NR == 1 { print $1 }')" || fail install-hash-unavailable
[[ "$INSTALLED_TEMP_SHA" == "$BINARY_SHA" ]] || fail install-hash-mismatch
/bin/mv -f "$INSTALL_TEMP" "$DESTINATION" || fail install-replace-failed
[[ -f "$DESTINATION" && -x "$DESTINATION" && ! -L "$DESTINATION" ]] || fail install-verification-failed
FINAL_SHA="$(/usr/bin/shasum -a 256 "$DESTINATION" | /usr/bin/awk 'NR == 1 { print $1 }')" || fail install-verification-failed
[[ "$FINAL_SHA" == "$BINARY_SHA" ]] || fail install-verification-failed

printf 'locked XcodeGen installed: Tools/bin/xcodegen\n'
