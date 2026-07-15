#!/usr/bin/env python3
from __future__ import annotations

import ast
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
COLLECTOR = ROOT / "Scripts/release/collect-evidence.py"
SCHEMA = ROOT / "docs/release/evidence-schema.json"
COMMIT = "1a" * 20
TREE = "2b" * 20
TEAM = "ABCDE12345"
REQUEST_ID = "3c" * 32
PRE_HASH = "4d" * 32
FINAL_HASH = "5e" * 32
PROFILE_RECEIPT_HASH = "6f" * 32
DMG_NAME = "UtterInk-0.1.0-arm64.dmg"
NOW = datetime(2026, 7, 15, 4, 0, 0, tzinfo=timezone.utc)

PRODUCT_CHECKS = (
    "MR-01", "MR-02", "MR-03", "MR-04", "MR-05", "MR-06", "MR-07",
    "PM-01", "PM-02", "PM-03", "PM-04", "PM-05",
    "MD-01", "MD-02", "MD-03", "MD-04", "MD-05", "MD-06",
    "DD-01", "DD-02", "DD-03", "DD-04", "DD-05", "DD-06", "DD-07", "DD-08", "DD-09", "DD-10", "DD-11",
    "HI-01", "HI-02", "HI-03", "HI-04", "HI-05", "HI-06", "HI-07", "HI-08", "HI-09",
    "PV-01", "PV-02", "PV-03", "PV-04", "PV-05", "PV-06", "PV-07",
)
ACCESSIBILITY_CHECKS = (
    "AX-01", "AX-02", "AX-03", "AX-04", "AX-05", "AX-06", "AX-07", "AX-08", "AX-09", "AX-10", "AX-11", "AX-12",
    "ST-01", "ST-02", "ST-03", "ST-04", "ST-05", "ST-06", "ST-07", "ST-08",
)
LOCAL_GATEKEEPER_CHECKS = ("LG-01", "LG-02", "LG-03")
SECOND_MAC_CHECKS = ("SM-01", "SM-02", "SM-03", "SM-04", "SM-05", "SM-06", "SM-07")
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


def fail(message: str) -> None:
    raise SystemExit(f"collect evidence tests failed: {message}")


def canonical(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def reviewed_known_issues() -> list[str]:
    text = (ROOT / "README.md").read_text(encoding="utf-8")
    section = text.split("## Current Limitations\n", 1)[1].split("\n## ", 1)[0]
    return sorted((line[2:] for line in section.splitlines() if line.startswith("- ")), key=lambda item: item.encode("utf-8"))


def write_json(path: Path, value: object, mode: int = 0o600) -> bytes:
    data = canonical(value)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.write_bytes(data)
    path.chmod(mode)
    return data


def aggregate_status(checks: dict[str, str]) -> str:
    values = set(checks.values())
    if values == {"pass"}:
        return "pass"
    if "fail" in values:
        return "fail"
    return "not-run"


def check_record(evidence_type: str, names: tuple[str, ...], *, overrides: dict[str, str] | None = None) -> dict[str, object]:
    checks = {name: "pass" for name in names}
    if overrides:
        checks.update(overrides)
    return {
        "candidateCommit": COMMIT,
        "checks": checks,
        "evidenceType": evidence_type,
        "product": "UtterInk",
        "schemaVersion": 1,
        "status": aggregate_status(checks),
    }


def manual_record(evidence_type: str, names: tuple[str, ...], *, overrides: dict[str, str] | None = None) -> dict[str, object]:
    states = {name: "pass" for name in names}
    if overrides:
        states.update(overrides)
    rows = {
        name: {
            "appleSiliconModelClass": "Apple-Silicon-laptop",
            "candidateCommit": COMMIT,
            "finalDMGSHA256": FINAL_HASH,
            "locale": "en",
            "macOSVersion": "14.7.6",
            "observation": "All required rows were exercised.",
            "status": state,
            "tester": "maintainer",
            "timestamp": NOW.isoformat().replace("+00:00", "Z"),
        }
        for name, state in states.items()
    }
    if "PV-02" in rows:
        rows["PV-02"]["observation"] = "Normalized provider host: https://provider.example"
    return {
        "candidateCommit": COMMIT,
        "evidenceType": evidence_type,
        "finalDMGSHA256": FINAL_HASH,
        "locale": "en",
        "product": "UtterInk",
        "rows": rows,
        "schemaVersion": 1,
        "status": aggregate_status(states),
    }


def make_candidate() -> dict[str, object]:
    return {
        "checks": {
            "entitlements": True,
            "generatedProjectClean": True,
            "history": True,
            "infoPolicy": True,
            "metadata": True,
            "packageResolution": True,
        },
        "evidenceType": "release-candidate",
        "packageResolution": {
            "path": "Packages/UtterInkKit/Package.resolved",
            "sha256": "71" * 32,
        },
        "policies": {
            "ciToolchainSHA256": "72" * 32,
            "releaseEntitlementsSHA256": "73" * 32,
            "releaseInfoPolicySHA256": "74" * 32,
            "releaseMetadataSHA256": "75" * 32,
        },
        "product": "UtterInk",
        "release": {
            "architecture": "arm64",
            "buildNumber": "1",
            "bundleIdentifier": "dev.utterink.UtterInk",
            "configuration": "Release",
            "deploymentTarget": "14.0",
            "dmgFilename": DMG_NAME,
            "marketingVersion": "0.1.0",
        },
        "schemaVersion": 1,
        "source": {"clean": True, "commit": COMMIT, "releaseTag": "v0.1.0", "tree": TREE},
        "toolchain": {
            "lockSHA256": "72" * 32,
            "sdkBuild": "25A1",
            "sdkVersion": "26.4",
            "swiftVersion": "Apple Swift version 6.3 (swiftlang-6.3.0 clang-1700.0.0)",
            "xcodeBuild": "17E202",
            "xcodeVersion": "26.4.1",
            "xcodegenBinarySHA256": "76" * 32,
            "xcodegenVersion": "2.45.4",
        },
    }


def make_base(*, commit: str = COMMIT) -> dict[str, object]:
    return {
        "candidateCommit": commit,
        "evidenceType": "incomplete-release-status",
        "notRunEvidenceFiles": list(BASE_NOT_RUN_FILES),
        "outstandingExternalApprovals": list(BASE_EXTERNAL_APPROVALS),
        "product": "UtterInk",
        "schemaVersion": 1,
        "statement": BASE_STATEMENT,
        "status": "NOT_RELEASE_READY",
    }


def make_complete(inputs: Path) -> None:
    inputs.mkdir(parents=True, mode=0o700)
    candidate_bytes = write_json(inputs / "candidate.json", make_candidate(), 0o644)
    unsigned = {
        "appTreeSHA256": "77" * 32,
        "archiveTreeSHA256": "78" * 32,
        "candidateCommit": COMMIT,
        "candidateJSONSHA256": digest(candidate_bytes),
        "evidenceType": "unsigned-build",
        "product": "UtterInk",
        "schemaVersion": 1,
        "status": "valid",
        "treeAlgorithm": "utterink-logical-tree-v1",
    }
    unsigned_bytes = write_json(inputs / "unsigned-build-evidence.json", unsigned, 0o644)

    files = ["LICENSE", "README.md", "README.zh-CN.md"]
    list_hash = digest(("\n".join(files) + "\n").encode("utf-8"))
    write_json(
        inputs / "public-file-list.json",
        {
            "candidateCommit": COMMIT,
            "candidateTree": TREE,
            "complete": True,
            "evidenceType": "public-file-list",
            "fileCount": len(files),
            "files": files,
            "listSHA256": list_hash,
            "product": "UtterInk",
            "schemaVersion": 1,
            "status": "pass",
        },
    )
    write_json(
        inputs / "repository-scope.json",
        {
            "approvalScope": "repository-branch-exact-commit",
            "branch": "release/v0.1.0",
            "candidateCommit": COMMIT,
            "candidateTree": TREE,
            "evidenceType": "repository-scope-approval",
            "product": "UtterInk",
            "publicFileListSHA256": list_hash,
            "repository": "UtterInk",
            "schemaVersion": 1,
            "status": "pass",
        },
    )

    generic = {
        "history-scan.json": check_record(
            "history-scan", ("full-history", "secret-scan", "private-data-scan")
        ),
        "legal-review.json": check_record(
            "legal-review", ("source-ip", "provenance", "license", "model-notice")
        ),
        "automated-checks.json": check_record(
            "automated-checks", ("tests", "build", "unsigned-ci-smoke")
        ),
        "identity-review.json": check_record(
            "identity-review", ("identity-approval", "competitor-similarity", "trademark-risk")
        ),
        "documentation-review.json": check_record(
            "documentation-review",
            (
                "privacy",
                "security",
                "docs",
                "links",
                "markdown",
                "readme-en-render",
                "readme-zh-render",
                "privacy-preview",
            ),
        ),
    }
    for name, value in generic.items():
        write_json(inputs / name, value)

    app_component = {
        "architecture": None,
        "designatedRequirement": "valid",
        "entitlements": {"com.apple.security.device.audio-input": True},
        "identifier": "dev.utterink.UtterInk",
        "kind": "bundle",
        "path": "UtterInk.app",
        "runtime": "hardened",
        "secureTimestamp": "present",
        "sha256": "79" * 32,
        "teamID": TEAM,
        "trust": "valid",
    }
    executable_component = {
        **app_component,
        "architecture": "arm64",
        "kind": "mach-o",
        "path": "UtterInk.app/Contents/MacOS/UtterInk",
        "sha256": "7e" * 32,
    }
    signature = {
        "candidateCommit": COMMIT,
        "candidateJSONSHA256": digest(candidate_bytes),
        "certificate": {
            "notAfter": "Jul 15 12:00:00 2027 GMT",
            "notBefore": "Jul 15 12:00:00 2026 GMT",
            "sha256": "7a" * 32,
            "trust": "valid",
        },
        "components": [app_component, executable_component],
        "evidenceType": "signature-verification",
        "product": "UtterInk",
        "schemaVersion": 1,
        "signedAppTreeSHA256": "7b" * 32,
        "status": "valid",
        "teamID": TEAM,
        "treeAlgorithm": "utterink-logical-tree-v1",
        "unsignedBuildEvidenceSHA256": digest(unsigned_bytes),
    }
    signature_bytes = write_json(inputs / "signature-verification.json", signature, 0o644)
    inspection = {
        "architecture": "arm64",
        "buildNumber": "1",
        "bundleIdentifier": "dev.utterink.UtterInk",
        "dmgFilename": DMG_NAME,
        "dmgSHA256": PRE_HASH,
        "machOCount": 1,
        "manifest": ["Applications -> /Applications", "UtterInk.app directory"],
        "minimumSystemVersion": "14.0",
        "mode": "signed",
        "product": "UtterInk",
        "signature": "developer-id",
        "status": "valid",
        "version": "0.1.0",
    }
    signing = {
        "dmgFilename": DMG_NAME,
        "dmgSHA256": PRE_HASH,
        "evidenceType": "signed-pre-staple-dmg",
        "inspection": inspection,
        "product": "UtterInk",
        "schemaVersion": 1,
        "signatureVerificationSHA256": digest(signature_bytes),
        "status": "valid",
        "teamID": TEAM,
    }
    signing_bytes = write_json(inputs / "signing-evidence.json", signing, 0o644)

    request = {
        "appleTeamID": TEAM,
        "attempt": 1,
        "candidateCommit": COMMIT,
        "candidateTree": TREE,
        "preStapleDMG": {"filename": DMG_NAME, "sha256": PRE_HASH, "sizeBytes": 1024},
        "product": "UtterInk",
        "profileBindingReceiptSHA256": PROFILE_RECEIPT_HASH,
        "requestID": REQUEST_ID,
        "requestType": "apple-notarization-request",
        "schemaVersion": 1,
        "signatureVerification": {
            "evidenceSHA256": digest(signing_bytes),
            "status": "valid",
            "teamID": TEAM,
        },
        "statement": "one upload attempt only; rejection or any file change requires new approval.",
    }
    write_json(inputs / "notarization-request.json", request, 0o400)
    approved_at = NOW - timedelta(minutes=10)
    approval = {
        "action": "apple-notarization-upload",
        "appleTeamID": TEAM,
        "approvedAt": approved_at.isoformat().replace("+00:00", "Z"),
        "attempt": 1,
        "candidateCommit": COMMIT,
        "expiresAt": (approved_at + timedelta(minutes=20)).isoformat().replace("+00:00", "Z"),
        "preStapleDMGSHA256": PRE_HASH,
        "product": "UtterInk",
        "profileBindingReceiptSHA256": PROFILE_RECEIPT_HASH,
        "requestID": REQUEST_ID,
    }
    approval_bytes = write_json(inputs / "notarization-approval.json", approval)
    write_json(
        inputs / "approval-consumed.json",
        {
            "approvalSHA256": digest(approval_bytes),
            "attempt": 1,
            "requestID": REQUEST_ID,
            "status": "consumed",
        },
    )
    write_json(
        inputs / "notarization-result.json",
        {
            "automaticRetry": False,
            "completeLogReviewed": True,
            "dmgSHA256": PRE_HASH,
            "evidenceType": "notarization-result-review",
            "issueCount": 0,
            "logStatusSummary": "Ready for distribution",
            "notarizationLogSHA256": "7c" * 32,
            "product": "UtterInk",
            "schemaVersion": 1,
            "status": "Accepted",
            "submissionID": "12345678-1234-1234-1234-123456789abc",
            "submissionResultSHA256": "7d" * 32,
            "warningCount": 0,
            "warnings": [],
        },
    )
    write_json(
        inputs / "final-dmg-verification.json",
        {
            "appGatekeeperAssessment": "accepted",
            "candidateCommit": COMMIT,
            "dmgFilename": DMG_NAME,
            "dmgGatekeeperAssessment": "accepted",
            "dmgSHA256": FINAL_HASH,
            "dmgSizeBytes": 2048,
            "evidenceType": "final-dmg-verification",
            "hashAfterVerification": FINAL_HASH,
            "hashBeforeVerification": FINAL_HASH,
            "manifest": ["Applications -> /Applications", "UtterInk.app directory"],
            "mountMode": "read-only",
            "originalArtifactUnchanged": True,
            "originalQuarantineState": "present",
            "product": "UtterInk",
            "schemaVersion": 1,
            "signatureComponentCount": 3,
            "stapleValidation": "passed",
            "status": "valid",
            "strictSignatureValidation": "passed",
        },
    )

    write_json(inputs / "manual-verification-matrix.json", manual_record("manual-verification-matrix", PRODUCT_CHECKS))
    write_json(inputs / "accessibility-matrix.json", manual_record("accessibility-matrix", ACCESSIBILITY_CHECKS))
    write_json(inputs / "local-gatekeeper.json", manual_record("local-gatekeeper", LOCAL_GATEKEEPER_CHECKS))
    write_json(inputs / "second-mac-gatekeeper.json", manual_record("second-mac-gatekeeper", SECOND_MAC_CHECKS))

    write_json(
        inputs / "support-scope.json",
        {
            "candidateCommit": COMMIT,
            "checks": {"known-issues-reviewed": "pass", "support-scope-reviewed": "pass"},
            "evidenceType": "support-scope-review",
            "knownIssues": reviewed_known_issues(),
            "nonGoals": ["Intel Macs", "automatic updates", "cloud sync", "live transcription"],
            "product": "UtterInk",
            "schemaVersion": 1,
            "status": "pass",
            "supportedScope": ["Apple Silicon", "English UI", "macOS 14 or later", "manual updates"],
        },
    )
    assets = [
        {"filename": "SHA256SUMS", "sha256": "81" * 32, "sizeBytes": 512},
        {"filename": DMG_NAME, "sha256": FINAL_HASH, "sizeBytes": 2048},
        {"filename": "UtterInk-0.1.0-source.tar.gz", "sha256": "82" * 32, "sizeBytes": 4096},
        {"filename": "UtterInk-0.1.0-source.zip", "sha256": "83" * 32, "sizeBytes": 8192},
        {"filename": "release-notes-0.1.0.md", "sha256": "84" * 32, "sizeBytes": 256},
    ]
    write_json(
        inputs / "release-assets-evidence.json",
        {
            "assets": assets,
            "candidateCommit": COMMIT,
            "evidenceType": "release-assets",
            "finalDMGSHA256": FINAL_HASH,
            "product": "UtterInk",
            "releaseTag": "v0.1.0",
            "schemaVersion": 1,
            "status": "valid",
        },
    )


def rewrite_signature_chain(inputs: Path, mutate) -> None:
    signature_path = inputs / "signature-verification.json"
    signature = json.loads(signature_path.read_text(encoding="utf-8"))
    mutate(signature)
    signature_bytes = write_json(signature_path, signature, 0o644)

    signing_path = inputs / "signing-evidence.json"
    signing = json.loads(signing_path.read_text(encoding="utf-8"))
    signing["signatureVerificationSHA256"] = digest(signature_bytes)
    signing_bytes = write_json(signing_path, signing, 0o644)

    request_path = inputs / "notarization-request.json"
    request = json.loads(request_path.read_text(encoding="utf-8"))
    request["signatureVerification"]["evidenceSHA256"] = digest(signing_bytes)
    request_path.chmod(0o600)
    write_json(request_path, request, 0o400)


def run(inputs: Path, output: Path, expected: str | None, *extra: str) -> subprocess.CompletedProcess[str]:
    command = [sys.executable, "-I", str(COLLECTOR), "--inputs", str(inputs), "--output", str(output)]
    if expected is not None:
        command += ["--expect-status", expected]
    command += list(extra)
    return subprocess.run(
        command,
        cwd=ROOT,
        env={"PATH": "/usr/bin:/bin", "LC_ALL": "C", "PYTHONDONTWRITEBYTECODE": "1"},
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def clone(base: Path, destination: Path) -> Path:
    shutil.copytree(base, destination)
    return destination


def expect_rejected(result: subprocess.CompletedProcess[str], output: Path, label: str, *, preserved: bytes | None = None) -> None:
    if result.returncode == 0:
        fail(f"{label} unexpectedly passed")
    if result.stdout:
        fail(f"{label} leaked stdout")
    if preserved is None:
        if os.path.lexists(output):
            fail(f"{label} left an output")
    elif output.read_bytes() != preserved:
        fail(f"{label} changed a preexisting output")
    if not result.stderr.startswith("evidence collector error: ") or "/Users/" in result.stderr:
        fail(f"{label} emitted an unsanitized diagnostic")


if not SCHEMA.is_file() or SCHEMA.is_symlink():
    fail("candidate evidence schema is missing or unsafe")
if not COLLECTOR.is_file() or COLLECTOR.is_symlink():
    fail("collector is missing or unsafe")
try:
    tree = ast.parse(COLLECTOR.read_text(encoding="utf-8"), filename=str(COLLECTOR))
except (OSError, UnicodeError, SyntaxError):
    fail("collector is not valid Python")
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        names = {alias.name.partition(".")[0] for alias in node.names}
    elif isinstance(node, ast.ImportFrom) and node.module:
        names = {node.module.partition(".")[0]}
    else:
        continue
    if names & {"socket", "subprocess", "http", "urllib"}:
        fail("collector imports a network/process module")
source = COLLECTOR.read_text(encoding="utf-8")
if "evidence-schema.json" not in source:
    fail("collector does not load the repository candidate evidence schema")

with tempfile.TemporaryDirectory(prefix="utterink-collect-evidence-tests-") as temporary:
    temp = Path(temporary)
    complete = temp / "complete"
    make_complete(complete)

    ready_output = temp / "ready.md"
    ready = run(complete, ready_output, "READY")
    if ready.returncode != 0 or ready.stdout != "READY\n" or ready.stderr:
        fail(f"complete evidence failed: {ready.stderr.strip()}")
    raw = ready_output.read_bytes()
    try:
        encoded = raw.decode("utf-8", errors="strict")
    except UnicodeError:
        fail("READY packet is not UTF-8 Markdown")
    if stat.S_IMODE(ready_output.stat().st_mode) != 0o600 or not encoded.endswith("\n"):
        fail("READY packet is not owner-only complete Markdown")
    if f"Computed status: READY\n" not in encoded or f"Candidate commit: {COMMIT}\n" not in encoded:
        fail("READY packet identity is wrong")
    headings = [
        "## 1. Failures and missing gates",
        "## 2. Passed automated and manual gates",
        "## 3. Outstanding external approvals",
    ]
    if not (encoded.index(headings[0]) < encoded.index(headings[1]) < encoded.index(headings[2])):
        fail("packet summary section order drifted")
    if "| None | `pass` |" not in encoded or "### Automated" not in encoded or "### Manual" not in encoded:
        fail("READY summary does not separate passed gates and approvals")
    if "not permission to push, transfer, make public, or release" not in encoded:
        fail("packet omitted the no-publication statement")
    if re.search(r"^Generated at: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", encoded, re.MULTILINE) is None:
        fail("packet generation timestamp is not fixed UTC syntax")
    for forbidden in ("maintainer", "Apple-Silicon-laptop", "Ready for distribution", "https://provider.example"):
        if forbidden in encoded:
            fail("packet leaked reviewer, device, or log details")

    complete_with_base = clone(complete, temp / "complete-with-base")
    write_json(complete_with_base / "base-evidence.json", make_base())
    complete_with_base_output = temp / "complete-with-base.md"
    result = run(complete_with_base, complete_with_base_output, "NOT_RELEASE_READY")
    if result.returncode != 0 or result.stdout != "NOT_RELEASE_READY\n" or result.stderr:
        fail(f"complete evidence with active baseline was not held NOT_RELEASE_READY: {result.stderr.strip()}")
    complete_with_base_text = complete_with_base_output.read_text(encoding="utf-8")
    if (
        "Computed status: NOT_RELEASE_READY\n" not in complete_with_base_text
        or "| `incomplete-release-baseline` | `not-run` |" not in complete_with_base_text
        or "| `candidate` | `pass` |" not in complete_with_base_text
    ):
        fail("active baseline did not prevent READY while preserving real candidate evidence")

    base_only = temp / "base-only"
    base_only.mkdir(mode=0o700)
    write_json(base_only / "base-evidence.json", make_base(), 0o600)
    base_only_output = temp / "base-only.md"
    result = run(base_only, base_only_output, "NOT_RELEASE_READY")
    if result.returncode != 0 or result.stdout != "NOT_RELEASE_READY\n" or result.stderr:
        fail(f"valid incomplete baseline failed: {result.stderr.strip()}")
    base_only_text = base_only_output.read_text(encoding="utf-8")
    if "`missing`" in base_only_text:
        fail("complete baseline registry left an unclassified missing gate")
    for gate in (
        "signing",
        "candidate",
        "toolchain",
        "dependency-lock",
        "notarization-approval",
        "notarization-submission",
        "staple-validation",
        "immutable-final-dmg",
        "local-gatekeeper:LG-01",
        "second-mac-gatekeeper:SM-01",
        "release-assets-inventory",
    ):
        if f"| `{gate}` | `not-run` |" not in base_only_text:
            fail(f"incomplete baseline omitted stable not-run gate {gate}")

    malformed_with_base = clone(base_only, temp / "malformed-with-base")
    write_json(malformed_with_base / "signature-verification.json", {"status": "pass"})
    malformed_with_base_output = temp / "malformed-with-base.md"
    expect_rejected(
        run(malformed_with_base, malformed_with_base_output, "NOT_RELEASE_READY"),
        malformed_with_base_output,
        "baseline laundering malformed present evidence",
    )

    malformed_candidate_with_base = clone(base_only, temp / "malformed-candidate-with-base")
    write_json(malformed_candidate_with_base / "candidate.json", {"status": "pass"})
    malformed_candidate_output = temp / "malformed-candidate-with-base.md"
    expect_rejected(
        run(malformed_candidate_with_base, malformed_candidate_output, "NOT_RELEASE_READY"),
        malformed_candidate_output,
        "baseline laundering malformed present candidate",
    )

    baseline_mutations = []
    extra_field = make_base()
    extra_field["overrideStatus"] = "pass"
    baseline_mutations.append(("baseline-extra-pass-field", extra_field))
    pass_status = make_base()
    pass_status["status"] = "pass"
    baseline_mutations.append(("baseline-pass-status", pass_status))
    wrong_files = make_base()
    wrong_files["notRunEvidenceFiles"] = list(BASE_NOT_RUN_FILES[:-1])
    baseline_mutations.append(("baseline-incomplete-file-list", wrong_files))
    reordered_files = make_base()
    reordered_files["notRunEvidenceFiles"] = list(reversed(BASE_NOT_RUN_FILES))
    baseline_mutations.append(("baseline-unsorted-file-list", reordered_files))
    wrong_approvals = make_base()
    wrong_approvals["outstandingExternalApprovals"] = list(BASE_EXTERNAL_APPROVALS[:-1])
    baseline_mutations.append(("baseline-incomplete-approval-list", wrong_approvals))
    wrong_statement = make_base()
    wrong_statement["statement"] = "NOT_RELEASE_READY"
    baseline_mutations.append(("baseline-wrong-statement", wrong_statement))
    for label, baseline in baseline_mutations:
        case = clone(base_only, temp / label)
        write_json(case / "base-evidence.json", baseline)
        output = temp / f"{label}.md"
        expect_rejected(run(case, output, "NOT_RELEASE_READY"), output, label)

    baseline_wrong_commit = clone(complete_with_base, temp / "baseline-wrong-commit")
    write_json(baseline_wrong_commit / "base-evidence.json", make_base(commit="9a" * 20))
    baseline_wrong_commit_output = temp / "baseline-wrong-commit.md"
    expect_rejected(
        run(baseline_wrong_commit, baseline_wrong_commit_output, "NOT_RELEASE_READY"),
        baseline_wrong_commit_output,
        "baseline commit conflicting with present candidate",
    )

    duplicate_base = clone(base_only, temp / "duplicate-base-key")
    duplicate_base_path = duplicate_base / "base-evidence.json"
    duplicate_base_path.write_bytes(
        b'{"candidateCommit":"'
        + COMMIT.encode("ascii")
        + b'","candidateCommit":"'
        + COMMIT.encode("ascii")
        + b'"}\n'
    )
    duplicate_base_path.chmod(0o600)
    duplicate_base_output = temp / "duplicate-base-key.md"
    expect_rejected(
        run(duplicate_base, duplicate_base_output, "NOT_RELEASE_READY"),
        duplicate_base_output,
        "duplicate baseline key",
    )

    in_place = clone(complete, temp / "in-place")
    in_place_output = in_place / "final-evidence-packet.md"
    expect_rejected(
        run(in_place, in_place_output, "READY"),
        in_place_output,
        "output inside evidence input directory",
    )

    repeatable = clone(complete, temp / "repeatable-inputs")
    for review in (1, 2):
        repeatable_output = temp / f"final-evidence-packet.review-{review}.md"
        result = run(repeatable, repeatable_output, "READY")
        if (
            result.returncode != 0
            or result.stdout != "READY\n"
            or result.stderr
            or "Computed status: READY\n" not in repeatable_output.read_text(encoding="utf-8")
        ):
            fail("fresh packet path outside the input directory was not repeatable")
    if any(path.name.startswith(".collect-evidence.") for path in temp.iterdir()):
        fail("atomic packet publication left a temporary file")

    raced = clone(complete, temp / "raced-after-read")
    raced_output = temp / "raced-after-read.md"
    notify_read, notify_write = os.pipe()
    continue_read, continue_write = os.pipe()
    race_process = subprocess.Popen(
        [
            sys.executable,
            "-I",
            str(COLLECTOR),
            "--inputs",
            str(raced),
            "--output",
            str(raced_output),
            "--expect-status",
            "READY",
        ],
        cwd=ROOT,
        env={
            "PATH": "/usr/bin:/bin",
            "LC_ALL": "C",
            "PYTHONDONTWRITEBYTECODE": "1",
            "UTTERINK_EVIDENCE_TEST_MODE": "1",
            "UTTERINK_EVIDENCE_TEST_NOTIFY_FD": str(notify_write),
            "UTTERINK_EVIDENCE_TEST_CONTINUE_FD": str(continue_read),
        },
        pass_fds=(notify_write, continue_read),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    os.close(notify_write)
    os.close(continue_read)
    try:
        if os.read(notify_read, 1) != b"R":
            fail("race fixture did not reach the post-read barrier")
        early_path = raced / "automated-checks.json"
        early = json.loads(early_path.read_text(encoding="utf-8"))
        early["checks"]["build"] = "fail"
        early["status"] = "fail"
        write_json(early_path, early)
        if os.write(continue_write, b"C") != 1:
            fail("race fixture could not release the collector")
        race_stdout, race_stderr = race_process.communicate(timeout=10)
    finally:
        os.close(notify_read)
        os.close(continue_write)
        if race_process.poll() is None:
            race_process.kill()
            race_process.wait(timeout=5)
    if (
        race_process.returncode == 0
        or race_stdout
        or not race_stderr.startswith("evidence collector error: ")
        or os.path.lexists(raced_output)
    ):
        fail("an early-read file changed in place was not rejected before output")

    mismatch_output = temp / "ready-mismatch.md"
    mismatch = run(complete, mismatch_output, "NOT_RELEASE_READY")
    if mismatch.returncode == 0 or mismatch.stdout or mismatch.stderr != "evidence collector error: expectation-mismatch\n":
        fail("READY expectation mismatch did not fail safely")
    if "Computed status: READY\n" not in mismatch_output.read_text(encoding="utf-8"):
        fail("computed READY status was not embedded before expectation comparison")

    incomplete = clone(complete, temp / "incomplete")
    (incomplete / "second-mac-gatekeeper.json").unlink()
    incomplete_output = temp / "incomplete.md"
    result = run(incomplete, incomplete_output, "NOT_RELEASE_READY")
    if result.returncode != 0 or result.stdout != "NOT_RELEASE_READY\n" or result.stderr:
        fail("recognized missing evidence did not classify NOT_RELEASE_READY")
    expected_missing = {f"second-mac-gatekeeper:{name}" for name in SECOND_MAC_CHECKS}
    incomplete_text = incomplete_output.read_text(encoding="utf-8")
    actual_missing = {
        match.group(1)
        for match in re.finditer(r"^\| `([^`]+)` \| `missing` \|$", incomplete_text, re.MULTILINE)
    }
    if "Computed status: NOT_RELEASE_READY\n" not in incomplete_text or actual_missing != expected_missing:
        fail("missing second-Mac record did not enumerate every gap")
    wrong_expectation = temp / "incomplete-mismatch.md"
    mismatch = run(incomplete, wrong_expectation, "READY")
    if mismatch.returncode == 0 or "Computed status: NOT_RELEASE_READY\n" not in wrong_expectation.read_text(encoding="utf-8"):
        fail("NOT_RELEASE_READY expectation mismatch did not preserve computed status")

    failed = clone(complete, temp / "failed")
    manual = manual_record(
        "second-mac-gatekeeper",
        SECOND_MAC_CHECKS,
        overrides={"SM-05": "fail", "SM-06": "not-run"},
    )
    write_json(failed / "second-mac-gatekeeper.json", manual)
    failed_output = temp / "failed.md"
    result = run(failed, failed_output, "NOT_RELEASE_READY")
    if result.returncode != 0:
        fail(f"recognized failed evidence was rejected: {result.stderr.strip()}")
    failed_text = failed_output.read_text(encoding="utf-8")
    expected_rows = (
        "| `second-mac-gatekeeper:SM-05` | `failed` |\n"
        "| `second-mac-gatekeeper:SM-06` | `not-run` |"
    )
    if expected_rows not in failed_text:
        fail("failed/not-run gates were not summarized deterministically")

    contradictory = clone(complete, temp / "contradictory")
    record = json.loads((contradictory / "second-mac-gatekeeper.json").read_text())
    record["finalDMGSHA256"] = "99" * 32
    write_json(contradictory / "second-mac-gatekeeper.json", record)
    expect_rejected(run(contradictory, temp / "contradictory.json", "NOT_RELEASE_READY"), temp / "contradictory.json", "contradictory hash")

    pre_hash_drift = clone(complete, temp / "pre-hash-drift")
    approval = json.loads((pre_hash_drift / "notarization-approval.json").read_text())
    approval["preStapleDMGSHA256"] = "98" * 32
    write_json(pre_hash_drift / "notarization-approval.json", approval)
    consumed = json.loads((pre_hash_drift / "approval-consumed.json").read_text())
    consumed["approvalSHA256"] = digest((pre_hash_drift / "notarization-approval.json").read_bytes())
    write_json(pre_hash_drift / "approval-consumed.json", consumed)
    expect_rejected(run(pre_hash_drift, temp / "pre-hash-drift.json", "READY"), temp / "pre-hash-drift.json", "approved pre-staple hash drift")

    malformed = clone(complete, temp / "malformed")
    value = json.loads((malformed / "history-scan.json").read_text())
    value["unexpected"] = True
    write_json(malformed / "history-scan.json", value)
    expect_rejected(run(malformed, temp / "malformed.json", "READY"), temp / "malformed.json", "unknown field")

    candidate_schema_drift = clone(complete, temp / "candidate-schema-drift")
    value = json.loads((candidate_schema_drift / "candidate.json").read_text())
    value["toolchain"]["xcodeVersion"] = "99.0"
    write_json(candidate_schema_drift / "candidate.json", value, 0o644)
    expect_rejected(
        run(candidate_schema_drift, temp / "candidate-schema-drift.md", "READY"),
        temp / "candidate-schema-drift.md",
        "candidate schema drift",
    )

    signature_mutations = (
        ("unknown-component-kind", 0, "kind", "anything"),
        ("unknown-required-identifier", 1, "identifier", "dev.utterink.Unknown"),
        ("missing-required-entitlement", 0, "entitlements", {}),
    )
    for label, index, key, replacement in signature_mutations:
        case = clone(complete, temp / label)
        rewrite_signature_chain(
            case,
            lambda signature, index=index, key=key, replacement=replacement: signature["components"][index].__setitem__(key, replacement),
        )
        output = temp / f"{label}.md"
        expect_rejected(run(case, output, "READY"), output, label)

    signature_count_drift = clone(complete, temp / "signature-count-drift")
    value = json.loads((signature_count_drift / "final-dmg-verification.json").read_text())
    value["signatureComponentCount"] = 4
    write_json(signature_count_drift / "final-dmg-verification.json", value)
    expect_rejected(
        run(signature_count_drift, temp / "signature-count-drift.md", "READY"),
        temp / "signature-count-drift.md",
        "signature component count drift",
    )

    macho_count_drift = clone(complete, temp / "macho-count-drift")
    signing_path = macho_count_drift / "signing-evidence.json"
    signing = json.loads(signing_path.read_text(encoding="utf-8"))
    signing["inspection"]["machOCount"] = 2
    signing_bytes = write_json(signing_path, signing, 0o644)
    request_path = macho_count_drift / "notarization-request.json"
    request = json.loads(request_path.read_text(encoding="utf-8"))
    request["signatureVerification"]["evidenceSHA256"] = digest(signing_bytes)
    request_path.chmod(0o600)
    write_json(request_path, request, 0o400)
    expect_rejected(
        run(macho_count_drift, temp / "macho-count-drift.md", "READY"),
        temp / "macho-count-drift.md",
        "Mach-O count drift",
    )

    missing_manual_row = clone(complete, temp / "missing-manual-row")
    value = json.loads((missing_manual_row / "accessibility-matrix.json").read_text())
    del value["rows"][ACCESSIBILITY_CHECKS[-1]]
    write_json(missing_manual_row / "accessibility-matrix.json", value)
    expect_rejected(
        run(missing_manual_row, temp / "missing-manual-row.md", "NOT_RELEASE_READY"),
        temp / "missing-manual-row.md",
        "missing manual matrix row",
    )

    future_manual_row = clone(complete, temp / "future-manual-row")
    value = json.loads((future_manual_row / "local-gatekeeper.json").read_text())
    value["rows"][LOCAL_GATEKEEPER_CHECKS[0]]["timestamp"] = "2099-01-01T00:00:00Z"
    write_json(future_manual_row / "local-gatekeeper.json", value)
    expect_rejected(
        run(future_manual_row, temp / "future-manual-row.md", "READY"),
        temp / "future-manual-row.md",
        "future manual evidence",
    )

    minimum_runtime_newer_os = clone(complete, temp / "minimum-runtime-newer-os")
    value = json.loads((minimum_runtime_newer_os / "manual-verification-matrix.json").read_text())
    value["rows"]["MR-01"]["macOSVersion"] = "15.1"
    write_json(minimum_runtime_newer_os / "manual-verification-matrix.json", value)
    expect_rejected(
        run(minimum_runtime_newer_os, temp / "minimum-runtime-newer-os.md", "READY"),
        temp / "minimum-runtime-newer-os.md",
        "macOS 15 substituted for minimum-runtime 14.x",
    )

    honest_minimum_not_run = clone(complete, temp / "honest-minimum-not-run")
    value = json.loads((honest_minimum_not_run / "manual-verification-matrix.json").read_text())
    value["rows"]["MR-01"]["status"] = "not-run"
    value["rows"]["MR-01"]["macOSVersion"] = "15.1"
    value["rows"]["MR-01"]["observation"] = "Not executed."
    value["status"] = "not-run"
    write_json(honest_minimum_not_run / "manual-verification-matrix.json", value)
    honest_minimum_output = temp / "honest-minimum-not-run.md"
    result = run(honest_minimum_not_run, honest_minimum_output, "NOT_RELEASE_READY")
    if (
        result.returncode != 0
        or "| `manual-verification-matrix:MR-01` | `not-run` |"
        not in honest_minimum_output.read_text(encoding="utf-8")
    ):
        fail("an honest MR not-run row on supported macOS 15 was not classified")

    supported_newer_os = clone(complete, temp / "supported-newer-os")
    value = json.loads((supported_newer_os / "accessibility-matrix.json").read_text())
    value["rows"]["AX-01"]["macOSVersion"] = "15.1"
    write_json(supported_newer_os / "accessibility-matrix.json", value)
    newer_output = temp / "supported-newer-os.md"
    result = run(supported_newer_os, newer_output, "READY")
    if result.returncode != 0 or "Computed status: READY\n" not in newer_output.read_text(encoding="utf-8"):
        fail("a supported newer macOS version was rejected outside minimum-runtime rows")

    required_tester = clone(complete, temp / "required-tester")
    value = json.loads((required_tester / "manual-verification-matrix.json").read_text())
    value["rows"]["MR-01"]["tester"] = "required"
    write_json(required_tester / "manual-verification-matrix.json", value)
    expect_rejected(
        run(required_tester, temp / "required-tester.md", "READY"),
        temp / "required-tester.md",
        "required tester placeholder",
    )

    unexecuted_pass = clone(complete, temp / "unexecuted-pass")
    value = json.loads((unexecuted_pass / "local-gatekeeper.json").read_text())
    value["rows"]["LG-01"]["observation"] = "Not executed."
    write_json(unexecuted_pass / "local-gatekeeper.json", value)
    expect_rejected(
        run(unexecuted_pass, temp / "unexecuted-pass.md", "READY"),
        temp / "unexecuted-pass.md",
        "pass with Not executed observation",
    )

    angle_placeholder = clone(complete, temp / "angle-placeholder")
    value = json.loads((angle_placeholder / "second-mac-gatekeeper.json").read_text())
    value["rows"]["SM-01"]["observation"] = "<observation>"
    write_json(angle_placeholder / "second-mac-gatekeeper.json", value)
    expect_rejected(
        run(angle_placeholder, temp / "angle-placeholder.md", "READY"),
        temp / "angle-placeholder.md",
        "angle-bracket manual placeholder",
    )

    honest_not_run = clone(complete, temp / "honest-not-run")
    value = json.loads((honest_not_run / "local-gatekeeper.json").read_text())
    value["rows"]["LG-01"]["status"] = "not-run"
    value["rows"]["LG-01"]["observation"] = "Not executed."
    value["status"] = "not-run"
    write_json(honest_not_run / "local-gatekeeper.json", value)
    honest_not_run_output = temp / "honest-not-run.md"
    result = run(honest_not_run, honest_not_run_output, "NOT_RELEASE_READY")
    if result.returncode != 0 or "| `local-gatekeeper:LG-01` | `not-run` |" not in honest_not_run_output.read_text(encoding="utf-8"):
        fail("an honest not-run manual row with real metadata was not classified")

    duplicate_key = clone(complete, temp / "duplicate-key")
    path = duplicate_key / "history-scan.json"
    path.write_bytes(b'{"candidateCommit":"' + COMMIT.encode() + b'","candidateCommit":"' + COMMIT.encode() + b'"}\n')
    path.chmod(0o600)
    expect_rejected(run(duplicate_key, temp / "duplicate-key.md", "READY"), temp / "duplicate-key.md", "duplicate JSON key")

    coerced = clone(incomplete, temp / "coerced")
    value = json.loads((coerced / "repository-scope.json").read_text())
    value["overrideMissingGate"] = True
    write_json(coerced / "repository-scope.json", value)
    expect_rejected(run(coerced, temp / "coerced.json", "READY"), temp / "coerced.json", "missing-gate coercion")

    unknown = clone(complete, temp / "unknown")
    write_json(unknown / "unregistered.json", {"status": "pass"})
    expect_rejected(run(unknown, temp / "unknown.json", "READY"), temp / "unknown.json", "unknown evidence file")

    noncanonical = clone(complete, temp / "noncanonical")
    path = noncanonical / "history-scan.json"
    path.write_text(json.dumps(json.loads(path.read_text()), indent=2) + "\n", encoding="utf-8")
    path.chmod(0o600)
    expect_rejected(run(noncanonical, temp / "noncanonical.json", "READY"), temp / "noncanonical.json", "noncanonical JSON")

    canaries = (
        "/Users/" + "alice/private.txt",
        "username=alice",
        "keychain-profile=production",
        "transcript: private words",
        "prompt: private instruction",
        "https://provider.example/v1/chat?token=secret",
        "https://alice:" + "supersecret@provider.example",
        "response body: private payload",
        "clipboard: copied private text",
        "-----BEGIN CERTIFICATE-----",
    )
    for index, canary in enumerate(canaries):
        case = clone(complete, temp / f"canary-{index}")
        value = json.loads((case / "manual-verification-matrix.json").read_text())
        value["rows"][PRODUCT_CHECKS[0]]["observation"] = canary
        write_json(case / "manual-verification-matrix.json", value)
        output = temp / f"canary-{index}.json"
        result = run(case, output, "READY")
        expect_rejected(result, output, f"canary {index}")
        if canary in result.stderr:
            fail("canary value leaked through diagnostic")

    unsafe_mode = clone(complete, temp / "unsafe-mode")
    (unsafe_mode / "history-scan.json").chmod(0o666)
    expect_rejected(run(unsafe_mode, temp / "unsafe-mode.json", "READY"), temp / "unsafe-mode.json", "group/world-writable input")

    symlinked = clone(complete, temp / "symlinked")
    target = symlinked / "history-target.json"
    (symlinked / "history-scan.json").replace(target)
    (symlinked / "history-scan.json").symlink_to(target.name)
    expect_rejected(run(symlinked, temp / "symlinked.json", "READY"), temp / "symlinked.json", "symlink input")

    hardlinked = clone(complete, temp / "hardlinked")
    target = hardlinked / "history-target.json"
    os.link(hardlinked / "history-scan.json", target)
    expect_rejected(run(hardlinked, temp / "hardlinked.json", "READY"), temp / "hardlinked.json", "hardlinked input")

    input_link = temp / "input-link"
    input_link.symlink_to(complete.name)
    expect_rejected(run(input_link, temp / "input-link.md", "READY"), temp / "input-link.md", "symlink input directory")

    preexisting_output = temp / "preexisting.json"
    preserved = b"preserve\n"
    preexisting_output.write_bytes(preserved)
    preexisting_output.chmod(0o600)
    expect_rejected(run(complete, preexisting_output, "READY"), preexisting_output, "preexisting output", preserved=preserved)

    symlink_output = temp / "output-link.json"
    symlink_target = temp / "output-target.json"
    symlink_target.write_bytes(preserved)
    symlink_output.symlink_to(symlink_target.name)
    result = run(complete, symlink_output, "READY")
    if result.returncode == 0 or symlink_target.read_bytes() != preserved or not symlink_output.is_symlink():
        fail("symlink output was followed or replaced")

    unsafe_output_parent = temp / "unsafe-output-parent"
    unsafe_output_parent.mkdir(mode=0o700)
    unsafe_output_parent.chmod(0o777)
    unsafe_output = unsafe_output_parent / "packet.md"
    expect_rejected(run(complete, unsafe_output, "READY"), unsafe_output, "world-writable output parent")

    omitted = temp / "omitted-expectation.json"
    expect_rejected(run(complete, omitted, None), omitted, "omitted expectation")
    invalid = temp / "invalid-expectation.json"
    expect_rejected(run(complete, invalid, "MAYBE"), invalid, "unknown expectation")
    duplicate_expectation = temp / "duplicate-expectation.md"
    expect_rejected(
        run(complete, duplicate_expectation, "READY", "--expect-status", "NOT_RELEASE_READY"),
        duplicate_expectation,
        "duplicate expectation",
    )

print("evidence collector tests passed")
