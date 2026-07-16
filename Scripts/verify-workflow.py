#!/usr/bin/env python3
from __future__ import annotations

import ast
from dataclasses import dataclass
import os
from pathlib import Path
import re
import stat
import sys
from typing import NoReturn


WORKFLOW_RELATIVE_PATH = Path(".github/workflows/ci.yml")
CHECKOUT_ACTION = "actions/checkout"
CHECKOUT_SHA = "de0fac2e4500dabe0009e67214ff5f5447ce83dd"
CHECKOUT_REFERENCE = f"{CHECKOUT_ACTION}@{CHECKOUT_SHA}"
RUNNER = "macos-26"
DEVELOPER_DIR = "/Applications/Xcode_26.4.app/Contents/Developer"
TIMEOUT_MINUTES = 75
MAX_WORKFLOW_BYTES = 64 * 1024
MAX_LINE_LENGTH = 4096

ACTION_REFERENCE = re.compile(
    r"(?P<action>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)@(?P<sha>[0-9a-f]{40})\Z"
)
SECRET_REFERENCE = re.compile(r"\bsecrets\s*\.", re.IGNORECASE)
CREDENTIAL_NAME = re.compile(
    r"(?:^|[^A-Z0-9])(?:"
    r"APPLE_(?:ID|APP_SPECIFIC_PASSWORD|TEAM_ID)|"
    r"ASC_(?:KEY_ID|ISSUER_ID)|"
    r"API_(?:KEY|TOKEN|SECRET)|"
    r"GITHUB_TOKEN|AUTH_TOKEN|ACCESS_TOKEN|CLIENT_SECRET|PRIVATE_KEY|"
    r"CERTIFICATE_PASSWORD|CODE_SIGN_IDENTITY|SIGNING_IDENTITY|"
    r"DEVELOPMENT_TEAM|PROVISIONING_PROFILE(?:_SPECIFIER)?"
    r")(?:$|[^A-Z0-9])",
    re.IGNORECASE,
)
FORBIDDEN_COMMANDS = tuple(
    re.compile(pattern, re.IGNORECASE)
    for pattern in (
        r"\bgh\s+release\b",
        r"\bgit\s+push\b",
        r"\bnotarytool\b",
        r"\baltool\b",
        r"\bcodesign\b",
        r"\bproductsign\b",
        r"\bsecurity\s+(?:import|find-identity)\b",
        r"\bxcrun\s+stapler\b",
    )
)


class WorkflowPolicyError(Exception):
    def __init__(self, category: str):
        super().__init__(category)
        self.category = category


@dataclass(frozen=True)
class YAMLLine:
    indent: int
    content: str


def reject(category: str) -> NoReturn:
    raise WorkflowPolicyError(category)


class RestrictedYAMLParser:
    """Parse only the small, inert YAML subset used by the CI policy.

    The workflow deliberately avoids YAML features that need object
    construction or implicit tag resolution. Tags, anchors, aliases, merge
    keys, block scalars, flow mappings, directives, and duplicate keys are
    rejected before policy checks see the resulting dictionaries and lists.
    """

    def __init__(self, source: str):
        self.lines: list[YAMLLine] = []
        for raw_line in source.splitlines():
            if len(raw_line) > MAX_LINE_LENGTH or "\t" in raw_line:
                reject("invalid-yaml")
            stripped = raw_line.lstrip(" ")
            if not stripped or stripped.startswith("#"):
                continue
            indent = len(raw_line) - len(stripped)
            if indent % 2 != 0:
                reject("invalid-yaml")
            if stripped in {"---", "..."} or stripped.startswith("%"):
                reject("unsafe-yaml")
            self.lines.append(YAMLLine(indent=indent, content=stripped))

    def parse(self) -> object:
        if not self.lines or self.lines[0].indent != 0:
            reject("invalid-yaml")
        value, index = self._parse_node(0, 0)
        if index != len(self.lines):
            reject("invalid-yaml")
        return value

    def _parse_node(self, index: int, indent: int) -> tuple[object, int]:
        if index >= len(self.lines) or self.lines[index].indent != indent:
            reject("invalid-yaml")
        if self.lines[index].content == "-" or self.lines[index].content.startswith("- "):
            return self._parse_sequence(index, indent)
        return self._parse_mapping(index, indent)

    def _parse_mapping(
        self,
        index: int,
        indent: int,
        initial: dict[str, object] | None = None,
    ) -> tuple[dict[str, object], int]:
        result = {} if initial is None else initial
        while index < len(self.lines):
            line = self.lines[index]
            if line.indent < indent:
                break
            if line.indent > indent or line.content == "-" or line.content.startswith("- "):
                break
            key, remainder = self._mapping_pair(line.content)
            if key in result:
                reject("invalid-yaml")
            index += 1
            value, index = self._value_or_nested(remainder, index, indent)
            result[key] = value
        return result, index

    def _parse_sequence(self, index: int, indent: int) -> tuple[list[object], int]:
        result: list[object] = []
        while index < len(self.lines):
            line = self.lines[index]
            if line.indent < indent:
                break
            if line.indent != indent:
                reject("invalid-yaml")
            if line.content == "-":
                remainder = ""
            elif line.content.startswith("- "):
                remainder = line.content[2:].strip()
            else:
                break
            index += 1
            if not remainder:
                if index >= len(self.lines) or self.lines[index].indent != indent + 2:
                    reject("invalid-yaml")
                value, index = self._parse_node(index, indent + 2)
                result.append(value)
                continue
            if ":" not in remainder:
                result.append(self._scalar(remainder))
                continue

            key, scalar_text = self._mapping_pair(remainder)
            item: dict[str, object] = {}
            value, index = self._value_or_nested(scalar_text, index, indent + 2)
            item[key] = value
            if index < len(self.lines) and self.lines[index].indent == indent + 2:
                if self.lines[index].content == "-" or self.lines[index].content.startswith("- "):
                    reject("invalid-yaml")
                item, index = self._parse_mapping(index, indent + 2, initial=item)
            result.append(item)
        return result, index

    def _value_or_nested(
        self,
        remainder: str,
        index: int,
        parent_indent: int,
    ) -> tuple[object, int]:
        if remainder:
            return self._scalar(remainder), index
        if index < len(self.lines) and self.lines[index].indent > parent_indent:
            if self.lines[index].indent != parent_indent + 2:
                reject("invalid-yaml")
            return self._parse_node(index, parent_indent + 2)
        return None, index

    @staticmethod
    def _mapping_pair(content: str) -> tuple[str, str]:
        if ":" not in content:
            reject("invalid-yaml")
        key_text, remainder = content.split(":", 1)
        key_text = key_text.strip()
        remainder = remainder.strip()
        if not key_text or key_text == "<<" or key_text.startswith(("!", "&", "*")):
            reject("unsafe-yaml")
        if key_text[0] in {"'", '"'}:
            key = RestrictedYAMLParser._quoted_string(key_text)
        else:
            if any(character in key_text for character in "{}[],#"):
                reject("invalid-yaml")
            key = key_text
        return key, remainder

    @staticmethod
    def _quoted_string(text: str) -> str:
        try:
            value = ast.literal_eval(text)
        except (SyntaxError, ValueError):
            reject("invalid-yaml")
        if not isinstance(value, str):
            reject("invalid-yaml")
        return value

    @staticmethod
    def _scalar(text: str) -> object:
        if not text:
            return None
        if text.startswith(("!", "&", "*")) or text in {"|", ">"}:
            reject("unsafe-yaml")
        if text.startswith("{"):
            reject("unsafe-yaml")
        if text[0] in {"'", '"'}:
            return RestrictedYAMLParser._quoted_string(text)
        if text.startswith("["):
            if not text.endswith("]"):
                reject("invalid-yaml")
            inner = text[1:-1].strip()
            if not inner:
                return []
            values = []
            for item in inner.split(","):
                item = item.strip()
                if not item or item.startswith("["):
                    reject("invalid-yaml")
                values.append(RestrictedYAMLParser._scalar(item))
            return values
        if text in {"true", "false"}:
            return text == "true"
        if text in {"null", "~"}:
            return None
        if re.fullmatch(r"-?(?:0|[1-9][0-9]*)", text):
            return int(text)
        return text


def all_mappings(value: object):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from all_mappings(child)
    elif isinstance(value, list):
        for child in value:
            yield from all_mappings(child)


def all_strings(value: object):
    if isinstance(value, dict):
        for key, child in value.items():
            yield key
            yield from all_strings(child)
    elif isinstance(value, list):
        for child in value:
            yield from all_strings(child)
    elif isinstance(value, str):
        yield value


def validate_sensitive_data(document: object) -> None:
    strings = tuple(all_strings(document))
    if any(SECRET_REFERENCE.search(value) for value in strings):
        reject("secret-reference")
    if any(CREDENTIAL_NAME.search(value) for value in strings):
        reject("credential-name")


def validate_permissions(document: dict[str, object]) -> None:
    if document.get("permissions") != {"contents": "read"}:
        reject("permissions")
    jobs = document.get("jobs")
    if jobs is not None:
        for mapping in all_mappings(jobs):
            if "permissions" in mapping:
                reject("permissions")


def validate_actions(document: object) -> None:
    for mapping in all_mappings(document):
        if "uses" not in mapping:
            continue
        reference = mapping["uses"]
        if not isinstance(reference, str):
            reject("action-reference")
        match = ACTION_REFERENCE.fullmatch(reference)
        if match is None:
            reject("action-reference")
        if match.group("action").casefold() == "actions/upload-artifact":
            reject("artifact-upload")
        if reference != CHECKOUT_REFERENCE:
            reject("action-not-allowed")


def validate_commands(document: object) -> None:
    for mapping in all_mappings(document):
        command = mapping.get("run")
        if command is None:
            continue
        if not isinstance(command, str):
            reject("forbidden-command")
        if any(pattern.search(command) for pattern in FORBIDDEN_COMMANDS):
            reject("forbidden-command")


def validate_exact_workflow(document: object) -> None:
    if not isinstance(document, dict):
        reject("workflow-shape")
    validate_sensitive_data(document)
    validate_permissions(document)
    validate_actions(document)
    validate_commands(document)

    if document.get("on") != {
        "pull_request": None,
        "push": {"branches": ["main"]},
    }:
        reject("triggers")
    if set(document) != {"name", "on", "permissions", "jobs"} or document.get("name") != "CI":
        reject("workflow-shape")

    jobs = document.get("jobs")
    if not isinstance(jobs, dict) or set(jobs) != {"verify"}:
        reject("jobs")
    job = jobs.get("verify")
    if not isinstance(job, dict):
        reject("jobs")
    if job.get("runs-on") != RUNNER:
        reject("runner")

    environment = job.get("env")
    if not isinstance(environment, dict):
        reject("developer-dir")
    if environment.get("DEVELOPER_DIR") != DEVELOPER_DIR:
        reject("developer-dir")
    if environment.get("UTTERINK_CI_RUNNER_LABEL") != RUNNER:
        reject("runner")
    if set(environment) != {"DEVELOPER_DIR", "UTTERINK_CI_RUNNER_LABEL"}:
        reject("environment")

    if set(job) != {"runs-on", "timeout-minutes", "env", "steps"}:
        reject("jobs")
    if job.get("timeout-minutes") != TIMEOUT_MINUTES:
        reject("jobs")

    steps = job.get("steps")
    if not isinstance(steps, list) or not steps:
        reject("steps")
    checkout_steps = [
        step
        for step in steps
        if isinstance(step, dict) and step.get("uses") == CHECKOUT_REFERENCE
    ]
    if len(checkout_steps) != 1:
        reject("checkout-policy")
    checkout = checkout_steps[0]
    if checkout.get("with") != {"fetch-depth": 0, "persist-credentials": False}:
        reject("checkout-policy")
    if set(checkout) != {"uses", "with"}:
        reject("checkout-policy")

    expected_steps: list[dict[str, object]] = [
        {
            "uses": CHECKOUT_REFERENCE,
            "with": {"fetch-depth": 0, "persist-credentials": False},
        },
        {
            "name": "Bootstrap locked XcodeGen",
            "run": "./Scripts/bootstrap-xcodegen.sh",
        },
        {
            "name": "Verify toolchain",
            "run": "./Scripts/verify-toolchain.sh --context ci",
        },
        {
            "name": "Verify workflow policy",
            "run": "python3 Scripts/verify-workflow.py",
        },
        {
            "name": "Run source, history, test, and build checks",
            "run": "./Scripts/ci-local.sh --ci --unsigned-package-smoke",
        },
        {
            "name": "Remove unsigned outputs",
            "if": "always()",
            "run": "./Scripts/clean-distribution-output.sh",
        },
    ]
    if steps != expected_steps:
        reject("steps")


def read_workflow() -> str:
    try:
        script_path = Path(__file__).resolve(strict=True)
        root = script_path.parents[1]
        workflow = root / WORKFLOW_RELATIVE_PATH
        metadata = os.lstat(workflow)
    except (FileNotFoundError, OSError, RuntimeError, IndexError):
        reject("unsafe-workflow")
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        reject("unsafe-workflow")
    if metadata.st_size > MAX_WORKFLOW_BYTES:
        reject("unsafe-workflow")
    try:
        return workflow.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        reject("unsafe-workflow")


def main() -> int:
    if len(sys.argv) != 1:
        print("workflow policy error: invalid-arguments", file=sys.stderr)
        return 2
    try:
        source = read_workflow()
        document = RestrictedYAMLParser(source).parse()
        validate_exact_workflow(document)
    except WorkflowPolicyError as error:
        print(f"workflow policy error: {error.category}", file=sys.stderr)
        return 1
    print("workflow policy valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
