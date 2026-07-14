#!/usr/bin/env python3
from __future__ import annotations

import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import stat
import sys
from typing import NoReturn
import xml.etree.ElementTree as ElementTree


MAX_FILE_BYTES = 128 * 1024
POLICY_PATH = PurePosixPath("Config/release-entitlements.json")
EXPECTED_POLICY_KEYS = {"schemaVersion", "app", "nestedComponents"}
EXPECTED_APP_KEYS = {"bundleIdentifier", "sourcePath", "entitlements"}
EXPECTED_ENTITLEMENT_KEYS = {"key", "value", "reason"}
EXPECTED_BUNDLE_IDENTIFIER = "dev.utterink.UtterInk"
EXPECTED_SOURCE_PATH = "App/Supporting/UtterInk.entitlements"
EXPECTED_ENTITLEMENT_KEY = "com.apple.security.device.audio-input"
EXPECTED_REASON = "Required for local microphone capture"
EXPECTED_ENTITLEMENTS = {EXPECTED_ENTITLEMENT_KEY: True}
OPTION_NAMES = {"--archived", "--signed"}


class EntitlementError(Exception):
    def __init__(self, category: str):
        super().__init__(category)
        self.category = category


def reject(category: str) -> NoReturn:
    raise EntitlementError(category)


def repository_root() -> Path:
    try:
        script = Path(__file__).resolve(strict=True)
        root = script.parents[2]
    except (IndexError, OSError):
        reject("unsafe-policy-file")
    if not root.is_dir():
        reject("unsafe-policy-file")
    return root


def checked_repository_path(root: Path, relative_text: str, category: str) -> Path:
    relative = PurePosixPath(relative_text)
    if relative.is_absolute() or not relative.parts or ".." in relative.parts:
        reject(category)
    current = root
    for component in relative.parts:
        current = current / component
        try:
            metadata = os.lstat(current)
        except OSError:
            reject(category)
        if stat.S_ISLNK(metadata.st_mode):
            reject(category)
    return current


def read_regular_file(path: Path, category: str) -> bytes:
    try:
        before = os.lstat(path)
    except (OSError, ValueError):
        reject(category)
    if not stat.S_ISREG(before.st_mode) or before.st_size > MAX_FILE_BYTES:
        reject(category)

    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except (OSError, ValueError):
        reject(category)
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_size > MAX_FILE_BYTES
            or opened.st_dev != before.st_dev
            or opened.st_ino != before.st_ino
        ):
            reject(category)
        chunks: list[bytes] = []
        remaining = MAX_FILE_BYTES + 1
        while remaining:
            chunk = os.read(descriptor, min(64 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
    except OSError:
        reject(category)
    finally:
        os.close(descriptor)
    if len(data) > MAX_FILE_BYTES:
        reject(category)
    return data


def reject_duplicate_json_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            reject("invalid-policy-schema")
        result[key] = value
    return result


def read_policy(root: Path) -> dict[str, object]:
    policy_path = checked_repository_path(root, str(POLICY_PATH), "unsafe-policy-file")
    data = read_regular_file(policy_path, "unsafe-policy-file")
    try:
        text = data.decode("utf-8", errors="strict")
        value = json.loads(text, object_pairs_hook=reject_duplicate_json_keys)
    except (UnicodeDecodeError, json.JSONDecodeError):
        reject("invalid-policy-schema")

    if type(value) is not dict or set(value) != EXPECTED_POLICY_KEYS:
        reject("invalid-policy-schema")
    if type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1:
        reject("invalid-policy-schema")
    if type(value["nestedComponents"]) is not list or value["nestedComponents"] != []:
        reject("invalid-policy-schema")

    app = value["app"]
    if type(app) is not dict or set(app) != EXPECTED_APP_KEYS:
        reject("invalid-policy-schema")
    if app["bundleIdentifier"] != EXPECTED_BUNDLE_IDENTIFIER or type(app["bundleIdentifier"]) is not str:
        reject("invalid-policy-schema")
    if app["sourcePath"] != EXPECTED_SOURCE_PATH or type(app["sourcePath"]) is not str:
        reject("invalid-policy-schema")

    inventory = app["entitlements"]
    if type(inventory) is not list or len(inventory) != 1:
        reject("invalid-policy-schema")
    item = inventory[0]
    if type(item) is not dict or set(item) != EXPECTED_ENTITLEMENT_KEYS:
        reject("invalid-policy-schema")
    if type(item["key"]) is not str or item["key"] != EXPECTED_ENTITLEMENT_KEY:
        reject("invalid-policy-schema")
    if type(item["value"]) is not bool or item["value"] is not True:
        reject("invalid-policy-schema")
    if type(item["reason"]) is not str or item["reason"] != EXPECTED_REASON:
        reject("invalid-policy-schema")
    return value


def reject_duplicate_xml_dictionary_keys(data: bytes) -> None:
    if data.startswith(b"bplist00"):
        return
    try:
        document = ElementTree.fromstring(data)
    except ElementTree.ParseError:
        reject("invalid-entitlements-plist")
    for dictionary in document.iter("dict"):
        children = list(dictionary)
        if len(children) % 2 != 0:
            reject("invalid-entitlements-plist")
        keys: set[str] = set()
        for offset in range(0, len(children), 2):
            key = children[offset]
            if key.tag != "key" or key.text is None or key.text in keys:
                reject("invalid-entitlements-plist")
            keys.add(key.text)


def read_entitlements(path: Path) -> dict[str, object]:
    data = read_regular_file(path, "unsafe-entitlements-file")
    reject_duplicate_xml_dictionary_keys(data)
    try:
        value = plistlib.loads(data)
    except Exception:
        reject("invalid-entitlements-plist")
    if type(value) is not dict:
        reject("entitlements-mismatch")
    if set(value) != set(EXPECTED_ENTITLEMENTS):
        reject("entitlements-mismatch")
    actual = value[EXPECTED_ENTITLEMENT_KEY]
    if type(actual) is not bool or actual is not True:
        reject("entitlements-mismatch")
    return value


def parse_arguments(arguments: list[str]) -> dict[str, Path]:
    parsed: dict[str, Path] = {}
    index = 0
    while index < len(arguments):
        option = arguments[index]
        if option not in OPTION_NAMES or option in parsed or index + 1 >= len(arguments):
            reject("invalid-arguments")
        value = arguments[index + 1]
        if not value or value.startswith("--"):
            reject("invalid-arguments")
        parsed[option] = Path(value)
        index += 2
    return parsed


def verify(arguments: list[str]) -> None:
    options = parse_arguments(arguments)
    root = repository_root()
    policy = read_policy(root)
    app = policy["app"]
    if type(app) is not dict:
        reject("invalid-policy-schema")
    source_path = checked_repository_path(root, str(app["sourcePath"]), "unsafe-entitlements-file")
    read_entitlements(source_path)
    for option in ("--archived", "--signed"):
        if option in options:
            read_entitlements(options[option])


def main() -> int:
    try:
        verify(sys.argv[1:])
    except EntitlementError as error:
        status = 2 if error.category == "invalid-arguments" else 1
        print(f"release entitlements error: {error.category}", file=sys.stderr)
        return status
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
