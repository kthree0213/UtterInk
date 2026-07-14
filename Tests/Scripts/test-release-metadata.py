#!/usr/bin/env python3
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
READER = ROOT / "Scripts" / "release" / "read-metadata.py"
EXPECTED = {
    "product": "UtterInk",
    "marketingVersion": "0.1.0",
    "buildNumber": "1",
    "bundleIdentifier": "dev.utterink.UtterInk",
    "deploymentTarget": "14.0",
    "architecture": "arm64",
    "configuration": "Release",
    "dmgFilename": "UtterInk-0.1.0-arm64.dmg",
    "releaseTag": "v0.1.0",
}


def fail(reason: str) -> None:
    print(f"release metadata tests failed: {reason}", file=sys.stderr)
    raise SystemExit(1)


def sanitized_environment() -> dict[str, str]:
    environment = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("GIT_") and key not in {"PYTHONPATH", "PYTHONHOME"}
    }
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    return environment


def run_reader(root: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(root / "Scripts" / "release" / "read-metadata.py"), *arguments],
        cwd=root,
        env=sanitized_environment(),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )


def expect_failure(root: Path, category: str, *arguments: str) -> None:
    result = run_reader(root, *(arguments or ("--json",)))
    if result.returncode == 0:
        fail(f"{category} fixture unexpectedly passed")
    if result.stdout:
        fail(f"{category} fixture wrote metadata on failure")
    if result.stderr != f"release metadata error: {category}\n":
        fail(f"{category} fixture emitted a non-sanitized diagnostic")


def make_fixture(parent: Path, label: str) -> Path:
    fixture = parent / label
    shutil.copytree(ROOT / "Config", fixture / "Config")
    destination = fixture / "Scripts" / "release"
    destination.mkdir(parents=True)
    shutil.copyfile(READER, destination / "read-metadata.py")
    return fixture


if not READER.is_file():
    fail("metadata reader does not exist: Scripts/release/read-metadata.py")

result = run_reader(ROOT, "--json")
if result.returncode != 0:
    fail("metadata reader rejected the authoritative configuration")
if result.stderr:
    fail("metadata reader wrote to stderr for valid input")

try:
    metadata = json.loads(result.stdout)
except json.JSONDecodeError:
    fail("metadata reader did not emit one JSON value")
if metadata != EXPECTED:
    fail("normalized metadata does not match the approved 0.1.0 contract")
if result.stdout.count("\n") > 1 or not result.stdout.endswith("\n"):
    fail("metadata reader output is not one normalized JSON line")

invalid_arguments = run_reader(ROOT, "--json", "unexpected")
if invalid_arguments.returncode != 2:
    fail("metadata reader did not reject extra arguments with usage status")
if invalid_arguments.stdout or invalid_arguments.stderr != "release metadata error: invalid-arguments\n":
    fail("invalid argument diagnostic was not sanitized")

with tempfile.TemporaryDirectory(prefix="utterink-release-metadata-tests-") as temporary:
    fixtures = Path(temporary)

    duplicate_assignment = make_fixture(fixtures, "duplicate-assignment")
    with (duplicate_assignment / "Config" / "Release.xcconfig").open("a", encoding="utf-8") as handle:
        handle.write("ARCHS = arm64\n")
    expect_failure(duplicate_assignment, "duplicate-setting")

    cyclic_include = make_fixture(fixtures, "cyclic-include")
    base = cyclic_include / "Config" / "Base.xcconfig"
    base.write_text('#include "Release.xcconfig"\n' + base.read_text(encoding="utf-8"), encoding="utf-8")
    expect_failure(cyclic_include, "include-cycle")

    unresolved_value = make_fixture(fixtures, "unresolved-value")
    base = unresolved_value / "Config" / "Base.xcconfig"
    base.write_text(
        base.read_text(encoding="utf-8").replace("ARCHS = arm64", "ARCHS = $(SUPPORTED_ARCHS)"),
        encoding="utf-8",
    )
    expect_failure(unresolved_value, "unresolved-setting")

    unsupported_architecture = make_fixture(fixtures, "unsupported-architecture")
    base = unsupported_architecture / "Config" / "Base.xcconfig"
    base.write_text(
        base.read_text(encoding="utf-8").replace("ARCHS = arm64", "ARCHS = arm64 x86_64"),
        encoding="utf-8",
    )
    expect_failure(unsupported_architecture, "unsupported-architecture")

    bundle_mismatch = make_fixture(fixtures, "bundle-mismatch")
    base = bundle_mismatch / "Config" / "Base.xcconfig"
    base.write_text(
        base.read_text(encoding="utf-8").replace(
            "PRODUCT_BUNDLE_IDENTIFIER = dev.utterink.UtterInk",
            "PRODUCT_BUNDLE_IDENTIFIER = example.invalid.UtterInk",
        ),
        encoding="utf-8",
    )
    expect_failure(bundle_mismatch, "bundle-identifier-mismatch")

    configuration_drift = make_fixture(fixtures, "configuration-drift")
    debug = configuration_drift / "Config" / "Debug.xcconfig"
    debug.write_text(
        debug.read_text(encoding="utf-8").replace("MARKETING_VERSION = 0.1.0", "MARKETING_VERSION = 0.1.1"),
        encoding="utf-8",
    )
    expect_failure(configuration_drift, "configuration-mismatch")

    metadata_mismatch = make_fixture(fixtures, "metadata-mismatch")
    metadata_path = metadata_mismatch / "Config" / "release-metadata.json"
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    metadata["releaseTag"] = "v0.1.1"
    metadata_path.write_text(json.dumps(metadata), encoding="utf-8")
    expect_failure(metadata_mismatch, "metadata-mismatch")

    extra_metadata_key = make_fixture(fixtures, "extra-metadata-key")
    metadata_path = extra_metadata_key / "Config" / "release-metadata.json"
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    metadata["unexpected"] = True
    metadata_path.write_text(json.dumps(metadata), encoding="utf-8")
    expect_failure(extra_metadata_key, "invalid-metadata-schema")

    unsafe_config_path = make_fixture(fixtures, "unsafe-config-path")
    base = unsafe_config_path / "Config" / "Base.xcconfig"
    preserved = unsafe_config_path / "outside-base.xcconfig"
    base.replace(preserved)
    base.symlink_to(preserved)
    expect_failure(unsafe_config_path, "unsafe-config-path")

print("release metadata tests passed")
