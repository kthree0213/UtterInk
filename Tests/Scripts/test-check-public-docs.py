#!/usr/bin/env python3
from __future__ import annotations

import ast
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from typing import NoReturn


def fail(reason: str) -> NoReturn:
    print(f"public-doc validator tests failed: {reason}", file=sys.stderr)
    raise SystemExit(1)


try:
    TEST_PATH = Path(__file__).resolve(strict=True)
except OSError:
    fail("test path is not readable")
ROOT = TEST_PATH.parents[2]
VALIDATOR_RELATIVE = PurePosixPath("Scripts/check-public-docs.py")
VALIDATOR = ROOT.joinpath(*VALIDATOR_RELATIVE.parts)

# Keep the first TDD failure singular and useful. No fixture, Git command, or
# validator process is created before this fail-closed gate passes.
try:
    validator_metadata = os.lstat(VALIDATOR)
except FileNotFoundError:
    fail("validator does not exist: Scripts/check-public-docs.py")
except OSError:
    fail("validator is not readable: Scripts/check-public-docs.py")
if stat.S_ISLNK(validator_metadata.st_mode):
    fail("validator is a symlink: Scripts/check-public-docs.py")
if not stat.S_ISREG(validator_metadata.st_mode):
    fail("validator is not a regular file: Scripts/check-public-docs.py")
try:
    validator_source = VALIDATOR.read_text(encoding="utf-8")
    validator_tree = ast.parse(validator_source, filename=str(VALIDATOR_RELATIVE))
except (OSError, UnicodeError, SyntaxError):
    fail("validator is not valid UTF-8 Python: Scripts/check-public-docs.py")
if "/" + "Users" + "/" in validator_source:
    fail("validator contains a personal-path scanner canary")
if "/" + "home" + "/" in validator_source:
    fail("validator contains a Linux personal-path scanner canary")
stdlib_modules = sys.stdlib_module_names | {"__future__"}
for node in ast.walk(validator_tree):
    imported_modules: tuple[str, ...]
    if isinstance(node, ast.Import):
        imported_modules = tuple(alias.name for alias in node.names)
    elif isinstance(node, ast.ImportFrom) and node.module is not None:
        imported_modules = (node.module,)
    else:
        continue
    if any(module.partition(".")[0] not in stdlib_modules for module in imported_modules):
        fail("validator imports a non-stdlib module")


PUBLIC_FIXTURE_PATHS = (
    "README.md",
    "README.zh-CN.md",
    "PRIVACY.md",
    "SECURITY.md",
    "CONTRIBUTING.md",
    "CODE_OF_CONDUCT.md",
    "CHANGELOG.md",
    "TRADEMARKS.md",
    "THIRD_PARTY_NOTICES.md",
    "NOTICE",
    "LICENSE",
    "Brand/wordmark-lockup.svg",
    "docs/RELEASING.md",
    "docs/privacy-data-flow.md",
    "docs/parity/accessibility-matrix.md",
    "docs/release/0.1.0-finish-plan.md",
    "docs/release/evidence-packet-template.md",
    "docs/release/evidence-schema.json",
    "docs/release/manual-verification-matrix.md",
    "docs/release/release-notes-0.1.0.md",
    ".github/ISSUE_TEMPLATE/bug_report.yml",
    ".github/ISSUE_TEMPLATE/feature_request.yml",
    ".github/pull_request_template.md",
)
RELEASE_PUBLIC_DOCS = (
    "docs/RELEASING.md",
    "docs/release/0.1.0-finish-plan.md",
    "docs/release/evidence-packet-template.md",
    "docs/release/release-notes-0.1.0.md",
)
DIAGNOSTIC = re.compile(
    r"^finding category=(?P<category>[a-z0-9-]+) "
    r"file=(?P<file>[A-Za-z0-9._/@+,-]+) line=(?P<line>[1-9][0-9]*)$"
)


def checked_path(base: Path, relative: str) -> Path:
    parsed = PurePosixPath(relative)
    if parsed.is_absolute() or not parsed.parts or ".." in parsed.parts:
        fail("fixture path is unsafe")
    candidate = base.joinpath(*parsed.parts)
    try:
        candidate.resolve(strict=False).relative_to(base.resolve(strict=True))
    except (OSError, ValueError):
        fail("fixture path escapes its root")
    return candidate


def copy_public_file(fixture: Path, relative: str) -> None:
    source = checked_path(ROOT, relative)
    try:
        metadata = os.lstat(source)
    except FileNotFoundError:
        fail(f"required fixture source does not exist: {relative}")
    except OSError:
        fail(f"required fixture source is unreadable: {relative}")
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        fail(f"required fixture source is unsafe: {relative}")
    destination = checked_path(fixture, relative)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination, follow_symlinks=False)


GIT = shutil.which("git")
if GIT is None:
    fail("git is unavailable for tracked-path fixtures")


def git(fixture: Path, *arguments: str) -> None:
    result = subprocess.run(
        [GIT, "-C", str(fixture), *arguments],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
        env={
            **os.environ,
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "LC_ALL": "C",
        },
    )
    if result.returncode != 0:
        fail("could not prepare an isolated Git fixture")


def make_fixture(temp_root: Path, name: str) -> Path:
    fixture = checked_path(temp_root, name)
    fixture.mkdir()
    for relative in PUBLIC_FIXTURE_PATHS:
        copy_public_file(fixture, relative)
    git(fixture, "init", "-q")
    git(fixture, "add", "-f", "--", ".")
    return fixture


def write_fixture(fixture: Path, relative: str, contents: str, *, append: bool = False) -> None:
    destination = checked_path(fixture, relative)
    destination.parent.mkdir(parents=True, exist_ok=True)
    mode = "a" if append else "w"
    with destination.open(mode, encoding="utf-8", newline="\n") as handle:
        handle.write(contents)


def run_validator(
    fixture: Path,
    *,
    arguments: tuple[str, ...] = (),
    environment_overrides: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    fixture_validator = checked_path(fixture, str(VALIDATOR_RELATIVE))
    fixture_validator.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(VALIDATOR, fixture_validator, follow_symlinks=False)
    environment = {
        **os.environ,
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_CONFIG_NOSYSTEM": "1",
        "HOME": str(checked_path(fixture, ".test-home")),
        "LC_ALL": "C",
        "PYTHONDONTWRITEBYTECODE": "1",
    }
    for key in tuple(environment):
        if key.casefold() in {"http_proxy", "https_proxy", "all_proxy", "no_proxy"}:
            environment.pop(key)
    if environment_overrides is not None:
        environment.update(environment_overrides)
    return subprocess.run(
        [sys.executable, str(fixture_validator), *arguments],
        cwd=fixture,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        check=False,
        timeout=20,
        env=environment,
    )


def expect_failure(
    fixture: Path,
    case: str,
    category: str,
    relative: str,
    *,
    secret: str | None = None,
    expected_line: int | None = None,
    arguments: tuple[str, ...] = (),
    environment_overrides: dict[str, str] | None = None,
) -> None:
    result = run_validator(
        fixture,
        arguments=arguments,
        environment_overrides=environment_overrides,
    )
    if result.returncode == 0:
        fail(f"{case} fixture was accepted")
    if result.stdout:
        fail(f"{case} emitted failure output on stdout")
    if secret is not None and secret in result.stderr:
        fail(f"{case} diagnostic disclosed its matched value")
    records = []
    for line in result.stderr.splitlines():
        match = DIAGNOSTIC.fullmatch(line)
        if match is None:
            fail(f"{case} emitted a non-redacted diagnostic")
        records.append(match.groupdict())
    if not records:
        fail(f"{case} emitted no diagnostic")
    if not any(
        record["category"] == category
        and record["file"] == relative
        and (expected_line is None or int(record["line"]) == expected_line)
        for record in records
    ):
        fail(f"{case} omitted its expected category, file, or line")


def expect_pass(
    fixture: Path,
    *,
    environment_overrides: dict[str, str] | None = None,
) -> None:
    result = run_validator(fixture, environment_overrides=environment_overrides)
    if result.returncode != 0 or result.stderr:
        fail("valid fixture was rejected")
    if result.stdout != "public documents valid\n":
        fail("valid fixture emitted unexpected output")


with tempfile.TemporaryDirectory(prefix="utterink-public-docs-") as temporary:
    temp_root = Path(temporary).resolve(strict=True)

    valid = make_fixture(temp_root, "valid")
    expect_pass(valid)

    fixed_system_git = make_fixture(temp_root, "fixed-system-git")
    empty_path = checked_path(fixed_system_git, ".empty-path")
    empty_path.mkdir()
    expect_pass(
        fixed_system_git,
        environment_overrides={"PATH": str(empty_path)},
    )

    unexpected_argument = make_fixture(temp_root, "unexpected-argument")
    private_argument = "--root=/" + "Users/fixture-owner/private"
    expect_failure(
        unexpected_argument,
        "unexpected-argument",
        "unexpected-argument",
        "Scripts/check-public-docs.py",
        secret=private_argument,
        arguments=(private_argument,),
    )

    unsafe_git_environment = make_fixture(temp_root, "unsafe-git-environment")
    private_git_directory = "/" + "Users/fixture-owner/private.git"
    expect_failure(
        unsafe_git_environment,
        "unsafe-git-environment",
        "unsafe-git-environment",
        ".git",
        secret=private_git_directory,
        environment_overrides={"GIT_DIR": private_git_directory},
    )

    broken_link = make_fixture(temp_root, "broken-link")
    write_fixture(broken_link, "README.md", "\n[missing fixture](docs/missing.md)\n", append=True)
    expect_failure(broken_link, "broken-relative-link", "broken-relative-link", "README.md")

    template_relative_link = make_fixture(temp_root, "template-relative-link")
    write_fixture(
        template_relative_link,
        ".github/ISSUE_TEMPLATE/bug_report.yml",
        "\n  - type: markdown\n    attributes:\n      value: '[security](../../SECURITY.md)'\n",
        append=True,
    )
    expect_failure(
        template_relative_link,
        "template-relative-link",
        "template-relative-link",
        ".github/ISSUE_TEMPLATE/bug_report.yml",
    )

    unsafe_notice_command = make_fixture(temp_root, "unsafe-notice-command")
    write_fixture(
        unsafe_notice_command,
        "CONTRIBUTING.md",
        "\n```bash\n./Scripts/collect-third-party-notices.sh --check\n```\n",
        append=True,
    )
    expect_failure(
        unsafe_notice_command,
        "unsafe-notice-command",
        "unsafe-notice-command",
        "CONTRIBUTING.md",
    )

    unsafe_swiftpm_command = make_fixture(temp_root, "unsafe-swiftpm-command")
    write_fixture(
        unsafe_swiftpm_command,
        "CONTRIBUTING.md",
        "\n```bash\nswift test --package-path Packages/UtterInkKit\n```\n",
        append=True,
    )
    expect_failure(
        unsafe_swiftpm_command,
        "unsafe-swiftpm-command",
        "unsafe-swiftpm-command",
        "CONTRIBUTING.md",
    )

    insecure_url_value = "http" + "://example.org/utterink"
    insecure_url = make_fixture(temp_root, "insecure-url")
    write_fixture(
        insecure_url,
        "README.md",
        f"\n[insecure external link]({insecure_url_value})\n",
        append=True,
    )
    expect_failure(
        insecure_url,
        "insecure-link-scheme",
        "insecure-link-scheme",
        "README.md",
        secret=insecure_url_value,
    )

    personal_path = "/" + "Users" + "/fixture-owner/Documents/private.txt"
    personal = make_fixture(temp_root, "personal-path")
    personal_line = checked_path(personal, "README.md").read_text(encoding="utf-8").count("\n") + 2
    write_fixture(personal, "README.md", f"\nLocal note: {personal_path}\n", append=True)
    expect_failure(
        personal,
        "personal-path",
        "personal-path",
        "README.md",
        secret=personal_path,
        expected_line=personal_line,
    )

    local_url = "file" + ":///private/tmp/private-note.txt"
    file_url = make_fixture(temp_root, "file-url")
    write_fixture(file_url, "README.md", f"\nLocal note: {local_url}\n", append=True)
    expect_failure(file_url, "file-url", "file-url", "README.md", secret=local_url)

    transcript_value = "TRANSCRIPT_" + "CANARY_0123456789ABCDEF"
    transcript = make_fixture(temp_root, "transcript-canary")
    write_fixture(transcript, "README.md", f"\n{transcript_value}\n", append=True)
    expect_failure(
        transcript,
        "transcript-canary",
        "transcript-canary",
        "README.md",
        secret=transcript_value,
    )

    pem_value = "-----BEGIN " + "PRIVATE KEY-----"
    pem = make_fixture(temp_root, "private-key")
    write_fixture(pem, "README.md", f"\n{pem_value}\n", append=True)
    expect_failure(pem, "private-key", "private-key", "README.md", secret=pem_value)

    token_cases = (
        ("github-token", "gh" + "p_" + "A" * 24, "common-token"),
        ("github-pat", "github_" + "pat_" + "A" * 24, "common-token"),
        ("aws-token", "AK" + "IA" + "0" * 16, "common-token"),
        ("generic-provider-token", "sk-" + "A" * 32, "provider-credential"),
        ("provider-token", "sk-" + "proj-" + "A" * 32, "provider-credential"),
    )
    for name, token, category in token_cases:
        fixture = make_fixture(temp_root, name)
        write_fixture(fixture, "README.md", f"\n{token}\n", append=True)
        expect_failure(fixture, name, category, "README.md", secret=token)

    for index, relative in enumerate(RELEASE_PUBLIC_DOCS, 1):
        release_path = "/" + "Users" + f"/release-fixture-{index}/private.txt"
        personal_release = make_fixture(temp_root, f"release-doc-personal-{index}")
        write_fixture(personal_release, relative, f"\nLocal note: {release_path}\n", append=True)
        expect_failure(
            personal_release,
            f"release-doc-personal-{index}",
            "personal-path",
            relative,
            secret=release_path,
        )

        release_token = "sk-" + chr(ord("A") + index) * 32
        credential_release = make_fixture(temp_root, f"release-doc-credential-{index}")
        write_fixture(credential_release, relative, f"\n{release_token}\n", append=True)
        expect_failure(
            credential_release,
            f"release-doc-credential-{index}",
            "provider-credential",
            relative,
            secret=release_token,
        )

        false_release_claim = "Download https://example.org/UtterInk.dmg now."
        claim_release = make_fixture(temp_root, f"release-doc-claim-{index}")
        write_fixture(claim_release, relative, f"\n{false_release_claim}\n", append=True)
        expect_failure(
            claim_release,
            f"release-doc-claim-{index}",
            "prerelease-dmg-url",
            relative,
            secret=false_release_claim,
        )

    api_key_value = "fixture-private-value-0123456789"
    hardcoded_key = make_fixture(temp_root, "hardcoded-api-key")
    write_fixture(
        hardcoded_key,
        "README.md",
        "\n```swift\nprofile.api" + f'Key = "{api_key_value}"\n```\n',
        append=True,
    )
    expect_failure(
        hardcoded_key,
        "hardcoded-api-key",
        "provider-credential",
        "README.md",
        secret=api_key_value,
    )

    for name, forbidden_path in (
        ("environment-file", ".env"),
        ("swift-build", ".build/object.o"),
        ("disk-image", "dist/UtterInk.dmg"),
        ("model-cache", "models/weights.bin"),
    ):
        fixture = make_fixture(temp_root, name)
        write_fixture(fixture, forbidden_path, "fixture\n")
        git(fixture, "add", "-f", "--", forbidden_path)
        expect_failure(fixture, name, "forbidden-tracked-path", forbidden_path)

    missing_heading = make_fixture(temp_root, "missing-heading")
    readme = checked_path(missing_heading, "README.md")
    contents = readme.read_text(encoding="utf-8")
    if not contents.startswith("# UtterInk\n"):
        fail("README fixture lacks its expected required heading")
    write_fixture(missing_heading, "README.md", contents.removeprefix("# UtterInk\n"))
    expect_failure(
        missing_heading,
        "missing-required-heading",
        "missing-required-heading",
        "README.md",
    )

    stale_pr_heading = make_fixture(temp_root, "stale-pr-heading")
    pr_template = checked_path(stale_pr_heading, ".github/pull_request_template.md")
    pr_contents = pr_template.read_text(encoding="utf-8")
    current_heading = "## Final checklist"
    if current_heading not in pr_contents:
        fail("pull request fixture lacks its current required heading")
    write_fixture(
        stale_pr_heading,
        ".github/pull_request_template.md",
        pr_contents.replace(current_heading, "## Contributor checklist", 1),
    )
    expect_failure(
        stale_pr_heading,
        "stale-pr-template-heading",
        "missing-required-heading",
        ".github/pull_request_template.md",
    )

    claim_cases = (
        (
            "auto-update-claim",
            "UtterInk updates itself automatically.",
            "positive-auto-update-claim",
        ),
        ("cloud-sync-claim", "UtterInk supports cloud sync.", "positive-cloud-sync-claim"),
        (
            "live-transcription-claim",
            "UtterInk supports live transcription.",
            "positive-live-transcription-claim",
        ),
        (
            "bundled-api-keys-claim",
            "UtterInk ships with bundled API keys.",
            "bundled-api-keys-claim",
        ),
        (
            "audio-retention-claim",
            "UtterInk stores audio recordings.",
            "positive-audio-retention-claim",
        ),
        ("legacy-brand-claim", "FlowType is the product name.", "legacy-flowtype-brand"),
        ("intel-claim", "Runs on Intel Macs.", "intel-claim"),
        ("universal-claim", "Ships as a universal application.", "universal-claim"),
        (
            "prerelease-dmg-claim",
            "Download https://example.org/UtterInk.dmg now.",
            "prerelease-dmg-url",
        ),
    )
    for name, claim, category in claim_cases:
        fixture = make_fixture(temp_root, name)
        write_fixture(fixture, "README.md", f"\n{claim}\n", append=True)
        expect_failure(fixture, name, category, "README.md", secret=claim)

print("public-doc validator fixture tests passed")
