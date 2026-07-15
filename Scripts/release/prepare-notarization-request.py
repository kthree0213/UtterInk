#!/usr/bin/env python3
from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import stat
import sys
from typing import NoReturn


MAX_JSON_BYTES = 4 * 1024 * 1024
MAX_TEXT_BYTES = 16 * 1024
REQUEST_DIRECTORY = ".release-requests"
APPROVAL_DIRECTORY = ".release-approvals"
PROFILE_DIRECTORY = ".notary-profile-bindings"
DMG_FILENAME = "UtterInk-0.1.0-arm64.dmg"
REQUEST_STATEMENT = "one upload attempt only; rejection or any file change requires new approval."
HEX_40 = re.compile(r"[0-9a-f]{40}\Z")
HEX_64 = re.compile(r"[0-9a-f]{64}\Z")
TEAM_ID = re.compile(r"[A-Z0-9]{10}\Z")
SAFE_FILENAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}[.]json\Z")
RFC3339 = re.compile(
    r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
    r"(?:[.][0-9]{1,9})?(?:Z|[+-][0-9]{2}:[0-9]{2})\Z"
)
UTC_SECONDS = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\Z")

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
CANDIDATE_KEYS = {
    "schemaVersion",
    "evidenceType",
    "product",
    "source",
    "release",
    "toolchain",
    "packageResolution",
    "policies",
    "checks",
}
SIGNATURE_KEYS = {
    "candidateCommit",
    "candidateJSONSHA256",
    "certificate",
    "components",
    "evidenceType",
    "product",
    "schemaVersion",
    "signedAppTreeSHA256",
    "status",
    "teamID",
    "treeAlgorithm",
    "unsignedBuildEvidenceSHA256",
}
SIGNED_DMG_KEYS = {
    "dmgFilename",
    "dmgSHA256",
    "evidenceType",
    "inspection",
    "product",
    "schemaVersion",
    "signatureVerificationSHA256",
    "status",
    "teamID",
}
INSPECTION_KEYS = {
    "architecture",
    "buildNumber",
    "bundleIdentifier",
    "dmgFilename",
    "dmgSHA256",
    "machOCount",
    "manifest",
    "minimumSystemVersion",
    "mode",
    "product",
    "signature",
    "status",
    "version",
}


class GateError(Exception):
    def __init__(self, category: str):
        super().__init__(category)
        self.category = category


def reject(category: str) -> NoReturn:
    raise GateError(category)


def canonical(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            reject("duplicate-json-key")
        result[key] = value
    return result


def parse_json(data: bytes, category: str) -> object:
    try:
        return json.loads(data.decode("utf-8", errors="strict"), object_pairs_hook=unique_object)
    except GateError:
        raise
    except (UnicodeError, json.JSONDecodeError):
        reject(category)


def exact_object(value: object, keys: set[str], category: str) -> dict[str, object]:
    if type(value) is not dict or set(value) != keys:
        reject(category)
    return value


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


def checked_regular(
    path: Path,
    *,
    category: str,
    max_bytes: int,
    exact_mode: int | None = None,
) -> tuple[bytes, os.stat_result]:
    descriptor = -1
    try:
        before = os.lstat(path)
        mode = stat.S_IMODE(before.st_mode)
        if (
            not stat.S_ISREG(before.st_mode)
            or stat.S_ISLNK(before.st_mode)
            or before.st_uid != os.geteuid()
            or before.st_nlink != 1
            or before.st_size <= 0
            or before.st_size > max_bytes
            or (exact_mode is not None and mode != exact_mode)
            or (exact_mode is None and mode & 0o022)
        ):
            reject(category)
        descriptor = os.open(
            path,
            os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
        )
        opened = os.fstat(descriptor)
        if fingerprint(before) != fingerprint(opened):
            reject(category)
        chunks: list[bytes] = []
        remaining = max_bytes + 1
        while remaining:
            chunk = os.read(descriptor, min(1024 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        after = os.fstat(descriptor)
        data = b"".join(chunks)
        if fingerprint(opened) != fingerprint(after) or not data or len(data) > max_bytes:
            reject(category)
        return data, after
    except GateError:
        raise
    except OSError:
        reject(category)
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def hash_regular(path: Path, category: str) -> tuple[str, int]:
    descriptor = -1
    try:
        before = os.lstat(path)
        if (
            not stat.S_ISREG(before.st_mode)
            or stat.S_ISLNK(before.st_mode)
            or before.st_uid != os.geteuid()
            or before.st_nlink != 1
            or before.st_size <= 0
            or before.st_mode & 0o022
        ):
            reject(category)
        descriptor = os.open(
            path,
            os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
        )
        opened = os.fstat(descriptor)
        if fingerprint(before) != fingerprint(opened):
            reject(category)
        value = hashlib.sha256()
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            value.update(chunk)
        after = os.fstat(descriptor)
        if fingerprint(opened) != fingerprint(after):
            reject(category)
        return value.hexdigest(), after.st_size
    except GateError:
        raise
    except OSError:
        reject(category)
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def repository_root() -> Path:
    try:
        script = Path(__file__).resolve(strict=True)
        root = script.parents[2]
        scripts = (root / "Scripts" / "release").resolve(strict=True)
        if script.parent != scripts:
            reject("unsafe-script-location")
        return root
    except (IndexError, OSError, ValueError):
        reject("unsafe-script-location")


def absolute_lexical(path: Path) -> Path:
    return Path(os.path.abspath(os.fspath(path)))


def require_local_parent(path: Path, root: Path, directory_name: str, category: str) -> Path:
    absolute = absolute_lexical(path)
    expected_parent = root / directory_name
    if absolute.parent != expected_parent or SAFE_FILENAME.fullmatch(absolute.name) is None:
        reject(category)
    try:
        metadata = os.lstat(expected_parent)
    except FileNotFoundError:
        if directory_name != REQUEST_DIRECTORY:
            reject(category)
        try:
            os.mkdir(expected_parent, 0o700)
            os.chmod(expected_parent, 0o700)
            metadata = os.lstat(expected_parent)
        except OSError:
            reject(category)
    except OSError:
        reject(category)
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or stat.S_IMODE(metadata.st_mode) != 0o700
    ):
        reject(category)
    return absolute


def write_exclusive(path: Path, data: bytes, mode: int, category: str) -> None:
    descriptor = -1
    created = False
    created_identity: tuple[int, int] | None = None
    try:
        descriptor = os.open(
            path,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            mode,
        )
        created = True
        opened = os.fstat(descriptor)
        created_identity = (opened.st_dev, opened.st_ino)
        if not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.geteuid() or opened.st_nlink != 1:
            reject(category)
        offset = 0
        while offset < len(data):
            written = os.write(descriptor, data[offset:])
            if written <= 0:
                reject(category)
            offset += written
        os.fchmod(descriptor, mode)
        os.fsync(descriptor)
        final = os.fstat(descriptor)
        named = os.lstat(path)
        if (
            (final.st_dev, final.st_ino) != created_identity
            or (named.st_dev, named.st_ino) != created_identity
            or stat.S_IMODE(final.st_mode) != mode
            or final.st_size != len(data)
        ):
            reject(category)
    except GateError:
        raise
    except OSError:
        reject(category)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if created and sys.exc_info()[0] is not None and created_identity is not None:
            try:
                current = os.lstat(path)
                if (current.st_dev, current.st_ino) == created_identity:
                    os.unlink(path)
            except OSError:
                pass


def checked_hex(value: object, pattern: re.Pattern[str], category: str) -> str:
    if type(value) is not str or pattern.fullmatch(value) is None:
        reject(category)
    if value in {"0" * len(value), "f" * len(value)}:
        reject("placeholder-value")
    return value


def checked_team(value: object, category: str) -> str:
    if type(value) is not str or TEAM_ID.fullmatch(value) is None:
        reject(category)
    return value


def parse_rfc3339(value: object, category: str, *, utc_seconds: bool = False) -> datetime:
    if type(value) is not str or (UTC_SECONDS if utc_seconds else RFC3339).fullmatch(value) is None:
        reject(category)
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError:
        reject(category)
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        reject(category)
    return parsed.astimezone(timezone.utc)


def validated_profile_receipt(path: Path, root: Path, expected_team: str, now: datetime) -> tuple[bytes, dict[str, object]]:
    checked_path = require_local_parent(path, root, PROFILE_DIRECTORY, "unsafe-profile-binding")
    data, _ = checked_regular(
        checked_path,
        category="unsafe-profile-binding",
        max_bytes=MAX_JSON_BYTES,
        exact_mode=0o600,
    )
    value = exact_object(parse_json(data, "invalid-profile-binding"), PROFILE_KEYS, "invalid-profile-binding")
    if data != canonical(value):
        reject("noncanonical-profile-binding")
    if value["schemaVersion"] != 1 or type(value["schemaVersion"]) is not int:
        reject("invalid-profile-binding")
    if checked_team(value["appleTeamID"], "invalid-profile-binding") != expected_team:
        reject("profile-team-mismatch")
    for key in (
        "bindingNonce",
        "signingCertificateSHA256",
        "profileNameSalt",
        "profileNameHashSHA256",
        "selfSHA256",
    ):
        checked_hex(value[key], HEX_64, "invalid-profile-binding")
    tool_version = value["notarytoolVersion"]
    if (
        type(tool_version) is not str
        or not tool_version
        or len(tool_version) > 256
        or any(ord(character) < 32 or ord(character) == 127 for character in tool_version)
    ):
        reject("invalid-profile-binding")
    validated_at = parse_rfc3339(value["validatedAt"], "invalid-profile-binding", utc_seconds=True)
    expires_at = parse_rfc3339(value["expiresAt"], "invalid-profile-binding", utc_seconds=True)
    if expires_at - validated_at != timedelta(hours=24):
        reject("invalid-profile-binding-window")
    if validated_at > now or expires_at <= now:
        reject("stale-profile-binding")
    payload = dict(value)
    self_hash = payload.pop("selfSHA256")
    if not secrets.compare_digest(str(self_hash), hashlib.sha256(canonical(payload)).hexdigest()):
        reject("profile-binding-hash-mismatch")
    return data, value


def validated_candidate(candidate: Path, team: str, receipt: dict[str, object]) -> dict[str, object]:
    candidate = absolute_lexical(candidate)
    try:
        candidate_metadata = os.lstat(candidate)
    except OSError:
        reject("unsafe-candidate")
    if (
        not stat.S_ISDIR(candidate_metadata.st_mode)
        or stat.S_ISLNK(candidate_metadata.st_mode)
        or candidate_metadata.st_uid != os.geteuid()
        or candidate_metadata.st_mode & 0o022
    ):
        reject("unsafe-candidate")

    candidate_bytes, _ = checked_regular(
        candidate / "candidate.json",
        category="unsafe-candidate-evidence",
        max_bytes=MAX_JSON_BYTES,
    )
    candidate_value = exact_object(
        parse_json(candidate_bytes, "invalid-candidate-evidence"),
        CANDIDATE_KEYS,
        "invalid-candidate-evidence",
    )
    if candidate_bytes != canonical(candidate_value):
        reject("noncanonical-candidate-evidence")
    if (
        candidate_value["schemaVersion"] != 1
        or type(candidate_value["schemaVersion"]) is not int
        or candidate_value["evidenceType"] != "release-candidate"
        or candidate_value["product"] != "UtterInk"
    ):
        reject("invalid-candidate-evidence")
    source = exact_object(candidate_value["source"], {"commit", "tree", "releaseTag", "clean"}, "invalid-candidate-evidence")
    commit = checked_hex(source["commit"], HEX_40, "invalid-candidate-evidence")
    tree = checked_hex(source["tree"], HEX_40, "invalid-candidate-evidence")
    if source["releaseTag"] != "v0.1.0" or source["clean"] is not True:
        reject("invalid-candidate-evidence")
    release = exact_object(
        candidate_value["release"],
        {
            "configuration",
            "marketingVersion",
            "buildNumber",
            "bundleIdentifier",
            "deploymentTarget",
            "architecture",
            "dmgFilename",
        },
        "invalid-candidate-evidence",
    )
    expected_release = {
        "configuration": "Release",
        "marketingVersion": "0.1.0",
        "buildNumber": "1",
        "bundleIdentifier": "dev.utterink.UtterInk",
        "deploymentTarget": "14.0",
        "architecture": "arm64",
        "dmgFilename": DMG_FILENAME,
    }
    if release != expected_release or any(type(item) is not str for item in release.values()):
        reject("invalid-candidate-evidence")

    signature_bytes, _ = checked_regular(
        candidate / "signature-verification.json",
        category="unsafe-signature-evidence",
        max_bytes=MAX_JSON_BYTES,
    )
    signature = exact_object(
        parse_json(signature_bytes, "invalid-signature-evidence"),
        SIGNATURE_KEYS,
        "invalid-signature-evidence",
    )
    if signature_bytes != canonical(signature):
        reject("noncanonical-signature-evidence")
    certificate = exact_object(
        signature["certificate"],
        {"notAfter", "notBefore", "sha256", "trust"},
        "invalid-signature-evidence",
    )
    certificate_hash = checked_hex(certificate["sha256"], HEX_64, "invalid-signature-evidence")
    if (
        signature["schemaVersion"] != 1
        or type(signature["schemaVersion"]) is not int
        or signature["evidenceType"] != "signature-verification"
        or signature["product"] != "UtterInk"
        or signature["status"] != "valid"
        or signature["teamID"] != team
        or signature["candidateCommit"] != commit
        or signature["candidateJSONSHA256"] != hashlib.sha256(candidate_bytes).hexdigest()
        or signature["treeAlgorithm"] != "utterink-logical-tree-v1"
        or certificate["trust"] != "valid"
        or certificate_hash != receipt["signingCertificateSHA256"]
        or type(signature["components"]) is not list
        or not signature["components"]
    ):
        reject("signature-binding-mismatch")
    for key in ("candidateJSONSHA256", "signedAppTreeSHA256", "unsignedBuildEvidenceSHA256"):
        checked_hex(signature[key], HEX_64, "invalid-signature-evidence")

    dmg_path = candidate / DMG_FILENAME
    dmg_hash, dmg_size = hash_regular(dmg_path, "unsafe-pre-staple-dmg")
    pre_staple_bytes, _ = checked_regular(
        candidate / "pre-staple.sha256",
        category="unsafe-pre-staple-evidence",
        max_bytes=MAX_TEXT_BYTES,
    )
    if pre_staple_bytes != f"{dmg_hash}  {DMG_FILENAME}\n".encode("ascii"):
        reject("pre-staple-hash-mismatch")

    signed_dmg_bytes, _ = checked_regular(
        candidate / "signing-evidence.json",
        category="unsafe-signed-dmg-evidence",
        max_bytes=MAX_JSON_BYTES,
    )
    signed_dmg = exact_object(
        parse_json(signed_dmg_bytes, "invalid-signed-dmg-evidence"),
        SIGNED_DMG_KEYS,
        "invalid-signed-dmg-evidence",
    )
    if signed_dmg_bytes != canonical(signed_dmg):
        reject("noncanonical-signed-dmg-evidence")
    inspection = exact_object(signed_dmg["inspection"], INSPECTION_KEYS, "invalid-signed-dmg-evidence")
    expected_inspection = {
        "architecture": "arm64",
        "buildNumber": "1",
        "bundleIdentifier": "dev.utterink.UtterInk",
        "dmgFilename": DMG_FILENAME,
        "dmgSHA256": dmg_hash,
        "manifest": ["Applications -> /Applications", "UtterInk.app directory"],
        "minimumSystemVersion": "14.0",
        "mode": "signed",
        "product": "UtterInk",
        "signature": "developer-id",
        "status": "valid",
        "version": "0.1.0",
    }
    if (
        signed_dmg["schemaVersion"] != 1
        or type(signed_dmg["schemaVersion"]) is not int
        or signed_dmg["evidenceType"] != "signed-pre-staple-dmg"
        or signed_dmg["product"] != "UtterInk"
        or signed_dmg["status"] != "valid"
        or signed_dmg["teamID"] != team
        or signed_dmg["dmgFilename"] != DMG_FILENAME
        or signed_dmg["dmgSHA256"] != dmg_hash
        or signed_dmg["signatureVerificationSHA256"] != hashlib.sha256(signature_bytes).hexdigest()
        or any(inspection.get(key) != value for key, value in expected_inspection.items())
        or type(inspection["machOCount"]) is not int
        or isinstance(inspection["machOCount"], bool)
        or inspection["machOCount"] < 1
    ):
        reject("signed-dmg-binding-mismatch")

    return {
        "commit": commit,
        "tree": tree,
        "dmgHash": dmg_hash,
        "dmgSize": dmg_size,
        "signingEvidenceHash": hashlib.sha256(signed_dmg_bytes).hexdigest(),
    }


def validate_request(value: object) -> dict[str, object]:
    request = exact_object(value, REQUEST_KEYS, "invalid-request-summary")
    if (
        request["schemaVersion"] != 1
        or type(request["schemaVersion"]) is not int
        or request["requestType"] != "apple-notarization-request"
        or request["product"] != "UtterInk"
        or request["attempt"] != 1
        or type(request["attempt"]) is not int
        or request["statement"] != REQUEST_STATEMENT
    ):
        reject("invalid-request-summary")
    checked_hex(request["requestID"], HEX_64, "invalid-request-summary")
    checked_hex(request["candidateCommit"], HEX_40, "invalid-request-summary")
    checked_hex(request["candidateTree"], HEX_40, "invalid-request-summary")
    checked_team(request["appleTeamID"], "invalid-request-summary")
    checked_hex(request["profileBindingReceiptSHA256"], HEX_64, "invalid-request-summary")
    dmg = exact_object(request["preStapleDMG"], {"filename", "sizeBytes", "sha256"}, "invalid-request-summary")
    if (
        dmg["filename"] != DMG_FILENAME
        or type(dmg["sizeBytes"]) is not int
        or isinstance(dmg["sizeBytes"], bool)
        or dmg["sizeBytes"] <= 0
    ):
        reject("invalid-request-summary")
    checked_hex(dmg["sha256"], HEX_64, "invalid-request-summary")
    signature = exact_object(
        request["signatureVerification"],
        {"evidenceSHA256", "status", "teamID"},
        "invalid-request-summary",
    )
    if signature["status"] != "valid" or signature["teamID"] != request["appleTeamID"]:
        reject("invalid-request-summary")
    checked_hex(signature["evidenceSHA256"], HEX_64, "invalid-request-summary")
    return request


def prepare_request(arguments: argparse.Namespace) -> Path:
    root = repository_root()
    team = checked_team(arguments.apple_team_id, "invalid-team-id")
    now = datetime.now(timezone.utc)
    receipt_bytes, receipt = validated_profile_receipt(
        Path(arguments.profile_binding_receipt),
        root,
        team,
        now,
    )
    candidate = validated_candidate(Path(arguments.candidate), team, receipt)
    request_id = secrets.token_bytes(32).hex()
    checked_hex(request_id, HEX_64, "request-id-generation-failed")
    summary = {
        "schemaVersion": 1,
        "requestType": "apple-notarization-request",
        "requestID": request_id,
        "product": "UtterInk",
        "candidateCommit": candidate["commit"],
        "candidateTree": candidate["tree"],
        "appleTeamID": team,
        "profileBindingReceiptSHA256": hashlib.sha256(receipt_bytes).hexdigest(),
        "preStapleDMG": {
            "filename": DMG_FILENAME,
            "sizeBytes": candidate["dmgSize"],
            "sha256": candidate["dmgHash"],
        },
        "signatureVerification": {
            "evidenceSHA256": candidate["signingEvidenceHash"],
            "status": "valid",
            "teamID": team,
        },
        "attempt": 1,
        "statement": REQUEST_STATEMENT,
    }
    validate_request(summary)
    output = require_local_parent(Path(arguments.output), root, REQUEST_DIRECTORY, "unsafe-request-output")
    write_exclusive(output, canonical(summary), 0o400, "request-write-failed")
    return output


def validate_approval(arguments: argparse.Namespace) -> str:
    root = repository_root()
    request_path = require_local_parent(Path(arguments.request), root, REQUEST_DIRECTORY, "unsafe-request-summary")
    request_bytes, _ = checked_regular(
        request_path,
        category="unsafe-request-summary",
        max_bytes=MAX_JSON_BYTES,
        exact_mode=0o400,
    )
    request_value = parse_json(request_bytes, "invalid-request-summary")
    request = validate_request(request_value)
    if request_bytes != canonical(request):
        reject("noncanonical-request-summary")

    approval_path = require_local_parent(Path(arguments.approval), root, APPROVAL_DIRECTORY, "unsafe-approval")
    approval_bytes, _ = checked_regular(
        approval_path,
        category="unsafe-approval",
        max_bytes=MAX_JSON_BYTES,
        exact_mode=0o600,
    )
    approval = exact_object(parse_json(approval_bytes, "invalid-approval"), APPROVAL_KEYS, "invalid-approval")
    if approval_bytes != canonical(approval):
        reject("noncanonical-approval")
    if (
        approval["action"] != "apple-notarization-upload"
        or approval["product"] != "UtterInk"
        or approval["attempt"] != 1
        or type(approval["attempt"]) is not int
    ):
        reject("invalid-approval")
    checked_hex(approval["requestID"], HEX_64, "invalid-approval")
    checked_team(approval["appleTeamID"], "invalid-approval")
    checked_hex(approval["preStapleDMGSHA256"], HEX_64, "invalid-approval")
    checked_hex(approval["candidateCommit"], HEX_40, "invalid-approval")
    checked_hex(approval["profileBindingReceiptSHA256"], HEX_64, "invalid-approval")
    expected = {
        "requestID": request["requestID"],
        "appleTeamID": request["appleTeamID"],
        "preStapleDMGSHA256": request["preStapleDMG"]["sha256"],  # type: ignore[index]
        "candidateCommit": request["candidateCommit"],
        "profileBindingReceiptSHA256": request["profileBindingReceiptSHA256"],
        "attempt": request["attempt"],
    }
    if any(approval[key] != value for key, value in expected.items()):
        reject("approval-request-mismatch")
    approved_at = parse_rfc3339(approval["approvedAt"], "invalid-approval-time")
    expires_at = parse_rfc3339(approval["expiresAt"], "invalid-approval-time")
    now = datetime.now(timezone.utc)
    if approved_at > now:
        reject("future-approval")
    if expires_at <= now:
        reject("expired-approval")
    duration = expires_at - approved_at
    if duration <= timedelta(0) or duration > timedelta(minutes=30):
        reject("invalid-approval-window")
    return hashlib.sha256(approval_bytes).hexdigest()


class Parser(argparse.ArgumentParser):
    def error(self, message: str) -> NoReturn:
        del message
        reject("invalid-arguments")


def parser() -> Parser:
    value = Parser(add_help=False)
    commands = value.add_subparsers(dest="command", required=True, parser_class=Parser)
    prepare = commands.add_parser("prepare", add_help=False)
    prepare.add_argument("--candidate", required=True)
    prepare.add_argument("--apple-team-id", required=True)
    prepare.add_argument("--profile-binding-receipt", required=True)
    prepare.add_argument("--output", required=True)
    approval = commands.add_parser("validate-approval", add_help=False)
    approval.add_argument("--request", required=True)
    approval.add_argument("--approval", required=True)
    return value


def main() -> int:
    try:
        arguments = parser().parse_args()
        if arguments.command == "prepare":
            output = prepare_request(arguments)
            print(output)
        elif arguments.command == "validate-approval":
            print(validate_approval(arguments))
        else:
            reject("invalid-arguments")
        return 0
    except GateError as error:
        print(f"notarization request error: {error.category}", file=sys.stderr)
        return 1
    except (OSError, UnicodeError, ValueError):
        print("notarization request error: internal-failure", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
