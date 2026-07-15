#!/usr/bin/env python3
from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import secrets
import stat
import sys
from typing import Callable, NoReturn


ROOT = Path(__file__).resolve().parents[2]
CANDIDATE_SCHEMA = ROOT / "docs/release/evidence-schema.json"
MANUAL_MATRIX = ROOT / "docs/release/manual-verification-matrix.md"
PUBLIC_README = ROOT / "README.md"
DMG_NAME = "UtterInk-0.1.0-arm64.dmg"
MANIFEST = ["Applications -> /Applications", "UtterInk.app directory"]
HEX40 = re.compile(r"[0-9a-f]{40}\Z")
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
TEAM_ID = re.compile(r"[A-Z0-9]{10}\Z")
REQUEST_ID = re.compile(r"[0-9a-f]{64}\Z")
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")
RFC3339 = re.compile(
    r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
    r"(?:[.][0-9]{1,9})?(?:Z|[+-][0-9]{2}:[0-9]{2})\Z"
)
MAX_RECORD_BYTES = 16 * 1024 * 1024
MAX_TOTAL_BYTES = 64 * 1024 * 1024

PRODUCT_ROWS = (
    "MR-01", "MR-02", "MR-03", "MR-04", "MR-05", "MR-06", "MR-07",
    "PM-01", "PM-02", "PM-03", "PM-04", "PM-05",
    "MD-01", "MD-02", "MD-03", "MD-04", "MD-05", "MD-06",
    "DD-01", "DD-02", "DD-03", "DD-04", "DD-05", "DD-06", "DD-07", "DD-08", "DD-09", "DD-10", "DD-11",
    "HI-01", "HI-02", "HI-03", "HI-04", "HI-05", "HI-06", "HI-07", "HI-08", "HI-09",
    "PV-01", "PV-02", "PV-03", "PV-04", "PV-05", "PV-06", "PV-07",
)
ACCESSIBILITY_ROWS = (
    "AX-01", "AX-02", "AX-03", "AX-04", "AX-05", "AX-06", "AX-07", "AX-08", "AX-09", "AX-10", "AX-11", "AX-12",
    "ST-01", "ST-02", "ST-03", "ST-04", "ST-05", "ST-06", "ST-07", "ST-08",
)
LOCAL_GATEKEEPER_ROWS = ("LG-01", "LG-02", "LG-03")
SECOND_MAC_ROWS = ("SM-01", "SM-02", "SM-03", "SM-04", "SM-05", "SM-06", "SM-07")

GENERIC_CHECKS = {
    "history-scan.json": ("history-scan", ("full-history", "secret-scan", "private-data-scan")),
    "legal-review.json": ("legal-review", ("source-ip", "provenance", "license", "model-notice")),
    "automated-checks.json": ("automated-checks", ("tests", "build", "unsigned-ci-smoke")),
    "identity-review.json": ("identity-review", ("identity-approval", "competitor-similarity", "trademark-risk")),
    "documentation-review.json": (
        "documentation-review",
        ("privacy", "security", "docs", "links", "markdown", "readme-en-render", "readme-zh-render", "privacy-preview"),
    ),
}
MANUAL_RECORDS = {
    "manual-verification-matrix.json": ("manual-verification-matrix", PRODUCT_ROWS),
    "accessibility-matrix.json": ("accessibility-matrix", ACCESSIBILITY_ROWS),
    "local-gatekeeper.json": ("local-gatekeeper", LOCAL_GATEKEEPER_ROWS),
    "second-mac-gatekeeper.json": ("second-mac-gatekeeper", SECOND_MAC_ROWS),
}

FIXED_GATES = {
    "candidate.json": ("candidate", "toolchain", "dependency-lock"),
    "unsigned-build-evidence.json": ("unsigned-build",),
    "repository-scope.json": ("repository-scope",),
    "public-file-list.json": ("public-file-list",),
    "signature-verification.json": ("signing", "entitlements", "codesign"),
    "signing-evidence.json": ("signed-dmg", "pre-staple-manifest"),
    "notarization-request.json": ("notarization-request",),
    "notarization-approval.json": ("notarization-approval",),
    "approval-consumed.json": ("notarization-one-use",),
    "notarization-result.json": ("notarization-submission", "notarization-log-review"),
    "final-dmg-verification.json": ("immutable-final-dmg", "staple-validation", "local-gatekeeper-assessment"),
    "support-scope.json": ("known-issues-reviewed", "support-scope-reviewed"),
    "release-assets-evidence.json": ("release-assets-inventory",),
}
KNOWN_FILES = set(FIXED_GATES) | set(GENERIC_CHECKS) | set(MANUAL_RECORDS)

FORBIDDEN_KEY_MARKERS = {
    "username", "loginname", "accountname", "hostname", "machinename", "serialnumber", "hardwareuuid",
    "keychainprofile", "credentialprofile", "credential", "apikey", "authorizationheader", "accesstoken",
    "refreshtoken", "password", "privatekey", "transcript", "audio", "prompt", "instructions",
    "responsebody", "requestbody", "clipboard", "pasteboard", "targetwindowtitle", "certificatebody",
    "certificatepem", "certificatechain",
}
FORBIDDEN_TEXT = (
    re.compile(r"/(?:Users|home)/[^/\s]+", re.IGNORECASE),
    re.compile(r"/(?:private/)?(?:tmp|var/folders)/", re.IGNORECASE),
    re.compile(r"\b(?:user(?:name)?|login|account(?:name)?)\s*[:=]", re.IGNORECASE),
    re.compile(r"\b(?:keychain[-_ ]?profile|credential[-_ ]?profile|password|api[-_ ]?key|authorization|access[-_ ]?token|refresh[-_ ]?token|private[-_ ]?key|secret)\s*[:=]", re.IGNORECASE),
    re.compile(r"\b(?:transcript|prompt|instructions|response body|request body|clipboard|pasteboard)\s*[:=]", re.IGNORECASE),
    re.compile(r"-----BEGIN (?:CERTIFICATE|[^-]*PRIVATE KEY)-----", re.IGNORECASE),
)


class EvidenceError(Exception):
    def __init__(self, category: str):
        super().__init__(category)
        self.category = category


def reject(category: str) -> NoReturn:
    raise EvidenceError(category)


def canonical(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            reject("duplicate-json-key")
        result[key] = value
    return result


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


def exact(value: object, keys: set[str], category: str) -> dict[str, object]:
    if type(value) is not dict or set(value) != keys:
        reject(category)
    return value


def checked_text(value: object, category: str, maximum: int, *, allow_empty: bool = False) -> str:
    if type(value) is not str or len(value) > maximum or (not allow_empty and not value):
        reject(category)
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        reject(category)
    return value


def reject_placeholder(value: str, category: str) -> None:
    normalized = re.sub(r"[^a-z0-9]+", " ", value.strip().lower()).strip()
    if (
        "<" in value
        or ">" in value
        or re.search(r"\b(?:placeholder|tbd|todo|unset)\b", value, re.IGNORECASE) is not None
        or normalized in {
            "required", "placeholder", "tbd", "todo", "unset", "tester", "reviewer", "name",
            "unknown", "n/a", "na", "none", "replace me", "not recorded",
        }
    ):
        reject(category)


def checked_hex(value: object, pattern: re.Pattern[str], category: str) -> str:
    text = checked_text(value, category, 128)
    if pattern.fullmatch(text) is None or set(text) in ({"0"}, {"f"}):
        reject(category)
    return text


def checked_int(value: object, category: str, *, minimum: int = 0, maximum: int = 2**63 - 1) -> int:
    if type(value) is not int or isinstance(value, bool) or not minimum <= value <= maximum:
        reject(category)
    return value


def checked_relative_path(value: object, category: str) -> str:
    text = checked_text(value, category, 4096)
    path = PurePosixPath(text)
    if path.is_absolute() or text.startswith(("~", "./")) or "\\" in text or any(part in {"", ".", ".."} for part in path.parts):
        reject(category)
    return text


def checked_timestamp(value: object, category: str) -> datetime:
    text = checked_text(value, category, 128)
    if RFC3339.fullmatch(text) is None:
        reject(category)
    normalized = text[:-1] + "+00:00" if text.endswith("Z") else text
    try:
        result = datetime.fromisoformat(normalized)
    except ValueError:
        reject(category)
    offset = result.utcoffset()
    if offset is None or abs(offset) > timedelta(hours=14):
        reject(category)
    return result.astimezone(timezone.utc)


def derived_status(values: list[str]) -> str:
    if values and all(value == "pass" for value in values):
        return "pass"
    if "fail" in values:
        return "fail"
    return "not-run"


def sorted_unique_text(values: object, category: str, *, exact_names: set[str] | None = None) -> list[str]:
    if type(values) is not list or not values or len(values) > 10000:
        reject(category)
    result = [checked_text(item, category, 4096) for item in values]
    if result != sorted(result, key=lambda item: item.encode("utf-8")) or len(result) != len(set(result)):
        reject(category)
    if exact_names is not None and set(result) != exact_names:
        reject(category)
    return result


def scan_canaries(value: object, key: str = "") -> None:
    normalized_key = re.sub(r"[^a-z0-9]", "", key.lower())
    if normalized_key in FORBIDDEN_KEY_MARKERS:
        reject("prohibited-evidence-field")
    if type(value) is dict:
        for child_key, child_value in value.items():
            scan_canaries(child_value, child_key)
    elif type(value) is list:
        for child in value:
            scan_canaries(child, key)
    elif type(value) is str:
        if any(pattern.search(value) for pattern in FORBIDDEN_TEXT):
            reject("prohibited-evidence-value")
        for match in re.finditer(r"https?://([^/\s?#]+)([^\s]*)", value, re.IGNORECASE):
            authority, suffix = match.group(1), match.group(2)
            if "@" in authority:
                reject("url-userinfo")
            host = authority.lower()
            if host not in {"developer.apple.com", "support.apple.com"} and suffix not in {"", "/"}:
                reject("provider-url-detail")


def parse_canonical_json(data: bytes) -> object:
    try:
        value = json.loads(data.decode("utf-8", errors="strict"), object_pairs_hook=unique_object)
    except EvidenceError:
        raise
    except (UnicodeError, json.JSONDecodeError):
        reject("invalid-json")
    if data != canonical(value):
        reject("noncanonical-json")
    scan_canaries(value)
    return value


def read_regular(path: Path, category: str, maximum: int, *, canonical_json: bool) -> tuple[bytes, object | None]:
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
        chunks: list[bytes] = []
        remaining = maximum + 1
        while remaining:
            chunk = os.read(descriptor, min(1024 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        after = os.fstat(descriptor)
        data = b"".join(chunks)
        if fingerprint(opened) != fingerprint(after) or not data or len(data) > maximum:
            reject(category)
        if not canonical_json:
            return data, None
        return data, parse_canonical_json(data)
    except EvidenceError:
        raise
    except OSError:
        reject(category)
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def read_regular_at(directory: int, name: str, category: str, maximum: int) -> tuple[bytes, object, tuple[int, ...]]:
    descriptor = -1
    try:
        before = os.stat(name, dir_fd=directory, follow_symlinks=False)
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
        descriptor = os.open(
            name,
            os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=directory,
        )
        opened = os.fstat(descriptor)
        if fingerprint(before) != fingerprint(opened):
            reject(category)
        chunks: list[bytes] = []
        remaining = maximum + 1
        while remaining:
            chunk = os.read(descriptor, min(1024 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        after = os.fstat(descriptor)
        named = os.stat(name, dir_fd=directory, follow_symlinks=False)
        data = b"".join(chunks)
        if fingerprint(opened) != fingerprint(after) or fingerprint(after) != fingerprint(named) or not data or len(data) > maximum:
            reject(category)
        return data, parse_canonical_json(data), fingerprint(after)
    except EvidenceError:
        raise
    except OSError:
        reject(category)
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def read_schema() -> dict[str, object]:
    data, _ = read_regular(CANDIDATE_SCHEMA, "unsafe-candidate-schema", 1024 * 1024, canonical_json=False)
    try:
        value = json.loads(data.decode("utf-8", errors="strict"), object_pairs_hook=unique_object)
    except EvidenceError:
        raise
    except (UnicodeError, json.JSONDecodeError):
        reject("invalid-candidate-schema")
    if type(value) is not dict:
        reject("invalid-candidate-schema")
    return value


def validate_schema(value: object, schema: object, category: str, *, root: bool = False) -> None:
    if type(schema) is not dict:
        reject("invalid-candidate-schema")
    allowed = {"type", "additionalProperties", "required", "properties", "const", "pattern", "minLength", "maxLength"}
    if root:
        allowed |= {"$schema", "title", "description"}
    if set(schema) - allowed:
        reject("unsupported-candidate-schema")
    if "const" in schema and (type(value) is not type(schema["const"]) or value != schema["const"]):
        reject(category)
    expected_type = schema.get("type")
    if expected_type is not None:
        matches = (expected_type == "object" and type(value) is dict) or (expected_type == "string" and type(value) is str)
        if not matches:
            reject(category)
    if type(value) is dict:
        properties = schema.get("properties")
        required = schema.get("required")
        if type(properties) is not dict or type(required) is not list or any(type(item) is not str for item in required):
            reject("invalid-candidate-schema")
        if schema.get("additionalProperties") is not False or set(value) - set(properties) or not set(required) <= set(value):
            reject(category)
        for key, child in value.items():
            if key not in properties:
                reject(category)
            validate_schema(child, properties[key], category)
    elif type(value) is str:
        minimum, maximum = schema.get("minLength"), schema.get("maxLength")
        if minimum is not None and (type(minimum) is not int or len(value) < minimum):
            reject(category)
        if maximum is not None and (type(maximum) is not int or len(value) > maximum):
            reject(category)
        pattern = schema.get("pattern")
        if pattern is not None:
            if type(pattern) is not str:
                reject("invalid-candidate-schema")
            try:
                if re.search(pattern, value) is None:
                    reject(category)
            except re.error:
                reject("invalid-candidate-schema")


def verify_manual_matrix_contract() -> None:
    data, _ = read_regular(MANUAL_MATRIX, "unsafe-manual-matrix", 2 * 1024 * 1024, canonical_json=False)
    try:
        text = data.decode("utf-8", errors="strict")
    except UnicodeError:
        reject("invalid-manual-matrix")
    found = tuple(re.findall(r"^\| ([A-Z]{2}-[0-9]{2}) \|", text, flags=re.MULTILINE))
    expected = PRODUCT_ROWS + ACCESSIBILITY_ROWS + LOCAL_GATEKEEPER_ROWS + SECOND_MAC_ROWS
    if len(found) != len(set(found)) or set(found) != set(expected):
        reject("manual-matrix-contract-drift")


def reviewed_known_issues() -> list[str]:
    data, _ = read_regular(PUBLIC_README, "unsafe-public-readme", 2 * 1024 * 1024, canonical_json=False)
    try:
        text = data.decode("utf-8", errors="strict")
        section = text.split("## Current Limitations\n", 1)[1].split("\n## ", 1)[0]
    except (UnicodeError, IndexError):
        reject("invalid-public-readme-limitations")
    issues = [line[2:] for line in section.splitlines() if line.startswith("- ")]
    if not issues or len(issues) != len(set(issues)) or any(not item or len(item) > 4096 for item in issues):
        reject("invalid-public-readme-limitations")
    return sorted(issues, key=lambda item: item.encode("utf-8"))


class Collector:
    def __init__(self, schema: dict[str, object]) -> None:
        self.schema = schema
        self.raw: dict[str, bytes] = {}
        self.values: dict[str, dict[str, object]] = {}
        self.failures: dict[str, str] = {}
        self.passed_automated: set[str] = set()
        self.passed_manual: set[str] = set()
        self.commits: set[str] = set()
        self.trees: set[str] = set()
        self.teams: set[str] = set()
        self.request_ids: set[str] = set()
        self.pre_hashes: set[str] = set()
        self.final_hashes: set[str] = set()
        self.profile_hashes: set[str] = set()
        self.candidate_hash_refs: set[str] = set()
        self.unsigned_hash_refs: set[str] = set()
        self.signature_hash_refs: set[str] = set()
        self.signing_hash_refs: set[str] = set()
        self.approval_hash_refs: set[str] = set()
        self.public_list_hashes: set[str] = set()
        self.branch: str | None = None
        self.repository: str | None = None
        self.final_size: int | None = None
        self.input_directory_fingerprint: tuple[int, ...] | None = None
        self.input_names: tuple[str, ...] = ()
        self.input_fingerprints: dict[str, tuple[int, ...]] = {}
        self.input_sha256: dict[str, str] = {}
        self.signature_component_count: int | None = None
        self.signature_macho_count: int | None = None
        self.signing_macho_count: int | None = None
        self.final_signature_component_count: int | None = None

    def automated_pass(self, *gates: str) -> None:
        self.passed_automated.update(gates)

    def manual_pass(self, *gates: str) -> None:
        self.passed_manual.update(gates)

    def gap(self, gate: str, state: str) -> None:
        if gate in self.failures and self.failures[gate] != state:
            reject("contradictory-gate-state")
        self.failures[gate] = state

    def commit(self, value: object, category: str) -> str:
        result = checked_hex(value, HEX40, category)
        self.commits.add(result)
        return result

    def tree(self, value: object, category: str) -> str:
        result = checked_hex(value, HEX40, category)
        self.trees.add(result)
        return result

    def team(self, value: object, category: str) -> str:
        result = checked_text(value, category, 10)
        if TEAM_ID.fullmatch(result) is None:
            reject(category)
        self.teams.add(result)
        return result

    def request(self, value: object, category: str) -> str:
        result = checked_text(value, category, 64)
        if REQUEST_ID.fullmatch(result) is None:
            reject(category)
        self.request_ids.add(result)
        return result

    def pre_hash(self, value: object, category: str) -> str:
        result = checked_hex(value, HEX64, category)
        self.pre_hashes.add(result)
        return result

    def final_hash(self, value: object, category: str) -> str:
        result = checked_hex(value, HEX64, category)
        self.final_hashes.add(result)
        return result

    def profile_hash(self, value: object, category: str) -> str:
        result = checked_hex(value, HEX64, category)
        self.profile_hashes.add(result)
        return result

    def validate_candidate(self, value: dict[str, object], raw: bytes) -> None:
        validate_schema(value, self.schema, "invalid-candidate", root=True)
        source = exact(value["source"], {"commit", "tree", "releaseTag", "clean"}, "invalid-candidate")
        self.commit(source["commit"], "invalid-candidate")
        self.tree(source["tree"], "invalid-candidate")
        self.automated_pass("candidate", "toolchain", "dependency-lock")
        self.candidate_hash_refs.add(hashlib.sha256(raw).hexdigest())

    def validate_unsigned(self, value: dict[str, object], raw: bytes) -> None:
        record = exact(
            value,
            {"appTreeSHA256", "archiveTreeSHA256", "candidateCommit", "candidateJSONSHA256", "evidenceType", "product", "schemaVersion", "status", "treeAlgorithm"},
            "invalid-unsigned-build",
        )
        if record["schemaVersion"] != 1 or type(record["schemaVersion"]) is not int or record["evidenceType"] != "unsigned-build" or record["product"] != "UtterInk" or record["status"] != "valid" or record["treeAlgorithm"] != "utterink-logical-tree-v1":
            reject("invalid-unsigned-build")
        self.commit(record["candidateCommit"], "invalid-unsigned-build")
        self.candidate_hash_refs.add(checked_hex(record["candidateJSONSHA256"], HEX64, "invalid-unsigned-build"))
        checked_hex(record["appTreeSHA256"], HEX64, "invalid-unsigned-build")
        checked_hex(record["archiveTreeSHA256"], HEX64, "invalid-unsigned-build")
        self.unsigned_hash_refs.add(hashlib.sha256(raw).hexdigest())
        self.automated_pass("unsigned-build")

    def validate_scope(self, value: dict[str, object]) -> None:
        record = exact(value, {"approvalScope", "branch", "candidateCommit", "candidateTree", "evidenceType", "product", "publicFileListSHA256", "repository", "schemaVersion", "status"}, "invalid-repository-scope")
        if record["schemaVersion"] != 1 or type(record["schemaVersion"]) is not int or record["evidenceType"] != "repository-scope-approval" or record["product"] != "UtterInk" or record["approvalScope"] != "repository-branch-exact-commit" or record["status"] not in {"pass", "fail", "not-run"}:
            reject("invalid-repository-scope")
        self.commit(record["candidateCommit"], "invalid-repository-scope")
        self.tree(record["candidateTree"], "invalid-repository-scope")
        repository = checked_text(record["repository"], "invalid-repository-scope", 256)
        if repository != "local-no-origin" and re.fullmatch(r"(?:[A-Za-z0-9_.-]+/)?UtterInk", repository) is None:
            reject("invalid-repository-scope")
        branch = checked_text(record["branch"], "invalid-repository-scope", 256)
        if re.fullmatch(r"[A-Za-z0-9._/-]+", branch) is None or branch.startswith("/") or ".." in PurePosixPath(branch).parts:
            reject("invalid-repository-scope")
        self.public_list_hashes.add(checked_hex(record["publicFileListSHA256"], HEX64, "invalid-repository-scope"))
        self.repository, self.branch = repository, branch
        if record["status"] == "pass":
            self.automated_pass("repository-scope")
        else:
            self.gap("repository-scope", "failed" if record["status"] == "fail" else "not-run")

    def validate_public_files(self, value: dict[str, object]) -> None:
        record = exact(value, {"candidateCommit", "candidateTree", "complete", "evidenceType", "fileCount", "files", "listSHA256", "product", "schemaVersion", "status"}, "invalid-public-file-list")
        if record["schemaVersion"] != 1 or type(record["schemaVersion"]) is not int or record["evidenceType"] != "public-file-list" or record["product"] != "UtterInk" or record["status"] not in {"pass", "fail", "not-run"} or type(record["complete"]) is not bool:
            reject("invalid-public-file-list")
        self.commit(record["candidateCommit"], "invalid-public-file-list")
        self.tree(record["candidateTree"], "invalid-public-file-list")
        files = sorted_unique_text(record["files"], "invalid-public-file-list")
        for item in files:
            checked_relative_path(item, "invalid-public-file-list")
            path = PurePosixPath(item)
            forbidden_roots = {
                ".git", ".release-work", ".release-evidence", ".release-approvals", ".release-requests",
                ".notary-profile-bindings", "DerivedData", "build", "dist",
            }
            if path.parts[0] in forbidden_roots or path.name in {".DS_Store", ".env"} or path.suffix.lower() in {".dmg", ".p12", ".pfx", ".cer", ".xcarchive"}:
                reject("invalid-public-file-list")
        if checked_int(record["fileCount"], "invalid-public-file-list", minimum=1, maximum=100000) != len(files):
            reject("invalid-public-file-list")
        list_hash = hashlib.sha256(("\n".join(files) + "\n").encode("utf-8")).hexdigest()
        if record["listSHA256"] != list_hash:
            reject("invalid-public-file-list")
        self.public_list_hashes.add(list_hash)
        if record["status"] == "pass":
            if record["complete"] is not True:
                reject("contradictory-public-file-list")
            self.automated_pass("public-file-list")
        else:
            self.gap("public-file-list", "failed" if record["status"] == "fail" else "not-run")

    def validate_generic(self, value: dict[str, object], evidence_type: str, names: tuple[str, ...]) -> None:
        record = exact(value, {"candidateCommit", "checks", "evidenceType", "product", "schemaVersion", "status"}, "invalid-gate-review")
        if record["schemaVersion"] != 1 or type(record["schemaVersion"]) is not int or record["evidenceType"] != evidence_type or record["product"] != "UtterInk":
            reject("invalid-gate-review")
        self.commit(record["candidateCommit"], "invalid-gate-review")
        checks = exact(record["checks"], set(names), "invalid-gate-review")
        states: list[str] = []
        for name in names:
            state = checks[name]
            if state not in {"pass", "fail", "not-run"} or type(state) is not str:
                reject("invalid-gate-review")
            states.append(state)
            gate = f"{evidence_type}:{name}"
            if state == "pass":
                self.automated_pass(gate)
            else:
                self.gap(gate, "failed" if state == "fail" else "not-run")
        if record["status"] != derived_status(states):
            reject("contradictory-gate-status")

    def validate_signature(self, value: dict[str, object]) -> None:
        record = exact(value, {"candidateCommit", "candidateJSONSHA256", "certificate", "components", "evidenceType", "product", "schemaVersion", "signedAppTreeSHA256", "status", "teamID", "treeAlgorithm", "unsignedBuildEvidenceSHA256"}, "invalid-signature-evidence")
        if record["schemaVersion"] != 1 or type(record["schemaVersion"]) is not int or record["evidenceType"] != "signature-verification" or record["product"] != "UtterInk" or record["status"] != "valid" or record["treeAlgorithm"] != "utterink-logical-tree-v1":
            reject("invalid-signature-evidence")
        self.commit(record["candidateCommit"], "invalid-signature-evidence")
        self.team(record["teamID"], "invalid-signature-evidence")
        self.candidate_hash_refs.add(checked_hex(record["candidateJSONSHA256"], HEX64, "invalid-signature-evidence"))
        self.unsigned_hash_refs.add(checked_hex(record["unsignedBuildEvidenceSHA256"], HEX64, "invalid-signature-evidence"))
        checked_hex(record["signedAppTreeSHA256"], HEX64, "invalid-signature-evidence")
        certificate = exact(record["certificate"], {"notAfter", "notBefore", "sha256", "trust"}, "invalid-signature-evidence")
        if certificate["trust"] != "valid":
            reject("invalid-signature-evidence")
        checked_text(certificate["notBefore"], "invalid-signature-evidence", 128)
        checked_text(certificate["notAfter"], "invalid-signature-evidence", 128)
        checked_hex(certificate["sha256"], HEX64, "invalid-signature-evidence")
        components = record["components"]
        if type(components) is not list or not components or len(components) > 10000:
            reject("invalid-signature-evidence")
        paths: list[str] = []
        required_components = {
            "UtterInk.app": ("bundle", None),
            "UtterInk.app/Contents/MacOS/UtterInk": ("mach-o", "arm64"),
        }
        for item in components:
            component = exact(item, {"architecture", "designatedRequirement", "entitlements", "identifier", "kind", "path", "runtime", "secureTimestamp", "sha256", "teamID", "trust"}, "invalid-signature-evidence")
            if component["designatedRequirement"] != "valid" or component["runtime"] != "hardened" or component["secureTimestamp"] != "present" or component["trust"] != "valid" or component["teamID"] != record["teamID"]:
                reject("invalid-signature-evidence")
            identifier = checked_text(component["identifier"], "invalid-signature-evidence", 256)
            if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,255}", identifier) is None:
                reject("invalid-signature-evidence")
            kind = checked_text(component["kind"], "invalid-signature-evidence", 16)
            if kind not in {"bundle", "mach-o"}:
                reject("invalid-signature-evidence")
            path = checked_relative_path(component["path"], "invalid-signature-evidence")
            if PurePosixPath(path).parts[0] != "UtterInk.app":
                reject("invalid-signature-evidence")
            paths.append(path)
            checked_hex(component["sha256"], HEX64, "invalid-signature-evidence")
            entitlements = component["entitlements"]
            if type(entitlements) is not dict:
                reject("invalid-signature-evidence")
            if path in required_components:
                expected_kind, expected_architecture = required_components[path]
                if (
                    kind != expected_kind
                    or component["architecture"] != expected_architecture
                    or identifier != "dev.utterink.UtterInk"
                    or entitlements != {"com.apple.security.device.audio-input": True}
                ):
                    reject("invalid-signature-evidence")
            elif (
                component["architecture"] != (None if kind == "bundle" else "arm64")
                or entitlements != {}
            ):
                reject("invalid-signature-evidence")
        if paths != sorted(paths, key=lambda item: item.encode("utf-8")) or len(paths) != len(set(paths)):
            reject("invalid-signature-evidence")
        if not set(required_components) <= set(paths):
            reject("invalid-signature-evidence")
        self.signature_component_count = len(components)
        self.signature_macho_count = sum(1 for item in components if item["kind"] == "mach-o")
        self.signature_hash_refs.add(hashlib.sha256(self.raw["signature-verification.json"]).hexdigest())
        self.automated_pass("signing", "entitlements", "codesign")

    def validate_inspection(self, value: object, expected_hash: str) -> None:
        inspection = exact(value, {"architecture", "buildNumber", "bundleIdentifier", "dmgFilename", "dmgSHA256", "machOCount", "manifest", "minimumSystemVersion", "mode", "product", "signature", "status", "version"}, "invalid-signing-evidence")
        expected = {"architecture": "arm64", "buildNumber": "1", "bundleIdentifier": "dev.utterink.UtterInk", "dmgFilename": DMG_NAME, "minimumSystemVersion": "14.0", "mode": "signed", "product": "UtterInk", "signature": "developer-id", "status": "valid", "version": "0.1.0"}
        if any(inspection[key] != expected_value for key, expected_value in expected.items()) or inspection["dmgSHA256"] != expected_hash or inspection["manifest"] != MANIFEST:
            reject("invalid-signing-evidence")
        self.signing_macho_count = checked_int(inspection["machOCount"], "invalid-signing-evidence", minimum=1, maximum=100000)

    def validate_signing(self, value: dict[str, object], raw: bytes) -> None:
        record = exact(value, {"dmgFilename", "dmgSHA256", "evidenceType", "inspection", "product", "schemaVersion", "signatureVerificationSHA256", "status", "teamID"}, "invalid-signing-evidence")
        if record["schemaVersion"] != 1 or type(record["schemaVersion"]) is not int or record["evidenceType"] != "signed-pre-staple-dmg" or record["product"] != "UtterInk" or record["status"] != "valid" or record["dmgFilename"] != DMG_NAME:
            reject("invalid-signing-evidence")
        pre_hash = self.pre_hash(record["dmgSHA256"], "invalid-signing-evidence")
        self.team(record["teamID"], "invalid-signing-evidence")
        self.signature_hash_refs.add(checked_hex(record["signatureVerificationSHA256"], HEX64, "invalid-signing-evidence"))
        self.validate_inspection(record["inspection"], pre_hash)
        self.signing_hash_refs.add(hashlib.sha256(raw).hexdigest())
        self.automated_pass("signed-dmg", "pre-staple-manifest")

    def validate_request(self, value: dict[str, object]) -> None:
        record = exact(value, {"appleTeamID", "attempt", "candidateCommit", "candidateTree", "preStapleDMG", "product", "profileBindingReceiptSHA256", "requestID", "requestType", "schemaVersion", "signatureVerification", "statement"}, "invalid-notarization-request")
        if record["schemaVersion"] != 1 or type(record["schemaVersion"]) is not int or record["requestType"] != "apple-notarization-request" or record["product"] != "UtterInk" or record["attempt"] != 1 or type(record["attempt"]) is not int or record["statement"] != "one upload attempt only; rejection or any file change requires new approval.":
            reject("invalid-notarization-request")
        self.commit(record["candidateCommit"], "invalid-notarization-request")
        self.tree(record["candidateTree"], "invalid-notarization-request")
        self.team(record["appleTeamID"], "invalid-notarization-request")
        self.request(record["requestID"], "invalid-notarization-request")
        self.profile_hash(record["profileBindingReceiptSHA256"], "invalid-notarization-request")
        dmg = exact(record["preStapleDMG"], {"filename", "sha256", "sizeBytes"}, "invalid-notarization-request")
        if dmg["filename"] != DMG_NAME:
            reject("invalid-notarization-request")
        self.pre_hash(dmg["sha256"], "invalid-notarization-request")
        checked_int(dmg["sizeBytes"], "invalid-notarization-request", minimum=1)
        signature = exact(record["signatureVerification"], {"evidenceSHA256", "status", "teamID"}, "invalid-notarization-request")
        if signature["status"] != "valid" or signature["teamID"] != record["appleTeamID"]:
            reject("invalid-notarization-request")
        self.signing_hash_refs.add(checked_hex(signature["evidenceSHA256"], HEX64, "invalid-notarization-request"))
        self.automated_pass("notarization-request")

    def validate_approval(self, value: dict[str, object], raw: bytes) -> None:
        record = exact(value, {"action", "appleTeamID", "approvedAt", "attempt", "candidateCommit", "expiresAt", "preStapleDMGSHA256", "product", "profileBindingReceiptSHA256", "requestID"}, "invalid-notarization-approval")
        if record["action"] != "apple-notarization-upload" or record["product"] != "UtterInk" or record["attempt"] != 1 or type(record["attempt"]) is not int:
            reject("invalid-notarization-approval")
        self.commit(record["candidateCommit"], "invalid-notarization-approval")
        self.team(record["appleTeamID"], "invalid-notarization-approval")
        self.request(record["requestID"], "invalid-notarization-approval")
        self.pre_hash(record["preStapleDMGSHA256"], "invalid-notarization-approval")
        self.profile_hash(record["profileBindingReceiptSHA256"], "invalid-notarization-approval")
        approved = checked_timestamp(record["approvedAt"], "invalid-notarization-approval")
        expires = checked_timestamp(record["expiresAt"], "invalid-notarization-approval")
        if expires <= approved or expires - approved > timedelta(minutes=30) or approved > datetime.now(timezone.utc) + timedelta(minutes=5):
            reject("invalid-notarization-approval")
        self.approval_hash_refs.add(hashlib.sha256(raw).hexdigest())
        self.automated_pass("notarization-approval")

    def validate_consumed(self, value: dict[str, object]) -> None:
        record = exact(value, {"approvalSHA256", "attempt", "requestID", "status"}, "invalid-approval-consumption")
        if record["attempt"] != 1 or type(record["attempt"]) is not int or record["status"] != "consumed":
            reject("invalid-approval-consumption")
        self.request(record["requestID"], "invalid-approval-consumption")
        self.approval_hash_refs.add(checked_hex(record["approvalSHA256"], HEX64, "invalid-approval-consumption"))
        self.automated_pass("notarization-one-use")

    def validate_result(self, value: dict[str, object]) -> None:
        record = exact(value, {"automaticRetry", "completeLogReviewed", "dmgSHA256", "evidenceType", "issueCount", "logStatusSummary", "notarizationLogSHA256", "product", "schemaVersion", "status", "submissionID", "submissionResultSHA256", "warningCount", "warnings"}, "invalid-notarization-result")
        if record["schemaVersion"] != 1 or type(record["schemaVersion"]) is not int or record["evidenceType"] != "notarization-result-review" or record["product"] != "UtterInk" or record["status"] != "Accepted" or record["completeLogReviewed"] is not True or record["automaticRetry"] is not False:
            reject("invalid-notarization-result")
        submission = checked_text(record["submissionID"], "invalid-notarization-result", 36)
        if UUID.fullmatch(submission) is None:
            reject("invalid-notarization-result")
        self.pre_hash(record["dmgSHA256"], "invalid-notarization-result")
        checked_hex(record["submissionResultSHA256"], HEX64, "invalid-notarization-result")
        checked_hex(record["notarizationLogSHA256"], HEX64, "invalid-notarization-result")
        checked_text(record["logStatusSummary"], "invalid-notarization-result", 1024)
        issue_count = checked_int(record["issueCount"], "invalid-notarization-result", maximum=10000)
        warning_count = checked_int(record["warningCount"], "invalid-notarization-result", maximum=10000)
        warnings = record["warnings"]
        if type(warnings) is not list or len(warnings) != warning_count or warning_count > issue_count:
            reject("invalid-notarization-result")
        for item in warnings:
            warning = exact(item, {"architecture", "code", "documentURL", "message", "path", "severity"}, "invalid-notarization-result")
            if warning["severity"] != "warning":
                reject("invalid-notarization-result")
            if warning["architecture"] is not None:
                architecture = checked_text(warning["architecture"], "invalid-notarization-result", 128)
                if re.fullmatch(r"[A-Za-z0-9_.+-]+", architecture) is None:
                    reject("invalid-notarization-result")
            if warning["code"] is not None:
                checked_text(warning["code"], "invalid-notarization-result", 128)
            if warning["path"] is not None:
                checked_relative_path(warning["path"], "invalid-notarization-result")
            if warning["documentURL"] is not None:
                document_url = checked_text(warning["documentURL"], "invalid-notarization-result", 2048)
                if re.fullmatch(r"https://(?:developer|support)[.]apple[.]com/[A-Za-z0-9._~!$&'()*+,;=:@%/-]+", document_url) is None:
                    reject("invalid-notarization-result")
            checked_text(warning["message"], "invalid-notarization-result", 4096)
        self.automated_pass("notarization-submission", "notarization-log-review")

    def validate_final(self, value: dict[str, object]) -> None:
        record = exact(value, {"appGatekeeperAssessment", "candidateCommit", "dmgFilename", "dmgGatekeeperAssessment", "dmgSHA256", "dmgSizeBytes", "evidenceType", "hashAfterVerification", "hashBeforeVerification", "manifest", "mountMode", "originalArtifactUnchanged", "originalQuarantineState", "product", "schemaVersion", "signatureComponentCount", "stapleValidation", "status", "strictSignatureValidation"}, "invalid-final-dmg-verification")
        fixed = {"appGatekeeperAssessment": "accepted", "dmgFilename": DMG_NAME, "dmgGatekeeperAssessment": "accepted", "evidenceType": "final-dmg-verification", "manifest": MANIFEST, "mountMode": "read-only", "originalArtifactUnchanged": True, "product": "UtterInk", "schemaVersion": 1, "stapleValidation": "passed", "status": "valid", "strictSignatureValidation": "passed"}
        if any(record[key] != expected for key, expected in fixed.items()) or type(record["schemaVersion"]) is not int or record["originalQuarantineState"] not in {"present", "absent"}:
            reject("invalid-final-dmg-verification")
        self.commit(record["candidateCommit"], "invalid-final-dmg-verification")
        final_hash = self.final_hash(record["dmgSHA256"], "invalid-final-dmg-verification")
        if record["hashBeforeVerification"] != final_hash or record["hashAfterVerification"] != final_hash:
            reject("contradictory-final-dmg-hash")
        size = checked_int(record["dmgSizeBytes"], "invalid-final-dmg-verification", minimum=1)
        if self.final_size is not None and self.final_size != size:
            reject("contradictory-final-dmg-size")
        self.final_size = size
        self.final_signature_component_count = checked_int(record["signatureComponentCount"], "invalid-final-dmg-verification", minimum=1, maximum=100000)
        self.automated_pass("immutable-final-dmg", "staple-validation", "local-gatekeeper-assessment")

    def validate_manual(self, value: dict[str, object], evidence_type: str, row_ids: tuple[str, ...]) -> None:
        record = exact(value, {"candidateCommit", "evidenceType", "finalDMGSHA256", "locale", "product", "rows", "schemaVersion", "status"}, "invalid-manual-evidence")
        if record["schemaVersion"] != 1 or type(record["schemaVersion"]) is not int or record["evidenceType"] != evidence_type or record["product"] != "UtterInk" or record["locale"] != "en":
            reject("invalid-manual-evidence")
        commit = self.commit(record["candidateCommit"], "invalid-manual-evidence")
        final_hash = self.final_hash(record["finalDMGSHA256"], "invalid-manual-evidence")
        rows = exact(record["rows"], set(row_ids), "invalid-manual-evidence")
        states: list[str] = []
        for row_id in row_ids:
            row = exact(rows[row_id], {"appleSiliconModelClass", "candidateCommit", "finalDMGSHA256", "locale", "macOSVersion", "observation", "status", "tester", "timestamp"}, "invalid-manual-evidence")
            state = row["status"]
            if state not in {"pass", "fail", "not-run"} or type(state) is not str or row["candidateCommit"] != commit or row["finalDMGSHA256"] != final_hash or row["locale"] != "en":
                reject("invalid-manual-evidence")
            tester = checked_text(row["tester"], "invalid-manual-evidence", 128)
            reject_placeholder(tester, "manual-placeholder")
            if (
                re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9 ._-]{0,127}", tester) is None
                or re.search(r"\b(?:required|placeholder|tbd|todo)\b", tester, re.IGNORECASE) is not None
            ):
                reject("invalid-manual-evidence")
            model = checked_text(row["appleSiliconModelClass"], "invalid-manual-evidence", 128)
            reject_placeholder(model, "manual-placeholder")
            if re.fullmatch(
                r"(?:Apple Silicon|Apple-Silicon-(?:laptop|desktop)|Mac (?:mini|Studio|Pro)|MacBook (?:Air|Pro))(?: \(M-series\))?",
                model,
            ) is None:
                reject("invalid-manual-evidence")
            version = checked_text(row["macOSVersion"], "invalid-manual-evidence", 32)
            reject_placeholder(version, "manual-placeholder")
            version_match = re.fullmatch(r"([0-9]{2})(?:[.][0-9]{1,2}){1,2}", version)
            if (
                version_match is None
                or int(version_match.group(1)) < 14
                or (row_id.startswith("MR-") and state == "pass" and int(version_match.group(1)) != 14)
            ):
                reject("invalid-manual-evidence")
            timestamp_text = checked_text(row["timestamp"], "invalid-manual-evidence", 128)
            reject_placeholder(timestamp_text, "manual-placeholder")
            observed = checked_timestamp(timestamp_text, "invalid-manual-evidence")
            if observed > datetime.now(timezone.utc) + timedelta(minutes=5):
                reject("future-manual-evidence")
            observation = checked_text(row["observation"], "invalid-manual-evidence", 1024)
            reject_placeholder(observation, "manual-placeholder")
            observation_state = re.sub(r"[^a-z0-9]+", " ", observation.strip().lower()).strip()
            if state in {"pass", "fail"} and (
                observation_state == "pending"
                or re.fullmatch(
                    r"(?:(?:test|row|scenario) )?(?:was )?not (?:executed|run|tested|observed)(?: yet)?(?: due to .*)?",
                    observation_state,
                )
                is not None
            ):
                reject("contradictory-manual-observation")
            states.append(state)
            gate = f"{evidence_type}:{row_id}"
            if state == "pass":
                self.manual_pass(gate)
            else:
                self.gap(gate, "failed" if state == "fail" else "not-run")
        if record["status"] != derived_status(states):
            reject("contradictory-manual-status")

    def validate_support(self, value: dict[str, object]) -> None:
        record = exact(value, {"candidateCommit", "checks", "evidenceType", "knownIssues", "nonGoals", "product", "schemaVersion", "status", "supportedScope"}, "invalid-support-scope")
        if record["schemaVersion"] != 1 or type(record["schemaVersion"]) is not int or record["evidenceType"] != "support-scope-review" or record["product"] != "UtterInk":
            reject("invalid-support-scope")
        self.commit(record["candidateCommit"], "invalid-support-scope")
        checks = exact(record["checks"], {"known-issues-reviewed", "support-scope-reviewed"}, "invalid-support-scope")
        states: list[str] = []
        for name in ("known-issues-reviewed", "support-scope-reviewed"):
            state = checks[name]
            if state not in {"pass", "fail", "not-run"} or type(state) is not str:
                reject("invalid-support-scope")
            states.append(state)
            if state == "pass":
                self.automated_pass(name)
            else:
                self.gap(name, "failed" if state == "fail" else "not-run")
        if record["status"] != derived_status(states):
            reject("contradictory-support-status")
        if sorted_unique_text(record["knownIssues"], "invalid-support-scope") != reviewed_known_issues():
            reject("invalid-support-scope")
        sorted_unique_text(record["supportedScope"], "invalid-support-scope", exact_names={"macOS 14 or later", "Apple Silicon", "English UI", "manual updates"})
        sorted_unique_text(record["nonGoals"], "invalid-support-scope", exact_names={"Intel Macs", "automatic updates", "cloud sync", "live transcription"})

    def validate_assets(self, value: dict[str, object]) -> None:
        record = exact(value, {"assets", "candidateCommit", "evidenceType", "finalDMGSHA256", "product", "releaseTag", "schemaVersion", "status"}, "invalid-release-assets")
        if record["schemaVersion"] != 1 or type(record["schemaVersion"]) is not int or record["evidenceType"] != "release-assets" or record["product"] != "UtterInk" or record["releaseTag"] != "v0.1.0" or record["status"] != "valid":
            reject("invalid-release-assets")
        self.commit(record["candidateCommit"], "invalid-release-assets")
        final_hash = self.final_hash(record["finalDMGSHA256"], "invalid-release-assets")
        assets = record["assets"]
        expected_names = {"UtterInk-0.1.0-arm64.dmg", "UtterInk-0.1.0-source.tar.gz", "UtterInk-0.1.0-source.zip", "SHA256SUMS", "release-notes-0.1.0.md"}
        if type(assets) is not list or len(assets) != len(expected_names):
            reject("invalid-release-assets")
        names: list[str] = []
        for item in assets:
            asset = exact(item, {"filename", "sha256", "sizeBytes"}, "invalid-release-assets")
            filename = checked_relative_path(asset["filename"], "invalid-release-assets")
            if "/" in filename:
                reject("invalid-release-assets")
            names.append(filename)
            digest = checked_hex(asset["sha256"], HEX64, "invalid-release-assets")
            size = checked_int(asset["sizeBytes"], "invalid-release-assets", minimum=1)
            if filename == DMG_NAME:
                if digest != final_hash:
                    reject("contradictory-release-asset-hash")
                if self.final_size is not None and size != self.final_size:
                    reject("contradictory-release-asset-size")
                self.final_size = size
        if names != sorted(names, key=lambda item: item.encode("utf-8")) or set(names) != expected_names:
            reject("invalid-release-assets")
        self.automated_pass("release-assets-inventory")

    def add_missing(self) -> None:
        for filename, gates in FIXED_GATES.items():
            if filename not in self.values:
                for gate in gates:
                    self.gap(gate, "missing")
        for filename, (evidence_type, checks) in GENERIC_CHECKS.items():
            if filename not in self.values:
                for check in checks:
                    self.gap(f"{evidence_type}:{check}", "missing")
        for filename, (evidence_type, rows) in MANUAL_RECORDS.items():
            if filename not in self.values:
                for row in rows:
                    self.gap(f"{evidence_type}:{row}", "missing")

    @staticmethod
    def same_or_absent(values: set[str], category: str) -> None:
        if len(values) > 1:
            reject(category)

    def cross_validate(self) -> None:
        if not self.commits:
            reject("missing-candidate-anchor")
        for values, category in (
            (self.commits, "contradictory-candidate-commit"),
            (self.trees, "contradictory-candidate-tree"),
            (self.teams, "contradictory-team-id"),
            (self.request_ids, "contradictory-request-id"),
            (self.pre_hashes, "contradictory-pre-staple-hash"),
            (self.final_hashes, "contradictory-final-dmg-hash"),
            (self.profile_hashes, "contradictory-profile-binding"),
            (self.public_list_hashes, "contradictory-public-file-list"),
        ):
            self.same_or_absent(values, category)
        bindings = (
            ("candidate.json", self.candidate_hash_refs, "contradictory-candidate-record"),
            ("unsigned-build-evidence.json", self.unsigned_hash_refs, "contradictory-unsigned-build"),
            ("signature-verification.json", self.signature_hash_refs, "contradictory-signature-evidence"),
            ("signing-evidence.json", self.signing_hash_refs, "contradictory-signing-evidence"),
            ("notarization-approval.json", self.approval_hash_refs, "contradictory-notarization-approval"),
        )
        for filename, references, category in bindings:
            if filename in self.raw:
                references.add(hashlib.sha256(self.raw[filename]).hexdigest())
            self.same_or_absent(references, category)
        if (
            self.signature_component_count is not None
            and self.final_signature_component_count is not None
            and self.final_signature_component_count != self.signature_component_count + 1
        ):
            reject("contradictory-signature-component-count")
        if (
            self.signature_macho_count is not None
            and self.signing_macho_count is not None
            and self.signing_macho_count != self.signature_macho_count
        ):
            reject("contradictory-mach-o-count")


def read_inputs(path: Path, collector: Collector) -> None:
    directory = -1
    try:
        before = os.lstat(path)
        if not stat.S_ISDIR(before.st_mode) or stat.S_ISLNK(before.st_mode) or before.st_uid != os.geteuid() or before.st_mode & 0o022:
            reject("unsafe-input-directory")
        directory = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0))
        opened = os.fstat(directory)
        if fingerprint(before) != fingerprint(opened):
            reject("unsafe-input-directory")
        names = os.listdir(directory)
        if len(names) != len(set(names)) or any(name not in KNOWN_FILES for name in names):
            reject("unknown-evidence-file")
        ordered_names = tuple(sorted(names, key=lambda item: item.encode("utf-8")))
        total = 0
        for name in ordered_names:
            raw, parsed, item_fingerprint = read_regular_at(directory, name, "unsafe-evidence-file", MAX_RECORD_BYTES)
            total += len(raw)
            if total > MAX_TOTAL_BYTES or type(parsed) is not dict:
                reject("invalid-evidence-set")
            collector.raw[name] = raw
            collector.values[name] = parsed
            collector.input_fingerprints[name] = item_fingerprint
            collector.input_sha256[name] = hashlib.sha256(raw).hexdigest()
        final_opened = os.fstat(directory)
        final_named = os.lstat(path)
        if fingerprint(opened) != fingerprint(final_opened) or fingerprint(final_opened) != fingerprint(final_named):
            reject("unsafe-input-directory")
        collector.input_directory_fingerprint = fingerprint(final_opened)
        collector.input_names = ordered_names
    except EvidenceError:
        raise
    except OSError:
        reject("unsafe-input-directory")
    finally:
        if directory >= 0:
            os.close(directory)


def revalidate_inputs(path: Path, collector: Collector) -> None:
    directory = -1
    try:
        if collector.input_directory_fingerprint is None:
            reject("missing-input-snapshot")
        before = os.lstat(path)
        if fingerprint(before) != collector.input_directory_fingerprint:
            reject("evidence-set-mutated-after-read")
        directory = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0))
        opened = os.fstat(directory)
        if fingerprint(opened) != collector.input_directory_fingerprint:
            reject("evidence-set-mutated-after-read")
        names = tuple(sorted(os.listdir(directory), key=lambda item: item.encode("utf-8")))
        if names != collector.input_names:
            reject("evidence-set-mutated-after-read")
        for name in names:
            raw, _, item_fingerprint = read_regular_at(directory, name, "evidence-mutated-after-read", MAX_RECORD_BYTES)
            if (
                item_fingerprint != collector.input_fingerprints.get(name)
                or hashlib.sha256(raw).hexdigest() != collector.input_sha256.get(name)
            ):
                reject("evidence-mutated-after-read")
        final_opened = os.fstat(directory)
        final_named = os.lstat(path)
        if (
            fingerprint(final_opened) != collector.input_directory_fingerprint
            or fingerprint(final_named) != collector.input_directory_fingerprint
        ):
            reject("evidence-set-mutated-after-read")
    except EvidenceError:
        raise
    except OSError:
        reject("evidence-set-mutated-after-read")
    finally:
        if directory >= 0:
            os.close(directory)


def test_after_read_barrier() -> None:
    notify_text = os.environ.get("UTTERINK_EVIDENCE_TEST_NOTIFY_FD")
    continue_text = os.environ.get("UTTERINK_EVIDENCE_TEST_CONTINUE_FD")
    requested = notify_text is not None or continue_text is not None
    if not requested:
        return
    if os.environ.get("UTTERINK_EVIDENCE_TEST_MODE") != "1" or notify_text is None or continue_text is None:
        reject("invalid-test-barrier")
    try:
        notify = int(notify_text)
        continuation = int(continue_text)
        if notify < 3 or continuation < 3 or notify == continuation:
            reject("invalid-test-barrier")
        if not stat.S_ISFIFO(os.fstat(notify).st_mode) or not stat.S_ISFIFO(os.fstat(continuation).st_mode):
            reject("invalid-test-barrier")
        if os.write(notify, b"R") != 1 or os.read(continuation, 1) != b"C":
            reject("invalid-test-barrier")
        os.close(notify)
        os.close(continuation)
    except EvidenceError:
        raise
    except (OSError, ValueError):
        reject("invalid-test-barrier")


def validate_records(collector: Collector) -> None:
    validators: dict[str, Callable[[], None]] = {}
    if "candidate.json" in collector.values:
        validators["candidate.json"] = lambda: collector.validate_candidate(collector.values["candidate.json"], collector.raw["candidate.json"])
    if "unsigned-build-evidence.json" in collector.values:
        validators["unsigned-build-evidence.json"] = lambda: collector.validate_unsigned(collector.values["unsigned-build-evidence.json"], collector.raw["unsigned-build-evidence.json"])
    if "repository-scope.json" in collector.values:
        validators["repository-scope.json"] = lambda: collector.validate_scope(collector.values["repository-scope.json"])
    if "public-file-list.json" in collector.values:
        validators["public-file-list.json"] = lambda: collector.validate_public_files(collector.values["public-file-list.json"])
    if "signature-verification.json" in collector.values:
        validators["signature-verification.json"] = lambda: collector.validate_signature(collector.values["signature-verification.json"])
    if "signing-evidence.json" in collector.values:
        validators["signing-evidence.json"] = lambda: collector.validate_signing(collector.values["signing-evidence.json"], collector.raw["signing-evidence.json"])
    if "notarization-request.json" in collector.values:
        validators["notarization-request.json"] = lambda: collector.validate_request(collector.values["notarization-request.json"])
    if "notarization-approval.json" in collector.values:
        validators["notarization-approval.json"] = lambda: collector.validate_approval(collector.values["notarization-approval.json"], collector.raw["notarization-approval.json"])
    if "approval-consumed.json" in collector.values:
        validators["approval-consumed.json"] = lambda: collector.validate_consumed(collector.values["approval-consumed.json"])
    if "notarization-result.json" in collector.values:
        validators["notarization-result.json"] = lambda: collector.validate_result(collector.values["notarization-result.json"])
    if "final-dmg-verification.json" in collector.values:
        validators["final-dmg-verification.json"] = lambda: collector.validate_final(collector.values["final-dmg-verification.json"])
    if "support-scope.json" in collector.values:
        validators["support-scope.json"] = lambda: collector.validate_support(collector.values["support-scope.json"])
    if "release-assets-evidence.json" in collector.values:
        validators["release-assets-evidence.json"] = lambda: collector.validate_assets(collector.values["release-assets-evidence.json"])
    for filename, (evidence_type, checks) in GENERIC_CHECKS.items():
        if filename in collector.values:
            validators[filename] = lambda filename=filename, evidence_type=evidence_type, checks=checks: collector.validate_generic(collector.values[filename], evidence_type, checks)
    for filename, (evidence_type, rows) in MANUAL_RECORDS.items():
        if filename in collector.values:
            validators[filename] = lambda filename=filename, evidence_type=evidence_type, rows=rows: collector.validate_manual(collector.values[filename], evidence_type, rows)
    for filename in sorted(validators, key=lambda item: item.encode("utf-8")):
        validators[filename]()
    collector.add_missing()
    collector.cross_validate()


def markdown_packet(collector: Collector) -> tuple[str, bytes]:
    status = "READY" if not collector.failures else "NOT_RELEASE_READY"
    generated = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    commit = next(iter(collector.commits))
    tree = next(iter(collector.trees)) if collector.trees else "not-recorded"
    pre_hash = next(iter(collector.pre_hashes)) if collector.pre_hashes else "not-recorded"
    final_hash = next(iter(collector.final_hashes)) if collector.final_hashes else "not-recorded"
    candidate_digest = hashlib.sha256(collector.raw["candidate.json"]).hexdigest() if "candidate.json" in collector.raw else "not-recorded"
    approval_digest = hashlib.sha256(collector.raw["notarization-approval.json"]).hexdigest() if "notarization-approval.json" in collector.raw else "not-recorded"
    repository = collector.repository or "not-recorded"
    branch = collector.branch or "not-recorded"
    size = str(collector.final_size) if collector.final_size is not None else "not-recorded"
    lines = [
        "# UtterInk 0.1.0 Release Evidence Packet",
        "",
        f"Computed status: {status}",
        f"Generated at: {generated}",
        "Product: UtterInk 0.1.0 (1)",
        f"Repository scope: {repository}",
        f"Branch: {branch}",
        f"Candidate commit: {commit}",
        f"Candidate tree: {tree}",
        f"Candidate record SHA-256: {candidate_digest}",
        f"Final DMG filename: {DMG_NAME}",
        f"Signed pre-staple approved SHA-256: {pre_hash}",
        f"Notarization approval record SHA-256: {approval_digest}",
        f"Final post-staple DMG SHA-256: {final_hash}",
        f"Final post-staple DMG size: {size}",
        "",
        "## 1. Failures and missing gates",
        "",
        "| Gate code | Status |",
        "|---|---|",
    ]
    if collector.failures:
        for gate in sorted(collector.failures, key=lambda item: item.encode("utf-8")):
            lines.append(f"| `{gate}` | `{collector.failures[gate]}` |")
    else:
        lines.append("| None | `pass` |")
    lines += [
        "",
        "## 2. Passed automated and manual gates",
        "",
        "### Automated",
        "",
        "| Gate code | Status |",
        "|---|---|",
    ]
    if collector.passed_automated:
        for gate in sorted(collector.passed_automated, key=lambda item: item.encode("utf-8")):
            lines.append(f"| `{gate}` | `pass` |")
    else:
        lines.append("| None | `not-run` |")
    lines += ["", "### Manual", "", "| Gate code | Status |", "|---|---|"]
    if collector.passed_manual:
        for gate in sorted(collector.passed_manual, key=lambda item: item.encode("utf-8")):
            lines.append(f"| `{gate}` | `pass` |")
    else:
        lines.append("| None | `not-run` |")
    lines += ["", "### Sanitized evidence digests", "", "| Record | SHA-256 |", "|---|---|"]
    for name in sorted(collector.raw, key=lambda item: item.encode("utf-8")):
        lines.append(f"| `{name}` | `{hashlib.sha256(collector.raw[name]).hexdigest()}` |")
    lines += [
        "",
        "## 3. Outstanding external approvals",
        "",
        "| External action | Disposition |",
        "|---|---|",
        "| Private GitHub first push | `NOT AUTHORIZED BY THIS PACKET` |",
        "| Any future Apple notarization upload | `NOT AUTHORIZED BY THIS PACKET` |",
        "| Beta artifact transfer | `NOT AUTHORIZED BY THIS PACKET` |",
        "| GitHub public-visibility change | `NOT AUTHORIZED BY THIS PACKET` |",
        "| GitHub Release publication | `NOT AUTHORIZED BY THIS PACKET` |",
        "",
        "This packet is evidence for user review—not permission to push, transfer, make public, or release.",
        "",
    ]
    return status, "\n".join(lines).encode("utf-8")


def atomic_write(path: Path, data: bytes) -> None:
    absolute = Path(os.path.abspath(os.fspath(path)))
    descriptor = -1
    directory_descriptor = -1
    temporary_name: str | None = None
    linked = False
    identity: tuple[int, int] | None = None
    published_identity: tuple[int, int] | None = None
    try:
        parent_before = os.lstat(absolute.parent)
        if not stat.S_ISDIR(parent_before.st_mode) or stat.S_ISLNK(parent_before.st_mode) or parent_before.st_uid != os.geteuid() or parent_before.st_mode & 0o022:
            reject("unsafe-output")
        directory_descriptor = os.open(absolute.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0))
        parent_opened = os.fstat(directory_descriptor)
        if fingerprint(parent_before) != fingerprint(parent_opened):
            reject("unsafe-output")
        try:
            os.stat(absolute.name, dir_fd=directory_descriptor, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            reject("unsafe-output")
        for _ in range(32):
            candidate = f".collect-evidence.{secrets.token_hex(16)}.tmp"
            try:
                descriptor = os.open(
                    candidate,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
                    0o600,
                    dir_fd=directory_descriptor,
                )
                temporary_name = candidate
                break
            except FileExistsError:
                continue
        if descriptor < 0 or temporary_name is None:
            reject("output-write-failed")
        opened = os.fstat(descriptor)
        identity = (opened.st_dev, opened.st_ino)
        offset = 0
        while offset < len(data):
            written = os.write(descriptor, data[offset:])
            if written <= 0:
                reject("output-write-failed")
            offset += written
        os.fchmod(descriptor, 0o600)
        os.fsync(descriptor)
        final = os.fstat(descriptor)
        named = os.stat(temporary_name, dir_fd=directory_descriptor, follow_symlinks=False)
        if (final.st_dev, final.st_ino) != identity or (named.st_dev, named.st_ino) != identity or final.st_nlink != 1 or final.st_size != len(data) or stat.S_IMODE(final.st_mode) != 0o600:
            reject("output-write-failed")
        os.close(descriptor)
        descriptor = -1
        os.link(
            temporary_name,
            absolute.name,
            src_dir_fd=directory_descriptor,
            dst_dir_fd=directory_descriptor,
            follow_symlinks=False,
        )
        linked = True
        published = os.stat(absolute.name, dir_fd=directory_descriptor, follow_symlinks=False)
        published_identity = (published.st_dev, published.st_ino)
        if (published.st_dev, published.st_ino) != identity or published.st_nlink != 2 or stat.S_IMODE(published.st_mode) != 0o600:
            reject("output-write-failed")
        os.unlink(temporary_name, dir_fd=directory_descriptor)
        temporary_name = None
        published = os.stat(absolute.name, dir_fd=directory_descriptor, follow_symlinks=False)
        if (published.st_dev, published.st_ino) != identity or published.st_nlink != 1 or published.st_size != len(data):
            reject("output-write-failed")
        named_parent = os.lstat(absolute.parent)
        named_output = os.lstat(absolute)
        if (
            (named_parent.st_dev, named_parent.st_ino, named_parent.st_mode, named_parent.st_uid)
            != (parent_opened.st_dev, parent_opened.st_ino, parent_opened.st_mode, parent_opened.st_uid)
            or (named_output.st_dev, named_output.st_ino) != identity
        ):
            reject("output-write-failed")
        os.fsync(directory_descriptor)
    except EvidenceError:
        raise
    except OSError:
        reject("output-write-failed")
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary_name is not None and directory_descriptor >= 0:
            try:
                current = os.stat(temporary_name, dir_fd=directory_descriptor, follow_symlinks=False)
                if identity is None or (current.st_dev, current.st_ino) == identity:
                    os.unlink(temporary_name, dir_fd=directory_descriptor)
            except OSError:
                pass
        if linked and published_identity is not None and sys.exc_info()[0] is not None and directory_descriptor >= 0:
            try:
                current = os.stat(absolute.name, dir_fd=directory_descriptor, follow_symlinks=False)
                if (current.st_dev, current.st_ino) == published_identity:
                    os.unlink(absolute.name, dir_fd=directory_descriptor)
            except OSError:
                pass
        if directory_descriptor >= 0:
            os.close(directory_descriptor)


class Parser(argparse.ArgumentParser):
    def error(self, message: str) -> NoReturn:
        del message
        reject("invalid-arguments")


def parse_arguments() -> argparse.Namespace:
    arguments = sys.argv[1:]
    flags = ("--inputs", "--output", "--expect-status")
    if len(arguments) != 6 or any(arguments.count(flag) != 1 for flag in flags):
        reject("invalid-arguments")
    parser = Parser(add_help=False)
    parser.add_argument("--inputs", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--expect-status", required=True, choices=("READY", "NOT_RELEASE_READY"))
    return parser.parse_args()


def main() -> int:
    try:
        arguments = parse_arguments()
        verify_manual_matrix_contract()
        collector = Collector(read_schema())
        inputs = Path(os.path.abspath(arguments.inputs))
        read_inputs(inputs, collector)
        test_after_read_barrier()
        validate_records(collector)
        status, packet = markdown_packet(collector)
        revalidate_inputs(inputs, collector)
        atomic_write(Path(arguments.output), packet)
        if status != arguments.expect_status:
            print("evidence collector error: expectation-mismatch", file=sys.stderr)
            return 2
        print(status)
        return 0
    except EvidenceError as error:
        print(f"evidence collector error: {error.category}", file=sys.stderr)
        return 1
    except (OSError, UnicodeError, ValueError, KeyError):
        print("evidence collector error: internal-failure", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
