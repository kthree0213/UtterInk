#!/usr/bin/env python3
from __future__ import annotations

import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import sys
from typing import NoReturn


MAX_FILE_BYTES = 1024 * 1024
POLICY_PATH = PurePosixPath("Config/release-info-policy.json")
APP_INFO_PATH = PurePosixPath("App/Supporting/Info.plist")
PROBE_INFO_PATH = PurePosixPath("Tests/ATSPolicyProbe/Info.plist")
AUTHORITATIVE_SOURCES = {
    "app": APP_INFO_PATH.as_posix(),
    "probe": PROBE_INFO_PATH.as_posix(),
}
POLICY_KEYS = {
    "schemaVersion",
    "finalShape",
    "authoritativeSources",
    "sourceAppOwnedFields",
    "sourceProbeOwnedFields",
    "archivedAppOwnedFields",
    "archiveGeneratedKeyAllowlist",
}
ATS_KEY = "NSAppTransportSecurity"
LOCAL_USAGE_KEY = "NSLocalNetworkUsageDescription"
LOCAL_NETWORK_ATS = {"NSAllowsLocalNetworking": True}
FORBIDDEN_ATS_KEYS = {
    "NSAllowsArbitraryLoads",
    "NSAllowsArbitraryLoadsForMedia",
    "NSAllowsArbitraryLoadsInWebContent",
    "NSExceptionDomains",
}
RESERVED_POLICY_KEYS = FORBIDDEN_ATS_KEYS | {
    ATS_KEY,
    LOCAL_USAGE_KEY,
    "NSAllowsLocalNetworking",
}
UNRESOLVED = re.compile(r"\$\([^)]*\)|\$\{[^}]*\}")
GENERATED_KEY = re.compile(r"[A-Za-z][A-Za-z0-9_.-]*\Z")

APP_SOURCE_FIELDS = {
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
PROBE_SOURCE_FIELDS = {
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
ARCHIVED_APP_FIELDS = {
    **APP_SOURCE_FIELDS,
    "CFBundleExecutable": "UtterInk",
    "CFBundleIdentifier": "dev.utterink.UtterInk",
    "CFBundleShortVersionString": "0.1.0",
    "CFBundleVersion": "1",
    "LSMinimumSystemVersion": "14.0",
}


class InfoPolicyError(Exception):
    def __init__(self, category: str):
        super().__init__(category)
        self.category = category


class DuplicatePlistKey(Exception):
    pass


class UniquePlistDictionary(dict[object, object]):
    def __setitem__(self, key: object, value: object) -> None:
        if key in self:
            raise DuplicatePlistKey
        super().__setitem__(key, value)


def reject(category: str) -> NoReturn:
    raise InfoPolicyError(category)


def checked_repository_root() -> Path:
    try:
        script = Path(__file__).resolve(strict=True)
        root = script.parents[2]
    except (IndexError, OSError):
        reject("unsafe-path")
    if not root.is_dir():
        reject("unsafe-path")
    return root


def read_regular_file(path: Path, *, root: Path | None = None) -> bytes:
    if root is not None:
        try:
            relative = path.relative_to(root)
        except ValueError:
            reject("unsafe-path")
        if not relative.parts:
            reject("unsafe-path")
        current = root
        components = relative.parts
    else:
        if not path.is_absolute():
            reject("unsafe-path")
        current = Path(path.anchor)
        components = path.parts[1:]

    for index, component in enumerate(components):
        current = current / component
        try:
            metadata = os.lstat(current)
        except FileNotFoundError:
            reject("missing-file")
        except OSError:
            reject("unsafe-path")
        if stat.S_ISLNK(metadata.st_mode):
            reject("unsafe-path")
        if index < len(components) - 1 and not stat.S_ISDIR(metadata.st_mode):
            reject("unsafe-path")

    try:
        metadata = os.lstat(current)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > MAX_FILE_BYTES:
            reject("unsafe-path")
        data = current.read_bytes()
    except InfoPolicyError:
        raise
    except OSError:
        reject("unsafe-path")
    if len(data) > MAX_FILE_BYTES:
        reject("unsafe-path")
    return data


def read_repository_file(root: Path, relative: PurePosixPath) -> bytes:
    if relative.is_absolute() or not relative.parts or ".." in relative.parts:
        reject("unsafe-path")
    return read_regular_file(root.joinpath(*relative.parts), root=root)


def duplicate_json_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            reject("invalid-policy")
        result[key] = value
    return result


def read_policy(root: Path) -> dict[str, object]:
    data = read_repository_file(root, POLICY_PATH)
    try:
        text = data.decode("utf-8", errors="strict")
        value = json.loads(text, object_pairs_hook=duplicate_json_keys)
    except InfoPolicyError:
        raise
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError, TypeError, RecursionError):
        reject("invalid-policy")
    if type(value) is not dict or set(value) != POLICY_KEYS:
        reject("invalid-policy")
    return value


def parse_plist(data: bytes) -> dict[str, object]:
    try:
        value = plistlib.loads(data, dict_type=UniquePlistDictionary)
    except DuplicatePlistKey:
        reject("duplicate-plist-key")
    except (plistlib.InvalidFileException, ValueError, TypeError, OverflowError, RecursionError):
        reject("invalid-plist")
    if not isinstance(value, dict):
        reject("invalid-plist")
    validate_plist_structure(value)
    return dict(value)


def validate_plist_structure(value: object) -> None:
    active: set[int] = set()
    complete: set[int] = set()
    pending: list[tuple[object, bool]] = [(value, False)]
    while pending:
        current, leaving = pending.pop()
        if not isinstance(current, (dict, list)):
            continue
        identity = id(current)
        if leaving:
            active.remove(identity)
            complete.add(identity)
            continue
        if identity in active:
            reject("invalid-plist")
        if identity in complete:
            continue
        if isinstance(current, dict) and any(type(key) is not str for key in current):
            reject("invalid-plist")
        active.add(identity)
        pending.append((current, True))
        if isinstance(current, dict):
            pending.extend((item, False) for item in current.values())
        else:
            pending.extend((item, False) for item in current)


def exact_field_map(value: object, expected: dict[str, object]) -> bool:
    if type(value) is not dict or set(value) != set(expected):
        return False
    for key, expected_value in expected.items():
        actual = value.get(key)
        if type(actual) is not type(expected_value) or actual != expected_value:
            return False
    return True


def validate_policy(policy: dict[str, object]) -> None:
    if type(policy["schemaVersion"]) is not int or policy["schemaVersion"] != 1:
        reject("invalid-policy")
    if type(policy["finalShape"]) is not str or policy["finalShape"] not in {
        "absent",
        "local-network-only",
    }:
        reject("invalid-policy")
    if policy["authoritativeSources"] != AUTHORITATIVE_SOURCES:
        reject("invalid-policy")
    if not exact_field_map(policy["sourceAppOwnedFields"], APP_SOURCE_FIELDS):
        reject("invalid-policy")
    if not exact_field_map(policy["sourceProbeOwnedFields"], PROBE_SOURCE_FIELDS):
        reject("invalid-policy")
    if not exact_field_map(policy["archivedAppOwnedFields"], ARCHIVED_APP_FIELDS):
        reject("invalid-policy")

    allowlist = policy["archiveGeneratedKeyAllowlist"]
    if (
        type(allowlist) is not list
        or any(type(key) is not str or not GENERATED_KEY.fullmatch(key) for key in allowlist)
        or len(allowlist) != len(set(allowlist))
        or any(key in ARCHIVED_APP_FIELDS or key in RESERVED_POLICY_KEYS for key in allowlist)
    ):
        reject("invalid-policy")


def validate_ats(info: dict[str, object], final_shape: str) -> None:
    if LOCAL_USAGE_KEY in info:
        reject("local-network-usage-description")
    if contains_forbidden_ats_key(info):
        reject("ats-policy")
    if final_shape == "absent":
        if ATS_KEY in info:
            reject("ats-policy")
        return
    if ATS_KEY not in info:
        reject("ats-policy")
    ats = info[ATS_KEY]
    if not isinstance(ats, dict) or set(ats) != set(LOCAL_NETWORK_ATS):
        reject("ats-policy")
    value = ats["NSAllowsLocalNetworking"]
    if type(value) is not bool or value is not True:
        reject("ats-policy")


def contains_forbidden_ats_key(value: object) -> bool:
    pending = [value]
    seen_containers: set[int] = set()
    while pending:
        current = pending.pop()
        if isinstance(current, dict):
            identity = id(current)
            if identity in seen_containers:
                continue
            seen_containers.add(identity)
            for key, item in current.items():
                if type(key) is str and key in FORBIDDEN_ATS_KEYS:
                    return True
                pending.append(item)
        elif isinstance(current, list):
            identity = id(current)
            if identity in seen_containers:
                continue
            seen_containers.add(identity)
            pending.extend(current)
    return False


def without_ats(info: dict[str, object]) -> dict[str, object]:
    return {key: value for key, value in info.items() if key != ATS_KEY}


def validate_source(
    info: dict[str, object],
    expected_fields: dict[str, object],
    final_shape: str,
) -> None:
    validate_ats(info, final_shape)
    if not exact_field_map(without_ats(info), expected_fields):
        reject("source-fields")


def has_unresolved_placeholder(value: object) -> bool:
    pending = [value]
    seen_containers: set[int] = set()
    while pending:
        current = pending.pop()
        if type(current) is str and UNRESOLVED.search(current) is not None:
            return True
        if isinstance(current, dict):
            identity = id(current)
            if identity in seen_containers:
                continue
            seen_containers.add(identity)
            pending.extend(current.keys())
            pending.extend(current.values())
        elif isinstance(current, list):
            identity = id(current)
            if identity in seen_containers:
                continue
            seen_containers.add(identity)
            pending.extend(current)
    return False


def validate_archive(
    info: dict[str, object],
    policy: dict[str, object],
) -> None:
    if has_unresolved_placeholder(info):
        reject("unresolved-archive-placeholder")
    final_shape = str(policy["finalShape"])
    validate_ats(info, final_shape)

    owned = {key: info[key] for key in ARCHIVED_APP_FIELDS if key in info}
    if not exact_field_map(owned, ARCHIVED_APP_FIELDS):
        reject("archived-fields")

    excluded = set(ARCHIVED_APP_FIELDS)
    if final_shape == "local-network-only":
        excluded.add(ATS_KEY)
    generated = set(info) - excluded
    allowlist = set(policy["archiveGeneratedKeyAllowlist"])
    if not generated.issubset(allowlist):
        reject("unexpected-generated-key")


def archive_path(root: Path, argument: str) -> Path:
    if not argument or "\x00" in argument:
        reject("invalid-arguments")
    candidate = Path(argument)
    if not candidate.is_absolute():
        candidate = root / candidate
    return Path(os.path.abspath(candidate))


def main(arguments: list[str]) -> int:
    if not arguments:
        archived_argument: str | None = None
    elif len(arguments) == 2 and arguments[0] == "--archived" and not arguments[1].startswith("--"):
        archived_argument = arguments[1]
    else:
        reject("invalid-arguments")

    root = checked_repository_root()
    policy = read_policy(root)
    validate_policy(policy)
    final_shape = str(policy["finalShape"])

    app_info = parse_plist(read_repository_file(root, APP_INFO_PATH))
    probe_info = parse_plist(read_repository_file(root, PROBE_INFO_PATH))
    validate_source(app_info, APP_SOURCE_FIELDS, final_shape)
    validate_source(probe_info, PROBE_SOURCE_FIELDS, final_shape)

    if archived_argument is not None:
        archived = parse_plist(read_regular_file(archive_path(root, archived_argument)))
        validate_archive(archived, policy)

    print("release Info policy valid")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except InfoPolicyError as error:
        print(f"release Info policy error: {error.category}", file=sys.stderr)
        raise SystemExit(2 if error.category == "invalid-arguments" else 1)
