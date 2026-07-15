#!/usr/bin/env python3
from __future__ import annotations

import ast
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
VERIFIER = ROOT / "Scripts" / "verify-workflow.py"
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"

CHECKOUT_SHA = "de0fac2e4500dabe0009e67214ff5f5447ce83dd"
VALID_WORKFLOW = f"""\
name: CI
on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  verify:
    runs-on: macos-26
    timeout-minutes: 45
    env:
      DEVELOPER_DIR: /Applications/Xcode_26.4.app/Contents/Developer
      UTTERINK_CI_RUNNER_LABEL: macos-26
    steps:
      - uses: actions/checkout@{CHECKOUT_SHA}
        with:
          fetch-depth: 0
          persist-credentials: false
      - name: Bootstrap locked XcodeGen
        run: ./Scripts/bootstrap-xcodegen.sh
      - name: Verify toolchain
        run: ./Scripts/verify-toolchain.sh --context ci
      - name: Verify workflow policy
        run: python3 Scripts/verify-workflow.py
      - name: Run source, history, test, and build checks
        run: ./Scripts/ci-local.sh --ci --unsigned-package-smoke
      - name: Remove unsigned outputs
        if: always()
        run: ./Scripts/clean-distribution-output.sh
"""


def fail(reason: str) -> None:
    print(f"workflow policy tests failed: {reason}", file=sys.stderr)
    raise SystemExit(1)


def sanitized_environment() -> dict[str, str]:
    environment = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("GIT_") and key not in {"PYTHONPATH", "PYTHONHOME"}
    }
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    return environment


def replace_once(source: str, old: str, new: str) -> str:
    if source.count(old) != 1:
        fail(f"fixture mutation is not singular: {old!r}")
    return source.replace(old, new, 1)


def make_fixture(parent: Path, label: str, workflow: str) -> Path:
    fixture = parent / label
    (fixture / "Scripts").mkdir(parents=True)
    (fixture / ".github" / "workflows").mkdir(parents=True)
    shutil.copyfile(VERIFIER, fixture / "Scripts" / "verify-workflow.py")
    (fixture / ".github" / "workflows" / "ci.yml").write_text(
        workflow,
        encoding="utf-8",
    )
    return fixture


def run_verifier(root: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(root / "Scripts" / "verify-workflow.py"), *arguments],
        cwd=root,
        env=sanitized_environment(),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
        timeout=10,
    )


def expect_success(root: Path) -> None:
    result = run_verifier(root)
    if result.returncode != 0:
        fail(f"valid fixture was rejected: {result.stderr.strip()}")
    if result.stdout != "workflow policy valid\n" or result.stderr:
        fail("valid fixture output was not normalized")


def expect_failure(root: Path, category: str, *, secret: str | None = None) -> None:
    result = run_verifier(root)
    if result.returncode != 1:
        fail(f"{root.name} returned {result.returncode}, expected 1")
    if result.stdout:
        fail(f"{root.name} wrote success output")
    if secret is not None and secret in result.stderr:
        fail(f"{root.name} disclosed a fixture secret")
    if result.stderr != f"workflow policy error: {category}\n":
        fail(f"{root.name} emitted an unexpected diagnostic: {result.stderr.strip()}")


# This is the intentional first TDD gate: the test must fail before the policy
# verifier exists, without building any misleading fixtures.
if not VERIFIER.is_file():
    fail("verifier does not exist: Scripts/verify-workflow.py")
if not WORKFLOW.is_file():
    fail("workflow does not exist: .github/workflows/ci.yml")

try:
    verifier_source = VERIFIER.read_text(encoding="utf-8")
    verifier_tree = ast.parse(verifier_source, filename="Scripts/verify-workflow.py")
except (OSError, UnicodeError, SyntaxError):
    fail("verifier is not valid UTF-8 Python")

allowed_stdlib_modules = {
    "__future__",
    "ast",
    "dataclasses",
    "os",
    "pathlib",
    "re",
    "stat",
    "sys",
    "typing",
}
for node in ast.walk(verifier_tree):
    if isinstance(node, ast.Import):
        modules = tuple(alias.name for alias in node.names)
    elif isinstance(node, ast.ImportFrom) and node.module is not None:
        modules = (node.module,)
    else:
        continue
    if any(module.partition(".")[0] not in allowed_stdlib_modules for module in modules):
        fail("verifier imports a non-standard-library YAML implementation")

try:
    authoritative_workflow = WORKFLOW.read_text(encoding="utf-8")
except (OSError, UnicodeError):
    fail("authoritative workflow is not readable UTF-8")
if authoritative_workflow != VALID_WORKFLOW:
    fail("authoritative workflow does not match the reviewed exact workflow")


with tempfile.TemporaryDirectory(prefix="utterink-workflow-policy-tests-") as temporary:
    fixtures = Path(temporary).resolve()

    valid = make_fixture(fixtures, "valid", VALID_WORKFLOW)
    expect_success(valid)

    # Policy decisions are structural: forbidden-looking text in a comment is
    # inert and must not be confused with an action, command, or secret use.
    commented = make_fixture(
        fixtures,
        "commented-inert-text",
        "# actions/upload-artifact and secrets.EXAMPLE are forbidden when active\n"
        + VALID_WORKFLOW,
    )
    expect_success(commented)

    mutations = (
        (
            "permissions-write",
            replace_once(VALID_WORKFLOW, "contents: read", "contents: write"),
            "permissions",
            None,
        ),
        (
            "permissions-extra",
            replace_once(
                VALID_WORKFLOW,
                "  contents: read\n\njobs:",
                "  contents: read\n  issues: read\n\njobs:",
            ),
            "permissions",
            None,
        ),
        (
            "job-permissions",
            replace_once(
                VALID_WORKFLOW,
                "    runs-on: macos-26",
                "    permissions:\n      contents: write\n    runs-on: macos-26",
            ),
            "permissions",
            None,
        ),
        (
            "write-all",
            replace_once(
                VALID_WORKFLOW,
                "permissions:\n  contents: read",
                "permissions: write-all",
            ),
            "permissions",
            None,
        ),
        (
            "checkout-tag",
            replace_once(VALID_WORKFLOW, f"actions/checkout@{CHECKOUT_SHA}", "actions/checkout@v4"),
            "action-reference",
            None,
        ),
        (
            "checkout-branch",
            replace_once(
                VALID_WORKFLOW,
                f"actions/checkout@{CHECKOUT_SHA}",
                "actions/checkout@main",
            ),
            "action-reference",
            None,
        ),
        (
            "checkout-wrong-sha",
            replace_once(
                VALID_WORKFLOW,
                CHECKOUT_SHA,
                "1111111111111111111111111111111111111111",
            ),
            "action-not-allowed",
            None,
        ),
        (
            "fetch-depth",
            replace_once(VALID_WORKFLOW, "fetch-depth: 0", "fetch-depth: 1"),
            "checkout-policy",
            None,
        ),
        (
            "fetch-depth-string",
            replace_once(VALID_WORKFLOW, "fetch-depth: 0", 'fetch-depth: "0"'),
            "checkout-policy",
            None,
        ),
        (
            "persist-credentials",
            replace_once(
                VALID_WORKFLOW,
                "persist-credentials: false",
                "persist-credentials: true",
            ),
            "checkout-policy",
            None,
        ),
        (
            "persist-credentials-string",
            replace_once(
                VALID_WORKFLOW,
                "persist-credentials: false",
                'persist-credentials: "false"',
            ),
            "checkout-policy",
            None,
        ),
        (
            "runner",
            replace_once(VALID_WORKFLOW, "runs-on: macos-26", "runs-on: macos-15"),
            "runner",
            None,
        ),
        (
            "runner-label-env",
            replace_once(
                VALID_WORKFLOW,
                "UTTERINK_CI_RUNNER_LABEL: macos-26",
                "UTTERINK_CI_RUNNER_LABEL: macos-15",
            ),
            "runner",
            None,
        ),
        (
            "developer-dir",
            replace_once(
                VALID_WORKFLOW,
                "/Applications/Xcode_26.4.app/Contents/Developer",
                "/Applications/Xcode.app/Contents/Developer",
            ),
            "developer-dir",
            None,
        ),
        (
            "missing-unsigned-package-smoke",
            replace_once(
                VALID_WORKFLOW,
                "run: ./Scripts/ci-local.sh --ci --unsigned-package-smoke",
                "run: ./Scripts/ci-local.sh --ci",
            ),
            "steps",
            None,
        ),
        (
            "secret-reference",
            replace_once(
                VALID_WORKFLOW,
                "      DEVELOPER_DIR:",
                "      LEAKED_VALUE: ${{ secrets.UTTERINK_PRIVATE_VALUE }}\n      DEVELOPER_DIR:",
            ),
            "secret-reference",
            "UTTERINK_PRIVATE_VALUE",
        ),
        (
            "apple-credential",
            replace_once(
                VALID_WORKFLOW,
                "      DEVELOPER_DIR:",
                "      APPLE_ID: redacted@example.invalid\n      DEVELOPER_DIR:",
            ),
            "credential-name",
            "redacted@example.invalid",
        ),
        (
            "api-credential",
            replace_once(
                VALID_WORKFLOW,
                "      DEVELOPER_DIR:",
                "      API_KEY: fixture-private-value\n      DEVELOPER_DIR:",
            ),
            "credential-name",
            "fixture-private-value",
        ),
        (
            "signing-identity",
            replace_once(
                VALID_WORKFLOW,
                "      DEVELOPER_DIR:",
                "      CODE_SIGN_IDENTITY: Developer ID Application\n      DEVELOPER_DIR:",
            ),
            "credential-name",
            None,
        ),
        (
            "upload-action",
            replace_once(
                VALID_WORKFLOW,
                "      - name: Remove unsigned outputs",
                "      - uses: actions/upload-artifact@1111111111111111111111111111111111111111\n"
                "      - name: Remove unsigned outputs",
            ),
            "artifact-upload",
            None,
        ),
        (
            "unknown-action",
            replace_once(
                VALID_WORKFLOW,
                "      - name: Remove unsigned outputs",
                "      - uses: actions/setup-python@1111111111111111111111111111111111111111\n"
                "      - name: Remove unsigned outputs",
            ),
            "action-not-allowed",
            None,
        ),
        (
            "release-command",
            replace_once(
                VALID_WORKFLOW,
                "run: ./Scripts/ci-local.sh --ci --unsigned-package-smoke",
                "run: gh release create v0.1.0",
            ),
            "forbidden-command",
            None,
        ),
        (
            "push-command",
            replace_once(
                VALID_WORKFLOW,
                "run: ./Scripts/ci-local.sh --ci --unsigned-package-smoke",
                "run: git push origin main",
            ),
            "forbidden-command",
            None,
        ),
        (
            "notary-command",
            replace_once(
                VALID_WORKFLOW,
                "run: ./Scripts/ci-local.sh --ci --unsigned-package-smoke",
                "run: xcrun notarytool submit candidate.dmg",
            ),
            "forbidden-command",
            None,
        ),
        (
            "sign-command",
            replace_once(
                VALID_WORKFLOW,
                "run: ./Scripts/ci-local.sh --ci --unsigned-package-smoke",
                'run: codesign --sign "Developer ID" UtterInk.app',
            ),
            "forbidden-command",
            None,
        ),
        (
            "workflow-dispatch",
            replace_once(
                VALID_WORKFLOW,
                "  pull_request:\n",
                "  pull_request:\n  workflow_dispatch:\n",
            ),
            "triggers",
            None,
        ),
        (
            "yaml-tag",
            replace_once(VALID_WORKFLOW, "runs-on: macos-26", "runs-on: !unsafe macos-26"),
            "unsafe-yaml",
            None,
        ),
        (
            "yaml-anchor",
            replace_once(VALID_WORKFLOW, "runs-on: macos-26", "runs-on: &runner macos-26"),
            "unsafe-yaml",
            None,
        ),
        (
            "duplicate-permissions",
            replace_once(
                VALID_WORKFLOW,
                "permissions:\n  contents: read",
                "permissions:\n  contents: read\npermissions:\n  contents: read",
            ),
            "invalid-yaml",
            None,
        ),
    )

    for label, contents, category, secret in mutations:
        fixture = make_fixture(fixtures, label, contents)
        expect_failure(fixture, category, secret=secret)

    invalid_arguments = run_verifier(valid, "--workflow", "private.yml")
    if invalid_arguments.returncode != 2:
        fail("unexpected arguments were not rejected with status 2")
    if invalid_arguments.stdout:
        fail("unexpected arguments wrote success output")
    if invalid_arguments.stderr != "workflow policy error: invalid-arguments\n":
        fail("unexpected arguments emitted a non-sanitized diagnostic")


print("workflow policy tests passed")
