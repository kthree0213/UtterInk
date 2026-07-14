#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"

PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 - "$ROOT" <<'PY'
from __future__ import annotations

import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys


ROOT = Path(sys.argv[1])
REQUIRED_DOCUMENTS = (
    "README.md",
    "README.zh-CN.md",
    "PRIVACY.md",
    "SECURITY.md",
    "docs/privacy-data-flow.md",
)
README_DOCUMENTS = ("README.md", "README.zh-CN.md")
MAX_DOCUMENT_BYTES = 2 * 1024 * 1024

# Task 4 Step 3 replaces both empty strings with the exact user-approved
# public values. Empty, example, or provisional values intentionally fail.
APPROVED_CONTACTS = {
    "security-reporting": "swallowclever.k3@gmail.com",
    "conduct-enforcement": "swallowclever.k3@gmail.com",
}


class ReadFailure(Exception):
    def __init__(self, category: str) -> None:
        self.category = category


def report(category: str, relative_path: str) -> None:
    # Never print document contents, matched text, or approved contact values.
    print(
        f"public-claims failure category={category} file={relative_path}",
        file=sys.stderr,
    )


def read_public_file(relative_path: str) -> str:
    relative = PurePosixPath(relative_path)
    if relative.is_absolute() or ".." in relative.parts or not relative.parts:
        raise ReadFailure("unsafe-path")

    current = ROOT
    for index, part in enumerate(relative.parts):
        current = current / part
        try:
            metadata = os.lstat(current)
        except FileNotFoundError as error:
            raise ReadFailure("missing-document") from error
        except OSError as error:
            raise ReadFailure("unreadable-document") from error
        if stat.S_ISLNK(metadata.st_mode):
            raise ReadFailure("symlink-document")
        expected = stat.S_ISREG if index == len(relative.parts) - 1 else stat.S_ISDIR
        if not expected(metadata.st_mode):
            raise ReadFailure("unsafe-file-type")

    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(current, flags)
    except OSError as error:
        raise ReadFailure("unreadable-document") from error
    try:
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode):
            raise ReadFailure("unsafe-file-type")
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, 65536)
            if not chunk:
                break
            total += len(chunk)
            if total > MAX_DOCUMENT_BYTES:
                raise ReadFailure("oversized-document")
            chunks.append(chunk)
    finally:
        os.close(descriptor)

    try:
        contents = b"".join(chunks).decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise ReadFailure("invalid-utf8") from error
    if not contents.strip():
        raise ReadFailure("empty-document")
    return contents


documents: dict[str, str] = {}
read_failed = False
for path in REQUIRED_DOCUMENTS:
    try:
        documents[path] = read_public_file(path)
    except ReadFailure as error:
        report(error.category, path)
        read_failed = True
if read_failed:
    raise SystemExit(1)


AUTO_UPDATE_TERM = (
    r"(?:automatic|auto[- ]?)\s*updates?"
    r"|\b(?:built[- ]in\s+)?updater\b"
    r"|\bupdates?\s+(?:itself\s+)?automatically\b"
    r"|\bautomatically\s+(?:checks?\s+for|downloads?|installs?)\s+(?:new\s+)?(?:updates?|releases?)\b"
    r"|自动更新|内置更新(?:器|机制)?|自动(?:检查|下载|安装)(?:软件)?更新"
)
AUTO_UPDATE_NEGATED = (
    r"(?:no|without)\s+(?:(?:automatic|auto[- ]?)\s*updates?|(?:built[- ]in\s+)?updater)",
    r"(?:does\s+not|doesn't|never|will\s+not|won't)\s+(?:(?:provide|support|include|implement|offer|have)\s+(?:an?\s+)?(?:(?:automatic|auto[- ]?)\s*updates?|(?:built[- ]in\s+)?updater)|updates?\s+(?:itself\s+)?automatically|automatically\s+(?:updates?|checks?\s+for|downloads?|installs?))",
    r"(?:(?:automatic|auto[- ]?)\s*updates?|(?:built[- ]in\s+)?updater).{0,40}(?:(?:is|are)\s+(?:not|never)|isn't|aren't)\s+(?:supported|available|included|provided|implemented)",
    r"(?:不|无|未|没有|不会|暂不|尚不)(?:支持|提供|包含|进行|实现|内置)?\s*(?:自动更新|内置更新(?:器|机制)?|自动(?:检查|下载|安装)(?:软件)?更新)",
)

CLOUD_SYNC_TERM = (
    r"\bcloud[- ]?(?:(?:history|settings?|data)\s+)?sync(?:ing|ed)?\b"
    r"|\bonline\s+sync(?:ing|ed)?\b|\bicloud\b"
    r"|\b(?:sync|synchroni[sz])\w*.{0,50}(?:through|to|with|via)\s+(?:the\s+)?(?:cloud|icloud)\b"
    r"|云(?:端)?同步|通过\s*iCloud\s*同步|同步.{0,20}(?:到|至|通过)云(?:端)?"
)
CLOUD_SYNC_NEGATED = (
    r"(?:no|without)\s+(?:(?:cloud|online)\s+(?:(?:history|settings?|data)\s+)?sync|icloud\s+sync)",
    r"(?:does\s+not|doesn't|never|will\s+not|won't)\s+(?:provide|support|include|implement|offer)\s+(?:(?:cloud|online)\s+(?:(?:history|settings?|data)\s+)?sync|icloud\s+sync)",
    r"(?:does\s+not|doesn't|never|will\s+not|won't)\s+(?:sync|synchroni[sz]e)\b.{0,80}\b(?:cloud|icloud)\b",
    r"(?:(?:cloud|online)\s+(?:(?:history|settings?|data)\s+)?sync|icloud\s+sync).{0,40}(?:(?:is|are)\s+(?:not|never)|isn't|aren't)\s+(?:supported|available|included|provided|implemented)",
    r"(?:settings?|history|data).{0,60}(?:(?:is|are)\s+not|isn't|aren't|never)\s+(?:cloud[- ]?)?sync(?:ed)?(?:.{0,30}(?:cloud|icloud))?",
    r"(?:不|无|未|没有|不会|暂不|尚不)(?:支持|提供|包含|进行|实现)?\s*(?:云(?:端)?同步|iCloud\s*同步|通过\s*iCloud\s*同步)",
)

LIVE_TRANSCRIPTION_TERM = (
    r"\b(?:live|streaming|real[- ]?time)\s+(?:speech\s+)?(?:transcription|recognition)\b"
    r"|\btranscrib\w*.{0,50}(?:live|in\s+real[- ]?time|while\s+you\s+speak)\b"
    r"|\btext.{0,50}(?:appears?|is\s+produced).{0,50}(?:in\s+real[- ]?time|while\s+you\s+speak)\b"
    r"|(?:实时|流式)(?:语音)?(?:转录|转写|识别)|边说边(?:转录|转写)|说话时.{0,20}(?:出现|生成)文本"
)
LIVE_TRANSCRIPTION_NEGATED = (
    r"(?:no|without)\s+(?:live|streaming|real[- ]?time)\s+(?:(?:or\s+streaming)\s+)?(?:transcription|recognition)",
    r"(?:does\s+not|doesn't|never|will\s+not|won't)\s+(?:provide|support|include|implement|offer)\s+(?:live|streaming|real[- ]?time)\s+(?:(?:or\s+streaming)\s+)?(?:transcription|recognition)",
    r"(?:does\s+not|doesn't|never|will\s+not|won't)\s+transcrib\w*.{0,50}(?:live|in\s+real[- ]?time|while\s+you\s+speak)",
    r"(?:live|streaming|real[- ]?time)\s+(?:transcription|recognition).{0,40}(?:(?:is|are)\s+(?:not|never)|isn't|aren't)\s+(?:supported|available|included|provided|implemented)",
    r"text.{0,40}(?:does\s+not|doesn't|never|will\s+not|won't).{0,30}(?:appear|be\s+produced).{0,40}(?:in\s+real[- ]?time|while\s+you\s+speak)",
    r"(?:不|无|未|没有|不会|暂不|尚不)(?:支持|提供|包含|进行|实现)?\s*(?:(?:实时|流式)(?:语音)?(?:转录|转写|识别)|边说边(?:转录|转写))",
)

BUNDLED_CREDENTIAL_TERM = (
    r"\b(?:bundled?|pre[- ]?configured|built[- ]in|included|hosted)\b.{0,40}\b(?:api|provider)\b.{0,20}\b(?:keys?|credentials?)\b"
    r"|\b(?:api|provider)\b.{0,20}\b(?:keys?|credentials?)\b.{0,40}\b(?:bundled?|pre[- ]?configured|built[- ]in|included|hosted)\b"
    r"|\b(?:ships?|comes?)\s+with\b.{0,40}\b(?:api|provider)\b.{0,20}\b(?:keys?|credentials?)\b"
    r"|\bevery\s+provider\s+profile\s+(?:includes?|comes?\s+with).{0,30}\b(?:api\s+)?credentials?\b"
    r"|(?:内置|捆绑|预配置|附带).{0,30}(?:api|接口|服务商).{0,20}(?:密钥|凭据)"
)
BUNDLED_CREDENTIAL_NEGATED = (
    r"(?:no|without)\s+(?:bundled|pre[- ]?configured|built[- ]in|included|hosted).{0,40}(?:api|provider).{0,20}(?:keys?|credentials?)",
    r"(?:does\s+not|doesn't|never|will\s+not|won't)\s+(?:bundle|include|ship|provide|preconfigure|pre-configure).{0,40}(?:api|provider).{0,20}(?:keys?|credentials?)",
    r"(?:api|provider).{0,20}(?:keys?|credentials?).{0,30}(?:(?:is|are)\s+(?:not|never)|isn't|aren't)\s+(?:bundled|pre[- ]?configured|included|provided)",
    r"(?:不|无|未|没有|不会)(?:内置|捆绑|包含|提供|预配置|附带).{0,30}(?:api|接口|服务商).{0,20}(?:密钥|凭据)",
)

CAPABILITY_CLAIMS = (
    (
        "positive-auto-update-claim",
        AUTO_UPDATE_TERM,
        AUTO_UPDATE_NEGATED,
        (
            "A built-in updater downloads releases automatically.",
            "UtterInk updates itself automatically.",
            "UtterInk automatically downloads new releases.",
            "UtterInk 内置自动更新器。",
        ),
        (
            "No automatic updates are included.",
            "UtterInk does not update itself automatically.",
            "UtterInk doesn't have a built-in updater.",
            "UtterInk 不支持自动更新。",
        ),
    ),
    (
        "positive-cloud-sync-claim",
        CLOUD_SYNC_TERM,
        CLOUD_SYNC_NEGATED,
        (
            "Settings synchronize through iCloud.",
            "History is cloud-synced.",
            "UtterInk provides online sync.",
            "设置通过 iCloud 同步。",
        ),
        (
            "No cloud sync is provided.",
            "UtterInk does not synchronize settings or history through the cloud.",
            "History isn't synced to iCloud.",
            "UtterInk 不支持云同步。",
        ),
    ),
    (
        "positive-live-transcription-claim",
        LIVE_TRANSCRIPTION_TERM,
        LIVE_TRANSCRIPTION_NEGATED,
        (
            "Text appears in real time while you speak.",
            "UtterInk transcribes while you speak.",
            "Real-time speech recognition is available.",
            "UtterInk 支持边说边转写。",
        ),
        (
            "No streaming transcription is available.",
            "UtterInk does not transcribe while you speak.",
            "Live transcription isn't available.",
            "UtterInk 不支持实时转录。",
        ),
    ),
    (
        "bundled-api-keys-claim",
        BUNDLED_CREDENTIAL_TERM,
        BUNDLED_CREDENTIAL_NEGATED,
        (
            "UtterInk ships with an API credential.",
            "Every provider profile includes an API credential.",
            "The API key is preconfigured.",
            "UtterInk 内置服务商 API 密钥。",
        ),
        (
            "UtterInk does not bundle provider API keys.",
            "No preconfigured API credentials are included.",
            "API keys are not included.",
            "UtterInk 不内置 API 密钥。",
        ),
    ),
)

README_CLAIMS = (
    ("product-name", (r"\butterink\b",)),
    ("minimum-macos", (r"\bmacos\s*14(?:\.0)?\s*\+",)),
    ("apple-silicon", (r"\bapple\s+silicon\b",)),
    ("arm64", (r"\barm64\b",)),
    ("local-whisper", (
        r"(?:local|on-device|本地|设备端).{0,80}\bwhisper\b",
        r"\bwhisper\b.{0,80}(?:local|on-device|locally|本地|设备端)",
    )),
    ("optional-openai-compatible-text-polishing", (
        r"optional.{0,160}(?:openai[-\s\u2011]compatible.{0,160}text\s+polish|text\s+polish.{0,160}openai[-\s\u2011]compatible)",
        r"可选.{0,100}(?:openai\s*兼容.{0,100}(?:文本)?润色|(?:文本)?润色.{0,100}(?:openai\s*兼容|兼容\s*openai))",
    )),
    ("keychain", (r"\bkeychain\b",)),
    ("text-only-history", (
        r"(?:text[-\s]only|only\s+(?:the\s+)?text|仅(?:保存|保留)?文本|只(?:保存|保留)文本).{0,100}(?:history|历史)",
        r"(?:history|历史).{0,100}(?:text[-\s]only|only\s+(?:the\s+)?text|仅(?:保存|保留)?文本|只(?:保存|保留)文本)",
    )),
    ("twenty-session-history", (
        r"(?:20[-\s]session|20\s+sessions?|20\s*个?会话).{0,100}(?:history|历史)",
        r"(?:history|历史).{0,100}(?:20[-\s]session|20\s+sessions?|20\s*个?会话)",
    )),
    ("no-audio-retention", (
        r"(?:no|never).{0,40}(?:audio|recordings?).{0,50}(?:retention|retained|stored|kept|history)",
        r"(?:audio|recordings?).{0,40}(?:is\s+not|isn't|never).{0,30}(?:retained|stored|kept)",
        r"(?:does\s+not|doesn't)\s+(?:retain|store|keep).{0,20}(?:audio|recordings?)",
        r"(?:不|无|未|没有|不会)(?:保存|保留|存储)(?:任何)?音频|音频.{0,20}(?:不|未|不会)(?:保存|保留|存储)",
    )),
    ("apache-2.0", (r"apache[-\u2011]2\.0",)),
    ("build-xcodegen-command", (r"\bxcodegen\s+generate\b",)),
    ("test-package-command", (r"swift\s+test\s+--package-path\s+packages/utterinkkit\b",)),
    ("test-ci-command", (r"\./scripts/ci-local\.sh\b",)),
    ("current-limitations", (r"(?m)^#{1,6}\s*(?:current\s+limitations|当前限制)\s*$",)),
    ("no-auto-update", AUTO_UPDATE_NEGATED),
    ("no-cloud-sync", CLOUD_SYNC_NEGATED),
    ("no-live-transcription", LIVE_TRANSCRIPTION_NEGATED),
)


def has_any(contents: str, patterns: tuple[str, ...]) -> bool:
    return any(re.search(pattern, contents, re.IGNORECASE | re.DOTALL) for pattern in patterns)


SHELL_CODE_FENCE = re.compile(
    r"^[ \t]*```(?:bash|sh|shell|zsh)[ \t]*\r?\n(.*?)^[ \t]*```[ \t]*$",
    re.IGNORECASE | re.MULTILINE | re.DOTALL,
)
BUILD_BLOCK_REQUIREMENTS = (
    r"(?:^|\s)xcodebuild(?:\s|$)",
    r"(?:^|\s)-project\s+utterink\.xcodeproj(?:\s|$)",
    r"(?:^|\s)-scheme\s+utterink(?:\s|$)",
    r"(?:^|\s)-destination\s+['\"]?platform\s*=\s*macos\s*,\s*arch\s*=\s*arm64['\"]?(?:\s|$)",
    r"(?:^|\s)code_signing_allowed\s*=\s*no(?:\s|$)",
    r"(?:^|\s)build(?:\s|$)",
)


def has_unsigned_arm64_build_block(contents: str) -> bool:
    for match in SHELL_CODE_FENCE.finditer(contents):
        block = re.sub(r"\\[ \t]*\r?\n", " ", match.group(1))
        if all(re.search(pattern, block, re.IGNORECASE) for pattern in BUILD_BLOCK_REQUIREMENTS):
            return True
    return False


failed = False
for category, term, allowed_negation, positive_canaries, negative_canaries in CAPABILITY_CLAIMS:
    if any(
        not re.search(term, canary, re.IGNORECASE | re.DOTALL)
        or has_any(canary, allowed_negation)
        for canary in positive_canaries
    ):
        report(f"validator-positive-canary-{category}", "Tests/Scripts/test-public-claims.sh")
        failed = True
    if any(
        not re.search(term, canary, re.IGNORECASE | re.DOTALL)
        or not has_any(canary, allowed_negation)
        for canary in negative_canaries
    ):
        report(f"validator-negative-canary-{category}", "Tests/Scripts/test-public-claims.sh")
        failed = True

build_block_canaries = (
    (
        True,
        """```bash
xcodebuild -project UtterInk.xcodeproj -scheme UtterInk -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build
```""",
    ),
    (
        False,
        """```bash
xcodebuild -project UtterInk.xcodeproj -scheme UtterInk -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test
```""",
    ),
    (False, "xcodebuild -project UtterInk.xcodeproj -scheme UtterInk build"),
)
if any(has_unsigned_arm64_build_block(canary) != expected for expected, canary in build_block_canaries):
    report("validator-canary-build-command", "Tests/Scripts/test-public-claims.sh")
    failed = True

for path in README_DOCUMENTS:
    for claim, patterns in README_CLAIMS:
        if not has_any(documents[path], patterns):
            report(f"missing-claim-{claim}", path)
            failed = True
    if not has_unsigned_arm64_build_block(documents[path]):
        report("missing-claim-build-xcodebuild-command", path)
        failed = True

always_forbidden = (
    ("legacy-flowtype-brand", r"\bflowtype\b"),
    ("intel-claim", r"\bintel\b|\bx86(?:_64|-64)\b|英特尔"),
    ("universal-claim", r"\buniversal\b|通用(?:二进制|构建|应用)"),
    ("prerelease-dmg-url", r"https?://[^\s<>()\]]+\.dmg(?:[?#][^\s<>()\]]*)?"),
)
for path, contents in documents.items():
    for category, pattern in always_forbidden:
        if re.search(pattern, contents, re.IGNORECASE):
            report(category, path)
            failed = True

for path, contents in documents.items():
    for statement in re.split(
        r"\n\s*\n|(?=^\s*(?:#{1,6}|[-*+]\s|\d+[.)]\s))",
        contents,
        flags=re.MULTILINE,
    ):
        for category, term, allowed_negation, _, _ in CAPABILITY_CLAIMS:
            if re.search(term, statement, re.IGNORECASE | re.DOTALL) and not has_any(statement, allowed_negation):
                report(category, path)
                failed = True

placeholder = re.compile(
    r"(?:^\s*$|\b(?:tbd|todo|example|placeholder|changeme|pending)\b|example\.(?:com|org|net)|\.invalid\b)",
    re.IGNORECASE,
)
for purpose, contact in APPROVED_CONTACTS.items():
    if "\n" in contact or "\r" in contact or placeholder.search(contact):
        report(f"invalid-approved-{purpose}-contact", "Tests/Scripts/test-public-claims.sh")
        failed = True


def reporting_section(contents: str) -> str | None:
    heading = re.search(
        r"^(?P<marks>#{1,6})\s*(?:reporting\s+(?:a\s+)?vulnerability|security\s+reporting|报告安全(?:问题|漏洞)|漏洞报告)\s*$",
        contents,
        re.IGNORECASE | re.MULTILINE,
    )
    if heading is None:
        return None
    level = len(heading.group("marks"))
    tail = contents[heading.end():]
    next_heading = re.search(rf"^#{{1,{level}}}\s+", tail, re.MULTILINE)
    return tail if next_heading is None else tail[:next_heading.start()]


EMAIL_ADDRESS = re.compile(
    r"(?<![A-Z0-9._%+-])([A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,})(?![A-Z0-9._%+-])",
    re.IGNORECASE,
)
security_contact = APPROVED_CONTACTS["security-reporting"]
security_reporting_section = reporting_section(documents["SECURITY.md"])
if security_reporting_section is None:
    report("missing-security-reporting-section", "SECURITY.md")
    failed = True
else:
    reporting_emails = EMAIL_ADDRESS.findall(security_reporting_section)
    if reporting_emails != [security_contact]:
        report("security-reporting-contact-mismatch", "SECURITY.md")
        failed = True

for path in (*README_DOCUMENTS, "PRIVACY.md"):
    if security_contact not in documents[path]:
        report("security-contact-mismatch", path)
        failed = True

conduct_path = "CODE_OF_CONDUCT.md"
try:
    conduct = read_public_file(conduct_path)
except ReadFailure as error:
    if error.category != "missing-document":
        report(error.category, conduct_path)
        failed = True
else:
    conduct_contact = APPROVED_CONTACTS["conduct-enforcement"]
    if conduct_contact and conduct_contact not in conduct:
        report("conduct-contact-mismatch", conduct_path)
        failed = True

contact_placeholder_line = re.compile(
    r"(?im)^(?=[^\n]*(?:contact|channel|e-?mail|联系|渠道))[^\n]*[:：]\s*(?:tbd|todo|example[^\s]*|placeholder|pending)?\s*$"
)
for path in ("SECURITY.md", conduct_path):
    contents = documents.get(path, conduct if path == conduct_path and "conduct" in locals() else "")
    if contents and contact_placeholder_line.search(contents):
        report("placeholder-or-empty-contact", path)
        failed = True

if failed:
    raise SystemExit(1)

print("public claim matrix passed")
PY
