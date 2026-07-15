#!/bin/bash
set +x +v
set -euo pipefail

export LC_ALL=C
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
unset BASH_ENV ENV BASH_XTRACEFD PS4 CDPATH GLOBIGNORE PYTHONHOME PYTHONPATH
unset SDKROOT TOOLCHAINS XCODE_DEFAULT_TOOLCHAIN_OVERRIDE
umask 077

fail() {
  printf 'macOS 26 toolchain probe error: %s\n' "$1" >&2
  exit "${2:-1}"
}

[[ "$#" -eq 0 ]] || fail invalid-arguments 64

ROOT="$(cd "$(/usr/bin/dirname "$0")/../.." && /bin/pwd -P)"
cd "$ROOT"

APPROVED_BASELINE=fef9e537fdf673711be27983a8818155ad073f1b
PROBE_BRANCH=codex/macos26-toolchain-probe
PROBE_WORKFLOW=.github/workflows/macos26-toolchain-probe.yml
PROBE_SCRIPT=Scripts/release/probe-macos26-toolchain.sh
DEVELOPER_DIR_LOCKED=/Applications/Xcode_26.4.app/Contents/Developer
XCODEGEN_VERSION=2.45.4
XCODEGEN_COMMIT=8d3d3476a69ae3e5d68e1adccc701c410c05eb36
XCODEGEN_ARCHIVE_URL="https://github.com/yonaskolb/XcodeGen/archive/$XCODEGEN_COMMIT.tar.gz"
XCODEGEN_ARCHIVE_SHA=afe64a4e9b14a91a113ae7bd2c156666ee9be51dfa84c9a6e89c89797e5d871c

[[ "${GITHUB_ACTIONS:-}" == true ]] || fail github-actions-required
[[ "${GITHUB_EVENT_NAME:-}" == push ]] || fail unexpected-event
[[ "${GITHUB_REPOSITORY:-}" == kthree0213/UtterInk ]] || fail unexpected-repository
[[ "${GITHUB_REF_NAME:-}" == "$PROBE_BRANCH" ]] || fail unexpected-branch
[[ "${RUNNER_OS:-}" == macOS && "${RUNNER_ARCH:-}" == ARM64 ]] || fail unexpected-runner
[[ "${ImageOS:-}" == macos26 ]] || fail unexpected-runner-image
[[ "${UTTERINK_CI_RUNNER_LABEL:-}" == macos-26 ]] || fail unexpected-runner-label
[[ "${DEVELOPER_DIR:-}" == "$DEVELOPER_DIR_LOCKED" ]] || fail unexpected-developer-directory
[[ "${ImageVersion:-}" =~ ^([0-9]{8}[.][0-9]{4})([.][0-9]+)?$ ]] || fail invalid-runner-image-version
RUNNER_RELEASE="macos-26-arm64/${BASH_REMATCH[1]}"

HEAD_COMMIT="$(/usr/bin/git rev-parse --verify HEAD^{commit} 2>/dev/null)" || fail source-commit-unavailable
[[ "$HEAD_COMMIT" =~ ^[0-9a-f]{40}$ && "${GITHUB_SHA:-}" == "$HEAD_COMMIT" ]] || fail source-commit-mismatch
/usr/bin/git rev-parse --verify "$APPROVED_BASELINE^{commit}" >/dev/null 2>&1 || fail approved-baseline-unavailable
/usr/bin/git merge-base --is-ancestor "$APPROVED_BASELINE" "$HEAD_COMMIT" || fail approved-baseline-not-ancestor
[[ -z "$(/usr/bin/git status --porcelain=v1 --untracked-files=all)" ]] || fail dirty-checkout

ACTUAL_CHANGED_PATHS="$(/usr/bin/git diff --name-only "$APPROVED_BASELINE..$HEAD_COMMIT" | /usr/bin/sort)"
EXPECTED_CHANGED_PATHS="$(/usr/bin/printf '%s\n' "$PROBE_WORKFLOW" "$PROBE_SCRIPT" | /usr/bin/sort)"
[[ "$ACTUAL_CHANGED_PATHS" == "$EXPECTED_CHANGED_PATHS" ]] || fail unapproved-probe-diff
for path in "$PROBE_WORKFLOW" "$PROBE_SCRIPT"; do
  [[ -f "$path" && ! -L "$path" ]] || fail unsafe-probe-file
done

TMP="$(/usr/bin/mktemp -d "${RUNNER_TEMP:-/tmp}/utterink-macos26-probe.XXXXXX")"
CANONICAL_ROOT=''
CANONICAL_LOCK=''
CANONICAL_ROOT_OWNED=0
CANONICAL_LOCK_OWNED=0
cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$CANONICAL_ROOT_OWNED" -eq 1 && "$CANONICAL_ROOT" == /private/tmp/utterink-xcodegen-bootstrap-* && ! -L "$CANONICAL_ROOT" ]]; then
    /bin/rm -rf "$CANONICAL_ROOT"
  fi
  if [[ "$CANONICAL_LOCK_OWNED" -eq 1 && "$CANONICAL_LOCK" == /private/tmp/utterink-xcodegen-bootstrap-*.lock && ! -L "$CANONICAL_LOCK" ]]; then
    /bin/rmdir "$CANONICAL_LOCK" 2>/dev/null || :
  fi
  /bin/rm -rf "$TMP"
  exit "$status"
}
trap cleanup EXIT

/bin/mkdir -m 0700 \
  "$TMP/public-git-home" \
  "$TMP/repository-home" \
  "$TMP/repository-tmp" \
  "$TMP/repository-xdg-config" \
  "$TMP/repository-xdg-cache" \
  "$TMP/DerivedData" \
  "$TMP/SourcePackages" \
  "$TMP/build-home" \
  "$TMP/build-tmp" \
  "$TMP/build-xdg-config" \
  "$TMP/build-xdg-cache" \
  "$TMP/build-swift-module-cache" \
  "$TMP/build-clang-module-cache"

XCODEBUILD=/usr/bin/xcodebuild
SWIFT="$DEVELOPER_DIR_LOCKED/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
for tool in "$XCODEBUILD" /usr/bin/git /usr/bin/python3 /usr/bin/curl /usr/bin/file /usr/bin/id /usr/bin/lipo /usr/bin/otool; do
  [[ -f "$tool" && -x "$tool" && ! -L "$tool" ]] || fail required-tool-unavailable
done
BUILD_USER="$(/usr/bin/id -un 2> "$TMP/id-error")" || fail build-user-unavailable
[[ "$BUILD_USER" =~ ^[A-Za-z_][A-Za-z0-9_.-]{0,63}$ ]] || fail build-user-invalid
/usr/bin/python3 -I - "$SWIFT" "$DEVELOPER_DIR_LOCKED" <<'PY' || fail swift-unavailable
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

XCODE_OUTPUT="$(DEVELOPER_DIR="$DEVELOPER_DIR_LOCKED" "$XCODEBUILD" -version 2> "$TMP/xcode-error")" || fail xcode-unavailable
XCODE_VERSION="$(/usr/bin/printf '%s\n' "$XCODE_OUTPUT" | /usr/bin/sed -n '1s/^Xcode //p')"
XCODE_BUILD="$(/usr/bin/printf '%s\n' "$XCODE_OUTPUT" | /usr/bin/sed -n '2s/^Build version //p')"
[[ "$XCODE_OUTPUT" == "Xcode $XCODE_VERSION
Build version $XCODE_BUILD" ]] || fail invalid-xcode-output
[[ "$XCODE_VERSION" == 26.4.1 && "$XCODE_BUILD" == 17E202 ]] || fail xcode-mismatch

SDK_VERSION="$(DEVELOPER_DIR="$DEVELOPER_DIR_LOCKED" "$XCODEBUILD" -version -sdk macosx SDKVersion 2> "$TMP/sdk-error")" || fail sdk-unavailable
SDK_BUILD="$(DEVELOPER_DIR="$DEVELOPER_DIR_LOCKED" "$XCODEBUILD" -version -sdk macosx ProductBuildVersion 2>> "$TMP/sdk-error")" || fail sdk-unavailable
[[ "$SDK_VERSION" == 26.4 && "$SDK_BUILD" =~ ^[0-9]{2}[A-Z][0-9]{1,6}[a-z]?$ ]] || fail sdk-mismatch

"$SWIFT" --version > "$TMP/swift-version" 2> "$TMP/swift-error" || fail swift-unavailable
SWIFT_VERSION="$(/usr/bin/sed -n '1p' "$TMP/swift-version")"
/usr/bin/python3 -I - "$SWIFT_VERSION" <<'PY' || fail swift-version-invalid
import re
import sys

pattern = (
    r"(?:swift-driver version: [0-9]+(?:[.][0-9]+)* )?"
    r"Apple Swift version 6[.]3(?:[.][0-9]+)* "
    r"[(]swiftlang-[A-Za-z0-9.]+ clang-[A-Za-z0-9.]+[)]"
)
if re.fullmatch(pattern, sys.argv[1]) is None:
    raise SystemExit(1)
PY

OS_VERSION="$(/usr/bin/sw_vers -productVersion 2> "$TMP/sw-vers-error")" || fail os-version-unavailable
OS_BUILD="$(/usr/bin/sw_vers -buildVersion 2>> "$TMP/sw-vers-error")" || fail os-build-unavailable
UNAME_ARCH="$(/usr/bin/uname -m 2> "$TMP/uname-error")" || fail architecture-unavailable
[[ "$OS_VERSION" == 26.4 && "$OS_BUILD" =~ ^[0-9]{2}[A-Z][0-9]{1,6}[a-z]?$ && "$UNAME_ARCH" == arm64 ]] || fail runner-platform-mismatch

RUNNER_TAG_REF="refs/tags/$RUNNER_RELEASE"
if ! /usr/bin/env -i \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  LC_ALL=C \
  HOME="$TMP/public-git-home" \
  GIT_CONFIG_GLOBAL=/dev/null \
  GIT_CONFIG_SYSTEM=/dev/null \
  GIT_TERMINAL_PROMPT=0 \
  /usr/bin/git ls-remote --tags https://github.com/actions/runner-images.git \
    "$RUNNER_TAG_REF" "$RUNNER_TAG_REF^{}" \
    > "$TMP/runner-tag" 2> "$TMP/runner-tag-error"; then
  fail runner-release-unavailable
fi
RUNNER_COMMIT="$(/usr/bin/python3 -I - "$TMP/runner-tag" "$RUNNER_TAG_REF" <<'PY'
from pathlib import Path
import re
import sys

path, expected = sys.argv[1:]
direct = []
peeled = []
for line in Path(path).read_text(encoding="ascii").splitlines():
    fields = line.split("\t")
    if len(fields) != 2 or re.fullmatch(r"[0-9a-f]{40}", fields[0]) is None:
        raise SystemExit(1)
    if fields[1] == expected:
        direct.append(fields[0])
    elif fields[1] == expected + "^{}":
        peeled.append(fields[0])
    else:
        raise SystemExit(1)
if len(direct) != 1 or len(peeled) > 1:
    raise SystemExit(1)
print(peeled[0] if peeled else direct[0])
PY
)" || fail runner-release-invalid
[[ "$RUNNER_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail runner-release-invalid

[[ -d /private/tmp && ! -L /private/tmp ]] || fail canonical-build-root-unavailable
CANONICAL_ROOT="/private/tmp/utterink-xcodegen-bootstrap-$XCODEGEN_COMMIT"
CANONICAL_LOCK="$CANONICAL_ROOT.lock"
if ! /bin/mkdir -m 0700 "$CANONICAL_LOCK" 2>/dev/null; then
  fail canonical-build-root-busy
fi
CANONICAL_LOCK_OWNED=1
[[ ! -e "$CANONICAL_ROOT" && ! -L "$CANONICAL_ROOT" ]] || fail canonical-build-root-busy
/bin/mkdir -m 0700 "$CANONICAL_ROOT" || fail canonical-build-root-unavailable
CANONICAL_ROOT_OWNED=1
/bin/mkdir -m 0700 \
  "$CANONICAL_ROOT/source" \
  "$CANONICAL_ROOT/build" \
  "$CANONICAL_ROOT/home" \
  "$CANONICAL_ROOT/tmp" \
  "$CANONICAL_ROOT/swift-module-cache" \
  "$CANONICAL_ROOT/clang-module-cache" \
  "$CANONICAL_ROOT/swiftpm-cache" \
  "$CANONICAL_ROOT/swiftpm-config" \
  "$CANONICAL_ROOT/swiftpm-security"

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

XCODEGEN_ARCHIVE="$TMP/XcodeGen.tar.gz"
/usr/bin/curl \
  --disable \
  --fail \
  --location \
  --proto '=https' \
  --proto-redir '=https' \
  --silent \
  --show-error \
  --output "$XCODEGEN_ARCHIVE" \
  "$XCODEGEN_ARCHIVE_URL" 2> "$TMP/xcodegen-download-error" || fail xcodegen-download-failed
ACTUAL_ARCHIVE_SHA="$(/usr/bin/shasum -a 256 "$XCODEGEN_ARCHIVE" | /usr/bin/awk 'NR == 1 { print $1 }')" || fail xcodegen-archive-hash-unavailable
[[ "$ACTUAL_ARCHIVE_SHA" == "$XCODEGEN_ARCHIVE_SHA" ]] || fail xcodegen-archive-hash-mismatch

/usr/bin/python3 -I - "$XCODEGEN_ARCHIVE" "XcodeGen-$XCODEGEN_COMMIT" <<'PY' || fail unsafe-xcodegen-archive
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
            raw_path = PurePosixPath(member.name)
            if ".." in raw_path.parts:
                raise ValueError
            member_path = normalized(raw_path)
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
                target = normalized(
                    member_path.parent / PurePosixPath(member.linkname)
                    if member.issym()
                    else PurePosixPath(member.linkname)
                )
                if not target.parts or target.parts[0] != expected_root:
                    raise ValueError
except (OSError, tarfile.TarError, ValueError):
    raise SystemExit(1)
PY

COPYFILE_DISABLE=1 /usr/bin/tar -xzf "$XCODEGEN_ARCHIVE" -C "$CANONICAL_ROOT/source" \
  > "$TMP/xcodegen-extract-output" 2> "$TMP/xcodegen-extract-error" || fail xcodegen-extraction-failed
XCODEGEN_SOURCE_ROOT="$CANONICAL_ROOT/source/XcodeGen-$XCODEGEN_COMMIT"
[[ -d "$XCODEGEN_SOURCE_ROOT" && ! -L "$XCODEGEN_SOURCE_ROOT" ]] || fail xcodegen-source-layout-mismatch
[[ -f "$XCODEGEN_SOURCE_ROOT/Package.swift" && ! -L "$XCODEGEN_SOURCE_ROOT/Package.swift" ]] || fail xcodegen-source-layout-mismatch
[[ -f "$XCODEGEN_SOURCE_ROOT/Package.resolved" && ! -L "$XCODEGEN_SOURCE_ROOT/Package.resolved" ]] || fail xcodegen-resolution-missing

if ! /usr/bin/env -i "${SWIFT_BUILD_ENV[@]}" \
  "$SWIFT" build \
    --package-path "$XCODEGEN_SOURCE_ROOT" \
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
    > "$TMP/xcodegen-build-output" 2> "$TMP/xcodegen-build-error"; then
  fail xcodegen-build-failed
fi

XCODEGEN_BIN_DIR="$(/usr/bin/env -i "${SWIFT_BUILD_ENV[@]}" \
  "$SWIFT" build \
    --package-path "$XCODEGEN_SOURCE_ROOT" \
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
    --show-bin-path 2> "$TMP/xcodegen-bin-error")" || fail xcodegen-bin-path-unavailable
[[ "$XCODEGEN_BIN_DIR" == "$CANONICAL_ROOT/build"/* && -d "$XCODEGEN_BIN_DIR" && ! -L "$XCODEGEN_BIN_DIR" ]] || fail xcodegen-bin-path-invalid
XCODEGEN_BINARY="$XCODEGEN_BIN_DIR/xcodegen"
[[ -f "$XCODEGEN_BINARY" && -x "$XCODEGEN_BINARY" && ! -L "$XCODEGEN_BINARY" ]] || fail xcodegen-binary-missing
XCODEGEN_BINARY_SHA="$(/usr/bin/shasum -a 256 "$XCODEGEN_BINARY" | /usr/bin/awk 'NR == 1 { print $1 }')" || fail xcodegen-binary-hash-unavailable
[[ "$XCODEGEN_BINARY_SHA" =~ ^[0-9a-f]{64}$ ]] || fail xcodegen-binary-hash-invalid
ACTUAL_XCODEGEN_VERSION="$(/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C HOME="$CANONICAL_ROOT/home" "$XCODEGEN_BINARY" --version 2> "$TMP/xcodegen-version-error")" || fail xcodegen-version-unavailable
[[ "$ACTUAL_XCODEGEN_VERSION" == "Version: $XCODEGEN_VERSION" ]] || fail xcodegen-version-mismatch

if ! /usr/bin/env -i \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  LC_ALL=C \
  HOME="$TMP/repository-home" \
  CFFIXED_USER_HOME="$TMP/repository-home" \
  TMPDIR="$TMP/repository-tmp" \
  XDG_CONFIG_HOME="$TMP/repository-xdg-config" \
  XDG_CACHE_HOME="$TMP/repository-xdg-cache" \
  USER="$BUILD_USER" \
  LOGNAME="$BUILD_USER" \
  GIT_CONFIG_GLOBAL=/dev/null \
  GIT_CONFIG_SYSTEM=/dev/null \
  GIT_TERMINAL_PROMPT=0 \
  "$XCODEGEN_BINARY" generate \
  > "$TMP/project-generation-output" 2> "$TMP/project-generation-error"; then
  fail project-generation-failed
fi
[[ -z "$(/usr/bin/git status --porcelain=v1 --untracked-files=all)" ]] || fail generated-project-mismatch

XCODE_BUILD_ENV=(
  PATH=/usr/bin:/bin:/usr/sbin:/sbin
  LC_ALL=C
  HOME="$TMP/build-home"
  CFFIXED_USER_HOME="$TMP/build-home"
  TMPDIR="$TMP/build-tmp"
  XDG_CONFIG_HOME="$TMP/build-xdg-config"
  XDG_CACHE_HOME="$TMP/build-xdg-cache"
  USER="$BUILD_USER"
  LOGNAME="$BUILD_USER"
  DEVELOPER_DIR="$DEVELOPER_DIR_LOCKED"
  SWIFT_MODULECACHE_PATH="$TMP/build-swift-module-cache"
  CLANG_MODULE_CACHE_PATH="$TMP/build-clang-module-cache"
  GIT_CONFIG_GLOBAL=/dev/null
  GIT_CONFIG_SYSTEM=/dev/null
  GIT_TERMINAL_PROMPT=0
  GIT_NO_LAZY_FETCH=1
  GIT_NO_REPLACE_OBJECTS=1
  GIT_OPTIONAL_LOCKS=0
  PYTHONDONTWRITEBYTECODE=1
)

if ! /usr/bin/env -i "${XCODE_BUILD_ENV[@]}" "$XCODEBUILD" \
  -resolvePackageDependencies \
  -project UtterInk.xcodeproj \
  -scheme UtterInk \
  -clonedSourcePackagesDirPath "$TMP/SourcePackages" \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  > "$TMP/package-resolution-output" 2> "$TMP/package-resolution-error"; then
  fail package-resolution-failed
fi
[[ -z "$(/usr/bin/git status --porcelain=v1 --untracked-files=all)" ]] || fail package-resolution-mutated-source

ARCHIVE_PATH="$TMP/UtterInk.xcarchive"
if ! /usr/bin/env -i "${XCODE_BUILD_ENV[@]}" "$XCODEBUILD" archive \
  -project UtterInk.xcodeproj \
  -scheme UtterInk \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  -derivedDataPath "$TMP/DerivedData" \
  -clonedSourcePackagesDirPath "$TMP/SourcePackages" \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  OTHER_LDFLAGS=-Wl,-no_adhoc_codesign \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  DEVELOPMENT_TEAM= \
  PROVISIONING_PROFILE_SPECIFIER= \
  > "$TMP/archive-output" 2> "$TMP/archive-error"; then
  fail archive-failed
fi
[[ -z "$(/usr/bin/git status --porcelain=v1 --untracked-files=all)" ]] || fail archive-mutated-source

APP="$ARCHIVE_PATH/Products/Applications/UtterInk.app"
INFO_PLIST="$APP/Contents/Info.plist"
MAIN_EXECUTABLE="$APP/Contents/MacOS/UtterInk"
[[ -d "$ARCHIVE_PATH" && ! -L "$ARCHIVE_PATH" && -d "$APP" && ! -L "$APP" ]] || fail archive-layout-invalid
[[ -f "$INFO_PLIST" && ! -L "$INFO_PLIST" && -f "$MAIN_EXECUTABLE" && -x "$MAIN_EXECUTABLE" && ! -L "$MAIN_EXECUTABLE" ]] || fail archive-layout-invalid

/usr/bin/python3 -I - \
  "$ROOT/Config/release-info-policy.json" \
  "$INFO_PLIST" \
  "$ARCHIVE_PATH" \
  "$APP" \
  "$TMP/archive-inspection.json" <<'PY' || fail archive-inspection-failed
from __future__ import annotations

import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys


policy_path, info_path, archive_text, app_text, output_text = sys.argv[1:]
archive = Path(archive_text)
app = Path(app_text)
output = Path(output_text)


def abort() -> None:
    raise SystemExit(1)


def clean_relative(path: Path, root: Path) -> str:
    try:
        value = path.relative_to(root).as_posix()
    except ValueError:
        abort()
    if not value or value.startswith("/") or ".." in Path(value).parts:
        abort()
    value.encode("utf-8", errors="strict")
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        abort()
    return value


def run(tool: str, *arguments: str) -> str:
    result = subprocess.run(
        [tool, *arguments],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
        env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"},
    )
    if result.returncode != 0 or len(result.stdout) > 64 * 1024:
        abort()
    try:
        value = result.stdout.decode("utf-8", errors="strict").strip()
    except UnicodeError:
        abort()
    if not value or any(ord(character) < 32 and character not in "\t\n\r" for character in value):
        abort()
    return value


try:
    if Path(policy_path).stat().st_size > 128 * 1024 or Path(info_path).stat().st_size > 1024 * 1024:
        abort()
    policy = json.loads(Path(policy_path).read_text(encoding="utf-8"))
    with Path(info_path).open("rb") as handle:
        info = plistlib.load(handle)
except (OSError, UnicodeError, ValueError, json.JSONDecodeError, plistlib.InvalidFileException):
    abort()

if type(policy) is not dict or type(info) is not dict:
    abort()
owned = policy.get("archivedAppOwnedFields")
if type(owned) is not dict or set(owned) - set(info):
    abort()
for key, expected in owned.items():
    actual = info.get(key)
    if type(actual) is not type(expected) or actual != expected:
        abort()
if policy.get("finalShape") != "absent" or "NSAppTransportSecurity" in info:
    abort()

pending = [info]
seen: set[int] = set()
while pending:
    current = pending.pop()
    if type(current) is str and re.search(r"[$][(][^)]*[)]|[$][{][^}]*[}]", current):
        abort()
    if isinstance(current, dict):
        identity = id(current)
        if identity in seen:
            continue
        seen.add(identity)
        pending.extend(current.keys())
        pending.extend(current.values())
    elif isinstance(current, list):
        identity = id(current)
        if identity in seen:
            continue
        seen.add(identity)
        pending.extend(current)

reserved = {
    "NSAppTransportSecurity",
    "NSLocalNetworkUsageDescription",
    "NSAllowsLocalNetworking",
    "NSAllowsArbitraryLoads",
    "NSAllowsArbitraryLoadsForMedia",
    "NSAllowsArbitraryLoadsInWebContent",
    "NSExceptionDomains",
}
generated = sorted(set(info) - set(owned), key=lambda value: value.encode("utf-8"))
if any(
    type(key) is not str
    or re.fullmatch(r"[A-Za-z][A-Za-z0-9_.-]*", key) is None
    or key in reserved
    for key in generated
):
    abort()

sanitized_nodes = 0


def sanitize_generated_value(value: object, depth: int = 0) -> object:
    global sanitized_nodes
    sanitized_nodes += 1
    if sanitized_nodes > 1024 or depth > 12:
        abort()
    if type(value) is str:
        try:
            value.encode("utf-8", errors="strict")
        except UnicodeError:
            abort()
        if (
            len(value) > 4096
            or any(ord(character) < 32 or ord(character) == 127 for character in value)
            or value.startswith("/")
            or re.search(r"(?:^|/)(?:Users|private|tmp|var/folders)/", value)
        ):
            abort()
        return value
    if type(value) is bool or type(value) is int:
        return value
    if type(value) is float:
        if value != value or value in {float("inf"), float("-inf")}:
            abort()
        return value
    if type(value) is list:
        if len(value) > 256:
            abort()
        return [sanitize_generated_value(item, depth + 1) for item in value]
    if type(value) is dict:
        if len(value) > 256:
            abort()
        result: dict[str, object] = {}
        for key in sorted(value, key=lambda item: str(item).encode("utf-8")):
            if type(key) is not str or re.fullmatch(r"[A-Za-z][A-Za-z0-9_.-]*", key) is None:
                abort()
            result[key] = sanitize_generated_value(value[key], depth + 1)
        return result
    abort()


generated_fields = {key: sanitize_generated_value(info[key]) for key in generated}

signable_bundle_suffixes = {".app", ".appex", ".framework", ".plugin", ".xpc"}
signable_bundle_records: list[dict[str, str]] = []
resource_bundle_records: list[str] = []
macho_records: list[dict[str, object]] = []
main_archive_path = "Products/Applications/UtterInk.app/Contents/MacOS/UtterInk"

for current, directory_names, file_names in os.walk(archive, topdown=True, followlinks=False):
    current_path = Path(current)
    try:
        current_metadata = os.lstat(current_path)
    except OSError:
        abort()
    if not stat.S_ISDIR(current_metadata.st_mode) or stat.S_ISLNK(current_metadata.st_mode):
        abort()
    directory_names.sort(key=lambda value: os.fsencode(value))
    file_names.sort(key=lambda value: os.fsencode(value))
    for name in directory_names:
        path = current_path / name
        try:
            metadata = os.lstat(path)
        except OSError:
            abort()
        if path.name in {"_CodeSignature", "CodeResources"}:
            abort()
        if stat.S_ISLNK(metadata.st_mode):
            target = Path(os.readlink(path))
            if target.is_absolute() or ".." in target.parts:
                abort()
            try:
                path.resolve(strict=True).relative_to(archive.resolve(strict=True))
            except (OSError, RuntimeError, ValueError):
                abort()
        elif not stat.S_ISDIR(metadata.st_mode):
            abort()
        if app in path.parents and path.suffix in signable_bundle_suffixes:
            signable_bundle_records.append({"kind": "bundle", "path": clean_relative(path, app)})
        elif app in path.parents and path.suffix == ".bundle":
            resource_bundle_records.append(clean_relative(path, app))
    for name in file_names:
        path = current_path / name
        try:
            metadata = os.lstat(path)
        except OSError:
            abort()
        if path.name in {"_CodeSignature", "CodeResources"}:
            abort()
        if stat.S_ISLNK(metadata.st_mode):
            target = Path(os.readlink(path))
            if target.is_absolute() or ".." in target.parts:
                abort()
            try:
                path.resolve(strict=True).relative_to(archive.resolve(strict=True))
            except (OSError, RuntimeError, ValueError):
                abort()
            continue
        if not stat.S_ISREG(metadata.st_mode):
            abort()
        description = run("/usr/bin/file", "-b", str(path))
        if "Mach-O" not in description:
            if app in path.parents and metadata.st_mode & stat.S_IXUSR:
                abort()
            continue
        architectures = run("/usr/bin/lipo", "-archs", str(path)).split()
        if architectures != ["arm64"]:
            abort()
        load_commands = run("/usr/bin/otool", "-l", str(path))
        if re.search(r"(?m)^\s*cmd\s+LC_CODE_SIGNATURE\s*$", load_commands):
            abort()
        archive_relative = clean_relative(path, archive)
        macho_records.append(
            {
                "architecture": "arm64",
                "archivePath": archive_relative,
                "fileType": description,
                "hasCodeSignature": False,
            }
        )

macho_records.sort(key=lambda item: str(item["archivePath"]).encode("utf-8"))
main_matches = [item for item in macho_records if item["archivePath"] == main_archive_path]
if len(main_matches) != 1:
    abort()
app_prefix = "Products/Applications/UtterInk.app/"
nested_macho = []
for item in macho_records:
    archive_path_value = str(item["archivePath"])
    if archive_path_value.startswith(app_prefix) and archive_path_value != main_archive_path:
        nested_macho.append(
            {
                "architecture": "arm64",
                "fileType": item["fileType"],
                "kind": "mach-o",
                "path": archive_path_value.removeprefix(app_prefix),
            }
        )

nested = signable_bundle_records + nested_macho
nested.sort(key=lambda item: (str(item["path"]).encode("utf-8"), str(item["kind"])))
resource_bundle_records.sort(key=lambda value: value.encode("utf-8"))
result = {
    "archiveGeneratedFields": generated_fields,
    "archiveGeneratedKeyAllowlist": generated,
    "archiveMachOCount": len(macho_records),
    "mainMachO": {
        "architecture": "arm64",
        "fileType": main_matches[0]["fileType"],
        "hasCodeSignature": False,
        "path": "Contents/MacOS/UtterInk",
    },
    "nestedComponents": nested,
    "observedGeneratedKeysMatchCurrentLock": generated == policy.get("archiveGeneratedKeyAllowlist"),
    "resourceBundles": resource_bundle_records,
}
output.write_text(json.dumps(result, sort_keys=True, separators=(",", ":")), encoding="utf-8")
PY

set +e
/usr/bin/python3 -I - \
  "$TMP/archive-inspection.json" \
  "$APPROVED_BASELINE" \
  "$HEAD_COMMIT" \
  "${ImageOS}" \
  "${ImageVersion}" \
  "$RUNNER_RELEASE" \
  "$RUNNER_COMMIT" \
  "$OS_VERSION" \
  "$OS_BUILD" \
  "$UNAME_ARCH" \
  "$XCODE_VERSION" \
  "$XCODE_BUILD" \
  "$DEVELOPER_DIR_LOCKED" \
  "$SDK_VERSION" \
  "$SDK_BUILD" \
  "$SWIFT_VERSION" \
  "$XCODEGEN_VERSION" \
  "$XCODEGEN_COMMIT" \
  "$XCODEGEN_ARCHIVE_URL" \
  "$XCODEGEN_ARCHIVE_SHA" \
  "$XCODEGEN_BINARY_SHA" <<'PY'
from __future__ import annotations

import json
from pathlib import Path
import re
import sys


(
    inspection_path,
    baseline,
    probe_commit,
    image_os,
    image_version,
    runner_release,
    runner_commit,
    os_version,
    os_build,
    uname_architecture,
    xcode_version,
    xcode_build,
    developer_dir,
    sdk_version,
    sdk_build,
    swift_version,
    xcodegen_version,
    xcodegen_commit,
    archive_url,
    archive_sha,
    binary_sha,
) = sys.argv[1:]

try:
    inspection = json.loads(Path(inspection_path).read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError):
    raise SystemExit(1)

hex40 = r"[0-9a-f]{40}"
hex64 = r"[0-9a-f]{64}"
if any(re.fullmatch(hex40, value) is None for value in (baseline, probe_commit, runner_commit, xcodegen_commit)):
    raise SystemExit(1)
if any(re.fullmatch(hex64, value) is None for value in (archive_sha, binary_sha)):
    raise SystemExit(1)
if inspection.get("nestedComponents") is None or type(inspection["nestedComponents"]) is not list:
    raise SystemExit(1)

report = {
    "archive": {
        "architecture": "arm64",
        "archiveGeneratedFields": inspection["archiveGeneratedFields"],
        "archiveGeneratedKeyAllowlist": inspection["archiveGeneratedKeyAllowlist"],
        "archiveMachOCount": inspection["archiveMachOCount"],
        "configuration": "Release",
        "generatedKeyLockMatches": inspection["observedGeneratedKeysMatchCurrentLock"],
        "mainMachO": inspection["mainMachO"],
        "nestedComponents": inspection["nestedComponents"],
        "nestedComponentLockMatches": not inspection["nestedComponents"],
        "releasePolicyReady": (
            inspection["observedGeneratedKeysMatchCurrentLock"]
            and not inspection["nestedComponents"]
        ),
        "resourceBundles": inspection["resourceBundles"],
        "unsigned": True,
    },
    "runnerImage": {
        "architecture": uname_architecture,
        "commit": runner_commit,
        "imageOS": image_os,
        "imageVersion": image_version,
        "label": "macos-26",
        "osBuild": os_build,
        "osVersion": os_version,
        "releaseTag": runner_release,
    },
    "schemaVersion": 1,
    "sdk": {"build": sdk_build, "version": sdk_version},
    "source": {"approvedBaseline": baseline, "probeCommit": probe_commit},
    "sources": {
        "runnerReadme": f"https://github.com/actions/runner-images/blob/{runner_commit}/images/macos/macos-26-arm64-Readme.md",
        "runnerRelease": f"https://github.com/actions/runner-images/releases/tag/{runner_release.replace('/', '%2F')}",
        "xcodegenCommit": f"https://github.com/yonaskolb/XcodeGen/commit/{xcodegen_commit}",
        "xcodegenRelease": f"https://github.com/yonaskolb/XcodeGen/releases/tag/{xcodegen_version}",
    },
    "swift": {"version": swift_version},
    "xcode": {"build": xcode_build, "developerDir": developer_dir, "version": xcode_version},
    "xcodegen": {
        "archiveSHA256": archive_sha,
        "archiveURL": archive_url,
        "binarySHA256": binary_sha,
        "sourceCommit": xcodegen_commit,
        "version": xcodegen_version,
    },
}
print("UTTERINK_TOOLCHAIN_PROBE_JSON_BEGIN")
print(json.dumps(report, ensure_ascii=True, sort_keys=True, separators=(",", ":")))
print("UTTERINK_TOOLCHAIN_PROBE_JSON_END")
raise SystemExit(0 if report["archive"]["nestedComponentLockMatches"] else 3)
PY
REPORT_STATUS=$?
set -e
[[ "$REPORT_STATUS" -eq 0 ]] || exit "$REPORT_STATUS"
