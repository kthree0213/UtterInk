#!/bin/bash

set -euo pipefail

ROOT="$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "${BASH_SOURCE[0]}")/../.." && /bin/pwd -P)"
VERIFIER="$ROOT/Scripts/release/verify-final-dmg.sh"
POLICY="$ROOT/Config/dmg-allowed-content.txt"
SCHEMA="$ROOT/docs/release/evidence-schema.json"

fail() {
  /usr/bin/printf 'final DMG verification tests failed: %s\n' "$1" >&2
  exit 1
}

[[ -x "$VERIFIER" ]] || fail 'Scripts/release/verify-final-dmg.sh is not executable'
[[ -f "$POLICY" && ! -L "$POLICY" ]] || fail 'DMG allowlist policy is unavailable'
[[ -f "$SCHEMA" && ! -L "$SCHEMA" ]] || fail 'candidate evidence schema is unavailable'

/usr/bin/python3 -I - "$VERIFIER" "$POLICY" "$SCHEMA" <<'PY'
from __future__ import annotations

import ctypes
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import textwrap


SOURCE = Path(os.sys.argv[1])
POLICY = Path(os.sys.argv[2])
SCHEMA = Path(os.sys.argv[3])
EXPECTED_MANIFEST = ["Applications -> /Applications", "UtterInk.app directory"]
EXPECTED_KEYS = {
    "appGatekeeperAssessment",
    "candidateCommit",
    "dmgFilename",
    "dmgGatekeeperAssessment",
    "dmgSHA256",
    "dmgSizeBytes",
    "evidenceType",
    "hashAfterVerification",
    "hashBeforeVerification",
    "manifest",
    "mountMode",
    "originalArtifactUnchanged",
    "originalQuarantineState",
    "product",
    "schemaVersion",
    "signatureComponentCount",
    "stapleValidation",
    "status",
    "strictSignatureValidation",
}

SOURCE_TEXT = SOURCE.read_text(encoding="utf-8")
if ("/" + "Users" + "/") in SOURCE_TEXT:
    raise AssertionError("verifier contains a literal local-home prefix")
for binding in (
    'HDIUTIL="$TOOL_ROOT/hdiutil"',
    'CODESIGN="$TOOL_ROOT/codesign"',
    'SPCTL="$TOOL_ROOT/spctl"',
    'XCRUN="$TOOL_ROOT/xcrun"',
    'XATTR="$TOOL_ROOT/xattr"',
    'SHASUM="$TOOL_ROOT/shasum"',
    'DITTO="$TOOL_ROOT/ditto"',
    'FILE_TOOL="$TOOL_ROOT/file"',
):
    if binding not in SOURCE_TEXT:
        raise AssertionError(f"test mode is not pinned to a fake tool: {binding}")


def abort(message: str) -> None:
    raise AssertionError(message)


def write(path: Path, value: str | bytes, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    raw = value if isinstance(value, bytes) else textwrap.dedent(value).lstrip().encode()
    path.write_bytes(raw)
    path.chmod(mode)


def run(command: list[str], *, cwd: Path, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        command,
        cwd=cwd,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


with tempfile.TemporaryDirectory(prefix="utterink-final-dmg-tests.", dir="/private/tmp") as temp_text:
    temp = Path(temp_text)
    temp.chmod(0o700)
    root = temp / "FixtureRepository"
    (root / "Scripts/release").mkdir(parents=True, mode=0o700)
    (root / "Config").mkdir(mode=0o700)
    (root / "docs/release").mkdir(parents=True, mode=0o700)
    shutil.copyfile(SOURCE, root / "Scripts/release/verify-final-dmg.sh")
    (root / "Scripts/release/verify-final-dmg.sh").chmod(0o700)
    shutil.copyfile(POLICY, root / "Config/dmg-allowed-content.txt")
    (root / "Config/dmg-allowed-content.txt").chmod(0o600)
    shutil.copyfile(SCHEMA, root / "docs/release/evidence-schema.json")
    (root / "docs/release/evidence-schema.json").chmod(0o600)
    write(root / ".utterink-final-dmg-test-repository", "utterink-final-dmg-test-repository-v1\n")
    write(
        root / ".gitignore",
        "FixtureTools/\n.release-work/\n.release-evidence/\n.test-*\n",
    )

    fixture_mount = root / "FixtureMount"
    app = fixture_mount / "UtterInk.app"
    executable = app / "Contents/MacOS/UtterInk"
    framework_binary = app / "Contents/Frameworks/Nested.framework/Nested"
    helper = app / "Contents/Helpers/UtterInkHelper"
    write(executable, b"signed-main\n", 0o755)
    write(framework_binary, b"signed-framework\n", 0o755)
    write(helper, b"signed-helper\n", 0o755)
    write(app / "Contents/Resources/Native.node", b"signed-native-module\n", 0o644)
    write(app / "Contents/Info.plist", b"fixture-info\n", 0o644)
    write(app / "Contents/Resources/Notice.txt", b"resource\n", 0o644)
    (fixture_mount / "Applications").symlink_to("/Applications")

    initialized = run(["/usr/bin/git", "init", "-q"], cwd=root)
    if initialized.returncode:
        abort(initialized.stderr.decode(errors="replace"))
    for command in (
        ["/usr/bin/git", "add", "."],
        [
            "/usr/bin/git",
            "-c",
            "user.name=UtterInk Test",
            "-c",
            "user.email=test.invalid@example.invalid",
            "commit",
            "-qm",
            "fixture",
        ],
    ):
        result = run(command, cwd=root)
        if result.returncode:
            abort(result.stderr.decode(errors="replace"))
    commit = run(["/usr/bin/git", "rev-parse", "HEAD"], cwd=root).stdout.decode().strip()
    tree = run(["/usr/bin/git", "rev-parse", "HEAD^{tree}"], cwd=root).stdout.decode().strip()

    tools = root / "FixtureTools"
    tools.mkdir(mode=0o700)
    write(tools / ".utterink-final-dmg-test-tools", "utterink-final-dmg-test-tools-v1\n")

    write(
        tools / "shasum",
        r'''
        #!/bin/bash
        set -euo pipefail
        [[ "$#" -eq 2 && "$1" == -a && "$2" == 256 ]] || exit 70
        LOG="${UTTERINK_FINAL_DMG_TEST_LOG:?}"
        /usr/bin/printf 'shasum\t-a\t256\n' >> "$LOG"
        /bin/cat >/dev/null
        COUNT_FILE="$LOG.hash-count"
        count=0
        [[ ! -f "$COUNT_FILE" ]] || count="$(/bin/cat "$COUNT_FILE")"
        count=$((count + 1))
        /usr/bin/printf '%s\n' "$count" > "$COUNT_FILE"
        expected="$(/bin/cat "$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "$0")" && /bin/pwd -P)/expected-hash")"
        if [[ "${UTTERINK_FINAL_DMG_TEST_SCENARIO:-success}" == initial-hash-failure && "$count" -eq 1 ]]; then
          expected="$(/usr/bin/printf '0%.0s' {1..64})"
        elif [[ "${UTTERINK_FINAL_DMG_TEST_SCENARIO:-success}" == final-hash-failure && "$count" -eq 2 ]]; then
          expected="$(/usr/bin/printf 'f%.0s' {1..64})"
        fi
        /usr/bin/printf '%s  -\n' "$expected"
        ''',
        0o700,
    )
    write(
        tools / "xcrun",
        r'''
        #!/bin/bash
        set -euo pipefail
        LOG="${UTTERINK_FINAL_DMG_TEST_LOG:?}"
        line=xcrun
        for value in "$@"; do line="${line}"$'\t'"$value"; done
        /usr/bin/printf '%s\n' "$line" >> "$LOG"
        [[ "$#" -eq 3 && "$1" == stapler && "$2" == validate && -f "$3" ]] || exit 71
        [[ "${UTTERINK_FINAL_DMG_TEST_SCENARIO:-success}" != staple-failure ]] || exit 72
        ''',
        0o700,
    )
    write(
        tools / "hdiutil",
        r'''
        #!/bin/bash
        set -euo pipefail
        LOG="${UTTERINK_FINAL_DMG_TEST_LOG:?}"
        line=hdiutil
        for value in "$@"; do line="${line}"$'\t'"$value"; done
        /usr/bin/printf '%s\n' "$line" >> "$LOG"
        root="$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "$0")/.." && /bin/pwd -P)"
        case "${1:-}" in
          attach)
            [[ "${UTTERINK_FINAL_DMG_TEST_SCENARIO:-success}" != mount-failure ]] || exit 73
            mountroot=''
            previous=''
            readonly=0
            nobrowse=0
            noautoopen=0
            owners=0
            plist=0
            for value in "$@"; do
              [[ "$previous" != -mountroot ]] || mountroot="$value"
              [[ "$previous" != -owners || "$value" != on ]] || owners=1
              [[ "$value" != -readonly ]] || readonly=1
              [[ "$value" != -nobrowse ]] || nobrowse=1
              [[ "$value" != -noautoopen ]] || noautoopen=1
              [[ "$value" != -plist ]] || plist=1
              previous="$value"
            done
            [[ "$readonly$nobrowse$noautoopen$owners$plist" == 11111 && "$mountroot" == /private/tmp/utterink-final-dmg.*'/mount-root' ]] || exit 74
            volume="$mountroot/UtterInk"
            /usr/bin/python3 -I - "$root/FixtureMount" "$volume" <<'PY_COPY'
import shutil,sys
shutil.copytree(sys.argv[1],sys.argv[2],symlinks=True,copy_function=shutil.copy2)
PY_COPY
            if [[ "${UTTERINK_FINAL_DMG_TEST_SCENARIO:-success}" == manifest-failure ]]; then
              /usr/bin/printf 'unexpected\n' > "$volume/Unexpected.txt"
            fi
            /usr/bin/python3 -I - "$volume" <<'PY_PLIST'
import plistlib,sys
plistlib.dump({"system-entities":[
 {"content-hint":"GUID_partition_scheme","dev-entry":"/dev/disk91"},
 {"content-hint":"Apple_HFS","dev-entry":"/dev/disk91s1","mount-point":sys.argv[1]},
]},sys.stdout.buffer,sort_keys=True)
PY_PLIST
            ;;
          detach)
            [[ "$#" -ge 2 && "$2" == /dev/disk91 ]] || exit 75
            if [[ "${UTTERINK_FINAL_DMG_TEST_SCENARIO:-success}" == detach-failure && "$#" -eq 2 ]]; then exit 84; fi
            ;;
          *) exit 76 ;;
        esac
        ''',
        0o700,
    )
    write(
        tools / "codesign",
        r'''
        #!/bin/bash
        set -euo pipefail
        LOG="${UTTERINK_FINAL_DMG_TEST_LOG:?}"
        line=codesign
        for value in "$@"; do line="${line}"$'\t'"$value"; done
        /usr/bin/printf '%s\n' "$line" >> "$LOG"
        [[ "$#" -eq 4 && "$1" == --verify && "$2" == --strict && "$3" == --verbose=4 ]] || exit 77
        if [[ "${UTTERINK_FINAL_DMG_TEST_SCENARIO:-success}" == signature-failure && "$4" == *Nested.framework ]]; then exit 78; fi
        ''',
        0o700,
    )
    write(
        tools / "file",
        r'''
        #!/bin/bash
        set -euo pipefail
        LOG="${UTTERINK_FINAL_DMG_TEST_LOG:?}"
        line=file
        for value in "$@"; do line="${line}"$'\t'"$value"; done
        /usr/bin/printf '%s\n' "$line" >> "$LOG"
        [[ "$#" -eq 2 && "$1" == -b && -f "$2" ]] || exit 85
        if [[ -x "$2" || "$2" == *.node ]]; then
          /usr/bin/printf 'Mach-O 64-bit arm64\n'
        else
          /usr/bin/printf 'data\n'
        fi
        ''',
        0o700,
    )
    write(
        tools / "spctl",
        r'''
        #!/bin/bash
        set -euo pipefail
        LOG="${UTTERINK_FINAL_DMG_TEST_LOG:?}"
        line=spctl
        for value in "$@"; do line="${line}"$'\t'"$value"; done
        /usr/bin/printf '%s\n' "$line" >> "$LOG"
        scenario="${UTTERINK_FINAL_DMG_TEST_SCENARIO:-success}"
        if [[ " $* " == *' --type open '* && "$scenario" == pinned-mutation ]]; then
          target="${!#}"
          /bin/chmod 0600 "$target"
          /usr/bin/printf 'mutated-pinned-copy\n' >> "$target"
        fi
        if [[ " $* " == *' --type open '* && "$scenario" == dmg-gatekeeper-failure ]]; then exit 79; fi
        if [[ " $* " == *' --type execute '* && "$scenario" == app-gatekeeper-failure ]]; then exit 80; fi
        ''',
        0o700,
    )
    write(
        tools / "xattr",
        r'''
        #!/bin/bash
        set -euo pipefail
        LOG="${UTTERINK_FINAL_DMG_TEST_LOG:?}"
        line=xattr
        for value in "$@"; do line="${line}"$'\t'"$value"; done
        /usr/bin/printf '%s\n' "$line" >> "$LOG"
        [[ "$#" -eq 1 && -f "$1" ]] || exit 81
        case "${UTTERINK_FINAL_DMG_TEST_SCENARIO:-success}" in
          metadata-failure) exit 82 ;;
          metadata-malformed) /usr/bin/printf 'bad\tattribute\n' ;;
          *) /usr/bin/xattr "$1" ;;
        esac
        ''',
        0o700,
    )
    write(
        tools / "ditto",
        r'''
        #!/bin/bash
        set -euo pipefail
        LOG="${UTTERINK_FINAL_DMG_TEST_LOG:?}"
        line=ditto
        for value in "$@"; do line="${line}"$'\t'"$value"; done
        /usr/bin/printf '%s\n' "$line" >> "$LOG"
        [[ "$#" -eq 2 && -d "$1" && ! -e "$2" ]] || exit 83
        /usr/bin/python3 -I - "$1" "$2" <<'PY_COPY'
import shutil,sys
shutil.copytree(sys.argv[1],sys.argv[2],symlinks=True,copy_function=shutil.copy2)
PY_COPY
        ''',
        0o700,
    )

    artifact_dir = temp / "artifact"
    artifact_dir.mkdir(mode=0o700)
    dmg = artifact_dir / "UtterInk-0.1.0-arm64.dmg"
    dmg.write_bytes(b"immutable-final-dmg-fixture\n")
    dmg.chmod(0o400)
    expected_hash = hashlib.sha256(dmg.read_bytes()).hexdigest()
    write(tools / "expected-hash", expected_hash + "\n")
    candidate = {
        "checks": {"entitlements": True, "generatedProjectClean": True, "history": True, "infoPolicy": True, "metadata": True, "packageResolution": True},
        "evidenceType": "release-candidate",
        "packageResolution": {"path": "Packages/UtterInkKit/Package.resolved", "sha256": "11" * 32},
        "policies": {"ciToolchainSHA256": "12" * 32, "releaseEntitlementsSHA256": "13" * 32, "releaseInfoPolicySHA256": "14" * 32, "releaseMetadataSHA256": "15" * 32},
        "product": "UtterInk",
        "release": {"architecture": "arm64", "buildNumber": "1", "bundleIdentifier": "dev.utterink.UtterInk", "configuration": "Release", "deploymentTarget": "14.0", "dmgFilename": dmg.name, "marketingVersion": "0.1.0"},
        "schemaVersion": 1,
        "source": {"clean": True, "commit": commit, "releaseTag": "v0.1.0", "tree": tree},
        "toolchain": {"lockSHA256": "16" * 32, "sdkBuild": "25A123", "sdkVersion": "26.4", "swiftVersion": "Apple Swift version 6.3 (swiftlang-6.3.0.1 clang-1700.0.1.1)", "xcodeBuild": "17E202", "xcodeVersion": "26.4.1", "xcodegenBinarySHA256": "17" * 32, "xcodegenVersion": "2.45.4"},
    }
    candidate_path = dmg.parent / "candidate.json"
    write(candidate_path, (json.dumps(candidate, sort_keys=True, separators=(",", ":")) + "\n").encode(), 0o400)

    libc = ctypes.CDLL(None, use_errno=True)
    set_xattr = libc.setxattr
    set_xattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    set_xattr.restype = ctypes.c_int
    remove_xattr = libc.removexattr
    remove_xattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
    remove_xattr.restype = ctypes.c_int
    quarantine_present = False

    def configure_quarantine(present: bool) -> None:
        global quarantine_present
        if present == quarantine_present:
            return
        encoded = os.fsencode(dmg)
        dmg.chmod(0o600)
        try:
            if present:
                value = b"0081;fixture"
                buffer = ctypes.create_string_buffer(value)
                if set_xattr(encoded, b"com.apple.quarantine", buffer, len(value), 0, 0) != 0:
                    abort("could not create fixture quarantine metadata")
            elif remove_xattr(encoded, b"com.apple.quarantine", 0) != 0:
                abort("could not remove fixture quarantine metadata")
        finally:
            dmg.chmod(0o400)
        quarantine_present = present

    configure_quarantine(True)

    verifier = root / "Scripts/release/verify-final-dmg.sh"
    log = root / ".test-log"
    counter = root / ".test-log.hash-count"
    case_number = 0

    def invoke(
        scenario: str,
        expected_status: int,
        expected_diagnostic: str,
        *,
        dmg_argument: str | None = None,
        evidence_argument: str | None = None,
        hash_argument: str | None = None,
        extra_env: dict[str, str] | None = None,
    ) -> tuple[subprocess.CompletedProcess[bytes], list[str], Path]:
        global case_number
        configure_quarantine(scenario != "quarantine-absent")
        case_number += 1
        log.unlink(missing_ok=True)
        counter.unlink(missing_ok=True)
        (Path(str(log) + ".evidence")).unlink(missing_ok=True)
        evidence = root / ".release-evidence" / f"case-{case_number}"
        evidence.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        evidence.parent.chmod(0o700)
        evidence.mkdir(mode=0o700)
        selected_evidence = evidence_argument if evidence_argument is not None else str(evidence)
        selected_evidence_absolute = Path(selected_evidence)
        if not selected_evidence_absolute.is_absolute():
            selected_evidence_absolute = root / selected_evidence_absolute
        write(Path(str(log) + ".evidence"), str(selected_evidence_absolute) + "\n")
        env = {
            "PATH": "/untrusted/path",
            "LC_ALL": "C",
            "UTTERINK_FINAL_DMG_TEST_MODE": "1",
            "UTTERINK_FINAL_DMG_TEST_TOOL_ROOT": str(tools),
            "UTTERINK_FINAL_DMG_TEST_LOG": str(log),
            "UTTERINK_FINAL_DMG_TEST_SCENARIO": scenario,
        }
        if extra_env:
            env.update(extra_env)
        result = run(
            [
                str(verifier),
                "--dmg",
                dmg_argument if dmg_argument is not None else str(dmg),
                "--expected-sha256",
                hash_argument if hash_argument is not None else expected_hash,
                "--evidence",
                selected_evidence,
            ],
            cwd=root,
            env=env,
        )
        if result.returncode != expected_status:
            logged = log.read_text(encoding="utf-8") if log.exists() else ""
            abort(
                f"{scenario}: expected exit {expected_status}, got {result.returncode}; "
                f"stdout={result.stdout!r}, stderr={result.stderr!r}, log={logged!r}"
            )
        expected_stderr = b"" if expected_status == 0 else (expected_diagnostic + "\n").encode()
        if result.stderr != expected_stderr:
            abort(f"{scenario}: unsanitized or unexpected diagnostic {result.stderr!r}")
        lines = log.read_text(encoding="utf-8").splitlines() if log.exists() else []
        return result, lines, evidence

    original = os.lstat(dmg)
    success, commands, evidence = invoke("success", 0, "")
    if success.stderr != b"":
        abort("success emitted stderr")
    after = os.lstat(dmg)
    stable_fields = ("st_dev", "st_ino", "st_mode", "st_uid", "st_gid", "st_nlink", "st_size", "st_mtime_ns", "st_ctime_ns")
    if tuple(getattr(original, item) for item in stable_fields) != tuple(getattr(after, item) for item in stable_fields):
        abort("success changed original DMG metadata")
    if dmg.read_bytes() != b"immutable-final-dmg-fixture\n":
        abort("success changed original DMG bytes")

    output = evidence / "final-dmg-verification.json"
    raw = output.read_bytes()
    value = json.loads(raw.decode("utf-8"))
    if raw != (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode():
        abort("evidence is not canonical JSON plus LF")
    if stat.S_IMODE(os.lstat(output).st_mode) != 0o600 or os.lstat(output).st_nlink != 1:
        abort("evidence mode/link count is unsafe")
    if set(value) != EXPECTED_KEYS:
        abort(f"evidence keys differ: {set(value) ^ EXPECTED_KEYS}")
    expected_values = {
        "appGatekeeperAssessment": "accepted",
        "candidateCommit": commit,
        "dmgFilename": dmg.name,
        "dmgGatekeeperAssessment": "accepted",
        "dmgSHA256": expected_hash,
        "dmgSizeBytes": len(dmg.read_bytes()),
        "evidenceType": "final-dmg-verification",
        "hashAfterVerification": expected_hash,
        "hashBeforeVerification": expected_hash,
        "manifest": EXPECTED_MANIFEST,
        "mountMode": "read-only",
        "originalArtifactUnchanged": True,
        "originalQuarantineState": "present",
        "product": "UtterInk",
        "schemaVersion": 1,
        "stapleValidation": "passed",
        "status": "valid",
        "strictSignatureValidation": "passed",
    }
    for key, expected in expected_values.items():
        if value.get(key) != expected:
            abort(f"evidence {key} differs: {value.get(key)!r}")
    if type(value["signatureComponentCount"]) is not int or value["signatureComponentCount"] < 6:
        abort("evidence does not prove recursive component verification")
    local_home_prefix = b"/" + b"Users" + b"/"
    if any(token in raw for token in (b"/private/tmp/", local_home_prefix, b"FixtureRepository", b"mount-root")):
        abort("evidence contains a local path")
    if success.stdout != raw:
        abort("success stdout is not the canonical evidence")

    names = [line.split("\t", 1)[0] for line in commands]
    try:
        initial_hash = names.index("shasum")
        staple = names.index("xcrun")
        attach = next(i for i, line in enumerate(commands) if line.startswith("hdiutil\tattach\t"))
        first_codesign = names.index("codesign")
        dmg_spctl = next(i for i, line in enumerate(commands) if line.startswith("spctl\t") and "\t--type\topen\t" in line)
        ditto = names.index("ditto")
        app_spctl = next(i for i, line in enumerate(commands) if line.startswith("spctl\t") and "\t--type\texecute\t" in line)
        xattr = names.index("xattr")
        detach = next(i for i, line in enumerate(commands) if line.startswith("hdiutil\tdetach\t"))
        final_hash = len(names) - 1 - names[::-1].index("shasum")
    except (ValueError, StopIteration):
        abort(f"success command inventory incomplete: {commands!r}")
    if not (initial_hash < staple < attach < first_codesign < dmg_spctl < ditto < app_spctl < xattr < detach < final_hash):
        abort(f"verification order differs: {commands!r}")
    attach_line = commands[attach]
    for required in ("\t-readonly\t", "\t-nobrowse\t", "\t-noautoopen\t", "\t-owners\ton\t", "\t-plist\t"):
        if required not in attach_line:
            abort(f"mount is not strict read-only: {attach_line!r}")
    codesign_lines = [line for line in commands if line.startswith("codesign\t")]
    if len(codesign_lines) != value["signatureComponentCount"]:
        abort("signature component count does not match invocations")
    if any("\t--deep\t" in line or "\t--deep" in line for line in codesign_lines):
        abort("recursive signature verification used --deep")
    if not any(line.endswith("Nested.framework") for line in codesign_lines):
        abort("nested framework was not verified")
    if not any(line.endswith("Native.node") for line in codesign_lines):
        abort("non-executable Mach-O was not verified")
    dmg_assessment = commands[dmg_spctl]
    if "\t--assess\t--type\topen\t--context\tcontext:primary-signature\t--verbose=4\t" not in dmg_assessment:
        abort(f"DMG Gatekeeper assessment arguments differ: {dmg_assessment!r}")
    app_assessment = commands[app_spctl]
    if "\t--assess\t--type\texecute\t--verbose=4\t" not in app_assessment or "/copied/UtterInk.app" not in app_assessment:
        abort(f"copied-app Gatekeeper assessment arguments differ: {app_assessment!r}")
    if not commands[ditto].startswith("ditto\t") or "/mount-root/UtterInk/UtterInk.app\t" not in commands[ditto] or not commands[ditto].endswith("/copied/UtterInk.app"):
        abort(f"app copy did not use the isolated fake tool: {commands[ditto]!r}")
    if commands[xattr] != f"xattr\t{dmg}":
        abort(f"original metadata command differs: {commands[xattr]!r}")
    if any("xattr" in line and any(flag in line.split("\t")[1:] for flag in ("-c", "-d", "-r", "--delete")) for line in commands):
        abort("a command attempted to strip quarantine")

    # Relative evidence under the other documented ignored root is accepted.
    absent, _, absent_evidence = invoke(
        "quarantine-absent",
        0,
        "",
        evidence_argument=f".release-work/case-{case_number + 1}",
    )
    relative_output = root / f".release-work/case-{case_number}" / "final-dmg-verification.json"
    if not relative_output.is_file():
        # invoke increments before formatting the default case number; resolve by stdout.
        candidates = list((root / ".release-work").glob("case-*/final-dmg-verification.json"))
        if len(candidates) != 1:
            abort("relative documented evidence directory was not accepted")
        relative_output = candidates[0]
    absent_value = json.loads(absent.stdout)
    if absent_value["originalQuarantineState"] != "absent":
        abort("absent quarantine state was not sanitized")

    failures = [
        ("initial-hash-failure", 30, "final DMG verification error: initial-hash-mismatch", "xcrun"),
        ("staple-failure", 31, "final DMG verification error: staple-validation-failed", "hdiutil"),
        ("mount-failure", 32, "final DMG verification error: readonly-mount-failed", "codesign"),
        ("manifest-failure", 33, "final DMG verification error: manifest-validation-failed", "codesign"),
        ("signature-failure", 34, "final DMG verification error: signature-validation-failed", "spctl"),
        ("dmg-gatekeeper-failure", 35, "final DMG verification error: dmg-gatekeeper-assessment-failed", "xattr"),
        ("app-gatekeeper-failure", 36, "final DMG verification error: app-gatekeeper-assessment-failed", "xattr"),
        ("metadata-failure", 37, "final DMG verification error: metadata-inspection-failed", "shasum-final"),
        ("metadata-malformed", 37, "final DMG verification error: metadata-inspection-failed", "shasum-final"),
        ("final-hash-failure", 38, "final DMG verification error: final-hash-mismatch", "none"),
        ("pinned-mutation", 38, "final DMG verification error: final-hash-mismatch", "none"),
        ("detach-failure", 39, "final DMG verification error: detach-failed", "none"),
    ]
    codes = set()
    for scenario, code, diagnostic, forbidden in failures:
        _, lines, failed_evidence = invoke(scenario, code, diagnostic)
        codes.add(code)
        if list(failed_evidence.iterdir()):
            abort(f"{scenario}: partial evidence survived")
        failure_names = [line.split("\t", 1)[0] for line in lines]
        if forbidden == "xcrun" and "xcrun" in failure_names:
            abort(f"{scenario}: continued after initial hash failure")
        if forbidden == "hdiutil" and any(line.startswith("hdiutil\tattach") for line in lines):
            abort(f"{scenario}: continued after staple failure")
        if forbidden == "codesign" and "codesign" in failure_names:
            abort(f"{scenario}: continued after mount/manifest failure")
        if forbidden == "spctl" and "spctl" in failure_names:
            abort(f"{scenario}: continued after signature failure")
        if forbidden == "xattr" and "xattr" in failure_names:
            abort(f"{scenario}: continued after Gatekeeper failure")
        if forbidden == "shasum-final" and failure_names.count("shasum") != 1:
            abort(f"{scenario}: continued to final hash")
        if scenario == "manifest-failure" and not any(line == "hdiutil\tdetach\t/dev/disk91\t-force" for line in lines):
            abort("post-attach manifest failure did not detach during cleanup")
    if codes != set(range(30, 40)):
        abort(f"failure stages do not have distinct exit codes: {codes}")
    if not any(line == "hdiutil\tdetach\t/dev/disk91\t-force" for line in lines):
        abort("detach failure did not trigger isolated cleanup detach")

    _, evidence_failure_lines, evidence_failure_directory = invoke(
        "evidence-write-failure",
        40,
        "final DMG verification error: evidence-write-failed",
    )
    if {path.name for path in evidence_failure_directory.iterdir()} != {"concurrent-canary"}:
        abort("evidence write failure removed user content or left verifier output")
    if [line.split("\t", 1)[0] for line in evidence_failure_lines].count("shasum") != 2:
        abort("evidence write failure occurred before final immutable hash")

    _, partial_failure_lines, partial_failure_directory = invoke(
        "evidence-partial-write-failure",
        40,
        "final DMG verification error: evidence-write-failed",
    )
    if list(partial_failure_directory.iterdir()):
        abort("partial evidence write left an owned temporary or final file")
    if [line.split("\t", 1)[0] for line in partial_failure_lines].count("shasum") != 2:
        abort("partial evidence write failure occurred before final immutable hash")

    _, replacement_lines, replacement_directory = invoke(
        "evidence-final-replace",
        40,
        "final DMG verification error: evidence-write-failed",
    )
    replacement = replacement_directory / "final-dmg-verification.json"
    if {path.name for path in replacement_directory.iterdir()} != {replacement.name} or replacement.read_bytes() != b"concurrent-replacement\n":
        abort("final-name replacement was removed or accepted as verifier evidence")
    if [line.split("\t", 1)[0] for line in replacement_lines].count("shasum") != 2:
        abort("final-name replacement occurred before final immutable hash")

    _, removal_lines, removal_directory = invoke(
        "evidence-final-remove",
        40,
        "final DMG verification error: evidence-write-failed",
    )
    if list(removal_directory.iterdir()):
        abort("removed final evidence name left an owned publication artifact")
    if [line.split("\t", 1)[0] for line in removal_lines].count("shasum") != 2:
        abort("final-name removal occurred before final immutable hash")

    created_race = root / ".release-work" / f"created-race-{case_number + 1}"
    moved_created_race = created_race.with_name(created_race.name + ".owned-moved")
    _, created_race_lines, _ = invoke(
        "evidence-created-dir-replace",
        40,
        "final DMG verification error: evidence-write-failed",
        evidence_argument=str(created_race.relative_to(root)),
    )
    if not created_race.is_dir() or any(created_race.iterdir()):
        abort("replacement evidence directory was removed or modified during failure cleanup")
    if not moved_created_race.is_dir() or any(moved_created_race.iterdir()):
        abort("owned evidence directory was followed to its concurrent destination")
    created_race_item = os.lstat(created_race)
    moved_created_race_item = os.lstat(moved_created_race)
    if (created_race_item.st_dev, created_race_item.st_ino) == (moved_created_race_item.st_dev, moved_created_race_item.st_ino):
        abort("created-directory replacement fixture did not produce distinct identities")
    if [line.split("\t", 1)[0] for line in created_race_lines].count("shasum") != 2:
        abort("created-directory replacement occurred before final immutable hash")
    created_race.rmdir()
    moved_created_race.rmdir()

    invalid_hash = "A" * 64
    invoke("success", 2, "final DMG verification error: invalid-arguments", hash_argument=invalid_hash)
    invoke("success", 21, "final DMG verification error: unsafe-dmg", dmg_argument=dmg.name)
    dmg_link = artifact_dir / "linked.dmg"
    dmg_link.symlink_to(dmg)
    invoke("success", 21, "final DMG verification error: unsafe-dmg", dmg_argument=str(dmg_link))
    dmg_hardlink = artifact_dir / "hardlinked.dmg"
    os.link(dmg, dmg_hardlink)
    invoke("success", 21, "final DMG verification error: unsafe-dmg", dmg_argument=str(dmg))
    dmg_hardlink.unlink()

    candidate_raw = candidate_path.read_bytes()
    candidate_value = json.loads(candidate_raw)
    candidate_value["source"]["commit"] = "99" * 20
    candidate_path.chmod(0o600)
    write(candidate_path, (json.dumps(candidate_value, sort_keys=True, separators=(",", ":")) + "\n").encode(), 0o400)
    _, candidate_lines, _ = invoke("success", 23, "final DMG verification error: candidate-identity-invalid")
    if candidate_lines:
        abort("candidate mismatch reached a release tool")
    candidate_path.chmod(0o600)
    write(candidate_path, candidate_raw, 0o400)
    candidate_hardlink = artifact_dir / "candidate-hardlink.json"
    os.link(candidate_path, candidate_hardlink)
    _, candidate_lines, _ = invoke("success", 23, "final DMG verification error: candidate-identity-invalid")
    if candidate_lines:
        abort("candidate hardlink reached a release tool")
    candidate_hardlink.unlink()

    outside = temp / "outside-evidence"
    outside.mkdir(mode=0o700)
    invoke("success", 22, "final DMG verification error: unsafe-evidence", evidence_argument=str(outside))
    evidence_link = root / ".release-evidence/evidence-link"
    evidence_link.symlink_to(outside)
    invoke("success", 22, "final DMG verification error: unsafe-evidence", evidence_argument=str(evidence_link))
    nonempty = root / ".release-evidence/nonempty"
    nonempty.mkdir(mode=0o700)
    write(nonempty / "canary", "must-not-overwrite\n")
    invoke("success", 22, "final DMG verification error: unsafe-evidence", evidence_argument=str(nonempty))

    newly_created_relative = root / ".release-work" / f"failure-created-{case_number + 1}"
    invoke(
        "staple-failure",
        31,
        "final DMG verification error: staple-validation-failed",
        evidence_argument=str(newly_created_relative.relative_to(root)),
    )
    if os.path.lexists(newly_created_relative):
        abort("a newly-created empty evidence directory survived failure")

    fixture_policy = root / "Config/dmg-allowed-content.txt"
    policy_raw = fixture_policy.read_bytes()
    fixture_policy.write_bytes(policy_raw + b"policy-tamper\n")
    _, policy_lines, _ = invoke("success", 20, "final DMG verification error: repository-binding-invalid")
    if policy_lines:
        abort("repository policy tamper reached a release tool")
    fixture_policy.write_bytes(policy_raw)
    fixture_policy.chmod(0o600)

    dirty_canary = root / "unreviewed-public-canary"
    write(dirty_canary, "dirty\n")
    _, dirty_lines, _ = invoke("success", 20, "final DMG verification error: repository-binding-invalid")
    if dirty_lines:
        abort("dirty repository reached a release tool")
    dirty_canary.unlink()

    verifier_raw = verifier.read_bytes()
    verifier.write_bytes(verifier_raw + b"\n# verifier tamper\n")
    verifier.chmod(0o700)
    _, verifier_lines, _ = invoke("success", 20, "final DMG verification error: repository-binding-invalid")
    if verifier_lines:
        abort("verifier tamper reached a release tool")
    verifier.write_bytes(verifier_raw)
    verifier.chmod(0o700)

    source_text = SOURCE.read_text(encoding="utf-8")
    required_production_bindings = (
        "HDIUTIL=/usr/bin/hdiutil",
        "CODESIGN=/usr/bin/codesign",
        "SPCTL=/usr/sbin/spctl",
        "XCRUN=/usr/bin/xcrun",
        "XATTR=/usr/bin/xattr",
        "SHASUM=/usr/bin/shasum",
        "DITTO=/usr/bin/ditto",
        "FILE_TOOL=/usr/bin/file",
    )
    for binding in required_production_bindings:
        if binding not in source_text:
            abort(f"missing fixed production tool binding: {binding}")
    for forbidden_text in ("xattr -d", "xattr -c", "xattr -r", "--deep"):
        if forbidden_text in source_text:
            abort(f"verifier contains forbidden mutation/deep-verification text: {forbidden_text}")

print("final DMG verification tests passed")
PY
