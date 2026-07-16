#!/usr/bin/env python3
from __future__ import annotations

import ast
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import select
import shutil
import stat
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True


ROOT = Path(__file__).resolve().parents[2]
PREPARER = ROOT / "Scripts/release/prepare-incomplete-evidence.py"
COLLECTOR = ROOT / "Scripts/release/collect-evidence.py"
SCHEMA = ROOT / "docs/release/evidence-schema.json"
MATRIX = ROOT / "docs/release/manual-verification-matrix.md"
README = ROOT / "README.md"
README_ZH = ROOT / "README.zh-CN.md"
CANONICAL_ORIGIN = "https://github.com/example/UtterInk.git"
BASE_FILES = (
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
APPROVALS = (
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


def fail(message: str) -> None:
    raise SystemExit(f"prepare incomplete evidence tests failed: {message}")


def command(
    arguments: list[str],
    cwd: Path,
    *,
    env: dict[str, str] | None = None,
    process_umask: int = -1,
) -> subprocess.CompletedProcess[str]:
    process_env = {
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_SYSTEM": "/dev/null",
        "GIT_OPTIONAL_LOCKS": "0",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "PYTHONDONTWRITEBYTECODE": "1",
    }
    if env:
        process_env.update(env)
    return subprocess.run(
        arguments,
        cwd=cwd,
        env=process_env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
        timeout=60,
        umask=process_umask,
    )


def checked(arguments: list[str], cwd: Path, *, env: dict[str, str] | None = None) -> str:
    result = command(arguments, cwd, env=env)
    if result.returncode != 0 or result.stderr:
        fail(f"fixture command failed: {' '.join(arguments[:3])}")
    return result.stdout.strip()


def make_repository(path: Path) -> str:
    (path / "Scripts/release").mkdir(parents=True)
    (path / "Tests/Scripts").mkdir(parents=True)
    (path / "docs/release").mkdir(parents=True)
    shutil.copy2(PREPARER, path / "Scripts/release/prepare-incomplete-evidence.py")
    shutil.copy2(COLLECTOR, path / "Scripts/release/collect-evidence.py")
    shutil.copy2(SCHEMA, path / "docs/release/evidence-schema.json")
    shutil.copy2(MATRIX, path / "docs/release/manual-verification-matrix.md")
    shutil.copy2(README, path / "README.md")
    shutil.copy2(README_ZH, path / "README.zh-CN.md")
    (path / ".gitignore").write_text(".release-work/\n", encoding="utf-8")
    checked(["/usr/bin/git", "init", "-q", "--initial-branch=main"], path)
    checked(["/usr/bin/git", "add", "."], path)
    commit_env = {
        "GIT_AUTHOR_DATE": "2026-07-15T00:00:00Z",
        "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
        "GIT_AUTHOR_NAME": "UtterInk Fixture",
        "GIT_COMMITTER_DATE": "2026-07-15T00:00:00Z",
        "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
        "GIT_COMMITTER_NAME": "UtterInk Fixture",
    }
    checked(["/usr/bin/git", "commit", "-q", "-m", "fixture"], path, env=commit_env)
    return checked(["/usr/bin/git", "rev-parse", "HEAD"], path)


def copy_repository(source: Path, destination: Path) -> Path:
    shutil.copytree(source, destination)
    return destination


def prepare(
    repo: Path,
    commit: str,
    output: str,
    *extra: str,
    process_umask: int = -1,
) -> subprocess.CompletedProcess[str]:
    return command(
        [
            sys.executable,
            "-I",
            os.fspath(repo / "Scripts/release/prepare-incomplete-evidence.py"),
            "--commit",
            commit,
            "--output",
            output,
            *extra,
        ],
        repo,
        process_umask=process_umask,
    )


def prepare_at_publish_barrier(
    repo: Path,
    commit: str,
    output: str,
    action,
    *,
    phase: str = "publish",
) -> subprocess.CompletedProcess[str]:
    notify_read, notify_write = os.pipe()
    continue_read, continue_write = os.pipe()
    if phase not in {"publish", "collector"}:
        fail("invalid fixture barrier phase")
    prefix = "UTTERINK_INCOMPLETE_TEST" if phase == "publish" else "UTTERINK_INCOMPLETE_COLLECTOR_TEST"
    process = subprocess.Popen(
        [
            sys.executable,
            "-I",
            os.fspath(repo / "Scripts/release/prepare-incomplete-evidence.py"),
            "--commit",
            commit,
            "--output",
            output,
        ],
        cwd=repo,
        env={
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_OPTIONAL_LOCKS": "0",
            "LC_ALL": "C",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PYTHONDONTWRITEBYTECODE": "1",
            f"{prefix}_MODE": "1",
            f"{prefix}_NOTIFY_FD": str(notify_write),
            f"{prefix}_CONTINUE_FD": str(continue_read),
        },
        pass_fds=(notify_write, continue_read),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    os.close(notify_write)
    os.close(continue_read)
    try:
        ready, _, _ = select.select([notify_read], [], [], 15)
        expected = b"P" if phase == "publish" else b"B"
        if not ready or os.read(notify_read, 1) != expected:
            process.kill()
            stdout, stderr = process.communicate(timeout=5)
            fail(f"post-publish race did not reach barrier: {stdout}{stderr}")
        action()
        if os.write(continue_write, b"C") != 1:
            fail("post-publish race could not release barrier")
        stdout, stderr = process.communicate(timeout=20)
        return subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr)
    finally:
        os.close(notify_read)
        os.close(continue_write)
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)


def expect_rejected(result: subprocess.CompletedProcess[str], output: Path, label: str) -> None:
    if result.returncode == 0 or result.stdout:
        fail(f"{label} unexpectedly passed or emitted stdout")
    if not result.stderr.startswith("incomplete evidence error: "):
        fail(f"{label} emitted an unexpected diagnostic")
    if any(canary in result.stderr for canary in ("/Users/", "fixture-user", "READY", "pass")):
        fail(f"{label} leaked user input")
    if os.path.lexists(output):
        fail(f"{label} created an output")


for required in (PREPARER, COLLECTOR, SCHEMA, MATRIX, README, README_ZH):
    if not required.is_file() or required.is_symlink():
        fail(f"required source is missing or unsafe: {required.name}")

source = PREPARER.read_text(encoding="utf-8")
try:
    tree = ast.parse(source, filename=os.fspath(PREPARER))
except SyntaxError:
    fail("preparer is not valid Python")
imports: set[str] = set()
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        imports.update(alias.name.partition(".")[0] for alias in node.names)
    elif isinstance(node, ast.ImportFrom) and node.module:
        imports.add(node.module.partition(".")[0])
if imports & {"http", "socket", "urllib"}:
    fail("preparer imports a network module")
for forbidden in (
    "verify-candidate",
    "swift",
    "xcodebuild",
    "xcodegen",
    "notarytool",
    "xcrun",
    "git push",
    "curl ",
    "wget ",
    "gh release",
    "api.github.com",
):
    if forbidden in source:
        fail(f"preparer contains publication capability: {forbidden}")

with tempfile.TemporaryDirectory(prefix="utterink-prepare-incomplete-tests-") as temporary:
    temp = Path(temporary)
    template = temp / "template"
    template.mkdir()
    commit = make_repository(template)

    spy_repository = copy_repository(template, temp / "subprocess-spy")
    module_path = spy_repository / "Scripts/release/prepare-incomplete-evidence.py"
    specification = importlib.util.spec_from_file_location("utterink_prepare_incomplete_fixture", module_path)
    if specification is None or specification.loader is None:
        fail("could not load preparer for subprocess spy")
    preparer_module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(preparer_module)
    observed_commands: list[tuple[str, ...]] = []
    original_run = preparer_module.run

    def spy_run(arguments, root, *, timeout=900, pass_fds=()):
        observed_commands.append(tuple(os.fspath(item) for item in arguments))
        return original_run(arguments, root, timeout=timeout, pass_fds=pass_fds)

    preparer_module.run = spy_run
    previous_arguments = sys.argv
    previous_umask = os.umask(0o077)
    os.umask(previous_umask)
    spy_stdout = io.StringIO()
    spy_stderr = io.StringIO()
    try:
        sys.argv = [
            os.fspath(module_path),
            "--commit",
            commit,
            "--output",
            ".release-work/subprocess-spy-evidence",
        ]
        with contextlib.redirect_stdout(spy_stdout), contextlib.redirect_stderr(spy_stderr):
            spy_status = preparer_module.main()
    finally:
        sys.argv = previous_arguments
        os.umask(previous_umask)
        preparer_module.run = original_run
    if spy_status != 0 or spy_stdout.getvalue() != "NOT_RELEASE_READY\n" or spy_stderr.getvalue():
        fail("in-process subprocess spy initialization failed")
    if not observed_commands or not any(command[0] == "/usr/bin/python3" for command in observed_commands):
        fail("subprocess spy did not observe collector validation")
    forbidden_children = (
        "verify-candidate",
        "swift",
        "xcode",
        "xcodegen",
        "curl",
        "wget",
        "notary",
        "http",
        " fetch ",
        " pull ",
        " push ",
        " clone ",
        "ls-remote",
        "submodule",
    )
    python_children = []
    for observed in observed_commands:
        joined = " ".join(observed).lower()
        if observed[0] not in {"/usr/bin/git", "/usr/bin/python3"} or any(item in joined for item in forbidden_children):
            fail(f"initializer launched a forbidden child process: {observed[0]}")
        if observed[0] == "/usr/bin/git":
            if len(observed) < 5 or observed[4] not in {
                "check-ignore", "config", "ls-files", "ls-tree", "remote", "rev-parse", "status"
            }:
                fail("initializer launched a non-read-only Git subcommand")
        else:
            python_children.append(observed)
    if (
        len(python_children) != 1
        or len(python_children[0]) < 7
        or python_children[0][1] != "-I"
        or python_children[0][2] != "-c"
        or re.fullmatch(r"/dev/fd/[0-9]+", python_children[0][4]) is None
        or python_children[0][5] != os.fspath((spy_repository / "Scripts/release/collect-evidence.py").resolve())
        or "--bound-policy-fds" not in python_children[0]
    ):
        fail("initializer did not launch the commit-bound collector and policy descriptors")

    fault_directory = temp / "write-faults"
    fault_directory.mkdir(mode=0o700)
    original_fsync = preparer_module.os.fsync

    def fail_fsync(_descriptor):
        raise OSError("injected-fsync-failure")

    direct_fault = fault_directory / "direct.json"
    preparer_module.os.fsync = fail_fsync
    try:
        try:
            preparer_module.write_exclusive(direct_fault, b"retry-safe\n")
        except preparer_module.PreparationError:
            pass
        else:
            fail("write_exclusive fsync fault unexpectedly passed")
    finally:
        preparer_module.os.fsync = original_fsync
    if os.path.lexists(direct_fault):
        fail("write_exclusive left a partial file after fsync failure")
    preparer_module.write_exclusive(direct_fault, b"retry-safe\n")
    if direct_fault.read_bytes() != b"retry-safe\n":
        fail("write_exclusive could not retry after rollback")

    at_fault = fault_directory / "at.json"
    directory_descriptor = os.open(fault_directory, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    preparer_module.os.fsync = fail_fsync
    try:
        try:
            preparer_module.write_exclusive_at(directory_descriptor, at_fault.name, b"retry-safe-at\n")
        except preparer_module.PreparationError:
            pass
        else:
            fail("write_exclusive_at fsync fault unexpectedly passed")
    finally:
        preparer_module.os.fsync = original_fsync
    if os.path.lexists(at_fault):
        os.close(directory_descriptor)
        fail("write_exclusive_at left a partial file after fsync failure")
    preparer_module.write_exclusive_at(directory_descriptor, at_fault.name, b"retry-safe-at\n")
    os.close(directory_descriptor)
    if at_fault.read_bytes() != b"retry-safe-at\n":
        fail("write_exclusive_at could not retry after rollback")

    nested_fault = fault_directory / "created/parent/evidence"
    preparer_module.os.fsync = fail_fsync
    try:
        try:
            preparer_module.create_output(
                fault_directory,
                nested_fault,
                False,
                None,
                {"base-evidence.json": b"fault\n"},
            )
        except preparer_module.PreparationError:
            pass
        else:
            fail("create_output fsync fault unexpectedly passed")
    finally:
        preparer_module.os.fsync = original_fsync
    if os.path.lexists(fault_directory / "created"):
        fail("create_output left newly-created directories after a write fault")

    first = copy_repository(template, temp / "first")
    second = copy_repository(template, temp / "second")
    checked(["/usr/bin/git", "config", "--local", "gc.auto", "0"], first)
    first_output = first / ".release-work/evidence"
    second_output = second / ".release-work/evidence"
    first_result = prepare(first, commit, ".release-work/evidence")
    second_result = prepare(second, commit, ".release-work/evidence")
    for label, result in (("first", first_result), ("second", second_result)):
        if result.returncode != 0 or result.stdout != "NOT_RELEASE_READY\n" or result.stderr:
            fail(f"{label} clean initialization failed: {result.stderr.strip()}")
    for output in (first_output, second_output):
        names = sorted(path.name for path in output.iterdir())
        if names != ["base-evidence.json"]:
            fail("initializer emitted an unexpected evidence filename")
        for path in output.iterdir():
            metadata = os.lstat(path)
            if (
                not stat.S_ISREG(metadata.st_mode)
                or stat.S_ISLNK(metadata.st_mode)
                or metadata.st_nlink != 1
                or stat.S_IMODE(metadata.st_mode) != 0o600
            ):
                fail("initializer output is not an owner-only regular file")
    if (first_output / "base-evidence.json").read_bytes() != (second_output / "base-evidence.json").read_bytes():
        fail("base-evidence.json changed across independent absolute roots")
    for repo in (first, second):
        leftovers = [
            path.name
            for path in (repo / ".release-work").iterdir()
            if path.name.startswith(".prepare-incomplete-evidence")
        ]
        if leftovers:
            fail("successful initialization left a private staging artifact")

    base_bytes = (first_output / "base-evidence.json").read_bytes()
    base = json.loads(base_bytes.decode("utf-8"))
    if base_bytes != (json.dumps(base, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8"):
        fail("base evidence is not canonical JSON")
    if base != {
        "candidateCommit": commit,
        "evidenceType": "incomplete-release-status",
        "notRunEvidenceFiles": list(BASE_FILES),
        "outstandingExternalApprovals": list(APPROVALS),
        "product": "UtterInk",
        "schemaVersion": 1,
        "statement": BASE_STATEMENT,
        "status": "NOT_RELEASE_READY",
    }:
        fail("base evidence contract drifted")
    if any(marker in base_bytes for marker in (b"timestamp", b"tester", b"sha256", b'"pass"', b"/Users/", b"/home/")):
        fail("base evidence fabricated or leaked a machine-bound field")

    packet = first / ".release-work/final-evidence-packet.md"
    collected = command(
        [
            sys.executable,
            "-I",
            os.fspath(first / "Scripts/release/collect-evidence.py"),
            "--inputs",
            os.fspath(first_output),
            "--output",
            os.fspath(packet),
            "--expect-status",
            "NOT_RELEASE_READY",
        ],
        first,
    )
    if collected.returncode != 0 or collected.stdout != "NOT_RELEASE_READY\n" or collected.stderr:
        fail(f"real collector rejected initialized evidence: {collected.stderr.strip()}")
    packet_text = packet.read_text(encoding="utf-8")
    required_packet_text = (
        "Candidate tree: not-recorded\n",
        "Candidate record SHA-256: not-recorded\n",
        "| `candidate` | `not-run` |",
        "| `toolchain` | `not-run` |",
        "| `dependency-lock` | `not-run` |",
        "| `signing` | `not-run` |",
        "| `release-assets-inventory` | `not-run` |",
    )
    if "`missing`" in packet_text or any(item not in packet_text for item in required_packet_text):
        fail("initialized packet did not enumerate stable not-run gates")

    existing = copy_repository(template, temp / "existing")
    existing_output = existing / ".release-work/evidence"
    existing_output.mkdir(parents=True, mode=0o700)
    existing_output.chmod(0o755)
    result = prepare(existing, commit, ".release-work/evidence")
    if result.returncode != 0 or result.stdout != "NOT_RELEASE_READY\n" or result.stderr:
        fail("safe existing empty output was rejected")
    if stat.S_IMODE(os.lstat(existing_output).st_mode) != 0o700:
        fail("existing empty output was not tightened to mode 0700")

    hostile_umask = copy_repository(template, temp / "hostile-umask")
    hostile_output = hostile_umask / ".release-work/level-one/level-two/evidence"
    result = prepare(
        hostile_umask,
        commit,
        ".release-work/level-one/level-two/evidence",
        process_umask=0o000,
    )
    if result.returncode != 0 or result.stdout != "NOT_RELEASE_READY\n" or result.stderr:
        fail(f"hostile-umask initialization failed: {result.stderr.strip()}")
    for directory in (
        hostile_umask / ".release-work",
        hostile_umask / ".release-work/level-one",
        hostile_umask / ".release-work/level-one/level-two",
        hostile_output,
    ):
        mode = stat.S_IMODE(os.lstat(directory).st_mode)
        if mode != 0o700 or mode & 0o022:
            fail("hostile umask created an unsafe output parent")

    wrong_commit = copy_repository(template, temp / "wrong-commit")
    wrong_commit_output = wrong_commit / ".release-work/evidence"
    expect_rejected(prepare(wrong_commit, "9" * 40, ".release-work/evidence"), wrong_commit_output, "mismatched commit")

    gc_auto_wrong = copy_repository(template, temp / "gc-auto-wrong")
    checked(["/usr/bin/git", "config", "--local", "gc.auto", "1"], gc_auto_wrong)
    gc_auto_wrong_output = gc_auto_wrong / ".release-work/evidence"
    gc_auto_wrong_result = prepare(gc_auto_wrong, commit, ".release-work/evidence")
    expect_rejected(gc_auto_wrong_result, gc_auto_wrong_output, "nonzero gc.auto")
    if gc_auto_wrong_result.stderr != "incomplete evidence error: unsafe-git-config\n":
        fail("nonzero gc.auto did not fail as unsafe-git-config")

    gc_auto_duplicate = copy_repository(template, temp / "gc-auto-duplicate")
    checked(["/usr/bin/git", "config", "--local", "gc.auto", "0"], gc_auto_duplicate)
    checked(["/usr/bin/git", "config", "--local", "--add", "gc.auto", "0"], gc_auto_duplicate)
    gc_auto_duplicate_output = gc_auto_duplicate / ".release-work/evidence"
    gc_auto_duplicate_result = prepare(gc_auto_duplicate, commit, ".release-work/evidence")
    expect_rejected(gc_auto_duplicate_result, gc_auto_duplicate_output, "duplicate gc.auto")
    if gc_auto_duplicate_result.stderr != "incomplete evidence error: unsafe-git-config\n":
        fail("duplicate gc.auto did not fail as unsafe-git-config")

    dirty = copy_repository(template, temp / "dirty")
    (dirty / "README.md").write_text("dirty\n", encoding="utf-8")
    dirty_output = dirty / ".release-work/evidence"
    expect_rejected(prepare(dirty, commit, ".release-work/evidence"), dirty_output, "dirty worktree")

    controlled_paths = (
        ".gitignore",
        "README.md",
        "README.zh-CN.md",
        "Scripts/release/collect-evidence.py",
        "Scripts/release/prepare-incomplete-evidence.py",
        "docs/release/evidence-schema.json",
        "docs/release/manual-verification-matrix.md",
    )
    for index, relative in enumerate(controlled_paths):
        hidden = copy_repository(template, temp / f"hidden-{index}")
        flag = "--skip-worktree" if index % 2 == 0 else "--assume-unchanged"
        checked(["/usr/bin/git", "update-index", flag, "--", relative], hidden)
        with (hidden / relative).open("ab") as stream:
            stream.write(b"\n# hidden controlled-input tamper\n")
        hidden_output = hidden / ".release-work/evidence"
        expect_rejected(
            prepare(hidden, commit, ".release-work/evidence"),
            hidden_output,
            f"hidden controlled input {index}",
        )

    staged = copy_repository(template, temp / "staged-mismatch")
    with (staged / "README.md").open("ab") as stream:
        stream.write(b"\nstaged mismatch\n")
    checked(["/usr/bin/git", "add", "--", "README.md"], staged)
    staged_output = staged / ".release-work/evidence"
    expect_rejected(prepare(staged, commit, ".release-work/evidence"), staged_output, "staged mismatch")

    mode_mismatch = copy_repository(template, temp / "controlled-mode-mismatch")
    checked(["/usr/bin/git", "config", "--local", "core.filemode", "false"], mode_mismatch)
    (mode_mismatch / "README.md").chmod(0o755)
    mode_output = mode_mismatch / ".release-work/evidence"
    expect_rejected(prepare(mode_mismatch, commit, ".release-work/evidence"), mode_output, "controlled mode mismatch")

    nonempty = copy_repository(template, temp / "nonempty")
    nonempty_output = nonempty / ".release-work/evidence"
    nonempty_output.mkdir(parents=True)
    marker = nonempty_output / "keep.txt"
    marker.write_text("keep\n", encoding="utf-8")
    result = prepare(nonempty, commit, ".release-work/evidence")
    if result.returncode == 0 or result.stdout or marker.read_text(encoding="utf-8") != "keep\n":
        fail("nonempty output was changed or accepted")

    symlinked = copy_repository(template, temp / "symlinked")
    symlinked_work = symlinked / ".release-work"
    symlinked_work.mkdir()
    target = symlinked / "target"
    target.mkdir()
    symlinked_output = symlinked_work / "evidence"
    symlinked_output.symlink_to(target)
    result = prepare(symlinked, commit, ".release-work/evidence")
    if result.returncode == 0 or result.stdout or not symlinked_output.is_symlink() or list(target.iterdir()):
        fail("symlink output was followed or replaced")

    symlinked_parent = copy_repository(template, temp / "symlinked-parent")
    symlinked_parent_work = symlinked_parent / ".release-work"
    symlinked_parent_work.mkdir()
    parent_target = symlinked_parent / "parent-target"
    parent_target.mkdir()
    (symlinked_parent_work / "linked-parent").symlink_to(parent_target)
    result = prepare(symlinked_parent, commit, ".release-work/linked-parent/evidence")
    if result.returncode == 0 or result.stdout or list(parent_target.iterdir()):
        fail("symlink output parent was followed")

    unsafe_parent = copy_repository(template, temp / "unsafe-parent")
    unsafe_parent_path = unsafe_parent / ".release-work/unsafe"
    unsafe_parent_path.mkdir(parents=True)
    unsafe_parent_path.chmod(0o777)
    unsafe_parent_output = unsafe_parent_path / "evidence"
    expect_rejected(
        prepare(unsafe_parent, commit, ".release-work/unsafe/evidence"),
        unsafe_parent_output,
        "world-writable output parent",
    )

    outside = copy_repository(template, temp / "outside-repo")
    outside_output = temp / "outside-evidence"
    expect_rejected(prepare(outside, commit, os.fspath(outside_output)), outside_output, "out-of-root output")

    unknown_origin = copy_repository(template, temp / "unknown-origin")
    checked(["/usr/bin/git", "remote", "add", "origin", "https://evil.example/UtterInk.git"], unknown_origin)
    unknown_origin_output = unknown_origin / ".release-work/evidence"
    expect_rejected(prepare(unknown_origin, commit, ".release-work/evidence"), unknown_origin_output, "unknown origin")

    approved_origin = copy_repository(template, temp / "approved-origin")
    checked(["/usr/bin/git", "remote", "add", "origin", CANONICAL_ORIGIN], approved_origin)
    approved_origin_output = approved_origin / ".release-work/evidence"
    approved = prepare(approved_origin, commit, ".release-work/evidence", "--expected-origin", CANONICAL_ORIGIN)
    if approved.returncode != 0 or approved.stdout != "NOT_RELEASE_READY\n" or approved.stderr:
        fail(f"exact approved canonical origin failed: {approved.stderr.strip()}")

    def assert_no_initializer_artifacts(repo: Path, label: str) -> None:
        work = repo / ".release-work"
        if not work.exists():
            return
        forbidden = [
            path
            for path in work.rglob("*")
            if path.name == "base-evidence.json"
            or path.name.startswith(".prepare-incomplete-evidence")
        ]
        if forbidden:
            fail(f"{label} left initializer evidence or private artifacts")

    collector_swap = copy_repository(template, temp / "collector-transient-swap")
    collector_swap_output = collector_swap / ".release-work/evidence"

    def swap_collector_and_restore() -> None:
        path = collector_swap / "Scripts/release/collect-evidence.py"
        backup = path.with_name(".collector-held")
        path.rename(backup)
        path.write_text("raise SystemExit('replacement collector executed')\n", encoding="utf-8")
        path.unlink()
        backup.rename(path)

    result = prepare_at_publish_barrier(
        collector_swap,
        commit,
        ".release-work/evidence",
        swap_collector_and_restore,
        phase="collector",
    )
    expect_rejected(result, collector_swap_output, "collector transient swap")
    assert_no_initializer_artifacts(collector_swap, "collector transient swap")

    policy_swap = copy_repository(template, temp / "policy-transient-swap")
    policy_swap_output = policy_swap / ".release-work/evidence"

    def swap_policy_and_restore() -> None:
        path = policy_swap / "docs/release/manual-verification-matrix.md"
        backup = path.with_name(".matrix-held")
        path.rename(backup)
        path.write_text("replacement policy\n", encoding="utf-8")
        path.unlink()
        backup.rename(path)

    result = prepare_at_publish_barrier(
        policy_swap,
        commit,
        ".release-work/evidence",
        swap_policy_and_restore,
        phase="collector",
    )
    expect_rejected(result, policy_swap_output, "policy transient swap")
    assert_no_initializer_artifacts(policy_swap, "policy transient swap")

    io_swap = copy_repository(template, temp / "collector-io-transient-swap")
    io_swap_output = io_swap / ".release-work/evidence"
    external_stage_replacement = temp / "external-stage-replacement"
    external_work_replacement = temp / "external-work-replacement"
    displaced_io_work = temp / "displaced-io-work"

    def swap_bound_io_and_restore() -> None:
        work_path = io_swap / ".release-work"
        stages = [path for path in work_path.iterdir() if path.name.startswith(".prepare-incomplete-evidence.")]
        if len(stages) != 1:
            fail("collector IO swap could not identify the private stage")
        stage_path = stages[0]
        held_stage = work_path / ".held-stage"
        stage_path.rename(held_stage)
        stage_path.mkdir(mode=0o700)
        (stage_path / "sentinel.txt").write_text("stage replacement sentinel\n", encoding="utf-8")
        stage_path.rename(external_stage_replacement)
        held_stage.rename(stage_path)
        work_path.rename(displaced_io_work)
        work_path.mkdir(mode=0o700)
        (work_path / "sentinel.txt").write_text("work replacement sentinel\n", encoding="utf-8")
        work_path.rename(external_work_replacement)
        displaced_io_work.rename(work_path)

    result = prepare_at_publish_barrier(
        io_swap,
        commit,
        ".release-work/evidence",
        swap_bound_io_and_restore,
        phase="collector",
    )
    if result.returncode != 0 or result.stdout != "NOT_RELEASE_READY\n" or result.stderr:
        fail(f"collector bound IO swap was not isolated: {result.stderr.strip()}")
    if (external_stage_replacement / "sentinel.txt").read_text(encoding="utf-8") != "stage replacement sentinel\n":
        fail("collector wrote into the replacement stage")
    if (external_work_replacement / "sentinel.txt").read_text(encoding="utf-8") != "work replacement sentinel\n":
        fail("collector wrote into the replacement work root")
    if list(external_stage_replacement.iterdir()) != [external_stage_replacement / "sentinel.txt"]:
        fail("collector left evidence in the replacement stage")
    if list(external_work_replacement.iterdir()) != [external_work_replacement / "sentinel.txt"]:
        fail("collector left a packet in the replacement work root")
    if sorted(path.name for path in io_swap_output.iterdir()) != ["base-evidence.json"]:
        fail("collector IO swap did not publish the expected base-only output")

    post_dirty = copy_repository(template, temp / "post-publish-dirty")
    post_dirty_output = post_dirty / ".release-work/race/nested/evidence"
    result = prepare_at_publish_barrier(
        post_dirty,
        commit,
        ".release-work/race/nested/evidence",
        lambda: (post_dirty / "README.md").write_text("late dirty\n", encoding="utf-8"),
    )
    expect_rejected(result, post_dirty_output, "post-publish dirty race")
    if os.path.lexists(post_dirty / ".release-work/race"):
        fail("post-publish dirty rollback left newly-created parents")

    post_origin = copy_repository(template, temp / "post-publish-origin")
    post_origin_output = post_origin / ".release-work/race/evidence"
    post_origin_output.mkdir(parents=True, mode=0o700)
    result = prepare_at_publish_barrier(
        post_origin,
        commit,
        ".release-work/race/evidence",
        lambda: checked(["/usr/bin/git", "remote", "add", "origin", CANONICAL_ORIGIN], post_origin),
    )
    if result.returncode == 0 or result.stdout or not result.stderr.startswith("incomplete evidence error: "):
        fail("post-publish origin race unexpectedly passed")
    if not post_origin_output.is_dir() or list(post_origin_output.iterdir()):
        fail("rollback removed or populated a pre-existing empty output")

    post_input = copy_repository(template, temp / "post-publish-input")
    post_input_output = post_input / ".release-work/race/evidence"

    def mutate_hidden_collector() -> None:
        checked(
            ["/usr/bin/git", "update-index", "--assume-unchanged", "--", "Scripts/release/collect-evidence.py"],
            post_input,
        )
        with (post_input / "Scripts/release/collect-evidence.py").open("ab") as stream:
            stream.write(b"\n# late hidden tamper\n")

    result = prepare_at_publish_barrier(
        post_input,
        commit,
        ".release-work/race/evidence",
        mutate_hidden_collector,
    )
    expect_rejected(result, post_input_output, "post-publish controlled-input race")

    post_head = copy_repository(template, temp / "post-publish-head-swap")
    post_head_output = post_head / ".release-work/race/evidence"
    displaced = post_head / ".release-work/race/displaced"
    sentinel = post_head_output / "sentinel.txt"

    def replace_output_and_advance_head() -> None:
        post_head_output.rename(displaced)
        post_head_output.mkdir(mode=0o700)
        sentinel.write_text("external sentinel\n", encoding="utf-8")
        checked(
            ["/usr/bin/git", "commit", "-q", "--allow-empty", "-m", "late head"],
            post_head,
            env={
                "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
                "GIT_AUTHOR_NAME": "UtterInk Fixture",
                "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
                "GIT_COMMITTER_NAME": "UtterInk Fixture",
            },
        )

    result = prepare_at_publish_barrier(
        post_head,
        commit,
        ".release-work/race/evidence",
        replace_output_and_advance_head,
    )
    if result.returncode == 0 or result.stdout or not result.stderr.startswith("incomplete evidence error: "):
        fail("post-publish HEAD race unexpectedly passed")
    if sentinel.read_text(encoding="utf-8") != "external sentinel\n":
        fail("rollback deleted or changed a replacement sentinel")
    if list(displaced.iterdir()):
        fail("rollback left published evidence in the displaced original output inode")

    work_swap = copy_repository(template, temp / "post-publish-work-root-swap")
    work_swap_output = work_swap / ".release-work/evidence"
    displaced_work = work_swap / ".release-work-displaced"
    replacement_sentinel = work_swap / ".release-work/sentinel.txt"

    def replace_work_root() -> None:
        (work_swap / ".release-work").rename(displaced_work)
        (work_swap / ".release-work").mkdir(mode=0o700)
        replacement_sentinel.write_text("replacement work sentinel\n", encoding="utf-8")

    result = prepare_at_publish_barrier(
        work_swap,
        commit,
        ".release-work/evidence",
        replace_work_root,
    )
    if result.returncode == 0 or result.stdout or not result.stderr.startswith("incomplete evidence error: "):
        fail("post-publish work-root swap unexpectedly passed")
    if replacement_sentinel.read_text(encoding="utf-8") != "replacement work sentinel\n":
        fail("work-root rollback changed the replacement sentinel")
    assert_no_initializer_artifacts(displaced_work.parent, "post-publish work-root swap")
    for path in displaced_work.rglob("*"):
        if path.name == "base-evidence.json" or path.name.startswith(".prepare-incomplete-evidence"):
            fail("work-root swap left evidence, stage, or packet in the displaced inode")

    origin_mismatch = copy_repository(template, temp / "origin-mismatch")
    checked(["/usr/bin/git", "remote", "add", "origin", CANONICAL_ORIGIN], origin_mismatch)
    origin_mismatch_output = origin_mismatch / ".release-work/evidence"
    expect_rejected(
        prepare(
            origin_mismatch,
            commit,
            ".release-work/evidence",
            "--expected-origin",
            "https://github.com/different/UtterInk.git",
        ),
        origin_mismatch_output,
        "origin mismatch",
    )

    canary = copy_repository(template, temp / "canary")
    canary_output = canary / ".release-work/evidence"
    expect_rejected(
        prepare(
            canary,
            commit,
            ".release-work/evidence",
            "--expected-origin",
            "https://" + "fixture-user@" + "github.com/example/UtterInk.git",
        ),
        canary_output,
        "origin canary",
    )

    for label, extra in (
        ("status-override", ("--status", "READY")),
        ("fabricated-pass", ("--evidence-status", "pass")),
    ):
        case = copy_repository(template, temp / label)
        output = case / ".release-work/evidence"
        expect_rejected(prepare(case, commit, ".release-work/evidence", *extra), output, label)

print("prepare incomplete evidence tests passed")
