#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BASELINE="$ROOT/docs/parity/flowtype-behavior-baseline.md"
EVIDENCE="$ROOT/docs/parity/utterink-parity-evidence.md"
ACCESSIBILITY_MATRIX="$ROOT/docs/parity/accessibility-matrix.md"

if [[ "$#" -ne 0 ]]; then
  printf 'unknown parity checker argument: %s\n' "$1" >&2
  exit 64
fi

for required in "$BASELINE" "$ACCESSIBILITY_MATRIX"; do
  if [[ ! -f "$required" ]]; then
    printf 'missing required parity input: %s\n' "${required#"$ROOT"/}" >&2
    exit 1
  fi
done

if [[ ! -f "$EVIDENCE" ]]; then
  printf 'missing parity evidence map: %s\n' "${EVIDENCE#"$ROOT"/}" >&2
  exit 1
fi

python3 - "$ROOT" "$BASELINE" "$EVIDENCE" "$ACCESSIBILITY_MATRIX" <<'PY'
from __future__ import annotations

from datetime import date
from pathlib import Path
import re
import shlex
import subprocess
import sys


ROOT = Path(sys.argv[1]).resolve(strict=True)
BASELINE = Path(sys.argv[2])
EVIDENCE = Path(sys.argv[3])
ACCESSIBILITY_MATRIX = Path(sys.argv[4])

EVIDENCE_HEADERS = (
    "ID",
    "Behavior exact baseline",
    "Status",
    "Evidence path",
    "Exact passing test(s)",
    "Passing command",
    "Date + baseline commit",
    "Intentional safety difference",
)

EXPECTED_BASELINE_ROWS = (
    (
        "Menu-bar lifecycle",
        "FlowTypeApp, MenuBarRootView",
        "UtterInk menu and settings launch",
    ),
    (
        "Toggle and push-to-talk",
        "HotkeyManager",
        "Intent-only hotkey tests for both modes",
    ),
    (
        "Microphone CAF recording and level",
        "MicrophoneRecorder",
        "Permission/capture/cleanup adapter tests",
    ),
    (
        "WhisperKit download/load/transcribe",
        "FlowCoordinator, WhisperModelCacheInspector",
        "Separate model state plus local transcription integration",
    ),
    (
        "Language and auto-detect",
        "SpeechTranscriptionSettings",
        "Immutable session recognition snapshot",
    ),
    (
        "Raw and custom output modes",
        "OutputModesStorage",
        "Raw-first pipeline and editable modes",
    ),
    (
        "OpenAI-compatible providers",
        "LLMProviderCatalog, LLMProcessor",
        "HTTPS/loopback policy, Keychain, sanitized errors",
    ),
    (
        "Raw fallback",
        "FlowCoordinator.finishTranscribedPipeline",
        "Raw persisted before polish; warning on fallback",
    ),
    (
        "Paste",
        "TextInjector",
        "Target/focus validation and guarded restoration",
    ),
    (
        "Floating status",
        "DynamicIslandView",
        "Stage-specific non-authoritative view",
    ),
    (
        "Onboarding/settings",
        "OnboardingView, SettingsView",
        "First-success onboarding and complete P0 settings",
    ),
)

ACCESSIBILITY_HEADERS = (
    "Surface / state",
    "Name / role / value / actions",
    "State / error VoiceOver announcement",
    "Keyboard traversal / visible focus / no trap / focus return",
    "Icon-only label",
    "Non-color distinction",
    "Light / dark",
    "Increase Contrast",
    "Differentiate Without Color",
    "Reduce Motion",
    "Larger text / display clipping",
    "Result",
    "macOS / build / architecture",
    "Reviewer / date",
)

EXPECTED_ACCESSIBILITY_SURFACES = (
    "Menu-bar popover",
    "Floating recorder",
    "Onboarding — Privacy",
    "Onboarding — Readiness",
    "Onboarding — Shortcut Test",
    "Onboarding — Test Dictation",
    "Settings sidebar",
    "Settings — General",
    "Settings — Permissions",
    "Settings — Recognition Language",
    "Settings — Speech Model",
    "Settings — Shortcuts",
    "Settings — Output Modes",
    "Settings — Provider",
    "Settings — Diagnostics",
    "History list",
    "Latest result / result popover",
    "Destructive confirmation dialogs",
    "Pipeline — Idle",
    "Pipeline — Requesting Permission",
    "Pipeline — Recording",
    "Pipeline — Stopping",
    "Pipeline — Transcribing",
    "Pipeline — Polishing",
    "Pipeline — Delivering",
    "Pipeline — Completed",
    "Pipeline — Failed",
)


def fail(message: str) -> None:
    raise SystemExit(f"parity evidence error: {message}")


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        fail(f"cannot read {path.relative_to(ROOT)} as UTF-8: {error}")


def split_markdown_row(line: str) -> list[str] | None:
    stripped = line.strip()
    if not stripped.startswith("|") or not stripped.endswith("|"):
        return None

    cells: list[str] = []
    current: list[str] = []
    escaped = False
    code_delimiter = 0
    index = 1
    while index < len(stripped) - 1:
        character = stripped[index]
        if escaped:
            current.append(character)
            escaped = False
            index += 1
            continue
        if character == "\\":
            current.append(character)
            escaped = True
            index += 1
            continue
        if character == "`":
            run_end = index
            while run_end < len(stripped) - 1 and stripped[run_end] == "`":
                run_end += 1
            run_length = run_end - index
            if code_delimiter == 0:
                code_delimiter = run_length
            elif code_delimiter == run_length:
                code_delimiter = 0
            current.extend(stripped[index:run_end])
            index = run_end
            continue
        if character == "|" and code_delimiter == 0:
            cells.append("".join(current).strip())
            current = []
        else:
            current.append(character)
        index += 1
    cells.append("".join(current).strip())
    return cells


def is_separator(cells: list[str]) -> bool:
    return bool(cells) and all(
        re.fullmatch(r":?-{3,}:?", cell.replace(" ", "")) is not None
        for cell in cells
    )


def markdown_lines_outside_fences(text: str) -> list[str]:
    lines = text.splitlines()
    visible: list[str] = []
    fence_character: str | None = None
    fence_length = 0

    for line in lines:
        if fence_character is None:
            opener = re.match(r"^ {0,3}(`{3,}|~{3,})", line)
            if opener is None:
                visible.append(line)
                continue
            marker = opener.group(1)
            fence_character = marker[0]
            fence_length = len(marker)
            visible.append("")
            continue

        closer = re.match(
            rf"^ {{0,3}}{re.escape(fence_character)}{{{fence_length},}}\s*$",
            line,
        )
        if closer is not None:
            fence_character = None
            fence_length = 0
        visible.append("")

    return visible


def markdown_tables(text: str) -> list[tuple[list[str], list[list[str]]]]:
    lines = markdown_lines_outside_fences(text)
    tables: list[tuple[list[str], list[list[str]]]] = []
    index = 0
    while index + 1 < len(lines):
        header = split_markdown_row(lines[index])
        separator = split_markdown_row(lines[index + 1])
        if (
            header is None
            or separator is None
            or len(header) != len(separator)
            or not is_separator(separator)
        ):
            index += 1
            continue

        rows: list[list[str]] = []
        index += 2
        while index < len(lines):
            row = split_markdown_row(lines[index])
            if row is None:
                break
            if len(row) != len(header):
                fail(
                    f"malformed Markdown table row at line {index + 1}: "
                    f"expected {len(header)} cells, found {len(row)}"
                )
            rows.append(row)
            index += 1
        tables.append((header, rows))
    return tables


def normalized_header(value: str) -> str:
    return re.sub(r"\s+", " ", value.strip()).casefold()


def find_table(
    path: Path,
    text: str,
    expected_headers: tuple[str, ...],
) -> tuple[list[str], list[list[str]]]:
    expected = tuple(normalized_header(value) for value in expected_headers)
    matches = [
        (header, rows)
        for header, rows in markdown_tables(text)
        if tuple(normalized_header(value) for value in header) == expected
    ]
    if len(matches) > 1:
        fail(
            f"{path.relative_to(ROOT)} contains multiple tables with the "
            "required columns"
        )
    if matches:
        header, rows = matches[0]
        if not rows:
            fail(f"{path.relative_to(ROOT)} contains an empty required table")
        return header, rows
    rendered = " | ".join(expected_headers)
    fail(f"{path.relative_to(ROOT)} is missing table columns: {rendered}")


def plain_text(value: str) -> str:
    value = re.sub(r"\[([^]]+)]\([^)]+\)", r"\1", value)
    value = re.sub(r"[`*_~]", "", value)
    return re.sub(r"\s+", " ", value).strip()


def require_content(value: str, label: str, behavior: str) -> None:
    if not re.search(r"[A-Za-z0-9]", plain_text(value)):
        fail(f"{behavior!r} has an empty {label}")


def reject_pending(path: Path, text: str) -> None:
    match = re.search(r"\bpending\b", text, flags=re.IGNORECASE)
    if match is not None:
        line = text.count("\n", 0, match.start()) + 1
        fail(f"pending marker found in {path.relative_to(ROOT)}:{line}")


def extract_evidence_paths(cell: str, behavior: str) -> list[Path]:
    references = re.findall(r"`([^`]+)`", cell)
    references.extend(
        target.strip("<>")
        for target in re.findall(r"\[[^]]*]\(([^)]+)\)", cell)
    )
    if not references:
        fail(
            f"{behavior!r} must cite at least one repository-relative path "
            "in backticks or a Markdown link"
        )

    resolved_paths: list[Path] = []
    for raw_reference in references:
        reference = raw_reference.strip()
        if not reference or "://" in reference or reference.startswith("/"):
            fail(f"{behavior!r} has a non-repository evidence path: {raw_reference!r}")
        reference = reference.split("#", 1)[0]
        candidate = ROOT / reference
        if not candidate.exists():
            without_line = re.sub(r":\d+(?::\d+)?$", "", reference)
            candidate = ROOT / without_line
            reference = without_line
        try:
            resolved = candidate.resolve(strict=True)
        except OSError:
            fail(f"{behavior!r} cites a missing evidence path: {raw_reference!r}")
        if ROOT not in resolved.parents or not resolved.is_file():
            fail(
                f"{behavior!r} evidence path must be an existing file inside "
                f"the repository: {raw_reference!r}"
            )
        resolved_paths.append(resolved)
    return resolved_paths


def extract_test_identifiers(cell: str, behavior: str) -> list[tuple[str, str]]:
    code_spans = re.findall(r"`([^`\n]+)`", cell)
    if not code_spans:
        fail(
            f"{behavior!r} Automated PASS must name backticked "
            "Class.testMethod identifiers"
        )

    outside_code = re.sub(r"`[^`\n]+`", "", cell)
    outside_code = re.sub(r"</?br\s*/?>", "", outside_code, flags=re.IGNORECASE)
    if outside_code.replace(";", "").replace(",", "").strip():
        fail(
            f"{behavior!r} Exact passing test(s) contains text outside "
            "backticked test identifiers"
        )

    identifiers: list[tuple[str, str]] = []
    seen: set[str] = set()
    for code_span in code_spans:
        for candidate in re.split(r"\s*[;,]\s*", code_span.strip()):
            match = re.fullmatch(
                r"([A-Za-z_][A-Za-z0-9_]*)\."
                r"(test[A-Za-z0-9_]*)",
                candidate,
            )
            if match is None:
                fail(
                    f"{behavior!r} has an invalid automated test identifier: "
                    f"{candidate!r}"
                )
            if candidate in seen:
                fail(f"{behavior!r} repeats test identifier {candidate!r}")
            seen.add(candidate)
            identifiers.append((match.group(1), match.group(2)))
    return identifiers


def is_test_source(path: Path) -> bool:
    try:
        relative = path.relative_to(ROOT)
    except ValueError:
        return False
    return path.suffix == ".swift" and any(
        component.endswith("Tests") for component in relative.parts[:-1]
    )


def swift_code_without_comments_or_strings(source: str) -> str:
    masked = list(source)
    length = len(source)

    def blank(start: int, end: int) -> None:
        for position in range(start, min(end, length)):
            if masked[position] != "\n":
                masked[position] = " "

    index = 0
    while index < length:
        if source.startswith("//", index):
            end = source.find("\n", index + 2)
            if end < 0:
                end = length
            blank(index, end)
            index = end
            continue

        if source.startswith("/*", index):
            depth = 1
            end = index + 2
            while end < length and depth:
                if source.startswith("/*", end):
                    depth += 1
                    end += 2
                elif source.startswith("*/", end):
                    depth -= 1
                    end += 2
                else:
                    end += 1
            blank(index, end)
            index = end
            continue

        hash_count = 0
        while index + hash_count < length and source[index + hash_count] == "#":
            hash_count += 1
        quote_index = index + hash_count
        if quote_index < length and source[quote_index] == '"':
            triple = source.startswith('\"\"\"', quote_index)
            opener_length = 3 if triple else 1
            closing = ('\"\"\"' if triple else '"') + ("#" * hash_count)
            end = quote_index + opener_length
            while end < length:
                if source.startswith(closing, end):
                    end += len(closing)
                    break
                if hash_count == 0 and source[end] == "\\":
                    end += 2
                else:
                    end += 1
            blank(index, end)
            index = end
            continue

        index += 1

    return "".join(masked)


def matching_brace(source: str, opening: int) -> int | None:
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return index
    return None


def top_level_type_body(source: str, start: int, end: int) -> str:
    body = list(source[start:end])
    depth = 0
    for index, character in enumerate(body):
        if character == "{":
            depth += 1
            body[index] = " "
        elif character == "}":
            body[index] = " "
            depth = max(0, depth - 1)
        elif depth:
            body[index] = " "
    return "".join(body)


def text_defines_test(source: str, class_name: str, method_name: str) -> bool:
    code = swift_code_without_comments_or_strings(source)
    declarations = re.compile(
        rf"\b(?:(?:final|public|internal|private|fileprivate|open)\s+)*"
        rf"(?:class|struct)\s+{re.escape(class_name)}\b|"
        rf"\bextension\s+{re.escape(class_name)}\b"
    )
    method = re.compile(rf"\bfunc\s+{re.escape(method_name)}\s*\(")
    for declaration in declarations.finditer(code):
        opening = code.find("{", declaration.end())
        if opening < 0:
            continue
        closing = matching_brace(code, opening)
        if closing is None:
            continue
        body = top_level_type_body(code, opening + 1, closing)
        if method.search(body) is not None:
            return True
    return False


def source_defines_test(path: Path, class_name: str, method_name: str) -> bool:
    return text_defines_test(read_text(path), class_name, method_name)


def parse_command_records(text: str) -> dict[str, str]:
    records: dict[str, str] = {}
    for line in markdown_lines_outside_fences(text):
        match = re.match(
            r"^\s*-\s+\*\*([A-Z][A-Z0-9]*)\*\*\s+—\s+"
            r"`([^`\n]+)`\s+—\s+(.+)$",
            line,
        )
        if match is None:
            continue
        record_id, command, result = match.groups()
        if record_id in records:
            fail(f"duplicate passing command record: {record_id!r}")
        if re.search(r"\bpassed\b", result, flags=re.IGNORECASE) is None:
            fail(f"passing command record {record_id!r} does not say it passed")
        if re.search(r"(?<!\d)\d{4}-\d{2}-\d{2}(?!\d)", result) is None:
            fail(f"passing command record {record_id!r} has no YYYY-MM-DD date")
        validate_recorded_command(record_id, command)
        records[record_id] = command
    if not records:
        fail("parity evidence has no valid passing command records")
    return records


def command_tokens(record_id: str, command: str) -> list[str]:
    try:
        tokens = shlex.split(command)
    except ValueError as error:
        fail(f"passing command record {record_id!r} cannot be parsed: {error}")
    if not tokens:
        fail(f"passing command record {record_id!r} is empty")
    if any(token in {"&&", "||", ";", "|", ">", ">>", "<"} for token in tokens):
        fail(f"passing command record {record_id!r} must be one test command")
    return tokens


def option_value(tokens: list[str], option: str) -> str | None:
    for index, token in enumerate(tokens):
        if token == option and index + 1 < len(tokens):
            return tokens[index + 1]
        if token.startswith(option + "="):
            return token.split("=", 1)[1]
    return None


def option_values(tokens: list[str], option: str) -> list[str]:
    values: list[str] = []
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if token == option:
            if index + 1 >= len(tokens):
                fail(f"recorded command option {option!r} has no value")
            values.append(tokens[index + 1])
            index += 2
            continue
        if token.startswith(option + "="):
            values.append(token.split("=", 1)[1])
        index += 1
    return values


def require_single_option(
    record_id: str,
    tokens: list[str],
    option: str,
    expected: str,
) -> None:
    values = option_values(tokens, option)
    if values != [expected]:
        fail(
            f"passing command record {record_id!r} must contain exactly one "
            f"{option} {expected!r} option"
        )


SWIFT_TEST_OPTIONS_WITH_VALUE = {
    "--package-path",
    "--scratch-path",
}

SWIFT_TEST_FLAGS = {
    "--disable-sandbox",
    "--force-resolved-versions",
}


def validate_swift_test_arguments(record_id: str, tokens: list[str]) -> None:
    index = 2
    seen_flags: set[str] = set()
    while index < len(tokens):
        token = tokens[index]
        if token in SWIFT_TEST_OPTIONS_WITH_VALUE:
            if index + 1 >= len(tokens):
                fail(
                    f"passing command record {record_id!r} option "
                    f"{token!r} has no value"
                )
            index += 2
            continue
        if any(
            token.startswith(option + "=")
            for option in SWIFT_TEST_OPTIONS_WITH_VALUE
        ):
            index += 1
            continue
        if token in SWIFT_TEST_FLAGS:
            if token in seen_flags:
                fail(
                    f"passing command record {record_id!r} repeats Swift "
                    f"test flag {token!r}"
                )
            seen_flags.add(token)
            index += 1
            continue
        fail(
            f"passing command record {record_id!r} uses unsupported Swift "
            f"test argument {token!r}"
        )


XCODE_OPTIONS_WITH_VALUE = {
    "-project",
    "-scheme",
    "-configuration",
    "-destination",
    "-derivedDataPath",
    "-clonedSourcePackagesDirPath",
    "-parallel-testing-enabled",
    "-resultBundlePath",
}


def xcode_actions(record_id: str, tokens: list[str]) -> list[str]:
    actions: list[str] = []
    index = 1
    while index < len(tokens):
        token = tokens[index]
        if token in XCODE_OPTIONS_WITH_VALUE:
            if index + 1 >= len(tokens):
                fail(
                    f"passing command record {record_id!r} option "
                    f"{token!r} has no value"
                )
            index += 2
            continue
        if any(token.startswith(option + "=") for option in XCODE_OPTIONS_WITH_VALUE):
            index += 1
            continue
        if token.startswith("-only-testing:") or token.startswith("-skip-testing:"):
            index += 1
            continue
        if token == "CODE_SIGNING_ALLOWED=NO":
            index += 1
            continue
        if token.startswith("-"):
            fail(
                f"passing command record {record_id!r} uses unsupported "
                f"xcodebuild option {token!r}"
            )
        actions.append(token)
        index += 1
    return actions


def validate_recorded_command(record_id: str, command: str) -> None:
    tokens = command_tokens(record_id, command)
    if tokens[:2] == ["swift", "test"]:
        validate_swift_test_arguments(record_id, tokens)
        require_single_option(
            record_id,
            tokens,
            "--package-path",
            "Packages/UtterInkKit",
        )
        return
    if tokens[0] == "xcodebuild":
        actions = xcode_actions(record_id, tokens)
        if actions != ["test"]:
            fail(
                f"passing command record {record_id!r} must execute exactly "
                "the xcodebuild test action"
            )
        if any(
            token == "-skip-testing" or token.startswith("-skip-testing:")
            for token in tokens
        ):
            fail(
                f"passing command record {record_id!r} may not use "
                "-skip-testing"
            )
        require_single_option(
            record_id,
            tokens,
            "-project",
            "UtterInk.xcodeproj",
        )
        require_single_option(record_id, tokens, "-scheme", "UtterInk")
        signing_values = [
            token.split("=", 1)[1]
            for token in tokens
            if token.startswith("CODE_SIGNING_ALLOWED=")
        ]
        if signing_values != ["NO"]:
            fail(
                f"passing command record {record_id!r} is missing "
                "an exact, unique CODE_SIGNING_ALLOWED=NO assignment"
            )
        return
    fail(
        f"passing command record {record_id!r} must start with swift test "
        "or xcodebuild"
    )


def command_covers_test(
    command: str,
    test_path: Path,
    class_name: str,
    method_name: str,
) -> bool:
    tokens = command_tokens("selected", command)
    relative = test_path.relative_to(ROOT)
    if relative.parts[:3] == ("Packages", "UtterInkKit", "Tests"):
        return (
            tokens[:2] == ["swift", "test"]
            and option_value(tokens, "--package-path") == "Packages/UtterInkKit"
        )

    if not relative.parts:
        return False
    target = relative.parts[0]
    if target not in {"UtterInkAppTests", "UtterInkUITests"}:
        return False
    if tokens[0] != "xcodebuild" or "test" not in tokens:
        return False
    selectors = [
        token.split(":", 1)[1]
        for token in tokens
        if token.startswith("-only-testing:")
    ]
    if not selectors:
        return True
    exact_selector = f"{target}/{class_name}/{method_name}"
    class_selector = f"{target}/{class_name}"
    return any(
        selector in {target, class_selector, exact_selector} for selector in selectors
    )


def selected_command_records(cell: str, behavior: str) -> list[str]:
    rendered = plain_text(cell)
    if re.fullmatch(
        r"[A-Z][A-Z0-9]*(?:\s+and\s+[A-Z][A-Z0-9]*)*",
        rendered,
    ) is None:
        fail(
            f"{behavior!r} Passing command must contain command record IDs "
            "joined by 'and'"
        )
    return re.findall(r"[A-Z][A-Z0-9]*", rendered)


baseline_text = read_text(BASELINE)
evidence_text = read_text(EVIDENCE)
matrix_text = read_text(ACCESSIBILITY_MATRIX)
reject_pending(EVIDENCE, evidence_text)

_, baseline_rows = find_table(
    BASELINE,
    baseline_text,
    (
        "Behavior",
        "Rescued implementation evidence",
        "UtterInk replacement gate",
    ),
)
actual_baseline_rows: list[tuple[str, str, str]] = []
for row in baseline_rows:
    behavior = plain_text(row[0])
    require_content(behavior, "behavior", "baseline row")
    require_content(row[1], "rescued implementation evidence", behavior)
    require_content(row[2], "UtterInk replacement gate", behavior)
    if any(re.search(r"\bpending\b", cell, re.IGNORECASE) for cell in row):
        fail(f"pending marker found in baseline behavior {behavior!r}")
    actual_baseline_rows.append(
        (behavior, plain_text(row[1]), plain_text(row[2]))
    )
if tuple(actual_baseline_rows) != EXPECTED_BASELINE_ROWS:
    fail(
        "flowtype behavior baseline changed, lost a row, or was reordered; "
        "update the pinned parity contract intentionally"
    )
baseline_behaviors = [row[0] for row in EXPECTED_BASELINE_ROWS]

matrix_header, matrix_rows = find_table(
    ACCESSIBILITY_MATRIX,
    matrix_text,
    ACCESSIBILITY_HEADERS,
)
normalized_matrix_header = [normalized_header(value) for value in matrix_header]
surface_index = normalized_matrix_header.index("surface / state")
result_index = normalized_matrix_header.index("result")
matrix_results: dict[str, str] = {}
casefolded_surfaces: dict[str, str] = {}
for row in matrix_rows:
    surface = plain_text(row[surface_index])
    result = plain_text(row[result_index])
    require_content(surface, "surface / state", "accessibility matrix row")
    require_content(row[result_index], "Result", surface)
    if re.search(r"\bpending\b", result, re.IGNORECASE):
        fail(f"accessibility matrix contains a PENDING result for {surface!r}")
    status_match = re.match(r"^(PASS|FAIL|BLOCKED)\b", result, flags=re.IGNORECASE)
    if status_match is None:
        fail(
            f"accessibility matrix result for {surface!r} must start with "
            "PASS, FAIL, or BLOCKED"
        )
    status = status_match.group(1).upper()
    conflicting_statuses = {
        candidate.upper()
        for candidate in re.findall(
            r"\b(?:PASS|FAIL|BLOCKED|PENDING)\b",
            result,
            flags=re.IGNORECASE,
        )
        if candidate.upper() != status
    }
    if conflicting_statuses:
        fail(
            f"accessibility matrix result for {surface!r} contains "
            "conflicting status words: " + ", ".join(sorted(conflicting_statuses))
        )
    if status == "FAIL":
        fail(f"accessibility matrix contains a FAIL result for {surface!r}")
    folded_surface = surface.casefold()
    if folded_surface in casefolded_surfaces:
        fail(
            "duplicate accessibility matrix surface (case-insensitive): "
            f"{casefolded_surfaces[folded_surface]!r} and {surface!r}"
        )
    casefolded_surfaces[folded_surface] = surface
    matrix_results[surface] = status

if tuple(matrix_results) != EXPECTED_ACCESSIBILITY_SURFACES:
    fail(
        "accessibility matrix surfaces changed, lost a row, or were reordered; "
        "update the pinned acceptance contract intentionally"
    )

_, evidence_rows = find_table(EVIDENCE, evidence_text, EVIDENCE_HEADERS)
command_records = parse_command_records(evidence_text)
evidence_by_behavior: dict[str, list[str]] = {}
evidence_paths_by_behavior: dict[str, list[Path]] = {}
evidence_ids: set[str] = set()
committed_sources: dict[tuple[str, str], str] = {}
for row in evidence_rows:
    evidence_id = plain_text(row[0])
    behavior = plain_text(row[1])
    require_content(evidence_id, "ID", "evidence row")
    require_content(behavior, "Behavior exact baseline", evidence_id)
    if evidence_id in evidence_ids:
        fail(f"duplicate parity evidence ID: {evidence_id!r}")
    if behavior in evidence_by_behavior:
        fail(f"duplicate parity evidence mapping for {behavior!r}")
    if behavior not in baseline_behaviors:
        fail(f"parity evidence maps unknown behavior: {behavior!r}")
    for label, value in zip(EVIDENCE_HEADERS[2:], row[2:]):
        require_content(value, label, behavior)

    status = plain_text(row[2])
    if re.search(r"\b(?:FAIL|BLOCKED|PENDING)\b", status, re.IGNORECASE):
        fail(
            f"{behavior!r} passing evidence cannot use FAIL, BLOCKED, or PENDING"
        )
    if re.fullmatch(
        r"(automated(?:\s+test)?|manual)\s+PASS",
        status,
        flags=re.IGNORECASE,
    ) is None:
        fail(
            f"{behavior!r} Status must be Automated PASS, Automated test PASS, "
            "or Manual PASS"
        )

    paths = extract_evidence_paths(row[3], behavior)
    exact_result = plain_text(row[4])
    require_content(exact_result, "Exact passing test(s)", behavior)

    automated_test_locations: list[tuple[Path, str, str]] = []
    if status.casefold().startswith("automated"):
        test_paths = [path for path in paths if is_test_source(path)]
        if not test_paths:
            fail(
                f"{behavior!r} Automated PASS must cite at least one Swift "
                "test source"
            )
        identifiers = extract_test_identifiers(row[4], behavior)
        for class_name, method_name in identifiers:
            defining_paths = [
                path
                for path in test_paths
                if source_defines_test(path, class_name, method_name)
            ]
            if not defining_paths:
                rendered = f"{class_name}.{method_name}"
                fail(
                    f"{behavior!r} cites test {rendered!r}, but no cited "
                    "test source declares that class and method"
                )
            automated_test_locations.append(
                (defining_paths[0], class_name, method_name)
            )

        record_ids = selected_command_records(row[5], behavior)
        if len(set(record_ids)) != len(record_ids):
            fail(f"{behavior!r} repeats a passing command record")
        missing_records = [
            record_id for record_id in record_ids if record_id not in command_records
        ]
        if missing_records:
            fail(
                f"{behavior!r} names unknown passing command record(s): "
                + ", ".join(missing_records)
            )
        selected_commands = [command_records[record_id] for record_id in record_ids]
        for test_path, class_name, method_name in automated_test_locations:
            if not any(
                command_covers_test(command, test_path, class_name, method_name)
                for command in selected_commands
            ):
                rendered = f"{class_name}.{method_name}"
                fail(
                    f"{behavior!r} has no selected passing command that runs "
                    f"{rendered!r}"
                )

    date_and_commit = plain_text(row[6])
    dates = re.findall(r"(?<!\d)\d{4}-\d{2}-\d{2}(?!\d)", date_and_commit)
    commits = re.findall(r"(?<![0-9A-Fa-f])[0-9A-Fa-f]{7,40}(?![0-9A-Fa-f])", date_and_commit)
    if len(dates) != 1:
        fail(
            f"{behavior!r} Date + baseline commit must contain exactly one "
            "YYYY-MM-DD date"
        )
    try:
        date.fromisoformat(dates[0])
    except ValueError:
        fail(f"{behavior!r} has an invalid evidence date: {dates[0]!r}")

    if len(commits) != 1:
        fail(
            f"{behavior!r} Date + baseline commit must contain exactly one "
            "7-40 character Git commit hash"
        )
    commit = commits[0]
    verification = subprocess.run(
        ["git", "-C", str(ROOT), "cat-file", "-e", f"{commit}^{{commit}}"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if verification.returncode != 0:
        fail(f"{behavior!r} cites an unknown Git commit: {commit!r}")

    ancestry = subprocess.run(
        ["git", "-C", str(ROOT), "merge-base", "--is-ancestor", commit, "HEAD"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if ancestry.returncode != 0:
        fail(f"{behavior!r} cites a commit that is not an ancestor of HEAD: {commit!r}")

    for test_path, _, _ in automated_test_locations:
        relative_test_path = test_path.relative_to(ROOT).as_posix()
        committed_path = subprocess.run(
            [
                "git",
                "-C",
                str(ROOT),
                "cat-file",
                "-e",
                f"{commit}:{relative_test_path}",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if committed_path.returncode != 0:
            fail(
                f"{behavior!r} test source {relative_test_path!r} did not "
                f"exist at evidence commit {commit!r}"
            )

    for test_path, class_name, method_name in automated_test_locations:
        relative_test_path = test_path.relative_to(ROOT).as_posix()
        cache_key = (commit, relative_test_path)
        if cache_key not in committed_sources:
            historical_source = subprocess.run(
                [
                    "git",
                    "-C",
                    str(ROOT),
                    "show",
                    f"{commit}:{relative_test_path}",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            if historical_source.returncode != 0:
                fail(
                    f"{behavior!r} cannot read test source "
                    f"{relative_test_path!r} at evidence commit {commit!r}"
                )
            try:
                committed_sources[cache_key] = historical_source.stdout.decode(
                    "utf-8"
                )
            except UnicodeError:
                fail(
                    f"{behavior!r} test source {relative_test_path!r} is not "
                    f"UTF-8 at evidence commit {commit!r}"
                )
        if not text_defines_test(
            committed_sources[cache_key], class_name, method_name
        ):
            rendered = f"{class_name}.{method_name}"
            fail(
                f"{behavior!r} cites test {rendered!r}, but it was not "
                f"declared at evidence commit {commit!r}"
            )

    evidence_ids.add(evidence_id)
    evidence_by_behavior[behavior] = row
    evidence_paths_by_behavior[behavior] = paths

missing = [
    behavior for behavior in baseline_behaviors if behavior not in evidence_by_behavior
]
if missing:
    fail("missing parity evidence mappings: " + ", ".join(missing))

# BLOCKED matrix rows remain honest release blockers, but they are not passing
# manual evidence. Manual PASS must cite this matrix, name exact matrix surfaces,
# and every named surface must itself have a PASS result.
matrix_path = ACCESSIBILITY_MATRIX.resolve(strict=True)
for behavior, row in evidence_by_behavior.items():
    status = plain_text(row[2])
    if re.fullmatch(r"manual\s+PASS", status, re.IGNORECASE) is None:
        continue
    if matrix_path not in evidence_paths_by_behavior[behavior]:
        fail(
            f"{behavior!r} Manual PASS must cite the accessibility matrix "
            "as its durable manual result"
        )
    named_surfaces = re.findall(r"`([^`\n]+)`", row[4])
    if not named_surfaces:
        fail(
            f"{behavior!r} cites the accessibility matrix as Manual PASS but "
            "does not name a backticked matrix surface"
        )
    unknown_surfaces = [
        surface for surface in named_surfaces if surface not in matrix_results
    ]
    if unknown_surfaces:
        fail(
            f"{behavior!r} names unknown accessibility matrix surfaces: "
            + ", ".join(unknown_surfaces)
        )
    nonpassing = [
        surface for surface in named_surfaces if matrix_results[surface] != "PASS"
    ]
    if nonpassing:
        fail(
            f"{behavior!r} treats non-PASS accessibility rows as manual PASS: "
            + ", ".join(nonpassing)
        )

pass_count = sum(status == "PASS" for status in matrix_results.values())
blocked_count = sum(status == "BLOCKED" for status in matrix_results.values())
matrix_disposition = (
    f"{pass_count} PASS, {blocked_count} BLOCKED"
    + ("; BLOCKED rows are not release approval" if blocked_count else "")
)
print(
    f"parity replacement evidence passed for {len(baseline_behaviors)} behaviors; "
    f"accessibility matrix: {matrix_disposition}"
)
PY
