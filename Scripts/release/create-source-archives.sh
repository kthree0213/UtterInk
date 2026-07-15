#!/usr/bin/env -S -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u BASH_XTRACEFD -u PS4 -u POSIXLY_CORRECT -u BASH_COMPAT -u UTTERINK_SOURCE_ARCHIVE_ENV_CLEAN /bin/bash -p

set +x +v
if [[ "$-" != *p* ]]; then
  printf 'source archive error: unsafe-launch-environment\n' >&2
  exit 2
fi
if [[ "${UTTERINK_SOURCE_ARCHIVE_ENV_CLEAN:-}" != 1 ]]; then
  exec /usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    LC_ALL=C \
    UTTERINK_SOURCE_ARCHIVE_ENV_CLEAN=1 \
    /bin/bash -p "$0" "$@"
  printf 'source archive error: unsafe-launch-environment\n' >&2
  exit 2
fi
if [[ "$-" != hpB || "${PATH-}" != /usr/bin:/bin:/usr/sbin:/sbin || "${LC_ALL-}" != C ]]; then
  printf 'source archive error: unsafe-launch-environment\n' >&2
  exit 2
fi
while IFS= read -r -d '' environment_entry; do
  environment_name="${environment_entry%%=*}"
  case "$environment_name" in
    PATH|LC_ALL|UTTERINK_SOURCE_ARCHIVE_ENV_CLEAN|PWD|SHLVL|_) ;;
    *)
      printf 'source archive error: unsafe-launch-environment\n' >&2
      exit 2
      ;;
  esac
done < <(/usr/bin/env -0)
unset UTTERINK_SOURCE_ARCHIVE_ENV_CLEAN

set -euo pipefail

export LC_ALL=C
export GIT_NO_REPLACE_OBJECTS=1
export GIT_NO_LAZY_FETCH=1
export GIT_TERMINAL_PROMPT=0
export GIT_ATTR_NOSYSTEM=1
export PYTHONDONTWRITEBYTECODE=1
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
unset \
  BASH_ENV ENV CDPATH GLOBIGNORE PYTHONHOME PYTHONPATH \
  PERL5OPT PERL5LIB PERLLIB PERL5DB \
  GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
  GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE
umask 077

GIT=/usr/bin/git
PYTHON=/usr/bin/python3
AWK=/usr/bin/awk

fail() {
  local category="$1"
  local status="${2:-1}"
  printf 'source archive error: %s\n' "$category" >&2
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
if [[ -n "$EXPECTED_ORIGIN" ]]; then
  [[ ${#EXPECTED_ORIGIN} -le 2048 && "$EXPECTED_ORIGIN" != *[[:space:]]* ]] || fail invalid-arguments 2
  case "$EXPECTED_ORIGIN" in
    https://*/*|ssh://*/*|git@*:* ) ;;
    *) fail invalid-arguments 2 ;;
  esac
fi

for unsafe_name in \
  GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_NAMESPACE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_REPLACE_REF_BASE GIT_GRAFT_FILE \
  GIT_COMMON_DIR GIT_CONFIG GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_COUNT \
  GIT_CONFIG_PARAMETERS GIT_EXEC_PATH GIT_CEILING_DIRECTORIES \
  GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_SSH GIT_SSH_COMMAND \
  GIT_ASKPASS GIT_PROXY_COMMAND SSH_ASKPASS; do
  [[ -z "${!unsafe_name-}" ]] || fail unsafe-git-environment
done
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

ROOT="$($GIT rev-parse --show-toplevel 2>/dev/null)" || fail not-a-repository
SCRIPT_ROOT="$(cd "$(/usr/bin/dirname "$0")/../.." && pwd -P)"
[[ "$ROOT" == "$SCRIPT_ROOT" ]] || fail repository-mismatch
cd "$ROOT"

assert_clean_commit() {
  local head object_type resolved status
  object_type="$($GIT cat-file -t "$COMMIT" 2>/dev/null)" || fail commit-mismatch
  [[ "$object_type" == commit ]] || fail commit-mismatch
  resolved="$($GIT rev-parse --verify "$COMMIT^{commit}" 2>/dev/null)" || fail commit-mismatch
  [[ "$resolved" == "$COMMIT" ]] || fail commit-mismatch
  head="$($GIT rev-parse --verify HEAD 2>/dev/null)" || fail commit-mismatch
  [[ "$head" == "$COMMIT" ]] || fail commit-mismatch
  $GIT -c core.fsmonitor=false -c core.untrackedCache=false --no-pager diff --no-ext-diff --quiet --exit-code || fail dirty-checkout
  $GIT -c core.fsmonitor=false -c core.untrackedCache=false --no-pager diff --cached --no-ext-diff --quiet --exit-code || fail dirty-checkout
  status="$($GIT -c core.fsmonitor=false -c core.untrackedCache=false status --porcelain=v1 --untracked-files=all 2>/dev/null)" || fail dirty-checkout
  [[ -z "$status" ]] || fail dirty-checkout
}

verify_commit_file() {
  local path="$1"
  local expected_blob actual_blob expected_mode
  [[ -f "$path" && ! -L "$path" ]] || return 1
  expected_blob="$($GIT rev-parse "$COMMIT:$path" 2>/dev/null)" || return 1
  actual_blob="$($GIT hash-object --no-filters -- "$path" 2>/dev/null)" || return 1
  [[ "$actual_blob" == "$expected_blob" ]] || return 1
  expected_mode="$($GIT ls-tree "$COMMIT" -- "$path" | "$AWK" 'NR == 1 { print $1 }')" || return 1
  case "$expected_mode" in
    100644) [[ ! -x "$path" ]] ;;
    100755) [[ -x "$path" ]] ;;
    *) return 1 ;;
  esac
}

assert_clean_commit
for required in \
  Config/release-metadata.json \
  Scripts/release/create-source-archives.sh \
  Scripts/release/verify-candidate.sh; do
  verify_commit_file "$required" || fail required-input-mismatch
done

if ! OUTPUT_ABSOLUTE="$($PYTHON -I - "$ROOT" "$OUTPUT" <<'PY' 2>/dev/null
from __future__ import annotations

import os
from pathlib import Path
import stat
import sys


def abort() -> None:
    raise SystemExit(1)


try:
    root = Path(sys.argv[1]).resolve(strict=True)
except OSError:
    abort()
raw = sys.argv[2]
if not raw or "\x00" in raw:
    abort()
candidate = Path(raw)
if not candidate.is_absolute():
    candidate = root / candidate
raw_candidate = Path(os.path.abspath(candidate))
try:
    candidate = raw_candidate.resolve(strict=False)
except OSError:
    abort()
release_work = root / ".release-work"
try:
    relative = candidate.relative_to(release_work)
except ValueError:
    abort()
if not relative.parts or candidate == release_work:
    abort()

# macOS commonly spells the same temporary path through /var and /private/var.
# Allow that system-level alias, but reject every symlink component after the
# caller path has entered this canonical repository root.
raw_root: Path | None = None
for ancestor in (raw_candidate, *raw_candidate.parents):
    try:
        if ancestor.resolve(strict=False) == root:
            raw_root = ancestor
            break
    except OSError:
        abort()
if raw_root is None:
    abort()
try:
    raw_relative = raw_candidate.relative_to(raw_root)
except ValueError:
    abort()
raw_current = raw_root
for component in raw_relative.parts:
    raw_current = raw_current / component
    try:
        raw_metadata = os.lstat(raw_current)
    except FileNotFoundError:
        break
    except OSError:
        abort()
    if stat.S_ISLNK(raw_metadata.st_mode):
        abort()

try:
    root_metadata = os.lstat(root)
except OSError:
    abort()
if (
    not stat.S_ISDIR(root_metadata.st_mode)
    or stat.S_ISLNK(root_metadata.st_mode)
    or root_metadata.st_uid != os.geteuid()
    or root_metadata.st_mode & 0o022
):
    abort()

current = root
missing = False
for component in (".release-work", *relative.parts):
    current = current / component
    if missing:
        continue
    try:
        metadata = os.lstat(current)
    except FileNotFoundError:
        missing = True
        continue
    except OSError:
        abort()
    if current == candidate:
        abort()
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or metadata.st_mode & 0o022
    ):
        abort()
print(candidate)
PY
)"; then
  fail unsafe-output
fi

OUTPUT_RELATIVE="${OUTPUT_ABSOLUTE#"$ROOT"/}"
[[ "$OUTPUT_RELATIVE" != "$OUTPUT_ABSOLUTE" ]] || fail unsafe-output
case "$OUTPUT_RELATIVE" in
  .release-work/*) OUTPUT_UNDER_WORK="${OUTPUT_RELATIVE#.release-work/}" ;;
  *) fail unsafe-output ;;
esac
[[ -n "$OUTPUT_UNDER_WORK" ]] || fail unsafe-output
$GIT check-ignore -q -- "$OUTPUT_RELATIVE/archive-probe" 2>/dev/null || fail unsafe-output

if ! "$PYTHON" -I - "$ROOT" <<'PY' >/dev/null 2>&1
from __future__ import annotations

import os
from pathlib import Path
import stat
import sys


def abort() -> None:
    raise SystemExit(1)


root = Path(sys.argv[1])
flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
try:
    root_fd = os.open(root, flags)
except OSError:
    abort()
try:
    root_metadata = os.fstat(root_fd)
    if root_metadata.st_uid != os.geteuid() or root_metadata.st_mode & 0o022:
        abort()
    try:
        release_fd = os.open(".release-work", flags, dir_fd=root_fd)
    except FileNotFoundError:
        try:
            os.mkdir(".release-work", 0o700, dir_fd=root_fd)
            release_fd = os.open(".release-work", flags, dir_fd=root_fd)
            os.fsync(root_fd)
        except OSError:
            abort()
    except OSError:
        abort()
    try:
        metadata = os.fstat(release_fd)
        if metadata.st_uid != os.geteuid() or metadata.st_mode & 0o022:
            abort()
    finally:
        os.close(release_fd)
finally:
    os.close(root_fd)
PY
then
  fail unsafe-output
fi

RELEASE_WORK_FD=8
STAGE_FD=9
if ! exec 8< "$ROOT/.release-work"; then
  fail unsafe-output
fi
if ! "$PYTHON" -I - "$ROOT/.release-work" "$RELEASE_WORK_FD" <<'PY' >/dev/null 2>&1
from __future__ import annotations

import os
from pathlib import Path
import stat
import sys


path = Path(sys.argv[1])
descriptor = int(sys.argv[2])
try:
    by_path = os.lstat(path)
    opened = os.fstat(descriptor)
except OSError:
    raise SystemExit(1)
if (
    not stat.S_ISDIR(by_path.st_mode)
    or stat.S_ISLNK(by_path.st_mode)
    or by_path.st_uid != os.geteuid()
    or by_path.st_mode & 0o022
    or (by_path.st_dev, by_path.st_ino) != (opened.st_dev, opened.st_ino)
):
    raise SystemExit(1)
PY
then
  exec 8<&-
  fail unsafe-output
fi

STAGE_NAME=''
STAGE_DEV=''
STAGE_INO=''
STAGE_FD_READY=0
TAG_CREATED=0
PUBLISHED=0
OUTPUT_DEV=''
OUTPUT_INO=''
OUTPUT_TAR_DEV=''
OUTPUT_TAR_INO=''
OUTPUT_ZIP_DEV=''
OUTPUT_ZIP_INO=''
OUTPUT_PARENT_FD=12
OUTPUT_DIRECTORY_FD=13
OUTPUT_TAR_FD=14
OUTPUT_ZIP_FD=15
OUTPUT_PARENT_FD_READY=0
OUTPUT_DIRECTORY_FD_READY=0
OUTPUT_ARCHIVE_FDS_READY=0
OUTPUT_PARENT_DEV=''
OUTPUT_PARENT_INO=''
OUTPUT_TAR_FINGERPRINT=''
OUTPUT_ZIP_FINGERPRINT=''

cleanup_stage() {
  [[ -n "$STAGE_NAME" && "$STAGE_DEV" =~ ^[0-9]+$ && "$STAGE_INO" =~ ^[0-9]+$ ]] || return 0
  "$PYTHON" -I - \
    "$RELEASE_WORK_FD" \
    "$STAGE_FD" \
    "$STAGE_FD_READY" \
    "$STAGE_NAME" \
    "$STAGE_DEV" \
    "$STAGE_INO" <<'PY' >/dev/null 2>&1 || true
from __future__ import annotations

import os
import stat
import sys


release_fd = int(sys.argv[1])
stage_fd_number = int(sys.argv[2])
stage_fd_ready = sys.argv[3] == "1"
stage_name = sys.argv[4]
expected = (int(sys.argv[5]), int(sys.argv[6]))
flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
owned_fd = False


def identity(value: os.stat_result) -> tuple[int, int]:
    return value.st_dev, value.st_ino


def clear_directory(descriptor: int, device: int) -> None:
    try:
        names = os.listdir(descriptor)
    except OSError:
        return
    for name in names:
        if not name or "/" in name or name in {".", ".."}:
            continue
        try:
            before = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        except OSError:
            continue
        if stat.S_ISDIR(before.st_mode) and not stat.S_ISLNK(before.st_mode):
            if before.st_dev != device:
                continue
            try:
                child = os.open(name, flags, dir_fd=descriptor)
            except OSError:
                continue
            try:
                opened = os.fstat(child)
                if identity(opened) != identity(before) or opened.st_dev != device:
                    continue
                clear_directory(child, device)
            finally:
                os.close(child)
            try:
                current = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
                if identity(current) == identity(before) and stat.S_ISDIR(current.st_mode):
                    os.rmdir(name, dir_fd=descriptor)
            except OSError:
                pass
        else:
            try:
                current = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
                if identity(current) == identity(before):
                    os.unlink(name, dir_fd=descriptor)
            except OSError:
                pass


if stage_fd_ready:
    try:
        stage_fd = os.dup(stage_fd_number)
    except OSError:
        raise SystemExit(0)
    owned_fd = True
else:
    try:
        entry = os.stat(stage_name, dir_fd=release_fd, follow_symlinks=False)
        if identity(entry) != expected or not stat.S_ISDIR(entry.st_mode):
            raise SystemExit(0)
        stage_fd = os.open(stage_name, flags, dir_fd=release_fd)
    except OSError:
        raise SystemExit(0)
    owned_fd = True
try:
    opened = os.fstat(stage_fd)
    if identity(opened) != expected or not stat.S_ISDIR(opened.st_mode):
        raise SystemExit(0)
    clear_directory(stage_fd, opened.st_dev)
finally:
    if owned_fd:
        os.close(stage_fd)

try:
    entry = os.stat(stage_name, dir_fd=release_fd, follow_symlinks=False)
    if identity(entry) == expected and stat.S_ISDIR(entry.st_mode):
        os.rmdir(stage_name, dir_fd=release_fd)
        os.fsync(release_fd)
except OSError:
    pass
PY
}

revoke_published_output() {
  [[ "$PUBLISHED" -eq 1 ]] || return 0
  "$PYTHON" -I - \
    "$OUTPUT_PARENT_FD" \
    "$OUTPUT_BASENAME" \
    "$OUTPUT_DEV" \
    "$OUTPUT_INO" \
    "$TAR_NAME" \
    "$OUTPUT_TAR_DEV" \
    "$OUTPUT_TAR_INO" \
    "$ZIP_NAME" \
    "$OUTPUT_ZIP_DEV" \
    "$OUTPUT_ZIP_INO" <<'PY' >/dev/null 2>&1 || true
from __future__ import annotations

import os
import stat
import sys


parent_fd = int(sys.argv[1])
original_name = sys.argv[2]
expected_directory = (int(sys.argv[3]), int(sys.argv[4]))
expected_files = {
    sys.argv[5]: (int(sys.argv[6]), int(sys.argv[7])),
    sys.argv[8]: (int(sys.argv[9]), int(sys.argv[10])),
}
if not original_name or "/" in original_name or original_name in {".", ".."}:
    raise SystemExit(0)
flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
try:
    current_fd = os.dup(parent_fd)
except OSError:
    raise SystemExit(0)
try:
    output_fd = -1
    try:
        parent_names = os.listdir(current_fd)
    except OSError:
        raise SystemExit(0)
    for candidate in parent_names:
        candidate_fd = -1
        try:
            entry = os.stat(candidate, dir_fd=current_fd, follow_symlinks=False)
            if (
                (entry.st_dev, entry.st_ino) != expected_directory
                or not stat.S_ISDIR(entry.st_mode)
                or stat.S_ISLNK(entry.st_mode)
                or entry.st_uid != os.geteuid()
            ):
                continue
            candidate_fd = os.open(candidate, flags, dir_fd=current_fd)
            opened = os.fstat(candidate_fd)
            if (
                (opened.st_dev, opened.st_ino) != expected_directory
                or not stat.S_ISDIR(opened.st_mode)
                or opened.st_uid != os.geteuid()
            ):
                continue
            output_fd = candidate_fd
            candidate_fd = -1
            break
        except OSError:
            continue
        finally:
            if candidate_fd >= 0:
                try:
                    os.close(candidate_fd)
                except OSError:
                    pass
    if output_fd < 0:
        raise SystemExit(0)
    try:
        expected_identities = set(expected_files.values())
        try:
            child_names = os.listdir(output_fd)
        except OSError:
            child_names = []
        for filename in child_names:
            try:
                before = os.stat(filename, dir_fd=output_fd, follow_symlinks=False)
                if (
                    (before.st_dev, before.st_ino) not in expected_identities
                    or not stat.S_ISREG(before.st_mode)
                    or stat.S_ISLNK(before.st_mode)
                    or before.st_uid != os.geteuid()
                ):
                    continue
                current = os.stat(filename, dir_fd=output_fd, follow_symlinks=False)
                if (
                    (current.st_dev, current.st_ino) == (before.st_dev, before.st_ino)
                    and stat.S_ISREG(current.st_mode)
                    and not stat.S_ISLNK(current.st_mode)
                    and current.st_uid == os.geteuid()
                ):
                    os.unlink(filename, dir_fd=output_fd)
            except OSError:
                pass
        try:
            os.fsync(output_fd)
        except OSError:
            pass
    finally:
        os.close(output_fd)
    try:
        parent_names = os.listdir(current_fd)
    except OSError:
        parent_names = []
    for candidate in parent_names:
        try:
            current = os.stat(candidate, dir_fd=current_fd, follow_symlinks=False)
            if (
                (current.st_dev, current.st_ino) == expected_directory
                and stat.S_ISDIR(current.st_mode)
                and not stat.S_ISLNK(current.st_mode)
                and current.st_uid == os.geteuid()
            ):
                os.rmdir(candidate, dir_fd=current_fd)
                os.fsync(current_fd)
                break
        except OSError:
            continue
finally:
    os.close(current_fd)
PY
}

rollback_created_tag() {
  [[ "$TAG_CREATED" -eq 1 && -n "${RELEASE_TAG:-}" ]] || return 0
  "$GIT" -c core.hooksPath=/dev/null update-ref -d \
    "refs/tags/$RELEASE_TAG" \
    "$COMMIT" >/dev/null 2>&1 || true
}

cleanup() {
  local status=$?
  trap - EXIT
  set +e
  if [[ "$status" -ne 0 ]]; then
    revoke_published_output
    rollback_created_tag
  fi
  cleanup_stage
  if [[ "$STAGE_FD_READY" -eq 1 ]]; then
    exec 9<&-
  fi
  if [[ "$OUTPUT_ARCHIVE_FDS_READY" -eq 1 ]]; then
    exec 15<&-
    exec 14<&-
  fi
  if [[ "$OUTPUT_DIRECTORY_FD_READY" -eq 1 ]]; then
    exec 13<&-
  fi
  if [[ "$OUTPUT_PARENT_FD_READY" -eq 1 ]]; then
    exec 12<&-
  fi
  exec 8<&-
  exit "$status"
}
trap cleanup EXIT

if ! STAGE_RECORD="$($PYTHON -I - "$RELEASE_WORK_FD" <<'PY' 2>/dev/null
from __future__ import annotations

import os
import secrets
import stat
import sys


release_fd = int(sys.argv[1])
flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
for _ in range(64):
    name = f".source-archives.{secrets.token_hex(16)}"
    try:
        os.mkdir(name, 0o700, dir_fd=release_fd)
        descriptor = os.open(name, flags, dir_fd=release_fd)
    except FileExistsError:
        continue
    except OSError:
        raise SystemExit(1)
    try:
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISDIR(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
            or stat.S_IMODE(metadata.st_mode) != 0o700
        ):
            raise SystemExit(1)
        os.fsync(release_fd)
        print(name, metadata.st_dev, metadata.st_ino)
    finally:
        os.close(descriptor)
    break
else:
    raise SystemExit(1)
PY
)"; then
  fail staging-failed
fi
IFS=' ' read -r STAGE_NAME STAGE_DEV STAGE_INO <<< "$STAGE_RECORD"
[[ "$STAGE_NAME" =~ ^[.]source-archives[.][0-9a-f]{32}$ && "$STAGE_DEV" =~ ^[0-9]+$ && "$STAGE_INO" =~ ^[0-9]+$ ]] || fail staging-failed
STAGE_PATH="$ROOT/.release-work/$STAGE_NAME"
if ! exec 9< "$STAGE_PATH"; then
  fail staging-failed
fi
STAGE_FD_READY=1

assert_stage_bound() {
  if ! "$PYTHON" -I - \
    "$RELEASE_WORK_FD" \
    "$STAGE_FD" \
    "$ROOT/.release-work" \
    "$STAGE_NAME" \
    "$STAGE_DEV" \
    "$STAGE_INO" <<'PY' >/dev/null 2>&1
from __future__ import annotations

import os
import stat
import sys


release_fd = int(sys.argv[1])
stage_fd = int(sys.argv[2])
release_path = sys.argv[3]
stage_name = sys.argv[4]
expected = (int(sys.argv[5]), int(sys.argv[6]))
try:
    held_release = os.fstat(release_fd)
    named_release = os.lstat(release_path)
    opened = os.fstat(stage_fd)
    entry = os.stat(stage_name, dir_fd=release_fd, follow_symlinks=False)
except OSError:
    raise SystemExit(1)
if (
    (held_release.st_dev, held_release.st_ino) != (named_release.st_dev, named_release.st_ino)
    or not stat.S_ISDIR(named_release.st_mode)
    or stat.S_ISLNK(named_release.st_mode)
    or (opened.st_dev, opened.st_ino) != expected
    or (entry.st_dev, entry.st_ino) != expected
    or not stat.S_ISDIR(opened.st_mode)
    or not stat.S_ISDIR(entry.st_mode)
    or stat.S_ISLNK(entry.st_mode)
    or opened.st_uid != os.geteuid()
    or opened.st_mode & 0o022
):
    raise SystemExit(1)
PY
  then
    fail staging-rebound
  fi
}

assert_stage_bound
METADATA='release-metadata.json'
TREE_INVENTORY='tree-inventory'
RAW_TAR='git-archive.tar'
RESULT='result'
CANDIDATE_PATH="$STAGE_PATH/candidate"
CANDIDATE='candidate'

bind_stage_cwd() {
  cd "$STAGE_PATH" 2>/dev/null || return 1
  "$PYTHON" -I - "$STAGE_FD" "$STAGE_DEV" "$STAGE_INO" <<'PY' >/dev/null 2>&1
import os
import stat
import sys

stage_fd = int(sys.argv[1])
expected = (int(sys.argv[2]), int(sys.argv[3]))
try:
    held = os.fstat(stage_fd)
    current = os.stat(".", follow_symlinks=False)
except OSError:
    raise SystemExit(1)
if (
    (held.st_dev, held.st_ino) != expected
    or (current.st_dev, current.st_ino) != expected
    or not stat.S_ISDIR(held.st_mode)
    or not stat.S_ISDIR(current.st_mode)
    or held.st_uid != os.geteuid()
    or held.st_mode & 0o022
):
    raise SystemExit(1)
PY
}

if ! "$PYTHON" -I - "$STAGE_FD" <<'PY' >/dev/null 2>&1
import os
import stat
import sys

stage_fd = int(sys.argv[1])
try:
    values = []
    for name in ("result", "candidate"):
        os.mkdir(name, 0o700, dir_fd=stage_fd)
        descriptor = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=stage_fd)
        try:
            values.append(os.fstat(descriptor))
        finally:
            os.close(descriptor)
except OSError:
    raise SystemExit(1)
for metadata in values:
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or stat.S_IMODE(metadata.st_mode) != 0o700
    ):
        raise SystemExit(1)
PY
then
  fail staging-failed
fi

if ! (
  bind_stage_cwd || exit 1
  "$GIT" -C "$ROOT" show "$COMMIT:Config/release-metadata.json" > "$METADATA" 2>/dev/null || exit 1
  "$PYTHON" -I - "$METADATA" release-values <<'PY' >/dev/null 2>&1
from __future__ import annotations

import json
from pathlib import Path
import re
import sys


def duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError
        result[key] = value
    return result


try:
    metadata_path = Path(sys.argv[1])
    raw = metadata_path.read_bytes()
    value = json.loads(raw.decode("utf-8", errors="strict"), object_pairs_hook=duplicate_keys)
except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
    raise SystemExit(1)
if type(value) is not dict or set(value) != {
    "schemaVersion", "product", "configuration", "dmgFilenameTemplate",
    "supportedArchitectures", "releaseTag",
}:
    raise SystemExit(1)
if value != {
    "schemaVersion": 1,
    "product": "UtterInk",
    "configuration": "Release",
    "dmgFilenameTemplate": "UtterInk-{marketingVersion}-{architecture}.dmg",
    "supportedArchitectures": ["arm64"],
    "releaseTag": "v0.1.0",
}:
    raise SystemExit(1)
match = re.fullmatch(r"v([0-9]+[.][0-9]+[.][0-9]+)", value["releaseTag"])
if match is None:
    raise SystemExit(1)
Path(sys.argv[2]).write_text(
    "\n".join((match.group(1), value["releaseTag"], f"UtterInk-{match.group(1)}")) + "\n",
    encoding="ascii",
)
PY
)
then
  fail metadata-mismatch
fi

if ! RELEASE_VALUES="$(
  bind_stage_cwd || exit 1
  /bin/cat release-values
)"; then
  fail staging-rebound
fi
VERSION="$(/usr/bin/printf '%s\n' "$RELEASE_VALUES" | /usr/bin/sed -n '1p')"
RELEASE_TAG="$(/usr/bin/printf '%s\n' "$RELEASE_VALUES" | /usr/bin/sed -n '2p')"
PREFIX="$(/usr/bin/printf '%s\n' "$RELEASE_VALUES" | /usr/bin/sed -n '3p')"
TAR_NAME="UtterInk-$VERSION-source.tar.gz"
ZIP_NAME="UtterInk-$VERSION-source.zip"
[[ "$VERSION" == 0.1.0 && "$RELEASE_TAG" == v0.1.0 && "$PREFIX" == UtterInk-0.1.0 ]] || fail metadata-mismatch

set +e
(
  bind_stage_cwd || exit 1
  "$GIT" -C "$ROOT" ls-tree -r -z --full-tree "$COMMIT" > "$TREE_INVENTORY" 2>/dev/null || exit 1
  "$PYTHON" -I - "$TREE_INVENTORY" <<'PY' >/dev/null 2>&1
from __future__ import annotations

from pathlib import Path, PurePosixPath
import sys
import unicodedata


def abort() -> None:
    raise SystemExit(1)


def forbidden(path: str) -> bool:
    lower = path.lower()
    parts = PurePosixPath(lower).parts
    name = parts[-1]
    forbidden_directories = {
        ".git", ".build", ".swiftpm", ".release-work", ".release-approvals",
        ".release-evidence", ".release-requests", ".notary-profile-bindings",
        ".notarization-logs", "dist", "build", "deriveddata", "xcuserdata",
        "models", "secrets",
    }
    if any(component in forbidden_directories for component in parts):
        return True
    if parts[0] in {"users", "home"}:
        return True
    if name == ".env" or name.startswith(".env.") or name == ".envrc":
        return True
    if name.endswith((
        ".dmg", ".zip", ".tar", ".tar.gz", ".tgz", ".xcarchive", ".xcresult",
        ".pem", ".p12", ".cer", ".crt", ".key", ".mobileprovision",
        ".notarytool.json", ".notarytool.log", ".notarization.json", ".notarization.log",
    )):
        return True
    if "private-import-review" in lower or "import-review-private" in lower:
        return True
    if parts[0] == ".github" and any(
        token in name for token in ("credential", "secret", "private-key", "access-token")
    ):
        return True
    return False


try:
    data = Path(sys.argv[1]).read_bytes()
except OSError:
    abort()
if not data or not data.endswith(b"\0"):
    abort()
seen: set[str] = set()
for record in data[:-1].split(b"\0"):
    try:
        metadata, raw_path = record.split(b"\t", 1)
        mode, kind, object_id = metadata.decode("ascii").split(" ")
        path = raw_path.decode("utf-8", errors="strict")
    except (UnicodeDecodeError, ValueError):
        abort()
    pure = PurePosixPath(path)
    if (
        kind != "blob"
        or mode not in {"100644", "100755"}
        or len(object_id) != 40
        or any(character not in "0123456789abcdef" for character in object_id)
        or not path
        or path in seen
        or pure.is_absolute()
        or ".." in pure.parts
        or "\\" in path
        or any(ord(character) < 32 or ord(character) == 127 for character in path)
        or unicodedata.normalize("NFC", path) != path
    ):
        abort()
    if forbidden(path):
        raise SystemExit(2)
    seen.add(path)
PY
)
tree_status=$?
set -e
if [[ "$tree_status" -ne 0 ]]; then
  if [[ "$tree_status" -eq 2 ]]; then
    fail forbidden-source-path
  fi
  fail source-tree-mismatch
fi

TAG_PREEXISTED=0
TAG_REF_EXPECTED=''
if $GIT show-ref --verify --quiet "refs/tags/$RELEASE_TAG"; then
  TAG_PREEXISTED=1
  TAG_REF_EXPECTED="$($GIT rev-parse --verify "refs/tags/$RELEASE_TAG" 2>/dev/null)" || fail tag-commit-mismatch
  TAG_COMMIT="$($GIT rev-parse --verify "$RELEASE_TAG^{commit}" 2>/dev/null)" || fail tag-commit-mismatch
  [[ "$TAG_COMMIT" == "$COMMIT" ]] || fail tag-commit-mismatch
fi

assert_initial_tag_state() {
  local current current_commit
  if [[ "$TAG_PREEXISTED" -eq 1 ]]; then
    $GIT show-ref --verify --quiet "refs/tags/$RELEASE_TAG" || fail tag-state-changed
    current="$($GIT rev-parse --verify "refs/tags/$RELEASE_TAG" 2>/dev/null)" || fail tag-state-changed
    current_commit="$($GIT rev-parse --verify "$RELEASE_TAG^{commit}" 2>/dev/null)" || fail tag-state-changed
    [[ "$current" == "$TAG_REF_EXPECTED" && "$current_commit" == "$COMMIT" ]] || fail tag-state-changed
  else
    if $GIT show-ref --verify --quiet "refs/tags/$RELEASE_TAG"; then
      fail tag-state-changed
    fi
  fi
}

assert_bound_inputs() {
  assert_clean_commit
  verify_commit_file Config/release-metadata.json || fail required-input-mismatch
  verify_commit_file Scripts/release/create-source-archives.sh || fail required-input-mismatch
  verify_commit_file Scripts/release/verify-candidate.sh || fail required-input-mismatch
}

assert_initial_tag_state
assert_stage_bound

VERIFY_ARGUMENTS=(--commit "$COMMIT" --output "$CANDIDATE_PATH" --output-dir-fd 10)
if [[ -n "$EXPECTED_ORIGIN" ]]; then
  VERIFY_ARGUMENTS+=(--expected-origin "$EXPECTED_ORIGIN")
fi
VERIFY_CANDIDATE_BLOB="$($GIT rev-parse "$COMMIT:Scripts/release/verify-candidate.sh" 2>/dev/null)" || fail required-input-mismatch
VERIFY_CANDIDATE_MODE="$($GIT ls-tree "$COMMIT" -- Scripts/release/verify-candidate.sh | "$AWK" 'NR == 1 { print $1 }')" || fail required-input-mismatch
[[ "$VERIFY_CANDIDATE_MODE" == 100755 ]] || fail required-input-mismatch
if ! "$PYTHON" -I - \
  "$STAGE_FD" \
  "$ROOT/Scripts/release/verify-candidate.sh" \
  "$ROOT" \
  "$VERIFY_CANDIDATE_BLOB" \
  "${VERIFY_ARGUMENTS[@]}" <<'PY' >/dev/null 2>&1
from __future__ import annotations

import hashlib
import os
import stat
import sys


stage_fd = int(sys.argv[1])
executable = sys.argv[2]
root = sys.argv[3]
expected_blob = sys.argv[4]
arguments = sys.argv[5:]
try:
    executable_fd = os.open(executable, os.O_RDONLY | os.O_NOFOLLOW)
    executable_metadata = os.fstat(executable_fd)
    executable_named = os.lstat(executable)
except OSError:
    raise SystemExit(1)
if (
    not stat.S_ISREG(executable_metadata.st_mode)
    or stat.S_ISLNK(executable_named.st_mode)
    or executable_metadata.st_uid != os.geteuid()
    or executable_metadata.st_nlink != 1
    or stat.S_IMODE(executable_metadata.st_mode) != 0o755
    or (executable_metadata.st_dev, executable_metadata.st_ino)
    != (executable_named.st_dev, executable_named.st_ino)
):
    os.close(executable_fd)
    raise SystemExit(1)
content = bytearray()
offset = 0
while offset < executable_metadata.st_size:
    chunk = os.pread(executable_fd, min(1024 * 1024, executable_metadata.st_size - offset), offset)
    if not chunk:
        os.close(executable_fd)
        raise SystemExit(1)
    content.extend(chunk)
    offset += len(chunk)
digest = hashlib.sha1()
digest.update(f"blob {len(content)}\0".encode("ascii"))
digest.update(content)
stable = lambda value: (
    value.st_dev, value.st_ino, value.st_mode, value.st_uid, value.st_gid,
    value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns,
)
if stable(os.fstat(executable_fd)) != stable(executable_metadata) or digest.hexdigest() != expected_blob:
    os.close(executable_fd)
    raise SystemExit(1)
if executable_fd != 11:
    os.dup2(executable_fd, 11, inheritable=True)
    os.close(executable_fd)
else:
    os.set_inheritable(11, True)
try:
    candidate_fd = os.open(
        "candidate",
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
        dir_fd=stage_fd,
    )
    metadata = os.fstat(candidate_fd)
except OSError:
    raise SystemExit(1)
if (
    not stat.S_ISDIR(metadata.st_mode)
    or metadata.st_uid != os.geteuid()
    or metadata.st_mode & 0o022
):
    os.close(candidate_fd)
    raise SystemExit(1)
if candidate_fd != 10:
    os.dup2(candidate_fd, 10, inheritable=True)
    os.close(candidate_fd)
else:
    os.set_inheritable(10, True)
if stage_fd not in {10, 11}:
    os.close(stage_fd)
environment = {
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "LC_ALL": "C",
    "UTTERINK_RELEASE_ENV_CLEAN": "1",
    "UTTERINK_COMMIT_BOUND_SELF_FD": "11",
    "UTTERINK_COMMIT_BOUND_ROOT": root,
    "FIXTURE_VERIFY_ENV_CLEAN": "1",
}
os.execve("/bin/bash", ["/bin/bash", "-p", "/dev/fd/11", *arguments], environment)
PY
then
  fail candidate-verification-failed
fi
assert_stage_bound
assert_bound_inputs
assert_initial_tag_state

if ! (
  bind_stage_cwd || exit 1
  "$PYTHON" -I - "$CANDIDATE/candidate.json" "$COMMIT" "$("$GIT" -C "$ROOT" rev-parse "$COMMIT^{tree}")" "$RELEASE_TAG" <<'PY' >/dev/null 2>&1
from __future__ import annotations

import json
import os
from pathlib import Path
import stat
import sys


def duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError
        result[key] = value
    return result


path = Path(sys.argv[1])
try:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
except OSError:
    raise SystemExit(1)
try:
    metadata = os.fstat(fd)
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or metadata.st_nlink != 1
        or metadata.st_mode & 0o022
        or metadata.st_size > 1024 * 1024
    ):
        raise SystemExit(1)
    raw = b""
    while len(raw) < metadata.st_size:
        chunk = os.read(fd, metadata.st_size - len(raw))
        if not chunk:
            raise SystemExit(1)
        raw += chunk
finally:
    os.close(fd)
try:
    value = json.loads(raw.decode("utf-8", errors="strict"), object_pairs_hook=duplicate_keys)
except (UnicodeError, json.JSONDecodeError, ValueError):
    raise SystemExit(1)
if raw != (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8"):
    raise SystemExit(1)
if type(value) is not dict or set(value) != {
    "checks", "evidenceType", "packageResolution", "policies", "product",
    "release", "schemaVersion", "source", "toolchain",
}:
    raise SystemExit(1)
if value["schemaVersion"] != 1 or type(value["schemaVersion"]) is not int:
    raise SystemExit(1)
if value["evidenceType"] != "release-candidate" or value["product"] != "UtterInk":
    raise SystemExit(1)
source = value["source"]
if type(source) is not dict or source != {
    "clean": True,
    "commit": sys.argv[2],
    "releaseTag": sys.argv[4],
    "tree": sys.argv[3],
}:
    raise SystemExit(1)
PY
)
then
  fail candidate-evidence-mismatch
fi

assert_bound_inputs
assert_initial_tag_state
assert_stage_bound

if ! (
  bind_stage_cwd || exit 1
  "$GIT" -C "$ROOT" archive --format=tar --prefix="$PREFIX/" "$COMMIT" > "$RAW_TAR" 2> git-archive.err
); then
  fail archive-generation-failed
fi

if ! (
  bind_stage_cwd || exit 1
  "$PYTHON" -I - \
    "$RAW_TAR" \
    "$TREE_INVENTORY" \
    "$RESULT/$TAR_NAME" \
    "$RESULT/$ZIP_NAME" \
    "$PREFIX" <<'PY' >/dev/null 2>&1
from __future__ import annotations

import binascii
import hashlib
import io
import os
from pathlib import Path, PurePosixPath
import stat
import struct
import sys
import tarfile
import unicodedata
import zipfile
import zlib


MAX_ARCHIVE_BYTES = 512 * 1024 * 1024
MAX_MEMBER_BYTES = 128 * 1024 * 1024


def abort() -> None:
    raise SystemExit(1)


raw_tar_path = Path(sys.argv[1])
inventory_path = Path(sys.argv[2])
tar_output = Path(sys.argv[3])
zip_output = Path(sys.argv[4])
prefix = sys.argv[5] + "/"

try:
    raw_metadata = raw_tar_path.stat()
    if not stat.S_ISREG(raw_metadata.st_mode) or raw_metadata.st_size <= 0 or raw_metadata.st_size > MAX_ARCHIVE_BYTES:
        abort()
    tree_data = inventory_path.read_bytes()
except OSError:
    abort()
if not tree_data or not tree_data.endswith(b"\0"):
    abort()

expected: dict[str, tuple[int, str]] = {}
for record in tree_data[:-1].split(b"\0"):
    try:
        metadata, raw_path = record.split(b"\t", 1)
        mode_text, kind, object_id = metadata.decode("ascii").split(" ")
        path = raw_path.decode("utf-8", errors="strict")
    except (UnicodeDecodeError, ValueError):
        abort()
    if (
        kind != "blob"
        or mode_text not in {"100644", "100755"}
        or path in expected
        or len(object_id) != 40
        or any(character not in "0123456789abcdef" for character in object_id)
    ):
        abort()
    expected[path] = (0o755 if mode_text == "100755" else 0o644, object_id)

files: dict[str, tuple[int, bytes]] = {}
directories: set[str] = {prefix}
seen_members: set[str] = set()
top_level_count = 0
try:
    with tarfile.open(raw_tar_path, "r:") as archive:
        for member in archive.getmembers():
            name = member.name
            if member.isdir() and name.rstrip("/") == prefix.rstrip("/"):
                top_level_count += 1
                if top_level_count != 1:
                    abort()
                continue
            if (
                not name.startswith(prefix)
                or "\\" in name
                or unicodedata.normalize("NFC", name) != name
                or any(ord(character) < 32 or ord(character) == 127 for character in name)
            ):
                abort()
            relative = name[len(prefix):].rstrip("/")
            if not relative:
                abort()
            pure = PurePosixPath(relative)
            normalized_member = relative + ("/" if member.isdir() else "")
            if (
                pure.is_absolute()
                or ".." in pure.parts
                or not pure.parts
                or normalized_member in seen_members
            ):
                abort()
            seen_members.add(normalized_member)
            if member.isdir():
                directories.add(prefix + relative + "/")
                continue
            if not member.isfile() or relative in files or relative not in expected:
                abort()
            if member.size < 0 or member.size > MAX_MEMBER_BYTES:
                abort()
            handle = archive.extractfile(member)
            if handle is None:
                abort()
            content = handle.read(MAX_MEMBER_BYTES + 1)
            if len(content) != member.size or len(content) > MAX_MEMBER_BYTES:
                abort()
            expected_mode, expected_object = expected[relative]
            digest = hashlib.sha1()
            digest.update(f"blob {len(content)}\0".encode("ascii"))
            digest.update(content)
            if digest.hexdigest() != expected_object:
                abort()
            files[relative] = (expected_mode, content)
            current = PurePosixPath(relative).parent
            while current != PurePosixPath("."):
                directories.add(prefix + current.as_posix() + "/")
                current = current.parent
except (OSError, tarfile.TarError):
    abort()
expected_directories: set[str] = {prefix}
for relative in expected:
    current = PurePosixPath(relative).parent
    while current != PurePosixPath("."):
        expected_directories.add(prefix + current.as_posix() + "/")
        current = current.parent
if top_level_count != 1 or set(files) != set(expected) or directories != expected_directories:
    abort()

normalized_tar = raw_tar_path.with_name("normalized.tar")
try:
    with normalized_tar.open("xb") as output_handle:
        with tarfile.open(fileobj=output_handle, mode="w", format=tarfile.PAX_FORMAT) as archive:
            for directory in sorted(directories):
                info = tarfile.TarInfo(directory)
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                info.uid = 0
                info.gid = 0
                info.uname = ""
                info.gname = ""
                info.mtime = 0
                info.pax_headers = {}
                archive.addfile(info)
            for relative in sorted(files):
                mode, content = files[relative]
                info = tarfile.TarInfo(prefix + relative)
                info.type = tarfile.REGTYPE
                info.mode = mode
                info.uid = 0
                info.gid = 0
                info.uname = ""
                info.gname = ""
                info.mtime = 0
                info.size = len(content)
                info.pax_headers = {}
                archive.addfile(info, io.BytesIO(content))

    compressor = zlib.compressobj(level=9, method=zlib.DEFLATED, wbits=-15)
    crc = 0
    size = 0
    with normalized_tar.open("rb") as source, tar_output.open("xb") as destination:
        destination.write(b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff")
        while True:
            chunk = source.read(1024 * 1024)
            if not chunk:
                break
            size = (size + len(chunk)) & 0xFFFFFFFF
            crc = binascii.crc32(chunk, crc) & 0xFFFFFFFF
            destination.write(compressor.compress(chunk))
        destination.write(compressor.flush())
        destination.write(struct.pack("<II", crc, size))

    with zipfile.ZipFile(
        zip_output,
        mode="x",
        compression=zipfile.ZIP_DEFLATED,
        compresslevel=9,
        allowZip64=True,
        strict_timestamps=True,
    ) as archive:
        for directory in sorted(directories):
            info = zipfile.ZipInfo(directory, date_time=(1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.compress_type = zipfile.ZIP_STORED
            info.external_attr = ((stat.S_IFDIR | 0o755) << 16) | 0x10
            info.flag_bits |= 0x800
            archive.writestr(info, b"")
        for relative in sorted(files):
            mode, content = files[relative]
            info = zipfile.ZipInfo(prefix + relative, date_time=(1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (stat.S_IFREG | mode) << 16
            info.flag_bits |= 0x800
            archive.writestr(info, content, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)

    for output in (tar_output, zip_output):
        os.chmod(output, 0o644)
        metadata = os.lstat(output)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1 or stat.S_IMODE(metadata.st_mode) != 0o644:
            abort()
finally:
    try:
        normalized_tar.unlink()
    except FileNotFoundError:
        pass
    except OSError:
        abort()


def validate_tar() -> dict[str, tuple[int, bytes]]:
    result: dict[str, tuple[int, bytes]] = {}
    with tarfile.open(tar_output, "r:gz") as archive:
        for member in archive.getmembers():
            if member.isdir():
                continue
            if not member.isfile() or not member.name.startswith(prefix):
                abort()
            relative = member.name[len(prefix):]
            handle = archive.extractfile(member)
            if handle is None:
                abort()
            result[relative] = (stat.S_IMODE(member.mode), handle.read())
    return result


def validate_zip() -> dict[str, tuple[int, bytes]]:
    result: dict[str, tuple[int, bytes]] = {}
    with zipfile.ZipFile(zip_output, "r") as archive:
        if archive.testzip() is not None:
            abort()
        for item in archive.infolist():
            if item.is_dir():
                continue
            if not item.filename.startswith(prefix) or item.date_time != (1980, 1, 1, 0, 0, 0):
                abort()
            relative = item.filename[len(prefix):]
            result[relative] = (stat.S_IMODE(item.external_attr >> 16), archive.read(item))
    return result


expected_content = {path: (mode, content) for path, (mode, content) in files.items()}
if validate_tar() != expected_content or validate_zip() != expected_content:
    abort()
PY
)
then
  fail archive-tree-mismatch
fi

if ! (
  bind_stage_cwd || exit 1
  /bin/chmod 0755 "$RESULT"
); then
  fail staging-rebound
fi
assert_stage_bound
assert_bound_inputs
assert_initial_tag_state

if [[ "$TAG_PREEXISTED" -eq 0 ]]; then
  if ! $GIT -c core.hooksPath=/dev/null update-ref \
    "refs/tags/$RELEASE_TAG" \
    "$COMMIT" \
    0000000000000000000000000000000000000000; then
    fail tag-state-changed
  fi
  TAG_CREATED=1
  TAG_REF_EXPECTED="$COMMIT"
fi

assert_exact_tag() {
  local current current_commit
  $GIT show-ref --verify --quiet "refs/tags/$RELEASE_TAG" || fail tag-state-changed
  current="$($GIT rev-parse --verify "refs/tags/$RELEASE_TAG" 2>/dev/null)" || fail tag-state-changed
  current_commit="$($GIT rev-parse --verify "$RELEASE_TAG^{commit}" 2>/dev/null)" || fail tag-state-changed
  [[ "$current" == "$TAG_REF_EXPECTED" && "$current_commit" == "$COMMIT" ]] || fail tag-state-changed
}

assert_exact_tag
assert_bound_inputs
assert_stage_bound
TAG_COMMIT="$($GIT rev-parse --verify "$RELEASE_TAG^{commit}" 2>/dev/null)" || fail tag-commit-mismatch
[[ "$TAG_COMMIT" == "$COMMIT" ]] || fail tag-commit-mismatch

OUTPUT_BASENAME="${OUTPUT_UNDER_WORK##*/}"
if [[ "$OUTPUT_UNDER_WORK" == */* ]]; then
  OUTPUT_PARENT_UNDER_WORK="${OUTPUT_UNDER_WORK%/*}"
  OUTPUT_PARENT_PATH="$ROOT/.release-work/$OUTPUT_PARENT_UNDER_WORK"
else
  OUTPUT_PARENT_UNDER_WORK='.'
  OUTPUT_PARENT_PATH="$ROOT/.release-work"
fi
if ! OUTPUT_PARENT_RECORD="$($PYTHON -I - \
  "$RELEASE_WORK_FD" \
  "$OUTPUT_PARENT_UNDER_WORK" <<'PY' 2>/dev/null
from pathlib import PurePosixPath
import os
import stat
import sys

release_fd = int(sys.argv[1])
relative = PurePosixPath(sys.argv[2])
if relative.is_absolute() or ".." in relative.parts:
    raise SystemExit(1)
parts = () if relative == PurePosixPath(".") else relative.parts
flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
current_fd = os.dup(release_fd)
try:
    for component in parts:
        try:
            next_fd = os.open(component, flags, dir_fd=current_fd)
        except FileNotFoundError:
            parent = os.fstat(current_fd)
            if parent.st_uid != os.geteuid() or parent.st_mode & 0o022:
                raise SystemExit(1)
            os.mkdir(component, 0o700, dir_fd=current_fd)
            next_fd = os.open(component, flags, dir_fd=current_fd)
            os.fsync(current_fd)
        opened = os.fstat(next_fd)
        if (
            not stat.S_ISDIR(opened.st_mode)
            or opened.st_uid != os.geteuid()
            or opened.st_mode & 0o022
        ):
            os.close(next_fd)
            raise SystemExit(1)
        os.close(current_fd)
        current_fd = next_fd
    opened = os.fstat(current_fd)
    print(opened.st_dev, opened.st_ino)
finally:
    os.close(current_fd)
PY
)"; then
  fail unsafe-output
fi
IFS=' ' read -r OUTPUT_PARENT_DEV OUTPUT_PARENT_INO <<< "$OUTPUT_PARENT_RECORD"
[[ "$OUTPUT_PARENT_DEV" =~ ^[0-9]+$ && "$OUTPUT_PARENT_INO" =~ ^[0-9]+$ ]] || fail unsafe-output
if ! exec 12< "$OUTPUT_PARENT_PATH"; then
  fail unsafe-output
fi
OUTPUT_PARENT_FD_READY=1

assert_output_parent_bound() {
  if ! "$PYTHON" -I - \
    "$RELEASE_WORK_FD" "$OUTPUT_PARENT_FD" \
    "$OUTPUT_PARENT_UNDER_WORK" "$OUTPUT_PARENT_PATH" \
    "$OUTPUT_PARENT_DEV" "$OUTPUT_PARENT_INO" <<'PY' >/dev/null 2>&1
from pathlib import PurePosixPath
import os
import stat
import sys

release_fd = int(sys.argv[1])
held_fd = int(sys.argv[2])
relative = PurePosixPath(sys.argv[3])
path = sys.argv[4]
expected = (int(sys.argv[5]), int(sys.argv[6]))
if relative.is_absolute() or ".." in relative.parts:
    raise SystemExit(1)
parts = () if relative == PurePosixPath(".") else relative.parts
flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
current_fd = os.dup(release_fd)
try:
    for component in parts:
        next_fd = os.open(component, flags, dir_fd=current_fd)
        os.close(current_fd)
        current_fd = next_fd
    traversed = os.fstat(current_fd)
    held = os.fstat(held_fd)
    named = os.lstat(path)
    if (
        (traversed.st_dev, traversed.st_ino) != expected
        or (held.st_dev, held.st_ino) != expected
        or (named.st_dev, named.st_ino) != expected
        or not stat.S_ISDIR(held.st_mode)
        or stat.S_ISLNK(named.st_mode)
        or held.st_uid != os.geteuid()
        or held.st_mode & 0o022
    ):
        raise SystemExit(1)
finally:
    os.close(current_fd)
PY
  then
    fail published-output-changed
  fi
}

assert_output_parent_bound

if ! PUBLISH_RECORD="$($PYTHON -I - \
  "$OUTPUT_PARENT_FD" \
  "$STAGE_FD" \
  "$OUTPUT_BASENAME" \
  "$TAR_NAME" \
  "$ZIP_NAME" <<'PY' 2>/dev/null
from __future__ import annotations

import ctypes
import hashlib
import os
import stat
import sys


def abort() -> None:
    raise SystemExit(1)


output_parent_fd = int(sys.argv[1])
stage_fd = int(sys.argv[2])
destination_name = sys.argv[3]
tar_name = sys.argv[4]
zip_name = sys.argv[5]
if not destination_name or "/" in destination_name or destination_name in {".", ".."}:
    abort()

directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def identity(value: os.stat_result) -> tuple[int, int]:
    return value.st_dev, value.st_ino


def fingerprint(value: os.stat_result) -> tuple[int, ...]:
    return (
        value.st_dev, value.st_ino, value.st_mode, value.st_uid, value.st_gid,
        value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns,
    )


def digest_file(descriptor: int, metadata: os.stat_result) -> str:
    digest = hashlib.sha256()
    offset = 0
    while offset < metadata.st_size:
        chunk = os.pread(descriptor, min(1024 * 1024, metadata.st_size - offset), offset)
        if not chunk:
            abort()
        digest.update(chunk)
        offset += len(chunk)
    if fingerprint(os.fstat(descriptor)) != fingerprint(metadata):
        abort()
    return digest.hexdigest()


def encode_file(value: tuple[int, ...], digest: str) -> str:
    return ":".join(str(item) for item in (*value, digest))


def unlink_exact_files_and_directory(
    parent_fd: int,
    directory_name: str,
    expected_directory: tuple[int, int],
    expected_files: dict[str, tuple[int, int]],
) -> None:
    try:
        entry = os.stat(directory_name, dir_fd=parent_fd, follow_symlinks=False)
        if identity(entry) != expected_directory or not stat.S_ISDIR(entry.st_mode):
            return
        output_fd = os.open(directory_name, directory_flags, dir_fd=parent_fd)
    except OSError:
        return
    try:
        if identity(os.fstat(output_fd)) != expected_directory:
            return
        for filename, expected in expected_files.items():
            try:
                item = os.stat(filename, dir_fd=output_fd, follow_symlinks=False)
                if identity(item) == expected and stat.S_ISREG(item.st_mode):
                    os.unlink(filename, dir_fd=output_fd)
            except OSError:
                pass
    finally:
        os.close(output_fd)
    try:
        current = os.stat(directory_name, dir_fd=parent_fd, follow_symlinks=False)
        if identity(current) == expected_directory and stat.S_ISDIR(current.st_mode):
            os.rmdir(directory_name, dir_fd=parent_fd)
            os.fsync(parent_fd)
    except OSError:
        pass


try:
    source_metadata = os.stat("result", dir_fd=stage_fd, follow_symlinks=False)
    source_fd = os.open("result", directory_flags, dir_fd=stage_fd)
except OSError:
    abort()
try:
    if (
        not stat.S_ISDIR(source_metadata.st_mode)
        or stat.S_ISLNK(source_metadata.st_mode)
        or source_metadata.st_uid != os.geteuid()
        or source_metadata.st_nlink < 2
        or source_metadata.st_mode & 0o022
        or identity(os.fstat(source_fd)) != identity(source_metadata)
    ):
        abort()
    if set(os.listdir(source_fd)) != {tar_name, zip_name}:
        abort()
    expected_files: dict[str, tuple[tuple[int, ...], str]] = {}
    for filename in (tar_name, zip_name):
        item = os.stat(filename, dir_fd=source_fd, follow_symlinks=False)
        if (
            not stat.S_ISREG(item.st_mode)
            or stat.S_ISLNK(item.st_mode)
            or item.st_uid != os.geteuid()
            or item.st_nlink != 1
            or stat.S_IMODE(item.st_mode) != 0o644
        ):
            abort()
        item_fd = os.open(filename, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=source_fd)
        try:
            opened_item = os.fstat(item_fd)
            if fingerprint(opened_item) != fingerprint(item):
                abort()
            expected_files[filename] = (fingerprint(item), digest_file(item_fd, opened_item))
        finally:
            os.close(item_fd)
finally:
    os.close(source_fd)

expected_directory = identity(source_metadata)
destination_parent_fd = os.dup(output_parent_fd)
renamed = False
try:
    parent_metadata = os.fstat(destination_parent_fd)
    if (
        not stat.S_ISDIR(parent_metadata.st_mode)
        or parent_metadata.st_uid != os.geteuid()
        or parent_metadata.st_mode & 0o022
    ):
        abort()
    try:
        os.stat(destination_name, dir_fd=destination_parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        pass
    except OSError:
        abort()
    else:
        abort()

    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform == "darwin" and hasattr(libc, "renameatx_np"):
        rename = libc.renameatx_np
        rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        result = rename(stage_fd, b"result", destination_parent_fd, os.fsencode(destination_name), 0x00000004)
    elif sys.platform.startswith("linux") and hasattr(libc, "renameat2"):
        rename = libc.renameat2
        rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        result = rename(stage_fd, b"result", destination_parent_fd, os.fsencode(destination_name), 0x00000001)
    else:
        abort()
    if result != 0:
        abort()
    renamed = True
    os.fsync(destination_parent_fd)
    published = os.stat(destination_name, dir_fd=destination_parent_fd, follow_symlinks=False)
    if (
        identity(published) != expected_directory
        or not stat.S_ISDIR(published.st_mode)
        or stat.S_ISLNK(published.st_mode)
    ):
        abort()
    output_fd = os.open(destination_name, directory_flags, dir_fd=destination_parent_fd)
    try:
        if identity(os.fstat(output_fd)) != expected_directory or set(os.listdir(output_fd)) != set(expected_files):
            abort()
        for filename, expected in expected_files.items():
            item = os.stat(filename, dir_fd=output_fd, follow_symlinks=False)
            expected_fingerprint, expected_digest = expected
            if (
                fingerprint(item) != expected_fingerprint
                or not stat.S_ISREG(item.st_mode)
                or stat.S_ISLNK(item.st_mode)
                or item.st_nlink != 1
                or stat.S_IMODE(item.st_mode) != 0o644
            ):
                abort()
            item_fd = os.open(filename, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=output_fd)
            try:
                opened_item = os.fstat(item_fd)
                if fingerprint(opened_item) != expected_fingerprint or digest_file(item_fd, opened_item) != expected_digest:
                    abort()
            finally:
                os.close(item_fd)
    finally:
        os.close(output_fd)
    print(
        expected_directory[0],
        expected_directory[1],
        encode_file(expected_files[tar_name][0], expected_files[tar_name][1]),
        encode_file(expected_files[zip_name][0], expected_files[zip_name][1]),
    )
except BaseException:
    if renamed:
        unlink_exact_files_and_directory(
            destination_parent_fd,
            destination_name,
            expected_directory,
            {name: (value[0][0], value[0][1]) for name, value in expected_files.items()},
        )
    raise
finally:
    os.close(destination_parent_fd)
PY
)"; then
  fail unsafe-output
fi
IFS=' ' read -r \
  OUTPUT_DEV \
  OUTPUT_INO \
  OUTPUT_TAR_FINGERPRINT \
  OUTPUT_ZIP_FINGERPRINT <<< "$PUBLISH_RECORD"
for published_value in "$OUTPUT_DEV" "$OUTPUT_INO"; do
  [[ "$published_value" =~ ^[0-9]+$ ]] || fail unsafe-output
done
[[ "$OUTPUT_TAR_FINGERPRINT" =~ ^[0-9]+(:[0-9]+){8}:[0-9a-f]{64}$ ]] || fail unsafe-output
[[ "$OUTPUT_ZIP_FINGERPRINT" =~ ^[0-9]+(:[0-9]+){8}:[0-9a-f]{64}$ ]] || fail unsafe-output
OUTPUT_TAR_DEV="${OUTPUT_TAR_FINGERPRINT%%:*}"
OUTPUT_TAR_REST="${OUTPUT_TAR_FINGERPRINT#*:}"
OUTPUT_TAR_INO="${OUTPUT_TAR_REST%%:*}"
OUTPUT_ZIP_DEV="${OUTPUT_ZIP_FINGERPRINT%%:*}"
OUTPUT_ZIP_REST="${OUTPUT_ZIP_FINGERPRINT#*:}"
OUTPUT_ZIP_INO="${OUTPUT_ZIP_REST%%:*}"
PUBLISHED=1
if ! exec 13< "$OUTPUT_ABSOLUTE"; then
  fail published-output-changed
fi
OUTPUT_DIRECTORY_FD_READY=1
if ! exec 14< "$OUTPUT_ABSOLUTE/$TAR_NAME" || ! exec 15< "$OUTPUT_ABSOLUTE/$ZIP_NAME"; then
  fail published-output-changed
fi
OUTPUT_ARCHIVE_FDS_READY=1

assert_published_output_bound() {
  if ! "$PYTHON" -I - \
    "$RELEASE_WORK_FD" "$OUTPUT_PARENT_FD" \
    "$OUTPUT_DIRECTORY_FD" "$OUTPUT_TAR_FD" "$OUTPUT_ZIP_FD" \
    "$OUTPUT_PARENT_UNDER_WORK" "$OUTPUT_PARENT_PATH" \
    "$OUTPUT_PARENT_DEV" "$OUTPUT_PARENT_INO" \
    "$OUTPUT_BASENAME" "$OUTPUT_DEV" "$OUTPUT_INO" \
    "$TAR_NAME" "$OUTPUT_TAR_FINGERPRINT" \
    "$ZIP_NAME" "$OUTPUT_ZIP_FINGERPRINT" <<'PY' >/dev/null 2>&1
from __future__ import annotations

import hashlib
import os
from pathlib import PurePosixPath
import stat
import sys


release_fd = int(sys.argv[1])
parent_fd = int(sys.argv[2])
output_fd = int(sys.argv[3])
archive_fds = (int(sys.argv[4]), int(sys.argv[5]))
parent_relative = PurePosixPath(sys.argv[6])
parent_path = sys.argv[7]
expected_parent = (int(sys.argv[8]), int(sys.argv[9]))
output_name = sys.argv[10]
expected_directory = (int(sys.argv[11]), int(sys.argv[12]))
archive_names = (sys.argv[13], sys.argv[15])
encoded_fingerprints = (sys.argv[14], sys.argv[16])
if parent_relative.is_absolute() or ".." in parent_relative.parts:
    raise SystemExit(1)
if not output_name or "/" in output_name or output_name in {".", ".."}:
    raise SystemExit(1)


def parse_fingerprint(value: str) -> tuple[tuple[int, ...], str]:
    parts = value.split(":")
    if len(parts) != 10 or len(parts[-1]) != 64 or any(character not in "0123456789abcdef" for character in parts[-1]):
        raise SystemExit(1)
    try:
        metadata = tuple(int(item, 10) for item in parts[:-1])
    except ValueError:
        raise SystemExit(1)
    return metadata, parts[-1]


def fingerprint(value: os.stat_result) -> tuple[int, ...]:
    return (
        value.st_dev, value.st_ino, value.st_mode, value.st_uid, value.st_gid,
        value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns,
    )


def digest_file(descriptor: int, metadata: os.stat_result) -> str:
    digest = hashlib.sha256()
    offset = 0
    while offset < metadata.st_size:
        chunk = os.pread(descriptor, min(1024 * 1024, metadata.st_size - offset), offset)
        if not chunk:
            raise SystemExit(1)
        digest.update(chunk)
        offset += len(chunk)
    if fingerprint(os.fstat(descriptor)) != fingerprint(metadata):
        raise SystemExit(1)
    return digest.hexdigest()


expected_files = {
    name: (*parse_fingerprint(encoded), descriptor)
    for name, encoded, descriptor in zip(archive_names, encoded_fingerprints, archive_fds)
}
flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
current_fd = os.dup(release_fd)
try:
    parts = () if parent_relative == PurePosixPath(".") else parent_relative.parts
    for component in parts:
        next_fd = os.open(component, flags, dir_fd=current_fd)
        os.close(current_fd)
        current_fd = next_fd
    traversed_parent = os.fstat(current_fd)
    held_parent = os.fstat(parent_fd)
    named_parent = os.lstat(parent_path)
    if (
        (traversed_parent.st_dev, traversed_parent.st_ino) != expected_parent
        or (held_parent.st_dev, held_parent.st_ino) != expected_parent
        or (named_parent.st_dev, named_parent.st_ino) != expected_parent
        or not stat.S_ISDIR(held_parent.st_mode)
        or stat.S_ISLNK(named_parent.st_mode)
    ):
        raise SystemExit(1)
    entry = os.stat(output_name, dir_fd=parent_fd, follow_symlinks=False)
    if (
        (entry.st_dev, entry.st_ino) != expected_directory
        or not stat.S_ISDIR(entry.st_mode)
        or stat.S_ISLNK(entry.st_mode)
    ):
        raise SystemExit(1)
    opened = os.fstat(output_fd)
    if (opened.st_dev, opened.st_ino) != expected_directory:
        raise SystemExit(1)
    if set(os.listdir(output_fd)) != set(expected_files):
        raise SystemExit(1)
    for filename, (expected_fingerprint, expected_digest, descriptor) in expected_files.items():
        named = os.stat(filename, dir_fd=output_fd, follow_symlinks=False)
        held = os.fstat(descriptor)
        if (
            fingerprint(named) != expected_fingerprint
            or fingerprint(held) != expected_fingerprint
            or not stat.S_ISREG(named.st_mode)
            or stat.S_ISLNK(named.st_mode)
            or named.st_nlink != 1
            or stat.S_IMODE(named.st_mode) != 0o644
            or digest_file(descriptor, held) != expected_digest
        ):
            raise SystemExit(1)
finally:
    os.close(current_fd)
PY
  then
    fail published-output-changed
  fi
}

assert_stage_bound
assert_bound_inputs
assert_exact_tag
assert_published_output_bound
assert_bound_inputs
assert_exact_tag
assert_published_output_bound

exit 0
