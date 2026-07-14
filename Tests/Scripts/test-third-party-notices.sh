#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
COLLECTOR="$ROOT/Scripts/collect-third-party-notices.sh"
AUTHORITATIVE_LOCK="$ROOT/Packages/UtterInkKit/Package.resolved"
MODEL_CATALOG="$ROOT/Config/speech-model-catalog.json"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/utterink-third-party-notices.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

fail() {
  printf 'third-party notice test failed: %s\n' "$1" >&2
  exit 1
}

# Keep the first failure useful during TDD. None of these checks invokes the
# collector, SwiftPM, or the network.
[[ -f "$COLLECTOR" ]] || fail 'collector does not exist'
[[ -x "$COLLECTOR" ]] || fail 'collector is not executable'
for required in \
  LICENSE \
  NOTICE \
  TRADEMARKS.md \
  THIRD_PARTY_NOTICES.md \
  Packages/UtterInkKit/Package.resolved \
  Config/speech-model-catalog.json; do
  [[ -f "$ROOT/$required" ]] || fail "required input does not exist: $required"
  [[ ! -L "$ROOT/$required" ]] || fail "required input is a symlink: $required"
done

# This validator is intentionally independent of the production collector. It
# locks the currently reviewed dependency graph and the public Markdown schema,
# while deriving model rows from the authoritative catalog instead of copying a
# second model list into the test.
python3 - "$ROOT" <<'PY'
from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit


root = Path(sys.argv[1])


def reject(message: str) -> None:
    raise SystemExit(f"third-party notice contract failed: {message}")


def read_text(relative: str) -> str:
    path = root / relative
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        reject(f"cannot read {relative}: {error}")


def require_heading(text: str, heading: str, relative: str) -> None:
    if heading not in text.splitlines():
        reject(f"{relative} is missing exact heading {heading!r}")


def markdown_table(text: str, heading: str, columns: list[str], relative: str):
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
            reject(f"{relative} has a non-canonical Markdown table below {heading!r}")
        return [cell.strip() for cell in stripped[1:-1].split("|")]

    actual_columns = cells(lines[start])
    if actual_columns != columns:
        reject(
            f"{relative} table below {heading!r} has columns {actual_columns!r}; "
            f"expected {columns!r}"
        )
    separator = cells(lines[start + 1])
    if len(separator) != len(columns) or any(
        re.fullmatch(r":?-{3,}:?", cell) is None for cell in separator
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


def exact_https_url(value: object, label: str, immutable_revision: str | None = None) -> str:
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
        reject(f"{label} is not pinned to its immutable revision")
    return value


license_bytes = (root / "LICENSE").read_bytes()
# Canonical https://www.apache.org/licenses/LICENSE-2.0.txt, including its final
# newline. A wording change, added project preamble, BOM, or CRLF conversion is
# therefore rejected rather than silently called Apache-2.0.
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
    reject("NOTICE is missing the UtterInk 2026 copyright attribution")
if "The SwiftCrypto Project" not in notice:
    reject("NOTICE is missing the reviewed SwiftCrypto NOTICE propagation")
for forbidden_notice_name in (
    "KeyboardShortcuts",
    "SwiftASN1 Project",
    "Swift Argument Parser",
    "WhisperKit",
    "yyjson",
):
    if forbidden_notice_name.casefold() in notice.casefold():
        reject(
            "NOTICE includes a dependency without a shipped NOTICE propagation "
            f"obligation: {forbidden_notice_name}"
        )

trademarks = read_text("TRADEMARKS.md")
for heading in (
    "# UtterInk Trademark Policy",
    "## Source Code License",
    "## Permitted Uses",
    "## No Endorsement",
):
    require_heading(trademarks, heading, "TRADEMARKS.md")
trademark_scope = trademarks.casefold()
for terms, description in (
    (("apache license", "trademark rights"), "source license does not grant trademark rights"),
    (("descriptive", "nominative"), "descriptive and nominative use"),
    (("unmodified", "redistribution"), "unmodified redistribution identification"),
    (("endorsement", "affiliation", "sponsorship"), "no endorsement or affiliation claim"),
):
    if not all(term in trademark_scope for term in terms):
        reject(f"TRADEMARKS.md does not state {description}")

package_authority = {
    "keyboardshortcuts": {
        "version": "2.4.0",
        "revision": "1aef85578fdd4f9eaeeb8d53b7b4fc31bf08fe27",
        "location": "https://github.com/sindresorhus/KeyboardShortcuts",
        "license": "MIT",
        "license_url": "https://github.com/sindresorhus/KeyboardShortcuts/blob/1aef85578fdd4f9eaeeb8d53b7b4fc31bf08fe27/license",
        "status": "shipped-in-app",
        "obligation": "include-license-and-copyright",
    },
    "swift-argument-parser": {
        "version": "1.8.2",
        "revision": "6a52f3251125d74daf04fcbd5e6f08a75d074382",
        "location": "https://github.com/apple/swift-argument-parser.git",
        "license": "Apache-2.0",
        "license_url": "https://github.com/apple/swift-argument-parser/blob/6a52f3251125d74daf04fcbd5e6f08a75d074382/LICENSE.txt",
        "status": "resolved-only-not-shipped",
        "obligation": "none-not-shipped",
    },
    "swift-asn1": {
        "version": "1.7.1",
        "revision": "a9a5efd40eaf558a2bcd48d64b1d1646be686008",
        "location": "https://github.com/apple/swift-asn1.git",
        "license": "Apache-2.0",
        "license_url": "https://github.com/apple/swift-asn1/blob/a9a5efd40eaf558a2bcd48d64b1d1646be686008/LICENSE.txt",
        "status": "resolved-only-not-shipped",
        "obligation": "none-not-shipped",
    },
    "swift-collections": {
        "version": "1.6.0",
        "revision": "a0cb0954ecb21e4e31b0070e6ed5674e8556685a",
        "location": "https://github.com/apple/swift-collections.git",
        "license": "Apache-2.0",
        "license_url": "https://github.com/apple/swift-collections/blob/a0cb0954ecb21e4e31b0070e6ed5674e8556685a/LICENSE.txt",
        "status": "shipped-in-app",
        "obligation": "include-license",
    },
    "swift-crypto": {
        "version": "4.5.0",
        "revision": "1b6b2e274e85105bfa155183145a1dcfd63331f1",
        "location": "https://github.com/apple/swift-crypto.git",
        "license": "Apache-2.0",
        "license_url": "https://github.com/apple/swift-crypto/blob/1b6b2e274e85105bfa155183145a1dcfd63331f1/LICENSE.txt",
        "status": "shipped-in-app",
        "obligation": "include-license-and-notice",
    },
    "swift-jinja": {
        "version": "2.3.6",
        "revision": "0b67ecb79139f6addef8699eff3622808aa6c7dc",
        "location": "https://github.com/huggingface/swift-jinja.git",
        "license": "Apache-2.0",
        "license_url": "https://github.com/huggingface/swift-jinja/blob/0b67ecb79139f6addef8699eff3622808aa6c7dc/LICENSE",
        "status": "shipped-in-app",
        "obligation": "include-license",
    },
    "swift-transformers": {
        "version": "1.1.9",
        "revision": "150169bfba0889c229a2ce7494cf8949f18e6906",
        "location": "https://github.com/huggingface/swift-transformers.git",
        "license": "Apache-2.0",
        "license_url": "https://github.com/huggingface/swift-transformers/blob/150169bfba0889c229a2ce7494cf8949f18e6906/LICENSE",
        "status": "shipped-in-app",
        "obligation": "include-license",
    },
    "whisperkit": {
        "version": "0.18.0",
        "revision": "e2adabbe7d98dc4d0ab9a5b75424ecc42a9cdbef",
        "location": "https://github.com/argmaxinc/WhisperKit",
        "license": "MIT",
        "license_url": "https://github.com/argmaxinc/WhisperKit/blob/e2adabbe7d98dc4d0ab9a5b75424ecc42a9cdbef/LICENSE",
        "status": "shipped-in-app",
        "obligation": "include-license-and-copyright",
    },
    "yyjson": {
        "version": "0.12.0",
        "revision": "8b4a38dc994a110abaec8a400615567bd996105f",
        "location": "https://github.com/ibireme/yyjson.git",
        "license": "MIT",
        "license_url": "https://github.com/ibireme/yyjson/blob/8b4a38dc994a110abaec8a400615567bd996105f/LICENSE",
        "status": "shipped-in-app",
        "obligation": "include-license-and-copyright",
    },
}

try:
    lock = json.loads(read_text("Packages/UtterInkKit/Package.resolved"))
except json.JSONDecodeError as error:
    reject(f"Package.resolved is invalid JSON: {error}")
if not isinstance(lock, dict) or lock.get("version") != 2 or not isinstance(lock.get("pins"), list):
    reject("Package.resolved must use the reviewed version-2 pins schema")

actual_pins = {}
for index, pin in enumerate(lock["pins"]):
    if not isinstance(pin, dict):
        reject(f"Package.resolved pin {index} is not an object")
    identity = pin.get("identity")
    if not isinstance(identity, str) or identity != identity.casefold() or identity in actual_pins:
        reject(f"Package.resolved pin {index} has an invalid or duplicate identity")
    state = pin.get("state")
    if not isinstance(state, dict) or set(state) != {"revision", "version"}:
        reject(f"Package.resolved pin {identity} has mutable or unexpected state")
    if pin.get("kind") != "remoteSourceControl":
        reject(f"Package.resolved pin {identity} is not remote source control")
    actual_pins[identity] = pin

if set(actual_pins) != set(package_authority):
    reject("Package.resolved identities differ from the reviewed dependency inventory")
for identity, expected in package_authority.items():
    pin = actual_pins[identity]
    if pin["location"] != expected["location"] or pin["state"] != {
        "revision": expected["revision"],
        "version": expected["version"],
    }:
        reject(f"Package.resolved pin drifted from reviewed authority: {identity}")

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
rows_by_identity = {}
for row in package_rows:
    identity = row["Identity"]
    if identity in rows_by_identity:
        reject(f"THIRD_PARTY_NOTICES.md has duplicate package row: {identity}")
    rows_by_identity[identity] = row
if set(rows_by_identity) != set(package_authority):
    reject("THIRD_PARTY_NOTICES.md package rows do not exactly cover Package.resolved")
for identity, expected in package_authority.items():
    exact_https_url(expected["license_url"], f"{identity} reviewed license URL", expected["revision"])
    wanted = {
        "Identity": identity,
        "Version": expected["version"],
        "Revision": expected["revision"],
        "Source URL": expected["location"],
        "License": expected["license"],
        "License URL": expected["license_url"],
        "Distribution Status": expected["status"],
        "Notice Obligation": expected["obligation"],
        "Review Status": "reviewed",
    }
    if rows_by_identity[identity] != wanted:
        reject(f"THIRD_PARTY_NOTICES.md package row is not exact: {identity}")

try:
    catalog = json.loads(read_text("Config/speech-model-catalog.json"))
except json.JSONDecodeError as error:
    reject(f"speech-model-catalog.json is invalid JSON: {error}")
if not isinstance(catalog, dict) or not isinstance(catalog.get("models"), list) or not catalog["models"]:
    reject("speech-model-catalog.json must contain a non-empty models array")

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
model_rows_by_id = {}
for row in model_rows:
    model_id = row["Model ID"]
    if model_id in model_rows_by_id:
        reject(f"THIRD_PARTY_NOTICES.md has duplicate model row: {model_id}")
    model_rows_by_id[model_id] = row

models_by_id = {}
required_model_keys = {
    "id",
    "revision",
    "sourceURL",
    "licenseIdentifier",
    "licenseURL",
    "tokenizerRevision",
    "tokenizerSourceURL",
    "tokenizerLicenseIdentifier",
    "tokenizerLicenseURL",
    "noticeObligation",
    "reviewStatus",
}
for index, model in enumerate(catalog["models"]):
    if not isinstance(model, dict) or not required_model_keys.issubset(model):
        reject(f"speech model {index} lacks exact provenance/license fields")
    model_id = model["id"]
    if not isinstance(model_id, str) or not model_id or model_id in models_by_id:
        reject(f"speech model {index} has a missing or duplicate ID")
    revision = model["revision"]
    tokenizer_revision = model["tokenizerRevision"]
    for value, label in (
        (revision, f"{model_id} revision"),
        (tokenizer_revision, f"{model_id} tokenizer revision"),
    ):
        if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{40}", value) is None:
            reject(f"{label} is not an immutable lowercase commit")
    exact_https_url(model["sourceURL"], f"{model_id} source URL")
    exact_https_url(model["licenseURL"], f"{model_id} license URL", revision)
    exact_https_url(model["tokenizerSourceURL"], f"{model_id} tokenizer source URL")
    exact_https_url(
        model["tokenizerLicenseURL"],
        f"{model_id} tokenizer license URL",
        tokenizer_revision,
    )
    for key in ("licenseIdentifier", "tokenizerLicenseIdentifier", "noticeObligation"):
        if not isinstance(model[key], str) or not model[key]:
            reject(f"speech model {model_id} has an empty reviewed {key}")
    if model["reviewStatus"] != "reviewed":
        reject(f"speech model {model_id} is not reviewed")
    models_by_id[model_id] = model

if set(model_rows_by_id) != set(models_by_id):
    reject("THIRD_PARTY_NOTICES.md model rows do not exactly cover the model catalog")
for model_id, model in models_by_id.items():
    wanted = {
        "Model ID": model_id,
        "Model Revision": model["revision"],
        "Model Source URL": model["sourceURL"],
        "Model License": model["licenseIdentifier"],
        "Model License URL": model["licenseURL"],
        "Tokenizer Revision": model["tokenizerRevision"],
        "Tokenizer Source URL": model["tokenizerSourceURL"],
        "Tokenizer License": model["tokenizerLicenseIdentifier"],
        "Tokenizer License URL": model["tokenizerLicenseURL"],
        "Distribution Status": "runtime-download-only",
        "Repository Content": "no",
        "DMG Content": "no",
        "Notice Obligation": model["noticeObligation"],
        "Review Status": "reviewed",
    }
    if model_rows_by_id[model_id] != wanted:
        reject(f"THIRD_PARTY_NOTICES.md model row is not exact: {model_id}")
PY

BASE="$TMP/base"
mkdir -p \
  "$BASE/Scripts" \
  "$BASE/Packages/UtterInkKit" \
  "$BASE/Config" \
  "$BASE/bin" \
  "$BASE/.test-license-fixtures"
cp "$COLLECTOR" "$BASE/Scripts/collect-third-party-notices.sh"
if [[ -f "$ROOT/Scripts/check-package-resolution.py" ]]; then
  cp "$ROOT/Scripts/check-package-resolution.py" "$BASE/Scripts/check-package-resolution.py"
fi
cp "$AUTHORITATIVE_LOCK" "$BASE/Packages/UtterInkKit/Package.resolved"
cp "$MODEL_CATALOG" "$BASE/Config/speech-model-catalog.json"
for relative in LICENSE NOTICE TRADEMARKS.md THIRD_PARTY_NOTICES.md; do
  cp "$ROOT/$relative" "$BASE/$relative"
done

# Build byte-exact, offline legal fixtures from checked-in reviewed texts. The
# Apache variants are deterministic transformations of the canonical root
# license; each generated byte sequence is checked against its independently
# reviewed SHA-256 before a case can run.
python3 - "$BASE" <<'PY'
from __future__ import annotations

import base64
import hashlib
import sys
from pathlib import Path


root = Path(sys.argv[1])
fixture_root = root / ".test-license-fixtures"
root_license = (root / "LICENSE").read_text(encoding="utf-8")
third_party = (root / "THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8")
notice = (root / "NOTICE").read_text(encoding="utf-8")


def exact_section(document: str, heading: str) -> str:
    marker = f"{heading}\n\n"
    if document.count(marker) != 1:
        raise SystemExit(f"fixture source is missing exact heading: {heading}")
    start = document.index(marker) + len(marker)
    next_heading = document.find("\n#", start)
    return document[start:] if next_heading == -1 else document[start:next_heading]


asn1_license = (
    root_license.replace(
        "Apache License\n",
        "\n                                 Apache License\n",
        1,
    )
    .replace('brackets "{}"', 'brackets "[]"', 1)
    .replace(
        "Copyright {yyyy} {name of copyright owner}",
        "Copyright [yyyy] [name of copyright owner]",
        1,
    )
)
crypto_license = asn1_license.rstrip("\n") + "\n"
hugging_face_license = (
    root_license.replace(
        "Apache License\n",
        "                                 Apache License\n",
        1,
    )
    .replace('brackets "{}"', 'brackets "[]"', 1)
    .replace(
        "Copyright {yyyy} {name of copyright owner}",
        "Copyright 2022 Hugging Face SAS.",
        1,
    )
    .rstrip("\n")
    + "\n"
)
argument_parser_license = root_license.replace(
    "Apache License\n",
    "                                 Apache License\n",
    1,
)
for line_start in (
    "TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION",
    "1. Definitions.",
    "2. Grant of Copyright License. Subject",
    "3. Grant of Patent License. Subject",
    "4. Redistribution. You may",
    "5. Submission of Contributions. Unless",
    "6. Trademarks. This",
    "7. Disclaimer of Warranty. Unless",
    "8. Limitation of Liability. In",
    "9. Accepting Warranty or Additional Liability. While",
    "END OF TERMS AND CONDITIONS",
    "APPENDIX: How to apply the Apache License to your work.",
):
    argument_parser_license = argument_parser_license.replace(
        f"   {line_start}", f"    {line_start}", 1
    )
argument_parser_license = argument_parser_license.replace(
    'brackets "{}"', 'brackets "[]"', 1
).replace(
    "   Copyright {yyyy} {name of copyright owner}",
    "    Copyright [yyyy] [name of copyright owner]",
    1,
)
for line in (
    'Licensed under the Apache License, Version 2.0 (the "License");',
    "you may not use this file except in compliance with the License.",
    "You may obtain a copy of the License at",
    "Unless required by applicable law or agreed to in writing, software",
    'distributed under the License is distributed on an "AS IS" BASIS,',
    "WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.",
    "See the License for the specific language governing permissions and",
    "limitations under the License.",
):
    argument_parser_license = argument_parser_license.replace(
        f"   {line}", f"    {line}", 1
    )
argument_parser_license += (
    "\n\n## Runtime Library Exception to the Apache 2.0 License: ##\n\n\n"
    "    As an exception, if you use this Software to compile your source code and\n"
    "    portions of this Software are embedded into the binary product as a result,\n"
    "    you may redistribute such product without providing attribution as would\n"
    "    otherwise be required by Sections 4(a), 4(b) and 4(d) of the License.\n"
)

swift_asn1_notice = base64.b64decode(
    "CiAgICAgICAgICAgICAgICAgICAgICAgICAgICBUaGUgU3dpZnRBU04xIFByb2plY3QK"
    "ICAgICAgICAgICAgICAgICAgICAgICAgICAgID09PT09PT09PT09PT09PT09PT09PQ"
    "oKUGxlYXNlIHZpc2l0IHRoZSBTd2lmdEFTTjEgd2ViIHNpdGUgZm9yIG1vcmUgaW"
    "5mb3JtYXRpb246CgogICogaHR0cHM6Ly9naXRodWIuY29tL2FwcGxlL3N3aWZ0LW"
    "FzbjEKCkNvcHlyaWdodCAyMDIyIFRoZSBTd2lmdEFTTjEgUHJvamVjdAoKVGhlIFN3"
    "aWZ0QVNOMSBQcm9qZWN0IGxpY2Vuc2VzIHRoaXMgZmlsZSB0byB5b3UgdW5kZXIg"
    "dGhlIEFwYWNoZSBMaWNlbnNlLAp2ZXJzaW9uIDIuMCAodGhlICJMaWNlbnNlIik7"
    "IHlvdSBtYXkgbm90IHVzZSB0aGlzIGZpbGUgZXhjZXB0IGluIGNvbXBsaWFuY2UK"
    "d2l0aCB0aGUgTGljZW5zZS4gWW91IG1heSBvYnRhaW4gYSBjb3B5IG9mIHRoZSBM"
    "aWNlbnNlIGF0OgoKICBodHRwczovL3d3dy5hcGFjaGUub3JnL2xpY2Vuc2VzL0xJ"
    "Q0VOU0UtMi4wCgpVbmxlc3MgcmVxdWlyZWQgYnkgYXBwbGljYWJsZSBsYXcgb3Ig"
    "YWdyZWVkIHRvIGluIHdyaXRpbmcsIHNvZnR3YXJlCmRpc3RyaWJ1dGVkIHVuZGVy"
    "IHRoZSBMaWNlbnNlIGlzIGRpc3RyaWJ1dGVkIG9uIGFuICJBUyBJUyIgQkFTSVMs"
    "IFdJVEhPVVQKV0FSUkFOVElFUyBPUiBDT05ESVRJT05TIE9GIEFOWSBLSU5ELCBl"
    "aXRoZXIgZXhwcmVzcyBvciBpbXBsaWVkLiBTZWUgdGhlCkxpY2Vuc2UgZm9yIHRo"
    "ZSBzcGVjaWZpYyBsYW5ndWFnZSBnb3Zlcm5pbmcgcGVybWlzc2lvbnMgYW5kIGxp"
    "bWl0YXRpb25zCnVuZGVyIHRoZSBMaWNlbnNlLgoKQWxzbywgcGxlYXNlIHJlZmVy"
    "IHRvIGVhY2ggTElDRU5TRS50eHQgZmlsZSwgd2hpY2ggaXMgbG9jYXRlZCBpbgp0"
    "aGUgJ2xpY2Vuc2UnIGRpcmVjdG9yeSBvZiB0aGUgZGlzdHJpYnV0aW9uIGZpbGUs"
    "IGZvciB0aGUgbGljZW5zZSB0ZXJtcyBvZiB0aGUKY29tcG9uZW50cyB0aGF0IHRo"
    "aXMgcHJvZHVjdCBkZXBlbmRzIG9uLgoKLS0tCgpUaGlzIHByb2R1Y3QgY29udGFp"
    "bnMgZGVyaXZhdGlvbnMgb2YgdmFyaW91cyBzY3JpcHRzIGZyb20gU3dpZnROSU8u"
    "CgogICogTElDRU5TRSAoQXBhY2hlIExpY2Vuc2UgMi4wKToKICAgICogaHR0cHM6"
    "Ly93d3cuYXBhY2hlLm9yZy9saWNlbnNlcy9MSUNFTlNFLTIuMAogICogSE9NRVBB"
    "R0U6CiAgICAqIGh0dHBzOi8vZ2l0aHViLmNvbS9hcHBsZS9zd2lmdC1uaW8KICAg"
    "IAotLS0KClRoaXMgcHJvZHVjdCBjb250YWlucyBkZXJpdmF0aW9ucyBvZiB2YXJp"
    "b3VzIHNjcmlwdHMgZnJvbSBTd2lmdCBPcGVuQVBJIEdlbmVyYXRvci4KCiAgKiBM"
    "SUNFTlNFIChBcGFjaGUgTGljZW5zZSAyLjApOgogICAgKiBodHRwczovL3d3dy5h"
    "cGFjaGUub3JnL2xpY2Vuc2VzL0xJQ0VOU0UtMi4wCiAgKiBIT01FUEFHRToKICAg"
    "ICogaHR0cHM6Ly9naXRodWIuY29tL2FwcGxlL3N3aWZ0LW9wZW5hcGktZ2VuZXJh"
    "dG9yCg=="
)

fixtures = {
    ("KeyboardShortcuts", "license"): exact_section(
        third_party, "### KeyboardShortcuts"
    ).encode("utf-8"),
    ("swift-argument-parser", "LICENSE.txt"): argument_parser_license.encode("utf-8"),
    ("swift-asn1", "LICENSE.txt"): asn1_license.encode("utf-8"),
    ("swift-asn1", "NOTICE.txt"): swift_asn1_notice,
    ("swift-collections", "LICENSE.txt"): argument_parser_license.encode("utf-8"),
    ("swift-crypto", "LICENSE.txt"): crypto_license.encode("utf-8"),
    ("swift-crypto", "NOTICE.txt"): exact_section(
        notice, "## Third-Party Notices Requiring Propagation"
    ).encode("utf-8"),
    ("swift-jinja", "LICENSE"): hugging_face_license.encode("utf-8"),
    ("swift-transformers", "LICENSE"): hugging_face_license.encode("utf-8"),
    ("WhisperKit", "LICENSE"): exact_section(
        third_party, "### WhisperKit"
    ).encode("utf-8"),
    ("yyjson", "LICENSE"): exact_section(third_party, "### yyjson").encode("utf-8"),
}
expected_hashes = {
    ("KeyboardShortcuts", "license"): "5c932d88256b4ab958f64a856fa48e8bd1f55bc1d96b8149c65689e0c61789d3",
    ("swift-argument-parser", "LICENSE.txt"): "770af8291f708538d8ff885a0bbc4e045cd700531741c4f99528d435c14d7f55",
    ("swift-asn1", "LICENSE.txt"): "8c6db340475136df3c1201d458fa5755698eace76e510471ecc9d857d6083dac",
    ("swift-asn1", "NOTICE.txt"): "11dd3b3b783e6ec26098dd38ebc962986ea109b85447e28e62867b83bd0f8c5b",
    ("swift-collections", "LICENSE.txt"): "770af8291f708538d8ff885a0bbc4e045cd700531741c4f99528d435c14d7f55",
    ("swift-crypto", "LICENSE.txt"): "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30",
    ("swift-crypto", "NOTICE.txt"): "b3ddc2ae068e76b3beb71be03c0400f90090f9469aa491bf7b1ac42320af37b8",
    ("swift-jinja", "LICENSE"): "648b81e6c6f9975c3b6cf6d630229b6c8d6f1ddaef55f5770f576adda19f3495",
    ("swift-transformers", "LICENSE"): "648b81e6c6f9975c3b6cf6d630229b6c8d6f1ddaef55f5770f576adda19f3495",
    ("WhisperKit", "LICENSE"): "b8673adf319f1d6905c5c38cf69513f8857930fb3445566fa9839c6948bb85c4",
    ("yyjson", "LICENSE"): "45e384d3d52c73cba3a64d6e6c25d47cd738cd8a55c30629e3201046eda62947",
}
if set(fixtures) != set(expected_hashes):
    raise SystemExit("offline fixture inventory differs from reviewed hashes")
for key, content in fixtures.items():
    actual_hash = hashlib.sha256(content).hexdigest()
    if actual_hash != expected_hashes[key]:
        raise SystemExit(f"offline fixture bytes drifted for {key}: {actual_hash}")
    checkout, filename = key
    destination = fixture_root / checkout / filename
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(content)
PY

# The collector must execute the planned resolve command, but the test remains
# completely offline. The Swift spy materializes checkout legal fixtures at
# resolve time, simulating the post-resolution state of a clean clone.
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  '[[ "$*" == "package resolve --package-path Packages/UtterInkKit" ]] || {' \
  '  printf "unexpected swift invocation: %s\n" "$*" >&2' \
  '  exit 64' \
  '}' \
  'printf "%s\n" "$*" >> "${UTTERINK_SWIFT_LOG:?}"' \
  'checkout_root="${UTTERINK_FIXTURE_ROOT:?}/Packages/UtterInkKit/.build/checkouts"' \
  'rm -rf -- "$checkout_root"' \
  'mkdir -p "$checkout_root"' \
  'cp -R "${UTTERINK_FIXTURE_ROOT:?}/.test-license-fixtures/." "$checkout_root/"' \
  'if [[ "${UTTERINK_SWIFT_MUTATE_LOCK:-}" == "append-space" ]]; then' \
  '  printf " " >> "${UTTERINK_FIXTURE_ROOT:?}/Packages/UtterInkKit/Package.resolved"' \
  'fi' \
  > "$BASE/bin/swift"
chmod +x "$BASE/bin/swift"

# The production collector asks Git for each checkout's commit only; it does
# not reject ordinary SwiftPM worktree state. This offline spy returns the exact
# immutable revision associated with each checkout and can inject one mismatch.
cat > "$BASE/bin/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" == 5 ]] \
  && [[ "$1" == "-C" ]] \
  && [[ "$3" == "rev-parse" ]] \
  && [[ "$4" == "--verify" ]] \
  && [[ "$5" == 'HEAD^{commit}' ]] || {
  printf 'unexpected git invocation: %s\n' "$*" >&2
  exit 64
}
checkout="${2##*/}"
case "$checkout" in
  KeyboardShortcuts) revision='1aef85578fdd4f9eaeeb8d53b7b4fc31bf08fe27' ;;
  swift-argument-parser) revision='6a52f3251125d74daf04fcbd5e6f08a75d074382' ;;
  swift-asn1) revision='a9a5efd40eaf558a2bcd48d64b1d1646be686008' ;;
  swift-collections) revision='a0cb0954ecb21e4e31b0070e6ed5674e8556685a' ;;
  swift-crypto) revision='1b6b2e274e85105bfa155183145a1dcfd63331f1' ;;
  swift-jinja) revision='0b67ecb79139f6addef8699eff3622808aa6c7dc' ;;
  swift-transformers) revision='150169bfba0889c229a2ce7494cf8949f18e6906' ;;
  WhisperKit) revision='e2adabbe7d98dc4d0ab9a5b75424ecc42a9cdbef' ;;
  yyjson) revision='8b4a38dc994a110abaec8a400615567bd996105f' ;;
  *)
    printf 'unexpected checkout for git HEAD: %s\n' "$checkout" >&2
    exit 65
    ;;
esac
printf '%s\n' "$checkout" >> "${UTTERINK_GIT_LOG:?}"
if [[ "$checkout" == "${UTTERINK_BAD_GIT_CHECKOUT:-}" ]]; then
  revision='0000000000000000000000000000000000000000'
fi
printf '%s\n' "$revision"
SH
chmod +x "$BASE/bin/git"

CASE_NUMBER=0
CASE_ROOT=""
SWIFT_LOG=""
GIT_LOG=""
BAD_GIT_CHECKOUT=""
SWIFT_MUTATE_LOCK=""

new_case() {
  local label="$1"
  CASE_NUMBER=$((CASE_NUMBER + 1))
  CASE_ROOT="$TMP/$CASE_NUMBER-$label"
  cp -R "$BASE" "$CASE_ROOT"
  rm -rf -- "$CASE_ROOT/Packages/UtterInkKit/.build"
  SWIFT_LOG="$TMP/$CASE_NUMBER-$label.swift.log"
  GIT_LOG="$TMP/$CASE_NUMBER-$label.git.log"
  BAD_GIT_CHECKOUT=""
  SWIFT_MUTATE_LOCK=""
  : > "$SWIFT_LOG"
  : > "$GIT_LOG"
}

checked_fingerprint() {
  python3 - "$CASE_ROOT" <<'PY'
import hashlib
import os
import sys
from pathlib import Path

root = Path(sys.argv[1])
for relative in (
    "LICENSE",
    "NOTICE",
    "TRADEMARKS.md",
    "THIRD_PARTY_NOTICES.md",
    "Packages/UtterInkKit/Package.resolved",
    "Config/speech-model-catalog.json",
    "UtterInk.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
    "outside-lock.json",
    "outside-notices.md",
):
    path = root / relative
    if path.is_symlink():
        value = "symlink:" + os.readlink(path)
    elif not path.exists():
        value = "missing"
    else:
        value = "file:" + hashlib.sha256(path.read_bytes()).hexdigest()
    print(f"{relative}\t{value}")
PY
}

run_check() {
  (
    cd "$CASE_ROOT"
    PATH="$CASE_ROOT/bin:$PATH" \
      UTTERINK_FIXTURE_ROOT="$CASE_ROOT" \
      UTTERINK_SWIFT_LOG="$SWIFT_LOG" \
      UTTERINK_GIT_LOG="$GIT_LOG" \
      UTTERINK_BAD_GIT_CHECKOUT="$BAD_GIT_CHECKOUT" \
      UTTERINK_SWIFT_MUTATE_LOCK="$SWIFT_MUTATE_LOCK" \
      ./Scripts/collect-third-party-notices.sh --check
  )
}

assert_one_offline_resolve() {
  local count
  count="$(wc -l < "$SWIFT_LOG" | tr -d '[:space:]')"
  [[ "$count" == 1 ]] || fail "collector invoked swift $count times; expected exactly once"
  grep -Fx 'package resolve --package-path Packages/UtterInkKit' "$SWIFT_LOG" >/dev/null \
    || fail 'collector did not use the exact offline-resolved command contract'
}

assert_zero_offline_resolves() {
  local count
  count="$(wc -l < "$SWIFT_LOG" | tr -d '[:space:]')"
  [[ "$count" == 0 ]] || fail "collector invoked swift $count times; expected zero"
}

assert_nine_git_heads() {
  local count
  count="$(wc -l < "$GIT_LOG" | tr -d '[:space:]')"
  [[ "$count" == 9 ]] || fail "collector inspected $count Git HEADs; expected nine"
  [[ "$(sort -u "$GIT_LOG" | wc -l | tr -d '[:space:]')" == 9 ]] \
    || fail 'collector did not inspect nine distinct checkout Git HEADs'
}

expect_rejected() {
  local label="$1"
  local before
  local after
  before="$(checked_fingerprint)"
  if run_check > "$CASE_ROOT/stdout" 2> "$CASE_ROOT/stderr"; then
    fail "$label was accepted"
  fi
  after="$(checked_fingerprint)"
  [[ "$before" == "$after" ]] || fail "$label mutated a checked input during --check"
  [[ -s "$CASE_ROOT/stderr" ]] || fail "$label produced no diagnostic"
  assert_one_offline_resolve
}

expect_preflight_rejected() {
  local label="$1"
  local before
  local after
  before="$(checked_fingerprint)"
  if run_check > "$CASE_ROOT/stdout" 2> "$CASE_ROOT/stderr"; then
    fail "$label was accepted"
  fi
  after="$(checked_fingerprint)"
  [[ "$before" == "$after" ]] || fail "$label mutated a checked input during --check"
  [[ -s "$CASE_ROOT/stderr" ]] || fail "$label produced no diagnostic"
  assert_zero_offline_resolves
  [[ ! -s "$GIT_LOG" ]] || fail "$label inspected Git before failing preflight"
}

expect_resolve_lock_drift_rejected() {
  local label="$1"
  local lock="$CASE_ROOT/Packages/UtterInkKit/Package.resolved"
  local before
  local after
  local expected_diagnostic
  before="$(shasum -a 256 "$lock" | awk '{print $1}')"
  if run_check > "$CASE_ROOT/stdout" 2> "$CASE_ROOT/stderr"; then
    fail "$label was accepted"
  fi
  after="$(shasum -a 256 "$lock" | awk '{print $1}')"
  [[ "$before" != "$after" ]] || fail "$label did not actually rewrite Package.resolved"
  python3 - "$lock" <<'PY'
import sys
from pathlib import Path

content = Path(sys.argv[1]).read_bytes()
if not content.endswith(b"\n "):
    raise SystemExit("Swift spy did not append the controlled trailing byte")
PY
  expected_diagnostic='third-party notice check failed: swift package resolve changed the authoritative Package.resolved bytes'
  [[ "$(cat "$CASE_ROOT/stderr")" == "$expected_diagnostic" ]] \
    || fail "$label did not produce the exact lock-drift diagnostic"
  assert_one_offline_resolve
  [[ ! -s "$GIT_LOG" ]] || fail "$label inspected Git after lock drift was detected"
}

edit_notice_cell() {
  local key="$1"
  local column="$2"
  local value="$3"
  python3 - "$CASE_ROOT/THIRD_PARTY_NOTICES.md" "$key" "$column" "$value" <<'PY'
from pathlib import Path
import sys

path, key, column, value = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3]), sys.argv[4]
lines = path.read_text(encoding="utf-8").splitlines()
matched = 0
for index, line in enumerate(lines):
    if not line.startswith("|"):
        continue
    cells = [cell.strip() for cell in line[1:-1].split("|")]
    if cells and cells[0] == key:
        if column >= len(cells):
            raise SystemExit("fixture column is out of range")
        cells[column] = value
        lines[index] = "| " + " | ".join(cells) + " |"
        matched += 1
if matched != 1:
    raise SystemExit(f"expected one notice row for {key}, found {matched}")
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
}

remove_notice_row() {
  local key="$1"
  python3 - "$CASE_ROOT/THIRD_PARTY_NOTICES.md" "$key" <<'PY'
from pathlib import Path
import sys

path, key = Path(sys.argv[1]), sys.argv[2]
lines = path.read_text(encoding="utf-8").splitlines()
kept = []
removed = 0
for line in lines:
    if line.startswith("|"):
        cells = [cell.strip() for cell in line[1:-1].split("|")]
        if cells and cells[0] == key:
            removed += 1
            continue
    kept.append(line)
if removed != 1:
    raise SystemExit(f"expected one notice row for {key}, found {removed}")
path.write_text("\n".join(kept) + "\n", encoding="utf-8")
PY
}

duplicate_notice_row() {
  local key="$1"
  python3 - "$CASE_ROOT/THIRD_PARTY_NOTICES.md" "$key" <<'PY'
from pathlib import Path
import sys

path, key = Path(sys.argv[1]), sys.argv[2]
lines = path.read_text(encoding="utf-8").splitlines()
for index, line in enumerate(lines):
    if line.startswith("|"):
        cells = [cell.strip() for cell in line[1:-1].split("|")]
        if cells and cells[0] == key:
            lines.insert(index + 1, line)
            path.write_text("\n".join(lines) + "\n", encoding="utf-8")
            break
else:
    raise SystemExit(f"missing notice row for {key}")
PY
}

first_model_id() {
  python3 - "$CASE_ROOT/Config/speech-model-catalog.json" <<'PY'
import json
import sys
from pathlib import Path

print(json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))["models"][0]["id"])
PY
}

edit_first_model() {
  local field="$1"
  local json_value="$2"
  python3 - "$CASE_ROOT/Config/speech-model-catalog.json" "$field" "$json_value" <<'PY'
import json
import sys
from pathlib import Path

path, field, raw = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
document = json.loads(path.read_text(encoding="utf-8"))
document["models"][0][field] = json.loads(raw)
path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

# Happy path: a clean fixture resolves license checkouts offline, passes, and
# does not rewrite any checked-in legal, lock, catalog, or notice file.
new_case valid
valid_before="$(checked_fingerprint)"
run_check > "$CASE_ROOT/stdout" 2> "$CASE_ROOT/stderr" \
  || { sed 's/^/  /' "$CASE_ROOT/stderr" >&2; fail 'valid fixture was rejected'; }
valid_after="$(checked_fingerprint)"
[[ "$valid_before" == "$valid_after" ]] || fail '--check modified a checked input'
assert_one_offline_resolve
assert_nine_git_heads

new_case resolve-rewrites-authoritative-lock
SWIFT_MUTATE_LOCK='append-space'
expect_resolve_lock_drift_rejected 'resolve-time authoritative lock drift'

new_case workspace-lock-mismatch
mkdir -p "$CASE_ROOT/UtterInk.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
cp "$CASE_ROOT/Packages/UtterInkKit/Package.resolved" \
  "$CASE_ROOT/UtterInk.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
python3 - "$CASE_ROOT/UtterInk.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
document = json.loads(path.read_text(encoding="utf-8"))
document["pins"][0]["state"]["revision"] = "f" * 40
path.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
PY
expect_rejected 'workspace lock mismatch'

new_case missing-package-row
remove_notice_row keyboardshortcuts
expect_rejected 'missing package notice row'

new_case duplicate-package-row
duplicate_notice_row keyboardshortcuts
expect_rejected 'duplicate package notice row'

new_case mutable-package-state
python3 - "$CASE_ROOT/Packages/UtterInkKit/Package.resolved" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
document = json.loads(path.read_text(encoding="utf-8"))
document["pins"][0]["state"]["branch"] = "main"
path.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
PY
expect_rejected 'mutable package state'

new_case duplicate-package-pin
python3 - "$CASE_ROOT/Packages/UtterInkKit/Package.resolved" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
document = json.loads(path.read_text(encoding="utf-8"))
document["pins"].append(document["pins"][0])
path.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
PY
expect_rejected 'duplicate package pin'

new_case unsafe-package-location
python3 - "$CASE_ROOT/Packages/UtterInkKit/Package.resolved" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
document = json.loads(path.read_text(encoding="utf-8"))
document["pins"][0]["location"] = "../local-package"
path.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
PY
expect_rejected 'unsafe package source location'

new_case missing-package-license-url
edit_notice_cell keyboardshortcuts 5 ''
expect_rejected 'missing package license URL'

new_case missing-package-status
edit_notice_cell keyboardshortcuts 6 ''
expect_rejected 'missing package distribution status'

new_case missing-package-obligation
edit_notice_cell keyboardshortcuts 7 ''
expect_rejected 'missing package notice obligation'

new_case unreviewed-package-row
edit_notice_cell keyboardshortcuts 8 pending
expect_rejected 'unreviewed package row'

new_case missing-checkout-license
rm "$CASE_ROOT/.test-license-fixtures/KeyboardShortcuts/license"
expect_rejected 'missing resolved checkout license'

new_case wrong-checkout-git-head
BAD_GIT_CHECKOUT='WhisperKit'
expect_rejected 'resolved checkout at the wrong Git HEAD'
grep -Fx 'WhisperKit' "$GIT_LOG" >/dev/null \
  || fail 'wrong Git HEAD case did not reach the injected checkout'

new_case single-byte-checkout-license-mutation
python3 - "$CASE_ROOT/.test-license-fixtures/KeyboardShortcuts/license" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
content = path.read_bytes()
needle = b"Sindre Sorhus"
if content.count(needle) != 1:
    raise SystemExit("license fixture mutation target is not unique")
path.write_bytes(content.replace(needle, b"Sindre Xorhus", 1))
PY
expect_rejected 'single-byte resolved checkout license mutation'

new_case truncated-checkout-notice
python3 - "$CASE_ROOT/.test-license-fixtures/swift-crypto/NOTICE.txt" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
content = path.read_bytes()
if not content.endswith(b"\n"):
    raise SystemExit("NOTICE fixture does not have its reviewed final newline")
path.write_bytes(content[:-1])
PY
expect_rejected 'truncated resolved checkout NOTICE'

new_case single-character-mit-body-mutation
python3 - "$CASE_ROOT/THIRD_PARTY_NOTICES.md" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
content = path.read_text(encoding="utf-8")
needle = "Sindre Sorhus <sindresorhus@gmail.com>"
if content.count(needle) != 1:
    raise SystemExit("MIT body mutation target is not unique")
path.write_text(content.replace(needle, "Sindre Xorhus <sindresorhus@gmail.com>", 1), encoding="utf-8")
PY
expect_rejected 'single-character embedded MIT body mutation'

new_case single-character-propagated-notice-mutation
python3 - "$CASE_ROOT/NOTICE" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
content = path.read_text(encoding="utf-8")
needle = "https://github.com/apple/swift-nio"
if content.count(needle) != 1:
    raise SystemExit("propagated NOTICE mutation target is not unique")
path.write_text(content.replace(needle, "https://github.com/apple/swift-njo", 1), encoding="utf-8")
PY
expect_rejected 'single-character propagated NOTICE mutation'

new_case missing-model-row
MODEL_ID="$(first_model_id)"
remove_notice_row "$MODEL_ID"
expect_rejected 'missing model notice row'

new_case duplicate-model-row
MODEL_ID="$(first_model_id)"
duplicate_notice_row "$MODEL_ID"
expect_rejected 'duplicate model notice row'

new_case duplicate-model-catalog-entry
python3 - "$CASE_ROOT/Config/speech-model-catalog.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
document = json.loads(path.read_text(encoding="utf-8"))
document["models"].append(document["models"][0])
path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
expect_rejected 'duplicate model catalog entry'

new_case mutable-model-revision
edit_first_model revision '"main"'
expect_rejected 'mutable model revision'

new_case missing-model-license-url
edit_first_model licenseURL '""'
expect_rejected 'missing model license URL'

new_case unsafe-model-source
edit_first_model sourceURL '"../weights.bin"'
expect_rejected 'unsafe model source path'

new_case unreviewed-model-catalog-entry
edit_first_model reviewStatus '"pending"'
expect_rejected 'unreviewed model catalog entry'

new_case model-not-runtime-download
MODEL_ID="$(first_model_id)"
edit_notice_cell "$MODEL_ID" 9 shipped-in-app
expect_rejected 'model marked as shipped instead of runtime download'

new_case model-in-repository
MODEL_ID="$(first_model_id)"
edit_notice_cell "$MODEL_ID" 10 yes
expect_rejected 'model marked as repository content'

new_case model-in-dmg
MODEL_ID="$(first_model_id)"
edit_notice_cell "$MODEL_ID" 11 yes
expect_rejected 'model marked as DMG content'

new_case unreviewed-model-row
MODEL_ID="$(first_model_id)"
edit_notice_cell "$MODEL_ID" 13 pending
expect_rejected 'unreviewed model notice row'

new_case symlinked-authoritative-lock
mv "$CASE_ROOT/Packages/UtterInkKit/Package.resolved" "$CASE_ROOT/outside-lock.json"
ln -s ../../outside-lock.json "$CASE_ROOT/Packages/UtterInkKit/Package.resolved"
expect_preflight_rejected 'symlinked authoritative lock'

new_case symlinked-notices
mv "$CASE_ROOT/THIRD_PARTY_NOTICES.md" "$CASE_ROOT/outside-notices.md"
ln -s outside-notices.md "$CASE_ROOT/THIRD_PARTY_NOTICES.md"
expect_preflight_rejected 'symlinked notice output'

printf 'third-party notice tests passed (%d isolated cases)\n' "$CASE_NUMBER"
