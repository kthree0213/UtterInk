#!/usr/bin/env -S -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u BASH_XTRACEFD -u PS4 -u POSIXLY_CORRECT -u BASH_COMPAT -u UTTERINK_SIGN_ENV_CLEAN /bin/bash -p

set +x +v
if [[ "$-" != *p* ]]; then
  printf 'candidate signing error: unsafe-launch-environment\n' >&2
  exit 2
fi
if [[ "${UTTERINK_SIGN_ENV_CLEAN:-}" != 1 ]]; then
  clean_environment=(
    PATH=/usr/bin:/bin:/usr/sbin:/sbin
    LC_ALL=C
    UTTERINK_SIGN_ENV_CLEAN=1
  )
  for allowed_name in \
    UTTERINK_RELEASE_TEST_MODE \
    UTTERINK_RELEASE_TEST_TOOL_ROOT \
    UTTERINK_FIXTURE_LOG; do
    if [[ -n "${!allowed_name+x}" ]]; then
      clean_environment+=("$allowed_name=${!allowed_name}")
    fi
  done
  exec /usr/bin/env -i "${clean_environment[@]}" /bin/bash -p "$0" "$@"
  printf 'candidate signing error: unsafe-launch-environment\n' >&2
  exit 2
fi
if [[ "$-" != hpB || "${PATH-}" != /usr/bin:/bin:/usr/sbin:/sbin || "${LC_ALL-}" != C ]]; then
  printf 'candidate signing error: unsafe-launch-environment\n' >&2
  exit 2
fi
while IFS= read -r -d '' environment_entry; do
  environment_name="${environment_entry%%=*}"
  case "$environment_name" in
    PATH|LC_ALL|UTTERINK_SIGN_ENV_CLEAN|UTTERINK_RELEASE_TEST_MODE|UTTERINK_RELEASE_TEST_TOOL_ROOT|UTTERINK_FIXTURE_LOG|PWD|SHLVL|_) ;;
    *)
      printf 'candidate signing error: unsafe-launch-environment\n' >&2
      exit 2
      ;;
  esac
done < <(/usr/bin/env -0)
unset UTTERINK_SIGN_ENV_CLEAN

set -euo pipefail

export LC_ALL=C
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PYTHONDONTWRITEBYTECODE=1
unset \
  BASH_ENV ENV CDPATH GLOBIGNORE PYTHONHOME PYTHONPATH \
  DEVELOPER_DIR SDKROOT TOOLCHAINS XCODE_DEFAULT_TOOLCHAIN_OVERRIDE \
  DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH
umask 077

fail() {
  local category="$1"
  local status="${2:-1}"
  printf 'candidate signing error: %s\n' "$category" >&2
  exit "$status"
}

CANDIDATE_ARGUMENT=''
IDENTITY=''
TEAM_ID=''
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --candidate)
      [[ -z "$CANDIDATE_ARGUMENT" && "$#" -ge 2 && -n "$2" ]] || fail invalid-arguments 2
      CANDIDATE_ARGUMENT="$2"
      shift 2
      ;;
    --identity)
      [[ -z "$IDENTITY" && "$#" -ge 2 && -n "$2" ]] || fail invalid-arguments 2
      IDENTITY="$2"
      shift 2
      ;;
    --team-id)
      [[ -z "$TEAM_ID" && "$#" -ge 2 && -n "$2" ]] || fail invalid-arguments 2
      TEAM_ID="$2"
      shift 2
      ;;
    *) fail invalid-arguments 2 ;;
  esac
done

[[ -n "$CANDIDATE_ARGUMENT" && -n "$IDENTITY" && -n "$TEAM_ID" ]] || fail invalid-arguments 2
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || fail invalid-team-id 2
[[ "$IDENTITY" != '-' && "$IDENTITY" == 'Developer ID Application: '* ]] || fail invalid-identity 2
[[ "$IDENTITY" == *" ($TEAM_ID)" ]] || fail identity-team-mismatch 2
[[ "${#IDENTITY}" -le 512 ]] || fail invalid-identity 2
case "$IDENTITY" in
  *$'\n'*|*$'\r'*|*$'\t'*) fail invalid-identity 2 ;;
esac

readonly SCRIPT_PATH="${BASH_SOURCE[0]}"
[[ -f "$SCRIPT_PATH" && ! -L "$SCRIPT_PATH" ]] || fail unsafe-script-path 20
SCRIPT_DIRECTORY="$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "$SCRIPT_PATH")" && /bin/pwd -P)" ||
  fail unsafe-script-path 20
ROOT="$(CDPATH= cd -P -- "$SCRIPT_DIRECTORY/../.." && /bin/pwd -P)" || fail unsafe-script-path 20
GIT_ROOT="$(/usr/bin/git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" || fail not-a-repository 20
GIT_ROOT="$(CDPATH= cd -P -- "$GIT_ROOT" && /bin/pwd -P)" || fail not-a-repository 20
[[ "$GIT_ROOT" == "$ROOT" ]] || fail repository-mismatch 20
cd "$ROOT"

POLICY_PATH="$ROOT/Config/release-entitlements.json"
ENTITLEMENTS="$ROOT/App/Supporting/UtterInk.entitlements"
ENTITLEMENT_VERIFIER="$ROOT/Scripts/release/verify-entitlements.py"

if ! CANDIDATE="$(/usr/bin/python3 -I - "$ROOT" "$CANDIDATE_ARGUMENT" <<'PY'
from __future__ import annotations

import os
from pathlib import Path, PurePath
import stat
import sys


root = Path(sys.argv[1])
raw = sys.argv[2]
if (
    not raw
    or len(raw.encode("utf-8", errors="strict")) > 4096
    or any(ord(character) < 32 or ord(character) == 127 for character in raw)
    or ".." in PurePath(raw).parts
):
    raise SystemExit(1)
candidate = Path(raw) if os.path.isabs(raw) else root / raw
candidate = Path(os.path.abspath(candidate))
try:
    relative = candidate.relative_to(root)
except ValueError:
    raise SystemExit(1)
if len(relative.parts) < 2 or relative.parts[0] != ".release-work":
    raise SystemExit(1)
root_metadata = os.lstat(root)
current = root
for component in relative.parts:
    current /= component
    try:
        metadata = os.lstat(current)
    except OSError:
        raise SystemExit(1)
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_dev != root_metadata.st_dev
        or metadata.st_uid != os.geteuid()
        or metadata.st_mode & 0o022
    ):
        raise SystemExit(1)
print(candidate)
PY
)"; then
  fail unsafe-candidate 21
fi
readonly CANDIDATE
APP="$CANDIDATE/UtterInk.app"
EVIDENCE="$CANDIDATE/signature-verification.json"
UNSIGNED_EVIDENCE="$CANDIDATE/unsigned-build-evidence.json"
[[ -d "$APP" && ! -L "$APP" && -f "$UNSIGNED_EVIDENCE" && ! -L "$UNSIGNED_EVIDENCE" && \
  ! -e "$EVIDENCE" && ! -L "$EVIDENCE" ]] || fail invalid-candidate 21

TEST_MODE=0
case "${UTTERINK_RELEASE_TEST_MODE:-}" in
  '') ;;
  1) TEST_MODE=1 ;;
  *) fail invalid-test-mode 20 ;;
esac
if [[ "$TEST_MODE" -eq 1 ]]; then
  case "$ROOT" in
    /private/tmp/utterink-sign-candidate-tests.*/*) ;;
    *) fail test-mode-not-allowed 20 ;;
  esac
  TOOL_ROOT="${UTTERINK_RELEASE_TEST_TOOL_ROOT:-}"
  [[ "$TOOL_ROOT" == "$ROOT/FixtureTools" && -d "$TOOL_ROOT" && ! -L "$TOOL_ROOT" ]] ||
    fail invalid-test-tool-root 20
  MARKER="$TOOL_ROOT/.utterink-signing-test-fixture"
  [[ -f "$MARKER" && ! -L "$MARKER" ]] || fail invalid-test-tool-root 20
  [[ "$(/bin/cat "$MARKER")" == utterink-offline-signing-fixture-v1 ]] || fail invalid-test-tool-root 20
  [[ "${UTTERINK_FIXTURE_LOG:-}" == /private/tmp/* ]] || fail invalid-test-tool-root 20
  SECURITY="$TOOL_ROOT/security"
  OPENSSL="$TOOL_ROOT/openssl"
  FILE_TOOL="$TOOL_ROOT/file"
  LIPO="$TOOL_ROOT/lipo"
  CODESIGN="$TOOL_ROOT/codesign"
  VERIFIER="$TOOL_ROOT/verify-signatures.sh"
  MUTATION_HOOK="$TOOL_ROOT/mutation-hook"
else
  unset UTTERINK_RELEASE_TEST_TOOL_ROOT UTTERINK_FIXTURE_LOG
  SECURITY=/usr/bin/security
  OPENSSL=/usr/bin/openssl
  FILE_TOOL=/usr/bin/file
  LIPO=/usr/bin/lipo
  CODESIGN=/usr/bin/codesign
  VERIFIER="$ROOT/Scripts/release/verify-signatures.sh"
  MUTATION_HOOK=''
fi
for tool in "$SECURITY" "$OPENSSL" "$FILE_TOOL" "$LIPO" "$CODESIGN" "$VERIFIER"; do
  [[ -f "$tool" && -x "$tool" && ! -L "$tool" ]] || fail signing-tool-unavailable 20
done
if [[ "$TEST_MODE" -eq 1 ]]; then
  [[ -f "$MUTATION_HOOK" && -x "$MUTATION_HOOK" && ! -L "$MUTATION_HOOK" ]] ||
    fail signing-tool-unavailable 20
fi
readonly TEST_MODE SECURITY OPENSSL FILE_TOOL LIPO CODESIGN VERIFIER MUTATION_HOOK

[[ -d /private/tmp && ! -L /private/tmp ]] || fail temporary-directory-unavailable 20
CONTROL="$(/usr/bin/mktemp -d /private/tmp/utterink-sign-candidate.XXXXXX)" ||
  fail temporary-directory-unavailable 20
[[ "$CONTROL" == /private/tmp/utterink-sign-candidate.* && -d "$CONTROL" && ! -L "$CONTROL" ]] ||
  fail temporary-directory-unavailable 20
/bin/chmod 0700 "$CONTROL" || fail temporary-directory-unavailable 20
exec 9< "$CONTROL" || fail temporary-directory-unavailable 20
if ! read -r CONTROL_DEV CONTROL_INO < <(/usr/bin/stat -f '%d %i' "$CONTROL"); then
  exec 9<&-
  fail temporary-directory-unavailable 20
fi
[[ "$CONTROL_DEV" =~ ^[0-9]+$ && "$CONTROL_INO" =~ ^[0-9]+$ ]] || {
  exec 9<&-
  fail temporary-directory-unavailable 20
}
readonly CONTROL CONTROL_DEV CONTROL_INO
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  if ! /usr/bin/python3 -I - "$CONTROL_DEV" "$CONTROL_INO" 9 <<'PY' >/dev/null 2>&1
from __future__ import annotations

import os
import stat
import sys


expected = (int(sys.argv[1]), int(sys.argv[2]))
control_fd = int(sys.argv[3])


def clear_directory(descriptor: int) -> None:
    for name in os.listdir(descriptor):
        if not name or name in {".", ".."} or "/" in name or "\0" in name:
            raise OSError
        metadata = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        if stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode):
            child = os.open(
                name,
                os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=descriptor,
            )
            try:
                opened = os.fstat(child)
                if (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino):
                    raise OSError
                clear_directory(child)
            finally:
                os.close(child)
            os.rmdir(name, dir_fd=descriptor)
        else:
            os.unlink(name, dir_fd=descriptor)


opened = os.fstat(control_fd)
if (opened.st_dev, opened.st_ino) != expected or not stat.S_ISDIR(opened.st_mode):
    raise SystemExit(1)
clear_directory(control_fd)

# The pathname may have been renamed or replaced. Remove only the directory
# whose saved device/inode matches the retained descriptor; never a replacement.
parent_fd = os.open(
    "/private/tmp",
    os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
)
try:
    matches: list[str] = []
    for name in os.listdir(parent_fd):
        if not name.startswith("utterink-sign-candidate."):
            continue
        try:
            item = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        except OSError:
            continue
        if (item.st_dev, item.st_ino) == expected and stat.S_ISDIR(item.st_mode):
            matches.append(name)
    if len(matches) != 1:
        raise OSError
    os.rmdir(matches[0], dir_fd=parent_fd)
finally:
    os.close(parent_fd)
PY
  then
    printf 'candidate signing error: cleanup-failed\n' >&2
    status=40
  fi
  if [[ -n "${PINNED_VERIFIER_PARENT_DEV:-}" && -n "${PINNED_VERIFIER_PARENT_INO:-}" && \
    -n "${PINNED_VERIFIER_DIRECTORY_NAME:-}" && -n "${PINNED_VERIFIER_DIRECTORY_DEV:-}" && \
    -n "${PINNED_VERIFIER_DIRECTORY_INO:-}" && -n "${PINNED_VERIFIER_NAME:-}" && \
    -n "${PINNED_VERIFIER_DEV:-}" && -n "${PINNED_VERIFIER_INO:-}" ]]; then
    if ! /usr/bin/python3 -I - \
      "$PINNED_VERIFIER_PARENT_DEV" "$PINNED_VERIFIER_PARENT_INO" \
      "$PINNED_VERIFIER_DIRECTORY_NAME" "$PINNED_VERIFIER_DIRECTORY_DEV" \
      "$PINNED_VERIFIER_DIRECTORY_INO" "$PINNED_VERIFIER_NAME" \
      "$PINNED_VERIFIER_DEV" "$PINNED_VERIFIER_INO" 7 6 8 <<'PY' >/dev/null 2>&1
import os
import stat
import sys

parent_expected = (int(sys.argv[1]), int(sys.argv[2]))
directory_name = sys.argv[3]
directory_expected = (int(sys.argv[4]), int(sys.argv[5]))
file_name = sys.argv[6]
file_expected = (int(sys.argv[7]), int(sys.argv[8]))
parent_fd, directory_fd, file_fd = map(int, sys.argv[9:12])
if (
    not directory_name.startswith(".utterink-verifier-pinned.")
    or "/" in directory_name
    or not file_name
    or file_name != "verify-signatures.sh"
):
    raise SystemExit(1)
parent = os.fstat(parent_fd)
directory = os.fstat(directory_fd)
opened_file = os.fstat(file_fd)
if (
    (parent.st_dev, parent.st_ino) != parent_expected
    or not stat.S_ISDIR(parent.st_mode)
    or parent.st_uid != os.geteuid()
    or parent.st_mode & 0o022
    or (directory.st_dev, directory.st_ino) != directory_expected
    or not stat.S_ISDIR(directory.st_mode)
    or directory.st_uid != os.geteuid()
    or stat.S_IMODE(directory.st_mode) != 0o700
    or (opened_file.st_dev, opened_file.st_ino) != file_expected
    or not stat.S_ISREG(opened_file.st_mode)
    or opened_file.st_uid != os.geteuid()
):
    raise SystemExit(1)

# The original pinned bytes may already be unlinked by os.replace(). Wipe that
# retained inode, then remove whatever non-directory object now occupies the
# one controlled basename inside the exact retained private directory.
os.ftruncate(file_fd, 0)
os.fsync(file_fd)
entries = os.listdir(directory_fd)
if any(not name or name in {".", ".."} or "/" in name or "\0" in name for name in entries):
    raise OSError
if set(entries) - {file_name}:
    raise OSError
if file_name in entries:
    replacement = os.stat(file_name, dir_fd=directory_fd, follow_symlinks=False)
    if replacement.st_uid != os.geteuid() or stat.S_ISDIR(replacement.st_mode):
        raise OSError
    os.unlink(file_name, dir_fd=directory_fd)
if os.listdir(directory_fd):
    raise OSError

# Locate and remove only the private directory whose retained descriptor and
# saved inode identify this signer invocation. A replacement at its old path is
# never followed or removed.
matches = []
for name in os.listdir(parent_fd):
    if not name.startswith(".utterink-verifier-pinned."):
        continue
    try:
        item = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except OSError:
        continue
    if (item.st_dev, item.st_ino) == directory_expected and stat.S_ISDIR(item.st_mode):
        matches.append(name)
if len(matches) != 1:
    raise OSError
os.rmdir(matches[0], dir_fd=parent_fd)
PY
    then
      printf 'candidate signing error: cleanup-failed\n' >&2
      status=40
    fi
  fi
  exec 8>&- 2>/dev/null || :
  exec 6<&- 2>/dev/null || :
  exec 7<&- 2>/dev/null || :
  exec 9<&-
  exit "$status"
}
handle_signal() {
  local status="$1"
  trap - HUP INT TERM
  exit "$status"
}
trap cleanup EXIT
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

# Bind signing to the exact reviewed source commit and policy evidence before
# identity discovery or candidate inventory can reach codesign. The manifest
# is opened without following symlinks, duplicate JSON keys are rejected, and
# all allowlisted evidence fields are parsed with exact types and values.
if ! /usr/bin/python3 -I - \
  "$CANDIDATE/candidate.json" "$TEST_MODE" \
  "$CONTROL/source-commit" "$CONTROL/policy-sha256" \
  "$CONTROL/candidate-json-sha256" "$CONTROL/source-tree" <<'PY' >/dev/null 2>&1
from __future__ import annotations

import json
import hashlib
import os
from pathlib import Path
import re
import stat
import sys


MAX_BYTES = 256 * 1024


def abort() -> None:
    raise SystemExit(1)


def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            abort()
        result[key] = value
    return result


def exact_object(value: object, keys: set[str]) -> dict[str, object]:
    if type(value) is not dict or set(value) != keys:
        abort()
    return value


def exact_string(value: object, pattern: str) -> str:
    if type(value) is not str or re.fullmatch(pattern, value) is None:
        abort()
    return value


path = Path(sys.argv[1])
test_mode = sys.argv[2] == "1"
try:
    before = os.lstat(path)
    if (
        not stat.S_ISREG(before.st_mode)
        or stat.S_ISLNK(before.st_mode)
        or before.st_nlink != 1
        or before.st_uid != os.geteuid()
        or before.st_mode & 0o022
        or before.st_size > MAX_BYTES
    ):
        abort()
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            abort()
        chunks: list[bytes] = []
        remaining = MAX_BYTES + 1
        while remaining:
            chunk = os.read(descriptor, min(65536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    fingerprint = lambda item: (
        item.st_dev, item.st_ino, item.st_mode, item.st_uid, item.st_nlink,
        item.st_size, item.st_mtime_ns, item.st_ctime_ns,
    )
    if fingerprint(before) != fingerprint(opened) or fingerprint(opened) != fingerprint(after):
        abort()
    data = b"".join(chunks)
    if len(data) > MAX_BYTES:
        abort()
    value = json.loads(data.decode("utf-8", errors="strict"), object_pairs_hook=unique_object)
except (OSError, UnicodeError, json.JSONDecodeError):
    abort()

top = exact_object(value, {
    "schemaVersion", "evidenceType", "product", "source", "release", "toolchain",
    "packageResolution", "policies", "checks",
})
if type(top["schemaVersion"]) is not int or top["schemaVersion"] != 1:
    abort()
expected_evidence_type = "release-candidate-test" if test_mode else "release-candidate"
if top["evidenceType"] != expected_evidence_type or type(top["evidenceType"]) is not str:
    abort()
if top["product"] != "UtterInk" or type(top["product"]) is not str:
    abort()

source = exact_object(top["source"], {"commit", "tree", "releaseTag", "clean"})
commit = exact_string(source["commit"], r"[0-9a-f]{40}")
source_tree = exact_string(source["tree"], r"[0-9a-f]{40}")
if source["releaseTag"] != "v0.1.0" or type(source["releaseTag"]) is not str or source["clean"] is not True:
    abort()

release = exact_object(top["release"], {
    "configuration", "marketingVersion", "buildNumber", "bundleIdentifier",
    "deploymentTarget", "architecture", "dmgFilename",
})
expected_release = {
    "configuration": "Release",
    "marketingVersion": "0.1.0",
    "buildNumber": "1",
    "bundleIdentifier": "dev.utterink.UtterInk",
    "deploymentTarget": "14.0",
    "architecture": "arm64",
    "dmgFilename": "UtterInk-0.1.0-arm64.dmg",
}
if release != expected_release or any(type(item) is not str for item in release.values()):
    abort()

toolchain = exact_object(top["toolchain"], {
    "lockSHA256", "xcodeVersion", "xcodeBuild", "sdkVersion", "sdkBuild",
    "swiftVersion", "xcodegenVersion", "xcodegenBinarySHA256",
})
for key in ("lockSHA256", "xcodegenBinarySHA256"):
    exact_string(toolchain[key], r"[0-9a-f]{64}")
if (
    toolchain["xcodeVersion"] != "26.4.1"
    or toolchain["xcodeBuild"] != "17E202"
    or toolchain["sdkVersion"] != "26.4"
    or toolchain["xcodegenVersion"] != "2.45.4"
    or any(type(toolchain[key]) is not str for key in ("xcodeVersion", "xcodeBuild", "sdkVersion", "xcodegenVersion"))
):
    abort()
exact_string(toolchain["sdkBuild"], r"[0-9]{2}[A-Z][0-9]{1,4}[a-z]?")
exact_string(
    toolchain["swiftVersion"],
    r"(?:swift-driver version: [0-9]+(?:\.[0-9]+)* )?Apple Swift version 6\.3(?:\.[0-9]+)* \(swiftlang-[A-Za-z0-9.]+ clang-[A-Za-z0-9.]+\)",
)

package = exact_object(top["packageResolution"], {"path", "sha256"})
if package["path"] != "Packages/UtterInkKit/Package.resolved" or type(package["path"]) is not str:
    abort()
exact_string(package["sha256"], r"[0-9a-f]{64}")

policies = exact_object(top["policies"], {
    "releaseMetadataSHA256", "releaseEntitlementsSHA256",
    "releaseInfoPolicySHA256", "ciToolchainSHA256",
})
for key, item in policies.items():
    exact_string(item, r"[0-9a-f]{64}")
policy_sha256 = policies["releaseEntitlementsSHA256"]

checks = exact_object(top["checks"], {
    "history", "metadata", "entitlements", "infoPolicy",
    "packageResolution", "generatedProjectClean",
})
if any(item is not True for item in checks.values()):
    abort()

try:
    Path(sys.argv[3]).write_text(commit, encoding="ascii")
    Path(sys.argv[4]).write_text(policy_sha256, encoding="ascii")
    Path(sys.argv[5]).write_text(hashlib.sha256(data).hexdigest(), encoding="ascii")
    Path(sys.argv[6]).write_text(source_tree, encoding="ascii")
except OSError:
    abort()
PY
then
  fail invalid-candidate-evidence 22
fi
SOURCE_COMMIT="$(/bin/cat "$CONTROL/source-commit")"
POLICY_SHA256="$(/bin/cat "$CONTROL/policy-sha256")"
CANDIDATE_JSON_SHA256="$(/bin/cat "$CONTROL/candidate-json-sha256")"
SOURCE_TREE="$(/bin/cat "$CONTROL/source-tree")"
readonly SOURCE_COMMIT POLICY_SHA256 CANDIDATE_JSON_SHA256 SOURCE_TREE

HEAD_COMMIT="$(
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_NO_REPLACE_OBJECTS=1 \
    /usr/bin/git -C "$ROOT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null
)" || fail candidate-commit-mismatch 22
[[ "$HEAD_COMMIT" == "$SOURCE_COMMIT" ]] || fail candidate-commit-mismatch 22
COMMIT_TREE="$(
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_NO_REPLACE_OBJECTS=1 \
    /usr/bin/git -C "$ROOT" rev-parse --verify "$SOURCE_COMMIT^{tree}" 2>/dev/null
)" || fail candidate-tree-mismatch 22
[[ "$COMMIT_TREE" == "$SOURCE_TREE" ]] || fail candidate-tree-mismatch 22

# Bind the unsigned app to the build-stage evidence before any identity lookup
# or signing operation. This is the shared utterink-logical-tree-v1 contract:
# root excluded, UTF-8 byte ordering, and compact JSON-lines records.
if ! /usr/bin/python3 -I - \
  "$UNSIGNED_EVIDENCE" "$APP" "$SOURCE_COMMIT" "$CANDIDATE_JSON_SHA256" \
  "$CONTROL/unsigned-build-evidence-sha256" <<'PY' >/dev/null 2>&1
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys


MAX_EVIDENCE_BYTES = 64 * 1024


def abort() -> None:
    raise SystemExit(1)


def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, item in pairs:
        if key in value:
            abort()
        value[key] = item
    return value


def fingerprint(item: os.stat_result) -> tuple[int, ...]:
    return (
        item.st_dev, item.st_ino, item.st_mode, item.st_uid, item.st_nlink,
        item.st_size, item.st_mtime_ns, item.st_ctime_ns,
    )


def read_regular(path: Path, maximum: int | None = None) -> tuple[bytes, os.stat_result]:
    before = os.lstat(path)
    if (
        not stat.S_ISREG(before.st_mode)
        or stat.S_ISLNK(before.st_mode)
        or before.st_nlink != 1
        or before.st_uid != os.geteuid()
        or before.st_mode & 0o022
        or (maximum is not None and before.st_size > maximum)
    ):
        abort()
    descriptor = os.open(
        path,
        os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        opened = os.fstat(descriptor)
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, 65536)
            if not chunk:
                break
            total += len(chunk)
            if maximum is not None and total > maximum:
                abort()
            chunks.append(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    if fingerprint(before) != fingerprint(opened) or fingerprint(opened) != fingerprint(after):
        abort()
    return b"".join(chunks), after


def checked_symlink_target(relative: str, raw_target: str) -> str:
    if (
        not raw_target
        or len(raw_target.encode("utf-8", errors="strict")) > 4096
        or PurePosixPath(raw_target).is_absolute()
        or any(ord(character) < 32 or ord(character) == 127 for character in raw_target)
        or ".." in PurePosixPath(raw_target).parts
    ):
        abort()
    joined = PurePosixPath(relative).parent.joinpath(PurePosixPath(raw_target))
    if joined.is_absolute() or ".." in joined.parts:
        abort()
    return raw_target


def logical_tree(root: Path) -> str:
    root_metadata = os.lstat(root)
    if (
        not stat.S_ISDIR(root_metadata.st_mode)
        or stat.S_ISLNK(root_metadata.st_mode)
        or root_metadata.st_uid != os.geteuid()
        or root_metadata.st_mode & 0o022
    ):
        abort()
    records: list[tuple[bytes, list[object]]] = []
    pending = [root]
    while pending:
        directory = pending.pop()
        try:
            children = list(directory.iterdir())
        except OSError:
            abort()
        for path in children:
            metadata = os.lstat(path)
            relative = path.relative_to(root).as_posix()
            relative_bytes = relative.encode("utf-8", errors="strict")
            if (
                not relative
                or any(byte < 32 or byte == 127 for byte in relative_bytes)
                or metadata.st_dev != root_metadata.st_dev
                or metadata.st_uid != os.geteuid()
                or (not stat.S_ISLNK(metadata.st_mode) and metadata.st_mode & 0o022)
            ):
                abort()
            mode = stat.S_IMODE(metadata.st_mode)
            if stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode):
                kind = "directory"
                payload = ""
                pending.append(path)
            elif stat.S_ISREG(metadata.st_mode):
                if metadata.st_nlink != 1:
                    abort()
                data, opened = read_regular(path)
                if fingerprint(metadata) != fingerprint(opened):
                    abort()
                kind = "file"
                payload = hashlib.sha256(data).hexdigest()
            elif stat.S_ISLNK(metadata.st_mode):
                kind = "symlink"
                payload = checked_symlink_target(relative, os.readlink(path))
            else:
                abort()
            records.append((relative_bytes, [relative, kind, mode, payload]))
    records.sort(key=lambda item: item[0])
    digest = hashlib.sha256()
    for _, record in records:
        encoded = json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n"
        digest.update(encoded.encode("utf-8"))
    return digest.hexdigest()


try:
    evidence_path = Path(sys.argv[1])
    app_path = Path(sys.argv[2])
    expected_commit = sys.argv[3]
    expected_candidate_hash = sys.argv[4]
    raw, _ = read_regular(evidence_path, MAX_EVIDENCE_BYTES)
    evidence = json.loads(raw.decode("utf-8", errors="strict"), object_pairs_hook=unique_object)
    expected_keys = {
        "appTreeSHA256", "archiveTreeSHA256", "candidateCommit", "candidateJSONSHA256",
        "evidenceType", "product", "schemaVersion", "status", "treeAlgorithm",
    }
    if type(evidence) is not dict or set(evidence) != expected_keys:
        abort()
    canonical = (
        json.dumps(evidence, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n"
    ).encode("utf-8")
    if raw != canonical:
        abort()
    if (
        type(evidence["schemaVersion"]) is not int
        or evidence["schemaVersion"] != 1
        or evidence["evidenceType"] != "unsigned-build"
        or type(evidence["evidenceType"]) is not str
        or evidence["product"] != "UtterInk"
        or type(evidence["product"]) is not str
        or evidence["status"] != "valid"
        or type(evidence["status"]) is not str
        or evidence["treeAlgorithm"] != "utterink-logical-tree-v1"
        or type(evidence["treeAlgorithm"]) is not str
        or evidence["candidateCommit"] != expected_commit
        or type(evidence["candidateCommit"]) is not str
        or evidence["candidateJSONSHA256"] != expected_candidate_hash
        or type(evidence["candidateJSONSHA256"]) is not str
    ):
        abort()
    for key in ("appTreeSHA256", "archiveTreeSHA256", "candidateJSONSHA256"):
        if type(evidence[key]) is not str or re.fullmatch(r"[0-9a-f]{64}", evidence[key]) is None:
            abort()
    if re.fullmatch(r"[0-9a-f]{40}", evidence["candidateCommit"]) is None:
        abort()
    if logical_tree(app_path) != evidence["appTreeSHA256"]:
        abort()
    Path(sys.argv[5]).write_text(hashlib.sha256(canonical).hexdigest(), encoding="ascii")
except (OSError, UnicodeError, ValueError, json.JSONDecodeError):
    abort()
PY
then
  fail invalid-unsigned-build-evidence 22
fi
UNSIGNED_BUILD_EVIDENCE_SHA256="$(/bin/cat "$CONTROL/unsigned-build-evidence-sha256")"
readonly UNSIGNED_BUILD_EVIDENCE_SHA256

/bin/mkdir -p \
  "$CONTROL/reviewed-root/App/Supporting" \
  "$CONTROL/reviewed-root/Config" \
  "$CONTROL/reviewed-root/Scripts/release" || fail reviewed-entitlements-unavailable 22
/bin/chmod 0700 \
  "$CONTROL/reviewed-root" \
  "$CONTROL/reviewed-root/App" \
  "$CONTROL/reviewed-root/App/Supporting" \
  "$CONTROL/reviewed-root/Config" \
  "$CONTROL/reviewed-root/Scripts" \
  "$CONTROL/reviewed-root/Scripts/release" || fail reviewed-entitlements-unavailable 22

CONTROL_ENTITLEMENTS="$CONTROL/reviewed-root/App/Supporting/UtterInk.entitlements"
if ! /usr/bin/python3 -I - \
  "$ROOT" "$SOURCE_COMMIT" "$POLICY_SHA256" \
  "$CONTROL/reviewed-root/Config/release-entitlements.json" \
  "$CONTROL_ENTITLEMENTS" \
  "$CONTROL/reviewed-root/Scripts/release/verify-entitlements.py" \
  "$CONTROL/entitlements-record" "$CONTROL/verifier-record" <<'PY' >/dev/null 2>&1
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import stat
import subprocess
import sys


MAX_BYTES = 512 * 1024
PATHS = (
    "Config/release-entitlements.json",
    "App/Supporting/UtterInk.entitlements",
    "Scripts/release/verify-entitlements.py",
    "Scripts/release/verify-signatures.sh",
)


def abort() -> None:
    raise SystemExit(1)


root = Path(sys.argv[1])
commit = sys.argv[2]
evidence_policy_hash = sys.argv[3]
destinations = tuple(Path(item) for item in sys.argv[4:7])
record_path = Path(sys.argv[7])
verifier_record_path = Path(sys.argv[8])
git_environment = {
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "LC_ALL": "C",
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_CONFIG_SYSTEM": "/dev/null",
    "GIT_NO_REPLACE_OBJECTS": "1",
}


def git(*arguments: str) -> bytes:
    result = subprocess.run(
        ["/usr/bin/git", "-C", str(root), *arguments],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        env=git_environment,
        check=False,
    )
    if result.returncode != 0:
        abort()
    return result.stdout


if git("cat-file", "-t", commit) != b"commit\n":
    abort()


def exact_blob(relative: str) -> bytes:
    listing = git("ls-tree", "-z", commit, "--", relative)
    if not listing.endswith(b"\0") or listing.count(b"\0") != 1:
        abort()
    try:
        header, listed_path = listing[:-1].split(b"\t", 1)
        mode, kind, object_id = header.split(b" ", 2)
        decoded_path = listed_path.decode("utf-8", errors="strict")
    except (ValueError, UnicodeError):
        abort()
    if mode not in {b"100644", b"100755"} or kind != b"blob" or decoded_path != relative:
        abort()
    data = git("cat-file", "blob", object_id.decode("ascii"))
    if len(data) > MAX_BYTES:
        abort()
    return data


def read_current(relative: str, expected: bytes) -> tuple[bytes, os.stat_result]:
    path = root / relative
    try:
        before = os.lstat(path)
        if (
            not stat.S_ISREG(before.st_mode)
            or stat.S_ISLNK(before.st_mode)
            or before.st_nlink != 1
            or before.st_uid != os.geteuid()
            or before.st_mode & 0o022
            or before.st_size > MAX_BYTES
        ):
            abort()
        descriptor = os.open(
            path,
            os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
        )
        try:
            opened = os.fstat(descriptor)
            chunks: list[bytes] = []
            remaining = MAX_BYTES + 1
            while remaining:
                chunk = os.read(descriptor, min(65536, remaining))
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            after = os.fstat(descriptor)
        finally:
            os.close(descriptor)
    except OSError:
        abort()
    fingerprint = lambda item: (
        item.st_dev, item.st_ino, item.st_mode, item.st_uid, item.st_nlink,
        item.st_size, item.st_mtime_ns, item.st_ctime_ns,
    )
    data = b"".join(chunks)
    if (
        fingerprint(before) != fingerprint(opened)
        or fingerprint(opened) != fingerprint(after)
        or data != expected
    ):
        abort()
    return data, after


blobs = tuple(exact_blob(relative) for relative in PATHS)
if hashlib.sha256(blobs[0]).hexdigest() != evidence_policy_hash:
    abort()
current = tuple(read_current(relative, blob) for relative, blob in zip(PATHS, blobs))

for index, (destination, blob) in enumerate(zip(destinations, blobs)):
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(destination, flags, 0o600)
        try:
            offset = 0
            source_data = current[index][0]
            while offset < len(source_data):
                offset += os.write(descriptor, source_data[offset:])
            os.fsync(descriptor)
            snapshot = os.fstat(descriptor)
        finally:
            os.close(descriptor)
    except OSError:
        abort()
    if hashlib.sha256(blob).digest() != hashlib.sha256(source_data).digest():
        abort()
    os.chmod(destination, 0o500 if index == 2 else 0o400, follow_symlinks=False)
    if index == 1:
        snapshot = os.lstat(destination)
        digest = hashlib.sha256(blob).hexdigest()
        fields = (
            "file", snapshot.st_dev, snapshot.st_ino, snapshot.st_mode,
            snapshot.st_uid, snapshot.st_nlink, snapshot.st_size,
            snapshot.st_mtime_ns, snapshot.st_ctime_ns, digest, str(destination),
        )
        record_path.write_text("\t".join(map(str, fields)) + "\n", encoding="utf-8")

verifier_metadata = current[3][1]
verifier_fields = (
    "file", verifier_metadata.st_dev, verifier_metadata.st_ino, verifier_metadata.st_mode,
    verifier_metadata.st_uid, verifier_metadata.st_nlink, verifier_metadata.st_size,
    verifier_metadata.st_mtime_ns, verifier_metadata.st_ctime_ns,
    hashlib.sha256(blobs[3]).hexdigest(), str(root / PATHS[3]),
)
verifier_record_path.write_text("\t".join(map(str, verifier_fields)) + "\n", encoding="utf-8")
PY
then
  fail reviewed-entitlements-unavailable 22
fi
readonly CONTROL_ENTITLEMENTS

# Execute a private byte-for-byte verifier copy. The random 0700 directory is
# one level below Scripts so verify-signatures.sh retains its reviewed ../..
# repository-root derivation. Retained parent, directory, and file descriptors
# bind both execution and cleanup without following a mutable pathname.
PINNED_VERIFIER_PARENT="$(CDPATH= cd -P -- "$SCRIPT_DIRECTORY/.." && /bin/pwd -P)" ||
  fail signature-verification-failed 22
exec 7< "$PINNED_VERIFIER_PARENT" || fail signature-verification-failed 22
if ! read -r PINNED_VERIFIER_PARENT_DEV PINNED_VERIFIER_PARENT_INO < <(
  /usr/bin/stat -f '%d %i' "$PINNED_VERIFIER_PARENT"
); then
  fail signature-verification-failed 22
fi
if ! /usr/bin/python3 -I - \
  "$PINNED_VERIFIER_PARENT" "$PINNED_VERIFIER_PARENT_DEV" \
  "$PINNED_VERIFIER_PARENT_INO" 7 <<'PY' >/dev/null 2>&1
import os
from pathlib import Path
import stat
import sys

path = Path(sys.argv[1])
expected = (int(sys.argv[2]), int(sys.argv[3]))
opened = os.fstat(int(sys.argv[4]))
named = os.lstat(path)
if (
    (opened.st_dev, opened.st_ino) != expected
    or (named.st_dev, named.st_ino) != expected
    or not stat.S_ISDIR(opened.st_mode)
    or stat.S_ISLNK(named.st_mode)
    or opened.st_uid != os.geteuid()
    or opened.st_mode & 0o022
):
    raise SystemExit(1)
PY
then
  fail signature-verification-failed 22
fi
PINNED_VERIFIER_DIRECTORY="$(/usr/bin/mktemp -d "$PINNED_VERIFIER_PARENT/.utterink-verifier-pinned.XXXXXX")" ||
  fail signature-verification-failed 22
PINNED_VERIFIER_DIRECTORY_NAME="${PINNED_VERIFIER_DIRECTORY##*/}"
[[ "$PINNED_VERIFIER_DIRECTORY_NAME" =~ ^\.utterink-verifier-pinned\.[A-Za-z0-9]+$ && \
  "$PINNED_VERIFIER_DIRECTORY" == "$PINNED_VERIFIER_PARENT/$PINNED_VERIFIER_DIRECTORY_NAME" && \
  -d "$PINNED_VERIFIER_DIRECTORY" && ! -L "$PINNED_VERIFIER_DIRECTORY" ]] ||
  fail signature-verification-failed 22
/bin/chmod 0700 "$PINNED_VERIFIER_DIRECTORY" || fail signature-verification-failed 22
exec 6< "$PINNED_VERIFIER_DIRECTORY" || fail signature-verification-failed 22
if ! read -r PINNED_VERIFIER_DIRECTORY_DEV PINNED_VERIFIER_DIRECTORY_INO < <(
  /usr/bin/stat -f '%d %i' "$PINNED_VERIFIER_DIRECTORY"
); then
  fail signature-verification-failed 22
fi
if ! /usr/bin/python3 -I - \
  "$PINNED_VERIFIER_DIRECTORY_NAME" "$PINNED_VERIFIER_DIRECTORY_DEV" \
  "$PINNED_VERIFIER_DIRECTORY_INO" 7 6 <<'PY' >/dev/null 2>&1
import os
import stat
import sys

name = sys.argv[1]
expected = (int(sys.argv[2]), int(sys.argv[3]))
parent_fd, directory_fd = int(sys.argv[4]), int(sys.argv[5])
named = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
opened = os.fstat(directory_fd)
if (
    (named.st_dev, named.st_ino) != expected
    or (opened.st_dev, opened.st_ino) != expected
    or not stat.S_ISDIR(named.st_mode)
    or not stat.S_ISDIR(opened.st_mode)
    or opened.st_uid != os.geteuid()
    or stat.S_IMODE(opened.st_mode) != 0o700
    or os.listdir(directory_fd)
):
    raise SystemExit(1)
PY
then
  fail signature-verification-failed 22
fi
PINNED_VERIFIER_NAME=verify-signatures.sh
PINNED_VERIFIER="$PINNED_VERIFIER_DIRECTORY/$PINNED_VERIFIER_NAME"
if ! /usr/bin/python3 -I - "$PINNED_VERIFIER_NAME" 6 <<'PY' >/dev/null 2>&1
import os
import stat
import sys

name, directory_fd = sys.argv[1], int(sys.argv[2])
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
descriptor = os.open(name, flags, 0o600, dir_fd=directory_fd)
try:
    os.fchmod(descriptor, 0o600)
    opened = os.fstat(descriptor)
    if not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.geteuid() or opened.st_nlink != 1:
        raise OSError
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY
then
  fail signature-verification-failed 22
fi
exec 8<> "$PINNED_VERIFIER" || fail signature-verification-failed 22
if ! read -r PINNED_VERIFIER_DEV PINNED_VERIFIER_INO < <(/usr/bin/stat -f '%d %i' "$PINNED_VERIFIER"); then
  fail signature-verification-failed 22
fi
if ! /usr/bin/python3 -I - \
  "$VERIFIER" "$PINNED_VERIFIER" "$TEST_MODE" "$CONTROL/verifier-record" \
  "$CONTROL/pinned-verifier-record" "$PINNED_VERIFIER_NAME" 6 8 <<'PY' >/dev/null 2>&1
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import stat
import sys


def abort() -> None:
    raise SystemExit(1)


def fingerprint(item: os.stat_result) -> tuple[int, ...]:
    return (
        item.st_dev, item.st_ino, item.st_mode, item.st_uid, item.st_nlink,
        item.st_size, item.st_mtime_ns, item.st_ctime_ns,
    )


source, destination = map(Path, sys.argv[1:3])
test_mode = sys.argv[3] == "1"
record_path = Path(sys.argv[4])
output_record = Path(sys.argv[5])
destination_name = sys.argv[6]
directory_fd = int(sys.argv[7])
destination_fd = int(sys.argv[8])
try:
    before = os.lstat(source)
    if (
        not stat.S_ISREG(before.st_mode)
        or stat.S_ISLNK(before.st_mode)
        or before.st_nlink != 1
        or before.st_uid != os.geteuid()
        or before.st_mode & 0o022
        or not before.st_mode & stat.S_IXUSR
    ):
        abort()
    source_fd = os.open(source, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
    try:
        opened = os.fstat(source_fd)
        chunks: list[bytes] = []
        while True:
            chunk = os.read(source_fd, 65536)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(source_fd)
    finally:
        os.close(source_fd)
    if fingerprint(before) != fingerprint(opened) or fingerprint(opened) != fingerprint(after):
        abort()
    data = b"".join(chunks)
    if not data or len(data) > 512 * 1024:
        abort()
    if not test_mode:
        fields = record_path.read_text(encoding="utf-8").rstrip("\n").split("\t", 10)
        if len(fields) != 11 or hashlib.sha256(data).hexdigest() != fields[9]:
            abort()
    destination_before = os.lstat(destination)
    destination_named = os.stat(destination_name, dir_fd=directory_fd, follow_symlinks=False)
    destination_opened = os.fstat(destination_fd)
    if (
        (destination_before.st_dev, destination_before.st_ino)
        != (destination_opened.st_dev, destination_opened.st_ino)
        or (destination_named.st_dev, destination_named.st_ino)
        != (destination_opened.st_dev, destination_opened.st_ino)
        or not stat.S_ISREG(destination_opened.st_mode)
        or destination_opened.st_nlink != 1
        or destination_opened.st_uid != os.geteuid()
    ):
        abort()
    os.ftruncate(destination_fd, 0)
    offset = 0
    while offset < len(data):
        written = os.write(destination_fd, data[offset:])
        if written <= 0:
            abort()
        offset += written
    os.fsync(destination_fd)
    os.fchmod(destination_fd, 0o500)
    pinned = os.fstat(destination_fd)
    record = (
        "file", pinned.st_dev, pinned.st_ino, pinned.st_mode, pinned.st_uid,
        pinned.st_nlink, pinned.st_size, pinned.st_mtime_ns, pinned.st_ctime_ns,
        hashlib.sha256(data).hexdigest(), str(destination),
    )
    output_record.write_text("\t".join(map(str, record)) + "\n", encoding="utf-8")
except (OSError, UnicodeError, ValueError):
    abort()
PY
then
  fail signature-verification-failed 22
fi
readonly \
  PINNED_VERIFIER_PARENT PINNED_VERIFIER_PARENT_DEV PINNED_VERIFIER_PARENT_INO \
  PINNED_VERIFIER_DIRECTORY PINNED_VERIFIER_DIRECTORY_NAME \
  PINNED_VERIFIER_DIRECTORY_DEV PINNED_VERIFIER_DIRECTORY_INO \
  PINNED_VERIFIER_NAME PINNED_VERIFIER PINNED_VERIFIER_DEV PINNED_VERIFIER_INO

if ! /usr/bin/python3 -I "$CONTROL/reviewed-root/Scripts/release/verify-entitlements.py" \
  > "$CONTROL/tool-output.txt" 2> "$CONTROL/tool-error.txt"; then
  fail reviewed-entitlements-unavailable 22
fi

# Identity, private-key, certificate, validity, Team ID, and trust checks all
# complete before candidate discovery can issue the first signing operation.
if ! "$SECURITY" find-identity -v -p codesigning \
  > "$CONTROL/identities.txt" 2> "$CONTROL/tool-error.txt"; then
  fail identity-preflight-failed 24
fi
if ! /usr/bin/python3 -I - \
  "$CONTROL/identities.txt" "$IDENTITY" "$CONTROL/signing-identity-sha1" <<'PY' >/dev/null 2>&1
from pathlib import Path
import re
import sys

try:
    lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
except (OSError, UnicodeError):
    raise SystemExit(1)
expected = sys.argv[2]
matches = []
for line in lines:
    match = re.fullmatch(r"\s*[0-9]+[)]\s+([0-9A-Fa-f]{40})\s+\"([^\"]+)\"\s*", line)
    if match is not None and match.group(2) == expected:
        matches.append(match.group(1).lower())
if len(matches) != 1:
    raise SystemExit(1)
try:
    Path(sys.argv[3]).write_text(matches[0], encoding="ascii")
except OSError:
    raise SystemExit(1)
PY
then
  fail identity-preflight-failed 24
fi
SIGNING_IDENTITY_SHA1="$(/bin/cat "$CONTROL/signing-identity-sha1")"
readonly SIGNING_IDENTITY_SHA1
if ! "$SECURITY" find-certificate -a -c "$IDENTITY" -p \
  > "$CONTROL/certificate.pem" 2> "$CONTROL/tool-error.txt"; then
  fail identity-preflight-failed 24
fi
/bin/chmod 0600 "$CONTROL/certificate.pem" || fail identity-preflight-failed 24
if ! /usr/bin/python3 -I - "$CONTROL/certificate.pem" <<'PY' >/dev/null 2>&1
from pathlib import Path
import sys

try:
    value = Path(sys.argv[1]).read_text(encoding="ascii")
except (OSError, UnicodeError):
    raise SystemExit(1)
if value.count("-----BEGIN CERTIFICATE-----") != 1 or value.count("-----END CERTIFICATE-----") != 1:
    raise SystemExit(1)
PY
then
  fail identity-preflight-failed 24
fi
if ! "$SECURITY" verify-cert -c "$CONTROL/certificate.pem" -p codeSign \
  > "$CONTROL/security-verify.txt" 2> "$CONTROL/tool-error.txt"; then
  fail identity-preflight-failed 24
fi
if ! "$OPENSSL" x509 -in "$CONTROL/certificate.pem" -checkend 0 -noout \
  > "$CONTROL/openssl-check.txt" 2> "$CONTROL/tool-error.txt"; then
  fail identity-preflight-failed 24
fi
if ! "$OPENSSL" x509 -in "$CONTROL/certificate.pem" -noout -subject -nameopt sep_multiline \
  > "$CONTROL/subject.txt" 2> "$CONTROL/tool-error.txt"; then
  fail identity-preflight-failed 24
fi
if ! "$OPENSSL" x509 -in "$CONTROL/certificate.pem" -noout -fingerprint -sha1 \
  > "$CONTROL/certificate-sha1.txt" 2> "$CONTROL/tool-error.txt"; then
  fail identity-preflight-failed 24
fi
if ! "$OPENSSL" x509 -in "$CONTROL/certificate.pem" -noout -fingerprint -sha256 \
  > "$CONTROL/certificate-sha256.txt" 2> "$CONTROL/tool-error.txt"; then
  fail identity-preflight-failed 24
fi
if ! /usr/bin/python3 -I - "$CONTROL/subject.txt" "$IDENTITY" "$TEAM_ID" <<'PY' >/dev/null 2>&1
from pathlib import Path
import sys

try:
    lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
except (OSError, UnicodeError):
    raise SystemExit(1)
common_names = []
team_ids = []
for line in lines:
    stripped = line.strip()
    if stripped.startswith("commonName = "):
        common_names.append(stripped.removeprefix("commonName = "))
    elif stripped.startswith("organizationalUnitName = "):
        team_ids.append(stripped.removeprefix("organizationalUnitName = "))
if common_names != [sys.argv[2]] or team_ids != [sys.argv[3]]:
    raise SystemExit(1)
PY
then
  fail identity-preflight-failed 24
fi
if ! /usr/bin/python3 -I - \
  "$CONTROL/certificate-sha1.txt" "$CONTROL/certificate-sha256.txt" \
  "$SIGNING_IDENTITY_SHA1" "$CONTROL/certificate-sha256" <<'PY' >/dev/null 2>&1
from pathlib import Path
import re
import sys


def fingerprint(path: str, length: int) -> str:
    try:
        lines = Path(path).read_text(encoding="ascii").splitlines()
    except (OSError, UnicodeError):
        raise SystemExit(1)
    if len(lines) != 1 or "Fingerprint=" not in lines[0]:
        raise SystemExit(1)
    value = lines[0].split("Fingerprint=", 1)[1].replace(":", "").strip().lower()
    if re.fullmatch(rf"[0-9a-f]{{{length}}}", value) is None:
        raise SystemExit(1)
    return value


sha1 = fingerprint(sys.argv[1], 40)
sha256 = fingerprint(sys.argv[2], 64)
if sha1 != sys.argv[3]:
    raise SystemExit(1)
try:
    Path(sys.argv[4]).write_text(sha256, encoding="ascii")
except OSError:
    raise SystemExit(1)
PY
then
  fail identity-preflight-failed 24
fi
CERTIFICATE_SHA256="$(/bin/cat "$CONTROL/certificate-sha256")"
readonly CERTIFICATE_SHA256

# Inventory the entire bundle before signing. Symlinks and unknown code bundle
# types are forbidden; every executable file must be an arm64-only Mach-O as
# reported by absolute lipo, every framework has exactly one unambiguous Mach-O
# executable, and every signable is bound to an fd-derived fingerprint/hash.
if ! /usr/bin/python3 -I - \
  "$CANDIDATE" "$APP" "$FILE_TOOL" "$LIPO" \
  "$CONTROL/machos.records" "$CONTROL/frameworks.records" "$CONTROL/app.record" \
  "$CONTROL/resources.records" "$CONTROL/unsigned-manifest.records" \
  "$CONTROL/verification-components" <<'PY' >/dev/null 2>&1
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import stat
import subprocess
import sys


def abort() -> None:
    raise SystemExit(1)


(
    candidate, app, file_tool, lipo, macho_output, framework_output, app_output,
    resource_output, manifest_output, verification_output,
) = map(Path, sys.argv[1:11])
try:
    candidate_metadata = os.lstat(candidate)
    app_metadata = os.lstat(app)
except OSError:
    abort()
if (
    not stat.S_ISDIR(candidate_metadata.st_mode)
    or stat.S_ISLNK(candidate_metadata.st_mode)
    or not stat.S_ISDIR(app_metadata.st_mode)
    or stat.S_ISLNK(app_metadata.st_mode)
    or candidate_metadata.st_dev != app_metadata.st_dev
):
    abort()
try:
    top_entries = sorted(item.name for item in candidate.iterdir())
except OSError:
    abort()
if top_entries != ["UtterInk.app", "candidate.json", "unsigned-build-evidence.json"]:
    abort()
try:
    candidate_json = os.lstat(candidate / "candidate.json")
except OSError:
    abort()
if stat.S_ISLNK(candidate_json.st_mode) or not stat.S_ISREG(candidate_json.st_mode):
    abort()

tool_environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"}
fixture_log = os.environ.get("UTTERINK_FIXTURE_LOG")
if fixture_log is not None:
    tool_environment["UTTERINK_FIXTURE_LOG"] = fixture_log


def fingerprint(item: os.stat_result) -> tuple[int, ...]:
    return (
        item.st_dev, item.st_ino, item.st_mode, item.st_uid, item.st_nlink,
        item.st_size, item.st_mtime_ns, item.st_ctime_ns,
    )


def hash_regular(path: Path, expected: os.stat_result) -> str:
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
        )
        try:
            opened = os.fstat(descriptor)
            digest = hashlib.sha256()
            while True:
                chunk = os.read(descriptor, 65536)
                if not chunk:
                    break
                digest.update(chunk)
            after = os.fstat(descriptor)
        finally:
            os.close(descriptor)
    except OSError:
        abort()
    if fingerprint(expected) != fingerprint(opened) or fingerprint(opened) != fingerprint(after):
        abort()
    return digest.hexdigest()


def record(kind: str, path: Path, metadata: os.stat_result, digest: str = "-") -> str:
    fields = (
        kind, metadata.st_dev, metadata.st_ino, metadata.st_mode,
        metadata.st_uid, metadata.st_nlink, metadata.st_size,
        metadata.st_mtime_ns, metadata.st_ctime_ns, digest, str(path),
    )
    return "\t".join(map(str, fields)) + "\n"

files: list[tuple[Path, os.stat_result, str]] = []
frameworks: list[tuple[Path, os.stat_result]] = []
directories: list[tuple[Path, os.stat_result]] = []
pending = [app]
app_contents_directories = {"MacOS", "Resources", "Frameworks", "Helpers", "SharedSupport"}
framework_directories = {"Resources", "Frameworks", "Helpers", "Libraries", "Modules", "Headers"}
while pending:
    path = pending.pop()
    try:
        metadata = os.lstat(path)
        relative = path.relative_to(app)
        relative_text = "." if not relative.parts else relative.as_posix()
        relative_text.encode("utf-8", errors="strict")
    except (OSError, UnicodeError, ValueError):
        abort()
    if any(ord(character) < 32 or ord(character) == 127 for character in relative_text):
        abort()
    if stat.S_ISLNK(metadata.st_mode):
        abort()
    if metadata.st_dev != app_metadata.st_dev or metadata.st_uid != os.geteuid():
        abort()
    if stat.S_ISDIR(metadata.st_mode):
        directories.append((path, metadata))
        if path != app:
            suffix = path.suffix
            if suffix == ".framework":
                if path.parent.name != "Frameworks":
                    abort()
                frameworks.append((path, metadata))
            elif suffix == ".lproj":
                if path.parent.name != "Resources":
                    abort()
            elif suffix:
                abort()
            else:
                framework_ancestor = next(
                    (parent for parent in path.parents if parent != app and parent.suffix == ".framework"),
                    None,
                )
                if path.name == "Contents":
                    if path.parent != app:
                        abort()
                elif path.parent == app / "Contents":
                    if path.name not in app_contents_directories:
                        abort()
                elif framework_ancestor is not None:
                    if path.name == "Versions":
                        if path.parent != framework_ancestor:
                            abort()
                    elif path.name == "A":
                        if path.parent.name != "Versions" or path.parent.parent != framework_ancestor:
                            abort()
                    elif path.name in framework_directories:
                        allowed_parents = {framework_ancestor, framework_ancestor / "Versions" / "A"}
                        if path.parent not in allowed_parents:
                            abort()
                    else:
                        abort()
                else:
                    abort()
        try:
            children = sorted(path.iterdir(), key=lambda item: os.fsencode(item.name), reverse=True)
        except OSError:
            abort()
        pending.extend(children)
    elif stat.S_ISREG(metadata.st_mode):
        if metadata.st_nlink != 1:
            abort()
        result = subprocess.run(
            [str(file_tool), "-b", str(path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
            env=tool_environment,
        )
        if result.returncode != 0:
            abort()
        try:
            description = result.stdout.decode("utf-8", errors="strict").strip()
        except UnicodeError:
            abort()
        is_macho = "Mach-O" in description
        executable = bool(metadata.st_mode & stat.S_IXUSR)
        if is_macho:
            if not executable:
                abort()
            architecture = subprocess.run(
                [str(lipo), "-archs", str(path)],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                check=False,
                env=tool_environment,
            )
            try:
                architecture_text = architecture.stdout.decode("ascii", errors="strict").strip()
            except UnicodeError:
                abort()
            if architecture.returncode != 0 or architecture_text != "arm64":
                abort()
        elif executable:
            abort()
        try:
            after_tools = os.lstat(path)
        except OSError:
            abort()
        if fingerprint(metadata) != fingerprint(after_tools):
            abort()
        files.append((path, metadata, description))
    else:
        abort()

main_executable = app / "Contents" / "MacOS" / "UtterInk"
main_matches = [path for path, _, description in files if path == main_executable and "Mach-O" in description]
if main_matches != [main_executable]:
    abort()

macho_paths = [path for path, _, description in files if "Mach-O" in description and path != main_executable]
for framework, _ in frameworks:
    expected_name = framework.stem
    matches = [
        path
        for path in macho_paths
        if framework in path.parents and path.name == expected_name
    ]
    if len(matches) != 1:
        abort()

def inside_out_key(path: Path) -> tuple[int, bytes]:
    relative = path.relative_to(app)
    return (-len(relative.parts), os.fsencode(relative.as_posix()))

macho_paths.sort(key=inside_out_key)
frameworks.sort(key=lambda item: inside_out_key(item[0]))
try:
    metadata_by_path = {path: metadata for path, metadata, _ in files}
    digest_by_path = {path: hash_regular(path, metadata) for path, metadata, _ in files}
    macho_output.write_text(
        "".join(record("file", path, metadata_by_path[path], digest_by_path[path]) for path in macho_paths),
        encoding="utf-8",
    )
    framework_output.write_text(
        "".join(record("directory", path, metadata) for path, metadata in frameworks),
        encoding="utf-8",
    )
    app_output.write_text(record("directory", app, app_metadata), encoding="utf-8")
    resource_output.write_text(
        "".join(
            record("file", path, metadata, digest_by_path[path])
            for path, metadata, description in sorted(files, key=lambda item: os.fsencode(item[0].relative_to(app).as_posix()))
            if "Mach-O" not in description
        ),
        encoding="utf-8",
    )
    manifest_records = [record("directory", path, metadata) for path, metadata in directories]
    manifest_records.extend(
        record("file", path, metadata, digest_by_path[path])
        for path, metadata, _ in files
    )
    manifest_output.write_text("".join(sorted(manifest_records)), encoding="utf-8")
    verification_records = [("bundle", "UtterInk.app")]
    verification_records.extend(
        ("bundle", f"UtterInk.app/{path.relative_to(app).as_posix()}")
        for path, _ in frameworks
    )
    verification_records.extend(
        ("mach-o", f"UtterInk.app/{path.relative_to(app).as_posix()}")
        for path, _, description in files if "Mach-O" in description
    )
    verification_output.write_text(
        "".join(f"{kind}\t{relative}\n" for kind, relative in sorted(verification_records, key=lambda item: os.fsencode(item[1]))),
        encoding="utf-8",
    )
except OSError:
    abort()
PY
then
  fail invalid-candidate 25
fi

# Maintain an exact evolving snapshot across signing boundaries. The initial
# snapshot is the reviewed unsigned tree. After each successful codesign call,
# only codesign's synchronous mutations are admitted by refreshing the private
# snapshot; any add/delete/replace between boundaries is rejected.
capture_boundary_snapshot() {
  local output_path="$1"
  /usr/bin/python3 -I - "$APP" "$output_path" <<'PY' >/dev/null 2>&1
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import stat
import sys


def abort() -> None:
    raise SystemExit(1)


def fingerprint(item: os.stat_result) -> tuple[int, ...]:
    return (
        item.st_dev, item.st_ino, item.st_mode, item.st_uid, item.st_nlink,
        item.st_size, item.st_mtime_ns, item.st_ctime_ns,
    )


root = Path(sys.argv[1])
output = Path(sys.argv[2])
try:
    root_metadata = os.lstat(root)
    if (
        not stat.S_ISDIR(root_metadata.st_mode)
        or stat.S_ISLNK(root_metadata.st_mode)
        or root_metadata.st_uid != os.geteuid()
        or root_metadata.st_mode & 0o022
    ):
        abort()
    records: list[tuple[bytes, list[object]]] = []
    pending = [root]
    while pending:
        path = pending.pop()
        metadata = os.lstat(path)
        relative = "." if path == root else path.relative_to(root).as_posix()
        relative_bytes = relative.encode("utf-8", errors="strict")
        if (
            any(byte < 32 or byte == 127 for byte in relative_bytes)
            or metadata.st_dev != root_metadata.st_dev
            or metadata.st_uid != os.geteuid()
            or (not stat.S_ISLNK(metadata.st_mode) and metadata.st_mode & 0o022)
        ):
            abort()
        if stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode):
            kind, payload = "directory", ""
            children = sorted(path.iterdir(), key=lambda item: os.fsencode(item.name), reverse=True)
            pending.extend(children)
        elif stat.S_ISREG(metadata.st_mode):
            if metadata.st_nlink != 1:
                abort()
            descriptor = os.open(
                path,
                os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
            )
            try:
                opened = os.fstat(descriptor)
                digest = hashlib.sha256()
                while True:
                    chunk = os.read(descriptor, 65536)
                    if not chunk:
                        break
                    digest.update(chunk)
                after = os.fstat(descriptor)
            finally:
                os.close(descriptor)
            if fingerprint(metadata) != fingerprint(opened) or fingerprint(opened) != fingerprint(after):
                abort()
            kind, payload = "file", digest.hexdigest()
        elif stat.S_ISLNK(metadata.st_mode):
            kind, payload = "symlink", os.readlink(path)
            payload.encode("utf-8", errors="strict")
        else:
            abort()
        records.append((relative_bytes, [
            relative, kind, metadata.st_dev, metadata.st_ino, metadata.st_mode,
            metadata.st_uid, metadata.st_nlink, metadata.st_size,
            metadata.st_mtime_ns, metadata.st_ctime_ns, payload,
        ]))
    encoded = b"".join(
        (json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
        for _, record in sorted(records, key=lambda item: item[0])
    )
    descriptor = os.open(
        output,
        os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    try:
        offset = 0
        while offset < len(encoded):
            written = os.write(descriptor, encoded[offset:])
            if written <= 0:
                abort()
            offset += written
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
except (OSError, UnicodeError, ValueError):
    abort()
PY
}

refresh_boundary_snapshot() {
  /bin/rm -f "$CONTROL/boundary-tree.next"
  capture_boundary_snapshot "$CONTROL/boundary-tree.next" || return 1
  /bin/mv -f "$CONTROL/boundary-tree.next" "$CONTROL/boundary-tree.snapshot" || return 1
}

revalidate_boundary_snapshot() {
  /bin/rm -f "$CONTROL/boundary-tree.current"
  capture_boundary_snapshot "$CONTROL/boundary-tree.current" || return 1
  /usr/bin/cmp -s "$CONTROL/boundary-tree.snapshot" "$CONTROL/boundary-tree.current"
}

advance_boundary_snapshot() {
  local component_kind="$1"
  local component_path="$2"
  /bin/rm -f "$CONTROL/boundary-tree.next"
  capture_boundary_snapshot "$CONTROL/boundary-tree.next" || return 1
  if ! /usr/bin/python3 -I - \
    "$APP" "$component_kind" "$component_path" \
    "$CONTROL/verification-components" \
    "$CONTROL/boundary-tree.snapshot" "$CONTROL/boundary-tree.next" <<'PY' >/dev/null 2>&1
from __future__ import annotations

import json
import os
from pathlib import Path, PurePosixPath
import stat
import sys


def abort() -> None:
    raise SystemExit(1)


def load(path: Path) -> dict[str, list[object]]:
    result: dict[str, list[object]] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        record = json.loads(line)
        if type(record) is not list or len(record) != 11 or type(record[0]) is not str or record[0] in result:
            abort()
        result[record[0]] = record
    if "." not in result:
        abort()
    return result


def ancestors(relative: str) -> set[str]:
    result = {"."}
    current = PurePosixPath(relative)
    for parent in current.parents:
        text = parent.as_posix()
        result.add("." if text == "." else text)
    return result


def stable_directory(before: list[object], after: list[object], link_increase: int) -> bool:
    # Allow only directory size/timestamps and the exact filesystem-specific
    # link-count increase caused by authorized direct-child additions.
    return (
        before[1] == after[1] == "directory"
        and before[2:6] == after[2:6]
        and type(before[6]) is int
        and type(after[6]) is int
        and after[6] == before[6] + link_increase
        and before[10] == after[10] == ""
    )


def safe_file(record: list[object]) -> bool:
    mode = record[4]
    return (
        record[1] == "file"
        and type(mode) is int
        and stat.S_ISREG(mode)
        and not mode & 0o022
        and record[5] == os.geteuid()
        and record[6] == 1
        and type(record[10]) is str
    )


def safe_directory(record: list[object]) -> bool:
    mode = record[4]
    return (
        record[1] == "directory"
        and type(mode) is int
        and stat.S_ISDIR(mode)
        and not mode & 0o022
        and record[5] == os.geteuid()
        and record[10] == ""
    )


try:
    app = Path(sys.argv[1])
    component_kind = sys.argv[2]
    component = Path(sys.argv[3])
    if component_kind not in {"file", "bundle", "app"}:
        abort()
    component_relative = "." if component == app else component.relative_to(app).as_posix()
    before = load(Path(sys.argv[5]))
    after = load(Path(sys.argv[6]))
    if set(before) - set(after):
        abort()

    expected_machos: list[str] = []
    for line in Path(sys.argv[4]).read_text(encoding="utf-8").splitlines():
        fields = line.split("\t")
        if len(fields) != 2:
            abort()
        kind, relative = fields
        if kind == "mach-o":
            prefix = "UtterInk.app/"
            if not relative.startswith(prefix):
                abort()
            expected_machos.append(relative.removeprefix(prefix))

    if component_kind == "file":
        allowed_code = {component_relative}
        signature_bases: set[str] = set()
    elif component_kind == "app":
        allowed_code = {"Contents/MacOS/UtterInk"}
        signature_bases = {"Contents"}
    else:
        framework_name = component.stem
        allowed_code = {
            relative for relative in expected_machos
            if PurePosixPath(component_relative) in PurePosixPath(relative).parents
            and PurePosixPath(relative).name == framework_name
        }
        if len(allowed_code) != 1:
            abort()
        signature_bases = {component_relative}
        signature_bases.update(PurePosixPath(relative).parent.as_posix() for relative in allowed_code)

    signature_directories = {f"{base}/_CodeSignature" for base in signature_bases}
    signature_files = {f"{directory}/CodeResources" for directory in signature_directories}
    legacy_links = {f"{base}/CodeResources" for base in signature_bases}
    permitted_additions = signature_directories | signature_files | legacy_links
    additions = set(after) - set(before)
    if not additions <= permitted_additions:
        abort()

    for relative in additions:
        record = after[relative]
        if relative in signature_directories:
            if not safe_directory(record):
                abort()
        elif relative in signature_files:
            if not safe_file(record):
                abort()
        elif relative in legacy_links:
            if record[1] != "symlink" or record[10] != "_CodeSignature/CodeResources":
                abort()
        else:
            abort()

    # APFS counts every direct directory entry in st_nlink, while traditional
    # Unix filesystems count only direct subdirectories. Infer the one coherent
    # model from the already captured complete tree, then admit only the exact
    # increase caused by the allowlisted direct additions above.
    direct_children: dict[str, int] = {}
    direct_directories: dict[str, int] = {}
    for relative, record in before.items():
        if relative == ".":
            continue
        parent = PurePosixPath(relative).parent.as_posix()
        direct_children[parent] = direct_children.get(parent, 0) + 1
        if record[1] == "directory":
            direct_directories[parent] = direct_directories.get(parent, 0) + 1
    observed_models: set[str] = set()
    for relative, record in before.items():
        if record[1] != "directory":
            continue
        child_count = direct_children.get(relative, 0)
        directory_count = direct_directories.get(relative, 0)
        if child_count == directory_count:
            continue
        if record[6] == 2 + child_count:
            observed_models.add("entries")
        elif record[6] == 2 + directory_count:
            observed_models.add("directories")
        else:
            abort()
    if len(observed_models) != 1:
        abort()
    link_model = next(iter(observed_models))
    directory_link_deltas: dict[str, int] = {}
    for relative in additions:
        if link_model == "directories" and after[relative][1] != "directory":
            continue
        parent = PurePosixPath(relative).parent.as_posix()
        directory_link_deltas[parent] = directory_link_deltas.get(parent, 0) + 1

    allowed_directory_metadata = {component_relative}
    for relative in allowed_code | signature_directories | signature_files | legacy_links:
        allowed_directory_metadata.update(ancestors(relative))

    for relative in set(before) & set(after):
        old_record, new_record = before[relative], after[relative]
        if old_record == new_record:
            continue
        if relative in allowed_code:
            if not safe_file(old_record) or not safe_file(new_record):
                abort()
            if old_record[4:7] != new_record[4:7] or old_record[2] != new_record[2]:
                abort()
        elif relative in signature_files:
            if not safe_file(new_record):
                abort()
        elif relative in legacy_links:
            if new_record[1] != "symlink" or new_record[10] != "_CodeSignature/CodeResources":
                abort()
        elif relative in allowed_directory_metadata:
            if not stable_directory(old_record, new_record, directory_link_deltas.get(relative, 0)):
                abort()
        else:
            abort()

except (OSError, UnicodeError, ValueError, json.JSONDecodeError):
    abort()
PY
  then
    return 1
  fi
  /bin/mv -f "$CONTROL/boundary-tree.next" "$CONTROL/boundary-tree.snapshot" || return 1
}

refresh_boundary_snapshot || fail invalid-candidate 25

revalidate_record() {
  local component_record="$1"
  /usr/bin/python3 -I - "$component_record" <<'PY' >/dev/null 2>&1
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import stat
import sys


try:
    fields = sys.argv[1].split("\t", 10)
    if len(fields) != 11:
        raise ValueError
    kind, dev, ino, mode, uid, nlink, size, mtime_ns, ctime_ns, expected_hash, raw_path = fields
    expected = tuple(int(item) for item in (dev, ino, mode, uid, nlink, size, mtime_ns, ctime_ns))
    path = Path(raw_path)
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    if kind == "directory":
        flags |= getattr(os, "O_DIRECTORY", 0)
    elif kind != "file":
        raise ValueError
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        actual = (
            opened.st_dev, opened.st_ino, opened.st_mode, opened.st_uid,
            opened.st_nlink, opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns,
        )
        if actual != expected:
            raise ValueError
        if kind == "file":
            if not stat.S_ISREG(opened.st_mode) or opened.st_nlink != 1:
                raise ValueError
            digest = hashlib.sha256()
            while True:
                chunk = os.read(descriptor, 65536)
                if not chunk:
                    break
                digest.update(chunk)
            if digest.hexdigest() != expected_hash:
                raise ValueError
        elif not stat.S_ISDIR(opened.st_mode) or stat.S_ISLNK(opened.st_mode) or expected_hash != "-":
            raise ValueError
        after = os.fstat(descriptor)
        final = (
            after.st_dev, after.st_ino, after.st_mode, after.st_uid,
            after.st_nlink, after.st_size, after.st_mtime_ns, after.st_ctime_ns,
        )
        if final != actual:
            raise ValueError
    finally:
        os.close(descriptor)
except (OSError, ValueError):
    raise SystemExit(1)
PY
}

revalidate_records_file() {
  local records_path="$1"
  local record_line
  while IFS= read -r record_line; do
    [[ -n "$record_line" ]] || return 1
    revalidate_record "$record_line" || return 1
  done < "$records_path"
}

run_mutation_hook() {
  if [[ "$TEST_MODE" -eq 1 ]]; then
    "$MUTATION_HOOK" "$@" "$CONTROL_ENTITLEMENTS" \
      > "$CONTROL/tool-output.txt" 2> "$CONTROL/tool-error.txt" ||
      fail fixture-mutation-hook-failed 25
  fi
}

sign_component() {
  local component="$1"
  "$CODESIGN" \
    --force \
    --sign "$SIGNING_IDENTITY_SHA1" \
    --options runtime \
    --timestamp \
    "$component" \
    > "$CONTROL/tool-output.txt" 2> "$CONTROL/tool-error.txt" || fail signing-failed 30
}

sign_index=0
while IFS= read -r component_record; do
  [[ -n "$component_record" ]] || fail invalid-candidate 25
  component="${component_record##*$'\t'}"
  run_mutation_hook before-sign "$sign_index" "$component"
  revalidate_boundary_snapshot || fail candidate-changed-before-signing 25
  if [[ "$sign_index" -eq 0 ]]; then
    revalidate_records_file "$CONTROL/unsigned-manifest.records" || fail candidate-changed-before-signing 25
  else
    revalidate_records_file "$CONTROL/resources.records" || fail candidate-changed-before-signing 25
  fi
  revalidate_record "$component_record" || fail candidate-changed-before-signing 25
  sign_component "$component"
  advance_boundary_snapshot file "$component" || fail unexpected-signing-mutation 25
  sign_index=$((sign_index + 1))
done < "$CONTROL/machos.records"
while IFS= read -r component_record; do
  [[ -n "$component_record" ]] || fail invalid-candidate 25
  component="${component_record##*$'\t'}"
  run_mutation_hook before-sign "$sign_index" "$component"
  revalidate_boundary_snapshot || fail candidate-changed-before-signing 25
  revalidate_records_file "$CONTROL/resources.records" || fail candidate-changed-before-signing 25
  revalidate_record "$component_record" || fail candidate-changed-before-signing 25
  sign_component "$component"
  advance_boundary_snapshot bundle "$component" || fail unexpected-signing-mutation 25
  sign_index=$((sign_index + 1))
done < "$CONTROL/frameworks.records"

IFS= read -r app_record < "$CONTROL/app.record" || fail invalid-candidate 25
IFS= read -r entitlements_record < "$CONTROL/entitlements-record" || fail reviewed-entitlements-unavailable 22
run_mutation_hook before-sign "$sign_index" "$APP"
revalidate_boundary_snapshot || fail candidate-changed-before-signing 25
revalidate_records_file "$CONTROL/resources.records" || fail candidate-changed-before-signing 25
revalidate_record "$app_record" || fail candidate-changed-before-signing 25
revalidate_record "$entitlements_record" || fail candidate-changed-before-signing 25
"$CODESIGN" \
  --force \
  --sign "$SIGNING_IDENTITY_SHA1" \
  --options runtime \
  --timestamp \
  --entitlements "$CONTROL_ENTITLEMENTS" \
  "$APP" \
  > "$CONTROL/tool-output.txt" 2> "$CONTROL/tool-error.txt" || fail signing-failed 30
advance_boundary_snapshot app "$APP" || fail unexpected-signing-mutation 25

discard_invalid_evidence() {
  /usr/bin/python3 -I - "$CANDIDATE" <<'PY' >/dev/null 2>&1
import os
import stat
import sys

candidate = sys.argv[1]
descriptor = -1
try:
    descriptor = os.open(
        candidate,
        os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        metadata = os.stat("signature-verification.json", dir_fd=descriptor, follow_symlinks=False)
    except FileNotFoundError:
        raise SystemExit(0)
    if stat.S_ISDIR(metadata.st_mode):
        raise OSError
    os.unlink("signature-verification.json", dir_fd=descriptor)
except OSError:
    raise SystemExit(1)
finally:
    if descriptor >= 0:
        os.close(descriptor)
PY
}

IFS= read -r verifier_record < "$CONTROL/verifier-record" || fail signature-verification-failed 31
IFS= read -r pinned_verifier_record < "$CONTROL/pinned-verifier-record" || fail signature-verification-failed 31
revalidate_boundary_snapshot || fail candidate-changed-before-verification 31
revalidate_record "$verifier_record" || fail signature-verification-failed 31
revalidate_record "$pinned_verifier_record" || fail signature-verification-failed 31
if ! "$PINNED_VERIFIER" \
  --candidate "$CANDIDATE" \
  --identity "$IDENTITY" \
  --team-id "$TEAM_ID" \
  --expected-certificate-sha256 "$CERTIFICATE_SHA256" \
  --output "$EVIDENCE" \
  > "$CONTROL/tool-output.txt" 2> "$CONTROL/tool-error.txt"; then
  discard_invalid_evidence || fail evidence-cleanup-failed 31
  fail signature-verification-failed 31
fi
revalidate_boundary_snapshot || {
  discard_invalid_evidence || fail evidence-cleanup-failed 31
  fail candidate-changed-during-verification 31
}
revalidate_record "$verifier_record" || {
  discard_invalid_evidence || fail evidence-cleanup-failed 31
  fail signature-verifier-changed 31
}
revalidate_record "$pinned_verifier_record" || {
  discard_invalid_evidence || fail evidence-cleanup-failed 31
  fail pinned-signature-verifier-changed 31
}
if ! /usr/bin/python3 -I - \
  "$EVIDENCE" "$APP" "$CONTROL/verification-components" "$TEAM_ID" \
  "$SOURCE_COMMIT" "$CANDIDATE_JSON_SHA256" "$UNSIGNED_BUILD_EVIDENCE_SHA256" \
  "$CERTIFICATE_SHA256" <<'PY' >/dev/null 2>&1
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys


MAX_EVIDENCE_BYTES = 4 * 1024 * 1024


def abort() -> None:
    raise SystemExit(1)


def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, item in pairs:
        if key in value:
            abort()
        value[key] = item
    return value


def fingerprint(item: os.stat_result) -> tuple[int, ...]:
    return (
        item.st_dev, item.st_ino, item.st_mode, item.st_uid, item.st_nlink,
        item.st_size, item.st_mtime_ns, item.st_ctime_ns,
    )


def read_regular(path: Path) -> bytes:
    before = os.lstat(path)
    if (
        not stat.S_ISREG(before.st_mode)
        or stat.S_ISLNK(before.st_mode)
        or before.st_nlink != 1
        or before.st_uid != os.geteuid()
        or before.st_mode & 0o022
        or before.st_size <= 0
        or before.st_size > MAX_EVIDENCE_BYTES
    ):
        abort()
    descriptor = os.open(
        path,
        os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        opened = os.fstat(descriptor)
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, 65536)
            if not chunk:
                break
            total += len(chunk)
            if total > MAX_EVIDENCE_BYTES:
                abort()
            chunks.append(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    if fingerprint(before) != fingerprint(opened) or fingerprint(opened) != fingerprint(after):
        abort()
    return b"".join(chunks)


def checked_target(relative: str, target: str) -> str:
    if (
        not target
        or len(target.encode("utf-8", errors="strict")) > 4096
        or PurePosixPath(target).is_absolute()
        or ".." in PurePosixPath(target).parts
        or any(ord(character) < 32 or ord(character) == 127 for character in target)
    ):
        abort()
    joined = PurePosixPath(relative).parent.joinpath(PurePosixPath(target))
    if joined.is_absolute() or ".." in joined.parts:
        abort()
    return target


def logical_tree(root: Path) -> str:
    root_metadata = os.lstat(root)
    if not stat.S_ISDIR(root_metadata.st_mode) or stat.S_ISLNK(root_metadata.st_mode):
        abort()
    records: list[tuple[bytes, list[object]]] = []
    pending = [root]
    while pending:
        directory = pending.pop()
        for path in directory.iterdir():
            metadata = os.lstat(path)
            relative = path.relative_to(root).as_posix()
            encoded_relative = relative.encode("utf-8", errors="strict")
            if (
                not relative
                or any(byte < 32 or byte == 127 for byte in encoded_relative)
                or metadata.st_dev != root_metadata.st_dev
                or metadata.st_uid != os.geteuid()
                or (not stat.S_ISLNK(metadata.st_mode) and metadata.st_mode & 0o022)
            ):
                abort()
            mode = stat.S_IMODE(metadata.st_mode)
            if stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode):
                kind, payload = "directory", ""
                pending.append(path)
            elif stat.S_ISREG(metadata.st_mode):
                if metadata.st_nlink != 1:
                    abort()
                descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
                try:
                    opened = os.fstat(descriptor)
                    digest = hashlib.sha256()
                    while True:
                        chunk = os.read(descriptor, 65536)
                        if not chunk:
                            break
                        digest.update(chunk)
                    after = os.fstat(descriptor)
                finally:
                    os.close(descriptor)
                if fingerprint(metadata) != fingerprint(opened) or fingerprint(opened) != fingerprint(after):
                    abort()
                kind, payload = "file", digest.hexdigest()
            elif stat.S_ISLNK(metadata.st_mode):
                kind, payload = "symlink", checked_target(relative, os.readlink(path))
            else:
                abort()
            records.append((encoded_relative, [relative, kind, mode, payload]))
    records.sort(key=lambda item: item[0])
    digest = hashlib.sha256()
    for _, record in records:
        line = json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n"
        digest.update(line.encode("utf-8"))
    return digest.hexdigest()


try:
    evidence_path = Path(sys.argv[1])
    app = Path(sys.argv[2])
    expected_records = []
    for line in Path(sys.argv[3]).read_text(encoding="utf-8").splitlines():
        fields = line.split("\t")
        if len(fields) != 2 or fields[0] not in {"bundle", "mach-o"}:
            abort()
        expected_records.append((fields[0], fields[1]))
    if not expected_records or len(expected_records) != len(set(expected_records)):
        abort()
    team, commit, candidate_hash, unsigned_hash, certificate_hash = sys.argv[4:9]
    raw = read_regular(evidence_path)
    evidence = json.loads(raw.decode("utf-8", errors="strict"), object_pairs_hook=unique_object)
    top_keys = {
        "candidateCommit", "candidateJSONSHA256", "certificate", "components",
        "evidenceType", "product", "schemaVersion", "signedAppTreeSHA256", "status",
        "teamID", "treeAlgorithm", "unsignedBuildEvidenceSHA256",
    }
    if type(evidence) is not dict or set(evidence) != top_keys:
        abort()
    canonical = (json.dumps(evidence, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    if raw != canonical:
        abort()
    if (
        type(evidence["schemaVersion"]) is not int
        or evidence["schemaVersion"] != 1
        or evidence["evidenceType"] != "signature-verification"
        or type(evidence["evidenceType"]) is not str
        or evidence["product"] != "UtterInk"
        or type(evidence["product"]) is not str
        or evidence["status"] != "valid"
        or type(evidence["status"]) is not str
        or evidence["teamID"] != team
        or type(evidence["teamID"]) is not str
        or evidence["candidateCommit"] != commit
        or type(evidence["candidateCommit"]) is not str
        or evidence["candidateJSONSHA256"] != candidate_hash
        or type(evidence["candidateJSONSHA256"]) is not str
        or evidence["unsignedBuildEvidenceSHA256"] != unsigned_hash
        or type(evidence["unsignedBuildEvidenceSHA256"]) is not str
        or evidence["treeAlgorithm"] != "utterink-logical-tree-v1"
        or type(evidence["treeAlgorithm"]) is not str
    ):
        abort()
    for key in ("candidateJSONSHA256", "unsignedBuildEvidenceSHA256", "signedAppTreeSHA256"):
        if type(evidence[key]) is not str or re.fullmatch(r"[0-9a-f]{64}", evidence[key]) is None:
            abort()
    if re.fullmatch(r"[0-9a-f]{40}", evidence["candidateCommit"]) is None:
        abort()
    if evidence["signedAppTreeSHA256"] != logical_tree(app):
        abort()

    certificate = evidence["certificate"]
    if type(certificate) is not dict or set(certificate) != {"notAfter", "notBefore", "sha256", "trust"}:
        abort()
    if certificate["sha256"] != certificate_hash or certificate["trust"] != "valid":
        abort()
    if re.fullmatch(r"[0-9a-f]{64}", certificate["sha256"]) is None:
        abort()
    for key in ("notAfter", "notBefore"):
        value = certificate[key]
        if type(value) is not str or not value or len(value) > 128 or any(ord(character) < 32 or ord(character) == 127 for character in value):
            abort()

    components = evidence["components"]
    if type(components) is not list or len(components) != len(expected_records):
        abort()
    observed: list[tuple[str, str]] = []
    component_keys = {
        "architecture", "designatedRequirement", "entitlements", "identifier", "kind",
        "path", "runtime", "secureTimestamp", "sha256", "teamID", "trust",
    }
    app_entitlements = {"com.apple.security.device.audio-input": True}
    for component in components:
        if type(component) is not dict or set(component) != component_keys:
            abort()
        kind, path = component["kind"], component["path"]
        if type(kind) is not str or type(path) is not str:
            abort()
        observed.append((kind, path))
        if (
            component["teamID"] != team
            or type(component["teamID"]) is not str
            or component["trust"] != "valid"
            or component["runtime"] != "hardened"
            or component["secureTimestamp"] != "present"
            or component["designatedRequirement"] != "valid"
            or type(component["identifier"]) is not str
            or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,255}", component["identifier"]) is None
            or type(component["sha256"]) is not str
            or re.fullmatch(r"[0-9a-f]{64}", component["sha256"]) is None
        ):
            abort()
        expected_architecture = "arm64" if kind == "mach-o" else None
        if component["architecture"] != expected_architecture:
            abort()
        app_role = path in {"UtterInk.app", "UtterInk.app/Contents/MacOS/UtterInk"}
        if component["entitlements"] != (app_entitlements if app_role else {}):
            abort()
        if app_role and component["identifier"] != "dev.utterink.UtterInk":
            abort()
    if sorted(observed, key=lambda item: item[1].encode("utf-8")) != expected_records:
        abort()
except (OSError, UnicodeError, ValueError, json.JSONDecodeError):
    abort()
PY
then
  discard_invalid_evidence || fail evidence-cleanup-failed 31
  fail signature-verification-failed 31
fi

exit 0
