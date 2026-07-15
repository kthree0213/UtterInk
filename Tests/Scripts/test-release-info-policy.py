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
VERIFIER = ROOT / "Scripts" / "release" / "verify-info-policy.py"
POLICY = ROOT / "Config" / "release-info-policy.json"

EXPECTED_SOURCE_APP_FIELDS = {
    "CFBundleDevelopmentRegion": "en",
    "CFBundleDisplayName": "UtterInk",
    "CFBundleExecutable": "$(EXECUTABLE_NAME)",
    "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": "UtterInk",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "$(MARKETING_VERSION)",
    "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
    "LSApplicationCategoryType": "public.app-category.productivity",
    "LSMinimumSystemVersion": "$(MACOSX_DEPLOYMENT_TARGET)",
    "LSUIElement": True,
    "NSMicrophoneUsageDescription": (
        "UtterInk uses the microphone to transcribe speech locally on this Mac."
    ),
}
EXPECTED_SOURCE_PROBE_FIELDS = {
    "CFBundleDevelopmentRegion": "en",
    "CFBundleDisplayName": "ATSPolicyProbe",
    "CFBundleExecutable": "$(EXECUTABLE_NAME)",
    "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": "ATSPolicyProbe",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "1.0",
    "CFBundleVersion": "1",
    "LSMinimumSystemVersion": "14.0",
}
EXPECTED_ARCHIVED_APP_FIELDS = {
    **EXPECTED_SOURCE_APP_FIELDS,
    "CFBundleExecutable": "UtterInk",
    "CFBundleIdentifier": "dev.utterink.UtterInk",
    "CFBundleShortVersionString": "0.1.0",
    "CFBundleVersion": "1",
    "LSMinimumSystemVersion": "14.0",
}
EXPECTED_ARCHIVE_GENERATED_KEYS = [
    "BuildMachineOSBuild",
    "CFBundleIconFile",
    "CFBundleIconName",
    "CFBundleSupportedPlatforms",
    "DTCompiler",
    "DTPlatformBuild",
    "DTPlatformName",
    "DTPlatformVersion",
    "DTSDKBuild",
    "DTSDKName",
    "DTXcode",
    "DTXcodeBuild",
]


def fail(reason: str) -> None:
    print(f"release Info policy tests failed: {reason}", file=sys.stderr)
    raise SystemExit(1)


def sanitized_environment(extra: dict[str, str] | None = None) -> dict[str, str]:
    environment = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("GIT_")
        and key not in {"PYTHONPATH", "PYTHONHOME", "UTTERINK_INFO_POLICY_PATH"}
    }
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    if extra:
        environment.update(extra)
    return environment


def run_verifier(
    root: Path,
    *arguments: str,
    environment: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(root / "Scripts" / "release" / "verify-info-policy.py"), *arguments],
        cwd=root,
        env=sanitized_environment(environment),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )


def expect_success(root: Path, *arguments: str) -> None:
    result = run_verifier(root, *arguments)
    if result.returncode != 0:
        fail(f"valid fixture failed: {result.stderr.strip()}")
    if result.stdout != "release Info policy valid\n" or result.stderr:
        fail("valid fixture output was not normalized")


def expect_failure(root: Path, category: str, *arguments: str) -> None:
    result = run_verifier(root, *arguments)
    expected_status = 2 if category == "invalid-arguments" else 1
    if result.returncode != expected_status:
        fail(f"{category} fixture returned {result.returncode}, expected {expected_status}")
    if result.stdout:
        fail(f"{category} fixture wrote success output")
    if result.stderr != f"release Info policy error: {category}\n":
        fail(f"{category} fixture emitted a non-sanitized diagnostic")


def make_fixture(parent: Path, label: str) -> Path:
    fixture = parent / label
    for relative in (
        Path("Config/release-info-policy.json"),
        Path("App/Supporting/Info.plist"),
        Path("Tests/ATSPolicyProbe/Info.plist"),
        Path("Scripts/release/verify-info-policy.py"),
    ):
        destination = fixture / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / relative, destination)
    return fixture


def read_policy(root: Path) -> dict[str, object]:
    return json.loads((root / "Config/release-info-policy.json").read_text(encoding="utf-8"))


def write_policy(root: Path, policy: dict[str, object]) -> None:
    (root / "Config/release-info-policy.json").write_text(
        json.dumps(policy, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def read_plist(path: Path) -> dict[str, object]:
    with path.open("rb") as handle:
        value = plistlib.load(handle)
    if not isinstance(value, dict):
        fail("test fixture property list was not a dictionary")
    return value


def write_plist(path: Path, value: dict[str, object]) -> None:
    with path.open("wb") as handle:
        plistlib.dump(value, handle, fmt=plistlib.FMT_XML, sort_keys=False)


def source_app(root: Path) -> Path:
    return root / "App/Supporting/Info.plist"


def source_probe(root: Path) -> Path:
    return root / "Tests/ATSPolicyProbe/Info.plist"


def make_archive(root: Path, label: str = "Archived-Info.plist") -> Path:
    archive = root / label
    write_plist(archive, dict(EXPECTED_ARCHIVED_APP_FIELDS))
    return archive


if not VERIFIER.is_file():
    fail("verifier does not exist: Scripts/release/verify-info-policy.py")
if not POLICY.is_file():
    fail("policy does not exist: Config/release-info-policy.json")

try:
    production_policy = json.loads(POLICY.read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError):
    fail("production policy is not valid JSON")

expected_policy = {
    "schemaVersion": 1,
    "finalShape": "absent",
    "authoritativeSources": {
        "app": "App/Supporting/Info.plist",
        "probe": "Tests/ATSPolicyProbe/Info.plist",
    },
    "sourceAppOwnedFields": EXPECTED_SOURCE_APP_FIELDS,
    "sourceProbeOwnedFields": EXPECTED_SOURCE_PROBE_FIELDS,
    "archivedAppOwnedFields": EXPECTED_ARCHIVED_APP_FIELDS,
    "archiveGeneratedKeyAllowlist": EXPECTED_ARCHIVE_GENERATED_KEYS,
}
if production_policy != expected_policy:
    fail("production policy does not lock the reviewed absent ATS evidence")

expect_success(ROOT)

with tempfile.TemporaryDirectory(prefix="utterink-release-info-policy-tests-") as temporary:
    fixtures = Path(temporary).resolve()

    resolved_archive = make_fixture(fixtures, "resolved-archive")
    expect_success(resolved_archive, "--archived", str(make_archive(resolved_archive).resolve()))

    binary_archive = make_fixture(fixtures, "binary-archive")
    archive = binary_archive / "Archived-Info.plist"
    with archive.open("wb") as handle:
        plistlib.dump(EXPECTED_ARCHIVED_APP_FIELDS, handle, fmt=plistlib.FMT_BINARY)
    expect_success(binary_archive, "--archived", str(archive.resolve()))

    local_network = make_fixture(fixtures, "local-network-only")
    policy = read_policy(local_network)
    policy["finalShape"] = "local-network-only"
    write_policy(local_network, policy)
    for plist_path in (source_app(local_network), source_probe(local_network)):
        value = read_plist(plist_path)
        value["NSAppTransportSecurity"] = {"NSAllowsLocalNetworking": True}
        write_plist(plist_path, value)
    expect_success(local_network)
    archive = make_archive(local_network)
    value = read_plist(archive)
    value["NSAppTransportSecurity"] = {"NSAllowsLocalNetworking": True}
    write_plist(archive, value)
    expect_success(local_network, "--archived", str(archive.resolve()))

    local_network_widening = make_fixture(fixtures, "local-network-widening")
    policy = read_policy(local_network_widening)
    policy["finalShape"] = "local-network-only"
    write_policy(local_network_widening, policy)
    for plist_path in (source_app(local_network_widening), source_probe(local_network_widening)):
        value = read_plist(plist_path)
        value["NSAppTransportSecurity"] = {"NSAllowsLocalNetworking": True}
        write_plist(plist_path, value)
    value = read_plist(source_app(local_network_widening))
    value["NSAppTransportSecurity"] = {
        "NSAllowsLocalNetworking": True,
        "NSAllowsArbitraryLoads": True,
    }
    write_plist(source_app(local_network_widening), value)
    expect_failure(local_network_widening, "ats-policy")

    for label, ats in (
        ("arbitrary-loads", {"NSAllowsArbitraryLoads": True}),
        ("media-loads", {"NSAllowsArbitraryLoadsForMedia": True}),
        ("web-content-loads", {"NSAllowsArbitraryLoadsInWebContent": True}),
        ("exception-domains", {"NSExceptionDomains": {"example.invalid": {}}}),
        ("extra-ats-key", {"NSAllowsLocalNetworking": True, "Unexpected": True}),
        ("false-local-network", {"NSAllowsLocalNetworking": False}),
    ):
        fixture = make_fixture(fixtures, label)
        value = read_plist(source_app(fixture))
        value["NSAppTransportSecurity"] = ats
        write_plist(source_app(fixture), value)
        expect_failure(fixture, "ats-policy")

    local_description = make_fixture(fixtures, "local-description")
    value = read_plist(source_app(local_description))
    value["NSLocalNetworkUsageDescription"] = "Not approved"
    write_plist(source_app(local_description), value)
    expect_failure(local_description, "local-network-usage-description")

    extra_source_field = make_fixture(fixtures, "extra-source-field")
    value = read_plist(source_app(extra_source_field))
    value["UnexpectedOwnedField"] = "value"
    write_plist(source_app(extra_source_field), value)
    expect_failure(extra_source_field, "source-fields")

    placeholder_drift = make_fixture(fixtures, "placeholder-drift")
    value = read_plist(source_app(placeholder_drift))
    value["CFBundleIdentifier"] = "dev.utterink.UtterInk"
    write_plist(source_app(placeholder_drift), value)
    expect_failure(placeholder_drift, "source-fields")

    probe_widening = make_fixture(fixtures, "probe-widening")
    value = read_plist(source_probe(probe_widening))
    value["NSAppTransportSecurity"] = {"NSAllowsArbitraryLoads": True}
    write_plist(source_probe(probe_widening), value)
    expect_failure(probe_widening, "ats-policy")

    extra_archive_field = make_fixture(fixtures, "extra-archive-field")
    policy = read_policy(extra_archive_field)
    policy["archiveGeneratedKeyAllowlist"] = []
    write_policy(extra_archive_field, policy)
    archive = make_archive(extra_archive_field)
    value = read_plist(archive)
    value["BuildMachineOSBuild"] = "fixture"
    write_plist(archive, value)
    expect_failure(
        extra_archive_field,
        "unexpected-generated-key",
        "--archived",
        str(archive.resolve()),
    )

    allowlisted_archive_field = make_fixture(fixtures, "allowlisted-archive-field")
    policy = read_policy(allowlisted_archive_field)
    policy["archiveGeneratedKeyAllowlist"] = ["BuildMachineOSBuild"]
    write_policy(allowlisted_archive_field, policy)
    archive = make_archive(allowlisted_archive_field)
    value = read_plist(archive)
    value["BuildMachineOSBuild"] = "fixture"
    write_plist(archive, value)
    expect_success(allowlisted_archive_field, "--archived", str(archive.resolve()))

    nested_unresolved_archive = make_fixture(fixtures, "nested-unresolved-archive")
    policy = read_policy(nested_unresolved_archive)
    policy["archiveGeneratedKeyAllowlist"] = ["BuildMachineOSBuild"]
    write_policy(nested_unresolved_archive, policy)
    archive = make_archive(nested_unresolved_archive)
    value = read_plist(archive)
    value["BuildMachineOSBuild"] = {"nested": ["$(UNRESOLVED)"]}
    write_plist(archive, value)
    expect_failure(
        nested_unresolved_archive,
        "unresolved-archive-placeholder",
        "--archived",
        str(archive.resolve()),
    )

    nested_ats_widening = make_fixture(fixtures, "nested-ats-widening")
    policy = read_policy(nested_ats_widening)
    policy["archiveGeneratedKeyAllowlist"] = ["BuildMachineOSBuild"]
    write_policy(nested_ats_widening, policy)
    archive = make_archive(nested_ats_widening)
    value = read_plist(archive)
    value["BuildMachineOSBuild"] = {"NSAllowsArbitraryLoads": True}
    write_plist(archive, value)
    expect_failure(
        nested_ats_widening,
        "ats-policy",
        "--archived",
        str(archive.resolve()),
    )

    unresolved_archive = make_fixture(fixtures, "unresolved-archive")
    archive = make_archive(unresolved_archive)
    value = read_plist(archive)
    value["CFBundleExecutable"] = "$(EXECUTABLE_NAME)"
    write_plist(archive, value)
    expect_failure(
        unresolved_archive,
        "unresolved-archive-placeholder",
        "--archived",
        str(archive.resolve()),
    )

    archive_value_drift = make_fixture(fixtures, "archive-value-drift")
    archive = make_archive(archive_value_drift)
    value = read_plist(archive)
    value["CFBundleIdentifier"] = "example.invalid.UtterInk"
    write_plist(archive, value)
    expect_failure(
        archive_value_drift,
        "archived-fields",
        "--archived",
        str(archive.resolve()),
    )

    archive_local_description = make_fixture(fixtures, "archive-local-description")
    archive = make_archive(archive_local_description)
    value = read_plist(archive)
    value["NSLocalNetworkUsageDescription"] = "Not approved"
    write_plist(archive, value)
    expect_failure(
        archive_local_description,
        "local-network-usage-description",
        "--archived",
        str(archive.resolve()),
    )

    archive_exception_domains = make_fixture(fixtures, "archive-exception-domains")
    archive = make_archive(archive_exception_domains)
    value = read_plist(archive)
    value["NSAppTransportSecurity"] = {
        "NSExceptionDomains": {"example.invalid": {"NSTemporaryExceptionAllowsInsecureHTTPLoads": True}}
    }
    write_plist(archive, value)
    expect_failure(
        archive_exception_domains,
        "ats-policy",
        "--archived",
        str(archive.resolve()),
    )

    malformed_source = make_fixture(fixtures, "malformed-source")
    source_app(malformed_source).write_bytes(b"not a property list")
    expect_failure(malformed_source, "invalid-plist")

    malformed_archive = make_fixture(fixtures, "malformed-archive")
    archive = malformed_archive / "Archived-Info.plist"
    archive.write_bytes(b"not a property list")
    expect_failure(
        malformed_archive,
        "invalid-plist",
        "--archived",
        str(archive.resolve()),
    )

    cyclic_archive = make_fixture(fixtures, "cyclic-binary-archive")
    archive = cyclic_archive / "Archived-Info.plist"
    archive.write_bytes(
        bytes.fromhex(
            "62706c6973743030d101025947656e657261746564a102080b15"
            "0000000000000101000000000000000300000000000000000000000000000017"
        )
    )
    expect_failure(
        cyclic_archive,
        "invalid-plist",
        "--archived",
        str(archive.resolve()),
    )

    duplicate_source = make_fixture(fixtures, "duplicate-source")
    data = source_app(duplicate_source).read_bytes()
    data = data.replace(
        b"</dict>\n</plist>",
        b"<key>CFBundleName</key><string>Duplicate</string>\n</dict>\n</plist>",
    )
    source_app(duplicate_source).write_bytes(data)
    expect_failure(duplicate_source, "duplicate-plist-key")

    duplicate_archive = make_fixture(fixtures, "duplicate-archive")
    archive = make_archive(duplicate_archive)
    data = archive.read_bytes().replace(
        b"</dict>\n</plist>",
        b"<key>CFBundleName</key><string>Duplicate</string>\n</dict>\n</plist>",
    )
    archive.write_bytes(data)
    expect_failure(
        duplicate_archive,
        "duplicate-plist-key",
        "--archived",
        str(archive.resolve()),
    )

    source_symlink = make_fixture(fixtures, "source-symlink")
    preserved = source_symlink / "Info-preserved.plist"
    source_app(source_symlink).replace(preserved)
    source_app(source_symlink).symlink_to(preserved)
    expect_failure(source_symlink, "unsafe-path")

    policy_symlink = make_fixture(fixtures, "policy-symlink")
    policy_path = policy_symlink / "Config/release-info-policy.json"
    preserved = policy_symlink / "policy-preserved.json"
    policy_path.replace(preserved)
    policy_path.symlink_to(preserved)
    expect_failure(policy_symlink, "unsafe-path")

    archive_symlink = make_fixture(fixtures, "archive-symlink")
    archive = make_archive(archive_symlink)
    preserved = archive_symlink / "Archive-preserved.plist"
    archive.replace(preserved)
    archive.symlink_to(preserved)
    expect_failure(
        archive_symlink,
        "unsafe-path",
        "--archived",
        str(archive.absolute()),
    )

    malformed_policy = make_fixture(fixtures, "malformed-policy")
    (malformed_policy / "Config/release-info-policy.json").write_text("{", encoding="utf-8")
    expect_failure(malformed_policy, "invalid-policy")

    invalid_shape_type = make_fixture(fixtures, "invalid-shape-type")
    policy = read_policy(invalid_shape_type)
    policy["finalShape"] = []
    write_policy(invalid_shape_type, policy)
    expect_failure(invalid_shape_type, "invalid-policy")

    duplicate_policy = make_fixture(fixtures, "duplicate-policy")
    policy_text = (duplicate_policy / "Config/release-info-policy.json").read_text(encoding="utf-8")
    policy_text = policy_text.replace('"schemaVersion": 1,', '"schemaVersion": 1,\n  "schemaVersion": 1,', 1)
    (duplicate_policy / "Config/release-info-policy.json").write_text(policy_text, encoding="utf-8")
    expect_failure(duplicate_policy, "invalid-policy")

    ats_allowlist = make_fixture(fixtures, "ats-generated-key-allowlist")
    policy = read_policy(ats_allowlist)
    policy["archiveGeneratedKeyAllowlist"] = ["NSAllowsArbitraryLoads"]
    write_policy(ats_allowlist, policy)
    expect_failure(ats_allowlist, "invalid-policy")

    substituted_source = make_fixture(fixtures, "substituted-source")
    policy = read_policy(substituted_source)
    sources = dict(policy["authoritativeSources"])
    sources["app"] = "Alternate/Info.plist"
    policy["authoritativeSources"] = sources
    write_policy(substituted_source, policy)
    alternate = substituted_source / "Alternate/Info.plist"
    alternate.parent.mkdir(parents=True)
    shutil.copyfile(source_app(substituted_source), alternate)
    expect_failure(substituted_source, "invalid-policy")

    ignored_environment_override = make_fixture(fixtures, "ignored-environment-override")
    value = read_plist(source_app(ignored_environment_override))
    value["NSAppTransportSecurity"] = {"NSAllowsArbitraryLoads": True}
    write_plist(source_app(ignored_environment_override), value)
    alternate_policy = ignored_environment_override / "permissive-policy.json"
    alternate_policy.write_text(POLICY.read_text(encoding="utf-8"), encoding="utf-8")
    result = run_verifier(
        ignored_environment_override,
        environment={"UTTERINK_INFO_POLICY_PATH": str(alternate_policy)},
    )
    if result.stderr != "release Info policy error: ats-policy\n" or result.returncode != 1:
        fail("environment variable substituted the authoritative policy")

for arguments in (
    ("unexpected",),
    ("--policy", str(POLICY)),
    ("--source", str(ROOT / "App/Supporting/Info.plist")),
    ("--archived",),
    ("--archived", str(ROOT / "App/Supporting/Info.plist"), "extra"),
):
    expect_failure(ROOT, "invalid-arguments", *arguments)

print("release Info policy tests passed")
