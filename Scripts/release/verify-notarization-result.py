#!/usr/bin/env python3
from __future__ import annotations

import argparse
from datetime import datetime, timedelta
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
from typing import NoReturn
from urllib.parse import urlsplit


MAX_RESULT_BYTES = 16 * 1024 * 1024
DMG_FILENAME = "UtterInk-0.1.0-arm64.dmg"
HEX_64 = re.compile(r"[0-9a-f]{64}\Z")
CDHASH = re.compile(r"[0-9a-fA-F]{40}(?:[0-9a-fA-F]{24})?\Z")
RFC3339 = re.compile(
    r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
    r"(?:[.][0-9]{1,9})?(?:Z|[+-][0-9]{2}:[0-9]{2})\Z"
)
UUID = re.compile(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\Z"
)
SUBMISSION_KEYS = {"id", "message", "status"}
LOG_KEYS = {
    "archiveFilename",
    "issues",
    "jobId",
    "logFormatVersion",
    "sha256",
    "status",
    "statusCode",
    "statusSummary",
    "ticketContents",
    "uploadDate",
}
ISSUE_KEYS = {"severity", "code", "path", "message", "architecture", "docUrl"}


class ResultError(Exception):
    def __init__(self, category: str):
        super().__init__(category)
        self.category = category


def reject(category: str) -> NoReturn:
    raise ResultError(category)


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


def read_owner_only(path: Path, category: str) -> bytes:
    descriptor = -1
    try:
        before = os.lstat(path)
        if (
            not stat.S_ISREG(before.st_mode)
            or stat.S_ISLNK(before.st_mode)
            or before.st_uid != os.geteuid()
            or before.st_nlink != 1
            or stat.S_IMODE(before.st_mode) != 0o600
            or before.st_size <= 0
            or before.st_size > MAX_RESULT_BYTES
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
        remaining = MAX_RESULT_BYTES + 1
        while remaining:
            chunk = os.read(descriptor, min(1024 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        after = os.fstat(descriptor)
        data = b"".join(chunks)
        if fingerprint(opened) != fingerprint(after) or not data or len(data) > MAX_RESULT_BYTES:
            reject(category)
        return data
    except ResultError:
        raise
    except OSError:
        reject(category)
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def parse_json(data: bytes, category: str) -> object:
    try:
        return json.loads(data.decode("utf-8", errors="strict"), object_pairs_hook=unique_object)
    except ResultError:
        raise
    except (UnicodeError, json.JSONDecodeError):
        reject(category)


def exact_object(value: object, keys: set[str], category: str) -> dict[str, object]:
    if type(value) is not dict or set(value) != keys:
        reject(category)
    return value


def safe_text(value: object, category: str, maximum: int, *, allow_empty: bool = False) -> str:
    if type(value) is not str or len(value) > maximum or (not value and not allow_empty):
        reject(category)
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        reject(category)
    lowered = value.lower()
    if any(marker in lowered for marker in ("/users/", "/private/", "keychain-profile", "apple-id", "password")):
        reject("unsanitized-result")
    return value


def optional_text(value: object, category: str, maximum: int) -> str | None:
    if value is None:
        return None
    return safe_text(value, category, maximum, allow_empty=False)


def checked_rfc3339(value: object, category: str) -> str:
    text = safe_text(value, category, 128)
    if RFC3339.fullmatch(text) is None:
        reject(category)
    normalized = text[:-1] + "+00:00" if text.endswith("Z") else text
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError:
        reject(category)
    offset = parsed.utcoffset()
    if offset is None or abs(offset) > timedelta(hours=14):
        reject(category)
    return text


def checked_ticket(value: object) -> None:
    if type(value) is not dict or not value or len(value) > 32 or "path" not in value:
        reject("invalid-ticket-content")
    for key, item in value.items():
        safe_text(key, "invalid-ticket-content", 128)
        safe_text(item, "invalid-ticket-content", 4096)
    path = value["path"]
    if Path(path).is_absolute() or ".." in Path(path).parts:
        reject("unsanitized-result")
    if "digestAlgorithm" in value and value["digestAlgorithm"] != "SHA-256":
        reject("invalid-ticket-content")
    if "cdhash" in value and CDHASH.fullmatch(value["cdhash"]) is None:
        reject("invalid-ticket-content")


def checked_document_url(value: object) -> str | None:
    if value is None:
        return None
    text = safe_text(value, "invalid-log-issue", 2048)
    parsed = urlsplit(text)
    if parsed.scheme != "https" or parsed.hostname not in {"developer.apple.com", "support.apple.com"}:
        reject("unsanitized-result")
    if parsed.username is not None or parsed.password is not None or parsed.fragment:
        reject("unsanitized-result")
    return text


def normalized_issue(value: object) -> tuple[str, dict[str, object]]:
    if type(value) is not dict or not {"severity", "message"} <= set(value) or set(value) - ISSUE_KEYS:
        reject("invalid-log-issue")
    severity_value = value["severity"]
    if type(severity_value) is not str:
        reject("invalid-log-issue")
    severity = severity_value.lower()
    if severity in {"error", "invalid"}:
        reject("invalid-or-error-issue")
    if severity not in {"warning", "info"}:
        reject("unknown-issue-severity")
    code_value = value.get("code")
    if code_value is None:
        code: str | None = None
    elif type(code_value) in {str, int} and not isinstance(code_value, bool):
        code = safe_text(str(code_value), "invalid-log-issue", 128)
    else:
        reject("invalid-log-issue")
    path = optional_text(value.get("path"), "invalid-log-issue", 2048)
    if path is not None and (path.startswith("/") or ".." in Path(path).parts):
        reject("unsanitized-result")
    normalized = {
        "severity": severity,
        "code": code,
        "path": path,
        "message": safe_text(value["message"], "invalid-log-issue", 4096),
        "architecture": optional_text(value.get("architecture"), "invalid-log-issue", 128),
        "documentURL": checked_document_url(value.get("docUrl")),
    }
    return severity, normalized


def write_owner_only(path: Path, data: bytes) -> None:
    absolute = Path(os.path.abspath(os.fspath(path)))
    descriptor = -1
    created = False
    identity: tuple[int, int] | None = None
    try:
        parent = os.lstat(absolute.parent)
        if (
            not stat.S_ISDIR(parent.st_mode)
            or stat.S_ISLNK(parent.st_mode)
            or parent.st_uid != os.geteuid()
            or parent.st_mode & 0o022
        ):
            reject("unsafe-output")
        descriptor = os.open(
            absolute,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
        created = True
        opened = os.fstat(descriptor)
        identity = (opened.st_dev, opened.st_ino)
        if not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.geteuid() or opened.st_nlink != 1:
            reject("unsafe-output")
        offset = 0
        while offset < len(data):
            written = os.write(descriptor, data[offset:])
            if written <= 0:
                reject("output-write-failed")
            offset += written
        os.fchmod(descriptor, 0o600)
        os.fsync(descriptor)
        final = os.fstat(descriptor)
        named = os.lstat(absolute)
        if (
            (final.st_dev, final.st_ino) != identity
            or (named.st_dev, named.st_ino) != identity
            or stat.S_IMODE(final.st_mode) != 0o600
            or final.st_size != len(data)
        ):
            reject("output-write-failed")
    except ResultError:
        raise
    except OSError:
        reject("output-write-failed")
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if created and sys.exc_info()[0] is not None and identity is not None:
            try:
                current = os.lstat(absolute)
                if (current.st_dev, current.st_ino) == identity:
                    os.unlink(absolute)
            except OSError:
                pass


def verify(arguments: argparse.Namespace) -> dict[str, object]:
    expected_hash = arguments.expected_dmg_sha256
    if type(expected_hash) is not str or HEX_64.fullmatch(expected_hash) is None:
        reject("invalid-expected-dmg-hash")
    if expected_hash in {"0" * 64, "f" * 64}:
        reject("placeholder-value")

    submission_bytes = read_owner_only(Path(arguments.submission), "unsafe-submission-result")
    submission = exact_object(
        parse_json(submission_bytes, "invalid-submission-result"),
        SUBMISSION_KEYS,
        "invalid-submission-result",
    )
    submission_id = submission["id"]
    if type(submission_id) is not str or UUID.fullmatch(submission_id) is None:
        reject("invalid-submission-id")
    safe_text(submission["message"], "invalid-submission-result", 1024)
    if submission["status"] != "Accepted" or type(submission["status"]) is not str:
        reject("submission-not-accepted")

    log_bytes = read_owner_only(Path(arguments.log), "unsafe-notarization-log")
    log = exact_object(
        parse_json(log_bytes, "invalid-notarization-log"),
        LOG_KEYS,
        "invalid-notarization-log",
    )
    if (
        type(log["jobId"]) is not str
        or log["jobId"].lower() != submission_id.lower()
        or log["status"] != "Accepted"
        or type(log["status"]) is not str
        or type(log["statusCode"]) is not int
        or isinstance(log["statusCode"], bool)
        or log["statusCode"] != 0
        or type(log["logFormatVersion"]) is not int
        or isinstance(log["logFormatVersion"], bool)
        or log["logFormatVersion"] < 1
        or log["archiveFilename"] != DMG_FILENAME
        or log["sha256"] != expected_hash
        or type(log["ticketContents"]) is not list
        or not log["ticketContents"]
        or len(log["ticketContents"]) > 10000
    ):
        reject("notarization-log-mismatch")
    safe_text(log["statusSummary"], "invalid-notarization-log", 1024)
    checked_rfc3339(log["uploadDate"], "invalid-notarization-log")
    for ticket in log["ticketContents"]:
        checked_ticket(ticket)

    issues_value = log["issues"]
    if issues_value is None:
        issues: list[object] = []
    elif type(issues_value) is list and len(issues_value) <= 10000:
        issues = issues_value
    else:
        reject("invalid-notarization-log")

    warnings: list[dict[str, object]] = []
    for item in issues:
        severity, normalized = normalized_issue(item)
        if severity == "warning":
            warnings.append(normalized)

    summary = {
        "schemaVersion": 1,
        "evidenceType": "notarization-result-review",
        "product": "UtterInk",
        "submissionID": submission_id.lower(),
        "submissionResultSHA256": hashlib.sha256(submission_bytes).hexdigest(),
        "status": "Accepted",
        "logStatusSummary": log["statusSummary"],
        "notarizationLogSHA256": hashlib.sha256(log_bytes).hexdigest(),
        "dmgSHA256": expected_hash,
        "completeLogReviewed": True,
        "automaticRetry": False,
        "issueCount": len(issues),
        "warningCount": len(warnings),
        "warnings": warnings,
    }
    return summary


class Parser(argparse.ArgumentParser):
    def error(self, message: str) -> NoReturn:
        del message
        reject("invalid-arguments")


def parser() -> Parser:
    value = Parser(add_help=False)
    value.add_argument("--submission", required=True)
    value.add_argument("--log", required=True)
    value.add_argument("--expected-dmg-sha256", required=True)
    value.add_argument("--output", required=True)
    return value


def main() -> int:
    try:
        arguments = parser().parse_args()
        summary = verify(arguments)
        data = canonical(summary)
        write_owner_only(Path(arguments.output), data)
        sys.stdout.buffer.write(data)
        return 0
    except ResultError as error:
        print(f"notarization result error: {error.category}", file=sys.stderr)
        return 1
    except (OSError, UnicodeError, ValueError):
        print("notarization result error: internal-failure", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
