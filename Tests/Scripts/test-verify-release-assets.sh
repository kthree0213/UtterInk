#!/usr/bin/env -S -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u BASH_XTRACEFD -u PS4 /bin/bash

set -euo pipefail
export LC_ALL=C
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PYTHONDONTWRITEBYTECODE=1

ROOT="$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "${BASH_SOURCE[0]}")/../.." && /bin/pwd -P)"

/usr/bin/python3 -I - "$ROOT" <<'PY'
from __future__ import annotations

import binascii
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import zipfile
import zlib

ROOT = Path(sys.argv[1])
ASSEMBLER = ROOT / "Scripts/release/assemble-release-assets.sh"
VERIFIER = ROOT / "Scripts/release/verify-release-assets.sh"
SOURCE_GENERATOR = ROOT / "Scripts/release/create-source-archives.sh"
COLLECTOR = ROOT / "Scripts/release/collect-evidence.py"
NOTES = ROOT / "docs/release/release-notes-0.1.0.md"
EXPECTED_NAMES = {
    "UtterInk-0.1.0-arm64.dmg",
    "UtterInk-0.1.0-source.tar.gz",
    "UtterInk-0.1.0-source.zip",
    "SHA256SUMS",
    "release-notes-0.1.0.md",
}


def fail(message: str) -> None:
    raise AssertionError(message)


for required in (ASSEMBLER, VERIFIER, SOURCE_GENERATOR, COLLECTOR, NOTES):
    if not required.is_file():
        fail(f"missing implementation: {required.relative_to(ROOT)}")


def run(command: list[str], *, cwd: Path, expect: int = 0) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        command,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "HOME": str(cwd / ".home")},
        check=False,
    )
    if (result.returncode == 0) != (expect == 0):
        fail(
            f"unexpected exit {result.returncode} for {' '.join(command)}\n"
            f"stdout={result.stdout!r}\nstderr={result.stderr!r}"
        )
    return result


def git(repo: Path, *arguments: str) -> str:
    result = run(["/usr/bin/git", *arguments], cwd=repo)
    return result.stdout.strip()


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def rewrite_checksums(assets: Path) -> None:
    names = sorted(EXPECTED_NAMES - {"SHA256SUMS"}, key=lambda item: item.encode("utf-8"))
    text = "".join(f"{digest(assets / name)}  {name}\n" for name in names)
    (assets / "SHA256SUMS").write_text(text, encoding="ascii")
    (assets / "SHA256SUMS").chmod(0o644)


def copy_assets(source: Path, destination: Path) -> Path:
    shutil.copytree(source, destination)
    for path in destination.iterdir():
        path.chmod(0o644)
    return destination


def create_canonical_archives(repo: Path, commit: str, sources: Path) -> None:
    prefix = "UtterInk-0.1.0/"
    raw_tar = sources / "raw.tar"
    run(
        ["/usr/bin/git", "archive", "--format=tar", f"--prefix={prefix}", "-o", str(raw_tar), commit],
        cwd=repo,
    )
    files: dict[str, tuple[int, bytes]] = {}
    directories: set[str] = {prefix}
    with tarfile.open(raw_tar, "r:") as archive:
        for member in archive.getmembers():
            relative = member.name[len(prefix):].rstrip("/")
            if not relative:
                continue
            if member.isdir():
                directories.add(prefix + relative + "/")
                continue
            handle = archive.extractfile(member)
            if handle is None:
                fail("fixture git archive contains an unreadable member")
            files[relative] = (0o755 if member.mode & 0o111 else 0o644, handle.read())
            current = Path(relative).parent
            while current != Path("."):
                directories.add(prefix + current.as_posix() + "/")
                current = current.parent

    normalized = sources / "normalized.tar"
    with normalized.open("xb") as output:
        with tarfile.open(fileobj=output, mode="w", format=tarfile.PAX_FORMAT) as archive:
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

    tar_output = sources / "UtterInk-0.1.0-source.tar.gz"
    compressor = zlib.compressobj(level=9, method=zlib.DEFLATED, wbits=-15)
    crc = 0
    size = 0
    with normalized.open("rb") as source, tar_output.open("xb") as destination:
        destination.write(b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff")
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            size = (size + len(chunk)) & 0xFFFFFFFF
            crc = binascii.crc32(chunk, crc) & 0xFFFFFFFF
            destination.write(compressor.compress(chunk))
        destination.write(compressor.flush())
        destination.write(struct.pack("<II", crc, size))

    zip_output = sources / "UtterInk-0.1.0-source.zip"
    with zipfile.ZipFile(zip_output, mode="x", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
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
    raw_tar.unlink()
    normalized.unlink()


def make_fixture(root: Path) -> tuple[Path, str, Path, Path, str]:
    repo = root / "repo"
    (repo / "Scripts/release").mkdir(parents=True)
    (repo / "docs/release").mkdir(parents=True)
    (repo / "Config").mkdir(parents=True)
    (repo / ".home").mkdir(mode=0o700)
    shutil.copy2(ASSEMBLER, repo / "Scripts/release/assemble-release-assets.sh")
    shutil.copy2(VERIFIER, repo / "Scripts/release/verify-release-assets.sh")
    shutil.copy2(NOTES, repo / "docs/release/release-notes-0.1.0.md")
    (repo / "Scripts/release/assemble-release-assets.sh").chmod(0o755)
    (repo / "Scripts/release/verify-release-assets.sh").chmod(0o755)
    (repo / "Config/release-metadata.json").write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "product": "UtterInk",
                "configuration": "Release",
                "dmgFilenameTemplate": "UtterInk-{marketingVersion}-{architecture}.dmg",
                "supportedArchitectures": ["arm64"],
                "releaseTag": "v0.1.0",
            },
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n",
        encoding="utf-8",
    )
    (repo / "Config/Release.xcconfig").write_text(
        "PRODUCT_NAME = UtterInk\nMARKETING_VERSION = 0.1.0\nCURRENT_PROJECT_VERSION = 1\n",
        encoding="utf-8",
    )
    (repo / "README.md").write_text("# fixture source\n", encoding="utf-8")
    git(repo, "init", "-q")
    git(repo, "config", "user.name", "UtterInk fixture")
    git(repo, "config", "user.email", "fixture@example.invalid")
    git(repo, "add", ".")
    git(repo, "commit", "-q", "-m", "fixture")
    commit = git(repo, "rev-parse", "HEAD")
    git(repo, "tag", "v0.1.0", commit)

    sources = root / "sources"
    sources.mkdir(mode=0o700)
    create_canonical_archives(repo, commit, sources)
    for path in sources.iterdir():
        path.chmod(0o644)

    dmg = root / "UtterInk-0.1.0-arm64.dmg"
    dmg.write_bytes(b"fixture final stapled dmg\n" * 128)
    dmg.chmod(0o644)
    return repo, commit, sources, dmg, digest(dmg)


def assemble(repo: Path, commit: str, sources: Path, dmg: Path, dmg_hash: str, output: Path, *, expect: int = 0) -> subprocess.CompletedProcess[str]:
    return run(
        [
            str(repo / "Scripts/release/assemble-release-assets.sh"),
            "--dmg", str(dmg),
            "--source-archives", str(sources),
            "--commit", commit,
            "--expected-final-dmg-sha256", dmg_hash,
            "--output", str(output),
        ],
        cwd=repo,
        expect=expect,
    )


def verify(repo: Path, commit: str, assets: Path, dmg_hash: str, evidence: Path, *, expect: int = 0) -> subprocess.CompletedProcess[str]:
    return run(
        [
            str(repo / "Scripts/release/verify-release-assets.sh"),
            "--assets", str(assets),
            "--commit", commit,
            "--expected-final-dmg-sha256", dmg_hash,
            "--output", str(evidence),
        ],
        cwd=repo,
        expect=expect,
    )


def run_production_pipeline_fixture(root: Path) -> None:
    """Exercise the real source -> assets -> evidence -> collector chain."""
    fixture_root = root / "production-pipeline"
    fixture_root.mkdir(mode=0o700)
    repo = fixture_root / "repo"
    (repo / "Scripts/release").mkdir(parents=True)
    (repo / "docs/release").mkdir(parents=True)
    (repo / "Config").mkdir(parents=True)
    (repo / "Sources").mkdir(parents=True)
    (repo / ".home").mkdir(mode=0o700)
    for source, relative in (
        (SOURCE_GENERATOR, "Scripts/release/create-source-archives.sh"),
        (ASSEMBLER, "Scripts/release/assemble-release-assets.sh"),
        (VERIFIER, "Scripts/release/verify-release-assets.sh"),
        (NOTES, "docs/release/release-notes-0.1.0.md"),
    ):
        destination = repo / relative
        shutil.copy2(source, destination)
        destination.chmod(0o755 if relative.startswith("Scripts/") else 0o644)

    (repo / "Scripts/release/verify-candidate.sh").write_text(
        r'''#!/bin/bash
set -euo pipefail
commit=''
output=''
output_dir_fd=''
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --commit) commit="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --output-dir-fd) output_dir_fd="$2"; shift 2 ;;
    --expected-origin) shift 2 ;;
    *) exit 2 ;;
  esac
done
[[ "$commit" =~ ^[0-9a-f]{40}$ && -n "$output" && "$output_dir_fd" == 10 ]] || exit 2
tree="$(/usr/bin/git rev-parse "$commit^{tree}")"
/usr/bin/python3 -I - "$output_dir_fd" "$commit" "$tree" <<'PY_INNER'
import json
import os
import sys

directory_fd = int(sys.argv[1])
commit, tree = sys.argv[2:]
value = {
    "checks": {},
    "evidenceType": "release-candidate",
    "packageResolution": {},
    "policies": {},
    "product": "UtterInk",
    "release": {},
    "schemaVersion": 1,
    "source": {"clean": True, "commit": commit, "releaseTag": "v0.1.0", "tree": tree},
    "toolchain": {},
}
content = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
descriptor = os.open(
    "candidate.json",
    os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
    0o644,
    dir_fd=directory_fd,
)
try:
    view = memoryview(content)
    while view:
        written = os.write(descriptor, view)
        if written <= 0:
            raise SystemExit(1)
        view = view[written:]
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY_INNER
''',
        encoding="utf-8",
    )
    (repo / "Scripts/release/verify-candidate.sh").chmod(0o755)
    (repo / "Config/release-metadata.json").write_text(
        json.dumps(
            {
                "configuration": "Release",
                "dmgFilenameTemplate": "UtterInk-{marketingVersion}-{architecture}.dmg",
                "product": "UtterInk",
                "releaseTag": "v0.1.0",
                "schemaVersion": 1,
                "supportedArchitectures": ["arm64"],
            },
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n",
        encoding="utf-8",
    )
    (repo / "Config/Release.xcconfig").write_text("MARKETING_VERSION = 0.1.0\n", encoding="utf-8")
    (repo / ".gitignore").write_text(".release-work/\n", encoding="utf-8")
    (repo / "README.md").write_text("# UtterInk production pipeline fixture\n", encoding="utf-8")
    (repo / "Sources/main.swift").write_text('print("UtterInk")\n', encoding="utf-8")

    git(repo, "init", "-q")
    git(repo, "config", "user.name", "UtterInk production fixture")
    git(repo, "config", "user.email", "fixture@example.invalid")
    git(repo, "add", ".")
    git(repo, "commit", "-q", "-m", "production pipeline fixture")
    commit = git(repo, "rev-parse", "HEAD")

    sources = repo / ".release-work/e2e-source"
    generated = run(
        [
            str(repo / "Scripts/release/create-source-archives.sh"),
            "--commit", commit,
            "--output", str(sources),
        ],
        cwd=repo,
    )
    if generated.stdout or generated.stderr:
        fail("successful production source generator must be silent")
    expected_sources = {"UtterInk-0.1.0-source.tar.gz", "UtterInk-0.1.0-source.zip"}
    if {item.name for item in sources.iterdir()} != expected_sources:
        fail("production source generator emitted an unexpected inventory")
    for item in sources.iterdir():
        if item.is_symlink() or not item.is_file() or item.stat().st_nlink != 1 or stat.S_IMODE(item.stat().st_mode) != 0o644:
            fail(f"production source generator emitted an unsafe archive: {item.name}")
    if git(repo, "rev-parse", "v0.1.0^{commit}") != commit or git(repo, "cat-file", "-t", "refs/tags/v0.1.0") != "commit":
        fail("production source generator did not create the exact lightweight release tag")
    if git(repo, "status", "--porcelain=v1", "--untracked-files=all"):
        fail("production source generator left the fixture checkout dirty")

    dmg = fixture_root / "UtterInk-0.1.0-arm64.dmg"
    dmg.write_bytes(b"production pipeline fixture dmg\n" * 128)
    dmg.chmod(0o644)
    dmg_hash = digest(dmg)
    asset_parent = fixture_root / "asset-output"
    asset_parent.mkdir(mode=0o700)
    assets = asset_parent / "assets"
    assembled = assemble(repo, commit, sources, dmg, dmg_hash, assets)
    if assembled.stdout or assembled.stderr or {item.name for item in assets.iterdir()} != EXPECTED_NAMES:
        fail("production assembler pipeline output drifted")

    evidence_parent = fixture_root / "evidence-output"
    evidence_parent.mkdir(mode=0o700)
    evidence = evidence_parent / "release-assets-evidence.json"
    verified = verify(repo, commit, assets, dmg_hash, evidence)
    if verified.stdout or verified.stderr or stat.S_IMODE(evidence.stat().st_mode) != 0o600:
        fail("production verifier pipeline output drifted")

    collector_inputs = fixture_root / "collector-inputs"
    collector_inputs.mkdir(mode=0o700)
    copied_evidence = collector_inputs / "release-assets-evidence.json"
    shutil.copy2(evidence, copied_evidence)
    copied_evidence.chmod(0o600)
    collector_output = fixture_root / "collector-output"
    collector_output.mkdir(mode=0o700)
    packet = collector_output / "release-evidence-packet.md"
    collected = run(
        [
            "/usr/bin/python3", "-I", str(COLLECTOR),
            "--inputs", str(collector_inputs),
            "--output", str(packet),
            "--expect-status", "NOT_RELEASE_READY",
        ],
        cwd=ROOT,
    )
    packet_text = packet.read_text(encoding="utf-8")
    if collected.stdout != "NOT_RELEASE_READY\n" or collected.stderr:
        fail("collector did not accept the production release-assets evidence schema")
    for required_text in (
        "Computed status: NOT_RELEASE_READY",
        "| `release-assets-inventory` | `pass` |",
        "`release-assets-evidence.json`",
    ):
        if required_text not in packet_text:
            fail(f"collector packet omitted production pipeline result: {required_text}")


with tempfile.TemporaryDirectory(prefix="utterink-release-assets.", dir="/private/tmp") as temporary:
    base = Path(temporary)
    repo, commit, sources, dmg, dmg_hash = make_fixture(base)
    assets = base / "assets"
    assembled = assemble(repo, commit, sources, dmg, dmg_hash, assets)
    if assembled.stdout or assembled.stderr:
        fail("successful assembler must be silent")
    if {item.name for item in assets.iterdir()} != EXPECTED_NAMES:
        fail("assembler did not create the exact five-file inventory")
    for item in assets.iterdir():
        mode = stat.S_IMODE(item.lstat().st_mode)
        if not item.is_file() or item.is_symlink() or item.stat().st_nlink != 1 or mode != 0o644:
            fail(f"unsafe assembled asset: {item.name}")
    checksum_lines = (assets / "SHA256SUMS").read_text(encoding="ascii").splitlines()
    checksum_names = sorted(EXPECTED_NAMES - {"SHA256SUMS"}, key=lambda item: item.encode("utf-8"))
    if [line[66:] for line in checksum_lines] != checksum_names:
        fail("SHA256SUMS is not exact, sorted, or two-space delimited")
    if any(not re.fullmatch(r"[0-9a-f]{64}  [A-Za-z0-9._-]+", line) for line in checksum_lines):
        fail("SHA256SUMS format is not canonical")

    evidence = base / "evidence/release-assets-evidence.json"
    evidence.parent.mkdir(mode=0o700)
    verified = verify(repo, commit, assets, dmg_hash, evidence)
    if verified.stdout or verified.stderr:
        fail("successful verifier must be silent")
    if stat.S_IMODE(evidence.stat().st_mode) != 0o600 or evidence.is_symlink() or evidence.stat().st_nlink != 1:
        fail("evidence output mode/type is unsafe")
    raw = evidence.read_bytes()
    value = json.loads(raw)
    if raw != (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8"):
        fail("evidence is not canonical JSON")
    if set(value) != {"assets", "candidateCommit", "evidenceType", "finalDMGSHA256", "product", "releaseTag", "schemaVersion", "status"}:
        fail("evidence top-level keys drifted from collector contract")
    if value != {
        "assets": sorted(
            [
                {"filename": name, "sha256": digest(assets / name), "sizeBytes": (assets / name).stat().st_size}
                for name in EXPECTED_NAMES
            ],
            key=lambda item: item["filename"].encode("utf-8"),
        ),
        "candidateCommit": commit,
        "evidenceType": "release-assets",
        "finalDMGSHA256": dmg_hash,
        "product": "UtterInk",
        "releaseTag": "v0.1.0",
        "schemaVersion": 1,
        "status": "valid",
    }:
        fail("evidence values drifted from collector contract")

    # Index flags must not hide execution-script changes from commit binding.
    hidden_cases = (
        (
            "Scripts/release/assemble-release-assets.sh",
            "--skip-worktree",
            lambda data: data + b"\n# harmless hidden tamper\n",
            "hidden-skip-assets",
        ),
        (
            "Scripts/release/verify-release-assets.sh",
            "--assume-unchanged",
            lambda data: data.replace(
                b'DMG_NAME = "UtterInk-0.1.0-arm64.dmg"',
                b'DMG_NAME = "Altered-0.1.0-arm64.dmg"',
                1,
            ),
            "hidden-assume-evidence",
        ),
    )
    for relative_script, flag, mutate_script, case_name in hidden_cases:
        script_path = repo / relative_script
        original = script_path.read_bytes()
        clear_flag = "--no-skip-worktree" if flag == "--skip-worktree" else "--no-assume-unchanged"
        git(repo, "update-index", flag, "--", relative_script)
        changed = mutate_script(original)
        if changed == original:
            fail(f"hidden tamper fixture did not change {relative_script}")
        script_path.write_bytes(changed)
        script_path.chmod(0o755)
        if relative_script.endswith("assemble-release-assets.sh"):
            hidden_output = base / case_name
            assemble(repo, commit, sources, dmg, dmg_hash, hidden_output, expect=1)
            if hidden_output.exists():
                fail("hidden assembler tamper created public assets")
        else:
            hidden_parent = base / case_name
            hidden_parent.mkdir(mode=0o700)
            hidden_output = hidden_parent / "release-assets-evidence.json"
            verify(repo, commit, assets, dmg_hash, hidden_output, expect=1)
            if hidden_output.exists():
                fail("hidden verifier tamper created evidence")
        git(repo, "update-index", clear_flag, "--", relative_script)
        script_path.write_bytes(original)
        script_path.chmod(0o755)
        if git(repo, "status", "--porcelain=v1", "--untracked-files=all"):
            fail(f"fixture did not return clean after hidden tamper: {relative_script}")

    # Repo-internal evidence may exist only below the real root .release-work.
    unsafe_evidence_outputs = [
        repo / "release-assets-evidence.json",
        repo / ".git/release-assets-evidence.json",
        repo / "foo/.release-work/release-assets-evidence.json",
    ]
    unsafe_evidence_outputs[-1].parent.mkdir(parents=True, exist_ok=True)
    for unsafe_output in unsafe_evidence_outputs:
        verify(repo, commit, assets, dmg_hash, unsafe_output, expect=1)
        if unsafe_output.exists():
            fail(f"unsafe repo-internal evidence output was created: {unsafe_output}")

    # Assembler input/path/type/hash/no-overwrite failures.
    assemble(repo, commit, sources, dmg, dmg_hash, assets, expect=1)
    assemble(repo, "0" * 40, sources, dmg, dmg_hash, base / "bad-commit-assets", expect=1)
    assemble(repo, commit, sources, dmg, "0" * 64, base / "bad-hash-assets", expect=1)
    relative = run(
        [
            str(repo / "Scripts/release/assemble-release-assets.sh"), "--dmg", dmg.name,
            "--source-archives", str(sources), "--commit", commit,
            "--expected-final-dmg-sha256", dmg_hash, "--output", str(base / "relative-assets"),
        ], cwd=repo, expect=1,
    )
    if "invalid-arguments" not in relative.stderr:
        fail("relative input path did not produce a stable failure")
    dmg_link = base / "dmg-link.dmg"
    dmg_link.symlink_to(dmg)
    assemble(repo, commit, sources, dmg_link, dmg_hash, base / "symlink-dmg-assets", expect=1)
    dmg_hard = base / "dmg-hard.dmg"
    os.link(dmg, dmg_hard)
    assemble(repo, commit, sources, dmg_hard, dmg_hash, base / "hardlink-dmg-assets", expect=1)
    dmg_hard.unlink()
    sources_link = base / "sources-link"
    sources_link.symlink_to(sources, target_is_directory=True)
    assemble(repo, commit, sources_link, dmg, dmg_hash, base / "symlink-source-assets", expect=1)
    hard_sources = base / "hard-sources"
    shutil.copytree(sources, hard_sources)
    outside = base / "outside-source.tar.gz"
    os.link(hard_sources / "UtterInk-0.1.0-source.tar.gz", outside)
    assemble(repo, commit, hard_sources, dmg, dmg_hash, base / "hardlink-source-assets", expect=1)
    nested_release_work = repo / "foo/.release-work"
    nested_release_work.mkdir(parents=True, exist_ok=True)
    assemble(
        repo,
        commit,
        sources,
        dmg,
        dmg_hash,
        nested_release_work / "must-not-be-accepted",
        expect=1,
    )

    # Observe the private staging tree, then force late failures. No fixed
    # public directory or private staging residue may survive.
    race_input = base / "race-input"
    race_input.mkdir(mode=0o700)
    race_dmg = race_input / "UtterInk-0.1.0-arm64.dmg"
    with race_dmg.open("wb") as handle:
        block = b"r" * (1024 * 1024)
        for _ in range(128):
            handle.write(block)
    race_dmg.chmod(0o644)
    race_hash = digest(race_dmg)

    def start_assembler_race(label: str) -> tuple[subprocess.Popen[str], Path, Path]:
        parent = base / label
        parent.mkdir(mode=0o700)
        target = parent / "assets"
        command = [
            str(repo / "Scripts/release/assemble-release-assets.sh"),
            "--dmg", str(race_dmg),
            "--source-archives", str(sources),
            "--commit", commit,
            "--expected-final-dmg-sha256", race_hash,
            "--output", str(target),
        ]
        process = subprocess.Popen(
            command,
            cwd=repo,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "HOME": str(repo / ".home")},
        )
        return process, parent, target

    def wait_for_complete_staging(process: subprocess.Popen[str], parent: Path) -> Path:
        deadline = time.monotonic() + 30
        while process.poll() is None and time.monotonic() < deadline:
            candidates = list(parent.glob(".assemble-release-assets.*.tmp"))
            if len(candidates) == 1 and (candidates[0] / "SHA256SUMS").is_file():
                staging_metadata = candidates[0].lstat()
                if (
                    not stat.S_ISDIR(staging_metadata.st_mode)
                    or candidates[0].is_symlink()
                    or stat.S_IMODE(staging_metadata.st_mode) != 0o700
                ):
                    fail("assembler private staging directory is not mode 0700")
                return candidates[0]
            time.sleep(0.0005)
        stdout, stderr = process.communicate(timeout=5)
        fail(f"did not observe complete private staging: exit={process.returncode}, stdout={stdout!r}, stderr={stderr!r}")

    def arm_final_barrier(label: str) -> tuple[Path, Path]:
        pause = repo / ".git" / f"release-assets-test-{label}.pause"
        ready = repo / ".git" / f"release-assets-test-{label}.ready"
        if pause.exists() or ready.exists():
            fail(f"stale final-check barrier for {label}")
        pause.write_bytes(b"pause\n")
        pause.chmod(0o600)
        return pause, ready

    def wait_for_final_barrier(
        process: subprocess.Popen[str], ready: Path, label: str
    ) -> None:
        deadline = time.monotonic() + 30
        while process.poll() is None and time.monotonic() < deadline:
            if ready.exists() and ready.read_bytes() == b"ready\n":
                return
            time.sleep(0.0005)
        stdout, stderr = process.communicate(timeout=5)
        fail(f"did not observe final-check barrier for {label}: exit={process.returncode}, stdout={stdout!r}, stderr={stderr!r}")

    def assert_failed_without_assembly(
        process: subprocess.Popen[str],
        parent: Path,
        target: Path,
        *additional_parents: Path,
    ) -> None:
        stdout, stderr = process.communicate(timeout=30)
        if process.returncode == 0 or target.exists():
            fail(f"late assembler failure was accepted: stdout={stdout!r}, stderr={stderr!r}")
        for checked_parent in (parent, *additional_parents):
            if checked_parent.exists() and list(checked_parent.glob(".assemble-release-assets.*.tmp")):
                fail(f"private staging residue survived under {checked_parent}")

    process, race_parent, race_target = start_assembler_race("late-input-race")
    wait_for_complete_staging(process, race_parent)
    with race_dmg.open("r+b", buffering=0) as handle:
        handle.seek(64 * 1024 * 1024)
        handle.write(b"x")
    assert_failed_without_assembly(process, race_parent, race_target)
    with race_dmg.open("r+b", buffering=0) as handle:
        handle.seek(64 * 1024 * 1024)
        handle.write(b"r")

    process, stage_tamper_parent, stage_tamper_target = start_assembler_race("stage-tamper-race")
    staged_directory = wait_for_complete_staging(process, stage_tamper_parent)
    staged_dmg = staged_directory / "UtterInk-0.1.0-arm64.dmg"
    with staged_dmg.open("r+b", buffering=0) as handle:
        handle.seek(64 * 1024 * 1024)
        handle.write(b"x")
    staged_dmg.chmod(0o600)
    assert_failed_without_assembly(process, stage_tamper_parent, stage_tamper_target)

    process, no_replace_parent, no_replace_target = start_assembler_race("late-target-race")
    wait_for_complete_staging(process, no_replace_parent)
    no_replace_target.mkdir(mode=0o700)
    target_before = no_replace_target.lstat()
    stdout, stderr = process.communicate(timeout=30)
    target_after = no_replace_target.lstat()
    if (
        process.returncode == 0
        or (target_before.st_dev, target_before.st_ino) != (target_after.st_dev, target_after.st_ino)
        or not no_replace_target.is_dir()
        or list(no_replace_target.iterdir())
    ):
        fail(f"late no-replace target was overwritten: stdout={stdout!r}, stderr={stderr!r}")
    if list(no_replace_parent.glob(".assemble-release-assets.*.tmp")):
        fail("private staging residue survived a late no-replace failure")
    no_replace_target.rmdir()

    process, delete_parent, delete_target = start_assembler_race("tag-delete-race")
    wait_for_complete_staging(process, delete_parent)
    git(repo, "update-ref", "-d", "refs/tags/v0.1.0")
    assert_failed_without_assembly(process, delete_parent, delete_target)
    git(repo, "update-ref", "refs/tags/v0.1.0", commit)

    tree = git(repo, "rev-parse", f"{commit}^{{tree}}")
    alternate_commit = git(repo, "commit-tree", tree, "-p", commit, "-m", "alternate fixture commit")
    process, move_parent, move_target = start_assembler_race("tag-move-race")
    wait_for_complete_staging(process, move_parent)
    git(repo, "update-ref", "refs/tags/v0.1.0", alternate_commit, commit)
    assert_failed_without_assembly(process, move_parent, move_target)
    git(repo, "update-ref", "refs/tags/v0.1.0", commit, alternate_commit)

    process, rebind_parent, rebind_target = start_assembler_race("parent-rebind-race")
    wait_for_complete_staging(process, rebind_parent)
    moved_parent = base / "parent-rebind-race-moved"
    rebind_parent.rename(moved_parent)
    rebind_parent.mkdir(mode=0o700)
    assert_failed_without_assembly(process, rebind_parent, rebind_target, moved_parent)
    if (moved_parent / "assets").exists():
        fail("parent rebind race published into the retained parent fd")

    assembler_pause, assembler_ready = arm_final_barrier("assembler-final")
    process, swap_parent, swap_target = start_assembler_race("published-name-swap-race")
    wait_for_final_barrier(process, assembler_ready, "assembler published name swap")
    moved_output = swap_parent / "moved-assets"
    swap_target.rename(moved_output)
    swap_target.mkdir(mode=0o700)
    replacement_sentinel = swap_target / "sentinel.txt"
    replacement_sentinel.write_text("replacement must remain untouched\n", encoding="utf-8")
    replacement_sentinel.chmod(0o600)
    sentinel_before = replacement_sentinel.lstat()
    assembler_pause.unlink()
    stdout, stderr = process.communicate(timeout=30)
    sentinel_after = replacement_sentinel.lstat()
    if (
        process.returncode == 0
        or moved_output.exists()
        or replacement_sentinel.read_text(encoding="utf-8") != "replacement must remain untouched\n"
        or (sentinel_before.st_dev, sentinel_before.st_ino) != (sentinel_after.st_dev, sentinel_after.st_ino)
    ):
        fail(f"published output name swap was accepted or rollback was unsafe: stdout={stdout!r}, stderr={stderr!r}")
    if list(swap_parent.glob(".assemble-release-assets.*.tmp")):
        fail("published output name swap left private staging residue")
    replacement_sentinel.unlink()
    swap_target.rmdir()

    assembler_pause, assembler_ready = arm_final_barrier("assembler-final")
    process, final_parent, final_target = start_assembler_race("published-parent-rebind-final-race")
    wait_for_final_barrier(process, assembler_ready, "assembler final parent rebind")
    final_moved_parent = base / "published-parent-rebind-final-race-moved"
    final_parent.rename(final_moved_parent)
    final_parent.mkdir(mode=0o700)
    final_parent_sentinel = final_parent / "replacement-sentinel.txt"
    final_parent_sentinel.write_text("replacement parent must remain untouched\n", encoding="utf-8")
    final_parent_sentinel.chmod(0o600)
    final_parent_sentinel_before = final_parent_sentinel.lstat()
    assembler_pause.unlink()
    stdout, stderr = process.communicate(timeout=30)
    final_parent_sentinel_after = final_parent_sentinel.lstat()
    if (
        process.returncode == 0
        or (final_moved_parent / "assets").exists()
        or (final_parent / "assets").exists()
        or final_parent_sentinel.read_text(encoding="utf-8") != "replacement parent must remain untouched\n"
        or (final_parent_sentinel_before.st_dev, final_parent_sentinel_before.st_ino)
        != (final_parent_sentinel_after.st_dev, final_parent_sentinel_after.st_ino)
    ):
        fail(f"assembler final parent rebind was accepted or rollback was unsafe: stdout={stdout!r}, stderr={stderr!r}")
    for checked_parent in (final_parent, final_moved_parent):
        if list(checked_parent.glob(".assemble-release-assets.*.tmp")):
            fail(f"assembler final parent rebind left staging residue under {checked_parent}")
    final_parent_sentinel.unlink()
    final_parent.rmdir()
    final_moved_parent.rmdir()

    assembler_pause, assembler_ready = arm_final_barrier("assembler-final")
    process, inplace_parent, inplace_target = start_assembler_race("published-inplace-tamper-race")
    wait_for_final_barrier(process, assembler_ready, "assembler published in-place tamper")
    published_dmg = inplace_target / "UtterInk-0.1.0-arm64.dmg"
    with published_dmg.open("r+b", buffering=0) as handle:
        handle.seek(64 * 1024 * 1024)
        handle.write(b"x")
    assembler_pause.unlink()
    assert_failed_without_assembly(process, inplace_parent, inplace_target)

    # Verifier exact-inventory, checksum, note, archive, type, path and output failures.
    extra = copy_assets(assets, base / "extra-assets")
    (extra / "unexpected.txt").write_text("no\n", encoding="utf-8")
    verify(repo, commit, extra, dmg_hash, base / "extra-evidence.json", expect=1)

    malformed = copy_assets(assets, base / "malformed-sums-assets")
    (malformed / "SHA256SUMS").write_text("0" * 64 + " " + "UtterInk-0.1.0-arm64.dmg\n", encoding="ascii")
    verify(repo, commit, malformed, dmg_hash, base / "malformed-evidence.json", expect=1)

    wrong_sum = copy_assets(assets, base / "wrong-sum-assets")
    lines = (wrong_sum / "SHA256SUMS").read_text(encoding="ascii").splitlines()
    lines[0] = "0" * 64 + lines[0][64:]
    (wrong_sum / "SHA256SUMS").write_text("\n".join(lines) + "\n", encoding="ascii")
    verify(repo, commit, wrong_sum, dmg_hash, base / "wrong-sum-evidence.json", expect=1)

    unsorted_sum = copy_assets(assets, base / "unsorted-sum-assets")
    lines = (unsorted_sum / "SHA256SUMS").read_text(encoding="ascii").splitlines()
    (unsorted_sum / "SHA256SUMS").write_text("\n".join(reversed(lines)) + "\n", encoding="ascii")
    verify(repo, commit, unsorted_sum, dmg_hash, base / "unsorted-sum-evidence.json", expect=1)

    extra_sum = copy_assets(assets, base / "extra-sum-assets")
    with (extra_sum / "SHA256SUMS").open("a", encoding="ascii") as handle:
        handle.write("0" * 64 + "  unexpected.txt\n")
    verify(repo, commit, extra_sum, dmg_hash, base / "extra-sum-evidence.json", expect=1)

    changed_notes = copy_assets(assets, base / "changed-notes-assets")
    (changed_notes / "release-notes-0.1.0.md").write_text("# altered notes\n", encoding="utf-8")
    rewrite_checksums(changed_notes)
    verify(repo, commit, changed_notes, dmg_hash, base / "changed-notes-evidence.json", expect=1)

    gzip_metadata = copy_assets(assets, base / "gzip-metadata-assets")
    with (gzip_metadata / "UtterInk-0.1.0-source.tar.gz").open("r+b") as handle:
        handle.seek(9)
        handle.write(b"\x03")
    rewrite_checksums(gzip_metadata)
    verify(repo, commit, gzip_metadata, dmg_hash, base / "gzip-metadata-evidence.json", expect=1)

    zip_metadata = copy_assets(assets, base / "zip-metadata-assets")
    zip_path = zip_metadata / "UtterInk-0.1.0-source.zip"
    rewritten_zip = zip_metadata / "rewritten.zip"
    with zipfile.ZipFile(zip_path, "r") as source, zipfile.ZipFile(
        rewritten_zip, "x", compression=zipfile.ZIP_DEFLATED, compresslevel=9
    ) as destination:
        for source_info in source.infolist():
            info = zipfile.ZipInfo(source_info.filename, date_time=(1981, 1, 1, 0, 0, 0))
            info.create_system = source_info.create_system
            info.compress_type = source_info.compress_type
            info.external_attr = source_info.external_attr
            info.flag_bits = source_info.flag_bits
            destination.writestr(
                info,
                source.read(source_info),
                compress_type=source_info.compress_type,
                compresslevel=9,
            )
    rewritten_zip.chmod(0o644)
    zip_path.unlink()
    rewritten_zip.rename(zip_path)
    rewrite_checksums(zip_metadata)
    verify(repo, commit, zip_metadata, dmg_hash, base / "zip-metadata-evidence.json", expect=1)

    traversal = copy_assets(assets, base / "traversal-assets")
    bad_tar = traversal / "UtterInk-0.1.0-source.tar.gz"
    with tarfile.open(bad_tar, "w:gz") as archive:
        entry = tarfile.TarInfo("../escape")
        entry.size = 0
        archive.addfile(entry)
    bad_tar.chmod(0o644)
    rewrite_checksums(traversal)
    verify(repo, commit, traversal, dmg_hash, base / "traversal-evidence.json", expect=1)

    hard_member = copy_assets(assets, base / "hard-member-assets")
    bad_hard_tar = hard_member / "UtterInk-0.1.0-source.tar.gz"
    with tarfile.open(bad_hard_tar, "w:gz") as archive:
        directory = tarfile.TarInfo("UtterInk-0.1.0/")
        directory.type = tarfile.DIRTYPE
        archive.addfile(directory)
        entry = tarfile.TarInfo("UtterInk-0.1.0/hard")
        entry.type = tarfile.LNKTYPE
        entry.linkname = "UtterInk-0.1.0/README.md"
        archive.addfile(entry)
    bad_hard_tar.chmod(0o644)
    rewrite_checksums(hard_member)
    verify(repo, commit, hard_member, dmg_hash, base / "hard-member-evidence.json", expect=1)

    stale = copy_assets(assets, base / "stale-source-assets")
    git(repo, "tag", "-d", "v0.1.0")
    (repo / "README.md").write_text("# later fixture source\n", encoding="utf-8")
    git(repo, "add", "README.md")
    git(repo, "commit", "-q", "-m", "later fixture")
    later_commit = git(repo, "rev-parse", "HEAD")
    git(repo, "tag", "v0.1.0", later_commit)
    verify(repo, later_commit, stale, dmg_hash, base / "stale-evidence.json", expect=1)
    git(repo, "tag", "-d", "v0.1.0")
    git(repo, "tag", "v0.1.0", commit)
    git(repo, "reset", "--hard", "-q", commit)

    asset_link = copy_assets(assets, base / "asset-link-assets")
    (asset_link / "UtterInk-0.1.0-arm64.dmg").unlink()
    (asset_link / "UtterInk-0.1.0-arm64.dmg").symlink_to(assets / "UtterInk-0.1.0-arm64.dmg")
    verify(repo, commit, asset_link, dmg_hash, base / "asset-link-evidence.json", expect=1)

    asset_hard = copy_assets(assets, base / "asset-hard-assets")
    hard_target = base / "hard-target.zip"
    os.link(asset_hard / "UtterInk-0.1.0-source.zip", hard_target)
    verify(repo, commit, asset_hard, dmg_hash, base / "asset-hard-evidence.json", expect=1)

    existing = base / "existing-evidence.json"
    existing.write_text("keep\n", encoding="utf-8")
    verify(repo, commit, assets, dmg_hash, existing, expect=1)
    if existing.read_text(encoding="utf-8") != "keep\n":
        fail("verifier overwrote existing evidence")
    evidence_link = base / "evidence-link.json"
    evidence_link.symlink_to(existing)
    verify(repo, commit, assets, dmg_hash, evidence_link, expect=1)

    # Mutate an already-open file after evidence appears but during the required
    # post-publication re-hash. The verifier must remove its just-written result.
    write_race_assets = copy_assets(assets, base / "write-race-assets")
    race_asset_dmg = write_race_assets / "UtterInk-0.1.0-arm64.dmg"
    race_asset_dmg.write_bytes(b"w" * (64 * 1024 * 1024))
    race_asset_dmg.chmod(0o644)
    write_race_hash = digest(race_asset_dmg)
    rewrite_checksums(write_race_assets)
    write_race_parent = base / "write-race-evidence"
    write_race_parent.mkdir(mode=0o700)
    write_race_evidence = write_race_parent / "release-assets-evidence.json"
    command = [
        str(repo / "Scripts/release/verify-release-assets.sh"),
        "--assets", str(write_race_assets),
        "--commit", commit,
        "--expected-final-dmg-sha256", write_race_hash,
        "--output", str(write_race_evidence),
    ]
    process = subprocess.Popen(
        command,
        cwd=repo,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "HOME": str(repo / ".home")},
    )
    deadline = time.monotonic() + 15
    while process.poll() is None and not write_race_evidence.exists() and time.monotonic() < deadline:
        time.sleep(0.0005)
    if not write_race_evidence.exists():
        stdout, stderr = process.communicate(timeout=5)
        fail(f"did not observe atomic evidence window: exit={process.returncode}, stdout={stdout!r}, stderr={stderr!r}")
    with race_asset_dmg.open("r+b", buffering=0) as handle:
        handle.seek(32 * 1024 * 1024)
        handle.write(b"x")
    stdout, stderr = process.communicate(timeout=15)
    if process.returncode == 0 or write_race_evidence.exists():
        fail(f"write-window mutation was accepted: stdout={stdout!r}, stderr={stderr!r}")
    with race_asset_dmg.open("r+b", buffering=0) as handle:
        handle.seek(32 * 1024 * 1024)
        handle.write(b"w")

    def start_verifier_publish_race(label: str) -> tuple[subprocess.Popen[str], Path]:
        evidence_parent = base / label
        evidence_parent.mkdir(mode=0o700)
        evidence_path = evidence_parent / "release-assets-evidence.json"
        race_command = [
            str(repo / "Scripts/release/verify-release-assets.sh"),
            "--assets", str(write_race_assets),
            "--commit", commit,
            "--expected-final-dmg-sha256", write_race_hash,
            "--output", str(evidence_path),
        ]
        race_process = subprocess.Popen(
            race_command,
            cwd=repo,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "HOME": str(repo / ".home")},
        )
        deadline = time.monotonic() + 15
        while race_process.poll() is None and not evidence_path.exists() and time.monotonic() < deadline:
            time.sleep(0.0005)
        if not evidence_path.exists():
            race_stdout, race_stderr = race_process.communicate(timeout=5)
            fail(
                f"did not observe candidate-state evidence window for {label}: "
                f"exit={race_process.returncode}, stdout={race_stdout!r}, stderr={race_stderr!r}"
            )
        return race_process, evidence_path

    verifier_pause, verifier_ready = arm_final_barrier("verifier-final")
    process, final_swap_evidence = start_verifier_publish_race("verifier-final-name-swap-race")
    wait_for_final_barrier(process, verifier_ready, "verifier final evidence name swap")
    moved_final_evidence = final_swap_evidence.parent / "moved-release-assets-evidence.json"
    final_swap_evidence.rename(moved_final_evidence)
    final_swap_evidence.write_text("replacement evidence must remain untouched\n", encoding="utf-8")
    final_swap_evidence.chmod(0o600)
    replacement_before = final_swap_evidence.lstat()
    verifier_pause.unlink()
    stdout, stderr = process.communicate(timeout=30)
    replacement_after = final_swap_evidence.lstat()
    if (
        process.returncode == 0
        or moved_final_evidence.exists()
        or final_swap_evidence.read_text(encoding="utf-8") != "replacement evidence must remain untouched\n"
        or (replacement_before.st_dev, replacement_before.st_ino)
        != (replacement_after.st_dev, replacement_after.st_ino)
    ):
        fail(f"final evidence name swap was accepted or rollback was unsafe: stdout={stdout!r}, stderr={stderr!r}")
    if list(final_swap_evidence.parent.glob(".release-assets-evidence.*.tmp")):
        fail("final evidence name swap left temporary residue")
    final_swap_evidence.unlink()

    def rebind_evidence_parent(evidence_path: Path) -> tuple[Path, Path, Path, tuple[int, int]]:
        original_parent = evidence_path.parent
        moved_parent = base / f"{original_parent.name}-moved"
        original_parent.rename(moved_parent)
        moved_evidence = moved_parent / evidence_path.name
        if not moved_evidence.is_file():
            fail("evidence disappeared before the parent-rebind test mutation")
        original_parent.mkdir(mode=0o700)
        sentinel = original_parent / "replacement-sentinel.txt"
        sentinel.write_text("replacement parent must remain untouched\n", encoding="utf-8")
        sentinel.chmod(0o600)
        metadata = sentinel.lstat()
        return moved_parent, moved_evidence, sentinel, (metadata.st_dev, metadata.st_ino)

    def assert_rebound_evidence_rollback(
        race_process: subprocess.Popen[str],
        evidence_path: Path,
        rebound: tuple[Path, Path, Path, tuple[int, int]],
        label: str,
    ) -> None:
        moved_parent, moved_evidence, sentinel, sentinel_identity = rebound
        race_stdout, race_stderr = race_process.communicate(timeout=30)
        sentinel_after = sentinel.lstat()
        if (
            race_process.returncode == 0
            or evidence_path.exists()
            or moved_evidence.exists()
            or sentinel.read_text(encoding="utf-8") != "replacement parent must remain untouched\n"
            or (sentinel_after.st_dev, sentinel_after.st_ino) != sentinel_identity
        ):
            fail(
                f"rebound evidence parent race was accepted or rolled back unsafely for {label}: "
                f"stdout={race_stdout!r}, stderr={race_stderr!r}"
            )
        for checked_parent in (evidence_path.parent, moved_parent):
            if list(checked_parent.glob(".release-assets-evidence.*.tmp")):
                fail(f"temporary evidence residue survived under {checked_parent}")
        sentinel.unlink()
        evidence_path.parent.rmdir()
        moved_parent.rmdir()

    verifier_pause, verifier_ready = arm_final_barrier("verifier-final")
    process, final_parent_evidence = start_verifier_publish_race("verifier-final-parent-rebind-race")
    wait_for_final_barrier(process, verifier_ready, "verifier final evidence parent rebind")
    final_parent_rebound = rebind_evidence_parent(final_parent_evidence)
    verifier_pause.unlink()
    assert_rebound_evidence_rollback(
        process,
        final_parent_evidence,
        final_parent_rebound,
        "final evidence parent rebind",
    )

    process, asset_rebind_evidence = start_verifier_publish_race("asset-parent-rebind-evidence-race")
    asset_rebound = rebind_evidence_parent(asset_rebind_evidence)
    with race_asset_dmg.open("r+b", buffering=0) as handle:
        handle.seek(32 * 1024 * 1024)
        handle.write(b"x")
    try:
        assert_rebound_evidence_rollback(
            process, asset_rebind_evidence, asset_rebound, "late asset mutation"
        )
    finally:
        with race_asset_dmg.open("r+b", buffering=0) as handle:
            handle.seek(32 * 1024 * 1024)
            handle.write(b"w")

    process, head_race_evidence = start_verifier_publish_race("head-parent-rebind-evidence-race")
    head_rebound = rebind_evidence_parent(head_race_evidence)
    git(repo, "update-ref", "HEAD", alternate_commit, commit)
    try:
        assert_rebound_evidence_rollback(
            process, head_race_evidence, head_rebound, "HEAD advance"
        )
    finally:
        git(repo, "update-ref", "HEAD", commit, alternate_commit)

    process, tag_race_evidence = start_verifier_publish_race("tag-parent-rebind-evidence-race")
    tag_rebound = rebind_evidence_parent(tag_race_evidence)
    git(repo, "update-ref", "refs/tags/v0.1.0", alternate_commit, commit)
    try:
        assert_rebound_evidence_rollback(
            process, tag_race_evidence, tag_rebound, "tag move"
        )
    finally:
        git(repo, "update-ref", "refs/tags/v0.1.0", commit, alternate_commit)

    run_production_pipeline_fixture(base)

    # Production scripts must contain no publication or network capability.
    forbidden = re.compile(
        r"(?im)(?:^|[;&|()\s])(?:gh|curl|wget)(?:\s|$)|"
        r"git\s+push|api[.]github[.]com|release\s+create|"
        r"repository[\s_-]*visibility|send[\s_-]*(?:mail|message)|"
        r"upload[\s_-]*(?:asset|file|binary|release)"
    )
    for script in (ASSEMBLER, VERIFIER):
        text = script.read_text(encoding="utf-8")
        if forbidden.search(text):
            fail(f"publication/network capability found in {script.name}")
        for required_guard in ("O_NOFOLLOW", "st_ino", "st_ctime_ns"):
            if required_guard not in text:
                fail(f"missing TOCTOU guard {required_guard} in {script.name}")
        if script == ASSEMBLER:
            for required_atomic_guard in ("renameatx_np", "0x00000004", "renameat2", "0x00000001"):
                if required_atomic_guard not in text:
                    fail(f"missing atomic no-replace guard {required_atomic_guard} in assembler")
    execution_log = assembled.stdout + assembled.stderr + verified.stdout + verified.stderr
    if forbidden.search(execution_log):
        fail("publication/network capability appeared in execution log")

print("release asset tests passed")
PY
