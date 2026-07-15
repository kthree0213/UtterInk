#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SOURCE_INSPECTOR="$ROOT/Scripts/inspect-dmg.sh"

fail() {
  printf 'inspect DMG tests failed: %s\n' "$1" >&2
  exit 1
}

[[ -x "$SOURCE_INSPECTOR" ]] || fail 'Scripts/inspect-dmg.sh is not executable'
[[ "$(/bin/cat "$ROOT/Config/dmg-allowed-content.txt")" == $'Applications -> /Applications\nUtterInk.app directory' ]] || fail 'allowed manifest drifted'

TEMP="$(/usr/bin/mktemp -d /private/tmp/utterink-inspect-dmg-tests.XXXXXX)"
cleanup() {
  /bin/rm -rf "$TEMP"
}
trap cleanup EXIT HUP INT TERM
/bin/chmod 0700 "$TEMP"

FIXTURE_ROOT="$TEMP/FixtureRepository"
/bin/mkdir -p \
  "$FIXTURE_ROOT/Scripts/release" \
  "$FIXTURE_ROOT/Config" \
  "$FIXTURE_ROOT/App/Supporting" \
  "$FIXTURE_ROOT/Tests/ATSPolicyProbe"
/bin/chmod 0700 "$FIXTURE_ROOT"
/bin/cp "$SOURCE_INSPECTOR" "$FIXTURE_ROOT/Scripts/inspect-dmg.sh"
/bin/cp \
  "$ROOT/Scripts/release/read-metadata.py" \
  "$ROOT/Scripts/release/verify-info-policy.py" \
  "$FIXTURE_ROOT/Scripts/release/"
/bin/cp \
  "$ROOT/Config/Base.xcconfig" \
  "$ROOT/Config/Debug.xcconfig" \
  "$ROOT/Config/Release.xcconfig" \
  "$ROOT/Config/dmg-allowed-content.txt" \
  "$ROOT/Config/release-info-policy.json" \
  "$ROOT/Config/release-metadata.json" \
  "$FIXTURE_ROOT/Config/"
/bin/cp "$ROOT/App/Supporting/Info.plist" "$FIXTURE_ROOT/App/Supporting/Info.plist"
/bin/cp "$ROOT/Tests/ATSPolicyProbe/Info.plist" "$FIXTURE_ROOT/Tests/ATSPolicyProbe/Info.plist"
/usr/bin/printf '%s\n' 'utterink-dmg-inspect-test-repository-v1' > "$FIXTURE_ROOT/.utterink-dmg-inspect-test-repository"
/bin/chmod 0600 "$FIXTURE_ROOT/.utterink-dmg-inspect-test-repository"
/usr/bin/git init -q "$FIXTURE_ROOT"
INSPECTOR="$FIXTURE_ROOT/Scripts/inspect-dmg.sh"
[[ -x "$INSPECTOR" ]] || fail 'fixture inspector is not executable'

TOOLS="$FIXTURE_ROOT/FixtureTools"
/bin/mkdir -m 0700 "$TOOLS"
/usr/bin/printf '%s\n' 'utterink-dmg-inspect-test-tools-v1' > "$TOOLS/.utterink-dmg-inspect-test-tools"

/bin/cat > "$TOOLS/hdiutil" <<'FAKE_HDIUTIL'
#!/bin/bash
set -euo pipefail
tool_root="$(cd "$(dirname "$0")" && pwd -P)"
/usr/bin/printf '%s\n' "$*" >> "$tool_root/commands.log"
case "${1:-}" in
  attach)
    readonly=0
    nobrowse=0
    noautoopen=0
    plist=0
    owners=0
    mountroot=''
    dmg=''
    previous=''
    for argument in "$@"; do
      if [[ "$previous" == -mountroot ]]; then
        mountroot="$argument"
      elif [[ "$previous" == -owners && "$argument" == on ]]; then
        owners=1
      fi
      [[ "$argument" == -readonly ]] && readonly=1
      [[ "$argument" == -nobrowse ]] && nobrowse=1
      [[ "$argument" == -noautoopen ]] && noautoopen=1
      [[ "$argument" == -plist ]] && plist=1
      [[ "$argument" == *.dmg ]] && dmg="$argument"
      previous="$argument"
    done
    [[ "$readonly" -eq 1 && "$nobrowse" -eq 1 && "$noautoopen" -eq 1 && "$plist" -eq 1 && "$owners" -eq 1 ]] || exit 31
    [[ "$mountroot" == /private/tmp/utterink-dmg-inspection.*'/mount-root' && -f "$dmg" ]] || exit 31
    fixture_source="$(/usr/bin/sed -n 's/^FIXTURE_SOURCE://p' "$dmg" | /usr/bin/head -n 1)"
    fixture_swap="$(/usr/bin/sed -n 's/^FIXTURE_SWAP://p' "$dmg" | /usr/bin/head -n 1)"
    swap_saved=''
    restore_source() {
      if [[ -n "$swap_saved" && -e "$swap_saved" ]]; then
        /usr/bin/touch "$swap_saved"
        /bin/rm -f "$fixture_source"
        /bin/mv "$swap_saved" "$fixture_source"
      fi
    }
    trap restore_source EXIT HUP INT TERM
    if [[ -n "$fixture_source" || -n "$fixture_swap" ]]; then
      [[ -n "$fixture_source" && -n "$fixture_swap" && -f "$fixture_source" && -f "$fixture_swap" ]] || exit 31
      swap_saved="$fixture_source.swap-saved.$$"
      /bin/mv "$fixture_source" "$swap_saved"
      /bin/cp "$fixture_swap" "$fixture_source"
    fi
    fixture_mount="$(/usr/bin/sed -n 's/^FIXTURE_MOUNT://p' "$dmg" | /usr/bin/head -n 1)"
    [[ "$fixture_mount" == /private/tmp/* && -d "$fixture_mount" ]] || exit 31
    volume="$mountroot/UtterInk"
    /usr/bin/ditto "$fixture_mount" "$volume"
    multi=0
    if [[ -f "$fixture_mount/.fixture-multi-volume" ]]; then
      multi=1
      /bin/mkdir -m 0700 "$mountroot/Extra"
    fi
    restore_source
    swap_saved=''
    /usr/bin/python3 -I - "$volume" "$mountroot/Extra" "$multi" <<'PY'
import plistlib
import sys

entities = [
    {
        "content-hint": "GUID_partition_scheme",
        "dev-entry": "/dev/disk99",
        "potentially-mountable": False,
    },
    {
        "content-hint": "Apple_HFS",
        "dev-entry": "/dev/disk99s1",
        "mount-point": sys.argv[1],
        "potentially-mountable": True,
    },
]
if sys.argv[3] == "1":
    entities.append(
        {
            "content-hint": "Apple_HFS",
            "dev-entry": "/dev/disk99s2",
            "mount-point": sys.argv[2],
            "potentially-mountable": True,
        }
    )
plistlib.dump({"system-entities": entities}, sys.stdout.buffer, sort_keys=True)
PY
    ;;
  detach)
    [[ "$#" -ge 2 && "$2" == /dev/disk99 ]] || exit 32
    ;;
  *) exit 33 ;;
esac
FAKE_HDIUTIL

/bin/cat > "$TOOLS/file" <<'FAKE_FILE'
#!/bin/bash
set -euo pipefail
target="${!#}"
if /usr/bin/grep -q '^MACHO:' "$target" 2>/dev/null; then
  architecture="$(/usr/bin/awk -F: '/^MACHO:/ { print $2; exit }' "$target")"
  /usr/bin/printf 'Mach-O 64-bit executable %s\n' "$architecture"
else
  /usr/bin/printf 'data\n'
fi
FAKE_FILE

/bin/cat > "$TOOLS/lipo" <<'FAKE_LIPO'
#!/bin/bash
set -euo pipefail
[[ "${1:-}" == -archs && "$#" -eq 2 ]] || exit 41
/usr/bin/awk -F: '/^MACHO:/ { print $2; found=1; exit } END { if (!found) exit 42 }' "$2"
FAKE_LIPO

/bin/cat > "$TOOLS/codesign" <<'FAKE_CODESIGN'
#!/bin/bash
set -euo pipefail
target="${!#}"
payload="$target"
if [[ -d "$target" ]]; then
  payload="$target/Contents/MacOS/UtterInk"
fi
state="$(/usr/bin/awk -F: '/^SIGNATURE:/ { print $2; found=1; exit } END { if (!found) print "unsigned" }' "$payload" 2>/dev/null || /usr/bin/printf 'unsigned\n')"
display=0
for argument in "$@"; do
  [[ "$argument" == -d ]] && display=1
done
if [[ "$display" -eq 0 ]]; then
  [[ "$state" == developer || "$state" == adhoc ]] && exit 0
  /usr/bin/printf '%s: code object is not signed at all\n' "$target" >&2
  exit 1
fi
if [[ "$state" == unsigned ]]; then
  /usr/bin/printf '%s: code object is not signed at all\n' "$target" >&2
  exit 1
fi
identifier=fixture.component
case "$target" in
  *.dmg) identifier=fixture.dmg ;;
  */UtterInk.app|*/UtterInk.app/Contents/MacOS/UtterInk) identifier=dev.utterink.UtterInk ;;
esac
/usr/bin/printf 'Identifier=%s\n' "$identifier" >&2
if [[ "$state" == adhoc ]]; then
  /usr/bin/printf 'Signature=adhoc\nTeamIdentifier=not set\n' >&2
  exit 0
fi
/usr/bin/printf '%s\n' \
  'Authority=Developer ID Application: Fixture Author (ABCDE12345)' \
  'Authority=Developer ID Certification Authority' \
  'Authority=Apple Root CA' \
  'TeamIdentifier=ABCDE12345' \
  'Timestamp=Jul 15, 2026 at 12:00:00' \
  'Runtime Version=14.0.0' \
  'flags=0x10000(runtime)' >&2
FAKE_CODESIGN

/bin/chmod 0700 "$TOOLS/hdiutil" "$TOOLS/file" "$TOOLS/lipo" "$TOOLS/codesign"
: > "$TOOLS/commands.log"
/bin/chmod 0600 "$TOOLS/commands.log"

write_info_plist() {
  local path="$1"
  /usr/bin/python3 -I - "$path" <<'PY'
from pathlib import Path
import plistlib
import sys

value = {
    "CFBundleDevelopmentRegion": "en",
    "CFBundleDisplayName": "UtterInk",
    "CFBundleExecutable": "UtterInk",
    "CFBundleIdentifier": "dev.utterink.UtterInk",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": "UtterInk",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "0.1.0",
    "CFBundleVersion": "1",
    "LSApplicationCategoryType": "public.app-category.productivity",
    "LSMinimumSystemVersion": "14.0",
    "LSUIElement": True,
    "NSMicrophoneUsageDescription": "UtterInk uses the microphone to transcribe speech locally on this Mac.",
}
with Path(sys.argv[1]).open("wb") as handle:
    plistlib.dump(value, handle, sort_keys=True)
PY
}

make_fixture() {
  local label="$1"
  local signature="${2:-unsigned}"
  local architecture="${3:-arm64}"
  local filename_kind="${4:-unsigned}"
  local fixture="$TEMP/$label"
  local filename=UtterInk-0.1.0-arm64-UNSIGNED-DO-NOT-DISTRIBUTE.dmg
  [[ "$filename_kind" == signed ]] && filename=UtterInk-0.1.0-arm64.dmg
  local dmg="$fixture/$filename"
  local volume="$dmg.mount"
  /bin/mkdir -p "$volume/UtterInk.app/Contents/MacOS" "$volume/UtterInk.app/Contents/Resources"
  /usr/bin/printf '%s\n' 'utterink-dmg-inspect-fixture-v1' > "$fixture/.utterink-dmg-inspect-fixture"
  /usr/bin/printf 'FIXTURE_MOUNT:%s\nSIGNATURE:%s\n' "$volume" "$signature" > "$dmg"
  /bin/ln -s /Applications "$volume/Applications"
  write_info_plist "$volume/UtterInk.app/Contents/Info.plist"
  /usr/bin/printf 'MACHO:%s\nSIGNATURE:%s\n' "$architecture" "$signature" > "$volume/UtterInk.app/Contents/MacOS/UtterInk"
  /bin/chmod 0755 "$volume/UtterInk.app/Contents/MacOS/UtterInk"
  /usr/bin/printf 'UtterInk fixture resource\n' > "$volume/UtterInk.app/Contents/Resources/README.txt"
  /usr/bin/printf '%s\n' "$dmg"
}

change_plist() {
  local dmg="$1"
  local key="$2"
  local value="$3"
  /usr/bin/python3 -I - "$dmg.mount/UtterInk.app/Contents/Info.plist" "$key" "$value" <<'PY'
from pathlib import Path
import plistlib
import sys

path = Path(sys.argv[1])
with path.open("rb") as handle:
    value = plistlib.load(handle)
value[sys.argv[2]] = sys.argv[3]
with path.open("wb") as handle:
    plistlib.dump(value, handle, sort_keys=True)
PY
}

configure_swap_restore() {
  local source_dmg="$1"
  local replacement_dmg="$2"
  /usr/bin/printf 'FIXTURE_SOURCE:%s\nFIXTURE_SWAP:%s\n' \
    "$source_dmg" "$replacement_dmg" >> "$source_dmg"
}

set_fixture_xattr() {
  local path="$1"
  local name="$2"
  local value="$3"
  local output actual
  if ! output="$(/usr/bin/xattr -w "$name" "$value" "$path" 2>&1)"; then
    if [[ "$output" == *'Operation not supported'* || "$output" == *'not supported'* ]]; then
      return 77
    fi
    return 1
  fi
  [[ -z "$output" ]] || return 1
  if ! actual="$(/usr/bin/xattr -p "$name" "$path" 2>/dev/null)"; then
    return 1
  fi
  [[ "$actual" == "$value" ]] || return 1
}

set_fixture_symlink_xattr() {
  local path="$1"
  local name="$2"
  local value="$3"
  local output actual
  if ! output="$(/usr/bin/xattr -s -w "$name" "$value" "$path" 2>&1)"; then
    if [[ "$output" == *'Operation not supported'* || "$output" == *'not supported'* || "$output" == *'Operation not permitted'* ]]; then
      return 77
    fi
    return 1
  fi
  [[ -z "$output" ]] || return 1
  if ! actual="$(/usr/bin/xattr -s -p "$name" "$path" 2>/dev/null)"; then
    return 1
  fi
  [[ "$actual" == "$value" ]] || return 1
}

run_inspector() {
  local dmg="$1"
  local mode="$2"
  /usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    LC_ALL=C \
    UTTERINK_DMG_INSPECT_TEST_MODE=1 \
    UTTERINK_DMG_INSPECT_TEST_TOOL_ROOT="$TOOLS" \
    "$INSPECTOR" --dmg "$dmg" --mode "$mode"
}

assert_last_mount_cleaned() {
  local attach_line mountroot
  attach_line="$(/usr/bin/tail -n 2 "$TOOLS/commands.log" | /usr/bin/head -n 1)"
  mountroot="$(/usr/bin/python3 -I - "$attach_line" <<'PY'
import sys

arguments = sys.argv[1].split()
try:
    index = arguments.index("-mountroot")
    print(arguments[index + 1])
except (ValueError, IndexError):
    raise SystemExit(1)
PY
)" || fail 'fake attach log did not contain a mount root'
  [[ "$mountroot" == /private/tmp/utterink-dmg-inspection.*'/mount-root' ]] || fail 'inspection did not use a private mount root'
  [[ ! -e "${mountroot%/mount-root}" ]] || fail 'private mount workspace survived cleanup'
}

assert_last_attach_used_snapshot() {
  local source_dmg="$1"
  local attach_line
  attach_line="$(/usr/bin/tail -n 2 "$TOOLS/commands.log" | /usr/bin/head -n 1)"
  [[ "$attach_line" == *'/pinned/'"${source_dmg##*/}" ]] ||
    fail 'inspection did not attach its private pinned DMG snapshot'
  [[ "$attach_line" != *" $source_dmg" ]] ||
    fail 'inspection attached the caller-visible DMG path directly'
}

expect_success() {
  local dmg="$1"
  local mode="$2"
  local before after
  before="$(/usr/bin/wc -l < "$TOOLS/commands.log" | /usr/bin/tr -d ' ')"
  if ! run_inspector "$dmg" "$mode" > "$TEMP/stdout" 2> "$TEMP/stderr"; then
    fail "$mode fixture was rejected: $(/bin/cat "$TEMP/stderr")"
  fi
  [[ ! -s "$TEMP/stderr" ]] || fail 'successful inspection wrote to stderr'
  after="$(/usr/bin/wc -l < "$TOOLS/commands.log" | /usr/bin/tr -d ' ')"
  [[ "$after" -eq $((before + 2)) ]] || fail 'successful inspection did not attach and detach exactly once'
  /usr/bin/python3 -I - "$TEMP/stdout" "$mode" "$dmg" <<'PY' || fail 'success evidence was not sanitized deterministic JSON'
from pathlib import Path
import hashlib
import json
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
value = json.loads(text)
expected_signature = "unsigned" if sys.argv[2] == "unsigned" else "developer-id"
expected = {
    "architecture": "arm64",
    "buildNumber": "1",
    "bundleIdentifier": "dev.utterink.UtterInk",
    "dmgFilename": Path(sys.argv[3]).name,
    "dmgSHA256": hashlib.sha256(Path(sys.argv[3]).read_bytes()).hexdigest(),
    "machOCount": 1,
    "manifest": ["Applications -> /Applications", "UtterInk.app directory"],
    "minimumSystemVersion": "14.0",
    "mode": sys.argv[2],
    "product": "UtterInk",
    "signature": expected_signature,
    "status": "valid",
    "version": "0.1.0",
}
if value != expected or text != json.dumps(expected, sort_keys=True, separators=(",", ":")) + "\n":
    raise SystemExit(1)
for forbidden in ("/Users/", "/private/tmp/", "ABCDE12345", "Authority=", "Fixture Author"):
    if forbidden in text:
        raise SystemExit(1)
PY
  assert_last_mount_cleaned
}

expect_failure() {
  local dmg="$1"
  local mode="$2"
  local expected_category="${3:-}"
  local before after
  before="$(/usr/bin/wc -l < "$TOOLS/commands.log" | /usr/bin/tr -d ' ')"
  if run_inspector "$dmg" "$mode" > "$TEMP/stdout" 2> "$TEMP/stderr"; then
    fail "adversarial $mode fixture unexpectedly passed: ${dmg%/*}"
  fi
  [[ ! -s "$TEMP/stdout" ]] || fail 'failed inspection emitted evidence'
  /usr/bin/python3 -I - "$TEMP/stderr" "$TEMP" <<'PY' || fail 'failure diagnostic was not sanitized'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
if re.fullmatch(r"DMG inspection error: [a-z0-9-]+\n", text) is None:
    raise SystemExit(1)
if sys.argv[2] in text or "/Users/" in text or "ABCDE12345" in text:
    raise SystemExit(1)
PY
  if [[ -n "$expected_category" ]]; then
    [[ "$(/bin/cat "$TEMP/stderr")" == "DMG inspection error: $expected_category" ]] ||
      fail "expected $expected_category rejection"
  fi
  after="$(/usr/bin/wc -l < "$TOOLS/commands.log" | /usr/bin/tr -d ' ')"
  [[ "$after" -eq $((before + 2)) ]] || fail 'failure path did not attach and detach exactly once'
  assert_last_mount_cleaned
}

unsigned_dmg="$(make_fixture valid-unsigned unsigned arm64 unsigned)"
real_project_before="$(/usr/bin/wc -l < "$TOOLS/commands.log" | /usr/bin/tr -d ' ')"
if /usr/bin/env -i \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  LC_ALL=C \
  UTTERINK_DMG_INSPECT_TEST_MODE=1 \
  UTTERINK_DMG_INSPECT_TEST_TOOL_ROOT="$TOOLS" \
  "$SOURCE_INSPECTOR" --dmg "$unsigned_dmg" --mode unsigned \
  > "$TEMP/stdout" 2> "$TEMP/stderr"; then
  fail 'real repository inspector accepted test mode'
fi
[[ "$(/bin/cat "$TEMP/stderr")" == 'DMG inspection error: invalid-test-repository' && ! -s "$TEMP/stdout" ]] ||
  fail 'real repository test-mode rejection drifted'
real_project_after="$(/usr/bin/wc -l < "$TOOLS/commands.log" | /usr/bin/tr -d ' ')"
[[ "$real_project_after" -eq "$real_project_before" ]] || fail 'real repository test-mode rejection invoked fixture tools'
expect_success "$unsigned_dmg" unsigned
assert_last_attach_used_snapshot "$unsigned_dmg"

# The fake attach replaces and then restores the caller-visible path while it
# runs. A pathname-hash/pathname-attach implementation would accept the race;
# the inspector must attach its pinned snapshot and fail closed because the
# source fingerprint changed during inspection.
swap_restore_source="$(make_fixture swap-restore-source)"
swap_restore_replacement="$(make_fixture swap-restore-replacement)"
configure_swap_restore "$swap_restore_source" "$swap_restore_replacement"
expect_failure "$swap_restore_source" unsigned dmg-mutated-during-inspection
assert_last_attach_used_snapshot "$swap_restore_source"

signed_dmg="$(make_fixture valid-signed developer arm64 signed)"
expect_success "$signed_dmg" signed
expect_success "$signed_dmg" final

unexpected_signature="$(make_fixture unexpected-signature developer arm64)"
expect_failure "$unexpected_signature" unsigned

missing_signature="$(make_fixture missing-signature unsigned arm64 signed)"
expect_failure "$missing_signature" signed

adhoc_signature="$(make_fixture adhoc-signature adhoc arm64 signed)"
expect_failure "$adhoc_signature" signed

ds_store="$(make_fixture ds-store)"
/usr/bin/printf 'Finder metadata\n' > "$ds_store.mount/.DS_Store"
expect_failure "$ds_store" unsigned

source_file="$(make_fixture source-file)"
/usr/bin/printf 'print("source")\n' > "$source_file.mount/UtterInk.app/Contents/Resources/leak.swift"
expect_failure "$source_file" unsigned

log_file="$(make_fixture log-file)"
/usr/bin/printf 'debug log\n' > "$log_file.mount/UtterInk.app/Contents/Resources/session.log"
expect_failure "$log_file" unsigned

credential="$(make_fixture credential)"
/usr/bin/printf 'OPENAI_API_KEY=fixture-secret\n' > "$credential.mount/UtterInk.app/Contents/Resources/token.txt"
expect_failure "$credential" unsigned

credential_xattr="$(make_fixture credential-xattr)"
if set_fixture_xattr \
  "$credential_xattr.mount/UtterInk.app/Contents/Resources/README.txt" \
  com.utterink.fixture-credential \
  'OPENAI_API_KEY=fixture-secret'; then
  expect_failure "$credential_xattr" unsigned forbidden-content
else
  xattr_status=$?
  [[ "$xattr_status" -eq 77 ]] || fail 'credential xattr fixture creation failed unexpectedly'
  /usr/bin/printf '%s\n' 'inspect DMG tests: SKIP credential xattr fixture (test filesystem does not support xattrs)' >&2
fi

volume_root_xattr="$(make_fixture volume-root-xattr)"
if set_fixture_xattr \
  "$volume_root_xattr.mount" \
  com.utterink.fixture-volume-metadata \
  'hidden fixture metadata'; then
  expect_failure "$volume_root_xattr" unsigned forbidden-content
else
  xattr_status=$?
  [[ "$xattr_status" -eq 77 ]] || fail 'volume-root xattr fixture creation failed unexpectedly'
  /usr/bin/printf '%s\n' 'inspect DMG tests: SKIP volume-root xattr fixture (test filesystem does not support xattrs)' >&2
fi

applications_xattr="$(make_fixture applications-xattr)"
if set_fixture_symlink_xattr \
  "$applications_xattr.mount/Applications" \
  com.utterink.fixture-link-metadata \
  'hidden fixture metadata'; then
  expect_failure "$applications_xattr" unsigned forbidden-content
else
  xattr_status=$?
  [[ "$xattr_status" -eq 77 ]] || fail 'Applications symlink xattr fixture creation failed unexpectedly'
  /usr/bin/printf '%s\n' 'inspect DMG tests: SKIP Applications symlink xattr fixture (test filesystem does not support symlink xattrs)' >&2
fi

large_disguised_credential="$(make_fixture large-disguised-credential)"
/usr/bin/python3 -I - "$large_disguised_credential.mount/UtterInk.app/Contents/Resources/README.txt" <<'PY'
from pathlib import Path
import sys

private_key_marker = b"-----BEGIN " + b"PRIVATE KEY-----\n"
Path(sys.argv[1]).write_bytes(b"x" * (1024 * 1024 + 17) + private_key_marker)
PY
expect_failure "$large_disguised_credential" unsigned

extra_alias="$(make_fixture extra-alias)"
/bin/ln -s /private/tmp "$extra_alias.mount/Diagnostics"
expect_failure "$extra_alias" unsigned

multi_volume="$(make_fixture multi-volume)"
/usr/bin/printf 'second mounted entity\n' > "$multi_volume.mount/.fixture-multi-volume"
expect_failure "$multi_volume" unsigned

hidden_entry="$(make_fixture hidden-entry)"
/usr/bin/printf 'hidden\n' > "$hidden_entry.mount/UtterInk.app/Contents/Resources/.unexpected"
expect_failure "$hidden_entry" unsigned

wrong_app="$(make_fixture wrong-app)"
change_plist "$wrong_app" CFBundleName WrongProduct
expect_failure "$wrong_app" unsigned

wrong_bundle="$(make_fixture wrong-bundle)"
change_plist "$wrong_bundle" CFBundleIdentifier example.invalid.UtterInk
expect_failure "$wrong_bundle" unsigned

wrong_version="$(make_fixture wrong-version)"
change_plist "$wrong_version" CFBundleShortVersionString 9.9.9
expect_failure "$wrong_version" unsigned

wrong_build="$(make_fixture wrong-build)"
change_plist "$wrong_build" CFBundleVersion 999
expect_failure "$wrong_build" unsigned

wrong_minimum="$(make_fixture wrong-minimum)"
change_plist "$wrong_minimum" LSMinimumSystemVersion 15.0
expect_failure "$wrong_minimum" unsigned

wrong_architecture="$(make_fixture wrong-architecture unsigned x86_64)"
expect_failure "$wrong_architecture" unsigned

nested_architecture="$(make_fixture nested-architecture)"
/usr/bin/printf 'MACHO:x86_64\nSIGNATURE:unsigned\n' > "$nested_architecture.mount/UtterInk.app/Contents/Resources/Helper"
/bin/chmod 0755 "$nested_architecture.mount/UtterInk.app/Contents/Resources/Helper"
expect_failure "$nested_architecture" unsigned

non_executable_main="$(make_fixture non-executable-main)"
/bin/chmod 0644 "$non_executable_main.mount/UtterInk.app/Contents/MacOS/UtterInk"
expect_failure "$non_executable_main" unsigned bundle-layout-mismatch

quarantine_helper="$(make_fixture quarantine-helper)"
/usr/bin/printf '#!/bin/sh\n/usr/bin/xattr -dr com.apple.quarantine "$1"\n' > "$quarantine_helper.mount/UtterInk.app/Contents/Resources/CleanupTool"
/bin/chmod 0755 "$quarantine_helper.mount/UtterInk.app/Contents/Resources/CleanupTool"
expect_failure "$quarantine_helper" unsigned

quarantine_xattr="$(make_fixture quarantine-xattr)"
if set_fixture_xattr \
  "$quarantine_xattr.mount/UtterInk.app/Contents/Resources/README.txt" \
  com.apple.quarantine \
  '0081;fixture;Codex;fixture-origin'; then
  expect_failure "$quarantine_xattr" unsigned forbidden-content
else
  xattr_status=$?
  [[ "$xattr_status" -eq 77 ]] || fail 'quarantine xattr fixture creation failed unexpectedly'
  /usr/bin/printf '%s\n' 'inspect DMG tests: SKIP quarantine xattr fixture (test filesystem does not support xattrs)' >&2
fi

absolute_symlink="$(make_fixture absolute-symlink)"
/bin/ln -s /private/tmp "$absolute_symlink.mount/UtterInk.app/Contents/Resources/MutableTarget"
expect_failure "$absolute_symlink" unsigned

wrong_applications="$(make_fixture wrong-applications)"
/bin/rm "$wrong_applications.mount/Applications"
/bin/ln -s /private/tmp "$wrong_applications.mount/Applications"
expect_failure "$wrong_applications" unsigned

if /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
  UTTERINK_DMG_INSPECT_TEST_MODE=1 UTTERINK_DMG_INSPECT_TEST_TOOL_ROOT="$TOOLS" \
  "$INSPECTOR" --dmg "$unsigned_dmg" --mode unknown > "$TEMP/stdout" 2> "$TEMP/stderr"; then
  fail 'unknown mode unexpectedly passed'
fi
[[ "$(/bin/cat "$TEMP/stderr")" == 'DMG inspection error: invalid-arguments' && ! -s "$TEMP/stdout" ]] || fail 'invalid argument diagnostic drifted'

missing_marker="$(make_fixture missing-marker)"
/bin/rm "${missing_marker%/*}/.utterink-dmg-inspect-fixture"
if run_inspector "$missing_marker" unsigned > "$TEMP/stdout" 2> "$TEMP/stderr"; then
  fail 'test fixture without marker unexpectedly passed'
fi
[[ "$(/bin/cat "$TEMP/stderr")" == 'DMG inspection error: unsafe-dmg' && ! -s "$TEMP/stdout" ]] || fail 'missing marker was not rejected safely'

/usr/bin/printf 'inspect DMG tests passed\n'
