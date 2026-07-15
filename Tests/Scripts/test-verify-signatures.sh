#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SOURCE_VERIFY="$ROOT/Scripts/release/verify-signatures.sh"
SOURCE_CREATE="$ROOT/Scripts/release/create-signed-dmg.sh"

fail() {
  printf 'signature verification tests failed: %s\n' "$1" >&2
  exit 1
}

[[ -x "$SOURCE_VERIFY" ]] || fail 'Scripts/release/verify-signatures.sh is missing or not executable'
[[ -x "$SOURCE_CREATE" ]] || fail 'Scripts/release/create-signed-dmg.sh is missing or not executable'

TMP="$(/usr/bin/mktemp -d /private/tmp/utterink-signature-tests.XXXXXX)"
trap '/bin/rm -rf "$TMP"' EXIT HUP INT TERM
/bin/chmod 0700 "$TMP"

FIXTURE_ROOT="$TMP/FixtureRepository"
/bin/mkdir -p \
  "$FIXTURE_ROOT/Scripts/release" \
  "$FIXTURE_ROOT/Config" \
  "$FIXTURE_ROOT/.release-work"
/bin/chmod 0700 "$FIXTURE_ROOT" "$FIXTURE_ROOT/.release-work"
/bin/cp "$SOURCE_VERIFY" "$SOURCE_CREATE" "$FIXTURE_ROOT/Scripts/release/"
/bin/cp "$ROOT/Config/release-entitlements.json" "$FIXTURE_ROOT/Config/"
/usr/bin/printf '%s\n' 'utterink-signature-test-repository-v1' > "$FIXTURE_ROOT/.utterink-signature-test-repository"
/bin/chmod 0600 "$FIXTURE_ROOT/.utterink-signature-test-repository"
/usr/bin/git init -q "$FIXTURE_ROOT"

TOOLS="$FIXTURE_ROOT/FixtureTools"
/bin/mkdir -m 0700 "$TOOLS"
/usr/bin/printf '%s\n' 'utterink-signature-test-tools-v1' > "$TOOLS/.utterink-signature-test-tools"

/bin/cat > "$TOOLS/file" <<'FAKE_FILE'
#!/bin/bash
set -euo pipefail
target="${!#}"
if [[ -f "$target" ]] && /usr/bin/grep -q '^MACHO:' "$target"; then
  /usr/bin/printf 'Mach-O 64-bit executable arm64\n'
else
  /usr/bin/printf 'data\n'
fi
FAKE_FILE

/bin/cat > "$TOOLS/lipo" <<'FAKE_LIPO'
#!/bin/bash
set -euo pipefail
/usr/bin/printf 'lipo\t%s\n' "$*" >> "${UTTERINK_FIXTURE_LOG:?}"
[[ "${1:-}" == -archs && "$#" -eq 2 ]] || exit 51
if [[ "${UTTERINK_SIGNING_TEST_SCENARIO:-}" == wrong-architecture ]]; then
  /usr/bin/printf 'x86_64\n'
else
  /usr/bin/printf 'arm64\n'
fi
FAKE_LIPO

/bin/cat > "$TOOLS/codesign" <<'FAKE_CODESIGN'
#!/bin/bash
set -euo pipefail
scenario="${UTTERINK_SIGNING_TEST_SCENARIO:-success}"
target="${!#}"
/usr/bin/printf 'codesign\t%s\n' "$*" >> "${UTTERINK_FIXTURE_LOG:?}"

is_sign=0
is_verify=0
is_entitlements=0
is_requirement=0
is_extract=0
extract_prefix=''
previous=''
for argument in "$@"; do
  [[ "$argument" == --sign ]] && is_sign=1
  [[ "$argument" == --verify ]] && is_verify=1
  [[ "$argument" == --entitlements ]] && is_entitlements=1
  [[ "$argument" == -r- ]] && is_requirement=1
  if [[ "$previous" == --extract-certificates ]]; then extract_prefix="$argument"; fi
  [[ "$argument" == --extract-certificates ]] && is_extract=1
  [[ "$argument" != --deep ]] || exit 61
  previous="$argument"
done

if [[ "$is_extract" -eq 1 ]]; then
  [[ -n "$extract_prefix" && "$extract_prefix" == /private/tmp/* ]] || exit 60
  if [[ "$scenario" == rotated-embedded-certificate || ( "$scenario" == rotated-dmg-certificate && "$target" == *.dmg ) ]]; then
    /usr/bin/printf 'FIXTURE-LEAF-ROTATED\n' > "${extract_prefix}0"
  else
    /usr/bin/printf 'FIXTURE-LEAF-BASE\n' > "${extract_prefix}0"
  fi
  exit 0
fi

if [[ "$is_verify" -eq 1 && "$target" == */UtterInk.app ]]; then
  if [[ "$scenario" == component-swap && ! -e "${UTTERINK_FIXTURE_LOG}.component-swap-fired" ]]; then
    : > "${UTTERINK_FIXTURE_LOG}.component-swap-fired"
    /usr/bin/printf 'attacker mutation\n' >> "$target/Contents/Resources/readme.txt"
  elif [[ "$scenario" == mutate-verifier && ! -e "${UTTERINK_FIXTURE_LOG}.mutate-verifier-fired" ]]; then
    : > "${UTTERINK_FIXTURE_LOG}.mutate-verifier-fired"
    /usr/bin/touch "$([[ "$0" == */FixtureTools/* ]] && /usr/bin/dirname "$0")/../Scripts/release/verify-signatures.sh"
  elif [[ "$scenario" == mutate-release-policy && ! -e "${UTTERINK_FIXTURE_LOG}.mutate-policy-fired" ]]; then
    : > "${UTTERINK_FIXTURE_LOG}.mutate-policy-fired"
    /usr/bin/touch "$([[ "$0" == */FixtureTools/* ]] && /usr/bin/dirname "$0")/../Config/release-entitlements.json"
  fi
fi

if [[ "$is_sign" -eq 1 ]]; then
  [[ "$target" == *.dmg && -f "$target" ]] || exit 62
  [[ "$*" == *'--timestamp'* && "$*" == *'--sign 00112233445566778899aabbccddeeff00112233'* ]] || exit 63
  [[ "$scenario" != dmg-sign-fail ]] || exit 64
  /usr/bin/printf 'DMG-SIGNED:ABCDE12345\n' >> "$target"
  exit 0
fi

kind=nested
case "$target" in
  */UtterInk.app|*/UtterInk.app/Contents/MacOS/UtterInk) kind=app ;;
  *.dmg) kind=dmg ;;
esac

if [[ "$is_verify" -eq 1 ]]; then
  [[ "$scenario" != verify-fail ]] || exit 65
  exit 0
fi

if [[ "$is_entitlements" -eq 1 ]]; then
  if [[ "$kind" == app && "$scenario" != missing-app-entitlement ]]; then
    if [[ "$scenario" == extra-app-entitlement ]]; then
      /usr/bin/printf '%s\n' '<?xml version="1.0"?><plist version="1.0"><dict><key>com.apple.security.device.audio-input</key><true/><key>com.apple.security.network.client</key><true/></dict></plist>'
    else
      /usr/bin/printf '%s\n' '<?xml version="1.0"?><plist version="1.0"><dict><key>com.apple.security.device.audio-input</key><true/></dict></plist>'
    fi
  elif [[ "$kind" == nested && "$scenario" == nested-entitlement ]]; then
    /usr/bin/printf '%s\n' '<?xml version="1.0"?><plist version="1.0"><dict><key>com.apple.security.device.audio-input</key><true/></dict></plist>'
  fi
  exit 0
fi

identifier=fixture.component
[[ "$kind" != app ]] || identifier=dev.utterink.UtterInk
[[ "$scenario" != wrong-app-identifier || "$kind" != app ]] || identifier=dev.utterink.Wrong
if [[ "$is_requirement" -eq 1 ]]; then
  [[ "$scenario" != missing-requirement ]] || exit 0
  requirement_identifier="$identifier"
  [[ "$scenario" != wrong-requirement-identifier ]] || requirement_identifier=dev.attacker.Other
  /usr/bin/printf 'designated => identifier "%s" and certificate leaf[subject.OU] = "ABCDE12345"\n' "$requirement_identifier" >&2
  exit 0
fi

team=ABCDE12345
authority='Developer ID Application: Fixture Author (ABCDE12345)'
[[ "$scenario" != wrong-team ]] || team=ZZZZZ99999
[[ "$scenario" != wrong-authority ]] || authority='Apple Development: Fixture Author (ABCDE12345)'
/usr/bin/printf '%s\n' \
  "Identifier=$identifier" \
  "Authority=$authority" \
  'Authority=Developer ID Certification Authority' \
  'Authority=Apple Root CA' \
  "TeamIdentifier=$team" >&2
[[ "$scenario" == missing-timestamp ]] || /usr/bin/printf '%s\n' 'Timestamp=Jul 15, 2026 at 12:00:00' >&2
[[ "$scenario" == missing-runtime ]] || /usr/bin/printf '%s\n' 'Runtime Version=14.0.0' 'flags=0x10000(runtime)' >&2
FAKE_CODESIGN

/bin/cat > "$TOOLS/security" <<'FAKE_SECURITY'
#!/bin/bash
set -euo pipefail
/usr/bin/printf 'security\t%s\n' "$*" >> "${UTTERINK_FIXTURE_LOG:?}"
case "${1:-}" in
  find-identity)
    /usr/bin/printf '%s\n' '  1) 00112233445566778899AABBCCDDEEFF00112233 "Developer ID Application: Fixture Author (ABCDE12345)"'
    if [[ "${UTTERINK_SIGNING_TEST_SCENARIO:-}" == duplicate-identity ]]; then
      /usr/bin/printf '%s\n' '  2) 00112233445566778899AABBCCDDEEFF00112233 "Developer ID Application: Fixture Author (ABCDE12345)"'
    fi
    ;;
  find-certificate)
    marker=BASE
    [[ "${UTTERINK_SIGNING_TEST_SCENARIO:-}" != same-name-certificate-rotation ]] || marker=ROTATED
    /usr/bin/printf '%s\n' '-----BEGIN CERTIFICATE-----' "$marker" '-----END CERTIFICATE-----'
    if [[ "${UTTERINK_SIGNING_TEST_SCENARIO:-}" == duplicate-certificate ]]; then
      /usr/bin/printf '%s\n' '-----BEGIN CERTIFICATE-----' "$marker" '-----END CERTIFICATE-----'
    fi
    ;;
  verify-cert)
    [[ "$*" == *'-p codeSign'* ]] || exit 70
    [[ "${UTTERINK_SIGNING_TEST_SCENARIO:-}" != untrusted-certificate ]] || exit 71
    ;;
  *) exit 72 ;;
esac
FAKE_SECURITY

/bin/cat > "$TOOLS/openssl" <<'FAKE_OPENSSL'
#!/bin/bash
set -euo pipefail
/usr/bin/printf 'openssl\t%s\n' "$*" >> "${UTTERINK_FIXTURE_LOG:?}"
input=''
output=''
previous=''
for argument in "$@"; do
  [[ "$previous" != -in ]] || input="$argument"
  [[ "$previous" != -out ]] || output="$argument"
  previous="$argument"
done
variant=BASE
if [[ -n "$input" ]] && /usr/bin/grep -Fq ROTATED "$input"; then variant=ROTATED; fi
if [[ -n "$output" ]]; then
  /usr/bin/printf '%s\n' '-----BEGIN CERTIFICATE-----' "$variant" '-----END CERTIFICATE-----' > "$output"
  exit 0
fi
if [[ "$*" == *'-checkend 0'* ]]; then
  [[ "${UTTERINK_SIGNING_TEST_SCENARIO:-}" != expired-certificate ]] || exit 73
  exit 0
fi
if [[ "$*" == *'-subject'* ]]; then
  /usr/bin/printf '%s\n' 'subject=' '    commonName = Developer ID Application: Fixture Author (ABCDE12345)' '    organizationalUnitName = ABCDE12345'
fi
[[ "$*" != *'-startdate'* ]] || /usr/bin/printf '%s\n' 'notBefore=Jul  1 00:00:00 2026 GMT'
[[ "$*" != *'-enddate'* ]] || /usr/bin/printf '%s\n' 'notAfter=Jul  1 00:00:00 2031 GMT'
if [[ "$*" == *'-sha1'* ]]; then
  if [[ "$variant" == BASE ]]; then
    /usr/bin/printf '%s\n' 'sha1 Fingerprint=00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33'
  else
    /usr/bin/printf '%s\n' 'sha1 Fingerprint=11:11:11:11:11:11:11:11:11:11:11:11:11:11:11:11:11:11:11:11'
  fi
fi
if [[ "$*" == *'-sha256'* ]]; then
  if [[ "$variant" == BASE ]]; then
    /usr/bin/printf '%s\n' 'sha256 Fingerprint=AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99'
  else
    /usr/bin/printf '%s\n' 'sha256 Fingerprint=BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB'
  fi
fi
FAKE_OPENSSL

for tool in file lipo codesign security openssl; do
  /bin/chmod 0700 "$TOOLS/$tool"
done
FIXTURE_LOG="$TMP/tool-commands.log"
: > "$FIXTURE_LOG"
/bin/chmod 0600 "$FIXTURE_LOG"

/bin/cat > "$FIXTURE_ROOT/Scripts/create-dmg.sh" <<'FAKE_CREATE_DMG'
#!/bin/bash
set -euo pipefail
/usr/bin/printf 'create-dmg\t%s\n' "$*" >> "${UTTERINK_FIXTURE_LOG:?}"
[[ "${UTTERINK_SIGNING_TEST_SCENARIO:-}" != create-fail ]] || exit 81
app=''
output=''
mode=''
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --app) app="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --mode) mode="$2"; shift 2 ;;
    *) exit 82 ;;
  esac
done
[[ "$app" == */UtterInk.app && -d "$app" && "$output" == *.dmg && "$mode" == signed ]] || exit 83
[[ "$app" == */.utterink-signed-dmg.*/pinned-candidate/UtterInk.app ]] || exit 84
/bin/mkdir -p "$(/usr/bin/dirname "$output")"
/usr/bin/printf '%s\n' 'SIGNED-DMG-BASE' > "$output"
if [[ "${UTTERINK_SIGNING_TEST_SCENARIO:-}" == mutate-create-dmg ]]; then /usr/bin/touch "$0"; fi
FAKE_CREATE_DMG

/bin/cat > "$FIXTURE_ROOT/Scripts/inspect-dmg.sh" <<'FAKE_INSPECT_DMG'
#!/bin/bash
set -euo pipefail
/usr/bin/printf 'inspect-dmg\t%s\n' "$*" >> "${UTTERINK_FIXTURE_LOG:?}"
[[ "${UTTERINK_SIGNING_TEST_SCENARIO:-}" != inspect-fail ]] || exit 91
[[ "$#" -eq 4 && "$1" == --dmg && -f "$2" && "$3" == --mode && "$4" == signed ]] || exit 92
/usr/bin/grep -Fq 'DMG-SIGNED:ABCDE12345' "$2" || exit 93
scenario="${UTTERINK_SIGNING_TEST_SCENARIO:-success}"
if [[ "$scenario" == inspect-schema ]]; then
  /usr/bin/printf '%s\n' '{"mode":"signed","signature":"developer-id","status":"valid"}'
  exit 0
fi
/usr/bin/python3 -I - "$2" "$scenario" <<'PY'
from pathlib import Path
import hashlib
import json
import sys

dmg = Path(sys.argv[1])
scenario = sys.argv[2]
digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
value = {
    "architecture": "x86_64" if scenario == "inspect-fixed-value" else "arm64",
    "buildNumber": "1",
    "bundleIdentifier": "dev.utterink.UtterInk",
    "dmgFilename": "UtterInk-0.1.0-arm64.dmg",
    "dmgSHA256": digest,
    "machOCount": 3,
    "manifest": ["Applications -> /Applications", "UtterInk.app directory"],
    "minimumSystemVersion": "14.0",
    "mode": "signed",
    "product": "UtterInk",
    "signature": "developer-id",
    "status": "valid",
    "version": "0.1.0",
}
if scenario == "inspect-swap":
    with dmg.open("ab") as stream:
        stream.write(b"INSPECTOR-SWAP\n")
print(json.dumps(value, sort_keys=True, separators=(",", ":")))
PY
if [[ "$scenario" == mutate-inspect-dmg ]]; then /usr/bin/touch "$0"; fi
FAKE_INSPECT_DMG
/bin/chmod 0700 "$FIXTURE_ROOT/Scripts/create-dmg.sh" "$FIXTURE_ROOT/Scripts/inspect-dmg.sh"

/usr/bin/printf '%s\n' '/.release-work/' > "$FIXTURE_ROOT/.gitignore"
/usr/bin/git -C "$FIXTURE_ROOT" config user.name 'UtterInk Fixture'
/usr/bin/git -C "$FIXTURE_ROOT" config user.email 'fixture@utterink.invalid'
/usr/bin/git -C "$FIXTURE_ROOT" add .
/usr/bin/git -C "$FIXTURE_ROOT" commit -qm 'fixture release contract'
FIXTURE_COMMIT="$(/usr/bin/git -C "$FIXTURE_ROOT" rev-parse HEAD)"
FIXTURE_TREE="$(/usr/bin/git -C "$FIXTURE_ROOT" rev-parse 'HEAD^{tree}')"
BASE_CERTIFICATE_SHA256=aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899

make_candidate() {
  local name="$1"
  local candidate="$FIXTURE_ROOT/.release-work/$name"
  local app="$candidate/UtterInk.app"
  /bin/mkdir -p \
    "$app/Contents/MacOS" \
    "$app/Contents/Frameworks/A.framework" \
    "$app/Contents/Helpers" \
    "$app/Contents/Resources"
  /bin/chmod 0700 "$candidate"
  /usr/bin/printf '%s\n' 'MACHO:arm64' > "$app/Contents/MacOS/UtterInk"
  /usr/bin/printf '%s\n' 'MACHO:arm64' > "$app/Contents/Frameworks/A.framework/A"
  /usr/bin/printf '%s\n' 'MACHO:arm64' > "$app/Contents/Helpers/Helper"
  /usr/bin/printf '%s\n' 'fixture resource' > "$app/Contents/Resources/readme.txt"
  /bin/chmod 0755 \
    "$app/Contents/MacOS/UtterInk" \
    "$app/Contents/Frameworks/A.framework/A" \
    "$app/Contents/Helpers/Helper"
  /usr/bin/python3 -I - \
    "$candidate" "$FIXTURE_COMMIT" "$FIXTURE_TREE" "$FIXTURE_ROOT/Config/release-entitlements.json" <<'PY'
from pathlib import Path, PurePosixPath
import hashlib
import json
import os
import stat
import sys

candidate = Path(sys.argv[1])
commit, tree = sys.argv[2:4]
policy = Path(sys.argv[4])
value = {
    "schemaVersion": 1,
    "evidenceType": "release-candidate-test",
    "product": "UtterInk",
    "source": {"commit": commit, "tree": tree, "releaseTag": "v0.1.0", "clean": True},
    "release": {
        "configuration": "Release", "marketingVersion": "0.1.0", "buildNumber": "1",
        "bundleIdentifier": "dev.utterink.UtterInk", "deploymentTarget": "14.0",
        "architecture": "arm64", "dmgFilename": "UtterInk-0.1.0-arm64.dmg",
    },
    "toolchain": {
        "lockSHA256": "e" * 64, "xcodeVersion": "26.4.1", "xcodeBuild": "17E202",
        "sdkVersion": "26.4", "sdkBuild": "25A1",
        "swiftVersion": "Apple Swift version 6.3 (swiftlang-6.3.0 clang-1700.0.0.0)",
        "xcodegenVersion": "2.45.4", "xcodegenBinarySHA256": "f" * 64,
    },
    "packageResolution": {"path": "Packages/UtterInkKit/Package.resolved", "sha256": "a" * 64},
    "policies": {
        "releaseMetadataSHA256": "d" * 64,
        "releaseEntitlementsSHA256": hashlib.sha256(policy.read_bytes()).hexdigest(),
        "releaseInfoPolicySHA256": "c" * 64,
        "ciToolchainSHA256": "b" * 64,
    },
    "checks": {
        "history": True, "metadata": True, "entitlements": True, "infoPolicy": True,
        "packageResolution": True, "generatedProjectClean": True,
    },
}
candidate_raw = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
(candidate / "candidate.json").write_bytes(candidate_raw)

def safe_target(relative, target):
    path = PurePosixPath(target)
    if not target or path.is_absolute() or ".." in path.parts or ".." in PurePosixPath(relative).parent.joinpath(path).parts:
        raise SystemExit(1)
    return target

def logical_tree(root):
    records = []
    pending = [root]
    while pending:
        directory = pending.pop()
        for path in directory.iterdir():
            metadata = os.lstat(path)
            relative = path.relative_to(root).as_posix()
            mode = stat.S_IMODE(metadata.st_mode)
            if stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode):
                records.append([relative, "directory", mode, ""])
                pending.append(path)
            elif stat.S_ISREG(metadata.st_mode):
                records.append([relative, "file", mode, hashlib.sha256(path.read_bytes()).hexdigest()])
            elif stat.S_ISLNK(metadata.st_mode):
                records.append([relative, "symlink", mode, safe_target(relative, os.readlink(path))])
            else:
                raise SystemExit(1)
    records.sort(key=lambda item: item[0].encode("utf-8"))
    digest = hashlib.sha256()
    for record in records:
        digest.update((json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8"))
    return digest.hexdigest()

unsigned = {
    "appTreeSHA256": logical_tree(candidate / "UtterInk.app"),
    "archiveTreeSHA256": "2" * 64,
    "candidateCommit": commit,
    "candidateJSONSHA256": hashlib.sha256(candidate_raw).hexdigest(),
    "evidenceType": "unsigned-build",
    "product": "UtterInk",
    "schemaVersion": 1,
    "status": "valid",
    "treeAlgorithm": "utterink-logical-tree-v1",
}
(candidate / "unsigned-build-evidence.json").write_text(
    json.dumps(unsigned, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8"
)
PY
  /usr/bin/printf '%s\n' "$candidate"
}

run_verify() {
  local candidate="$1"
  local scenario="$2"
  local output="$3"
  /usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    LC_ALL=C \
    UTTERINK_SIGNING_TEST_MODE=1 \
    UTTERINK_SIGNING_TEST_TOOL_ROOT="$TOOLS" \
    UTTERINK_SIGNING_TEST_SCENARIO="$scenario" \
    UTTERINK_FIXTURE_LOG="$FIXTURE_LOG" \
    "$FIXTURE_ROOT/Scripts/release/verify-signatures.sh" \
      --candidate "$candidate" \
      --identity 'Developer ID Application: Fixture Author (ABCDE12345)' \
      --team-id ABCDE12345 \
      --expected-certificate-sha256 "$BASE_CERTIFICATE_SHA256" \
      --output "$output"
}

expect_verify_failure() {
  local candidate="$1"
  local scenario="$2"
  local output="$candidate/$scenario.json"
  if run_verify "$candidate" "$scenario" "$output" > "$TMP/stdout" 2> "$TMP/stderr"; then
    fail "verify-signatures accepted scenario: $scenario"
  fi
  [[ ! -e "$output" && ! -s "$TMP/stdout" ]] || fail "$scenario left evidence or stdout"
  /usr/bin/grep -Eq '^signature verification error: [a-z0-9-]+$' "$TMP/stderr" ||
    fail "$scenario emitted an unsafe diagnostic"
}

run_create() {
  local candidate="$1"
  local scenario="$2"
  /usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    LC_ALL=C \
    UTTERINK_SIGNING_TEST_MODE=1 \
    UTTERINK_SIGNING_TEST_TOOL_ROOT="$TOOLS" \
    UTTERINK_SIGNING_TEST_SCENARIO="$scenario" \
    UTTERINK_FIXTURE_LOG="$FIXTURE_LOG" \
    "$FIXTURE_ROOT/Scripts/release/create-signed-dmg.sh" \
      --candidate "$candidate" \
      --identity 'Developer ID Application: Fixture Author (ABCDE12345)' \
      --team-id ABCDE12345
}

assert_no_signed_outputs() {
  local candidate="$1"
  for name in UtterInk-0.1.0-arm64.dmg pre-staple.sha256 signing-evidence.json; do
    [[ ! -e "$candidate/$name" && ! -L "$candidate/$name" ]] || fail "failure left partial output: $name"
  done
  [[ -z "$(/usr/bin/find "$candidate" -maxdepth 1 \( -name '.utterink-signed-dmg.*' -o -name '.create-signature-verification-*.json' \) -print -quit)" ]] ||
    fail 'failure left private signed-DMG work artifacts'
}

expect_signal_status() {
  local kind="$1"
  local candidate="$2"
  local signal_name="$3"
  local expected_status="$4"
  local signal_lower
  signal_lower="$(/usr/bin/printf '%s' "$signal_name" | /usr/bin/tr '[:upper:]' '[:lower:]')"
  local scenario="$kind-signal-$signal_lower"
  local ready="$FIXTURE_LOG.$scenario.ready"
  local output="$candidate/$scenario.json"
  local script="$FIXTURE_ROOT/Scripts/release/verify-signatures.sh"
  [[ "$kind" == verify ]] || script="$FIXTURE_ROOT/Scripts/release/create-signed-dmg.sh"
  /bin/rm -f "$ready"
  /usr/bin/python3 -I - \
    "$kind" "$script" "$candidate" "$signal_name" "$expected_status" \
    "$scenario" "$ready" "$output" "$TMP/$scenario.stdout" "$TMP/$scenario.stderr" \
    "$TOOLS" "$FIXTURE_LOG" <<'PY' || fail "$kind $signal_name signal status or cleanup drifted"
from pathlib import Path
import os
import signal
import subprocess
import sys
import time

kind, script, candidate, signal_name, expected_text, scenario = sys.argv[1:7]
ready, output, stdout_path, stderr_path, tools, fixture_log = map(Path, sys.argv[7:13])
command = [
    script,
    "--candidate", candidate,
    "--identity", "Developer ID Application: Fixture Author (ABCDE12345)",
    "--team-id", "ABCDE12345",
]
if kind == "verify":
    command += [
        "--expected-certificate-sha256",
        "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899",
        "--output", str(output),
    ]
environment = {
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "LC_ALL": "C",
    "UTTERINK_SIGNING_TEST_MODE": "1",
    "UTTERINK_SIGNING_TEST_TOOL_ROOT": str(tools),
    "UTTERINK_SIGNING_TEST_SCENARIO": scenario,
    "UTTERINK_FIXTURE_LOG": str(fixture_log),
}
process = None
try:
    with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
        process = subprocess.Popen(
            command,
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=stdout,
            stderr=stderr,
            start_new_session=True,
        )
        deadline = time.monotonic() + 5
        while not ready.exists():
            if process.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError
            time.sleep(0.01)
        os.kill(process.pid, getattr(signal, "SIG" + signal_name))
        try:
            actual_status = process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)
            raise RuntimeError
    if actual_status != int(expected_text):
        raise RuntimeError
    if stdout_path.read_bytes() or stderr_path.read_bytes() or os.path.lexists(output):
        raise RuntimeError
except (OSError, RuntimeError, ValueError):
    if process is not None and process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except OSError:
            pass
        process.wait()
    raise SystemExit(1)
finally:
    try:
        ready.unlink()
    except FileNotFoundError:
        pass
PY
}

expect_verify_signal_status() {
  local candidate="$1"
  local signal_name="$2"
  local expected_status="$3"
  expect_signal_status verify "$candidate" "$signal_name" "$expected_status"
}

expect_create_signal_status() {
  local candidate="$1"
  local signal_name="$2"
  local expected_status="$3"
  expect_signal_status create "$candidate" "$signal_name" "$expected_status"
  assert_no_signed_outputs "$candidate"
  [[ -z "$(/usr/bin/find "$candidate" -maxdepth 1 -name '.utterink-signed-dmg.*' -print -quit)" ]] ||
    fail "create $signal_name left its private work directory"
}

candidate="$(make_candidate verify-success)"
verify_output="$candidate/verification.json"
run_verify "$candidate" success "$verify_output" > "$TMP/stdout" 2> "$TMP/stderr" ||
  fail "valid signatures were rejected: $(/bin/cat "$TMP/stderr")"
[[ ! -s "$TMP/stdout" && ! -s "$TMP/stderr" && -s "$verify_output" ]] || fail 'valid verification output contract drifted'
/usr/bin/python3 -I - "$verify_output" <<'PY' || fail 'verification evidence is invalid or leaks identity'
from pathlib import Path
import json
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
value = json.loads(text)
if set(value) != {
    "candidateCommit", "candidateJSONSHA256", "certificate", "components", "evidenceType",
    "product", "schemaVersion", "signedAppTreeSHA256", "status", "teamID", "treeAlgorithm",
    "unsignedBuildEvidenceSHA256",
}:
    raise SystemExit(1)
if value["schemaVersion"] != 1 or value["evidenceType"] != "signature-verification" or value["status"] != "valid":
    raise SystemExit(1)
if value["product"] != "UtterInk" or value["teamID"] != "ABCDE12345" or len(value["components"]) != 5:
    raise SystemExit(1)
if value["treeAlgorithm"] != "utterink-logical-tree-v1" or len(value["signedAppTreeSHA256"]) != 64:
    raise SystemExit(1)
if value["certificate"]["trust"] != "valid" or not value["certificate"]["notBefore"] or not value["certificate"]["notAfter"]:
    raise SystemExit(1)
if set(value["certificate"]) != {"notAfter", "notBefore", "sha256", "trust"}:
    raise SystemExit(1)
if "Fixture Author" in text or "Developer ID Application" in text or "/private/tmp/" in text or "/Users/" in text:
    raise SystemExit(1)
app_records = [item for item in value["components"] if item["path"] in {"UtterInk.app", "UtterInk.app/Contents/MacOS/UtterInk"}]
if len(app_records) != 2 or any(item["entitlements"] != {"com.apple.security.device.audio-input": True} for item in app_records):
    raise SystemExit(1)
if any(item["entitlements"] for item in value["components"] if item not in app_records):
    raise SystemExit(1)
if any(item["identifier"] != "dev.utterink.UtterInk" for item in app_records):
    raise SystemExit(1)
PY

for needle in \
  $'codesign\t--verify --strict --verbose=4 ' \
  $'codesign\t-d --verbose=4 --entitlements :- ' \
  $'codesign\t-d -r- ' \
  $'codesign\t-d --extract-certificates ' \
  $'lipo\t-archs '; do
  /usr/bin/grep -Fq "$needle" "$FIXTURE_LOG" || fail "required verification command missing: $needle"
done
/usr/bin/grep -Eq $'security\tverify-cert .* -p codeSign$' "$FIXTURE_LOG" ||
  fail 'certificate trust policy is not exactly codeSign'
if /usr/bin/grep -Eq $'security\tverify-cert .* -p codesigning$' "$FIXTURE_LOG"; then
  fail 'legacy codesigning trust policy was used'
fi

/bin/mkdir -m 0700 "$candidate/nested-output"
for unsafe_output in \
  "$TMP/outside-verification.json" \
  "$candidate/nested-output/verification.json" \
  "$candidate/nested-output/../lexical-verification.json"; do
  if run_verify "$candidate" success "$unsafe_output" > "$TMP/stdout" 2> "$TMP/stderr"; then
    fail "verify-signatures accepted non-direct output: $unsafe_output"
  fi
  [[ ! -e "$unsafe_output" && ! -e "$candidate/lexical-verification.json" ]] ||
    fail 'non-direct verification output was published'
  [[ "$(/bin/cat "$TMP/stderr")" == 'signature verification error: unsafe-candidate' ]] ||
    fail 'non-direct verification output rejection drifted'
done

checks_candidate="$(make_candidate verify-invalid-checks)"
/usr/bin/python3 -I - "$checks_candidate" <<'PY'
from pathlib import Path
import hashlib, json, sys
candidate = Path(sys.argv[1])
manifest = json.loads((candidate / "candidate.json").read_text(encoding="utf-8"))
manifest["checks"]["history"] = False
raw = (json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
(candidate / "candidate.json").write_bytes(raw)
unsigned = json.loads((candidate / "unsigned-build-evidence.json").read_text(encoding="utf-8"))
unsigned["candidateJSONSHA256"] = hashlib.sha256(raw).hexdigest()
(candidate / "unsigned-build-evidence.json").write_text(
    json.dumps(unsigned, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8"
)
PY
expect_verify_failure "$checks_candidate" invalid-checks

unsigned_candidate="$(make_candidate verify-invalid-unsigned)"
/usr/bin/python3 -I - "$unsigned_candidate/unsigned-build-evidence.json" <<'PY'
from pathlib import Path
import json, sys
path = Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["candidateCommit"] = "0" * 40
path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
expect_verify_failure "$unsigned_candidate" invalid-unsigned-evidence

noncanonical_candidate="$(make_candidate verify-noncanonical-unsigned)"
/usr/bin/printf ' ' >> "$noncanonical_candidate/unsigned-build-evidence.json"
expect_verify_failure "$noncanonical_candidate" noncanonical-unsigned-evidence

signal_candidate="$(make_candidate verify-signals)"
expect_verify_signal_status "$signal_candidate" HUP 129
expect_verify_signal_status "$signal_candidate" INT 130
expect_verify_signal_status "$signal_candidate" TERM 143

for scenario in \
  wrong-team \
  wrong-authority \
  missing-timestamp \
  missing-runtime \
  wrong-architecture \
  wrong-app-identifier \
  wrong-requirement-identifier \
  missing-app-entitlement \
  extra-app-entitlement \
  nested-entitlement \
  missing-requirement \
  verify-fail \
  component-swap \
  mutate-verifier \
  mutate-release-policy \
  rotated-embedded-certificate \
  expired-certificate \
  untrusted-certificate; do
  expect_verify_failure "$candidate" "$scenario"
done

if /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
  UTTERINK_SIGNING_TEST_MODE=1 UTTERINK_SIGNING_TEST_TOOL_ROOT="$TOOLS" \
  UTTERINK_FIXTURE_LOG="$FIXTURE_LOG" \
  "$SOURCE_VERIFY" --candidate "$candidate" \
    --identity 'Developer ID Application: Fixture Author (ABCDE12345)' \
    --team-id ABCDE12345 --expected-certificate-sha256 "$BASE_CERTIFICATE_SHA256" \
    --output "$TMP/real.json" > "$TMP/stdout" 2> "$TMP/stderr"; then
  fail 'real repository accepted signing test mode'
fi
[[ "$(/bin/cat "$TMP/stderr")" == 'signature verification error: invalid-test-repository' ]] ||
  fail 'test-mode repository boundary drifted'

prepare_signed_candidate() {
  local candidate="$1"
  run_verify "$candidate" success "$candidate/signature-verification.json" > "$TMP/prepare.stdout" 2> "$TMP/prepare.stderr" ||
    fail "could not prepare retained signature evidence: $(/bin/cat "$TMP/prepare.stderr")"
}

prepared_template="$(make_candidate create-template)"
prepare_signed_candidate "$prepared_template"
clone_prepared_candidate() {
  local name="$1"
  local destination="$FIXTURE_ROOT/.release-work/$name"
  /bin/cp -R "$prepared_template" "$destination"
  /bin/chmod 0700 "$destination"
  /usr/bin/printf '%s\n' "$destination"
}

create_signal_candidate="$(clone_prepared_candidate create-signals)"
expect_create_signal_status "$create_signal_candidate" HUP 129
expect_create_signal_status "$create_signal_candidate" INT 130
expect_create_signal_status "$create_signal_candidate" TERM 143

create_candidate="$(clone_prepared_candidate create-success)"
preexisting_verification_hash="$(/usr/bin/shasum -a 256 "$create_candidate/signature-verification.json")"
verification_count_before="$(/usr/bin/grep -c $'security\tfind-certificate' "$FIXTURE_LOG" || :)"
run_create "$create_candidate" success > "$TMP/stdout" 2> "$TMP/stderr" ||
  fail "signed DMG creation failed: $(/bin/cat "$TMP/stderr")"
[[ ! -s "$TMP/stderr" ]] || fail 'signed DMG creation wrote stderr'
verification_count_after="$(/usr/bin/grep -c $'security\tfind-certificate' "$FIXTURE_LOG" || :)"
[[ "$verification_count_after" -eq $((verification_count_before + 1)) ]] ||
  fail 'signed DMG creation identity preflight count drifted'
[[ "$(/usr/bin/shasum -a 256 "$create_candidate/signature-verification.json")" == "$preexisting_verification_hash" ]] ||
  fail 'signed DMG creation mutated preexisting signer verification evidence'
[[ -z "$(/usr/bin/find "$create_candidate" -maxdepth 1 -name '.create-signature-verification-*.json' -print -quit)" ]] ||
  fail 'temporary independent verification evidence survived creation'
for name in UtterInk-0.1.0-arm64.dmg pre-staple.sha256 signing-evidence.json; do
  [[ -f "$create_candidate/$name" && ! -L "$create_candidate/$name" ]] || fail "signed output missing: $name"
done
/usr/bin/python3 -I - "$create_candidate" <<'PY' || fail 'signed DMG evidence or hash is invalid'
from pathlib import Path
import hashlib
import json
import sys

candidate = Path(sys.argv[1])
dmg = candidate / "UtterInk-0.1.0-arm64.dmg"
digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
if (candidate / "pre-staple.sha256").read_text(encoding="ascii") != f"{digest}  {dmg.name}\n":
    raise SystemExit(1)
text = (candidate / "signing-evidence.json").read_text(encoding="utf-8")
value = json.loads(text)
expected_keys = {"dmgFilename", "dmgSHA256", "evidenceType", "inspection", "product", "schemaVersion", "signatureVerificationSHA256", "status", "teamID"}
if set(value) != expected_keys or value["dmgSHA256"] != digest or value["teamID"] != "ABCDE12345":
    raise SystemExit(1)
expected_inspection = {
    "architecture": "arm64",
    "buildNumber": "1",
    "bundleIdentifier": "dev.utterink.UtterInk",
    "dmgFilename": "UtterInk-0.1.0-arm64.dmg",
    "dmgSHA256": digest,
    "machOCount": 3,
    "manifest": ["Applications -> /Applications", "UtterInk.app directory"],
    "minimumSystemVersion": "14.0",
    "mode": "signed",
    "product": "UtterInk",
    "signature": "developer-id",
    "status": "valid",
    "version": "0.1.0",
}
if value["inspection"] != expected_inspection:
    raise SystemExit(1)
if "Fixture Author" in text or "Developer ID Application" in text or "/private/tmp/" in text or "/Users/" in text:
    raise SystemExit(1)
PY
/usr/bin/grep -Eq $'create-dmg\t--app .*/[.]utterink-signed-dmg[.][^/]*/pinned-candidate/UtterInk[.]app ' "$FIXTURE_LOG" ||
  fail 'shared DMG creator did not receive the private pinned app'
/usr/bin/grep -Fq -- '--mode signed' "$FIXTURE_LOG" || fail 'shared DMG creator did not use signed mode'
/usr/bin/grep -Fq $'inspect-dmg\t--dmg ' "$FIXTURE_LOG" || fail 'shared DMG inspector was not called'
/usr/bin/grep -Fq $'codesign\t--force --timestamp --sign 00112233445566778899aabbccddeeff00112233 ' "$FIXTURE_LOG" ||
  fail 'outer DMG signing command drifted'

before_hash="$(/usr/bin/shasum -a 256 "$create_candidate/UtterInk-0.1.0-arm64.dmg" "$create_candidate/pre-staple.sha256" "$create_candidate/signing-evidence.json")"
if run_create "$create_candidate" success > "$TMP/stdout" 2> "$TMP/stderr"; then
  fail 'signed DMG creator clobbered existing outputs'
fi
after_hash="$(/usr/bin/shasum -a 256 "$create_candidate/UtterInk-0.1.0-arm64.dmg" "$create_candidate/pre-staple.sha256" "$create_candidate/signing-evidence.json")"
[[ "$after_hash" == "$before_hash" ]] || fail 'no-clobber failure mutated existing outputs'

for scenario in create-fail dmg-sign-fail inspect-fail inspect-schema inspect-fixed-value inspect-swap duplicate-certificate duplicate-identity same-name-certificate-rotation rotated-dmg-certificate mutate-create-dmg mutate-inspect-dmg; do
  failed_candidate="$(clone_prepared_candidate "create-$scenario")"
  if run_create "$failed_candidate" "$scenario" > "$TMP/stdout" 2> "$TMP/stderr"; then
    fail "signed DMG creation accepted scenario: $scenario"
  fi
  assert_no_signed_outputs "$failed_candidate"
done

retained_mismatch_candidate="$(clone_prepared_candidate create-retained-mismatch)"
/usr/bin/python3 -I - "$retained_mismatch_candidate/signature-verification.json" <<'PY'
from pathlib import Path
import json, sys
path = Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["status"] = "invalid"
path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
if run_create "$retained_mismatch_candidate" success > "$TMP/stdout" 2> "$TMP/stderr"; then
  fail 'signed DMG creator accepted mismatched retained evidence'
fi
assert_no_signed_outputs "$retained_mismatch_candidate"

unsigned_mismatch_candidate="$(clone_prepared_candidate create-unsigned-mismatch)"
/usr/bin/python3 -I - "$unsigned_mismatch_candidate/unsigned-build-evidence.json" <<'PY'
from pathlib import Path
import json, sys
path = Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["archiveTreeSHA256"] = "3" * 64
path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
if run_create "$unsigned_mismatch_candidate" success > "$TMP/stdout" 2> "$TMP/stderr"; then
  fail 'signed DMG creator accepted unsigned evidence drift'
fi
assert_no_signed_outputs "$unsigned_mismatch_candidate"

app_mismatch_candidate="$(clone_prepared_candidate create-app-mismatch)"
/usr/bin/printf 'post-verification swap\n' >> "$app_mismatch_candidate/UtterInk.app/Contents/Resources/readme.txt"
if run_create "$app_mismatch_candidate" success > "$TMP/stdout" 2> "$TMP/stderr"; then
  fail 'signed DMG creator accepted a post-verification app swap'
fi
assert_no_signed_outputs "$app_mismatch_candidate"

for script in "$SOURCE_VERIFY" "$SOURCE_CREATE"; do
  /usr/bin/grep -Fq '/usr/bin/codesign' "$script" || fail "production codesign is not absolute in ${script##*/}"
  /usr/bin/grep -Fq 'UTTERINK_SIGNING_TEST_MODE' "$script" || fail "strict signing test mode is missing in ${script##*/}"
done

for script in "$SOURCE_VERIFY" "$SOURCE_CREATE"; do
  /usr/bin/grep -Fq 'trap cleanup EXIT' "$script" || fail "EXIT cleanup trap missing in ${script##*/}"
  /usr/bin/grep -Fq "trap 'exit 129' HUP" "$script" || fail "HUP status trap missing in ${script##*/}"
  /usr/bin/grep -Fq "trap 'exit 130' INT" "$script" || fail "INT status trap missing in ${script##*/}"
  /usr/bin/grep -Fq "trap 'exit 143' TERM" "$script" || fail "TERM status trap missing in ${script##*/}"
  if /usr/bin/grep -Eq 'trap cleanup .*HUP|trap cleanup .*INT|trap cleanup .*TERM' "$script"; then
    fail "signal directly invokes cleanup in ${script##*/}"
  fi
done

/usr/bin/grep -Fq 'EVIDENCE="$CANDIDATE/signature-verification.json"' "$ROOT/Scripts/release/sign-candidate.sh" ||
  fail 'sign-candidate does not use the shared signature-verification evidence name'
/usr/bin/grep -Fq '"machOCount"' "$ROOT/Scripts/inspect-dmg.sh" ||
  fail 'shared inspector does not expose the expected evidence schema'
/usr/bin/grep -Fq -- '--mode signed' "$SOURCE_CREATE" ||
  fail 'signed DMG creator does not use the adjacent signed inspection interface'

/usr/bin/printf 'signature verification tests passed\n'
