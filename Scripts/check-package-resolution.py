#!/usr/bin/env python3

import argparse
import json
import sys
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_AUTHORITATIVE = REPOSITORY_ROOT / "Packages" / "UtterInkKit" / "Package.resolved"
DEFAULT_WORKSPACE = (
    REPOSITORY_ROOT
    / "UtterInk.xcodeproj"
    / "project.xcworkspace"
    / "xcshareddata"
    / "swiftpm"
    / "Package.resolved"
)
SUPPORTED_LOCK_VERSIONS = frozenset({2, 3})


class ResolutionError(Exception):
    pass


def parse_arguments():
    parser = argparse.ArgumentParser(
        description="Validate UtterInk's authoritative and optional Xcode package locks."
    )
    parser.add_argument(
        "--authoritative",
        type=Path,
        default=DEFAULT_AUTHORITATIVE,
        help="authoritative SwiftPM Package.resolved path",
    )
    parser.add_argument(
        "--workspace",
        type=Path,
        default=DEFAULT_WORKSPACE,
        help="optional Xcode workspace Package.resolved path",
    )
    return parser.parse_args()


def load_graph(path, label, required):
    if not path.exists():
        if required:
            raise ResolutionError(f"{label} lock does not exist: {path}")
        return None
    if not path.is_file():
        raise ResolutionError(f"{label} lock is not a regular file: {path}")

    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError) as error:
        raise ResolutionError(f"cannot read {label} lock {path}: {error}") from error
    except json.JSONDecodeError as error:
        raise ResolutionError(
            f"invalid JSON in {label} lock {path}: line {error.lineno}, column {error.colno}"
        ) from error

    if not isinstance(document, dict):
        raise ResolutionError(f"{label} lock must be a JSON object with a pins array")
    schema_version = document.get("version")
    if type(schema_version) is not int:
        raise ResolutionError(
            f"{label} lock must declare an integer supported version"
        )
    if schema_version not in SUPPORTED_LOCK_VERSIONS:
        supported = ", ".join(str(version) for version in sorted(SUPPORTED_LOCK_VERSIONS))
        raise ResolutionError(
            f"{label} lock has unsupported version {schema_version}; "
            f"supported versions: {supported}"
        )
    pins = document.get("pins")
    if not isinstance(pins, list):
        raise ResolutionError(f"{label} lock must contain a pins array")

    graph = {}
    for index, package_pin in enumerate(pins):
        pin_label = f"{label} lock pin {index}"
        if not isinstance(package_pin, dict):
            raise ResolutionError(f"{pin_label} must be an object")

        identity = package_pin.get("identity")
        if not isinstance(identity, str) or not identity.strip():
            raise ResolutionError(f"{pin_label} identity must be a non-empty string")
        normalized_identity = identity.strip().casefold()
        if normalized_identity in graph:
            raise ResolutionError(
                f"{label} lock contains duplicate package identity: {normalized_identity}"
            )

        state = package_pin.get("state")
        if not isinstance(state, dict):
            raise ResolutionError(f"{pin_label} state must be an object")
        if "branch" in state:
            raise ResolutionError(
                f"{pin_label} uses a mutable branch state: {normalized_identity}"
            )

        version = state.get("version")
        revision = state.get("revision")
        if (
            not isinstance(version, str)
            or not version.strip()
            or not isinstance(revision, str)
            or not revision.strip()
        ):
            raise ResolutionError(
                f"{pin_label} must have non-empty version and revision values"
            )

        graph[normalized_identity] = (version, revision)

    return graph


def describe_graph_mismatch(authoritative, workspace):
    authoritative_identities = set(authoritative)
    workspace_identities = set(workspace)
    missing = sorted(authoritative_identities - workspace_identities)
    unexpected = sorted(workspace_identities - authoritative_identities)
    changed = sorted(
        identity
        for identity in authoritative_identities & workspace_identities
        if authoritative[identity] != workspace[identity]
    )

    details = []
    if missing:
        details.append(f"missing={','.join(missing)}")
    if unexpected:
        details.append(f"unexpected={','.join(unexpected)}")
    if changed:
        details.append(f"changed={','.join(changed)}")
    return "; ".join(details) or "unknown difference"


def main():
    arguments = parse_arguments()
    try:
        authoritative = load_graph(arguments.authoritative, "authoritative", required=True)
        workspace = load_graph(arguments.workspace, "workspace", required=False)
        if workspace is not None and workspace != authoritative:
            detail = describe_graph_mismatch(authoritative, workspace)
            raise ResolutionError(f"workspace lock graph mismatch: {detail}")
    except ResolutionError as error:
        print(f"package-resolution error: {error}", file=sys.stderr)
        return 1

    if workspace is None:
        print(
            "package resolution valid: "
            f"{len(authoritative)} authoritative pins; optional workspace lock absent"
        )
    else:
        print(
            "package resolution valid: "
            f"{len(authoritative)} authoritative pins; workspace lock matches"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
