#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import secrets
import stat
import subprocess
import sys
from typing import NoReturn


HEX40 = re.compile(r"[0-9a-f]{40}\Z")
CANONICAL_ORIGIN = re.compile(
    r"https://github[.]com/[A-Za-z0-9](?:[A-Za-z0-9_.-]{0,99})/UtterInk[.]git\Z"
)
BASE_NOT_RUN_FILES = (
    "accessibility-matrix.json",
    "approval-consumed.json",
    "automated-checks.json",
    "candidate.json",
    "documentation-review.json",
    "final-dmg-verification.json",
    "history-scan.json",
    "identity-review.json",
    "legal-review.json",
    "local-gatekeeper.json",
    "manual-verification-matrix.json",
    "notarization-approval.json",
    "notarization-request.json",
    "notarization-result.json",
    "public-file-list.json",
    "release-assets-evidence.json",
    "repository-scope.json",
    "second-mac-gatekeeper.json",
    "signature-verification.json",
    "signing-evidence.json",
    "support-scope.json",
    "unsigned-build-evidence.json",
)
BASE_EXTERNAL_APPROVALS = (
    "apple-notarization-upload",
    "beta-transfer",
    "github-release-publication",
    "private-first-push",
    "public-visibility",
)
BASE_STATEMENT = (
    "This baseline records only not-run release evidence and grants no permission "
    "to sign, submit, transfer, publish, or release."
)
OUTPUT_NAMES = ("base-evidence.json",)
CONTROLLED_INPUTS = (
    ".gitignore",
    "README.md",
    "README.zh-CN.md",
    "Scripts/release/collect-evidence.py",
    "Scripts/release/prepare-incomplete-evidence.py",
    "docs/release/evidence-schema.json",
    "docs/release/manual-verification-matrix.md",
)
SAFE_ENV = {
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_SYSTEM": "/dev/null",
    "GIT_NO_LAZY_FETCH": "1",
    "GIT_NO_REPLACE_OBJECTS": "1",
    "GIT_OPTIONAL_LOCKS": "0",
    "GIT_TERMINAL_PROMPT": "0",
    "LC_ALL": "C",
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "PYTHONDONTWRITEBYTECODE": "1",
}
GIT = "/usr/bin/git"
PYTHON = "/usr/bin/python3"
FD_EXEC_BOOTSTRAP = (
    "import os,sys;source=sys.argv[1];path=sys.argv[2];"
    "fd=int(source.rsplit('/',1)[1]);sys.argv=sys.argv[2:];"
    "size=os.fstat(fd).st_size;code=b''.join(os.pread(fd,min(1048576,size-off),off) "
    "for off in range(0,size,1048576));"
    "len(code)==size or (_ for _ in ()).throw(OSError('short-read'));"
    "ns={'__name__':'__main__','__file__':path};"
    "exec(compile(code,path,'exec'),ns,ns)"
)


class PreparationError(Exception):
    def __init__(self, category: str):
        super().__init__(category)
        self.category = category


def reject(category: str) -> NoReturn:
    raise PreparationError(category)


def canonical(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def fingerprint(value: os.stat_result) -> tuple[int, ...]:
    return (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_uid,
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def safe_directory(metadata: os.stat_result) -> bool:
    return (
        stat.S_ISDIR(metadata.st_mode)
        and not stat.S_ISLNK(metadata.st_mode)
        and metadata.st_uid == os.geteuid()
        and metadata.st_mode & 0o022 == 0
    )


def run(
    command: list[str],
    root: Path,
    *,
    timeout: int = 900,
    pass_fds: tuple[int, ...] = (),
) -> subprocess.CompletedProcess[bytes]:
    try:
        return subprocess.run(
            command,
            cwd=root,
            env=SAFE_ENV,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            pass_fds=pass_fds,
            timeout=timeout,
        )
    except (OSError, subprocess.SubprocessError):
        reject("local-verification-failed")


def git(root: Path, *arguments: str, expected: tuple[int, ...] = (0,)) -> bytes:
    result = run([GIT, "--no-optional-locks", "-C", os.fspath(root), *arguments], root)
    if result.returncode not in expected:
        reject("repository-verification-failed")
    return result.stdout


def validate_script(path: Path) -> None:
    try:
        metadata = os.lstat(path)
    except OSError:
        reject("unsafe-release-tool")
    if (
        not stat.S_ISREG(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or metadata.st_nlink != 1
        or metadata.st_mode & 0o022
        or metadata.st_size <= 0
    ):
        reject("unsafe-release-tool")


def validate_local_config(root: Path) -> None:
    allowed_exact = {
        "core.bare",
        "core.filemode",
        "core.ignorecase",
        "core.logallrefupdates",
        "core.precomposeunicode",
        "core.repositoryformatversion",
        "user.email",
        "user.name",
    }
    raw = git(root, "config", "--local", "--no-includes", "--name-only", "--list", "-z")
    try:
        keys = [item.decode("utf-8", errors="strict") for item in raw.rstrip(b"\0").split(b"\0") if item]
    except UnicodeError:
        reject("unsafe-git-config")
    for key in keys:
        if key in allowed_exact:
            continue
        if re.fullmatch(r"remote[.][A-Za-z0-9._-]+[.](?:url|fetch)", key):
            continue
        if re.fullmatch(r"branch[.][A-Za-z0-9._/-]+[.](?:remote|merge)", key):
            continue
        reject("unsafe-git-config")


def zero_records(raw: bytes, category: str) -> list[bytes]:
    if raw and not raw.endswith(b"\0"):
        reject(category)
    return [] if not raw else raw[:-1].split(b"\0")


def parse_tree(raw: bytes, object_length: int) -> dict[bytes, tuple[bytes, bytes, bytes]]:
    result: dict[bytes, tuple[bytes, bytes, bytes]] = {}
    for record in zero_records(raw, "invalid-repository-index"):
        metadata, separator, path = record.partition(b"\t")
        fields = metadata.split(b" ")
        if separator != b"\t" or len(fields) != 3 or not path or path in result:
            reject("invalid-repository-index")
        mode, object_type, object_id = fields
        if (
            mode not in {b"100644", b"100755", b"120000", b"160000"}
            or object_type not in {b"blob", b"commit"}
            or len(object_id) != object_length
            or re.fullmatch(b"[0-9a-f]+", object_id) is None
        ):
            reject("invalid-repository-index")
        result[path] = (mode, object_type, object_id)
    return result


def parse_index(raw: bytes, object_length: int) -> dict[bytes, tuple[bytes, bytes]]:
    result: dict[bytes, tuple[bytes, bytes]] = {}
    for record in zero_records(raw, "invalid-repository-index"):
        metadata, separator, path = record.partition(b"\t")
        fields = metadata.split(b" ")
        if separator != b"\t" or len(fields) != 3 or not path or path in result:
            reject("invalid-repository-index")
        mode, object_id, stage = fields
        if (
            stage != b"0"
            or mode not in {b"100644", b"100755", b"120000", b"160000"}
            or len(object_id) != object_length
            or re.fullmatch(b"[0-9a-f]+", object_id) is None
        ):
            reject("invalid-repository-index")
        result[path] = (mode, object_id)
    return result


def read_bound_input(root: Path, relative: str, expected: tuple[bytes, bytes, bytes], algorithm: str) -> bytes:
    path = root / relative
    current = root
    for component in Path(relative).parts[:-1]:
        current /= component
        try:
            if not safe_directory(os.lstat(current)):
                reject("unsafe-controlled-input")
        except OSError:
            reject("unsafe-controlled-input")
    expected_mode, object_type, expected_id = expected
    if object_type != b"blob" or expected_mode not in {b"100644", b"100755"}:
        reject("controlled-input-mismatch")
    descriptor = -1
    try:
        before = os.lstat(path)
        if (
            not stat.S_ISREG(before.st_mode)
            or stat.S_ISLNK(before.st_mode)
            or before.st_uid != os.geteuid()
            or before.st_nlink != 1
            or before.st_mode & 0o022
            or before.st_size <= 0
            or before.st_size > 16 * 1024 * 1024
        ):
            reject("unsafe-controlled-input")
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
        opened = os.fstat(descriptor)
        if fingerprint(before) != fingerprint(opened):
            reject("controlled-input-mutated")
        data = b""
        while len(data) <= 16 * 1024 * 1024:
            chunk = os.read(descriptor, min(1024 * 1024, 16 * 1024 * 1024 + 1 - len(data)))
            if not chunk:
                break
            data += chunk
        after = os.fstat(descriptor)
        named = os.lstat(path)
        if fingerprint(opened) != fingerprint(after) or fingerprint(after) != fingerprint(named):
            reject("controlled-input-mutated")
        actual_mode = b"100755" if opened.st_mode & 0o111 else b"100644"
        digest = hashlib.new(algorithm)
        digest.update(f"blob {len(data)}\0".encode("ascii"))
        digest.update(data)
        if actual_mode != expected_mode or digest.hexdigest().encode("ascii") != expected_id:
            reject("controlled-input-mismatch")
        return hashlib.sha256(repr(fingerprint(after)).encode("ascii") + b"\0" + data).digest()
    except PreparationError:
        raise
    except (OSError, ValueError):
        reject("unsafe-controlled-input")
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def repository_snapshot(root: Path, commit: str, expected_origin: str | None) -> bytes:
    try:
        root_metadata = os.lstat(root)
        git_metadata = os.lstat(root / ".git")
        config_metadata = os.lstat(root / ".git/config")
    except OSError:
        reject("not-a-repository")
    if (
        not safe_directory(root_metadata)
        or not safe_directory(git_metadata)
        or not stat.S_ISREG(config_metadata.st_mode)
        or stat.S_ISLNK(config_metadata.st_mode)
        or config_metadata.st_uid != os.geteuid()
        or config_metadata.st_nlink != 1
        or config_metadata.st_mode & 0o022
    ):
        reject("unsafe-repository")
    validate_local_config(root)
    discovered = git(root, "rev-parse", "--show-toplevel").decode("utf-8", errors="strict").strip()
    if discovered != os.fspath(root):
        reject("repository-mismatch")
    head = git(root, "rev-parse", "--verify", "HEAD^{commit}").decode("ascii", errors="strict").strip()
    resolved = git(root, "rev-parse", "--verify", f"{commit}^{{commit}}").decode("ascii", errors="strict").strip()
    if head != commit or resolved != commit:
        reject("candidate-commit-mismatch")
    object_format = git(root, "rev-parse", "--show-object-format").decode("ascii", errors="strict").strip()
    if object_format not in {"sha1", "sha256"}:
        reject("unsupported-object-format")
    object_length = 40 if object_format == "sha1" else 64
    tree_raw = git(root, "ls-tree", "-r", "-z", "--full-tree", commit)
    index_raw = git(root, "ls-files", "--stage", "-z")
    tree = parse_tree(tree_raw, object_length)
    index = parse_index(index_raw, object_length)
    if set(tree) != set(index) or any((mode, object_id) != index[path] for path, (mode, _, object_id) in tree.items()):
        reject("repository-index-mismatch")
    flags_raw = git(root, "ls-files", "-v", "-z")
    flag_paths: set[bytes] = set()
    for record in zero_records(flags_raw, "invalid-repository-index"):
        if not record.startswith(b"H ") or not record[2:] or record[2:] in flag_paths:
            reject("hidden-index-state")
        flag_paths.add(record[2:])
    if flag_paths != set(tree):
        reject("repository-index-mismatch")
    status_raw = git(root, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=no")
    if status_raw:
        reject("dirty-worktree")
    raw_remotes = git(root, "remote")
    try:
        remote_text = raw_remotes.decode("utf-8", errors="strict")
        if remote_text and not remote_text.endswith("\n"):
            reject("invalid-origin")
        remotes = [item for item in remote_text.splitlines() if item]
    except UnicodeError:
        reject("invalid-origin")
    if expected_origin is None:
        if remotes:
            reject("origin-approval-required")
    else:
        if CANONICAL_ORIGIN.fullmatch(expected_origin) is None or remotes != ["origin"]:
            reject("invalid-origin")
        actual_text = git(root, "config", "--local", "--no-includes", "--get-all", "remote.origin.url").decode(
            "utf-8", errors="strict"
        )
        actual = actual_text.splitlines()
        if actual != [expected_origin]:
            reject("origin-mismatch")
    pieces = [tree_raw, index_raw, flags_raw, status_raw, raw_remotes, os.fspath(root).encode("utf-8")]
    for relative in CONTROLLED_INPUTS:
        key = relative.encode("utf-8")
        expected = tree.get(key)
        if expected is None:
            reject("controlled-input-missing")
        pieces.append(key + b"\0" + read_bound_input(root, relative, expected, object_format))
    digest = hashlib.sha256()
    for piece in pieces:
        digest.update(len(piece).to_bytes(8, "big"))
        digest.update(piece)
    return digest.digest()


def stable_repository_checkpoint(root: Path, commit: str, expected_origin: str | None) -> bytes:
    first = repository_snapshot(root, commit, expected_origin)
    second = repository_snapshot(root, commit, expected_origin)
    if first != second:
        reject("repository-state-unstable")
    return first


def open_commit_bound_inputs(root: Path, commit: str, relatives: tuple[str, ...]) -> dict[str, int]:
    object_format = git(root, "rev-parse", "--show-object-format").decode("ascii", errors="strict").strip()
    if object_format not in {"sha1", "sha256"}:
        reject("unsupported-object-format")
    tree = parse_tree(
        git(root, "ls-tree", "-r", "-z", "--full-tree", commit),
        40 if object_format == "sha1" else 64,
    )
    result: dict[str, int] = {}
    try:
        for relative in relatives:
            expected = tree.get(relative.encode("utf-8"))
            if expected is None:
                reject("controlled-input-missing")
            descriptor = os.open(
                root / relative,
                os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
            )
            result[relative] = descriptor
            metadata = os.fstat(descriptor)
            expected_mode, object_type, expected_id = expected
            if (
                not stat.S_ISREG(metadata.st_mode)
                or metadata.st_uid != os.geteuid()
                or metadata.st_nlink != 1
                or metadata.st_mode & 0o022
                or metadata.st_size <= 0
                or metadata.st_size > 16 * 1024 * 1024
                or object_type != b"blob"
            ):
                reject("unsafe-controlled-input")
            data = b""
            offset = 0
            while offset <= 16 * 1024 * 1024:
                chunk = os.pread(descriptor, min(1024 * 1024, 16 * 1024 * 1024 + 1 - offset), offset)
                if not chunk:
                    break
                data += chunk
                offset += len(chunk)
            after = os.fstat(descriptor)
            named = os.lstat(root / relative)
            actual_mode = b"100755" if after.st_mode & 0o111 else b"100644"
            digest = hashlib.new(object_format)
            digest.update(f"blob {len(data)}\0".encode("ascii"))
            digest.update(data)
            if (
                fingerprint(metadata) != fingerprint(after)
                or fingerprint(after) != fingerprint(named)
                or actual_mode != expected_mode
                or digest.hexdigest().encode("ascii") != expected_id
            ):
                reject("controlled-input-mismatch")
        return result
    except BaseException:
        for descriptor in result.values():
            try:
                os.close(descriptor)
            except OSError:
                pass
        raise


def output_path(root: Path, raw: str) -> Path:
    if (
        not raw
        or "\0" in raw
        or raw.startswith("~")
        or "\\" in raw
        or any(ord(character) < 32 or ord(character) == 127 for character in raw)
    ):
        reject("invalid-output")
    candidate = Path(raw)
    if not candidate.is_absolute():
        candidate = root / candidate
    candidate = Path(os.path.abspath(os.fspath(candidate)))
    work = root / ".release-work"
    try:
        relative = candidate.relative_to(work)
    except ValueError:
        reject("output-outside-release-work")
    if candidate == work or not relative.parts or any(part in {"", ".", ".."} for part in relative.parts):
        reject("invalid-output")
    if PurePosixPath(relative.as_posix()).is_absolute():
        reject("invalid-output")
    for name in OUTPUT_NAMES:
        check = run(
            [GIT, "--no-optional-locks", "-C", os.fspath(root), "check-ignore", "-q", "--", os.fspath((candidate / name).relative_to(root))],
            root,
        )
        if check.returncode != 0:
            reject("output-not-ignored")
    return candidate


def inspect_output(root: Path, output: Path) -> tuple[bool, tuple[int, ...] | None]:
    current = root
    relative = output.relative_to(root)
    for index, part in enumerate(relative.parts):
        current = current / part
        try:
            metadata = os.lstat(current)
        except FileNotFoundError:
            return False, None
        except OSError:
            reject("unsafe-output")
        if stat.S_ISLNK(metadata.st_mode):
            reject("unsafe-output")
        if index < len(relative.parts) - 1:
            if not safe_directory(metadata):
                reject("unsafe-output")
        else:
            if not safe_directory(metadata):
                reject("unsafe-output")
            try:
                if os.listdir(current):
                    reject("nonempty-output")
            except OSError:
                reject("unsafe-output")
            return True, fingerprint(metadata)
    reject("unsafe-output")


def ensure_work_root(root: Path) -> Path:
    work = root / ".release-work"
    try:
        os.mkdir(work, 0o700)
    except FileExistsError:
        pass
    except OSError:
        reject("unsafe-output")
    try:
        metadata = os.lstat(work)
    except OSError:
        reject("unsafe-output")
    if not safe_directory(metadata):
        reject("unsafe-output")
    return work


def open_work_root(root: Path) -> tuple[Path, int, tuple[int, int]]:
    work = ensure_work_root(root)
    descriptor = -1
    try:
        before = os.lstat(work)
        descriptor = os.open(
            work,
            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
        )
        opened = os.fstat(descriptor)
        if fingerprint(before) != fingerprint(opened) or not safe_directory(opened):
            reject("unsafe-output")
        return work, descriptor, (opened.st_dev, opened.st_ino)
    except BaseException:
        if descriptor >= 0:
            os.close(descriptor)
        raise


def validate_work_binding(work: Path, descriptor: int, identity: tuple[int, int]) -> None:
    try:
        opened = os.fstat(descriptor)
        named = os.lstat(work)
        if (
            (opened.st_dev, opened.st_ino) != identity
            or (named.st_dev, named.st_ino) != identity
            or not safe_directory(opened)
            or not safe_directory(named)
        ):
            reject("release-work-rebound")
    except PreparationError:
        raise
    except OSError:
        reject("release-work-rebound")


def create_private_directory(directory: int, prefix: str) -> tuple[str, int, tuple[int, int]]:
    for _ in range(32):
        name = prefix + secrets.token_hex(16)
        try:
            os.mkdir(name, 0o700, dir_fd=directory)
        except FileExistsError:
            continue
        child = -1
        try:
            child = os.open(
                name,
                os.O_RDONLY
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=directory,
            )
            metadata = os.fstat(child)
            if not safe_directory(metadata) or stat.S_IMODE(metadata.st_mode) != 0o700:
                reject("unsafe-output")
            return name, child, (metadata.st_dev, metadata.st_ino)
        except BaseException:
            if child >= 0:
                os.close(child)
            try:
                os.rmdir(name, dir_fd=directory)
            except OSError:
                pass
            raise
    reject("unsafe-output")


def read_regular(path: Path, category: str, maximum: int = 16 * 1024 * 1024) -> bytes:
    descriptor = -1
    try:
        before = os.lstat(path)
        if (
            not stat.S_ISREG(before.st_mode)
            or stat.S_ISLNK(before.st_mode)
            or before.st_uid != os.geteuid()
            or before.st_nlink != 1
            or before.st_mode & 0o022
            or before.st_size <= 0
            or before.st_size > maximum
        ):
            reject(category)
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
        opened = os.fstat(descriptor)
        if fingerprint(before) != fingerprint(opened):
            reject(category)
        data = b""
        while len(data) <= maximum:
            chunk = os.read(descriptor, min(1024 * 1024, maximum + 1 - len(data)))
            if not chunk:
                break
            data += chunk
        after = os.fstat(descriptor)
        if fingerprint(opened) != fingerprint(after) or not data or len(data) > maximum:
            reject(category)
        return data
    except PreparationError:
        raise
    except OSError:
        reject(category)
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def write_exclusive(path: Path, data: bytes) -> None:
    directory = -1
    try:
        directory = os.open(
            path.parent,
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
        if not safe_directory(os.fstat(directory)) or path.name in {"", ".", ".."}:
            reject("output-write-failed")
        write_exclusive_at(directory, path.name, data)
    except PreparationError:
        raise
    except OSError:
        reject("output-write-failed")
    finally:
        if directory >= 0:
            os.close(directory)


def write_exclusive_at(directory: int, name: str, data: bytes) -> None:
    descriptor = -1
    identity: tuple[int, int] | None = None
    try:
        descriptor = os.open(
            name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
            0o600,
            dir_fd=directory,
        )
        created = os.fstat(descriptor)
        identity = (created.st_dev, created.st_ino)
        view = memoryview(data)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                reject("output-write-failed")
            view = view[written:]
        os.fchmod(descriptor, 0o600)
        os.fsync(descriptor)
        opened = os.fstat(descriptor)
        named = os.stat(name, dir_fd=directory, follow_symlinks=False)
        if (
            fingerprint(opened) != fingerprint(named)
            or opened.st_nlink != 1
            or stat.S_IMODE(opened.st_mode) != 0o600
            or opened.st_size != len(data)
        ):
            reject("output-write-failed")
    except BaseException as error:
        if descriptor >= 0:
            try:
                os.close(descriptor)
            except OSError:
                pass
            descriptor = -1
        if identity is not None:
            try:
                current = os.stat(name, dir_fd=directory, follow_symlinks=False)
                if (current.st_dev, current.st_ino) == identity and not stat.S_ISDIR(current.st_mode):
                    os.unlink(name, dir_fd=directory)
            except OSError:
                pass
        if isinstance(error, PreparationError):
            raise
        if isinstance(error, OSError):
            reject("output-write-failed")
        raise
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def read_regular_at(directory: int, name: str, category: str) -> bytes:
    descriptor = -1
    try:
        before = os.stat(name, dir_fd=directory, follow_symlinks=False)
        if (
            not stat.S_ISREG(before.st_mode)
            or stat.S_ISLNK(before.st_mode)
            or before.st_uid != os.geteuid()
            or before.st_nlink != 1
            or stat.S_IMODE(before.st_mode) != 0o600
            or before.st_size <= 0
            or before.st_size > 16 * 1024 * 1024
        ):
            reject(category)
        descriptor = os.open(
            name,
            os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=directory,
        )
        opened = os.fstat(descriptor)
        if fingerprint(before) != fingerprint(opened):
            reject(category)
        chunks: list[bytes] = []
        remaining = before.st_size
        while remaining:
            chunk = os.read(descriptor, min(remaining, 1024 * 1024))
            if not chunk:
                reject(category)
            chunks.append(chunk)
            remaining -= len(chunk)
        after = os.fstat(descriptor)
        named = os.stat(name, dir_fd=directory, follow_symlinks=False)
        if fingerprint(opened) != fingerprint(after) or fingerprint(after) != fingerprint(named):
            reject(category)
        return b"".join(chunks)
    except PreparationError:
        raise
    except OSError:
        reject(category)
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def base_record(commit: str) -> bytes:
    return canonical(
        {
            "candidateCommit": commit,
            "evidenceType": "incomplete-release-status",
            "notRunEvidenceFiles": list(BASE_NOT_RUN_FILES),
            "outstandingExternalApprovals": list(BASE_EXTERNAL_APPROVALS),
            "product": "UtterInk",
            "schemaVersion": 1,
            "statement": BASE_STATEMENT,
            "status": "NOT_RELEASE_READY",
        }
    )


class CreatedDirectory:
    def __init__(self, parent: int, name: str, identity: tuple[int, int]):
        self.parent = parent
        self.name = name
        self.identity = identity


class Publication:
    def __init__(
        self,
        directory: int,
        directory_identity: tuple[int, int],
        files: dict[str, tuple[int, int]],
        created_directories: list[CreatedDirectory],
    ):
        self.directory = directory
        self.directory_identity = directory_identity
        self.files = files
        self.created_directories = created_directories

    def close(self) -> None:
        if self.directory >= 0:
            os.close(self.directory)
            self.directory = -1
        for item in self.created_directories:
            if item.parent >= 0:
                os.close(item.parent)
                item.parent = -1


def rollback_publication(publication: Publication) -> None:
    if publication.directory >= 0:
        for name, identity in publication.files.items():
            try:
                metadata = os.stat(name, dir_fd=publication.directory, follow_symlinks=False)
                if (
                    (metadata.st_dev, metadata.st_ino) == identity
                    and stat.S_ISREG(metadata.st_mode)
                    and metadata.st_uid == os.geteuid()
                    and metadata.st_nlink == 1
                ):
                    os.unlink(name, dir_fd=publication.directory)
            except OSError:
                pass
        try:
            os.fsync(publication.directory)
        except OSError:
            pass
    for item in reversed(publication.created_directories):
        if item.parent < 0:
            continue
        try:
            metadata = os.stat(item.name, dir_fd=item.parent, follow_symlinks=False)
            if (metadata.st_dev, metadata.st_ino) == item.identity and stat.S_ISDIR(metadata.st_mode):
                os.rmdir(item.name, dir_fd=item.parent)
                os.fsync(item.parent)
        except OSError:
            pass


def create_output(
    root: Path,
    output: Path,
    existed: bool,
    original: tuple[int, ...] | None,
    files: dict[str, bytes],
) -> Publication:
    directory = -1
    created: dict[str, tuple[int, int]] = {}
    created_directories: list[CreatedDirectory] = []
    publication: Publication | None = None
    try:
        directory = os.open(
            root,
            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
        )
        root_metadata = os.fstat(directory)
        if not safe_directory(root_metadata):
            reject("unsafe-output")
        parts = output.relative_to(root).parts
        for index, component in enumerate(parts):
            last = index == len(parts) - 1
            created_component = False
            try:
                next_directory = os.open(
                    component,
                    os.O_RDONLY
                    | getattr(os, "O_DIRECTORY", 0)
                    | getattr(os, "O_CLOEXEC", 0)
                    | getattr(os, "O_NOFOLLOW", 0),
                    dir_fd=directory,
                )
            except FileNotFoundError:
                if last and existed:
                    reject("unsafe-output")
                parent = os.fstat(directory)
                if not safe_directory(parent):
                    reject("unsafe-output")
                parent_for_rollback = -1
                next_directory = -1
                try:
                    os.mkdir(component, 0o700, dir_fd=directory)
                    next_directory = os.open(
                        component,
                        os.O_RDONLY
                        | getattr(os, "O_DIRECTORY", 0)
                        | getattr(os, "O_CLOEXEC", 0)
                        | getattr(os, "O_NOFOLLOW", 0),
                        dir_fd=directory,
                    )
                    parent_for_rollback = os.dup(directory)
                    created_component = True
                    created_metadata = os.fstat(next_directory)
                    created_directories.append(
                        CreatedDirectory(
                            parent=parent_for_rollback,
                            name=component,
                            identity=(created_metadata.st_dev, created_metadata.st_ino),
                        )
                    )
                except OSError:
                    if next_directory >= 0:
                        os.close(next_directory)
                    if parent_for_rollback >= 0:
                        os.close(parent_for_rollback)
                    try:
                        os.rmdir(component, dir_fd=directory)
                    except OSError:
                        pass
                    reject("unsafe-output")
            except OSError:
                reject("unsafe-output")
            metadata = os.fstat(next_directory)
            if not safe_directory(metadata):
                os.close(next_directory)
                reject("unsafe-output")
            if last and original is not None and fingerprint(metadata) != original:
                os.close(next_directory)
                reject("unsafe-output")
            if last and not existed and not created_component:
                os.close(next_directory)
                reject("unsafe-output")
            if created_component or last:
                os.fchmod(next_directory, 0o700)
                metadata = os.fstat(next_directory)
                if stat.S_IMODE(metadata.st_mode) != 0o700:
                    os.close(next_directory)
                    reject("unsafe-output")
            os.close(directory)
            directory = next_directory
        metadata = os.fstat(directory)
        if os.listdir(directory):
            reject("nonempty-output")
        for name in OUTPUT_NAMES:
            write_exclusive_at(directory, name, files[name])
            item = os.stat(name, dir_fd=directory, follow_symlinks=False)
            created[name] = (item.st_dev, item.st_ino)
        if sorted(os.listdir(directory), key=lambda item: item.encode("utf-8")) != list(OUTPUT_NAMES):
            reject("output-write-failed")
        for name in OUTPUT_NAMES:
            if read_regular_at(directory, name, "output-write-failed") != files[name]:
                reject("output-write-failed")
        final_directory = os.fstat(directory)
        os.fsync(directory)
        publication = Publication(
            directory=directory,
            directory_identity=(final_directory.st_dev, final_directory.st_ino),
            files=dict(created),
            created_directories=created_directories,
        )
        directory = -1
        created_directories = []
        return publication
    except BaseException:
        for name, identity in created.items():
            try:
                metadata = os.stat(name, dir_fd=directory, follow_symlinks=False)
                if (
                    (metadata.st_dev, metadata.st_ino) == identity
                    and stat.S_ISREG(metadata.st_mode)
                    and metadata.st_uid == os.geteuid()
                    and metadata.st_nlink == 1
                ):
                    os.unlink(name, dir_fd=directory)
            except OSError:
                pass
        temporary = Publication(
            directory=directory,
            directory_identity=(-1, -1),
            files={},
            created_directories=created_directories,
        )
        rollback_publication(temporary)
        temporary.close()
        directory = -1
        created_directories = []
        raise
    finally:
        if directory >= 0:
            os.close(directory)
        for item in created_directories:
            if item.parent >= 0:
                os.close(item.parent)


def validate_publication(output: Path, publication: Publication, files: dict[str, bytes]) -> None:
    try:
        opened = os.fstat(publication.directory)
        named = os.lstat(output)
        if (
            (opened.st_dev, opened.st_ino) != publication.directory_identity
            or (named.st_dev, named.st_ino) != publication.directory_identity
            or not safe_directory(opened)
            or not safe_directory(named)
            or sorted(os.listdir(publication.directory), key=lambda item: item.encode("utf-8")) != list(OUTPUT_NAMES)
        ):
            reject("published-output-mutated")
        for name in OUTPUT_NAMES:
            if read_regular_at(publication.directory, name, "published-output-mutated") != files[name]:
                reject("published-output-mutated")
            metadata = os.stat(name, dir_fd=publication.directory, follow_symlinks=False)
            if (metadata.st_dev, metadata.st_ino) != publication.files[name]:
                reject("published-output-mutated")
    except PreparationError:
        raise
    except OSError:
        reject("published-output-mutated")


def test_after_publish_barrier() -> None:
    notify_text = os.environ.get("UTTERINK_INCOMPLETE_TEST_NOTIFY_FD")
    continue_text = os.environ.get("UTTERINK_INCOMPLETE_TEST_CONTINUE_FD")
    if notify_text is None and continue_text is None:
        return
    if os.environ.get("UTTERINK_INCOMPLETE_TEST_MODE") != "1" or notify_text is None or continue_text is None:
        reject("invalid-test-barrier")
    try:
        notify = int(notify_text)
        continuation = int(continue_text)
        if notify < 3 or continuation < 3 or notify == continuation:
            reject("invalid-test-barrier")
        if not stat.S_ISFIFO(os.fstat(notify).st_mode) or not stat.S_ISFIFO(os.fstat(continuation).st_mode):
            reject("invalid-test-barrier")
        if os.write(notify, b"P") != 1 or os.read(continuation, 1) != b"C":
            reject("invalid-test-barrier")
        os.close(notify)
        os.close(continuation)
    except PreparationError:
        raise
    except (OSError, ValueError):
        reject("invalid-test-barrier")


def test_before_collector_barrier() -> None:
    notify_text = os.environ.get("UTTERINK_INCOMPLETE_COLLECTOR_TEST_NOTIFY_FD")
    continue_text = os.environ.get("UTTERINK_INCOMPLETE_COLLECTOR_TEST_CONTINUE_FD")
    if notify_text is None and continue_text is None:
        return
    if (
        os.environ.get("UTTERINK_INCOMPLETE_COLLECTOR_TEST_MODE") != "1"
        or notify_text is None
        or continue_text is None
    ):
        reject("invalid-test-barrier")
    try:
        notify = int(notify_text)
        continuation = int(continue_text)
        if notify < 3 or continuation < 3 or notify == continuation:
            reject("invalid-test-barrier")
        if not stat.S_ISFIFO(os.fstat(notify).st_mode) or not stat.S_ISFIFO(os.fstat(continuation).st_mode):
            reject("invalid-test-barrier")
        if os.write(notify, b"B") != 1 or os.read(continuation, 1) != b"C":
            reject("invalid-test-barrier")
        os.close(notify)
        os.close(continuation)
    except PreparationError:
        raise
    except (OSError, ValueError):
        reject("invalid-test-barrier")


class Parser(argparse.ArgumentParser):
    def error(self, message: str) -> NoReturn:
        del message
        reject("invalid-arguments")


def parse_arguments() -> argparse.Namespace:
    arguments = sys.argv[1:]
    if len(arguments) not in {4, 6} or arguments.count("--commit") != 1 or arguments.count("--output") != 1:
        reject("invalid-arguments")
    if len(arguments) == 6 and arguments.count("--expected-origin") != 1:
        reject("invalid-arguments")
    if len(arguments) == 4 and "--expected-origin" in arguments:
        reject("invalid-arguments")
    parser = Parser(add_help=False)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--expected-origin")
    result = parser.parse_args(arguments)
    if HEX40.fullmatch(result.commit) is None:
        reject("invalid-arguments")
    if result.expected_origin is not None and CANONICAL_ORIGIN.fullmatch(result.expected_origin) is None:
        reject("invalid-origin")
    return result


def main() -> int:
    work: Path | None = None
    work_descriptor = -1
    work_identity: tuple[int, int] | None = None
    stage_name: str | None = None
    stage_descriptor = -1
    stage_identity: tuple[int, int] | None = None
    stage_file_identities: dict[str, tuple[int, int]] = {}
    packet_name: str | None = None
    packet_identity: tuple[int, int] | None = None
    bound_inputs: dict[str, int] = {}
    publication: Publication | None = None
    publication_complete = False
    try:
        os.umask(0o077)
        arguments = parse_arguments()
        invoked_script = Path(__file__).absolute()
        validate_script(invoked_script)
        script = invoked_script.resolve(strict=True)
        validate_script(script)
        root = script.parents[2]
        collector = root / "Scripts/release/collect-evidence.py"
        schema = root / "docs/release/evidence-schema.json"
        for tool in (collector, schema):
            validate_script(tool)
        output = output_path(root, arguments.output)
        existed, original = inspect_output(root, output)
        work, work_descriptor, work_identity = open_work_root(root)
        initial_checkpoint = stable_repository_checkpoint(root, arguments.commit, arguments.expected_origin)
        bound_inputs = open_commit_bound_inputs(
            root,
            arguments.commit,
            (
                "Scripts/release/collect-evidence.py",
                "docs/release/evidence-schema.json",
                "docs/release/manual-verification-matrix.md",
                "README.md",
            ),
        )
        stage_name, stage_descriptor, stage_identity = create_private_directory(
            work_descriptor, ".prepare-incomplete-evidence."
        )
        base = base_record(arguments.commit)
        write_exclusive_at(stage_descriptor, "base-evidence.json", base)
        base_metadata = os.stat("base-evidence.json", dir_fd=stage_descriptor, follow_symlinks=False)
        stage_file_identities["base-evidence.json"] = (base_metadata.st_dev, base_metadata.st_ino)
        packet_name = f".prepare-incomplete-evidence-packet.{secrets.token_hex(16)}.md"
        collector_descriptor = bound_inputs["Scripts/release/collect-evidence.py"]
        policy_descriptors = (
            bound_inputs["docs/release/evidence-schema.json"],
            bound_inputs["docs/release/manual-verification-matrix.md"],
            bound_inputs["README.md"],
        )
        test_before_collector_barrier()
        collected = run(
            [
                PYTHON,
                "-I",
                "-c",
                FD_EXEC_BOOTSTRAP,
                f"/dev/fd/{collector_descriptor}",
                os.fspath(collector),
                "--inputs",
                f"/dev/fd/{stage_descriptor}",
                "--output",
                f"/dev/fd/{work_descriptor}/{packet_name}",
                "--expect-status",
                "NOT_RELEASE_READY",
                "--bound-policy-fds",
                ",".join(str(item) for item in policy_descriptors),
                "--bound-io-fds",
                f"{stage_descriptor},{work_descriptor}",
            ],
            root,
            pass_fds=(collector_descriptor, *policy_descriptors, stage_descriptor, work_descriptor),
        )
        if collected.returncode != 0 or collected.stdout != b"NOT_RELEASE_READY\n" or collected.stderr:
            reject("baseline-schema-verification-failed")
        packet_before = os.stat(packet_name, dir_fd=work_descriptor, follow_symlinks=False)
        packet_identity = (packet_before.st_dev, packet_before.st_ino)
        packet_bytes = read_regular_at(work_descriptor, packet_name, "baseline-schema-verification-failed")
        packet_after = os.stat(packet_name, dir_fd=work_descriptor, follow_symlinks=False)
        if fingerprint(packet_before) != fingerprint(packet_after):
            reject("baseline-schema-verification-failed")
        base_digest = hashlib.sha256(base).hexdigest()
        required_packet_lines = (
            b"Computed status: NOT_RELEASE_READY\n",
            f"Candidate commit: {arguments.commit}\n".encode("ascii"),
            b"Candidate tree: not-recorded\n",
            b"Candidate record SHA-256: not-recorded\n",
            f"| `base-evidence.json` | `{base_digest}` |\n".encode("ascii"),
            b"| `candidate` | `not-run` |\n",
            b"| `toolchain` | `not-run` |\n",
            b"| `dependency-lock` | `not-run` |\n",
        )
        if any(line not in packet_bytes for line in required_packet_lines):
            reject("baseline-schema-verification-failed")
        if stable_repository_checkpoint(root, arguments.commit, arguments.expected_origin) != initial_checkpoint:
            reject("repository-state-changed")
        validate_work_binding(work, work_descriptor, work_identity)
        if read_regular_at(stage_descriptor, "base-evidence.json", "invalid-base-evidence") != base:
            reject("evidence-mutated-after-validation")
        files = {"base-evidence.json": base}
        publication = create_output(root, output, existed, original, files)
        validate_publication(output, publication, files)
        test_after_publish_barrier()
        if stable_repository_checkpoint(root, arguments.commit, arguments.expected_origin) != initial_checkpoint:
            reject("repository-state-changed-after-publish")
        validate_work_binding(work, work_descriptor, work_identity)
        validate_publication(output, publication, files)
        publication_complete = True
        print("NOT_RELEASE_READY")
        return 0
    except PreparationError as error:
        print(f"incomplete evidence error: {error.category}", file=sys.stderr)
        return 1
    except (OSError, UnicodeError, ValueError, KeyError):
        print("incomplete evidence error: internal-failure", file=sys.stderr)
        return 1
    finally:
        if publication is not None:
            if not publication_complete:
                rollback_publication(publication)
            publication.close()
        if packet_name is not None and packet_identity is not None and work_descriptor >= 0:
            try:
                current = os.stat(packet_name, dir_fd=work_descriptor, follow_symlinks=False)
                if (current.st_dev, current.st_ino) == packet_identity and stat.S_ISREG(current.st_mode):
                    os.unlink(packet_name, dir_fd=work_descriptor)
            except OSError:
                pass
        if stage_descriptor >= 0:
            for name, identity in stage_file_identities.items():
                try:
                    item = os.stat(name, dir_fd=stage_descriptor, follow_symlinks=False)
                    if (item.st_dev, item.st_ino) == identity and not stat.S_ISDIR(item.st_mode):
                        os.unlink(name, dir_fd=stage_descriptor)
                except OSError:
                    pass
            try:
                os.fsync(stage_descriptor)
            except OSError:
                pass
            os.close(stage_descriptor)
            stage_descriptor = -1
        if stage_name is not None and stage_identity is not None and work_descriptor >= 0:
            try:
                current = os.stat(stage_name, dir_fd=work_descriptor, follow_symlinks=False)
                if (current.st_dev, current.st_ino) == stage_identity and safe_directory(current):
                    os.rmdir(stage_name, dir_fd=work_descriptor)
            except OSError:
                pass
        for descriptor in bound_inputs.values():
            try:
                os.close(descriptor)
            except OSError:
                pass
        if work_descriptor >= 0:
            os.close(work_descriptor)


if __name__ == "__main__":
    raise SystemExit(main())
