#!/usr/bin/env -S -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u BASH_XTRACEFD -u PS4 -u POSIXLY_CORRECT -u BASH_COMPAT -u UTTERINK_VERIFY_ASSETS_ENV_CLEAN /bin/bash -p

set +x +v
if [[ "$-" != *p* ]]; then
  /usr/bin/printf 'release asset verification error: unsafe-launch-environment\n' >&2
  exit 2
fi
if [[ "${UTTERINK_VERIFY_ASSETS_ENV_CLEAN:-}" != 1 ]]; then
  exec /usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    LC_ALL=C \
    UTTERINK_VERIFY_ASSETS_ENV_CLEAN=1 \
    /bin/bash -p "$0" "$@"
  /usr/bin/printf 'release asset verification error: unsafe-launch-environment\n' >&2
  exit 2
fi
if [[ "$-" != hpB || "${PATH-}" != /usr/bin:/bin:/usr/sbin:/sbin || "${LC_ALL-}" != C ]]; then
  /usr/bin/printf 'release asset verification error: unsafe-launch-environment\n' >&2
  exit 2
fi
while IFS= read -r -d '' environment_entry; do
  environment_name="${environment_entry%%=*}"
  case "$environment_name" in
    PATH|LC_ALL|UTTERINK_VERIFY_ASSETS_ENV_CLEAN|PWD|SHLVL|_) ;;
    *) /usr/bin/printf 'release asset verification error: unsafe-launch-environment\n' >&2; exit 2 ;;
  esac
done < <(/usr/bin/env -0)
unset UTTERINK_VERIFY_ASSETS_ENV_CLEAN

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
  /usr/bin/printf 'release asset verification error: unsafe-repository\n' >&2
  exit 20
}
SCRIPT_DIRECTORY="$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "$SCRIPT_PATH")" && /bin/pwd -P)"
ROOT="$(CDPATH= cd -P -- "$SCRIPT_DIRECTORY/../.." && /bin/pwd -P)"
readonly SCRIPT_PATH SCRIPT_DIRECTORY ROOT

exec /usr/bin/python3 -I - "$ROOT" "$SCRIPT_PATH" "$@" <<'PY'
from __future__ import annotations

import binascii
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import secrets
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
import unicodedata
import zipfile
import zlib

ROOT = Path(sys.argv[1])
SCRIPT = Path(sys.argv[2])
ARGUMENTS = sys.argv[3:]
DMG_NAME = "UtterInk-0.1.0-arm64.dmg"
TAR_NAME = "UtterInk-0.1.0-source.tar.gz"
ZIP_NAME = "UtterInk-0.1.0-source.zip"
SUMS_NAME = "SHA256SUMS"
NOTES_NAME = "release-notes-0.1.0.md"
PREFIX = "UtterInk-0.1.0/"
MAX_ARCHIVE_BYTES = 512 * 1024 * 1024
MAX_MEMBER_BYTES = 128 * 1024 * 1024
ASSET_NAMES = tuple(sorted((DMG_NAME, TAR_NAME, ZIP_NAME, SUMS_NAME, NOTES_NAME), key=lambda value: value.encode("utf-8")))
CHECKSUM_NAMES = tuple(name for name in ASSET_NAMES if name != SUMS_NAME)
SCRIPT_RELATIVE = "Scripts/release/verify-release-assets.sh"


def reject(category: str, status_code: int = 1) -> None:
    print(f"release asset verification error: {category}", file=sys.stderr)
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
        "--assets": "assets",
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
        or stat.S_IMODE(before.st_mode) != 0o644
    ):
        os.close(descriptor)
        reject(category)
    return descriptor, fingerprint(opened)


def ensure_directory_still_bound(path: Path, descriptor: int, expected: tuple[int, ...], category: str) -> None:
    try:
        current_path = os.lstat(path)
        current_descriptor = os.fstat(descriptor)
    except OSError:
        reject(category)
    if fingerprint(current_path) != expected or fingerprint(current_descriptor) != expected:
        reject(category)


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
    try:
        current = os.lstat(ROOT / SCRIPT_RELATIVE)
    except OSError:
        reject("script-binding-changed")
    if actual != committed or fingerprint(current) != state:
        reject("script-binding-changed")


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


def validate_release_notes(notes: bytes, committed: bytes) -> None:
    if notes != committed:
        reject("release-notes-mismatch")
    try:
        text = notes.decode("utf-8", "strict")
    except UnicodeDecodeError:
        reject("release-notes-mismatch")
    required = (
        "# UtterInk 0.1.0\n",
        "first public release",
        "does not by\nitself prove that a binary has been published",
        "GitHub Release page",
        "## Highlights\n",
        "Local Whisper transcription",
        "Right Option as the default dictation shortcut",
        "Guarded Automatic Paste",
        "Simple provider setup",
        "stores the selected credential in macOS Keychain",
        "Raw output plus Clean Up",
        "Translate to English",
        "Classical Chinese",
        "user-created polishing modes",
        "## Requirements\n",
        "macOS 14 or later",
        "Apple Silicon (arm64) only",
        "## Privacy and data handling\n",
        "transcription is\nperformed locally on this Mac",
        "Audio is not stored in History and is never\nsent",
        "optional OpenAI-compatible text polishing",
        "sends transcript text",
        "## Updates\n",
        "has no automatic updater",
        "Install future versions manually",
        "## Known limitations\n",
        "## Verify checksums\n",
        "shasum -a 256 -c SHA256SUMS",
        "exactly two spaces",
    )
    if any(value not in text for value in required):
        reject("release-notes-mismatch")
    headings = [line for line in text.splitlines() if line.startswith("## ")]
    if headings != [
        "## Highlights",
        "## Requirements",
        "## Privacy and data handling",
        "## Updates",
        "## Known limitations",
        "## Verify checksums",
    ]:
        reject("release-notes-mismatch")


def checked_member_name(raw: str, directory: bool) -> str:
    if not raw or "\\" in raw or any(ord(character) < 32 or ord(character) == 127 for character in raw):
        reject("invalid-source-archive")
    path = PurePosixPath(raw)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        reject("invalid-source-archive")
    normalized = path.as_posix()
    if directory:
        normalized = normalized.rstrip("/") + "/"
    if not normalized.startswith(PREFIX) or normalized == PREFIX.rstrip("/"):
        reject("invalid-source-archive")
    return normalized


def tar_inventory(file_object, *, expected_archive: bool = False) -> dict[str, tuple[str, int, int, str]]:
    inventory: dict[str, tuple[str, int, int, str]] = {}
    try:
        with tarfile.open(fileobj=file_object, mode="r:*") as archive:
            for member in archive.getmembers():
                if member.isdir():
                    name = checked_member_name(member.name, True)
                    if member.mode & 0o777 not in {0o755, 0o775}:
                        reject("invalid-source-archive")
                    value = ("directory", 0o755, 0, "")
                elif member.isfile():
                    name = checked_member_name(member.name, False)
                    if member.mode & 0o777 not in {0o644, 0o664, 0o755, 0o775}:
                        reject("invalid-source-archive")
                    extracted = archive.extractfile(member)
                    if extracted is None:
                        reject("invalid-source-archive")
                    digest = hashlib.sha256()
                    count = 0
                    while True:
                        chunk = extracted.read(1024 * 1024)
                        if not chunk:
                            break
                        digest.update(chunk)
                        count += len(chunk)
                        if count > member.size:
                            reject("invalid-source-archive")
                    if count != member.size:
                        reject("invalid-source-archive")
                    mode = 0o755 if member.mode & 0o111 else 0o644
                    value = ("file", mode, member.size, digest.hexdigest())
                else:
                    reject("invalid-source-archive")
                if name in inventory:
                    reject("invalid-source-archive")
                inventory[name] = value
    except (OSError, EOFError, tarfile.TarError, ValueError):
        reject("invalid-source-archive")
    if PREFIX not in inventory or len(inventory) < 2:
        reject("invalid-source-archive")
    return inventory


def zip_inventory(file_object) -> dict[str, tuple[str, int, int, str]]:
    inventory: dict[str, tuple[str, int, int, str]] = {}
    try:
        with zipfile.ZipFile(file_object, mode="r") as archive:
            for member in archive.infolist():
                raw_mode = (member.external_attr >> 16) & 0xFFFF
                if stat.S_ISLNK(raw_mode):
                    reject("invalid-source-archive")
                is_directory = member.is_dir()
                if raw_mode and is_directory and (
                    not stat.S_ISDIR(raw_mode)
                    or raw_mode & 0o777 not in {0o755, 0o775}
                ):
                    reject("invalid-source-archive")
                if raw_mode and not is_directory and (
                    not stat.S_ISREG(raw_mode)
                    or raw_mode & 0o777 not in {0o644, 0o664, 0o755, 0o775}
                ):
                    reject("invalid-source-archive")
                name = checked_member_name(member.filename, is_directory)
                if is_directory:
                    value = ("directory", 0o755, 0, "")
                else:
                    digest = hashlib.sha256()
                    count = 0
                    with archive.open(member, "r") as extracted:
                        while True:
                            chunk = extracted.read(1024 * 1024)
                            if not chunk:
                                break
                            digest.update(chunk)
                            count += len(chunk)
                            if count > member.file_size:
                                reject("invalid-source-archive")
                    if count != member.file_size:
                        reject("invalid-source-archive")
                    mode = 0o755 if raw_mode & 0o111 else 0o644
                    value = ("file", mode, member.file_size, digest.hexdigest())
                if name in inventory:
                    reject("invalid-source-archive")
                inventory[name] = value
            if archive.testzip() is not None:
                reject("invalid-source-archive")
    except (OSError, EOFError, RuntimeError, ValueError, zipfile.BadZipFile, zipfile.LargeZipFile):
        reject("invalid-source-archive")
    if PREFIX not in inventory or len(inventory) < 2:
        reject("invalid-source-archive")
    return inventory


def forbidden_source_path(path: str) -> bool:
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


def source_tree(commit: str) -> dict[str, tuple[int, str]]:
    raw = git("ls-tree", "-r", "-z", "--full-tree", commit, binary=True)
    if not raw or not raw.endswith(b"\0"):
        reject("source-tree-contract")
    expected: dict[str, tuple[int, str]] = {}
    for record in raw[:-1].split(b"\0"):
        try:
            metadata, raw_path = record.split(b"\t", 1)
            mode_text, kind, object_id = metadata.decode("ascii").split(" ")
            path = raw_path.decode("utf-8", "strict")
        except (UnicodeDecodeError, ValueError):
            reject("source-tree-contract")
        pure = PurePosixPath(path)
        if (
            kind != "blob"
            or mode_text not in {"100644", "100755"}
            or re.fullmatch(r"[0-9a-f]{40}", object_id) is None
            or not path
            or path in expected
            or pure.is_absolute()
            or ".." in pure.parts
            or "\\" in path
            or any(ord(character) < 32 or ord(character) == 127 for character in path)
            or unicodedata.normalize("NFC", path) != path
            or forbidden_source_path(path)
        ):
            reject("source-tree-contract")
        expected[path] = (0o755 if mode_text == "100755" else 0o644, object_id)
    return expected


def compare_descriptor_to_file(
    descriptor: int,
    state: tuple[int, ...],
    expected_file,
    category: str,
) -> None:
    os.lseek(descriptor, 0, os.SEEK_SET)
    expected_file.seek(0, os.SEEK_END)
    expected_size = expected_file.tell()
    expected_file.seek(0)
    if state[6] != expected_size:
        reject(category)
    remaining = expected_size
    while remaining:
        expected_chunk = expected_file.read(min(1024 * 1024, remaining))
        actual_chunk = os.read(descriptor, len(expected_chunk))
        if not expected_chunk or actual_chunk != expected_chunk:
            reject(category)
        remaining -= len(expected_chunk)
    if os.read(descriptor, 1) or expected_file.read(1) or fingerprint(os.fstat(descriptor)) != state:
        reject(category)


def verify_canonical_source_archives(
    commit: str,
    tar_descriptor: int,
    tar_state: tuple[int, ...],
    zip_descriptor: int,
    zip_state: tuple[int, ...],
) -> dict[str, tuple[str, int, int, str]]:
    expected_tree = source_tree(commit)
    files: dict[str, tuple[int, bytes]] = {}
    directories: set[str] = {PREFIX}
    with tempfile.TemporaryFile(mode="w+b") as raw_tar:
        result = subprocess.run(
            [
                "/usr/bin/git", "-C", str(ROOT),
                "-c", "core.fsmonitor=false",
                "-c", "core.untrackedCache=false",
                "-c", "core.hooksPath=/dev/null",
                "--no-pager",
                "archive", "--format=tar", f"--prefix={PREFIX}", commit,
            ],
            stdin=subprocess.DEVNULL,
            stdout=raw_tar,
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
        if result.returncode != 0 or raw_tar.tell() < 1 or raw_tar.tell() > MAX_ARCHIVE_BYTES:
            reject("source-tree-archive-failed")
        raw_tar.seek(0)
        try:
            with tarfile.open(fileobj=raw_tar, mode="r:") as archive:
                for member in archive.getmembers():
                    name = member.name
                    if unicodedata.normalize("NFC", name) != name:
                        reject("source-tree-archive-invalid")
                    if name.rstrip("/") == PREFIX.rstrip("/"):
                        if not member.isdir():
                            reject("source-tree-archive-invalid")
                        continue
                    if not name.startswith(PREFIX) or "\\" in name:
                        reject("source-tree-archive-invalid")
                    relative = name[len(PREFIX):].rstrip("/")
                    if not relative:
                        reject("source-tree-archive-invalid")
                    pure = PurePosixPath(relative)
                    if pure.is_absolute() or ".." in pure.parts or not pure.parts:
                        reject("source-tree-archive-invalid")
                    if member.isdir():
                        directories.add(PREFIX + relative + "/")
                        continue
                    if (
                        not member.isfile()
                        or relative in files
                        or relative not in expected_tree
                        or member.size < 0
                        or member.size > MAX_MEMBER_BYTES
                    ):
                        reject("source-tree-archive-invalid")
                    extracted = archive.extractfile(member)
                    if extracted is None:
                        reject("source-tree-archive-invalid")
                    content = extracted.read(MAX_MEMBER_BYTES + 1)
                    if len(content) != member.size or len(content) > MAX_MEMBER_BYTES:
                        reject("source-tree-archive-invalid")
                    expected_mode, expected_object = expected_tree[relative]
                    object_digest = hashlib.sha1()
                    object_digest.update(f"blob {len(content)}\0".encode("ascii"))
                    object_digest.update(content)
                    if object_digest.hexdigest() != expected_object:
                        reject("source-tree-object-mismatch")
                    files[relative] = (expected_mode, content)
                    current = PurePosixPath(relative).parent
                    while current != PurePosixPath("."):
                        directories.add(PREFIX + current.as_posix() + "/")
                        current = current.parent
        except (OSError, EOFError, tarfile.TarError):
            reject("source-tree-archive-invalid")
    if set(files) != set(expected_tree):
        reject("source-tree-inventory-mismatch")

    inventory: dict[str, tuple[str, int, int, str]] = {
        directory: ("directory", 0o755, 0, "") for directory in directories
    }
    for relative, (mode, content) in files.items():
        inventory[PREFIX + relative] = ("file", mode, len(content), hashlib.sha256(content).hexdigest())

    with tempfile.TemporaryFile(mode="w+b") as normalized_tar, tempfile.TemporaryFile(mode="w+b") as canonical_tar, tempfile.TemporaryFile(mode="w+b") as canonical_zip:
        with tarfile.open(fileobj=normalized_tar, mode="w", format=tarfile.PAX_FORMAT) as archive:
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
                info = tarfile.TarInfo(PREFIX + relative)
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
        normalized_tar.seek(0)
        compressor = zlib.compressobj(level=9, method=zlib.DEFLATED, wbits=-15)
        crc = 0
        size = 0
        canonical_tar.write(b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff")
        while True:
            chunk = normalized_tar.read(1024 * 1024)
            if not chunk:
                break
            size = (size + len(chunk)) & 0xFFFFFFFF
            crc = binascii.crc32(chunk, crc) & 0xFFFFFFFF
            canonical_tar.write(compressor.compress(chunk))
        canonical_tar.write(compressor.flush())
        canonical_tar.write(struct.pack("<II", crc, size))

        with zipfile.ZipFile(
            canonical_zip,
            mode="w",
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
                info = zipfile.ZipInfo(PREFIX + relative, date_time=(1980, 1, 1, 0, 0, 0))
                info.create_system = 3
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = (stat.S_IFREG | mode) << 16
                info.flag_bits |= 0x800
                archive.writestr(info, content, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)

        compare_descriptor_to_file(tar_descriptor, tar_state, canonical_tar, "noncanonical-source-archive")
        compare_descriptor_to_file(zip_descriptor, zip_state, canonical_zip, "noncanonical-source-archive")
    return inventory


def parse_checksums(raw: bytes, actual: dict[str, str]) -> None:
    try:
        text = raw.decode("ascii", "strict")
    except UnicodeDecodeError:
        reject("invalid-checksums")
    if not text.endswith("\n") or "\r" in text or "\x00" in text:
        reject("invalid-checksums")
    lines = text.splitlines()
    if len(lines) != len(CHECKSUM_NAMES):
        reject("invalid-checksums")
    parsed: list[str] = []
    for line in lines:
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9._-]+)", line)
        if match is None:
            reject("invalid-checksums")
        digest, name = match.groups()
        if name == SUMS_NAME or name not in CHECKSUM_NAMES or digest != actual.get(name):
            reject("invalid-checksums")
        parsed.append(name)
    if parsed != list(CHECKSUM_NAMES):
        reject("invalid-checksums")


def ensure_output_parent_still_bound(
    path: Path,
    descriptor: int,
    identity: tuple[int, int],
    category: str,
) -> None:
    try:
        named = os.lstat(path)
        held = os.fstat(descriptor)
    except OSError:
        reject(category)
    if (
        fingerprint(named) != fingerprint(held)
        or (held.st_dev, held.st_ino) != identity
        or not stat.S_ISDIR(held.st_mode)
        or stat.S_ISLNK(named.st_mode)
        or held.st_uid != os.geteuid()
        or held.st_mode & 0o022
    ):
        reject(category)


def write_atomic_evidence(
    path: Path,
    payload: bytes,
    assets_path: Path,
) -> tuple[int, tuple[int, int], tuple[int, ...]]:
    if path.name != "release-assets-evidence.json" or path == assets_path or assets_path in path.parents:
        reject("unsafe-output")
    parent = path.parent
    parent_descriptor, parent_state = safe_directory(parent, "unsafe-output-parent")
    parent_identity = (parent_state[0], parent_state[1])
    temporary_name = f".release-assets-evidence.{secrets.token_hex(16)}.tmp"
    temporary_descriptor = -1
    linked = False
    keep_parent_descriptor = False
    target_identity: tuple[int, int] | None = None
    try:
        try:
            os.stat(path.name, dir_fd=parent_descriptor, follow_symlinks=False)
        except FileNotFoundError:
            pass
        except OSError:
            reject("unsafe-output")
        else:
            reject("output-exists")
        try:
            temporary_descriptor = os.open(
                temporary_name,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                0o600,
                dir_fd=parent_descriptor,
            )
            view = memoryview(payload)
            while view:
                written = os.write(temporary_descriptor, view)
                if written <= 0:
                    reject("output-write-failed")
                view = view[written:]
            os.fsync(temporary_descriptor)
            temporary_state = os.fstat(temporary_descriptor)
            if stat.S_IMODE(temporary_state.st_mode) != 0o600 or temporary_state.st_nlink != 1 or temporary_state.st_size != len(payload):
                reject("output-write-failed")
            os.close(temporary_descriptor)
            temporary_descriptor = -1
            os.link(
                temporary_name,
                path.name,
                src_dir_fd=parent_descriptor,
                dst_dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
            linked = True
            target_identity = (temporary_state.st_dev, temporary_state.st_ino)
            os.unlink(temporary_name, dir_fd=parent_descriptor)
            linked_state = os.stat(path.name, dir_fd=parent_descriptor, follow_symlinks=False)
            if (
                not stat.S_ISREG(linked_state.st_mode)
                or stat.S_ISLNK(linked_state.st_mode)
                or linked_state.st_uid != os.geteuid()
                or linked_state.st_nlink != 1
                or stat.S_IMODE(linked_state.st_mode) != 0o600
                or linked_state.st_size != len(payload)
            ):
                reject("output-write-failed")
            readback = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent_descriptor)
            try:
                readback_before = os.fstat(readback)
                content = b""
                while len(content) < len(payload):
                    chunk = os.read(readback, len(payload) - len(content))
                    if not chunk:
                        reject("output-write-failed")
                    content += chunk
                readback_after = os.fstat(readback)
                if (
                    content != payload
                    or os.read(readback, 1)
                    or fingerprint(readback_before) != fingerprint(linked_state)
                    or fingerprint(readback_after) != fingerprint(linked_state)
                ):
                    reject("output-write-failed")
            finally:
                os.close(readback)
            os.fsync(parent_descriptor)
            ensure_output_parent_still_bound(
                parent,
                parent_descriptor,
                parent_identity,
                "output-parent-changed",
            )
            keep_parent_descriptor = True
        except FileExistsError:
            reject("output-exists")
        except OSError:
            reject("output-write-failed")
    except BaseException:
        if linked and target_identity is not None:
            try:
                current = os.stat(path.name, dir_fd=parent_descriptor, follow_symlinks=False)
                if (
                    current.st_dev == target_identity[0]
                    and current.st_ino == target_identity[1]
                    and stat.S_ISREG(current.st_mode)
                    and not stat.S_ISLNK(current.st_mode)
                    and current.st_uid == os.geteuid()
                ):
                    os.unlink(path.name, dir_fd=parent_descriptor)
                    os.fsync(parent_descriptor)
            except OSError:
                pass
        raise
    finally:
        if temporary_descriptor >= 0:
            os.close(temporary_descriptor)
        try:
            os.unlink(temporary_name, dir_fd=parent_descriptor)
        except OSError:
            pass
        if not keep_parent_descriptor:
            os.close(parent_descriptor)
    return parent_descriptor, parent_identity, fingerprint(linked_state)


def remove_exact_output_at(parent: int, name: str, expected: tuple[int, ...]) -> None:
    try:
        names = [name, *os.listdir(parent)]
    except OSError:
        names = [name]
    seen: set[str] = set()
    for candidate in names:
        if candidate in seen:
            continue
        seen.add(candidate)
        try:
            current = os.stat(candidate, dir_fd=parent, follow_symlinks=False)
            if (
                current.st_dev == expected[0]
                and current.st_ino == expected[1]
                and stat.S_ISREG(current.st_mode)
                and not stat.S_ISLNK(current.st_mode)
                and current.st_uid == os.geteuid()
            ):
                os.unlink(candidate, dir_fd=parent)
                os.fsync(parent)
                return
        except OSError:
            continue


def verify_exact_output_at(parent: int, name: str, expected: tuple[int, ...], payload: bytes) -> None:
    try:
        named_before = os.stat(name, dir_fd=parent, follow_symlinks=False)
        descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent)
    except OSError:
        reject("output-changed")
    try:
        before = os.fstat(descriptor)
        content = b""
        while len(content) < len(payload):
            chunk = os.read(descriptor, len(payload) - len(content))
            if not chunk:
                reject("output-changed")
            content += chunk
        after = os.fstat(descriptor)
        try:
            named_after = os.stat(name, dir_fd=parent, follow_symlinks=False)
        except OSError:
            reject("output-changed")
        if (
            content != payload
            or os.read(descriptor, 1)
            or fingerprint(named_before) != expected
            or fingerprint(named_after) != expected
            or fingerprint(before) != expected
            or fingerprint(after) != expected
        ):
            reject("output-changed")
    finally:
        os.close(descriptor)


values = parse_arguments()
assets_path = absolute_path(values["assets"], "invalid-arguments")
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
assets_descriptor, assets_state = safe_directory(assets_path, "unsafe-assets")
try:
    try:
        names = sorted(os.listdir(assets_descriptor), key=lambda value: value.encode("utf-8"))
    except OSError:
        reject("invalid-asset-inventory")
    if names != list(ASSET_NAMES):
        reject("invalid-asset-inventory")
    opened: dict[str, tuple[int, tuple[int, ...]]] = {
        name: safe_file_at(assets_descriptor, name, "unsafe-asset") for name in ASSET_NAMES
    }
    try:
        hashes = {
            name: hash_descriptor(descriptor, state, "asset-changed")
            for name, (descriptor, state) in opened.items()
        }
        sizes = {name: state[6] for name, (_, state) in opened.items()}
        if hashes[DMG_NAME] != values["dmg_hash"]:
            reject("final-dmg-hash-mismatch")
        sums = read_all(*opened[SUMS_NAME], "invalid-checksums", 1024 * 1024)
        parse_checksums(sums, hashes)
        notes = read_all(*opened[NOTES_NAME], "release-notes-mismatch", 1024 * 1024)
        validate_release_notes(notes, committed_notes)

        expected = verify_canonical_source_archives(
            values["commit"],
            opened[TAR_NAME][0],
            opened[TAR_NAME][1],
            opened[ZIP_NAME][0],
            opened[ZIP_NAME][1],
        )
        os.lseek(opened[TAR_NAME][0], 0, os.SEEK_SET)
        os.lseek(opened[ZIP_NAME][0], 0, os.SEEK_SET)
        tar_stream = os.fdopen(os.dup(opened[TAR_NAME][0]), "rb", closefd=True)
        zip_stream = os.fdopen(os.dup(opened[ZIP_NAME][0]), "rb", closefd=True)
        try:
            tar_items = tar_inventory(tar_stream)
            zip_items = zip_inventory(zip_stream)
        finally:
            tar_stream.close()
            zip_stream.close()
        if tar_items != expected or zip_items != expected or tar_items != zip_items:
            reject("source-archive-commit-mismatch")
        for descriptor, state in opened.values():
            if fingerprint(os.fstat(descriptor)) != state:
                reject("asset-changed")

        asset_records = [
            {"filename": name, "sha256": hashes[name], "sizeBytes": sizes[name]}
            for name in ASSET_NAMES
        ]
        evidence = {
            "assets": asset_records,
            "candidateCommit": values["commit"],
            "evidenceType": "release-assets",
            "finalDMGSHA256": values["dmg_hash"],
            "product": "UtterInk",
            "releaseTag": "v0.1.0",
            "schemaVersion": 1,
            "status": "valid",
        }
        payload = (json.dumps(evidence, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
        ensure_directory_still_bound(assets_path, assets_descriptor, assets_state, "asset-directory-changed")
        revalidate_candidate_state(
            values["commit"], script_descriptor, script_state, committed_script
        )
        evidence_parent_descriptor, evidence_parent_identity, output_state = write_atomic_evidence(
            output_path, payload, assets_path
        )
        try:
            try:
                post_publish_hashes = {
                    name: hash_descriptor(descriptor, state, "asset-changed")
                    for name, (descriptor, state) in opened.items()
                }
                if post_publish_hashes != hashes:
                    reject("asset-changed")
                ensure_directory_still_bound(assets_path, assets_descriptor, assets_state, "asset-directory-changed")
                revalidate_candidate_state(
                    values["commit"], script_descriptor, script_state, committed_script
                )
                ensure_output_parent_still_bound(
                    output_path.parent,
                    evidence_parent_descriptor,
                    evidence_parent_identity,
                    "output-parent-changed",
                )
                verify_exact_output_at(
                    evidence_parent_descriptor, output_path.name, output_state, payload
                )
                ensure_output_parent_still_bound(
                    output_path.parent,
                    evidence_parent_descriptor,
                    evidence_parent_identity,
                    "output-parent-changed",
                )
                test_barrier("verifier-final")
                ensure_output_parent_still_bound(
                    output_path.parent,
                    evidence_parent_descriptor,
                    evidence_parent_identity,
                    "output-parent-changed",
                )
                verify_exact_output_at(
                    evidence_parent_descriptor, output_path.name, output_state, payload
                )
            except BaseException:
                remove_exact_output_at(
                    evidence_parent_descriptor, output_path.name, output_state
                )
                raise
        finally:
            os.close(evidence_parent_descriptor)
    finally:
        for descriptor, _ in opened.values():
            os.close(descriptor)
finally:
    os.close(assets_descriptor)
    os.close(script_descriptor)
PY
