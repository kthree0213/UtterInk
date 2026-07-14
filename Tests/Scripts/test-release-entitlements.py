#!/usr/bin/env python3
from __future__ import annotations

import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
VERIFIER = ROOT / "Scripts" / "release" / "verify-entitlements.py"
POLICY = ROOT / "Config" / "release-entitlements.json"
SOURCE = ROOT / "App" / "Supporting" / "UtterInk.entitlements"
EXPECTED_ENTITLEMENTS = {"com.apple.security.device.audio-input": True}
EXPECTED_POLICY = {
    "schemaVersion": 1,
    "app": {
        "bundleIdentifier": "dev.utterink.UtterInk",
        "sourcePath": "App/Supporting/UtterInk.entitlements",
        "entitlements": [
            {
                "key": "com.apple.security.device.audio-input",
                "value": True,
                "reason": "Required for local microphone capture",
            }
        ],
    },
    "nestedComponents": [],
}


def fail(reason: str) -> None:
    print(f"release entitlement tests failed: {reason}", file=sys.stderr)
    raise SystemExit(1)


def sanitized_environment() -> dict[str, str]:
    environment = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("GIT_") and key not in {"PYTHONPATH", "PYTHONHOME"}
    }
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    return environment


def run_verifier(root: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(root / "Scripts" / "release" / "verify-entitlements.py"), *arguments],
        cwd=root,
        env=sanitized_environment(),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )


def expect_success(root: Path, *arguments: str) -> None:
    result = run_verifier(root, *arguments)
    if result.returncode != 0:
        fail(f"valid fixture was rejected: {result.stderr.strip()}")
    if result.stdout or result.stderr:
        fail("valid fixture emitted non-silent output")


def expect_failure(
    root: Path,
    category: str,
    *arguments: str,
    returncode: int = 1,
) -> None:
    result = run_verifier(root, *arguments)
    if result.returncode != returncode:
        fail(f"{category} fixture returned {result.returncode}, expected {returncode}")
    if result.stdout:
        fail(f"{category} fixture wrote to stdout")
    expected = f"release entitlements error: {category}\n"
    if result.stderr != expected:
        fail(f"{category} fixture emitted a non-sanitized diagnostic")


def make_fixture(parent: Path, label: str) -> Path:
    fixture = parent / label
    (fixture / "Config").mkdir(parents=True)
    (fixture / "App" / "Supporting").mkdir(parents=True)
    (fixture / "Scripts" / "release").mkdir(parents=True)
    shutil.copyfile(POLICY, fixture / "Config" / "release-entitlements.json")
    shutil.copyfile(SOURCE, fixture / "App" / "Supporting" / "UtterInk.entitlements")
    shutil.copyfile(VERIFIER, fixture / "Scripts" / "release" / "verify-entitlements.py")
    return fixture


def write_plist(path: Path, value: object, *, binary: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as handle:
        plistlib.dump(
            value,
            handle,
            fmt=plistlib.FMT_BINARY if binary else plistlib.FMT_XML,
            sort_keys=True,
        )


def write_policy(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def mutated_policy() -> dict[str, object]:
    return json.loads(json.dumps(EXPECTED_POLICY))


if not VERIFIER.is_file():
    fail("verifier does not exist: Scripts/release/verify-entitlements.py")
if not POLICY.is_file():
    fail("policy does not exist: Config/release-entitlements.json")
if not SOURCE.is_file():
    fail("authoritative entitlement source does not exist")

try:
    policy = json.loads(POLICY.read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError):
    fail("authoritative policy is not valid UTF-8 JSON")
if policy != EXPECTED_POLICY:
    fail("authoritative policy does not match the approved exact inventory")

expect_success(ROOT)

for arguments in (
    ("--archived", str(SOURCE)),
    ("--signed", str(SOURCE)),
    ("--archived", str(SOURCE), "--signed", str(SOURCE)),
    ("--signed", str(SOURCE), "--archived", str(SOURCE)),
):
    expect_success(ROOT, *arguments)

expect_failure(ROOT, "invalid-arguments", "--unknown", returncode=2)
expect_failure(ROOT, "invalid-arguments", "unexpected", returncode=2)
expect_failure(ROOT, "invalid-arguments", "--archived", returncode=2)
expect_failure(ROOT, "invalid-arguments", "--signed", returncode=2)
expect_failure(
    ROOT,
    "invalid-arguments",
    "--archived",
    str(SOURCE),
    "--archived",
    str(SOURCE),
    returncode=2,
)
expect_failure(
    ROOT,
    "invalid-arguments",
    "--signed",
    str(SOURCE),
    "--signed",
    str(SOURCE),
    returncode=2,
)

with tempfile.TemporaryDirectory(prefix="utterink-release-entitlement-tests-") as temporary:
    fixtures = Path(temporary)

    for label, value in (
        ("missing", {}),
        ("extra", {**EXPECTED_ENTITLEMENTS, "example.invalid.extra": True}),
        ("false", {"com.apple.security.device.audio-input": False}),
        ("integer", {"com.apple.security.device.audio-input": 1}),
        ("string", {"com.apple.security.device.audio-input": "true"}),
        (
            "wildcard",
            {
                **EXPECTED_ENTITLEMENTS,
                "com.apple.security.application-groups": ["*"],
            },
        ),
        ("root-array", [EXPECTED_ENTITLEMENTS]),
        ("debugger", {**EXPECTED_ENTITLEMENTS, "com.apple.security.get-task-allow": True}),
        ("jit", {**EXPECTED_ENTITLEMENTS, "com.apple.security.cs.allow-jit": True}),
        (
            "unsigned-memory",
            {**EXPECTED_ENTITLEMENTS, "com.apple.security.cs.allow-unsigned-executable-memory": True},
        ),
        (
            "disable-library-validation",
            {**EXPECTED_ENTITLEMENTS, "com.apple.security.cs.disable-library-validation": True},
        ),
        ("network-server", {**EXPECTED_ENTITLEMENTS, "com.apple.security.network.server": True}),
        ("sandbox", {**EXPECTED_ENTITLEMENTS, "com.apple.security.app-sandbox": True}),
    ):
        fixture = make_fixture(fixtures, f"source-{label}")
        write_plist(fixture / "App" / "Supporting" / "UtterInk.entitlements", value)
        expect_failure(fixture, "entitlements-mismatch")

    archived_mismatch = make_fixture(fixtures, "archived-mismatch")
    archived = archived_mismatch / "candidate" / "archived.plist"
    write_plist(archived, {})
    expect_failure(archived_mismatch, "entitlements-mismatch", "--archived", str(archived))

    signed_mismatch = make_fixture(fixtures, "signed-mismatch")
    signed = signed_mismatch / "candidate" / "signed.plist"
    write_plist(signed, {**EXPECTED_ENTITLEMENTS, "com.apple.security.get-task-allow": True})
    expect_failure(signed_mismatch, "entitlements-mismatch", "--signed", str(signed))

    source_cannot_be_replaced = make_fixture(fixtures, "source-cannot-be-replaced")
    source = source_cannot_be_replaced / "App" / "Supporting" / "UtterInk.entitlements"
    write_plist(source, {})
    archived = source_cannot_be_replaced / "candidate" / "archived.plist"
    signed = source_cannot_be_replaced / "candidate" / "signed.plist"
    write_plist(archived, EXPECTED_ENTITLEMENTS)
    write_plist(signed, EXPECTED_ENTITLEMENTS)
    expect_failure(
        source_cannot_be_replaced,
        "entitlements-mismatch",
        "--archived",
        str(archived),
        "--signed",
        str(signed),
    )

    binary_inputs = make_fixture(fixtures, "binary-inputs")
    archived = binary_inputs / "candidate" / "archived.plist"
    signed = binary_inputs / "candidate" / "signed.plist"
    write_plist(archived, EXPECTED_ENTITLEMENTS, binary=True)
    write_plist(signed, EXPECTED_ENTITLEMENTS, binary=True)
    expect_success(binary_inputs, "--archived", str(archived), "--signed", str(signed))

    missing_input = make_fixture(fixtures, "missing-input")
    missing = missing_input / "candidate" / "private-missing-value.plist"
    expect_failure(missing_input, "unsafe-entitlements-file", "--archived", str(missing))

    directory_input = make_fixture(fixtures, "directory-input")
    directory = directory_input / "candidate" / "private-directory-value.plist"
    directory.mkdir(parents=True)
    expect_failure(directory_input, "unsafe-entitlements-file", "--signed", str(directory))

    symlink_input = make_fixture(fixtures, "symlink-input")
    target = symlink_input / "candidate" / "target.plist"
    link = symlink_input / "candidate" / "private-link-value.plist"
    write_plist(target, EXPECTED_ENTITLEMENTS)
    link.symlink_to(target)
    expect_failure(symlink_input, "unsafe-entitlements-file", "--archived", str(link))

    symlink_source = make_fixture(fixtures, "symlink-source")
    source = symlink_source / "App" / "Supporting" / "UtterInk.entitlements"
    target = symlink_source / "source-target.plist"
    source.replace(target)
    source.symlink_to(target)
    expect_failure(symlink_source, "unsafe-entitlements-file")

    oversized_input = make_fixture(fixtures, "oversized-input")
    oversized = oversized_input / "candidate" / "oversized.plist"
    oversized.parent.mkdir(parents=True)
    oversized.write_bytes(b"x" * (128 * 1024 + 1))
    expect_failure(oversized_input, "unsafe-entitlements-file", "--signed", str(oversized))

    malformed_input = make_fixture(fixtures, "malformed-input")
    malformed = malformed_input / "candidate" / "malformed.plist"
    malformed.parent.mkdir(parents=True)
    malformed.write_bytes(b"not a plist")
    expect_failure(malformed_input, "invalid-entitlements-plist", "--archived", str(malformed))

    duplicate_plist_key = make_fixture(fixtures, "duplicate-plist-key")
    duplicate = duplicate_plist_key / "candidate" / "duplicate.plist"
    duplicate.parent.mkdir(parents=True)
    duplicate.write_text(
        """<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>com.apple.security.device.audio-input</key><true/>
<key>com.apple.security.device.audio-input</key><true/>
</dict></plist>
""",
        encoding="utf-8",
    )
    expect_failure(
        duplicate_plist_key,
        "invalid-entitlements-plist",
        "--archived",
        str(duplicate),
    )

    for label, mutate in (
        ("wrong-schema", lambda value: value.__setitem__("schemaVersion", 2)),
        ("boolean-schema", lambda value: value.__setitem__("schemaVersion", True)),
        ("extra-top-level", lambda value: value.__setitem__("unexpected", True)),
        ("missing-app", lambda value: value.pop("app")),
        ("nested-component", lambda value: value.__setitem__("nestedComponents", [{}])),
        (
            "bundle-identifier",
            lambda value: value["app"].__setitem__("bundleIdentifier", "example.invalid.UtterInk"),
        ),
        (
            "source-path",
            lambda value: value["app"].__setitem__("sourcePath", "Other.entitlements"),
        ),
        (
            "absolute-source-path",
            lambda value: value["app"].__setitem__("sourcePath", "/private/tmp/Other.entitlements"),
        ),
        (
            "traversing-source-path",
            lambda value: value["app"].__setitem__("sourcePath", "../Other.entitlements"),
        ),
        (
            "entitlement-key",
            lambda value: value["app"]["entitlements"][0].__setitem__("key", "example.invalid"),
        ),
        (
            "entitlement-value",
            lambda value: value["app"]["entitlements"][0].__setitem__("value", 1),
        ),
        (
            "entitlement-reason",
            lambda value: value["app"]["entitlements"][0].__setitem__("reason", "Microphone"),
        ),
        (
            "extra-entitlement-field",
            lambda value: value["app"]["entitlements"][0].__setitem__("unexpected", True),
        ),
        (
            "duplicate-entitlement",
            lambda value: value["app"]["entitlements"].append(
                dict(value["app"]["entitlements"][0])
            ),
        ),
    ):
        fixture = make_fixture(fixtures, f"policy-{label}")
        value = mutated_policy()
        mutate(value)
        write_policy(fixture / "Config" / "release-entitlements.json", value)
        expect_failure(fixture, "invalid-policy-schema")

    duplicate_policy_key = make_fixture(fixtures, "duplicate-policy-key")
    policy_path = duplicate_policy_key / "Config" / "release-entitlements.json"
    policy_path.write_text(
        policy_path.read_text(encoding="utf-8").replace(
            '"schemaVersion": 1,',
            '"schemaVersion": 1,\n  "schemaVersion": 1,',
            1,
        ),
        encoding="utf-8",
    )
    expect_failure(duplicate_policy_key, "invalid-policy-schema")

    malformed_policy = make_fixture(fixtures, "malformed-policy")
    (malformed_policy / "Config" / "release-entitlements.json").write_text("{", encoding="utf-8")
    expect_failure(malformed_policy, "invalid-policy-schema")

    symlink_policy = make_fixture(fixtures, "symlink-policy")
    policy_path = symlink_policy / "Config" / "release-entitlements.json"
    target = symlink_policy / "policy-target.json"
    policy_path.replace(target)
    policy_path.symlink_to(target)
    expect_failure(symlink_policy, "unsafe-policy-file")

print("release entitlement tests passed")
