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
    PATH|LC_ALL|UTTERINK_RELEASE_ENV_CLEAN|UTTERINK_RELEASE_TEST_MODE|UTTERINK_RELEASE_TEST_TOOL_ROOT|UTTERINK_FIXTURE_LOG|PWD|SHLVL|_) ;;
    *)
      printf 'release candidate error: unsafe-launch-environment\n' >&2
      exit 2
      ;;
  esac
done < <(/usr/bin/env -0)
unset UTTERINK_RELEASE_ENV_CLEAN

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
    --expected-origin)
      [[ -z "$EXPECTED_ORIGIN" && "$#" -ge 2 && -n "$2" ]] || fail invalid-arguments 2
      EXPECTED_ORIGIN="$2"
      shift 2
      ;;
    *) fail invalid-arguments 2 ;;
  esac
done

[[ "$COMMIT" =~ ^[0-9a-f]{40}$ && -n "$OUTPUT" ]] || fail invalid-arguments 2

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

ROOT="$($GIT rev-parse --show-toplevel 2>/dev/null)" || fail not-a-repository
SCRIPT_ROOT="$(cd "$(/usr/bin/dirname "$0")/../.." && pwd -P)"
[[ "$ROOT" == "$SCRIPT_ROOT" ]] || fail repository-mismatch
cd "$ROOT"

TMP="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/utterink-release-candidate.XXXXXX")"
cleanup() {
  local status=$?
  trap - EXIT
  /bin/rm -rf "$TMP"
  exit "$status"
}
trap cleanup EXIT
/bin/mkdir -p "$TMP/empty-home" "$TMP/tool-tmp"
export HOME="$TMP/empty-home"
export XDG_CONFIG_HOME="$TMP/empty-home"
export TMPDIR="$TMP/tool-tmp"

validate_local_git_config() {
  local config_keys="$TMP/local-git-config-keys"
  local key
  [[ -d "$ROOT/.git" && ! -L "$ROOT/.git" ]] || fail unsafe-git-config 20
  [[ -f "$ROOT/.git/config" && ! -L "$ROOT/.git/config" ]] || fail unsafe-git-config 20
  [[ ! -e "$ROOT/.git/config.worktree" && ! -e "$ROOT/.git/commondir" ]] || fail unsafe-git-config 20
  $GIT config --local --no-includes --name-only --list -z > "$config_keys" 2>/dev/null || fail unsafe-git-config 20
  while IFS= read -r -d '' key; do
    case "$key" in
      core.repositoryformatversion|core.filemode|core.bare|core.logallrefupdates|core.ignorecase|core.precomposeunicode|user.name|user.email) ;;
      remote.*.url|remote.*.fetch)
        [[ "$key" =~ ^remote\.[A-Za-z0-9._-]+\.(url|fetch)$ ]] || fail unsafe-git-config 20
        ;;
      branch.*.remote|branch.*.merge)
        [[ "$key" =~ ^branch\.[A-Za-z0-9._/-]+\.(remote|merge)$ ]] || fail unsafe-git-config 20
        ;;
      *) fail unsafe-git-config 20 ;;
    esac
  done < "$config_keys"
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
      .superpowers/*|Config/legacy-rights.local.tsv|Tools/bin/xcodegen|.release-work/*) ;;
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

if ! "$PYTHON" -I - Config/ci-toolchain.json "$TMP/expected-xcodegen-sha" <<'PY' > "$TMP/lock-preflight-output" 2>&1
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
xcodegen = exact(top["xcodegen"], {"version", "sourceCommit", "archiveURL", "archiveSHA256", "binarySHA256"})
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
}:
    abort()
binary_hash = xcodegen.get("binarySHA256")
if type(binary_hash) is not str or re.fullmatch(r"[0-9a-f]{64}", binary_hash) is None:
    abort()
if sources != {
    "runnerRelease": "https://github.com/actions/runner-images/releases/tag/macos-26-arm64%2F20260630.0213",
    "runnerReadme": "https://github.com/actions/runner-images/blob/afadebc447d1a69fc726b50cd5aba055c0cfdf82/images/macos/macos-26-arm64-Readme.md",
    "xcodegenRelease": "https://github.com/yonaskolb/XcodeGen/releases/tag/2.45.4",
    "xcodegenCommit": "https://github.com/yonaskolb/XcodeGen/commit/8d3d3476a69ae3e5d68e1adccc701c410c05eb36",
}:
    abort()
output_path.write_text(binary_hash + "\n", encoding="utf-8")
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
else
  DEVELOPER_DIR_LOCKED=/Applications/Xcode_26.4.app/Contents/Developer
  XCODEBUILD=/usr/bin/xcodebuild
  SWIFT="$DEVELOPER_DIR_LOCKED/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
  XCODEGEN_SOURCE="$ROOT/Tools/bin/xcodegen"
fi
if [[ "$TEST_MODE" -eq 1 ]]; then
  for tool in "$XCODEBUILD" "$SWIFT" "$XCODEGEN_SOURCE"; do
    [[ -f "$tool" && -x "$tool" && ! -L "$tool" ]] || fail toolchain-unavailable 24
  done
  for tool in "$TOOL_ROOT_REL/xcodebuild" "$TOOL_ROOT_REL/swift" "$TOOL_ROOT_REL/xcodegen"; do
    verify_commit_file "$tool" || fail invalid-test-tool-root 24
  done
else
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

XCODEGEN="$TMP/xcodegen"
/bin/cp "$XCODEGEN_SOURCE" "$XCODEGEN" || fail toolchain-unavailable 24
/bin/chmod 0700 "$XCODEGEN" || fail toolchain-unavailable 24
EXPECTED_XCODEGEN_HASH="$(/bin/cat "$TMP/expected-xcodegen-sha")"
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
  shift
  if [[ "$TEST_MODE" -eq 1 ]]; then
    [[ "${UTTERINK_FIXTURE_LOG:-}" == /* ]] || return 1
    /usr/bin/env -i \
      PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      HOME="$TMP/empty-home" \
      TMPDIR="$TMP/history-tmp" \
      LC_ALL=C \
      UTTERINK_FIXTURE_LOG="$UTTERINK_FIXTURE_LOG" \
      /bin/bash Scripts/scan-public-history.sh "$@" > "$output" 2>&1
  else
    /usr/bin/env -i \
      PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      HOME="$TMP/empty-home" \
      TMPDIR="$TMP/history-tmp" \
      LC_ALL=C \
      /bin/bash Scripts/scan-public-history.sh "$@" > "$output" 2>&1
  fi
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

if ! "$PYTHON" -I - \
  Config/ci-toolchain.json \
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
    {"version", "sourceCommit", "archiveURL", "archiveSHA256", "binarySHA256"},
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

if ! "$PYTHON" -I Scripts/release/read-metadata.py --json > "$TMP/metadata.json" 2> "$TMP/metadata-error"; then
  fail metadata-mismatch 23
fi
if ! "$PYTHON" -I Scripts/release/verify-entitlements.py > "$TMP/entitlements-output" 2> "$TMP/entitlements-error"; then
  fail entitlement-policy-failed 26
fi
if ! "$PYTHON" -I Scripts/release/verify-info-policy.py > "$TMP/info-output" 2> "$TMP/info-error"; then
  fail info-policy-failed 26
fi

PACKAGE_HASH_BEFORE="$($SHASUM -a 256 "$PACKAGE_RESOLUTION" | /usr/bin/awk '{print $1}')" || fail package-resolution-mismatch 22
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
PACKAGE_HASH_AFTER="$($SHASUM -a 256 "$PACKAGE_RESOLUTION" | /usr/bin/awk '{print $1}')" || fail package-resolution-mismatch 22
[[ "$PACKAGE_HASH_AFTER" == "$PACKAGE_HASH_BEFORE" ]] || fail package-resolution-mismatch 22
generated_tree_is_clean || fail package-resolution-mismatch 22

[[ "$($SHASUM -a 256 "$XCODEGEN" | /usr/bin/awk '{print $1}')" == "$EXPECTED_XCODEGEN_HASH" ]] || fail toolchain-mismatch 24
if ! "$XCODEGEN" generate > "$TMP/xcodegen-output" 2> "$TMP/xcodegen-error"; then
  fail generated-project-mismatch 27
fi
[[ "$($SHASUM -a 256 "$XCODEGEN" | /usr/bin/awk '{print $1}')" == "$EXPECTED_XCODEGEN_HASH" ]] || fail toolchain-mismatch 24
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
TREE="$($GIT rev-parse "$COMMIT^{tree}")" || fail source-identity-failed
LOCK_HASH="$($SHASUM -a 256 Config/ci-toolchain.json | /usr/bin/awk '{print $1}')" || fail evidence-generation-failed
METADATA_POLICY_HASH="$($SHASUM -a 256 Config/release-metadata.json | /usr/bin/awk '{print $1}')" || fail evidence-generation-failed
ENTITLEMENTS_POLICY_HASH="$($SHASUM -a 256 Config/release-entitlements.json | /usr/bin/awk '{print $1}')" || fail evidence-generation-failed
INFO_POLICY_HASH="$($SHASUM -a 256 Config/release-info-policy.json | /usr/bin/awk '{print $1}')" || fail evidence-generation-failed

if ! "$PYTHON" -I - \
  docs/release/evidence-schema.json \
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
if ! "$PYTHON" -I - "$OUTPUT_ABSOLUTE" "$TMP/candidate.json" <<'PY' >/dev/null 2>&1
from __future__ import annotations

import os
from pathlib import Path
import secrets
import stat
import sys


def abort() -> None:
    raise SystemExit(1)


output = Path(sys.argv[1])
source = Path(sys.argv[2])
if not output.is_absolute() or not source.is_absolute() or output == Path(output.anchor):
    abort()

read_flags = os.O_RDONLY | os.O_NOFOLLOW
try:
    source_fd = os.open(source, read_flags)
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
finally:
    os.close(source_fd)

directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
try:
    directory_fd = os.open(output.anchor, directory_flags)
except OSError:
    abort()
created = False
temporary_name: str | None = None
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

    directory = os.fstat(directory_fd)
    if directory.st_uid != os.geteuid() or directory.st_mode & 0o022:
        abort()
    if created:
        os.fchmod(directory_fd, 0o755)

    try:
        existing = os.stat("candidate.json", dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        existing = None
    except OSError:
        abort()
    if existing is not None and (
        not stat.S_ISREG(existing.st_mode)
        or existing.st_uid != os.geteuid()
        or existing.st_mode & 0o022
    ):
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

    os.replace(
        temporary_name,
        "candidate.json",
        src_dir_fd=directory_fd,
        dst_dir_fd=directory_fd,
    )
    temporary_name = None
finally:
    if temporary_name is not None:
        try:
            os.unlink(temporary_name, dir_fd=directory_fd)
        except OSError:
            pass
    os.close(directory_fd)
PY
then
  fail unsafe-output 29
fi

exit 0
