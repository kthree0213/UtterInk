#!/usr/bin/env python3
from __future__ import annotations

from dataclasses import dataclass
import html
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
from urllib.parse import unquote, urlsplit


MAX_PUBLIC_FILE_BYTES = 2 * 1024 * 1024
APPROVED_SECURITY_CONTACT = "swallowclever.k3@gmail.com"
APPROVED_CONDUCT_CONTACT = "swallowclever.k3@gmail.com"
GIT_OVERRIDE_VARIABLES = frozenset(
    {
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_CEILING_DIRECTORIES",
        "GIT_COMMON_DIR",
        "GIT_CONFIG_COUNT",
        "GIT_CONFIG_PARAMETERS",
        "GIT_DIR",
        "GIT_DISCOVERY_ACROSS_FILESYSTEM",
        "GIT_EXEC_PATH",
        "GIT_INDEX_FILE",
        "GIT_NAMESPACE",
        "GIT_OBJECT_DIRECTORY",
        "GIT_PREFIX",
        "GIT_QUARANTINE_PATH",
        "GIT_REPLACE_REF_BASE",
        "GIT_SHALLOW_FILE",
        "GIT_WORK_TREE",
    }
)

PUBLIC_TEXT_FILES = (
    "README.md",
    "README.zh-CN.md",
    "PRIVACY.md",
    "SECURITY.md",
    "CONTRIBUTING.md",
    "CODE_OF_CONDUCT.md",
    "CHANGELOG.md",
    "TRADEMARKS.md",
    "THIRD_PARTY_NOTICES.md",
    "NOTICE",
    "LICENSE",
    "docs/privacy-data-flow.md",
    "docs/RELEASING.md",
    "docs/release/0.1.0-finish-plan.md",
    "docs/release/evidence-packet-template.md",
    "docs/release/release-notes-0.1.0.md",
    ".github/ISSUE_TEMPLATE/bug_report.yml",
    ".github/ISSUE_TEMPLATE/feature_request.yml",
    ".github/pull_request_template.md",
)

REQUIRED_HEADINGS = {
    "README.md": (
        "# UtterInk",
        "## Privacy Summary",
        "## Features",
        "## Requirements",
        "## Build from Source",
        "## Test",
        "## Current Limitations",
        "## Contributing and Security",
        "## License",
    ),
    "README.zh-CN.md": (
        "# UtterInk",
        "## 隐私摘要",
        "## 功能",
        "## 系统要求",
        "## 从源码构建",
        "## 测试",
        "## 当前限制",
        "## 贡献与安全",
        "## 许可证",
    ),
    "PRIVACY.md": (
        "# UtterInk Privacy",
        "## Data inventory",
        "## History controls",
        "## Network boundaries",
        "## Sensitive reports",
    ),
    "SECURITY.md": (
        "# UtterInk Security Policy",
        "## Supported versions",
        "## Reporting a vulnerability",
        "## Credentials and sensitive data",
        "## Dependency vulnerabilities",
    ),
    "CONTRIBUTING.md": (
        "# Contributing to UtterInk",
        "## Code of Conduct",
        "## Before opening an issue or pull request",
        "## Development requirements",
        "## Test-driven workflow",
        "## Privacy-safe tests and fixtures",
        "## Dependencies and license review",
        "## Deterministic project and identity assets",
        "## Accessibility review",
        "## Pull request checklist",
        "## Contribution license",
    ),
    "CODE_OF_CONDUCT.md": (
        "# Contributor Covenant Code of Conduct",
        "## Our Pledge",
        "## Our Standards",
        "## Enforcement Responsibilities",
        "## Scope",
        "## Enforcement",
        "## Enforcement Guidelines",
        "### 1. Correction",
        "### 2. Warning",
        "### 3. Temporary Ban",
        "### 4. Permanent Ban",
        "## Attribution",
    ),
    "CHANGELOG.md": (
        "# Changelog",
        "## [Unreleased]",
        "## [0.1.0]",
    ),
    "TRADEMARKS.md": (
        "# UtterInk Trademark Policy",
        "## Source Code License",
        "## Permitted Uses",
        "## No Endorsement",
    ),
    "THIRD_PARTY_NOTICES.md": (
        "# Third-Party Notices",
        "## Swift Package Dependencies",
        "## Runtime-Downloaded Speech Models",
        "## License Texts and Attributions",
    ),
    "NOTICE": (
        "# UtterInk Notice",
        "## Third-Party Notices Requiring Propagation",
    ),
    "docs/privacy-data-flow.md": (
        "# UtterInk Privacy Data Flow",
        "## 1. Session snapshot and permissions",
        "## 2. Transient local capture",
        "## 3. Local transcription and the recoverable-raw boundary",
        "## 4. Optional provider egress",
        "## 5. Final-text update",
        "## 6. Safe delivery",
        "## 7. Terminal cleanup and retained local data",
        "## 8. Disable, clear, and deletion semantics",
        "## 9. No automatic collection or upload",
    ),
    ".github/pull_request_template.md": (
        "## Summary",
        "## Related issue or design discussion",
        "## Platform verification",
        "## Behavior verification",
        "## Test evidence",
        "## Privacy and security",
        "## Accessibility",
        "## Dependencies and licensing",
        "## Deterministic project and assets",
        "## Documentation and changelog",
        "## Screenshots or recordings",
        "## Final checklist",
    ),
}

PRODUCT_CLAIM_FILES = frozenset(
    {
        "README.md",
        "README.zh-CN.md",
        "PRIVACY.md",
        "SECURITY.md",
        "CONTRIBUTING.md",
        "CHANGELOG.md",
        "docs/privacy-data-flow.md",
        "docs/RELEASING.md",
        "docs/release/0.1.0-finish-plan.md",
        "docs/release/evidence-packet-template.md",
        "docs/release/release-notes-0.1.0.md",
        ".github/ISSUE_TEMPLATE/bug_report.yml",
        ".github/ISSUE_TEMPLATE/feature_request.yml",
        ".github/pull_request_template.md",
    }
)

DIAGNOSTIC_PATH = re.compile(r"[A-Za-z0-9._/@+,-]+\Z")
INLINE_LINK = re.compile(r"!?\[[^\]\r\n]*\]\(([^)\r\n]+)\)")
REFERENCE_LINK = re.compile(r"^\s*\[[^\]\r\n]+\]:\s*(\S+)")
YAML_LINK = re.compile(r"^\s*(?:url|link):\s*['\"]?([^'\"#\s]+)", re.IGNORECASE)
EMAIL_ADDRESS = re.compile(
    r"(?<![A-Z0-9._%+-])([A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,})(?![A-Z0-9._%+-])",
    re.IGNORECASE,
)
MACOS_HOME_PATTERN_PREFIX = re.escape("/" + "Users" + "/")
LINUX_HOME_PATTERN_PREFIX = re.escape("/" + "home" + "/")

SENSITIVE_PATTERNS = (
    (
        "private-key",
        re.compile(r"-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----"),
    ),
    (
        "common-token",
        re.compile(
            r"(?:AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|github_pat_[A-Za-z0-9_]{20,}|"
            r"gh[pousr]_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|"
            r"sk_(?:live|test)_[A-Za-z0-9]{16,}|AIza[0-9A-Za-z_-]{30,})"
        ),
    ),
    (
        "provider-credential",
        re.compile(
            r"(?:sk-[A-Za-z0-9_-]{20,}|sk-or-v1-[A-Za-z0-9_-]{20,}|sk-proj-[A-Za-z0-9_-]{20,}|"
            r"sk-ant-[A-Za-z0-9_-]{20,}|gsk_[A-Za-z0-9_-]{20,}|"
            r"hf_[A-Za-z0-9_-]{20,}|xai-[A-Za-z0-9_-]{20,})"
        ),
    ),
    (
        "transcript-canary",
        re.compile(r"(?:TRANSCRIPT[_ -]?CANARY|PRIVATE[_ -]?TRANSCRIPT)[_ :=-]*[A-Za-z0-9_-]{8,}", re.IGNORECASE),
    ),
    (
        "personal-path",
        re.compile(
            rf"(?:{MACOS_HOME_PATTERN_PREFIX}[^/\s]+/[^\s]+|"
            rf"{LINUX_HOME_PATTERN_PREFIX}[^/\s]+/[^\s]+|"
            r"[A-Za-z]:\\Users\\[^\\\s]+\\[^\s]+)"
        ),
    ),
    ("file-url", re.compile(r"file://", re.IGNORECASE)),
    (
        "provider-credential",
        re.compile(r"\.apiKey\s*=\s*(?:\"[^\"\r\n]+\"|'[^'\r\n]+')", re.IGNORECASE),
    ),
    (
        "common-token",
        re.compile(r"https?://[^/:\s@]+:[^/@\s]+@", re.IGNORECASE),
    ),
)

AUTO_TERM = re.compile(
    r"(?:automatic|auto[- ]?)\s*updates?|\b(?:built[- ]in\s+)?updater\b|"
    r"\bupdates?\s+(?:itself\s+)?automatically\b|"
    r"\bautomatically\s+(?:checks?\s+for|downloads?|installs?)\s+(?:new\s+)?(?:updates?|releases?)\b|"
    r"自动更新|内置更新(?:器|机制)?|自动(?:检查|下载|安装)(?:软件)?更新",
    re.IGNORECASE | re.DOTALL,
)
AUTO_NEGATED = re.compile(
    r"(?:no|without)\s+(?:(?:automatic|auto[- ]?)\s*updates?|(?:built[- ]in\s+)?updater)|"
    r"(?:does\s+not|doesn't|never|will\s+not|won't)\s+(?:(?:provide|support|include|implement|offer|have)\s+(?:an?\s+)?(?:(?:automatic|auto[- ]?)\s*updates?|(?:built[- ]in\s+)?updater)|updates?\s+(?:itself\s+)?automatically|automatically\s+(?:updates?|checks?\s+for|downloads?|installs?))|"
    r"(?:(?:automatic|auto[- ]?)\s*updates?|(?:built[- ]in\s+)?updater).{0,40}(?:(?:is|are)\s+(?:not|never)|isn't|aren't)\s+(?:supported|available|included|provided|implemented)|"
    r"(?:不|无|未|没有|不会|暂不|尚不)(?:支持|提供|包含|进行|实现|内置)?\s*(?:自动更新|内置更新(?:器|机制)?|自动(?:检查|下载|安装)(?:软件)?更新)",
    re.IGNORECASE | re.DOTALL,
)

CLOUD_TERM = re.compile(
    r"\bcloud[- ]?(?:(?:history|settings?|data)\s+)?sync(?:ing|ed)?\b|"
    r"\bonline\s+sync(?:ing|ed)?\b|\bicloud\b|"
    r"\b(?:sync|synchroni[sz])\w*.{0,50}(?:through|to|with|via)\s+(?:the\s+)?(?:cloud|icloud)\b|"
    r"云(?:端)?同步|通过\s*iCloud\s*同步|同步.{0,20}(?:到|至|通过)云(?:端)?",
    re.IGNORECASE | re.DOTALL,
)
CLOUD_NEGATED = re.compile(
    r"(?:no|without)\s+(?:(?:cloud|online)\s+(?:(?:history|settings?|data)\s+)?sync|icloud\s+sync)|"
    r"(?:does\s+not|doesn't|never|will\s+not|won't)\s+(?:provide|support|include|implement|offer)\s+(?:(?:cloud|online)\s+(?:(?:history|settings?|data)\s+)?sync|icloud\s+sync)|"
    r"(?:does\s+not|doesn't|never|will\s+not|won't)\s+(?:sync|synchroni[sz]e)\b.{0,80}\b(?:cloud|icloud)\b|"
    r"(?:(?:cloud|online)\s+(?:(?:history|settings?|data)\s+)?sync|icloud\s+sync).{0,40}(?:(?:is|are)\s+(?:not|never)|isn't|aren't)\s+(?:supported|available|included|provided|implemented)|"
    r"(?:settings?|history|data).{0,60}(?:(?:is|are)\s+not|isn't|aren't|never)\s+(?:cloud[- ]?)?sync(?:ed)?(?:.{0,30}(?:cloud|icloud))?|"
    r"(?:不|无|未|没有|不会|暂不|尚不)(?:支持|提供|包含|进行|实现)?\s*(?:云(?:端)?同步|iCloud\s*同步|通过\s*iCloud\s*同步)",
    re.IGNORECASE | re.DOTALL,
)

LIVE_TERM = re.compile(
    r"\b(?:live|streaming|real[- ]?time)\s+(?:speech\s+)?(?:transcription|recognition)\b|"
    r"\btranscrib\w*.{0,50}(?:live|in\s+real[- ]?time|while\s+you\s+speak)\b|"
    r"\btext.{0,50}(?:appears?|is\s+produced).{0,50}(?:in\s+real[- ]?time|while\s+you\s+speak)\b|"
    r"(?:实时|流式)(?:语音)?(?:转录|转写|识别)|边说边(?:转录|转写)|说话时.{0,20}(?:出现|生成)文本",
    re.IGNORECASE | re.DOTALL,
)
LIVE_NEGATED = re.compile(
    r"(?:no|without)\s+(?:live|streaming|real[- ]?time)\s+(?:(?:or\s+streaming)\s+)?(?:transcription|recognition)|"
    r"(?:does\s+not|doesn't|never|will\s+not|won't)\s+(?:provide|support|include|implement|offer)\s+(?:live|streaming|real[- ]?time)\s+(?:(?:or\s+streaming)\s+)?(?:transcription|recognition)|"
    r"(?:does\s+not|doesn't|never|will\s+not|won't)\s+transcrib\w*.{0,50}(?:live|in\s+real[- ]?time|while\s+you\s+speak)|"
    r"(?:live|streaming|real[- ]?time)\s+(?:transcription|recognition).{0,40}(?:(?:is|are)\s+(?:not|never)|isn't|aren't)\s+(?:supported|available|included|provided|implemented)|"
    r"text.{0,40}(?:does\s+not|doesn't|never|will\s+not|won't).{0,30}(?:appear|be\s+produced).{0,40}(?:in\s+real[- ]?time|while\s+you\s+speak)|"
    r"(?:不|无|未|没有|不会|暂不|尚不)(?:支持|提供|包含|进行|实现)?\s*(?:(?:实时|流式)(?:语音)?(?:转录|转写|识别)|边说边(?:转录|转写))",
    re.IGNORECASE | re.DOTALL,
)

BUNDLED_TERM = re.compile(
    r"\b(?:bundled?|pre[- ]?configured|built[- ]in|included|hosted)\b.{0,40}\b(?:api|provider)\b.{0,20}\b(?:keys?|credentials?)\b|"
    r"\b(?:api|provider)\b.{0,20}\b(?:keys?|credentials?)\b.{0,40}\b(?:bundled?|pre[- ]?configured|built[- ]in|included|hosted)\b|"
    r"\b(?:ships?|comes?)\s+with\b.{0,40}\b(?:api|provider)\b.{0,20}\b(?:keys?|credentials?)\b|"
    r"\bevery\s+provider\s+profile\s+(?:includes?|comes?\s+with).{0,30}\b(?:api\s+)?credentials?\b|"
    r"(?:内置|捆绑|预配置|附带).{0,30}(?:api|接口|服务商).{0,20}(?:密钥|凭据)",
    re.IGNORECASE | re.DOTALL,
)
BUNDLED_NEGATED = re.compile(
    r"(?:no|without)\s+(?:bundled|pre[- ]?configured|built[- ]in|included|hosted).{0,40}(?:api|provider).{0,20}(?:keys?|credentials?)|"
    r"(?:no|without).{0,50}(?:api|provider).{0,20}(?:keys?|credentials?).{0,40}(?:bundled|pre[- ]?configured|built[- ]in|included|hosted)|"
    r"(?:does\s+not|doesn't|never|will\s+not|won't)\s+(?:bundle|include|ship|provide|preconfigure|pre-configure).{0,40}(?:api|provider).{0,20}(?:keys?|credentials?)|"
    r"(?:api|provider).{0,20}(?:keys?|credentials?).{0,30}(?:(?:is|are)\s+(?:not|never)|isn't|aren't)\s+(?:bundled|pre[- ]?configured|included|provided)|"
    r"(?:不|无|未|没有|不会)(?:内置|捆绑|包含|提供|预配置|附带).{0,30}(?:api|接口|服务商).{0,20}(?:密钥|凭据)",
    re.IGNORECASE | re.DOTALL,
)

AUDIO_TERM = re.compile(
    r"\baudio(?:-based)?\s+(?:history|retention|recovery)\b|"
    r"\b(?:retain|store|keep)\w*.{0,25}(?:audio|recordings?)\b|"
    r"\b(?:audio|recordings?).{0,25}(?:retained|stored|kept)\b|"
    r"(?:保存|保留|存储)(?:任何)?(?:音频|录音)|"
    r"(?:音频|录音)(?:会|将|仍|被)?(?:保存|保留|存储)|"
    r"(?:音频|录音)(?:历史|恢复|保留)",
    re.IGNORECASE | re.DOTALL,
)
AUDIO_NEGATED = re.compile(
    r"(?:no|without)\s+(?:audio(?:-based)?\s+)?(?:history|retention|recovery)|"
    r"(?:does\s+not|doesn't|never|will\s+not|won't)\s+(?:retain|store|keep).{0,25}(?:audio|recordings?)|"
    r"(?:audio|recordings?).{0,30}(?:(?:is|are)\s+not|isn't|aren't|never).{0,20}(?:retained|stored|kept)|"
    r"(?:不|无|未|没有|不会|绝不)(?:保存|保留|存储)(?:任何)?(?:音频|录音)|"
    r"(?:音频|录音).{0,20}(?:不|无|未|没有|不会|绝不).{0,10}(?:保存|保留|存储|历史|恢复)",
    re.IGNORECASE | re.DOTALL,
)

INTEL_NEGATED = re.compile(
    r"\b(?:no|not|without)\b[^\r\n]{0,80}\bintel\b|"
    r"(?:不|无|未|没有|不会|暂不|尚不)(?:支持|提供|包含)?[^\r\n]{0,30}\bintel\b",
    re.IGNORECASE,
)
RELEASE_NON_GOAL_LIST = re.compile(
    r"\bno\s+intel\s*/\s*cloud\s+sync\s*/\s*live\s+transcription\s*/\s*audio\s+history\b",
    re.IGNORECASE,
)

CAPABILITY_RULES = (
    ("positive-auto-update-claim", AUTO_TERM, AUTO_NEGATED),
    ("positive-cloud-sync-claim", CLOUD_TERM, CLOUD_NEGATED),
    ("positive-live-transcription-claim", LIVE_TERM, LIVE_NEGATED),
    ("bundled-api-keys-claim", BUNDLED_TERM, BUNDLED_NEGATED),
    ("positive-audio-retention-claim", AUDIO_TERM, AUDIO_NEGATED),
)


@dataclass(frozen=True, order=True)
class Finding:
    file: str
    line: int
    category: str


class PublicReadFailure(Exception):
    def __init__(self, category: str) -> None:
        self.category = category


class Validator:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.findings: set[Finding] = set()
        self.documents: dict[str, str] = {}

    def add(self, category: str, relative: str, line: int = 1) -> None:
        safe_relative = relative if DIAGNOSTIC_PATH.fullmatch(relative) else "_redacted_"
        self.findings.add(Finding(safe_relative, max(1, line), category))

    def required_path(self, relative: str) -> Path:
        parsed = PurePosixPath(relative)
        if parsed.is_absolute() or not parsed.parts or ".." in parsed.parts:
            raise PublicReadFailure("unsafe-public-path")
        return self.root.joinpath(*parsed.parts)

    def read_public_text(self, relative: str) -> str:
        path = self.required_path(relative)
        current = self.root
        final_metadata = None
        for index, component in enumerate(PurePosixPath(relative).parts):
            current = current / component
            try:
                metadata = os.lstat(current)
            except FileNotFoundError as error:
                raise PublicReadFailure("missing-required-file") from error
            except OSError as error:
                raise PublicReadFailure("unreadable-public-file") from error
            if stat.S_ISLNK(metadata.st_mode):
                raise PublicReadFailure("unsafe-public-path")
            if index < len(PurePosixPath(relative).parts) - 1:
                if not stat.S_ISDIR(metadata.st_mode):
                    raise PublicReadFailure("unsafe-public-path")
            elif not stat.S_ISREG(metadata.st_mode):
                raise PublicReadFailure("unsafe-public-path")
            final_metadata = metadata

        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(path, flags)
        except OSError as error:
            raise PublicReadFailure("unreadable-public-file") from error
        try:
            opened = os.fstat(descriptor)
            if (
                final_metadata is None
                or not stat.S_ISREG(opened.st_mode)
                or opened.st_dev != final_metadata.st_dev
                or opened.st_ino != final_metadata.st_ino
            ):
                raise PublicReadFailure("unsafe-public-path")
            chunks: list[bytes] = []
            total = 0
            while True:
                chunk = os.read(descriptor, 65536)
                if not chunk:
                    break
                total += len(chunk)
                if total > MAX_PUBLIC_FILE_BYTES:
                    raise PublicReadFailure("oversized-public-file")
                chunks.append(chunk)
        finally:
            os.close(descriptor)
        try:
            return b"".join(chunks).decode("utf-8", errors="strict")
        except UnicodeDecodeError as error:
            raise PublicReadFailure("invalid-utf8") from error

    def load_documents(self) -> None:
        for relative in PUBLIC_TEXT_FILES:
            try:
                self.documents[relative] = self.read_public_text(relative)
            except PublicReadFailure as error:
                self.add(error.category, relative)

    def check_headings(self) -> None:
        for relative, headings in REQUIRED_HEADINGS.items():
            text = self.documents.get(relative)
            if text is None:
                continue
            lines = text.splitlines()
            for heading in headings:
                if heading not in lines:
                    self.add("missing-required-heading", relative)

    @staticmethod
    def section(text: str, exact_heading: str) -> str | None:
        lines = text.splitlines(keepends=True)
        try:
            start = next(index for index, line in enumerate(lines) if line.rstrip("\r\n") == exact_heading)
        except StopIteration:
            return None
        level = len(exact_heading) - len(exact_heading.lstrip("#"))
        end = len(lines)
        for index in range(start + 1, len(lines)):
            stripped = lines[index].lstrip()
            match = re.match(r"(#{1,6})\s+", stripped)
            if match is not None and len(match.group(1)) <= level:
                end = index
                break
        return "".join(lines[start + 1 : end])

    def check_contacts(self) -> None:
        security = self.documents.get("SECURITY.md")
        if security is not None:
            reporting = self.section(security, "## Reporting a vulnerability")
            if reporting is None or EMAIL_ADDRESS.findall(reporting) != [APPROVED_SECURITY_CONTACT]:
                self.add("security-contact-mismatch", "SECURITY.md")
        conduct = self.documents.get("CODE_OF_CONDUCT.md")
        if conduct is not None:
            enforcement = self.section(conduct, "## Enforcement")
            if enforcement is None or EMAIL_ADDRESS.findall(enforcement) != [APPROVED_CONDUCT_CONTACT]:
                self.add("conduct-contact-mismatch", "CODE_OF_CONDUCT.md")
        for relative in ("README.md", "README.zh-CN.md", "PRIVACY.md"):
            text = self.documents.get(relative)
            if text is not None and APPROVED_SECURITY_CONTACT not in text:
                self.add("security-contact-mismatch", relative)
        for relative in ("SECURITY.md", "CODE_OF_CONDUCT.md"):
            text = self.documents.get(relative)
            if text is not None and re.search(
                r"\[INSERT CONTACT METHOD\]|\b(?:TBD|TODO|placeholder|changeme|pending)\b|example\.(?:com|org|net)|\.invalid\b",
                text,
                re.IGNORECASE,
            ):
                self.add("placeholder-contact", relative)

    def check_sensitive_text(self) -> None:
        for relative, text in self.documents.items():
            for line_number, line in enumerate(text.splitlines(), 1):
                for category, pattern in SENSITIVE_PATTERNS:
                    if pattern.search(line):
                        self.add(category, relative, line_number)

    @staticmethod
    def statements(text: str):
        start = 0
        for match in re.finditer(
            r"\n\s*\n|(?=^\s*(?:#{1,6}\s|[-*+]\s|\d+[.)]\s))",
            text,
            re.MULTILINE,
        ):
            if match.start() > start:
                yield text[start : match.start()], text.count("\n", 0, start) + 1
            start = match.end()
        if start < len(text):
            yield text[start:], text.count("\n", 0, start) + 1

    def check_product_claims(self) -> None:
        always_forbidden = (
            ("legacy-flowtype-brand", re.compile(r"\bflowtype\b", re.IGNORECASE)),
            ("intel-claim", re.compile(r"\bintel\b|\bx86(?:_64|-64)\b|英特尔", re.IGNORECASE)),
            ("universal-claim", re.compile(r"\buniversal\b|通用(?:二进制|构建|应用)", re.IGNORECASE)),
            (
                "prerelease-dmg-url",
                re.compile(r"https?://[^\s<>()\]]+\.dmg(?:[?#][^\s<>()\]]*)?", re.IGNORECASE),
            ),
        )
        for relative in PRODUCT_CLAIM_FILES:
            text = self.documents.get(relative)
            if text is None:
                continue
            for category, pattern in always_forbidden:
                for match in pattern.finditer(text):
                    if category == "intel-claim":
                        line_start = text.rfind("\n", 0, match.start()) + 1
                        line_end = text.find("\n", match.end())
                        if line_end < 0:
                            line_end = len(text)
                        if INTEL_NEGATED.search(text[line_start:line_end]):
                            continue
                    self.add(category, relative, text.count("\n", 0, match.start()) + 1)
            for statement, line_number in self.statements(text):
                for category, term, negated in CAPABILITY_RULES:
                    release_non_goals = (
                        category
                        in {
                            "positive-cloud-sync-claim",
                            "positive-live-transcription-claim",
                            "positive-audio-retention-claim",
                        }
                        and RELEASE_NON_GOAL_LIST.search(statement) is not None
                    )
                    if term.search(statement) and not negated.search(statement) and not release_non_goals:
                        self.add(category, relative, line_number)

    def check_document_commands(self) -> None:
        relative = "CONTRIBUTING.md"
        text = self.documents.get(relative)
        if text is None:
            return
        if 'UTTERINK_NOTICE_SCRATCH_PATH="$notice_scratch"' not in text:
            self.add("missing-safe-notice-command", relative)
        bare_notice_command = re.compile(
            r"(?m)^\s*\./Scripts/collect-third-party-notices[.]sh --check\s*$"
        )
        for match in bare_notice_command.finditer(text):
            self.add(
                "unsafe-notice-command",
                relative,
                text.count("\n", 0, match.start()) + 1,
            )
        lines = text.splitlines()
        index = 0
        while index < len(lines):
            stripped = lines[index].strip()
            if not (stripped.startswith("swift test ") or stripped.startswith("swift run ")):
                index += 1
                continue
            start_line = index + 1
            command_parts = [stripped]
            while command_parts[-1].endswith("\\") and index + 1 < len(lines):
                command_parts[-1] = command_parts[-1][:-1]
                index += 1
                command_parts.append(lines[index].strip())
            command = " ".join(command_parts)
            if (
                "--package-path Packages/UtterInkKit" in command
                and "--scratch-path" not in command
            ):
                self.add("unsafe-swiftpm-command", relative, start_line)
            index += 1

    @staticmethod
    def link_targets(line: str):
        for match in INLINE_LINK.finditer(line):
            raw = match.group(1).strip()
            if raw.startswith("<") and ">" in raw:
                yield raw[1 : raw.index(">")]
            else:
                yield raw.split(maxsplit=1)[0]
        reference = REFERENCE_LINK.match(line)
        if reference is not None:
            yield reference.group(1)
        yaml_link = YAML_LINK.match(line)
        if yaml_link is not None:
            yield yaml_link.group(1)

    def check_link(self, source: str, line_number: int, raw_target: str) -> None:
        target = html.unescape(raw_target.strip().strip("<>"))
        if not target or target.startswith("#"):
            return
        parsed = urlsplit(target)
        if parsed.scheme:
            scheme = parsed.scheme.casefold()
            if scheme == "http":
                self.add("insecure-link-scheme", source, line_number)
            elif scheme not in {"https", "mailto"}:
                self.add("unsafe-link-scheme", source, line_number)
            return
        if parsed.netloc or target.startswith("//"):
            self.add("unsafe-relative-link", source, line_number)
            return
        decoded = unquote(parsed.path)
        if not decoded:
            return
        # Repository-relative links in issue and pull-request templates are
        # resolved from the eventual issue/PR page, not this file's directory.
        # Requiring an explicit HTTPS URL or plain repository-root instruction
        # avoids a link that passes locally but points outside the repository at
        # runtime.
        if source.startswith(".github/"):
            self.add("template-relative-link", source, line_number)
            return
        if "\x00" in decoded or "\\" in decoded or decoded.startswith(("/", "~")):
            self.add("unsafe-relative-link", source, line_number)
            return
        source_parent = self.root.joinpath(*PurePosixPath(source).parent.parts)
        candidate = source_parent.joinpath(*PurePosixPath(decoded).parts)
        try:
            resolved = candidate.resolve(strict=False)
            relative = resolved.relative_to(self.root)
        except (OSError, ValueError):
            self.add("unsafe-relative-link", source, line_number)
            return
        current = self.root
        parts = relative.parts
        for index, component in enumerate(parts):
            current = current / component
            try:
                metadata = os.lstat(current)
            except FileNotFoundError:
                self.add("broken-relative-link", source, line_number)
                return
            except OSError:
                self.add("unsafe-relative-link", source, line_number)
                return
            if stat.S_ISLNK(metadata.st_mode):
                self.add("unsafe-relative-link", source, line_number)
                return
            if index < len(parts) - 1 and not stat.S_ISDIR(metadata.st_mode):
                self.add("broken-relative-link", source, line_number)
                return
            if index == len(parts) - 1 and not (
                stat.S_ISREG(metadata.st_mode) or stat.S_ISDIR(metadata.st_mode)
            ):
                self.add("unsafe-relative-link", source, line_number)
                return

    def check_links(self) -> None:
        for relative, text in self.documents.items():
            if not relative.endswith((".md", ".yml", ".yaml")):
                continue
            for line_number, line in enumerate(text.splitlines(), 1):
                for target in self.link_targets(line):
                    self.check_link(relative, line_number, target)

    @staticmethod
    def forbidden_tracked_path(relative: str) -> bool:
        parsed = PurePosixPath(relative)
        lowered = tuple(part.casefold() for part in parsed.parts)
        name = lowered[-1] if lowered else ""
        if name == ".env.example":
            return False
        if name == ".env" or name.startswith(".env.") or name == ".envrc":
            return True
        if any(
            component in {
                ".build",
                ".swiftpm",
                "dist",
                "models",
                "secrets",
                "deriveddata",
                "xcuserdata",
            }
            for component in lowered
        ):
            return True
        if name == ".ds_store":
            return True
        return any(
            name.endswith(suffix)
            for suffix in (
                ".dmg",
                ".caf",
                ".wav",
                ".pem",
                ".p12",
                ".cer",
                ".mobileprovision",
                ".xcarchive",
                ".xcresult",
            )
        )

    def check_tracked_paths(self) -> None:
        if any(
            key in GIT_OVERRIDE_VARIABLES
            or key.startswith("GIT_CONFIG_KEY_")
            or key.startswith("GIT_CONFIG_VALUE_")
            for key in os.environ
        ):
            self.add("unsafe-git-environment", ".git")
            return
        git = shutil.which("git")
        if git is None:
            self.add("tracked-path-scan-failed", ".git")
            return
        try:
            metadata = os.lstat(git)
        except OSError:
            self.add("tracked-path-scan-failed", ".git")
            return
        if not stat.S_ISREG(metadata.st_mode):
            self.add("tracked-path-scan-failed", ".git")
            return
        try:
            result = subprocess.run(
                [
                    git,
                    "-c",
                    "core.fsmonitor=false",
                    "-c",
                    "core.untrackedCache=false",
                    "-C",
                    str(self.root),
                    "ls-files",
                    "-z",
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                check=False,
                timeout=20,
                env={
                    **os.environ,
                    "GIT_CONFIG_GLOBAL": os.devnull,
                    "GIT_CONFIG_NOSYSTEM": "1",
                    "GIT_ASKPASS": "/usr/bin/false",
                    "GIT_LFS_SKIP_SMUDGE": "1",
                    "GIT_NO_LAZY_FETCH": "1",
                    "GIT_OPTIONAL_LOCKS": "0",
                    "GIT_PAGER": "cat",
                    "GIT_TERMINAL_PROMPT": "0",
                    "LC_ALL": "C",
                    "PAGER": "cat",
                    "SSH_ASKPASS": "/usr/bin/false",
                },
            )
        except (OSError, subprocess.SubprocessError):
            self.add("tracked-path-scan-failed", ".git")
            return
        if result.returncode != 0:
            self.add("tracked-path-scan-failed", ".git")
            return
        for raw in result.stdout.split(b"\0"):
            if not raw:
                continue
            try:
                relative = raw.decode("utf-8", errors="strict")
            except UnicodeDecodeError:
                self.add("invalid-tracked-path-encoding", ".git")
                continue
            parsed = PurePosixPath(relative)
            if (
                parsed.is_absolute()
                or not parsed.parts
                or ".." in parsed.parts
                or "\x00" in relative
                or "\\" in relative
            ):
                self.add("unsafe-tracked-path", "_redacted_")
            elif self.forbidden_tracked_path(relative):
                self.add("forbidden-tracked-path", relative)

    def run(self) -> int:
        self.load_documents()
        self.check_headings()
        self.check_contacts()
        self.check_sensitive_text()
        self.check_product_claims()
        self.check_document_commands()
        self.check_links()
        self.check_tracked_paths()
        if self.findings:
            for finding in sorted(self.findings):
                print(
                    f"finding category={finding.category} file={finding.file} line={finding.line}",
                    file=sys.stderr,
                )
            return 1
        print("public documents valid")
        return 0


def main() -> int:
    if len(sys.argv) != 1:
        print(
            "finding category=unexpected-argument file=Scripts/check-public-docs.py line=1",
            file=sys.stderr,
        )
        return 1
    try:
        script = Path(__file__)
        metadata = os.lstat(script)
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
            raise OSError
        root = script.resolve(strict=True).parent.parent
        if not root.is_dir():
            raise OSError
        return Validator(root).run()
    except Exception:
        print(
            "finding category=validator-internal-error file=Scripts/check-public-docs.py line=1",
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
