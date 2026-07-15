#!/usr/bin/env python3
from __future__ import annotations

from datetime import datetime, timedelta, timezone
import hashlib
import ast
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
PREPARER = ROOT / "Scripts" / "release" / "prepare-notarization-request.py"
RESULT_VERIFIER = ROOT / "Scripts" / "release" / "verify-notarization-result.py"
APPROVAL_SCHEMA = ROOT / "docs" / "release" / "notarization-approval.schema.json"
PROFILE_SCHEMA = ROOT / "docs" / "release" / "notary-profile-binding.schema.json"

TEAM = "ABCDE12345"
COMMIT = "1234567890abcdef1234567890abcdef12345678"
TREE = "abcdef1234567890abcdef1234567890abcdef12"
CERTIFICATE_SHA256 = "12" * 32
DMG_NAME = "UtterInk-0.1.0-arm64.dmg"
STATEMENT = "one upload attempt only; rejection or any file change requires new approval."
REQUEST_KEYS = {
    "schemaVersion",
    "requestType",
    "requestID",
    "product",
    "candidateCommit",
    "candidateTree",
    "appleTeamID",
    "profileBindingReceiptSHA256",
    "preStapleDMG",
    "signatureVerification",
    "attempt",
    "statement",
}
APPROVAL_KEYS = {
    "action",
    "requestID",
    "product",
    "appleTeamID",
    "preStapleDMGSHA256",
    "candidateCommit",
    "profileBindingReceiptSHA256",
    "attempt",
    "approvedAt",
    "expiresAt",
}
PROFILE_KEYS = {
    "schemaVersion",
    "bindingNonce",
    "appleTeamID",
    "signingCertificateSHA256",
    "profileNameSalt",
    "profileNameHashSHA256",
    "notarytoolVersion",
    "validatedAt",
    "expiresAt",
    "selfSHA256",
}


def fail(reason: str) -> None:
    print(f"notarization gate tests failed: {reason}", file=sys.stderr)
    raise SystemExit(1)


def canonical(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_bytes(path: Path, data: bytes, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    path.chmod(mode)


def write_json(path: Path, value: object, mode: int = 0o600) -> bytes:
    data = canonical(value)
    write_bytes(path, data, mode)
    return data


def iso(value: datetime) -> str:
    return value.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def environment(extra: dict[str, str] | None = None) -> dict[str, str]:
    result = {
        key: value
        for key, value in os.environ.items()
        if key not in {"PYTHONPATH", "PYTHONHOME"} and not key.startswith("GIT_")
    }
    result["PYTHONDONTWRITEBYTECODE"] = "1"
    if extra:
        result.update(extra)
    return result


def run(script: Path, root: Path, *arguments: str, extra_env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, "-I", str(script), *arguments],
        cwd=root,
        env=environment(extra_env),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
        timeout=20,
    )


def expect_failure(
    result: subprocess.CompletedProcess[str],
    context: str,
    *,
    output: Path | None = None,
) -> None:
    if result.returncode == 0:
        fail(f"{context} unexpectedly passed")
    if result.stdout:
        fail(f"{context} wrote success output")
    if output is not None and (output.exists() or output.is_symlink()):
        fail(f"{context} left an output file")
    if not re.fullmatch(r"(?:notarization request|notarization result) error: [a-z0-9-]+\n", result.stderr):
        fail(f"{context} emitted a non-sanitized diagnostic: {result.stderr!r}")


def schema_contract(path: Path, expected_keys: set[str]) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"schema is unreadable: {path}: {error}")
    if value.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
        fail(f"schema draft drifted: {path.name}")
    if value.get("type") != "object" or value.get("additionalProperties") is not False:
        fail(f"schema is not exact: {path.name}")
    if set(value.get("required", [])) != expected_keys or set(value.get("properties", {})) != expected_keys:
        fail(f"schema key contract drifted: {path.name}")
    return value


def make_profile_receipt(now: datetime) -> dict[str, object]:
    payload: dict[str, object] = {
        "schemaVersion": 1,
        "bindingNonce": "23" * 32,
        "appleTeamID": TEAM,
        "signingCertificateSHA256": CERTIFICATE_SHA256,
        "profileNameSalt": "34" * 32,
        "profileNameHashSHA256": "45" * 32,
        "notarytoolVersion": "notarytool version 1.0-fixture",
        "validatedAt": iso(now - timedelta(minutes=2)),
        "expiresAt": iso(now - timedelta(minutes=2) + timedelta(hours=24)),
    }
    payload["selfSHA256"] = digest(canonical(payload))
    return payload


def candidate_value() -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "evidenceType": "release-candidate",
        "product": "UtterInk",
        "source": {"commit": COMMIT, "tree": TREE, "releaseTag": "v0.1.0", "clean": True},
        "release": {
            "configuration": "Release",
            "marketingVersion": "0.1.0",
            "buildNumber": "1",
            "bundleIdentifier": "dev.utterink.UtterInk",
            "deploymentTarget": "14.0",
            "architecture": "arm64",
            "dmgFilename": DMG_NAME,
        },
        "toolchain": {
            "lockSHA256": "56" * 32,
            "xcodeVersion": "26.4.1",
            "xcodeBuild": "17E202",
            "sdkVersion": "26.4",
            "sdkBuild": "25E5200",
            "swiftVersion": "Apple Swift version 6.3 (swiftlang-fixture clang-fixture)",
            "xcodegenVersion": "2.45.4",
            "xcodegenBinarySHA256": "67" * 32,
        },
        "packageResolution": {"path": "Packages/UtterInkKit/Package.resolved", "sha256": "78" * 32},
        "policies": {
            "releaseMetadataSHA256": "89" * 32,
            "releaseEntitlementsSHA256": "9a" * 32,
            "releaseInfoPolicySHA256": "ab" * 32,
            "ciToolchainSHA256": "bc" * 32,
        },
        "checks": {
            "history": True,
            "metadata": True,
            "entitlements": True,
            "infoPolicy": True,
            "packageResolution": True,
            "generatedProjectClean": True,
        },
    }


def make_fixture(parent: Path, now: datetime) -> tuple[Path, Path, Path, Path]:
    fixture = parent / "repo"
    release_scripts = fixture / "Scripts" / "release"
    release_docs = fixture / "docs" / "release"
    release_scripts.mkdir(parents=True)
    release_docs.mkdir(parents=True)
    shutil.copyfile(PREPARER, release_scripts / PREPARER.name)
    shutil.copyfile(RESULT_VERIFIER, release_scripts / RESULT_VERIFIER.name)
    shutil.copyfile(APPROVAL_SCHEMA, release_docs / APPROVAL_SCHEMA.name)
    shutil.copyfile(PROFILE_SCHEMA, release_docs / PROFILE_SCHEMA.name)

    requests = fixture / ".release-requests"
    approvals = fixture / ".release-approvals"
    bindings = fixture / ".notary-profile-bindings"
    for directory in (requests, approvals, bindings):
        directory.mkdir(mode=0o700)

    candidate = fixture / ".release-work" / "candidate"
    candidate.mkdir(parents=True)
    candidate_json = write_json(candidate / "candidate.json", candidate_value(), 0o644)

    dmg_bytes = b"UtterInk signed pre-staple DMG fixture\0\x01\x02"
    write_bytes(candidate / DMG_NAME, dmg_bytes, 0o644)
    dmg_sha = digest(dmg_bytes)
    write_bytes(candidate / "pre-staple.sha256", f"{dmg_sha}  {DMG_NAME}\n".encode("ascii"), 0o644)

    signature_verification = {
        "candidateCommit": COMMIT,
        "candidateJSONSHA256": digest(candidate_json),
        "certificate": {
            "notAfter": "Jul 15 12:00:00 2027 GMT",
            "notBefore": "Jul 15 12:00:00 2026 GMT",
            "sha256": CERTIFICATE_SHA256,
            "trust": "valid",
        },
        "components": [{"fixture": True}],
        "evidenceType": "signature-verification",
        "product": "UtterInk",
        "schemaVersion": 1,
        "signedAppTreeSHA256": "cd" * 32,
        "status": "valid",
        "teamID": TEAM,
        "treeAlgorithm": "utterink-logical-tree-v1",
        "unsignedBuildEvidenceSHA256": "de" * 32,
    }
    signature_bytes = write_json(candidate / "signature-verification.json", signature_verification, 0o644)
    inspection = {
        "architecture": "arm64",
        "buildNumber": "1",
        "bundleIdentifier": "dev.utterink.UtterInk",
        "dmgFilename": DMG_NAME,
        "dmgSHA256": dmg_sha,
        "machOCount": 3,
        "manifest": ["Applications -> /Applications", "UtterInk.app directory"],
        "minimumSystemVersion": "14.0",
        "mode": "signed",
        "product": "UtterInk",
        "signature": "developer-id",
        "status": "valid",
        "version": "0.1.0",
    }
    signing_evidence = {
        "dmgFilename": DMG_NAME,
        "dmgSHA256": dmg_sha,
        "evidenceType": "signed-pre-staple-dmg",
        "inspection": inspection,
        "product": "UtterInk",
        "schemaVersion": 1,
        "signatureVerificationSHA256": digest(signature_bytes),
        "status": "valid",
        "teamID": TEAM,
    }
    write_json(candidate / "signing-evidence.json", signing_evidence, 0o644)

    receipt = bindings / "binding.json"
    write_json(receipt, make_profile_receipt(now), 0o600)
    request = requests / "request.json"
    return fixture, candidate, receipt, request


def prepare(fixture: Path, candidate: Path, receipt: Path, output: Path) -> subprocess.CompletedProcess[str]:
    return run(
        fixture / "Scripts" / "release" / PREPARER.name,
        fixture,
        "prepare",
        "--candidate",
        str(candidate),
        "--apple-team-id",
        TEAM,
        "--profile-binding-receipt",
        str(receipt),
        "--output",
        str(output),
    )


def approval_for(request: dict[str, object], now: datetime) -> dict[str, object]:
    return {
        "action": "apple-notarization-upload",
        "requestID": request["requestID"],
        "product": "UtterInk",
        "appleTeamID": request["appleTeamID"],
        "preStapleDMGSHA256": request["preStapleDMG"]["sha256"],  # type: ignore[index]
        "candidateCommit": request["candidateCommit"],
        "profileBindingReceiptSHA256": request["profileBindingReceiptSHA256"],
        "attempt": 1,
        "approvedAt": iso(now - timedelta(minutes=1)),
        "expiresAt": iso(now + timedelta(minutes=20)),
    }


def validate_approval(fixture: Path, request: Path, approval: Path) -> subprocess.CompletedProcess[str]:
    return run(
        fixture / "Scripts" / "release" / PREPARER.name,
        fixture,
        "validate-approval",
        "--request",
        str(request),
        "--approval",
        str(approval),
    )


for required in (PREPARER, RESULT_VERIFIER, APPROVAL_SCHEMA, PROFILE_SCHEMA):
    if not required.is_file():
        fail(f"required Task 5 file does not exist: {required.relative_to(ROOT)}")

for ignored_class in (
    ".release-requests/example.request.json",
    ".release-approvals/example.approval.json",
    ".release-approvals/example.consumed.json",
    ".notary-profile-bindings/example.receipt.json",
    ".release-work/notarization/submission.notarytool.json",
    ".release-work/notarization/complete.notarytool.log",
):
    ignored = subprocess.run(
        ["/usr/bin/git", "-C", str(ROOT), "check-ignore", "-q", "--", ignored_class],
        env=environment(),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if ignored.returncode != 0:
        fail(f"local notarization record class is not ignored: {ignored_class}")

approval_schema = schema_contract(APPROVAL_SCHEMA, APPROVAL_KEYS)
profile_schema = schema_contract(PROFILE_SCHEMA, PROFILE_KEYS)
if approval_schema["properties"]["action"].get("const") != "apple-notarization-upload":  # type: ignore[index,union-attr]
    fail("approval action schema drifted")
if approval_schema["properties"]["attempt"].get("const") != 1:  # type: ignore[index,union-attr]
    fail("approval attempt schema drifted")
if profile_schema["properties"]["schemaVersion"].get("const") != 1:  # type: ignore[index,union-attr]
    fail("profile binding schema version drifted")
timestamp_pattern = r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"
for timestamp_key in ("validatedAt", "expiresAt"):
    if profile_schema["properties"][timestamp_key].get("pattern") != timestamp_pattern:  # type: ignore[index,union-attr]
        fail("profile receipt timestamp contract drifted")

for helper in (PREPARER, RESULT_VERIFIER):
    try:
        tree = ast.parse(helper.read_text(encoding="utf-8"), filename=str(helper))
    except (OSError, UnicodeError, SyntaxError):
        fail(f"helper is not valid isolated Python: {helper.name}")
    forbidden_imports = {"socket", "subprocess", "http", "urllib.request", "random"}
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            names = {alias.name for alias in node.names}
        elif isinstance(node, ast.ImportFrom) and node.module is not None:
            names = {node.module}
        else:
            continue
        if any(name in forbidden_imports or name.partition(".")[0] in {"socket", "subprocess", "http"} for name in names):
            fail(f"offline helper imports a network/process module: {helper.name}")
if "secrets.token_bytes(32).hex()" not in PREPARER.read_text(encoding="utf-8"):
    fail("request preparer does not generate exactly 32 CSPRNG bytes")

with tempfile.TemporaryDirectory(prefix="utterink-notarization-gate-tests-") as temporary:
    temporary_path = Path(temporary).resolve()
    now = datetime.now(timezone.utc).replace(microsecond=0)
    fixture, candidate, receipt, request_path = make_fixture(temporary_path, now)

    result = prepare(fixture, candidate, receipt, request_path)
    if result.returncode != 0 or result.stderr or result.stdout != str(request_path) + "\n":
        fail(f"valid request preparation failed: {result.stderr.strip()}")
    if stat.S_IMODE(os.lstat(request_path).st_mode) != 0o400 or request_path.is_symlink():
        fail("request summary is not an immutable owner-only regular file")
    request_bytes = request_path.read_bytes()
    request = json.loads(request_bytes)
    if request_bytes != canonical(request) or set(request) != REQUEST_KEYS:
        fail("request summary is not canonical with exact keys")
    if (
        request["schemaVersion"] != 1
        or request["requestType"] != "apple-notarization-request"
        or request["product"] != "UtterInk"
        or request["candidateCommit"] != COMMIT
        or request["candidateTree"] != TREE
        or request["appleTeamID"] != TEAM
        or request["attempt"] != 1
        or request["statement"] != STATEMENT
        or re.fullmatch(r"[0-9a-f]{64}", request["requestID"]) is None
    ):
        fail("request summary identity is not exact")
    if set(request["preStapleDMG"]) != {"filename", "sizeBytes", "sha256"}:
        fail("request DMG binding keys drifted")
    if set(request["signatureVerification"]) != {"evidenceSHA256", "status", "teamID"}:
        fail("request signature binding keys drifted")
    if request["preStapleDMG"]["sizeBytes"] != (candidate / DMG_NAME).stat().st_size:
        fail("request did not bind the DMG byte length")
    if request["profileBindingReceiptSHA256"] != digest(receipt.read_bytes()):
        fail("request did not bind the profile receipt bytes")
    if request["signatureVerification"]["evidenceSHA256"] != digest((candidate / "signing-evidence.json").read_bytes()):
        fail("request did not bind the signed-DMG evidence")

    second_request = fixture / ".release-requests" / "second.json"
    second = prepare(fixture, candidate, receipt, second_request)
    if second.returncode != 0:
        fail("second request preparation failed")
    if json.loads(second_request.read_text(encoding="utf-8"))["requestID"] == request["requestID"]:
        fail("request IDs were reused")

    preexisting_request = fixture / ".release-requests" / "preexisting.json"
    write_bytes(preexisting_request, b"preserve\n", 0o400)
    expect_failure(prepare(fixture, candidate, receipt, preexisting_request), "preexisting request output")
    if preexisting_request.read_bytes() != b"preserve\n":
        fail("preparer changed a preexisting request output")

    outside_request = fixture / "outside-request.json"
    expect_failure(prepare(fixture, candidate, receipt, outside_request), "request outside ignored directory", output=outside_request)
    approval_output = fixture / ".release-approvals" / "preparer-created.json"
    invalid_prepare = run(
        fixture / "Scripts" / "release" / PREPARER.name,
        fixture,
        "prepare",
        "--candidate",
        str(candidate),
        "--apple-team-id",
        TEAM,
        "--profile-binding-receipt",
        str(receipt),
        "--approval",
        str(approval_output),
    )
    expect_failure(invalid_prepare, "preparer approval option", output=approval_output)

    changed_fixture, changed_candidate, changed_receipt, changed_output = make_fixture(temporary_path / "changed-dmg", now)
    with (changed_candidate / DMG_NAME).open("ab") as handle:
        handle.write(b"changed")
    expect_failure(
        prepare(changed_fixture, changed_candidate, changed_receipt, changed_output),
        "changed DMG",
        output=changed_output,
    )

    bad_receipt_fixture, bad_receipt_candidate, bad_receipt, bad_receipt_output = make_fixture(
        temporary_path / "bad-receipt", now
    )
    bad_receipt_value = json.loads(bad_receipt.read_text(encoding="utf-8"))
    bad_receipt_value["selfSHA256"] = "65" * 32
    write_json(bad_receipt, bad_receipt_value, 0o600)
    expect_failure(
        prepare(bad_receipt_fixture, bad_receipt_candidate, bad_receipt, bad_receipt_output),
        "profile receipt self hash",
        output=bad_receipt_output,
    )

    long_fixture, long_candidate, long_receipt, long_output = make_fixture(temporary_path / "long-receipt", now)
    long_value = json.loads(long_receipt.read_text(encoding="utf-8"))
    long_value["expiresAt"] = iso(now - timedelta(minutes=2) + timedelta(hours=25))
    without_self = dict(long_value)
    without_self.pop("selfSHA256")
    long_value["selfSHA256"] = digest(canonical(without_self))
    write_json(long_receipt, long_value, 0o600)
    expect_failure(
        prepare(long_fixture, long_candidate, long_receipt, long_output),
        "profile receipt non-24-hour window",
        output=long_output,
    )

    readable_fixture, readable_candidate, readable_receipt, readable_output = make_fixture(
        temporary_path / "readable-receipt", now
    )
    readable_receipt.chmod(0o644)
    expect_failure(
        prepare(readable_fixture, readable_candidate, readable_receipt, readable_output),
        "readable profile receipt",
        output=readable_output,
    )

    approval_path = fixture / ".release-approvals" / "approval.json"
    approval = approval_for(request, now)
    approval_bytes = write_json(approval_path, approval, 0o600)
    validated = validate_approval(fixture, request_path, approval_path)
    if validated.returncode != 0 or validated.stderr or validated.stdout != digest(approval_bytes) + "\n":
        fail(f"valid approval failed: {validated.stderr.strip()}")

    offset_approval = dict(approval)
    plus_eight = timezone(timedelta(hours=8))
    offset_approval["approvedAt"] = (now - timedelta(minutes=1)).astimezone(plus_eight).isoformat(timespec="seconds")
    offset_approval["expiresAt"] = (now + timedelta(minutes=20)).astimezone(plus_eight).isoformat(timespec="seconds")
    offset_path = fixture / ".release-approvals" / "offset-time.json"
    offset_bytes = write_json(offset_path, offset_approval, 0o600)
    offset_result = validate_approval(fixture, request_path, offset_path)
    if offset_result.returncode != 0 or offset_result.stdout != digest(offset_bytes) + "\n":
        fail("valid RFC3339 offset approval was rejected")

    readable_request = fixture / ".release-requests" / "readable-request.json"
    write_bytes(readable_request, request_bytes, 0o600)
    expect_failure(
        validate_approval(fixture, readable_request, approval_path),
        "request with writable mode",
    )
    symlink_request = fixture / ".release-requests" / "symlink-request.json"
    symlink_request.symlink_to(request_path)
    expect_failure(
        validate_approval(fixture, symlink_request, approval_path),
        "symlink request",
    )
    hardlink_request_source = fixture / ".release-requests" / "hardlink-request-source.json"
    hardlink_request = fixture / ".release-requests" / "hardlink-request.json"
    write_bytes(hardlink_request_source, request_bytes, 0o400)
    os.link(hardlink_request_source, hardlink_request)
    expect_failure(
        validate_approval(fixture, hardlink_request, approval_path),
        "hardlinked request",
    )

    mutations: list[tuple[str, dict[str, object]]] = []
    for label, key, value in (
        ("wrong-action", "action", "apple-notarization-retry"),
        ("wrong-request", "requestID", "98" * 32),
        ("wrong-product", "product", "Other"),
        ("wrong-team", "appleTeamID", "ZZZZZ99999"),
        ("wrong-dmg", "preStapleDMGSHA256", "87" * 32),
        ("wrong-commit", "candidateCommit", "76543210fedcba9876543210fedcba9876543210"),
        ("wrong-profile", "profileBindingReceiptSHA256", "76" * 32),
        ("wrong-attempt", "attempt", 2),
    ):
        changed = dict(approval)
        changed[key] = value
        mutations.append((label, changed))
    extra = dict(approval)
    extra["unexpected"] = True
    mutations.append(("unexpected-field", extra))
    future = dict(approval)
    future["approvedAt"] = iso(now + timedelta(minutes=2))
    future["expiresAt"] = iso(now + timedelta(minutes=20))
    mutations.append(("future-approval", future))
    expired = dict(approval)
    expired["approvedAt"] = iso(now - timedelta(minutes=31))
    expired["expiresAt"] = iso(now - timedelta(seconds=1))
    mutations.append(("expired-approval", expired))
    too_long = dict(approval)
    too_long["approvedAt"] = iso(now - timedelta(minutes=1))
    too_long["expiresAt"] = iso(now + timedelta(minutes=30))
    mutations.append(("approval-over-30m", too_long))

    for label, changed in mutations:
        path = fixture / ".release-approvals" / f"{label}.json"
        write_json(path, changed, 0o600)
        expect_failure(validate_approval(fixture, request_path, path), label)

    pretty = fixture / ".release-approvals" / "noncanonical.json"
    write_bytes(pretty, json.dumps(approval, indent=2).encode("utf-8") + b"\n", 0o600)
    expect_failure(validate_approval(fixture, request_path, pretty), "noncanonical approval")
    duplicate = fixture / ".release-approvals" / "duplicate.json"
    duplicate_data = approval_bytes.replace(b'"action":', b'"action":"apple-notarization-upload","action":', 1)
    write_bytes(duplicate, duplicate_data, 0o600)
    expect_failure(validate_approval(fixture, request_path, duplicate), "duplicate approval key")
    readable = fixture / ".release-approvals" / "readable.json"
    write_bytes(readable, approval_bytes, 0o644)
    expect_failure(validate_approval(fixture, request_path, readable), "readable approval")
    symlink = fixture / ".release-approvals" / "symlink.json"
    symlink.symlink_to(approval_path)
    expect_failure(validate_approval(fixture, request_path, symlink), "symlink approval")
    hardlink_approval_source = fixture / ".release-approvals" / "hardlink-source.json"
    hardlink_approval = fixture / ".release-approvals" / "hardlink.json"
    write_bytes(hardlink_approval_source, approval_bytes, 0o600)
    os.link(hardlink_approval_source, hardlink_approval)
    expect_failure(validate_approval(fixture, request_path, hardlink_approval), "hardlinked approval")

    placeholder_request = fixture / ".release-requests" / "placeholder.json"
    placeholder = dict(request)
    placeholder["requestID"] = "0" * 64
    write_json(placeholder_request, placeholder, 0o400)
    placeholder_approval = dict(approval)
    placeholder_approval["requestID"] = "0" * 64
    placeholder_approval_path = fixture / ".release-approvals" / "placeholder.json"
    write_json(placeholder_approval_path, placeholder_approval, 0o600)
    expect_failure(validate_approval(fixture, placeholder_request, placeholder_approval_path), "placeholder request")

    submission_id = "123e4567-e89b-12d3-a456-426614174000"
    dmg_sha = request["preStapleDMG"]["sha256"]
    submission = {"id": submission_id, "message": "Successfully uploaded file", "status": "Accepted"}
    log = {
        "archiveFilename": DMG_NAME,
        "issues": [],
        "jobId": submission_id,
        "logFormatVersion": 1,
        "sha256": dmg_sha,
        "status": "Accepted",
        "statusCode": 0,
        "statusSummary": "Ready for distribution",
        "ticketContents": [{"path": "UtterInk.app"}],
        "uploadDate": iso(now - timedelta(minutes=1)),
    }
    raw_dir = fixture / ".release-work" / "notary"
    raw_dir.mkdir(mode=0o700)
    submission_path = raw_dir / "submission.json"
    log_path = raw_dir / "log.json"
    output = raw_dir / "review.json"
    write_json(submission_path, submission, 0o600)
    write_json(log_path, log, 0o600)
    fake_bin = fixture / "fake-bin"
    fake_bin.mkdir()
    marker = fixture / "network-invoked"
    fake_xcrun = fake_bin / "xcrun"
    fake_xcrun.write_text(f"#!/bin/sh\ntouch '{marker}'\nexit 99\n", encoding="utf-8")
    fake_xcrun.chmod(0o755)
    verified = run(
        fixture / "Scripts" / "release" / RESULT_VERIFIER.name,
        fixture,
        "--submission",
        str(submission_path),
        "--log",
        str(log_path),
        "--expected-dmg-sha256",
        str(dmg_sha),
        "--output",
        str(output),
        extra_env={"PATH": str(fake_bin)},
    )
    if verified.returncode != 0 or verified.stderr:
        fail(f"accepted notarization result failed: {verified.stderr.strip()}")
    reviewed = json.loads(output.read_text(encoding="utf-8"))
    if verified.stdout.encode("utf-8") != canonical(reviewed) or output.read_bytes() != canonical(reviewed):
        fail("result review was not emitted canonically")
    if reviewed.get("status") != "Accepted" or reviewed.get("warnings") != [] or reviewed.get("automaticRetry") is not False:
        fail("accepted result review is incomplete")
    if (
        reviewed.get("submissionResultSHA256") != digest(submission_path.read_bytes())
        or reviewed.get("notarizationLogSHA256") != digest(log_path.read_bytes())
        or reviewed.get("issueCount") != 0
    ):
        fail("result review did not bind the complete raw Apple records")
    if stat.S_IMODE(os.lstat(output).st_mode) != 0o600 or marker.exists():
        fail("result verifier changed external state or wrote unsafe evidence")

    null_issue_log = dict(log)
    null_issue_log["issues"] = None
    null_issue_path = raw_dir / "null-issues-log.json"
    null_issue_output = raw_dir / "null-issues-review.json"
    write_json(null_issue_path, null_issue_log, 0o600)
    null_issue_result = run(
        fixture / "Scripts" / "release" / RESULT_VERIFIER.name,
        fixture,
        "--submission",
        str(submission_path),
        "--log",
        str(null_issue_path),
        "--expected-dmg-sha256",
        str(dmg_sha),
        "--output",
        str(null_issue_output),
    )
    if null_issue_result.returncode != 0 or json.loads(null_issue_output.read_text())["warnings"] != []:
        fail("accepted Apple null issues value was rejected")

    preexisting_output = raw_dir / "preexisting-review.json"
    write_bytes(preexisting_output, b"preserve\n", 0o600)
    preexisting_result = run(
        fixture / "Scripts" / "release" / RESULT_VERIFIER.name,
        fixture,
        "--submission",
        str(submission_path),
        "--log",
        str(log_path),
        "--expected-dmg-sha256",
        str(dmg_sha),
        "--output",
        str(preexisting_output),
    )
    expect_failure(preexisting_result, "preexisting result output")
    if preexisting_output.read_bytes() != b"preserve\n":
        fail("result verifier changed a preexisting output")

    warning_log = dict(log)
    warning_log["issues"] = [{
        "severity": "warning",
        "code": "legacy-format",
        "path": "UtterInk.app/Contents/MacOS/UtterInk",
        "message": "A reviewer-visible fixture warning.",
        "architecture": "arm64",
        "docUrl": "https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution",
    }]
    warning_path = raw_dir / "warning-log.json"
    warning_output = raw_dir / "warning-review.json"
    write_json(warning_path, warning_log, 0o600)
    warning_result = run(
        fixture / "Scripts" / "release" / RESULT_VERIFIER.name,
        fixture,
        "--submission",
        str(submission_path),
        "--log",
        str(warning_path),
        "--expected-dmg-sha256",
        str(dmg_sha),
        "--output",
        str(warning_output),
    )
    if warning_result.returncode != 0:
        fail("accepted warning result was rejected")
    warning_review = json.loads(warning_output.read_text(encoding="utf-8"))
    if warning_review.get("warningCount") != 1 or len(warning_review.get("warnings", [])) != 1:
        fail("accepted warnings were not reviewer-visible")

    result_failures: list[tuple[str, dict[str, object], dict[str, object], str]] = []
    rejected_submission = dict(submission)
    rejected_submission["status"] = "Rejected"
    result_failures.append(("rejected-submission", rejected_submission, log, str(dmg_sha)))
    rejected_log = dict(log)
    rejected_log["status"] = "Rejected"
    rejected_log["statusCode"] = 4000
    result_failures.append(("rejected-log", submission, rejected_log, str(dmg_sha)))
    error_log = dict(log)
    error_log["issues"] = [{"severity": "error", "message": "Invalid signature"}]
    result_failures.append(("error-issue", submission, error_log, str(dmg_sha)))
    invalid_log = dict(log)
    invalid_log["issues"] = [{"severity": "invalid", "message": "Invalid bundle"}]
    result_failures.append(("invalid-issue", submission, invalid_log, str(dmg_sha)))
    wrong_id_log = dict(log)
    wrong_id_log["jobId"] = "223e4567-e89b-12d3-a456-426614174000"
    result_failures.append(("job-id-mismatch", submission, wrong_id_log, str(dmg_sha)))
    result_failures.append(("dmg-hash-mismatch", submission, log, "ef" * 32))
    incomplete_log = dict(log)
    incomplete_log.pop("ticketContents")
    result_failures.append(("incomplete-log", submission, incomplete_log, str(dmg_sha)))
    null_ticket_log = dict(log)
    null_ticket_log["ticketContents"] = [None]
    result_failures.append(("null-ticket-item", submission, null_ticket_log, str(dmg_sha)))
    empty_ticket_log = dict(log)
    empty_ticket_log["ticketContents"] = [{}]
    result_failures.append(("empty-ticket-item", submission, empty_ticket_log, str(dmg_sha)))
    invalid_upload_date_log = dict(log)
    invalid_upload_date_log["uploadDate"] = "not-a-time"
    result_failures.append(("invalid-upload-date", submission, invalid_upload_date_log, str(dmg_sha)))
    impossible_upload_date_log = dict(log)
    impossible_upload_date_log["uploadDate"] = "2026-02-30T00:00:00Z"
    result_failures.append(("impossible-upload-date", submission, impossible_upload_date_log, str(dmg_sha)))
    unreasonable_upload_offset_log = dict(log)
    unreasonable_upload_offset_log["uploadDate"] = "2026-07-15T00:11:00+15:00"
    result_failures.append(("unreasonable-upload-offset", submission, unreasonable_upload_offset_log, str(dmg_sha)))
    unsanitized_log = dict(log)
    unsanitized_log["issues"] = [{"severity": "warning", "message": "See /" + "Users/example/private path"}]
    result_failures.append(("unsanitized-warning", submission, unsanitized_log, str(dmg_sha)))

    for label, submit_value, log_value, expected_hash in result_failures:
        submit_path = raw_dir / f"{label}-submit.json"
        issue_log_path = raw_dir / f"{label}-log.json"
        failure_output = raw_dir / f"{label}-review.json"
        write_json(submit_path, submit_value, 0o600)
        write_json(issue_log_path, log_value, 0o600)
        failed = run(
            fixture / "Scripts" / "release" / RESULT_VERIFIER.name,
            fixture,
            "--submission",
            str(submit_path),
            "--log",
            str(issue_log_path),
            "--expected-dmg-sha256",
            expected_hash,
            "--output",
            str(failure_output),
        )
        expect_failure(failed, label, output=failure_output)

print("notarization gate tests passed")
