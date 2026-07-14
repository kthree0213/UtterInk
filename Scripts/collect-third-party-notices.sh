#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'third-party notice check failed: %s\n' "$1" >&2
  exit 1
}

if [[ "$#" -ne 1 || "$1" != "--check" ]]; then
  fail 'usage: Scripts/collect-third-party-notices.sh --check'
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
AUTHORITATIVE_LOCK="$ROOT/Packages/UtterInkKit/Package.resolved"

# Reject links and special files before SwiftPM is allowed to run.  This
# preflight is intentionally broader than Package.resolved: `swift package
# resolve` must never get a chance to rewrite a lock when any authoritative
# legal/catalog input is unsafe.
python3 - "$ROOT" <<'PY'
from __future__ import annotations

import stat
import sys
from pathlib import Path


root = Path(sys.argv[1])
required = (
    "LICENSE",
    "NOTICE",
    "TRADEMARKS.md",
    "THIRD_PARTY_NOTICES.md",
    "Packages/UtterInkKit/Package.resolved",
    "Config/speech-model-catalog.json",
)
optional = (
    "UtterInk.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
)


def reject(message: str) -> None:
    raise SystemExit(f"third-party notice check failed: {message}")


def inspect(relative: str, *, required: bool) -> None:
    path = root / relative
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        if required:
            reject(f"required file does not exist: {relative}")
        return
    except OSError as error:
        reject(f"cannot inspect {relative} before resolve: {error}")
    if stat.S_ISLNK(metadata.st_mode):
        reject(f"required input is a symlink: {relative}")
    if not stat.S_ISREG(metadata.st_mode):
        reject(f"required input is not a regular file: {relative}")


for relative in required:
    inspect(relative, required=True)
for relative in optional:
    inspect(relative, required=False)
PY

# Keep the command and working directory stable: the offline contract test
# replaces `swift` with a spy that materializes clean-clone checkout fixtures.
lock_before="$(python3 - "$AUTHORITATIVE_LOCK" <<'PY'
import hashlib
import sys
from pathlib import Path

try:
    print(hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest())
except OSError as error:
    raise SystemExit(f"cannot fingerprint authoritative lock before resolve: {error}")
PY
)" || fail 'cannot fingerprint authoritative lock before resolve'

cd "$ROOT"
swift package resolve --package-path Packages/UtterInkKit \
  || fail 'Swift package resolution failed'

lock_after="$(python3 - "$AUTHORITATIVE_LOCK" <<'PY'
import hashlib
import sys
from pathlib import Path

try:
    print(hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest())
except OSError as error:
    raise SystemExit(f"cannot fingerprint authoritative lock after resolve: {error}")
PY
)" || fail 'cannot fingerprint authoritative lock after resolve'

[[ "$lock_before" == "$lock_after" ]] \
  || fail 'swift package resolve changed the authoritative Package.resolved bytes'

python3 - "$ROOT" <<'PY'
from __future__ import annotations

import hashlib
import json
import re
import stat
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlsplit


root = Path(sys.argv[1])


def reject(message: str) -> None:
    raise SystemExit(f"third-party notice check failed: {message}")


def regular_file(relative: str, *, required: bool = True) -> Path | None:
    path = root / relative
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        if required:
            reject(f"required file does not exist: {relative}")
        return None
    except OSError as error:
        reject(f"cannot inspect {relative}: {error}")
    if stat.S_ISLNK(metadata.st_mode):
        reject(f"required input is a symlink: {relative}")
    if not stat.S_ISREG(metadata.st_mode):
        reject(f"required input is not a regular file: {relative}")
    return path


def regular_directory(relative: str) -> Path:
    path = root / relative
    try:
        metadata = path.lstat()
    except OSError as error:
        reject(f"cannot inspect resolved checkout {relative}: {error}")
    if stat.S_ISLNK(metadata.st_mode):
        reject(f"resolved checkout is a symlink: {relative}")
    if not stat.S_ISDIR(metadata.st_mode):
        reject(f"resolved checkout is not a directory: {relative}")
    return path


def read_bytes(relative: str) -> bytes:
    path = regular_file(relative)
    assert path is not None
    try:
        return path.read_bytes()
    except OSError as error:
        reject(f"cannot read {relative}: {error}")


def read_text(relative: str) -> str:
    raw = read_bytes(relative)
    try:
        return raw.decode("utf-8")
    except UnicodeError as error:
        reject(f"{relative} is not UTF-8: {error}")


def load_json(relative: str) -> object:
    try:
        return json.loads(read_text(relative))
    except json.JSONDecodeError as error:
        reject(f"{relative} is invalid JSON at line {error.lineno}, column {error.colno}")


def require_heading(text: str, heading: str, relative: str) -> None:
    if heading not in text.splitlines():
        reject(f"{relative} is missing exact heading {heading!r}")


def markdown_section(text: str, heading: str, relative: str) -> str:
    marker = f"{heading}\n\n"
    if text.count(marker) != 1:
        reject(f"{relative} is missing exact heading {heading!r}")
    start = text.index(marker) + len(marker)
    # The blank line separating adjacent Markdown sections is not part of the
    # embedded legal text.  A final section extends exactly to EOF.
    next_heading = text.find("\n#", start)
    if next_heading == -1:
        return text[start:]
    return text[start:next_heading]


def exact_https_url(
    value: object,
    label: str,
    *,
    immutable_revision: str | None = None,
) -> str:
    if not isinstance(value, str) or not value:
        reject(f"{label} must be a non-empty HTTPS URL")
    parsed = urlsplit(value)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or ".." in parsed.path.split("/")
    ):
        reject(f"{label} is not a safe exact HTTPS URL")
    if immutable_revision is not None and immutable_revision not in value:
        reject(f"{label} is not pinned to immutable revision {immutable_revision}")
    return value


def markdown_table(
    text: str,
    heading: str,
    columns: list[str],
    relative: str,
) -> list[dict[str, str]]:
    lines = text.splitlines()
    try:
        start = lines.index(heading) + 1
    except ValueError:
        reject(f"{relative} is missing exact heading {heading!r}")
    while start < len(lines) and not lines[start].strip():
        start += 1
    if start + 1 >= len(lines):
        reject(f"{relative} has no table below {heading!r}")

    def cells(line: str) -> list[str]:
        stripped = line.strip()
        if not stripped.startswith("|") or not stripped.endswith("|"):
            reject(f"{relative} has a non-canonical table below {heading!r}")
        return [cell.strip() for cell in stripped[1:-1].split("|")]

    actual_columns = cells(lines[start])
    if actual_columns != columns:
        reject(
            f"{relative} table below {heading!r} has unexpected columns: "
            + ", ".join(actual_columns)
        )
    separators = cells(lines[start + 1])
    if len(separators) != len(columns) or any(
        re.fullmatch(r":?-{3,}:?", cell) is None for cell in separators
    ):
        reject(f"{relative} has an invalid table separator below {heading!r}")

    rows: list[dict[str, str]] = []
    for line in lines[start + 2 :]:
        if not line.strip() or line.startswith("#"):
            break
        values = cells(line)
        if len(values) != len(columns):
            reject(f"{relative} has a malformed row below {heading!r}")
        rows.append(dict(zip(columns, values)))
    if not rows:
        reject(f"{relative} has no rows below {heading!r}")
    return rows


package_authority = {
    "keyboardshortcuts": {
        "version": "2.4.0",
        "revision": "1aef85578fdd4f9eaeeb8d53b7b4fc31bf08fe27",
        "location": "https://github.com/sindresorhus/KeyboardShortcuts",
        "license": "MIT",
        "license_url": "https://github.com/sindresorhus/KeyboardShortcuts/blob/1aef85578fdd4f9eaeeb8d53b7b4fc31bf08fe27/license",
        "status": "shipped-in-app",
        "obligation": "include-license-and-copyright",
        "checkout": "KeyboardShortcuts",
        "license_file": "license",
        "license_sha256": "5c932d88256b4ab958f64a856fa48e8bd1f55bc1d96b8149c65689e0c61789d3",
    },
    "swift-argument-parser": {
        "version": "1.8.2",
        "revision": "6a52f3251125d74daf04fcbd5e6f08a75d074382",
        "location": "https://github.com/apple/swift-argument-parser.git",
        "license": "Apache-2.0",
        "license_url": "https://github.com/apple/swift-argument-parser/blob/6a52f3251125d74daf04fcbd5e6f08a75d074382/LICENSE.txt",
        "status": "resolved-only-not-shipped",
        "obligation": "none-not-shipped",
        "checkout": "swift-argument-parser",
        "license_file": "LICENSE.txt",
        "license_sha256": "770af8291f708538d8ff885a0bbc4e045cd700531741c4f99528d435c14d7f55",
    },
    "swift-asn1": {
        "version": "1.7.1",
        "revision": "a9a5efd40eaf558a2bcd48d64b1d1646be686008",
        "location": "https://github.com/apple/swift-asn1.git",
        "license": "Apache-2.0",
        "license_url": "https://github.com/apple/swift-asn1/blob/a9a5efd40eaf558a2bcd48d64b1d1646be686008/LICENSE.txt",
        "status": "resolved-only-not-shipped",
        "obligation": "none-not-shipped",
        "checkout": "swift-asn1",
        "license_file": "LICENSE.txt",
        "license_sha256": "8c6db340475136df3c1201d458fa5755698eace76e510471ecc9d857d6083dac",
        "notice_file": "NOTICE.txt",
        "notice_sha256": "11dd3b3b783e6ec26098dd38ebc962986ea109b85447e28e62867b83bd0f8c5b",
    },
    "swift-collections": {
        "version": "1.6.0",
        "revision": "a0cb0954ecb21e4e31b0070e6ed5674e8556685a",
        "location": "https://github.com/apple/swift-collections.git",
        "license": "Apache-2.0",
        "license_url": "https://github.com/apple/swift-collections/blob/a0cb0954ecb21e4e31b0070e6ed5674e8556685a/LICENSE.txt",
        "status": "shipped-in-app",
        "obligation": "include-license",
        "checkout": "swift-collections",
        "license_file": "LICENSE.txt",
        "license_sha256": "770af8291f708538d8ff885a0bbc4e045cd700531741c4f99528d435c14d7f55",
    },
    "swift-crypto": {
        "version": "4.5.0",
        "revision": "1b6b2e274e85105bfa155183145a1dcfd63331f1",
        "location": "https://github.com/apple/swift-crypto.git",
        "license": "Apache-2.0",
        "license_url": "https://github.com/apple/swift-crypto/blob/1b6b2e274e85105bfa155183145a1dcfd63331f1/LICENSE.txt",
        "status": "shipped-in-app",
        "obligation": "include-license-and-notice",
        "checkout": "swift-crypto",
        "license_file": "LICENSE.txt",
        "license_sha256": "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30",
        "notice_file": "NOTICE.txt",
        "notice_sha256": "b3ddc2ae068e76b3beb71be03c0400f90090f9469aa491bf7b1ac42320af37b8",
    },
    "swift-jinja": {
        "version": "2.3.6",
        "revision": "0b67ecb79139f6addef8699eff3622808aa6c7dc",
        "location": "https://github.com/huggingface/swift-jinja.git",
        "license": "Apache-2.0",
        "license_url": "https://github.com/huggingface/swift-jinja/blob/0b67ecb79139f6addef8699eff3622808aa6c7dc/LICENSE",
        "status": "shipped-in-app",
        "obligation": "include-license",
        "checkout": "swift-jinja",
        "license_file": "LICENSE",
        "license_sha256": "648b81e6c6f9975c3b6cf6d630229b6c8d6f1ddaef55f5770f576adda19f3495",
    },
    "swift-transformers": {
        "version": "1.1.9",
        "revision": "150169bfba0889c229a2ce7494cf8949f18e6906",
        "location": "https://github.com/huggingface/swift-transformers.git",
        "license": "Apache-2.0",
        "license_url": "https://github.com/huggingface/swift-transformers/blob/150169bfba0889c229a2ce7494cf8949f18e6906/LICENSE",
        "status": "shipped-in-app",
        "obligation": "include-license",
        "checkout": "swift-transformers",
        "license_file": "LICENSE",
        "license_sha256": "648b81e6c6f9975c3b6cf6d630229b6c8d6f1ddaef55f5770f576adda19f3495",
    },
    "whisperkit": {
        "version": "0.18.0",
        "revision": "e2adabbe7d98dc4d0ab9a5b75424ecc42a9cdbef",
        "location": "https://github.com/argmaxinc/WhisperKit",
        "license": "MIT",
        "license_url": "https://github.com/argmaxinc/WhisperKit/blob/e2adabbe7d98dc4d0ab9a5b75424ecc42a9cdbef/LICENSE",
        "status": "shipped-in-app",
        "obligation": "include-license-and-copyright",
        "checkout": "WhisperKit",
        "license_file": "LICENSE",
        "license_sha256": "b8673adf319f1d6905c5c38cf69513f8857930fb3445566fa9839c6948bb85c4",
    },
    "yyjson": {
        "version": "0.12.0",
        "revision": "8b4a38dc994a110abaec8a400615567bd996105f",
        "location": "https://github.com/ibireme/yyjson.git",
        "license": "MIT",
        "license_url": "https://github.com/ibireme/yyjson/blob/8b4a38dc994a110abaec8a400615567bd996105f/LICENSE",
        "status": "shipped-in-app",
        "obligation": "include-license-and-copyright",
        "checkout": "yyjson",
        "license_file": "LICENSE",
        "license_sha256": "45e384d3d52c73cba3a64d6e6c25d47cd738cd8a55c30629e3201046eda62947",
    },
}


def validate_lock(document: object, label: str) -> dict[str, dict[str, object]]:
    if not isinstance(document, dict) or document.get("version") != 2:
        reject(f"{label} must use the reviewed version-2 pins schema")
    if set(document) != {"pins", "version"}:
        reject(f"{label} has unexpected top-level fields")
    pins = document.get("pins")
    if not isinstance(pins, list):
        reject(f"{label} must contain a pins array")
    actual: dict[str, dict[str, object]] = {}
    for index, pin in enumerate(pins):
        if not isinstance(pin, dict):
            reject(f"{label} pin {index} is not an object")
        if set(pin) != {"identity", "kind", "location", "state"}:
            reject(f"{label} pin {index} has unexpected fields")
        identity = pin.get("identity")
        if (
            not isinstance(identity, str)
            or identity != identity.casefold()
            or not identity
            or identity in actual
        ):
            reject(f"{label} pin {index} has an invalid or duplicate identity")
        if pin.get("kind") != "remoteSourceControl":
            reject(f"{label} pin {identity} is not remote source control")
        exact_https_url(pin.get("location"), f"{label} {identity} source")
        state = pin.get("state")
        if not isinstance(state, dict) or set(state) != {"revision", "version"}:
            reject(f"{label} pin {identity} has mutable or unexpected state")
        revision = state.get("revision")
        if not isinstance(revision, str) or re.fullmatch(r"[0-9a-f]{40}", revision) is None:
            reject(f"{label} pin {identity} revision is not immutable")
        version = state.get("version")
        if not isinstance(version, str) or not version:
            reject(f"{label} pin {identity} version is empty")
        actual[identity] = pin
    return actual


authoritative = validate_lock(
    load_json("Packages/UtterInkKit/Package.resolved"),
    "authoritative lock",
)
if set(authoritative) != set(package_authority):
    reject("authoritative lock differs from the reviewed package inventory")
for identity, reviewed in package_authority.items():
    pin = authoritative[identity]
    wanted_state = {
        "revision": reviewed["revision"],
        "version": reviewed["version"],
    }
    if pin.get("location") != reviewed["location"] or pin.get("state") != wanted_state:
        reject(f"authoritative package pin drifted from review: {identity}")

workspace_relative = (
    "UtterInk.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
)
workspace_path = regular_file(workspace_relative, required=False)
if workspace_path is not None:
    workspace = validate_lock(load_json(workspace_relative), "workspace lock")
    if workspace != authoritative:
        reject("workspace lock does not exactly match the authoritative lock")

checkout_root = "Packages/UtterInkKit/.build/checkouts"
regular_directory(checkout_root)
checkout_license_texts: dict[str, str] = {}
checkout_notice_texts: dict[str, str] = {}
for identity, reviewed in package_authority.items():
    checkout = f"{checkout_root}/{reviewed['checkout']}"
    checkout_path = regular_directory(checkout)

    # SwiftPM checkouts may legitimately contain its own worktree metadata or
    # untracked build artifacts, so do not treat `git status` as authority.
    # The immutable commit plus exact reviewed legal-file bytes are the
    # relevant facts for this audit.
    try:
        head_result = subprocess.run(
            [
                "git",
                "-C",
                str(checkout_path),
                "rev-parse",
                "--verify",
                "HEAD^{commit}",
            ],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=15,
        )
    except (OSError, subprocess.SubprocessError) as error:
        reject(f"cannot inspect resolved checkout Git HEAD for {identity}: {error}")
    head_lines = head_result.stdout.splitlines()
    if head_result.returncode != 0 or len(head_lines) != 1:
        reject(f"cannot inspect resolved checkout Git HEAD for {identity}")
    checkout_head = head_lines[0]
    if (
        re.fullmatch(r"[0-9a-f]{40}", checkout_head) is None
        or checkout_head != reviewed["revision"]
    ):
        reject(f"resolved checkout Git HEAD differs from Package.resolved: {identity}")

    license_relative = f"{checkout}/{reviewed['license_file']}"
    license_bytes = read_bytes(license_relative)
    if hashlib.sha256(license_bytes).hexdigest() != reviewed["license_sha256"]:
        reject(f"resolved checkout LICENSE bytes differ from review: {identity}")
    try:
        checkout_license_texts[identity] = license_bytes.decode("utf-8")
    except UnicodeError as error:
        reject(f"resolved checkout LICENSE is not UTF-8 for {identity}: {error}")

    notice_file = reviewed.get("notice_file")
    if notice_file is not None:
        notice_relative = f"{checkout}/{notice_file}"
        notice_bytes = read_bytes(notice_relative)
        if hashlib.sha256(notice_bytes).hexdigest() != reviewed["notice_sha256"]:
            reject(f"resolved checkout NOTICE bytes differ from review: {identity}")
        try:
            checkout_notice_texts[identity] = notice_bytes.decode("utf-8")
        except UnicodeError as error:
            reject(f"resolved checkout NOTICE is not UTF-8 for {identity}: {error}")

license_bytes = read_bytes("LICENSE")
if len(license_bytes) != 11325 or hashlib.sha256(license_bytes).hexdigest() != (
    "cb5e8e7e5f4a3988e1063c142c60dc2df75605f4c46515e776e3aca6df976e14"
):
    reject("LICENSE is not the unmodified canonical Apache License 2.0 text")

notice = read_text("NOTICE")
require_heading(notice, "# UtterInk Notice", "NOTICE")
require_heading(
    notice,
    "## Third-Party Notices Requiring Propagation",
    "NOTICE",
)
if re.search(r"(?im)^Copyright 2026\b.*UtterInk", notice) is None:
    reject("NOTICE lacks the UtterInk 2026 copyright attribution")
propagated_notice = markdown_section(
    notice,
    "## Third-Party Notices Requiring Propagation",
    "NOTICE",
)
if propagated_notice != checkout_notice_texts["swift-crypto"]:
    reject("NOTICE propagated section differs from the exact SwiftCrypto NOTICE")
for forbidden in (
    "KeyboardShortcuts",
    "SwiftASN1 Project",
    "Swift Argument Parser",
    "WhisperKit",
    "yyjson",
):
    if forbidden.casefold() in notice.casefold():
        reject(f"NOTICE propagates an unreviewed notice entry: {forbidden}")

trademarks = read_text("TRADEMARKS.md")
for heading in (
    "# UtterInk Trademark Policy",
    "## Source Code License",
    "## Permitted Uses",
    "## No Endorsement",
):
    require_heading(trademarks, heading, "TRADEMARKS.md")
trademark_scope = trademarks.casefold()
for required_terms, description in (
    (("apache license", "trademark rights"), "source/trademark distinction"),
    (("descriptive", "nominative"), "descriptive and nominative use"),
    (("unmodified", "redistribution"), "unmodified redistribution"),
    (("endorsement", "affiliation", "sponsorship"), "no endorsement"),
):
    if not all(term in trademark_scope for term in required_terms):
        reject(f"TRADEMARKS.md lacks reviewed {description} language")

third_party = read_text("THIRD_PARTY_NOTICES.md")
require_heading(third_party, "# Third-Party Notices", "THIRD_PARTY_NOTICES.md")
package_columns = [
    "Identity",
    "Version",
    "Revision",
    "Source URL",
    "License",
    "License URL",
    "Distribution Status",
    "Notice Obligation",
    "Review Status",
]
package_rows = markdown_table(
    third_party,
    "## Swift Package Dependencies",
    package_columns,
    "THIRD_PARTY_NOTICES.md",
)
packages_by_identity: dict[str, dict[str, str]] = {}
for row in package_rows:
    identity = row["Identity"]
    if identity in packages_by_identity:
        reject(f"duplicate package notice row: {identity}")
    packages_by_identity[identity] = row
if set(packages_by_identity) != set(package_authority):
    reject("package notice rows do not exactly cover the reviewed lock")
for identity, reviewed in package_authority.items():
    exact_https_url(
        reviewed["license_url"],
        f"{identity} reviewed license URL",
        immutable_revision=str(reviewed["revision"]),
    )
    wanted = {
        "Identity": identity,
        "Version": str(reviewed["version"]),
        "Revision": str(reviewed["revision"]),
        "Source URL": str(reviewed["location"]),
        "License": str(reviewed["license"]),
        "License URL": str(reviewed["license_url"]),
        "Distribution Status": str(reviewed["status"]),
        "Notice Obligation": str(reviewed["obligation"]),
        "Review Status": "reviewed",
    }
    if packages_by_identity[identity] != wanted:
        reject(f"package notice row differs from review: {identity}")

for heading, identity in (
    ("### KeyboardShortcuts", "keyboardshortcuts"),
    ("### WhisperKit", "whisperkit"),
    ("### yyjson", "yyjson"),
):
    section = markdown_section(third_party, heading, "THIRD_PARTY_NOTICES.md")
    if section != checkout_license_texts[identity]:
        reject(f"{heading} body differs from the exact resolved checkout LICENSE")

catalog = load_json("Config/speech-model-catalog.json")
if not isinstance(catalog, dict) or not isinstance(catalog.get("models"), list):
    reject("speech-model-catalog.json must contain a models array")
if set(catalog) != {"defaultModelID", "models"}:
    reject("speech-model-catalog.json has unexpected top-level fields")
if catalog.get("defaultModelID") != "small":
    reject("speech-model-catalog.json default model drifted from review")
models = catalog["models"]
if not models:
    reject("speech-model-catalog.json has no reviewed models")

model_revision = "43ee8a5c2b72fb120079a4fb4a93f6e82057164a"
model_repository = "https://huggingface.co/argmaxinc/whisperkit-coreml"
model_license_url = f"{model_repository}/blob/{model_revision}/README.md"
model_authority = {
    "base": {
        "displayName": "Fast",
        "folder": "openai_whisper-base",
        "repository": "argmaxinc/whisperkit-coreml",
        "revision": model_revision,
        "sourceURL": f"{model_repository}/tree/{model_revision}/openai_whisper-base",
        "licenseIdentifier": "MIT",
        "licenseURL": model_license_url,
        "tokenizerRepository": "openai/whisper-base",
        "tokenizerRevision": "e37978b90ca9030d5170a5c07aadb050351a65bb",
        "tokenizerSourceURL": "https://huggingface.co/openai/whisper-base/tree/e37978b90ca9030d5170a5c07aadb050351a65bb",
        "tokenizerLicenseIdentifier": "Apache-2.0",
        "tokenizerLicenseURL": "https://huggingface.co/openai/whisper-base/blob/e37978b90ca9030d5170a5c07aadb050351a65bb/README.md",
        "approximateBytes": 149242445,
        "preset": "Fast",
        "releaseEvidence": "pending-functional-verification",
        "noticeObligation": "none-runtime-download-only",
        "reviewStatus": "reviewed",
    },
    "small": {
        "displayName": "Recommended",
        "folder": "openai_whisper-small",
        "repository": "argmaxinc/whisperkit-coreml",
        "revision": model_revision,
        "sourceURL": f"{model_repository}/tree/{model_revision}/openai_whisper-small",
        "licenseIdentifier": "MIT",
        "licenseURL": model_license_url,
        "tokenizerRepository": "openai/whisper-small",
        "tokenizerRevision": "973afd24965f72e36ca33b3055d56a652f456b4d",
        "tokenizerSourceURL": "https://huggingface.co/openai/whisper-small/tree/973afd24965f72e36ca33b3055d56a652f456b4d",
        "tokenizerLicenseIdentifier": "Apache-2.0",
        "tokenizerLicenseURL": "https://huggingface.co/openai/whisper-small/blob/973afd24965f72e36ca33b3055d56a652f456b4d/README.md",
        "approximateBytes": 488785875,
        "preset": "Recommended",
        "releaseEvidence": "pending-functional-verification",
        "noticeObligation": "none-runtime-download-only",
        "reviewStatus": "reviewed",
    },
    "large-v3": {
        "displayName": "Best Quality",
        "folder": "openai_whisper-large-v3",
        "repository": "argmaxinc/whisperkit-coreml",
        "revision": model_revision,
        "sourceURL": f"{model_repository}/tree/{model_revision}/openai_whisper-large-v3",
        "licenseIdentifier": "MIT",
        "licenseURL": model_license_url,
        "tokenizerRepository": "openai/whisper-large-v3",
        "tokenizerRevision": "06f233fe06e710322aca913c1bc4249a0d71fce1",
        "tokenizerSourceURL": "https://huggingface.co/openai/whisper-large-v3/tree/06f233fe06e710322aca913c1bc4249a0d71fce1",
        "tokenizerLicenseIdentifier": "Apache-2.0",
        "tokenizerLicenseURL": "https://huggingface.co/openai/whisper-large-v3/blob/06f233fe06e710322aca913c1bc4249a0d71fce1/README.md",
        "approximateBytes": 3091932457,
        "preset": "Best Quality",
        "releaseEvidence": "pending-functional-verification",
        "noticeObligation": "none-runtime-download-only",
        "reviewStatus": "reviewed",
    },
}

model_keys = {
    "id",
    "displayName",
    "folder",
    "repository",
    "revision",
    "sourceURL",
    "licenseIdentifier",
    "licenseURL",
    "tokenizerRepository",
    "tokenizerRevision",
    "tokenizerSourceURL",
    "tokenizerLicenseIdentifier",
    "tokenizerLicenseURL",
    "approximateBytes",
    "preset",
    "releaseEvidence",
    "noticeObligation",
    "reviewStatus",
}
models_by_id: dict[str, dict[str, object]] = {}
for index, model in enumerate(models):
    if not isinstance(model, dict) or set(model) != model_keys:
        reject(f"speech model {index} differs from the reviewed catalog schema")
    model_id = model.get("id")
    if not isinstance(model_id, str) or not model_id or model_id in models_by_id:
        reject(f"speech model {index} has a missing or duplicate ID")
    revision = model.get("revision")
    tokenizer_revision = model.get("tokenizerRevision")
    if not isinstance(revision, str) or re.fullmatch(r"[0-9a-f]{40}", revision) is None:
        reject(f"speech model {model_id} revision is not immutable")
    if (
        not isinstance(tokenizer_revision, str)
        or re.fullmatch(r"[0-9a-f]{40}", tokenizer_revision) is None
    ):
        reject(f"speech model {model_id} tokenizer revision is not immutable")
    exact_https_url(model.get("sourceURL"), f"{model_id} source URL")
    exact_https_url(
        model.get("licenseURL"),
        f"{model_id} license URL",
        immutable_revision=revision,
    )
    exact_https_url(model.get("tokenizerSourceURL"), f"{model_id} tokenizer source URL")
    exact_https_url(
        model.get("tokenizerLicenseURL"),
        f"{model_id} tokenizer license URL",
        immutable_revision=tokenizer_revision,
    )
    for field in (
        "licenseIdentifier",
        "tokenizerLicenseIdentifier",
        "noticeObligation",
    ):
        if not isinstance(model.get(field), str) or not model[field]:
            reject(f"speech model {model_id} has empty reviewed {field}")
    if model.get("reviewStatus") != "reviewed":
        reject(f"speech model {model_id} has not been reviewed")
    models_by_id[model_id] = model

if set(models_by_id) != set(model_authority):
    reject("speech model catalog differs from the reviewed model inventory")
for model_id, reviewed in model_authority.items():
    model = models_by_id[model_id]
    for field, wanted_value in reviewed.items():
        if model.get(field) != wanted_value:
            reject(f"speech model {model_id} {field} drifted from review")

model_columns = [
    "Model ID",
    "Model Revision",
    "Model Source URL",
    "Model License",
    "Model License URL",
    "Tokenizer Revision",
    "Tokenizer Source URL",
    "Tokenizer License",
    "Tokenizer License URL",
    "Distribution Status",
    "Repository Content",
    "DMG Content",
    "Notice Obligation",
    "Review Status",
]
model_rows = markdown_table(
    third_party,
    "## Runtime-Downloaded Speech Models",
    model_columns,
    "THIRD_PARTY_NOTICES.md",
)
model_rows_by_id: dict[str, dict[str, str]] = {}
for row in model_rows:
    model_id = row["Model ID"]
    if model_id in model_rows_by_id:
        reject(f"duplicate model notice row: {model_id}")
    model_rows_by_id[model_id] = row
if set(model_rows_by_id) != set(models_by_id):
    reject("model notice rows do not exactly cover the reviewed catalog")
for model_id, model in models_by_id.items():
    wanted = {
        "Model ID": model_id,
        "Model Revision": str(model["revision"]),
        "Model Source URL": str(model["sourceURL"]),
        "Model License": str(model["licenseIdentifier"]),
        "Model License URL": str(model["licenseURL"]),
        "Tokenizer Revision": str(model["tokenizerRevision"]),
        "Tokenizer Source URL": str(model["tokenizerSourceURL"]),
        "Tokenizer License": str(model["tokenizerLicenseIdentifier"]),
        "Tokenizer License URL": str(model["tokenizerLicenseURL"]),
        "Distribution Status": "runtime-download-only",
        "Repository Content": "no",
        "DMG Content": "no",
        "Notice Obligation": str(model["noticeObligation"]),
        "Review Status": "reviewed",
    }
    if model_rows_by_id[model_id] != wanted:
        reject(f"model notice row differs from reviewed catalog: {model_id}")

print(
    "third-party notices valid: "
    f"{len(package_authority)} package pins, {len(models_by_id)} runtime models"
)
PY
