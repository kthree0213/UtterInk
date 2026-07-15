#!/usr/bin/env -S -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u BASH_XTRACEFD -u PS4 -u POSIXLY_CORRECT -u BASH_COMPAT -u UTTERINK_ASSEMBLE_ASSETS_ENV_CLEAN /bin/bash -p

set +x +v
if [[ "$-" != *p* ]]; then
  /usr/bin/printf 'release asset assembly error: unsafe-launch-environment\n' >&2
  exit 2
fi
if [[ "${UTTERINK_ASSEMBLE_ASSETS_ENV_CLEAN:-}" != 1 ]]; then
  exec /usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    LC_ALL=C \
    UTTERINK_ASSEMBLE_ASSETS_ENV_CLEAN=1 \
    /bin/bash -p "$0" "$@"
  /usr/bin/printf 'release asset assembly error: unsafe-launch-environment\n' >&2
  exit 2
fi
if [[ "$-" != hpB || "${PATH-}" != /usr/bin:/bin:/usr/sbin:/sbin || "${LC_ALL-}" != C ]]; then
  /usr/bin/printf 'release asset assembly error: unsafe-launch-environment\n' >&2
  exit 2
fi
while IFS= read -r -d '' environment_entry; do
  environment_name="${environment_entry%%=*}"
  case "$environment_name" in
    PATH|LC_ALL|UTTERINK_ASSEMBLE_ASSETS_ENV_CLEAN|PWD|SHLVL|_) ;;
    *) /usr/bin/printf 'release asset assembly error: unsafe-launch-environment\n' >&2; exit 2 ;;
  esac
done < <(/usr/bin/env -0)
unset UTTERINK_ASSEMBLE_ASSETS_ENV_CLEAN

set -euo pipefail
export LC_ALL=C
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PYTHONDONTWRITEBYTECODE=1
export TZ=UTC
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_NO_REPLACE_OBJECTS=1
export GIT_NO_LAZY_FETCH=1
export GIT_TERMINAL_PROMPT=0
export GIT_ATTR_NOSYSTEM=1
unset BASH_ENV ENV CDPATH GLOBIGNORE PYTHONHOME PYTHONPATH DEVELOPER_DIR SDKROOT TOOLCHAINS
umask 077

SCRIPT_PATH="${BASH_SOURCE[0]}"
[[ -f "$SCRIPT_PATH" && ! -L "$SCRIPT_PATH" ]] || {
  /usr/bin/printf 'release asset assembly error: unsafe-repository\n' >&2
  exit 20
}
SCRIPT_DIRECTORY="$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "$SCRIPT_PATH")" && /bin/pwd -P)"
ROOT="$(CDPATH= cd -P -- "$SCRIPT_DIRECTORY/../.." && /bin/pwd -P)"
readonly SCRIPT_PATH SCRIPT_DIRECTORY ROOT

exec /usr/bin/python3 -I - "$ROOT" "$SCRIPT_PATH" "$@" <<'PY'
from __future__ import annotations

import ctypes
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import stat
import subprocess
import sys
import time

ROOT = Path(sys.argv[1])
SCRIPT = Path(sys.argv[2])
ARGUMENTS = sys.argv[3:]
DMG_NAME = "UtterInk-0.1.0-arm64.dmg"
TAR_NAME = "UtterInk-0.1.0-source.tar.gz"
ZIP_NAME = "UtterInk-0.1.0-source.zip"
NOTES_SOURCE = ROOT / "docs/release/release-notes-0.1.0.md"
NOTES_NAME = "release-notes-0.1.0.md"
SUMS_NAME = "SHA256SUMS"
SOURCE_NAMES = (TAR_NAME, ZIP_NAME)
COPY_NAMES = (DMG_NAME, TAR_NAME, ZIP_NAME, NOTES_NAME)
SCRIPT_RELATIVE = "Scripts/release/assemble-release-assets.sh"


def reject(category: str, status_code: int = 1) -> None:
    print(f"release asset assembly error: {category}", file=sys.stderr)
    raise SystemExit(status_code)


def test_barrier(label: str) -> None:
    pause = ROOT / ".git" / f"release-assets-test-{label}.pause"
    ready = ROOT / ".git" / f"release-assets-test-{label}.ready"
    try:
        pause_state = os.lstat(pause)
    except FileNotFoundError:
        return
    except OSError:
        reject("invalid-test-barrier")
    if (
        not stat.S_ISREG(pause_state.st_mode)
        or stat.S_ISLNK(pause_state.st_mode)
        or pause_state.st_uid != os.geteuid()
        or pause_state.st_nlink != 1
        or stat.S_IMODE(pause_state.st_mode) != 0o600
        or pause_state.st_size != len(b"pause\n")
        or pause.read_bytes() != b"pause\n"
    ):
        reject("invalid-test-barrier")
    descriptor = -1
    ready_identity: tuple[int, int] | None = None
    try:
        descriptor = os.open(ready, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        if os.write(descriptor, b"ready\n") != len(b"ready\n"):
            reject("invalid-test-barrier")
        os.fsync(descriptor)
        state = os.fstat(descriptor)
        ready_identity = (state.st_dev, state.st_ino)
        os.close(descriptor)
        descriptor = -1
        deadline = time.monotonic() + 30
        while True:
            try:
                current = os.lstat(pause)
            except FileNotFoundError:
                break
            except OSError:
                reject("invalid-test-barrier")
            if fingerprint(current) != fingerprint(pause_state) or time.monotonic() >= deadline:
                reject("invalid-test-barrier")
            time.sleep(0.001)
    except OSError:
        reject("invalid-test-barrier")
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if ready_identity is not None:
            try:
                current_ready = os.lstat(ready)
                if (current_ready.st_dev, current_ready.st_ino) == ready_identity:
                    os.unlink(ready)
            except OSError:
                pass


def parse_arguments() -> dict[str, str]:
    names = {
        "--dmg": "dmg",
        "--source-archives": "sources",
        "--commit": "commit",
        "--expected-final-dmg-sha256": "dmg_hash",
        "--output": "output",
    }
    values: dict[str, str] = {}
    index = 0
    while index < len(ARGUMENTS):
        option = ARGUMENTS[index]
        if option not in names or index + 1 >= len(ARGUMENTS):
            reject("invalid-arguments", 2)
        value = ARGUMENTS[index + 1]
        key = names[option]
        if key in values or not value or value.startswith("--"):
            reject("invalid-arguments", 2)
        values[key] = value
        index += 2
    if set(values) != set(names.values()):
        reject("invalid-arguments", 2)
    if re.fullmatch(r"[0-9a-f]{40}", values["commit"]) is None:
        reject("invalid-arguments", 2)
    if re.fullmatch(r"[0-9a-f]{64}", values["dmg_hash"]) is None:
        reject("invalid-arguments", 2)
    return values


def absolute_path(raw: str, category: str) -> Path:
    if any(ord(character) < 32 or ord(character) == 127 for character in raw):
        reject(category)
    path = Path(raw)
    if not path.is_absolute() or path != Path(os.path.abspath(raw)):
        reject(category)
    return path


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


def safe_directory(path: Path, category: str) -> tuple[int, tuple[int, ...]]:
    try:
        before = os.lstat(path)
        descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        opened = os.fstat(descriptor)
    except OSError:
        reject(category)
    if (
        not stat.S_ISDIR(before.st_mode)
        or stat.S_ISLNK(before.st_mode)
        or before.st_uid != os.geteuid()
        or before.st_mode & 0o022
        or fingerprint(before) != fingerprint(opened)
        or path.resolve(strict=True) != path
    ):
        os.close(descriptor)
        reject(category)
    return descriptor, fingerprint(opened)


def safe_file(path: Path, expected_name: str, category: str) -> tuple[int, tuple[int, ...]]:
    if path.name != expected_name:
        reject(category)
    try:
        before = os.lstat(path)
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        opened = os.fstat(descriptor)
    except OSError:
        reject(category)
    if (
        not stat.S_ISREG(before.st_mode)
        or stat.S_ISLNK(before.st_mode)
        or before.st_uid != os.geteuid()
        or before.st_nlink != 1
        or before.st_mode & 0o022
        or before.st_size < 1
        or fingerprint(before) != fingerprint(opened)
        or path.resolve(strict=True) != path
    ):
        os.close(descriptor)
        reject(category)
    return descriptor, fingerprint(opened)


def safe_file_at(directory: int, name: str, category: str) -> tuple[int, tuple[int, ...]]:
    try:
        before = os.stat(name, dir_fd=directory, follow_symlinks=False)
        descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory)
        opened = os.fstat(descriptor)
    except OSError:
        reject(category)
    if (
        not stat.S_ISREG(before.st_mode)
        or stat.S_ISLNK(before.st_mode)
        or before.st_uid != os.geteuid()
        or before.st_nlink != 1
        or before.st_mode & 0o022
        or before.st_size < 1
        or fingerprint(before) != fingerprint(opened)
    ):
        os.close(descriptor)
        reject(category)
    return descriptor, fingerprint(opened)


def read_all(descriptor: int, expected: tuple[int, ...], category: str, maximum: int) -> bytes:
    if expected[6] > maximum:
        reject(category)
    os.lseek(descriptor, 0, os.SEEK_SET)
    chunks: list[bytes] = []
    remaining = expected[6]
    while remaining:
        chunk = os.read(descriptor, min(1024 * 1024, remaining))
        if not chunk:
            reject(category)
        chunks.append(chunk)
        remaining -= len(chunk)
    if os.read(descriptor, 1) or fingerprint(os.fstat(descriptor)) != expected:
        reject(category)
    return b"".join(chunks)


def hash_descriptor(descriptor: int, expected: tuple[int, ...], category: str) -> str:
    value = hashlib.sha256()
    os.lseek(descriptor, 0, os.SEEK_SET)
    remaining = expected[6]
    while remaining:
        chunk = os.read(descriptor, min(1024 * 1024, remaining))
        if not chunk:
            reject(category)
        value.update(chunk)
        remaining -= len(chunk)
    if os.read(descriptor, 1) or fingerprint(os.fstat(descriptor)) != expected:
        reject(category)
    return value.hexdigest()


def git(*arguments: str, binary: bool = False) -> bytes | str:
    result = subprocess.run(
        [
            "/usr/bin/git", "-C", str(ROOT),
            "-c", "core.fsmonitor=false",
            "-c", "core.untrackedCache=false",
            "-c", "core.hooksPath=/dev/null",
            "--no-pager",
            *arguments,
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        env={
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LC_ALL": "C",
            "TZ": "UTC",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_NO_REPLACE_OBJECTS": "1",
            "GIT_NO_LAZY_FETCH": "1",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_ATTR_NOSYSTEM": "1",
        },
        check=False,
    )
    if result.returncode != 0:
        reject("candidate-mismatch")
    if binary:
        return result.stdout
    try:
        return result.stdout.decode("utf-8", "strict").strip()
    except UnicodeDecodeError:
        reject("candidate-mismatch")


def open_commit_bound_script(commit: str) -> tuple[int, tuple[int, ...], bytes]:
    expected_path = ROOT / SCRIPT_RELATIVE
    actual_path = Path(os.path.abspath(SCRIPT))
    if actual_path != expected_path:
        reject("script-binding-mismatch")
    try:
        before = os.lstat(actual_path)
        descriptor = os.open(actual_path, os.O_RDONLY | os.O_NOFOLLOW)
        opened = os.fstat(descriptor)
    except OSError:
        reject("script-binding-mismatch")
    state = fingerprint(opened)
    if (
        not stat.S_ISREG(before.st_mode)
        or stat.S_ISLNK(before.st_mode)
        or before.st_uid != os.geteuid()
        or before.st_nlink != 1
        or stat.S_IMODE(before.st_mode) != 0o755
        or fingerprint(before) != state
        or actual_path.resolve(strict=True) != actual_path
    ):
        os.close(descriptor)
        reject("script-binding-mismatch")
    tree_record = git("ls-tree", commit, "--", SCRIPT_RELATIVE, binary=True)
    committed = git("show", f"{commit}:{SCRIPT_RELATIVE}", binary=True)
    if not committed or len(committed) > 2 * 1024 * 1024:
        os.close(descriptor)
        reject("script-binding-mismatch")
    object_digest = hashlib.sha1()
    object_digest.update(f"blob {len(committed)}\0".encode("ascii"))
    object_digest.update(committed)
    expected_tree_record = f"100755 blob {object_digest.hexdigest()}\t{SCRIPT_RELATIVE}\n".encode("ascii")
    actual = read_all(descriptor, state, "script-binding-mismatch", 2 * 1024 * 1024)
    if tree_record != expected_tree_record or actual != committed:
        os.close(descriptor)
        reject("script-binding-mismatch")
    return descriptor, state, committed


def revalidate_commit_bound_script(
    descriptor: int,
    state: tuple[int, ...],
    committed: bytes,
) -> None:
    actual = read_all(descriptor, state, "script-binding-changed", 2 * 1024 * 1024)
    if actual != committed:
        reject("script-binding-changed")
    ensure_path_still_bound(ROOT / SCRIPT_RELATIVE, state, "script-binding-changed")


def revalidate_candidate_state(
    commit: str,
    script_descriptor: int,
    script_state: tuple[int, ...],
    committed_script: bytes,
) -> None:
    head_before = git("rev-parse", "--verify", "HEAD^{commit}")
    tag_before = git("rev-parse", "--verify", "refs/tags/v0.1.0^{commit}")
    if head_before != commit or tag_before != commit:
        reject("candidate-state-changed")
    if git("status", "--porcelain=v1", "--untracked-files=all"):
        reject("candidate-state-changed")
    revalidate_commit_bound_script(script_descriptor, script_state, committed_script)
    head_after = git("rev-parse", "--verify", "HEAD^{commit}")
    tag_after = git("rev-parse", "--verify", "refs/tags/v0.1.0^{commit}")
    if head_after != commit or tag_after != commit:
        reject("candidate-state-changed")


def validate_repository(commit: str) -> tuple[bytes, int, tuple[int, ...], bytes]:
    root_descriptor, _ = safe_directory(ROOT, "unsafe-repository")
    os.close(root_descriptor)
    if Path(str(git("rev-parse", "--show-toplevel"))) != ROOT:
        reject("unsafe-repository")
    if git("rev-parse", "--verify", "HEAD^{commit}") != commit:
        reject("candidate-mismatch")
    if git("rev-parse", "--verify", f"{commit}^{{commit}}") != commit:
        reject("candidate-mismatch")
    if git("rev-parse", "--verify", "refs/tags/v0.1.0^{commit}") != commit:
        reject("tag-mismatch")
    script_descriptor, script_state, committed_script = open_commit_bound_script(commit)
    if git("status", "--porcelain=v1", "--untracked-files=all"):
        os.close(script_descriptor)
        reject("dirty-repository")
    metadata_raw = git("show", f"{commit}:Config/release-metadata.json", binary=True)
    try:
        metadata = json.loads(metadata_raw)
    except (UnicodeDecodeError, json.JSONDecodeError):
        reject("metadata-mismatch")
    if metadata != {
        "schemaVersion": 1,
        "product": "UtterInk",
        "configuration": "Release",
        "dmgFilenameTemplate": "UtterInk-{marketingVersion}-{architecture}.dmg",
        "supportedArchitectures": ["arm64"],
        "releaseTag": "v0.1.0",
    }:
        reject("metadata-mismatch")
    release_config = git("show", f"{commit}:Config/Release.xcconfig", binary=True)
    try:
        version_lines = [
            line.strip()
            for line in release_config.decode("utf-8", "strict").splitlines()
            if line.strip().startswith("MARKETING_VERSION")
        ]
    except UnicodeDecodeError:
        reject("metadata-mismatch")
    if version_lines != ["MARKETING_VERSION = 0.1.0"]:
        reject("metadata-mismatch")
    notes = git("show", f"{commit}:docs/release/release-notes-0.1.0.md", binary=True)
    if not notes.endswith(b"\n") or b"\x00" in notes:
        os.close(script_descriptor)
        reject("release-notes-mismatch")
    return notes, script_descriptor, script_state, committed_script


def ensure_path_still_bound(path: Path, expected: tuple[int, ...], category: str) -> None:
    try:
        current = os.lstat(path)
    except OSError:
        reject(category)
    if fingerprint(current) != expected:
        reject(category)


def copy_descriptor(
    source: int,
    source_state: tuple[int, ...],
    destination_directory: int,
    name: str,
    expected_hash: str,
    created_files: dict[str, tuple[int, int]],
) -> tuple[int, tuple[int, ...]]:
    output = -1
    try:
        output = os.open(name, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644, dir_fd=destination_directory)
        os.fchmod(output, 0o644)
        initial_output = os.fstat(output)
        created_files[name] = (initial_output.st_dev, initial_output.st_ino)
    except OSError:
        reject("output-write-failed")
    value = hashlib.sha256()
    try:
        os.lseek(source, 0, os.SEEK_SET)
        remaining = source_state[6]
        while remaining:
            chunk = os.read(source, min(1024 * 1024, remaining))
            if not chunk:
                reject("input-changed")
            value.update(chunk)
            view = memoryview(chunk)
            while view:
                written = os.write(output, view)
                if written <= 0:
                    reject("output-write-failed")
                view = view[written:]
            remaining -= len(chunk)
        if os.read(source, 1) or fingerprint(os.fstat(source)) != source_state:
            reject("input-changed")
        os.fsync(output)
        output_state = os.fstat(output)
        if (
            not stat.S_ISREG(output_state.st_mode)
            or output_state.st_nlink != 1
            or stat.S_IMODE(output_state.st_mode) != 0o644
            or output_state.st_size != source_state[6]
            or value.hexdigest() != expected_hash
        ):
            reject("output-write-failed")
        return output, fingerprint(output_state)
    except BaseException:
        if output >= 0:
            os.close(output)
        raise


def validate_staged_outputs(
    directory: int,
    expected_names: tuple[str, ...],
    outputs: dict[str, tuple[int, tuple[int, ...], str]],
) -> None:
    try:
        names = sorted(os.listdir(directory), key=lambda item: item.encode("utf-8"))
    except OSError:
        reject("output-changed")
    if names != sorted(expected_names, key=lambda item: item.encode("utf-8")) or set(outputs) != set(expected_names):
        reject("output-changed")
    for name in expected_names:
        descriptor, expected_state, expected_hash = outputs[name]
        try:
            named_before = os.stat(name, dir_fd=directory, follow_symlinks=False)
        except OSError:
            reject("output-changed")
        if fingerprint(named_before) != expected_state:
            reject("output-changed")
        if hash_descriptor(descriptor, expected_state, "output-changed") != expected_hash:
            reject("output-changed")
        try:
            named_after = os.stat(name, dir_fd=directory, follow_symlinks=False)
        except OSError:
            reject("output-changed")
        if fingerprint(named_after) != expected_state:
            reject("output-changed")


def ensure_directory_path_matches_fd(
    path: Path,
    descriptor: int,
    identity: tuple[int, int],
    category: str,
    expected: tuple[int, ...] | None = None,
) -> tuple[int, ...]:
    try:
        path_state = os.lstat(path)
        descriptor_state = os.fstat(descriptor)
    except OSError:
        reject(category)
    path_fingerprint = fingerprint(path_state)
    descriptor_fingerprint = fingerprint(descriptor_state)
    if (
        path_fingerprint != descriptor_fingerprint
        or descriptor_state.st_dev != identity[0]
        or descriptor_state.st_ino != identity[1]
        or not stat.S_ISDIR(descriptor_state.st_mode)
        or stat.S_ISLNK(path_state.st_mode)
        or descriptor_state.st_uid != os.geteuid()
        or descriptor_state.st_mode & 0o022
        or (expected is not None and descriptor_fingerprint != expected)
    ):
        reject(category)
    return descriptor_fingerprint


def cleanup_private_directory(
    parent_descriptor: int,
    name: str,
    directory_identity: tuple[int, int],
    created_files: dict[str, tuple[int, int]],
) -> None:
    directory_descriptor = -1
    try:
        path_state = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
        if (
            not stat.S_ISDIR(path_state.st_mode)
            or stat.S_ISLNK(path_state.st_mode)
            or path_state.st_dev != directory_identity[0]
            or path_state.st_ino != directory_identity[1]
            or path_state.st_uid != os.geteuid()
            or path_state.st_mode & 0o077
        ):
            return
        directory_descriptor = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_descriptor)
        opened = os.fstat(directory_descriptor)
        if opened.st_dev != directory_identity[0] or opened.st_ino != directory_identity[1]:
            return
        entries = os.listdir(directory_descriptor)
        for entry in entries:
            expected_identity = created_files.get(entry)
            if expected_identity is None:
                return
            current = os.stat(entry, dir_fd=directory_descriptor, follow_symlinks=False)
            if (
                not stat.S_ISREG(current.st_mode)
                or stat.S_ISLNK(current.st_mode)
                or current.st_dev != expected_identity[0]
                or current.st_ino != expected_identity[1]
                or current.st_uid != os.geteuid()
            ):
                return
        for entry in entries:
            os.unlink(entry, dir_fd=directory_descriptor)
        os.fsync(directory_descriptor)
        if os.listdir(directory_descriptor):
            return
        os.close(directory_descriptor)
        directory_descriptor = -1
        os.rmdir(name, dir_fd=parent_descriptor)
        os.fsync(parent_descriptor)
    except OSError:
        return
    finally:
        if directory_descriptor >= 0:
            os.close(directory_descriptor)


def cleanup_private_directory_by_identity(
    parent_descriptor: int,
    preferred_name: str,
    directory_identity: tuple[int, int],
    created_files: dict[str, tuple[int, int]],
) -> None:
    try:
        names = [preferred_name, *os.listdir(parent_descriptor)]
    except OSError:
        names = [preferred_name]
    seen: set[str] = set()
    for name in names:
        if name in seen:
            continue
        seen.add(name)
        try:
            current = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
        except OSError:
            continue
        if (current.st_dev, current.st_ino) == directory_identity:
            cleanup_private_directory(
                parent_descriptor,
                name,
                directory_identity,
                created_files,
            )
            return


def ensure_published_output_bound(
    parent_descriptor: int,
    name: str,
    directory_descriptor: int,
    directory_identity: tuple[int, int],
) -> None:
    try:
        named = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
        held = os.fstat(directory_descriptor)
    except OSError:
        reject("output-changed")
    if (
        fingerprint(named) != fingerprint(held)
        or (held.st_dev, held.st_ino) != directory_identity
        or not stat.S_ISDIR(held.st_mode)
        or stat.S_ISLNK(named.st_mode)
        or held.st_uid != os.geteuid()
        or stat.S_IMODE(held.st_mode) != 0o700
    ):
        reject("output-changed")


def atomic_publish(parent_descriptor: int, staging_name: str, output_name: str) -> None:
    library = ctypes.CDLL(None, use_errno=True)
    source = os.fsencode(staging_name)
    destination = os.fsencode(output_name)
    if sys.platform == "darwin" and hasattr(library, "renameatx_np"):
        rename = library.renameatx_np
        rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        result = rename(parent_descriptor, source, parent_descriptor, destination, 0x00000004)
    elif sys.platform.startswith("linux") and hasattr(library, "renameat2"):
        rename = library.renameat2
        rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        result = rename(parent_descriptor, source, parent_descriptor, destination, 0x00000001)
    else:
        reject("atomic-publish-unavailable")
    if result != 0:
        error = ctypes.get_errno()
        if error in {errno.EEXIST, errno.ENOTEMPTY}:
            reject("output-exists")
        reject("atomic-publish-failed")


values = parse_arguments()
dmg_path = absolute_path(values["dmg"], "invalid-arguments")
sources_path = absolute_path(values["sources"], "invalid-arguments")
output_path = absolute_path(values["output"], "invalid-arguments")
try:
    repository_relative_output = output_path.relative_to(ROOT)
except ValueError:
    repository_relative_output = None
if repository_relative_output is not None and (
    not repository_relative_output.parts
    or repository_relative_output.parts[0] != ".release-work"
    or len(repository_relative_output.parts) < 2
):
    reject("unsafe-output")

committed_notes, script_descriptor, script_state, committed_script = validate_repository(values["commit"])

dmg_descriptor, dmg_state = safe_file(dmg_path, DMG_NAME, "unsafe-dmg")
sources_descriptor, sources_state = safe_directory(sources_path, "unsafe-source-archives")
try:
    if sorted(os.listdir(sources_descriptor), key=lambda item: item.encode("utf-8")) != sorted(SOURCE_NAMES, key=lambda item: item.encode("utf-8")):
        reject("invalid-source-inventory")
except OSError:
    reject("invalid-source-inventory")
tar_descriptor, tar_state = safe_file_at(sources_descriptor, TAR_NAME, "unsafe-source-archive")
zip_descriptor, zip_state = safe_file_at(sources_descriptor, ZIP_NAME, "unsafe-source-archive")
notes_descriptor, notes_state = safe_file(NOTES_SOURCE, NOTES_SOURCE.name, "unsafe-release-notes")

descriptors = [
    dmg_descriptor,
    tar_descriptor,
    zip_descriptor,
    notes_descriptor,
    sources_descriptor,
    script_descriptor,
]
staging_descriptor = -1
parent_descriptor = -1
staging_name = ""
staging_identity: tuple[int, int] | None = None
created_files: dict[str, tuple[int, int]] = {}
staged_outputs: dict[str, tuple[int, tuple[int, ...], str]] = {}
published = False
try:
    dmg_hash = hash_descriptor(dmg_descriptor, dmg_state, "dmg-changed")
    if dmg_hash != values["dmg_hash"]:
        reject("final-dmg-hash-mismatch")
    tar_hash = hash_descriptor(tar_descriptor, tar_state, "source-archive-changed")
    zip_hash = hash_descriptor(zip_descriptor, zip_state, "source-archive-changed")
    notes_bytes = read_all(notes_descriptor, notes_state, "release-notes-changed", 1024 * 1024)
    if notes_bytes != committed_notes:
        reject("release-notes-mismatch")
    notes_hash = hashlib.sha256(notes_bytes).hexdigest()

    parent = output_path.parent
    parent_descriptor, parent_initial = safe_directory(parent, "unsafe-output-parent")
    parent_identity = (parent_initial[0], parent_initial[1])
    ensure_directory_path_matches_fd(
        parent,
        parent_descriptor,
        parent_identity,
        "output-parent-changed",
        parent_initial,
    )
    try:
        os.stat(output_path.name, dir_fd=parent_descriptor, follow_symlinks=False)
    except FileNotFoundError:
        pass
    except OSError:
        reject("unsafe-output")
    else:
        reject("output-exists")

    for _ in range(16):
        candidate_name = f".assemble-release-assets.{secrets.token_hex(16)}.tmp"
        try:
            os.mkdir(candidate_name, 0o700, dir_fd=parent_descriptor)
            staging_name = candidate_name
            break
        except FileExistsError:
            continue
        except OSError:
            reject("output-create-failed")
    if not staging_name:
        reject("output-create-failed")
    staging_descriptor = os.open(
        staging_name,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
        dir_fd=parent_descriptor,
    )
    staging_state = os.fstat(staging_descriptor)
    staging_identity = (staging_state.st_dev, staging_state.st_ino)
    if (
        not stat.S_ISDIR(staging_state.st_mode)
        or staging_state.st_uid != os.geteuid()
        or stat.S_IMODE(staging_state.st_mode) != 0o700
    ):
        reject("output-create-failed")
    parent_after_staging = ensure_directory_path_matches_fd(
        parent,
        parent_descriptor,
        parent_identity,
        "output-parent-changed",
    )

    staged_dmg, staged_dmg_state = copy_descriptor(
        dmg_descriptor, dmg_state, staging_descriptor, DMG_NAME, dmg_hash, created_files
    )
    staged_outputs[DMG_NAME] = (staged_dmg, staged_dmg_state, dmg_hash)
    staged_tar, staged_tar_state = copy_descriptor(
        tar_descriptor, tar_state, staging_descriptor, TAR_NAME, tar_hash, created_files
    )
    staged_outputs[TAR_NAME] = (staged_tar, staged_tar_state, tar_hash)
    staged_zip, staged_zip_state = copy_descriptor(
        zip_descriptor, zip_state, staging_descriptor, ZIP_NAME, zip_hash, created_files
    )
    staged_outputs[ZIP_NAME] = (staged_zip, staged_zip_state, zip_hash)
    staged_notes, staged_notes_state = copy_descriptor(
        notes_descriptor, notes_state, staging_descriptor, NOTES_NAME, notes_hash, created_files
    )
    staged_outputs[NOTES_NAME] = (staged_notes, staged_notes_state, notes_hash)
    sums = "".join(
        f"{digest}  {name}\n"
        for name, digest in sorted(
            ((DMG_NAME, dmg_hash), (TAR_NAME, tar_hash), (ZIP_NAME, zip_hash), (NOTES_NAME, notes_hash)),
            key=lambda item: item[0].encode("utf-8"),
        )
    ).encode("ascii")
    sums_descriptor = -1
    try:
        sums_descriptor = os.open(
            SUMS_NAME,
            os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o644,
            dir_fd=staging_descriptor,
        )
        os.fchmod(sums_descriptor, 0o644)
        initial_sums = os.fstat(sums_descriptor)
        created_files[SUMS_NAME] = (initial_sums.st_dev, initial_sums.st_ino)
        view = memoryview(sums)
        while view:
            written = os.write(sums_descriptor, view)
            if written <= 0:
                reject("output-write-failed")
            view = view[written:]
        os.fsync(sums_descriptor)
        sums_state = os.fstat(sums_descriptor)
        if (
            stat.S_IMODE(sums_state.st_mode) != 0o644
            or sums_state.st_nlink != 1
            or sums_state.st_size != len(sums)
        ):
            reject("output-write-failed")
        staged_outputs[SUMS_NAME] = (
            sums_descriptor,
            fingerprint(sums_state),
            hashlib.sha256(sums).hexdigest(),
        )
        sums_descriptor = -1
    except BaseException:
        if sums_descriptor >= 0:
            os.close(sums_descriptor)
        raise

    if sorted(os.listdir(staging_descriptor), key=lambda item: item.encode("utf-8")) != sorted(
        (*COPY_NAMES, SUMS_NAME), key=lambda item: item.encode("utf-8")
    ):
        reject("output-changed")
    os.fsync(staging_descriptor)

    # A second complete input pass creates a deterministic late-failure window
    # and proves the private staging tree still represents immutable inputs.
    if hash_descriptor(dmg_descriptor, dmg_state, "dmg-changed") != dmg_hash:
        reject("dmg-changed")
    if hash_descriptor(tar_descriptor, tar_state, "source-archive-changed") != tar_hash:
        reject("source-archive-changed")
    if hash_descriptor(zip_descriptor, zip_state, "source-archive-changed") != zip_hash:
        reject("source-archive-changed")
    if hashlib.sha256(
        read_all(notes_descriptor, notes_state, "release-notes-changed", 1024 * 1024)
    ).hexdigest() != notes_hash:
        reject("release-notes-changed")

    ensure_path_still_bound(dmg_path, dmg_state, "dmg-changed")
    ensure_path_still_bound(sources_path, sources_state, "source-directory-changed")
    ensure_path_still_bound(NOTES_SOURCE, notes_state, "release-notes-changed")
    if fingerprint(os.fstat(tar_descriptor)) != tar_state or fingerprint(os.fstat(zip_descriptor)) != zip_state:
        reject("source-archive-changed")
    validate_staged_outputs(
        staging_descriptor,
        (*COPY_NAMES, SUMS_NAME),
        staged_outputs,
    )
    revalidate_candidate_state(
        values["commit"], script_descriptor, script_state, committed_script
    )
    ensure_directory_path_matches_fd(
        parent,
        parent_descriptor,
        parent_identity,
        "output-parent-changed",
        parent_after_staging,
    )
    current_staging = os.stat(staging_name, dir_fd=parent_descriptor, follow_symlinks=False)
    if (
        staging_identity is None
        or current_staging.st_dev != staging_identity[0]
        or current_staging.st_ino != staging_identity[1]
        or current_staging.st_dev != os.fstat(staging_descriptor).st_dev
        or current_staging.st_ino != os.fstat(staging_descriptor).st_ino
    ):
        reject("output-changed")

    atomic_publish(parent_descriptor, staging_name, output_path.name)
    published = True
    try:
        if staging_identity is None:
            reject("output-changed")
        ensure_published_output_bound(
            parent_descriptor,
            output_path.name,
            staging_descriptor,
            staging_identity,
        )
        ensure_directory_path_matches_fd(
            parent,
            parent_descriptor,
            parent_identity,
            "output-parent-changed",
        )
        validate_staged_outputs(
            staging_descriptor,
            (*COPY_NAMES, SUMS_NAME),
            staged_outputs,
        )
        revalidate_candidate_state(
            values["commit"], script_descriptor, script_state, committed_script
        )
        ensure_directory_path_matches_fd(
            parent,
            parent_descriptor,
            parent_identity,
            "output-parent-changed",
        )
        test_barrier("assembler-final")
        ensure_directory_path_matches_fd(
            parent,
            parent_descriptor,
            parent_identity,
            "output-parent-changed",
        )
        ensure_published_output_bound(
            parent_descriptor,
            output_path.name,
            staging_descriptor,
            staging_identity,
        )
        validate_staged_outputs(
            staging_descriptor,
            (*COPY_NAMES, SUMS_NAME),
            staged_outputs,
        )
        ensure_directory_path_matches_fd(
            parent,
            parent_descriptor,
            parent_identity,
            "output-parent-changed",
        )
        ensure_published_output_bound(
            parent_descriptor,
            output_path.name,
            staging_descriptor,
            staging_identity,
        )
    except BaseException:
        cleanup_private_directory_by_identity(
            parent_descriptor,
            output_path.name,
            staging_identity,
            created_files,
        )
        published = False
        raise
    try:
        os.fsync(parent_descriptor)
    except OSError:
        pass
finally:
    if not published and parent_descriptor >= 0 and staging_name and staging_identity is not None:
        cleanup_private_directory_by_identity(
            parent_descriptor,
            staging_name,
            staging_identity,
            created_files,
        )
    if staging_descriptor >= 0:
        os.close(staging_descriptor)
    if parent_descriptor >= 0:
        os.close(parent_descriptor)
    for descriptor, _, _ in staged_outputs.values():
        try:
            os.close(descriptor)
        except OSError:
            pass
    for descriptor in descriptors:
        try:
            os.close(descriptor)
        except OSError:
            pass
PY
