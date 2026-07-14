#!/usr/bin/env python3
from __future__ import annotations

from dataclasses import dataclass
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import string
import sys
from typing import NoReturn


MAX_FILE_BYTES = 128 * 1024
EXPECTED_METADATA_KEYS = {
    "schemaVersion",
    "product",
    "configuration",
    "dmgFilenameTemplate",
    "supportedArchitectures",
    "releaseTag",
}
REQUIRED_SETTINGS = {
    "PRODUCT_BUNDLE_IDENTIFIER",
    "MACOSX_DEPLOYMENT_TARGET",
    "ARCHS",
    "ONLY_ACTIVE_ARCH",
    "SWIFT_VERSION",
    "MARKETING_VERSION",
    "CURRENT_PROJECT_VERSION",
    "ENABLE_HARDENED_RUNTIME",
}
DEBUG_ONLY_SETTINGS = {
    "SWIFT_OPTIMIZATION_LEVEL",
    "GCC_OPTIMIZATION_LEVEL",
    "ENABLE_TESTABILITY",
}
INCLUDE = re.compile(r'^#include\s+"([^"\r\n]+)"$')
ASSIGNMENT = re.compile(r"^([A-Z][A-Z0-9_]*)\s*=\s*(\S(?:.*\S)?)$")
UNRESOLVED = re.compile(r"\$\([^)]*\)|\$\{[^}]*\}")
SEMVER = re.compile(r"(?:0|[1-9][0-9]*)[.](?:0|[1-9][0-9]*)[.](?:0|[1-9][0-9]*)\Z")
BUILD_NUMBER = re.compile(r"[1-9][0-9]*\Z")


class MetadataError(Exception):
    def __init__(self, category: str):
        super().__init__(category)
        self.category = category


def reject(category: str) -> NoReturn:
    raise MetadataError(category)


@dataclass(frozen=True)
class Repository:
    root: Path
    config: Path

    @classmethod
    def current(cls) -> "Repository":
        try:
            script = Path(__file__).resolve(strict=True)
            root = script.parents[2]
            config = (root / "Config").resolve(strict=True)
            config.relative_to(root)
        except (IndexError, OSError, ValueError):
            reject("unsafe-config-path")
        if not config.is_dir():
            reject("unsafe-config-path")
        return cls(root=root, config=config)

    def checked_config_path(self, relative: PurePosixPath) -> Path:
        if relative.is_absolute() or not relative.parts or ".." in relative.parts:
            reject("unsafe-config-path")
        candidate = self.config.joinpath(*relative.parts)
        current = self.config
        for component in relative.parts:
            current = current / component
            try:
                metadata = os.lstat(current)
            except OSError:
                reject("missing-config-file")
            if stat.S_ISLNK(metadata.st_mode):
                reject("unsafe-config-path")
        try:
            resolved = candidate.resolve(strict=True)
            resolved.relative_to(self.config)
        except (OSError, ValueError):
            reject("unsafe-config-path")
        return resolved

    def read_config_text(self, relative: PurePosixPath) -> str:
        path = self.checked_config_path(relative)
        try:
            metadata = os.lstat(path)
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > MAX_FILE_BYTES:
                reject("unsafe-config-path")
            data = path.read_bytes()
        except OSError:
            reject("unsafe-config-path")
        if len(data) > MAX_FILE_BYTES or b"\x00" in data:
            reject("unsafe-config-path")
        try:
            return data.decode("utf-8", errors="strict")
        except UnicodeDecodeError:
            reject("invalid-config-syntax")


def parse_xcconfig(repository: Repository, entry: str) -> dict[str, str]:
    settings: dict[str, str] = {}
    active: list[PurePosixPath] = []

    def visit(relative: PurePosixPath) -> None:
        if relative in active:
            reject("include-cycle")
        active.append(relative)
        text = repository.read_config_text(relative)
        for raw_line in text.splitlines():
            line = raw_line.strip()
            if not line or line.startswith("//"):
                continue
            include = INCLUDE.fullmatch(line)
            if include is not None:
                target = PurePosixPath(include.group(1))
                if target.is_absolute() or ".." in target.parts:
                    reject("unsafe-config-path")
                visit(relative.parent / target)
                continue
            assignment = ASSIGNMENT.fullmatch(line)
            if assignment is None:
                reject("invalid-config-syntax")
            key, value = assignment.groups()
            if key in settings:
                reject("duplicate-setting")
            if UNRESOLVED.search(value):
                reject("unresolved-setting")
            settings[key] = value
        active.pop()

    visit(PurePosixPath(entry))
    return settings


def reject_duplicate_json_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            reject("invalid-metadata-schema")
        result[key] = value
    return result


def read_release_metadata(repository: Repository) -> dict[str, object]:
    text = repository.read_config_text(PurePosixPath("release-metadata.json"))
    try:
        value = json.loads(text, object_pairs_hook=reject_duplicate_json_keys)
    except (json.JSONDecodeError, UnicodeError):
        reject("invalid-metadata-schema")
    if not isinstance(value, dict) or set(value) != EXPECTED_METADATA_KEYS:
        reject("invalid-metadata-schema")
    if type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1:
        reject("invalid-metadata-schema")
    for key in ("product", "configuration", "dmgFilenameTemplate", "releaseTag"):
        if type(value[key]) is not str or not value[key]:
            reject("invalid-metadata-schema")
    architectures = value["supportedArchitectures"]
    if (
        type(architectures) is not list
        or not architectures
        or any(type(item) is not str or not item for item in architectures)
        or len(set(architectures)) != len(architectures)
    ):
        reject("invalid-metadata-schema")
    return value


def validate_settings(configuration: str, settings: dict[str, str]) -> None:
    allowed = REQUIRED_SETTINGS | (DEBUG_ONLY_SETTINGS if configuration == "Debug" else set())
    if not REQUIRED_SETTINGS.issubset(settings) or not set(settings).issubset(allowed):
        reject("invalid-config-setting")
    if settings["PRODUCT_BUNDLE_IDENTIFIER"] != "dev.utterink.UtterInk":
        reject("bundle-identifier-mismatch")
    if settings["MACOSX_DEPLOYMENT_TARGET"] != "14.0":
        reject("metadata-mismatch")
    if settings["ARCHS"] != "arm64":
        reject("unsupported-architecture")
    if settings["ONLY_ACTIVE_ARCH"] != "NO":
        reject("unsupported-architecture")
    if settings["SWIFT_VERSION"] != "5.0":
        reject("metadata-mismatch")
    if not SEMVER.fullmatch(settings["MARKETING_VERSION"]):
        reject("metadata-mismatch")
    if not BUILD_NUMBER.fullmatch(settings["CURRENT_PROJECT_VERSION"]):
        reject("metadata-mismatch")
    if settings["ENABLE_HARDENED_RUNTIME"] != "YES":
        reject("metadata-mismatch")


def expand_dmg_template(template: str, marketing_version: str, architecture: str) -> str:
    formatter = string.Formatter()
    fields: list[str] = []
    try:
        for _, field_name, format_spec, conversion in formatter.parse(template):
            if field_name is None:
                continue
            if format_spec or conversion or field_name not in {"marketingVersion", "architecture"}:
                reject("metadata-mismatch")
            fields.append(field_name)
        if sorted(fields) != ["architecture", "marketingVersion"]:
            reject("metadata-mismatch")
        filename = template.format(
            marketingVersion=marketing_version,
            architecture=architecture,
        )
    except (KeyError, ValueError):
        reject("metadata-mismatch")
    if filename != f"UtterInk-{marketing_version}-{architecture}.dmg":
        reject("metadata-mismatch")
    if Path(filename).name != filename or "/" in filename or "\\" in filename:
        reject("metadata-mismatch")
    return filename


def normalized_metadata() -> dict[str, str]:
    repository = Repository.current()
    debug = parse_xcconfig(repository, "Debug.xcconfig")
    release = parse_xcconfig(repository, "Release.xcconfig")
    validate_settings("Debug", debug)
    validate_settings("Release", release)
    for key in REQUIRED_SETTINGS:
        if debug[key] != release[key]:
            reject("configuration-mismatch")

    metadata = read_release_metadata(repository)
    if metadata["product"] != "UtterInk" or metadata["configuration"] != "Release":
        reject("metadata-mismatch")
    architectures = metadata["supportedArchitectures"]
    if architectures != ["arm64"] or release["ARCHS"] not in architectures:
        reject("unsupported-architecture")
    marketing_version = release["MARKETING_VERSION"]
    if metadata["releaseTag"] != f"v{marketing_version}":
        reject("metadata-mismatch")
    dmg_filename = expand_dmg_template(
        str(metadata["dmgFilenameTemplate"]),
        marketing_version,
        release["ARCHS"],
    )
    return {
        "product": str(metadata["product"]),
        "marketingVersion": marketing_version,
        "buildNumber": release["CURRENT_PROJECT_VERSION"],
        "bundleIdentifier": release["PRODUCT_BUNDLE_IDENTIFIER"],
        "deploymentTarget": release["MACOSX_DEPLOYMENT_TARGET"],
        "architecture": release["ARCHS"],
        "configuration": str(metadata["configuration"]),
        "dmgFilename": dmg_filename,
        "releaseTag": str(metadata["releaseTag"]),
    }


def main() -> int:
    if sys.argv[1:] != ["--json"]:
        print("release metadata error: invalid-arguments", file=sys.stderr)
        return 2
    try:
        metadata = normalized_metadata()
    except MetadataError as error:
        print(f"release metadata error: {error.category}", file=sys.stderr)
        return 1
    print(json.dumps(metadata, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
