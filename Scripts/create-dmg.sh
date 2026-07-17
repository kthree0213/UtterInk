#!/usr/bin/env -S -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u BASH_XTRACEFD -u PS4 -u POSIXLY_CORRECT -u BASH_COMPAT -u UTTERINK_DMG_ENV_CLEAN /bin/bash -p

set +x +v
if [[ "$-" != *p* ]]; then
  printf 'DMG creation error: unsafe-launch-environment\n' >&2
  exit 2
fi
if [[ "${UTTERINK_DMG_ENV_CLEAN:-}" != 1 ]]; then
  clean_environment=(
    PATH=/usr/bin:/bin:/usr/sbin:/sbin
    LC_ALL=C
    UTTERINK_DMG_ENV_CLEAN=1
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
  if [[ "${UTTERINK_RELEASE_TEST_MODE:-}" == 1 && -n "${UTTERINK_DMG_TEST_PUBLISH_RACE+x}" ]]; then
    clean_environment+=("UTTERINK_DMG_TEST_PUBLISH_RACE=${UTTERINK_DMG_TEST_PUBLISH_RACE}")
  fi
  exec /usr/bin/env -i "${clean_environment[@]}" /bin/bash -p "$0" "$@"
  printf 'DMG creation error: unsafe-launch-environment\n' >&2
  exit 2
fi
if [[ "$-" != hpB || "${PATH-}" != /usr/bin:/bin:/usr/sbin:/sbin || "${LC_ALL-}" != C ]]; then
  printf 'DMG creation error: unsafe-launch-environment\n' >&2
  exit 2
fi
while IFS= read -r -d '' environment_entry; do
  environment_name="${environment_entry%%=*}"
  case "$environment_name" in
    PATH|LC_ALL|UTTERINK_DMG_ENV_CLEAN|UTTERINK_RELEASE_TEST_MODE|UTTERINK_RELEASE_TEST_TOOL_ROOT|UTTERINK_FIXTURE_LOG|UTTERINK_DMG_TEST_PUBLISH_RACE|PWD|SHLVL|_) ;;
    *)
      printf 'DMG creation error: unsafe-launch-environment\n' >&2
      exit 2
      ;;
  esac
done < <(/usr/bin/env -0)
unset UTTERINK_DMG_ENV_CLEAN

set -euo pipefail

export LC_ALL=C
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PYTHONDONTWRITEBYTECODE=1
export TZ=UTC
unset \
  BASH_ENV ENV CDPATH GLOBIGNORE PYTHONHOME PYTHONPATH \
  DEVELOPER_DIR SDKROOT TOOLCHAINS XCODE_DEFAULT_TOOLCHAIN_OVERRIDE \
  DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH
umask 077

fail() {
  local category="$1"
  local status="${2:-1}"
  printf 'DMG creation error: %s\n' "$category" >&2
  exit "$status"
}

APP_ARGUMENT=''
OUTPUT_ARGUMENT=''
MODE=''
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --app)
      [[ -z "$APP_ARGUMENT" && "$#" -ge 2 && -n "$2" ]] || fail invalid-arguments 2
      APP_ARGUMENT="$2"
      shift 2
      ;;
    --output)
      [[ -z "$OUTPUT_ARGUMENT" && "$#" -ge 2 && -n "$2" ]] || fail invalid-arguments 2
      OUTPUT_ARGUMENT="$2"
      shift 2
      ;;
    --mode)
      [[ -z "$MODE" && "$#" -ge 2 && -n "$2" ]] || fail invalid-arguments 2
      MODE="$2"
      shift 2
      ;;
    *) fail invalid-arguments 2 ;;
  esac
done
[[ -n "$APP_ARGUMENT" && -n "$OUTPUT_ARGUMENT" ]] || fail invalid-arguments 2
case "$MODE" in
  unsigned|signed) ;;
  *) fail invalid-arguments 2 ;;
esac

readonly SCRIPT_PATH="${BASH_SOURCE[0]}"
[[ -f "$SCRIPT_PATH" && ! -L "$SCRIPT_PATH" ]] || fail unsafe-script-path
SCRIPT_DIRECTORY="$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "$SCRIPT_PATH")" && /bin/pwd -P)" ||
  fail unsafe-script-path
readonly SCRIPT_DIRECTORY
ROOT="$(CDPATH= cd -P -- "$SCRIPT_DIRECTORY/.." && /bin/pwd -P)" || fail unsafe-script-path
readonly ROOT
GIT_ROOT="$(/usr/bin/git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" || fail not-a-repository
GIT_ROOT="$(CDPATH= cd -P -- "$GIT_ROOT" && /bin/pwd -P)" || fail not-a-repository
[[ "$GIT_ROOT" == "$ROOT" ]] || fail repository-mismatch
cd "$ROOT"

[[ -d /private/tmp && ! -L /private/tmp ]] || fail unsafe-temporary-root
CONTROL="$(/usr/bin/mktemp -d /private/tmp/utterink-create-dmg.XXXXXX)" || fail temporary-directory-unavailable
[[ "$CONTROL" == /private/tmp/utterink-create-dmg.* && -d "$CONTROL" && ! -L "$CONTROL" ]] ||
  fail temporary-directory-unavailable
/bin/chmod 0700 "$CONTROL" || fail temporary-directory-unavailable
WORK=''
WORK_DEVICE=''
WORK_INODE=''
RELEASE_WORK="$ROOT/.release-work"
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
    or re.fullmatch(r"[.]utterink-create-dmg[.][A-Za-z0-9]{6,32}", relative.parts[1]) is None
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
  if [[ "$CONTROL" == /private/tmp/utterink-create-dmg.* && -d "$CONTROL" && ! -L "$CONTROL" ]]; then
    /bin/rm -rf -- "$CONTROL"
  fi
  exit "$status"
}
handle_signal() {
  local signal_status="$1"
  trap - HUP INT TERM
  exit "$signal_status"
}
trap cleanup EXIT
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

readonly METADATA_READER="$ROOT/Scripts/release/read-metadata.py"
[[ -f "$METADATA_READER" && ! -L "$METADATA_READER" ]] || fail unsafe-metadata-reader
if ! /usr/bin/python3 -I "$METADATA_READER" --json > "$CONTROL/metadata.json" 2> "$CONTROL/metadata-error"; then
  fail invalid-release-metadata
fi
if ! /usr/bin/python3 -I - "$CONTROL/metadata.json" "$CONTROL/expected-filename" "$MODE" <<'PY'
from __future__ import annotations

import json
from pathlib import Path
import re
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


metadata_path, output_path, mode = (Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3])
try:
    if metadata_path.stat().st_size > 128 * 1024:
        abort()
    metadata = json.loads(
        metadata_path.read_text(encoding="utf-8"),
        object_pairs_hook=duplicate_keys,
    )
except (OSError, UnicodeError, json.JSONDecodeError):
    abort()

expected_keys = {
    "architecture",
    "buildNumber",
    "bundleIdentifier",
    "configuration",
    "deploymentTarget",
    "dmgFilename",
    "marketingVersion",
    "product",
    "releaseTag",
}
if type(metadata) is not dict or set(metadata) != expected_keys:
    abort()
if metadata["product"] != "UtterInk" or metadata["configuration"] != "Release":
    abort()
if metadata["architecture"] != "arm64":
    abort()
version = metadata["marketingVersion"]
if type(version) is not str or re.fullmatch(r"(?:0|[1-9][0-9]*)[.](?:0|[1-9][0-9]*)[.](?:0|[1-9][0-9]*)", version) is None:
    abort()
signed_name = f"UtterInk-{version}-arm64.dmg"
if metadata["dmgFilename"] != signed_name:
    abort()
if mode == "unsigned":
    expected_name = f"UtterInk-{version}-arm64-UNSIGNED-DO-NOT-DISTRIBUTE.dmg"
elif mode == "signed":
    expected_name = signed_name
else:
    abort()
output_path.write_text(expected_name, encoding="utf-8")
PY
then
  fail invalid-release-metadata
fi
EXPECTED_FILENAME="$(/bin/cat "$CONTROL/expected-filename")" || fail invalid-release-metadata
[[ -n "$EXPECTED_FILENAME" ]] || fail invalid-release-metadata
readonly EXPECTED_FILENAME

if ! /usr/bin/python3 -I - \
  "$ROOT" "$APP_ARGUMENT" "$OUTPUT_ARGUMENT" "$EXPECTED_FILENAME" \
  "$CONTROL/app-path" "$CONTROL/output-path" 0 <<'PY'
from __future__ import annotations

import os
from pathlib import Path, PurePath
import stat
import sys


def abort() -> None:
    raise SystemExit(1)


root = Path(sys.argv[1])
raw_app, raw_output, expected_filename = sys.argv[2:5]
app_file, output_file = Path(sys.argv[5]), Path(sys.argv[6])
require_output_parent = sys.argv[7] == "1"

for raw in (raw_app, raw_output):
    if not raw or len(raw.encode("utf-8", errors="strict")) > 4096:
        abort()
    if any(ord(character) < 32 or ord(character) == 127 for character in raw):
        abort()
    parts = PurePath(raw).parts
    if ".." in parts or "." in parts:
        abort()

try:
    root = root.resolve(strict=True)
except OSError:
    abort()
if not root.is_dir() or root.is_symlink():
    abort()


def normalized(raw: str) -> Path:
    candidate = Path(raw) if os.path.isabs(raw) else root / raw
    candidate = Path(os.path.normpath(str(candidate)))
    try:
        candidate.relative_to(root)
    except ValueError:
        abort()
    return candidate


app = normalized(raw_app)
output = normalized(raw_output)
try:
    app_relative = app.relative_to(root)
    output_relative = output.relative_to(root)
except ValueError:
    abort()
if not app_relative.parts or app_relative.parts[0] not in {"build", ".release-work"}:
    abort()
if not output_relative.parts or output_relative.parts[0] not in {"dist", ".release-work"}:
    abort()
if app.name != "UtterInk.app" or output.name != expected_filename:
    abort()
if app == output or app in output.parents or output in app.parents:
    abort()


def verify_existing_components(path: Path, include_leaf: bool) -> None:
    relative = path.relative_to(root)
    current = root
    components = relative.parts if include_leaf else relative.parts[:-1]
    missing_seen = False
    for component in components:
        current = current / component
        try:
            metadata = os.lstat(current)
        except FileNotFoundError:
            missing_seen = True
            continue
        except OSError:
            abort()
        if missing_seen or stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
            abort()


verify_existing_components(app, include_leaf=False)
verify_existing_components(output, include_leaf=False)
try:
    app_metadata = os.lstat(app)
except OSError:
    abort()
if stat.S_ISLNK(app_metadata.st_mode) or not stat.S_ISDIR(app_metadata.st_mode):
    abort()
try:
    os.lstat(output)
except FileNotFoundError:
    pass
except OSError:
    abort()
else:
    abort()
if require_output_parent:
    try:
        parent_metadata = os.lstat(output.parent)
    except OSError:
        abort()
    if stat.S_ISLNK(parent_metadata.st_mode) or not stat.S_ISDIR(parent_metadata.st_mode):
        abort()

app_file.write_text(str(app), encoding="utf-8")
output_file.write_text(str(output), encoding="utf-8")
PY
then
  fail unsafe-path
fi
APP="$(/bin/cat "$CONTROL/app-path")" || fail unsafe-path
OUTPUT="$(/bin/cat "$CONTROL/output-path")" || fail unsafe-path
readonly APP OUTPUT

TEST_MODE=0
PUBLISH_RACE=0
case "${UTTERINK_RELEASE_TEST_MODE:-}" in
  '') ;;
  1) TEST_MODE=1 ;;
  *) fail invalid-test-mode ;;
esac
if [[ "$TEST_MODE" -eq 1 ]]; then
  case "$ROOT" in
    /private/tmp/*) ;;
    *) fail test-mode-not-allowed ;;
  esac
  TOOL_ROOT="${UTTERINK_RELEASE_TEST_TOOL_ROOT:-}"
  [[ "$TOOL_ROOT" == "$ROOT/FixtureTools" && -d "$TOOL_ROOT" && ! -L "$TOOL_ROOT" ]] ||
    fail invalid-test-tool-root
  MARKER="$TOOL_ROOT/.utterink-dmg-test-fixture"
  [[ -f "$MARKER" && ! -L "$MARKER" ]] || fail invalid-test-tool-root
  [[ "$(/bin/cat "$MARKER")" == utterink-offline-dmg-fixture-v1 ]] || fail invalid-test-tool-root
  case "${UTTERINK_DMG_TEST_PUBLISH_RACE:-}" in
    '') ;;
    1) PUBLISH_RACE=1 ;;
    *) fail invalid-test-publish-race ;;
  esac
  DITTO="$TOOL_ROOT/ditto"
  HDIUTIL="$TOOL_ROOT/hdiutil"
else
  unset UTTERINK_RELEASE_TEST_TOOL_ROOT UTTERINK_FIXTURE_LOG UTTERINK_DMG_TEST_PUBLISH_RACE
  DITTO=/usr/bin/ditto
  HDIUTIL=/usr/bin/hdiutil
fi
unset UTTERINK_DMG_TEST_PUBLISH_RACE
for tool in "$DITTO" "$HDIUTIL"; do
  [[ -f "$tool" && -x "$tool" && ! -L "$tool" ]] || fail packaging-tool-unavailable
done
readonly TEST_MODE PUBLISH_RACE DITTO HDIUTIL

[[ ! -L "$RELEASE_WORK" ]] || fail temporary-directory-unavailable
if [[ ! -e "$RELEASE_WORK" ]]; then
  /bin/mkdir -m 0700 "$RELEASE_WORK" || fail temporary-directory-unavailable
fi
if ! /usr/bin/python3 -I - "$ROOT" "$RELEASE_WORK" <<'PY' >/dev/null 2>&1
import os
from pathlib import Path
import stat
import sys

root, release_work = map(Path, sys.argv[1:3])
try:
    root_metadata = os.lstat(root)
    work_metadata = os.lstat(release_work)
except OSError:
    raise SystemExit(1)
if (
    not stat.S_ISDIR(root_metadata.st_mode)
    or stat.S_ISLNK(root_metadata.st_mode)
    or not stat.S_ISDIR(work_metadata.st_mode)
    or stat.S_ISLNK(work_metadata.st_mode)
    or work_metadata.st_uid != os.geteuid()
    or stat.S_IMODE(work_metadata.st_mode) != 0o700
    or work_metadata.st_dev != root_metadata.st_dev
):
    raise SystemExit(1)
PY
then
  fail temporary-directory-unavailable
fi
WORK="$(/usr/bin/mktemp -d "$RELEASE_WORK/.utterink-create-dmg.XXXXXX")" ||
  fail temporary-directory-unavailable
[[ "$WORK" == "$RELEASE_WORK"/.utterink-create-dmg.* && -d "$WORK" && ! -L "$WORK" ]] ||
  fail temporary-directory-unavailable
/bin/chmod 0700 "$WORK" || fail temporary-directory-unavailable
if ! WORK_IDENTITY="$(/usr/bin/python3 -I - "$ROOT" "$RELEASE_WORK" "$WORK" <<'PY'
import os
from pathlib import Path
import stat
import sys

root, release_work, work = map(Path, sys.argv[1:4])
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
        or stat.S_IMODE(metadata.st_mode) != 0o700
        or metadata.st_dev != root_metadata.st_dev
    ):
        raise SystemExit(1)
print(f"{work_metadata.st_dev}:{work_metadata.st_ino}")
PY
)"; then
  fail temporary-directory-unavailable
fi
IFS=: read -r WORK_DEVICE WORK_INODE <<< "$WORK_IDENTITY"
[[ "$WORK_DEVICE" =~ ^[0-9]+$ && "$WORK_INODE" =~ ^[0-9]+$ ]] ||
  fail temporary-directory-unavailable
/bin/mkdir -m 0700 "$WORK/home" "$WORK/tmp" "$WORK/stage" || fail temporary-directory-unavailable
export HOME="$WORK/home"
export TMPDIR="$WORK/tmp"
STAGE="$WORK/stage"
STAGED_APP="$STAGE/UtterInk.app"
TEMP_DMG="$WORK/UtterInk.dmg"
readonly STAGE STAGED_APP TEMP_DMG

snapshot_bundle() {
  local bundle="$1"
  local output="$2"
  local detail="$3"
  local policy="${4:-copy}"
  /usr/bin/python3 -I - "$bundle" "$output" "$detail" "$TEST_MODE" "$policy" <<'PY'
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys


def abort() -> None:
    raise SystemExit(1)


bundle, output = Path(sys.argv[1]), Path(sys.argv[2])
detailed = sys.argv[3] == "detailed"
test_fixture = sys.argv[4] == "1"
require_executable_policy = sys.argv[5] == "source"
try:
    bundle_metadata = os.lstat(bundle)
except OSError:
    abort()
if stat.S_ISLNK(bundle_metadata.st_mode) or not stat.S_ISDIR(bundle_metadata.st_mode):
    abort()
try:
    bundle_resolved = bundle.resolve(strict=True)
except OSError:
    abort()

records: list[dict[str, object]] = []
file_count = 0
total_bytes = 0


def xattrs(path: Path) -> list[list[str]]:
    values: list[list[str]] = []
    environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"}
    listed = subprocess.run(
        ["/usr/bin/xattr", "-s", str(path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
        env=environment,
    )
    if listed.returncode != 0:
        abort()
    try:
        names = sorted(listed.stdout.decode("utf-8", errors="strict").splitlines())
    except UnicodeError:
        abort()
    if len(names) != len(set(names)):
        abort()
    if not names:
        return values
    # Current macOS can force-attach an inert, non-removable provenance marker
    # to newly-created files. Accept only the same canonical marker shape that
    # the candidate builder validates; quarantine, Finder metadata, credentials,
    # additional names, and malformed provenance values remain forbidden.
    if set(names) != {"com.apple.provenance"}:
        abort()
    provenance = subprocess.run(
        ["/usr/bin/xattr", "-s", "-px", "com.apple.provenance", str(path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
        env=environment,
    )
    if provenance.returncode != 0:
        abort()
    try:
        value = bytes.fromhex(provenance.stdout.decode("ascii", errors="strict"))
    except (UnicodeError, ValueError):
        abort()
    if len(value) != 11 or value[:3] != b"\x01\x02\x00":
        abort()
    return values


def regular_digest(path: Path, expected: os.stat_result) -> str:
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
        actual = os.fstat(descriptor)
        if (actual.st_dev, actual.st_ino) != (expected.st_dev, expected.st_ino) or not stat.S_ISREG(actual.st_mode):
            abort()
        digest = hashlib.sha256()
        with os.fdopen(descriptor, "rb", closefd=True) as handle:
            descriptor = -1
            while True:
                chunk = handle.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
        return digest.hexdigest()
    except OSError:
        abort()
    finally:
        if "descriptor" in locals() and descriptor >= 0:
            os.close(descriptor)


pending = [bundle]
while pending:
    path = pending.pop()
    try:
        metadata = os.lstat(path)
        relative = path.relative_to(bundle)
        relative_text = "." if not relative.parts else relative.as_posix()
        relative_text.encode("utf-8", errors="strict")
    except (OSError, UnicodeError, ValueError):
        abort()
    if any(ord(character) < 32 or ord(character) == 127 for character in relative_text):
        abort()
    record: dict[str, object] = {
        "path": relative_text,
        "mode": stat.S_IMODE(metadata.st_mode),
        "xattrs": xattrs(path),
    }
    if stat.S_ISDIR(metadata.st_mode):
        record["kind"] = "directory"
        try:
            children = sorted(path.iterdir(), key=lambda child: child.name.encode("utf-8", errors="strict"), reverse=True)
        except (OSError, UnicodeError):
            abort()
        pending.extend(children)
    elif stat.S_ISREG(metadata.st_mode):
        if metadata.st_nlink != 1:
            abort()
        file_count += 1
        total_bytes += metadata.st_size
        if file_count > 100_000 or total_bytes > 8 * 1024 * 1024 * 1024:
            abort()
        record["kind"] = "file"
        record["size"] = metadata.st_size
        record["sha256"] = regular_digest(path, metadata)
    elif stat.S_ISLNK(metadata.st_mode):
        try:
            target = os.readlink(path)
            if os.path.isabs(target):
                abort()
            resolved = path.resolve(strict=True)
            resolved.relative_to(bundle_resolved)
        except (OSError, RuntimeError, UnicodeError, ValueError):
            abort()
        if any(ord(character) < 32 or ord(character) == 127 for character in target):
            abort()
        record["kind"] = "symlink"
        record["target"] = target
    else:
        abort()
    if detailed:
        record.update(
            {
                "mode": stat.S_IMODE(metadata.st_mode),
                "uid": metadata.st_uid,
                "gid": metadata.st_gid,
                "mtimeNS": metadata.st_mtime_ns,
                "ctimeNS": metadata.st_ctime_ns,
                "flags": getattr(metadata, "st_flags", 0),
            }
        )
    records.append(record)

required = (
    bundle / "Contents" / "Info.plist",
    bundle / "Contents" / "MacOS" / "UtterInk",
)
for required_path in required:
    try:
        metadata = os.lstat(required_path)
    except OSError:
        abort()
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        abort()
    if required_path.name == "UtterInk" and require_executable_policy and (
        metadata.st_uid != os.geteuid()
        or stat.S_IMODE(metadata.st_mode) != 0o755
    ):
        abort()

records.sort(key=lambda item: str(item["path"]).encode("utf-8"))
try:
    output.write_text(
        json.dumps(records, sort_keys=True, separators=(",", ":")),
        encoding="utf-8",
    )
except OSError:
    abort()
PY
}

snapshot_bundle "$APP" "$CONTROL/source-before.json" detailed source || fail unsafe-app-bundle
snapshot_bundle "$APP" "$CONTROL/source-content.json" content source || fail unsafe-app-bundle

if ! "$DITTO" "$APP" "$STAGED_APP" > "$WORK/ditto-output" 2> "$WORK/ditto-error"; then
  fail app-copy-failed
fi
[[ -d "$STAGED_APP" && ! -L "$STAGED_APP" ]] || fail app-copy-failed
snapshot_bundle "$STAGED_APP" "$CONTROL/staged-content.json" content || fail app-copy-failed
/usr/bin/cmp -s "$CONTROL/source-content.json" "$CONTROL/staged-content.json" || fail app-copy-mismatch
snapshot_bundle "$STAGED_APP" "$CONTROL/staged-before.json" detailed || fail app-copy-failed

/bin/ln -s /Applications "$STAGE/Applications" || fail presentation-layout-failed
[[ -L "$STAGE/Applications" && "$(/usr/bin/readlink "$STAGE/Applications")" == /Applications ]] ||
  fail presentation-layout-failed
/bin/chmod 0755 "$STAGE" || fail presentation-layout-failed
/usr/bin/touch -h -t 202001010000 "$STAGE/Applications" || fail presentation-layout-failed
/usr/bin/touch -t 202001010000 "$STAGE" || fail presentation-layout-failed

if ! /usr/bin/python3 -I - "$STAGE" <<'PY'
from pathlib import Path
import os
import stat
import sys

stage = Path(sys.argv[1])
try:
    entries = sorted(item.name for item in stage.iterdir())
    app = os.lstat(stage / "UtterInk.app")
    applications = os.lstat(stage / "Applications")
    target = os.readlink(stage / "Applications")
except OSError:
    raise SystemExit(1)
if entries != ["Applications", "UtterInk.app"]:
    raise SystemExit(1)
if not stat.S_ISDIR(app.st_mode) or stat.S_ISLNK(app.st_mode):
    raise SystemExit(1)
if not stat.S_ISLNK(applications.st_mode) or target != "/Applications":
    raise SystemExit(1)
PY
then
  fail presentation-layout-failed
fi

if ! "$HDIUTIL" create \
  -quiet \
  -format UDZO \
  -imagekey zlib-level=9 \
  -fs HFS+ \
  -volname UtterInk \
  -srcfolder "$STAGE" \
  "$TEMP_DMG" > "$WORK/hdiutil-output" 2> "$WORK/hdiutil-error"; then
  fail hdiutil-create-failed
fi
[[ -f "$TEMP_DMG" && ! -L "$TEMP_DMG" && -s "$TEMP_DMG" ]] || fail invalid-dmg-output

snapshot_bundle "$APP" "$CONTROL/source-after.json" detailed source || fail source-app-mutated
/usr/bin/cmp -s "$CONTROL/source-before.json" "$CONTROL/source-after.json" || fail source-app-mutated
snapshot_bundle "$STAGED_APP" "$CONTROL/staged-after.json" detailed || fail staged-app-mutated
/usr/bin/cmp -s "$CONTROL/staged-before.json" "$CONTROL/staged-after.json" || fail staged-app-mutated

# Create every destination directory and publish the already-built image while
# holding directory descriptors rooted at the repository. The operation never
# resolves an output component through an absolute path after opening ROOT, and
# verifies the complete directory identity chain both before and after link(2).
if ! /usr/bin/python3 -I - \
  "$ROOT" "$TEMP_DMG" "$OUTPUT" "$EXPECTED_FILENAME" "$PUBLISH_RACE" <<'PY' >/dev/null 2>&1
from __future__ import annotations

import os
from pathlib import Path
import stat
import sys
import time


class PublishError(Exception):
    pass


root_path = Path(sys.argv[1])
source_path = Path(sys.argv[2])
output_path = Path(sys.argv[3])
expected_filename = sys.argv[4]
race_hook = sys.argv[5] == "1"
directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
file_flags = os.O_RDONLY | os.O_NOFOLLOW
root_fd = -1
root_device = -1
source_parent_fd = -1
source_fd = -1
directory_fds: list[int] = []
records: list[tuple[int, str, int, tuple[int, int], bool]] = []
published = False
source_identity: tuple[int, int] | None = None
target_name = ""


def identity(metadata: os.stat_result) -> tuple[int, int]:
    return metadata.st_dev, metadata.st_ino


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
    for parent_fd, component, child_fd, expected_identity, created in reversed(records):
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
    ready_name = ".utterink-dmg-publish-race-ready"
    go_name = ".utterink-dmg-publish-race-go"
    ready_identity: tuple[int, int] | None = None
    try:
        marker_fd = os.open(
            ".utterink-dmg-test-fixture", file_flags, dir_fd=tool_fd
        )
        try:
            marker_metadata = os.fstat(marker_fd)
            marker = os.read(marker_fd, 128)
            if (
                not stat.S_ISREG(marker_metadata.st_mode)
                or marker_metadata.st_uid != os.geteuid()
                or marker != b"utterink-offline-dmg-fixture-v1\n"
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
        output_relative = output_path.relative_to(root_path)
    except ValueError as error:
        raise PublishError from error
    source_parts = source_relative.parts
    output_parts = output_relative.parts
    if (
        len(source_parts) < 2
        or len(output_parts) < 2
        or output_parts[0] not in {"dist", ".release-work"}
        or output_parts[-1] != expected_filename
        or any(part in {"", ".", ".."} for part in source_parts + output_parts)
    ):
        raise PublishError

    source_parent_fd = open_existing_parent(source_parts[:-1])
    source_fd = os.open(source_parts[-1], file_flags, dir_fd=source_parent_fd)
    source_metadata = os.fstat(source_fd)
    if (
        not stat.S_ISREG(source_metadata.st_mode)
        or source_metadata.st_dev != root_device
        or source_metadata.st_size <= 0
    ):
        raise PublishError
    source_identity = identity(source_metadata)

    directory_fds.append(root_fd)
    for component in output_parts[:-1]:
        parent_fd = directory_fds[-1]
        created = False
        try:
            os.mkdir(component, 0o755, dir_fd=parent_fd)
            created = True
        except FileExistsError:
            pass
        child_fd = open_directory(parent_fd, component)
        child_identity = identity(os.fstat(child_fd))
        directory_fds.append(child_fd)
        records.append((parent_fd, component, child_fd, child_identity, created))

    target_name = output_parts[-1]
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
    target_metadata = os.stat(
        target_name, dir_fd=records[-1][2], follow_symlinks=False
    )
    if (
        not stat.S_ISREG(target_metadata.st_mode)
        or target_metadata.st_size <= 0
        or identity(target_metadata) != source_identity
        or identity(os.fstat(source_fd)) != source_identity
        or not chain_is_current()
    ):
        raise PublishError
    os.unlink(source_parts[-1], dir_fd=source_parent_fd)
    target_metadata = os.stat(
        target_name, dir_fd=records[-1][2], follow_symlinks=False
    )
    if identity(target_metadata) != source_identity or not chain_is_current():
        raise PublishError
except (OSError, PublishError):
    remove_published_target()
    rollback_directories()
    raise SystemExit(1)
finally:
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
  fail output-publish-failed
fi

safe_remove_work "$WORK" "$WORK_DEVICE" "$WORK_INODE" || fail work-cleanup-failed
WORK=''
WORK_DEVICE=''
WORK_INODE=''
printf '%s\n' "${OUTPUT#"$ROOT"/}"
