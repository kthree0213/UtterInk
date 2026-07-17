#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
PACKAGER="$ROOT/Scripts/package-unsigned-smoke.sh"
CLEANER="$ROOT/Scripts/clean-distribution-output.sh"
CREATE_DMG="$ROOT/Scripts/create-dmg.sh"

fail() {
  printf 'unsigned packaging tests failed: %s\n' "$1" >&2
  exit 1
}

[[ -x "$PACKAGER" ]] || fail 'Scripts/package-unsigned-smoke.sh is missing or not executable'
[[ -x "$CLEANER" ]] || fail 'Scripts/clean-distribution-output.sh is missing or not executable'
[[ -x "$CREATE_DMG" ]] || fail 'Scripts/create-dmg.sh is missing or not executable'
for signal_guard in \
  "trap 'handle_signal 129' HUP" \
  "trap 'handle_signal 130' INT" \
  "trap 'handle_signal 143' TERM"; do
  /usr/bin/grep -Fq "$signal_guard" "$CREATE_DMG" ||
    fail "create-dmg signal exit guard is missing: $signal_guard"
done
/usr/bin/grep -Fq 'trap cleanup EXIT' "$CREATE_DMG" ||
  fail 'create-dmg signal handlers do not route cleanup through EXIT'
for publisher in "$CREATE_DMG" "$PACKAGER"; do
  if /usr/bin/grep -Fq '/bin/rm -rf -- "$WORK"' "$publisher"; then
    fail "$(/usr/bin/basename "$publisher") still performs string-based recursive WORK cleanup"
  fi
  /usr/bin/grep -Fq 'def remove_contents(descriptor: int, root_device: int)' "$publisher" ||
    fail "$(/usr/bin/basename "$publisher") does not use descriptor-rooted WORK cleanup"
  /usr/bin/grep -Fq 'def safe_generated_directory(metadata: os.stat_result, root_device: int)' "$publisher" ||
    fail "$(/usr/bin/basename "$publisher") does not distinguish generated cleanup descendants"
  /usr/bin/grep -Fq 'def safe_private_directory(metadata: os.stat_result, root_device: int)' "$publisher" ||
    fail "$(/usr/bin/basename "$publisher") does not keep the WORK boundary private"
  /usr/bin/grep -Fq 'before.st_dev != root_device or before.st_uid != os.geteuid()' "$publisher" ||
    fail "$(/usr/bin/basename "$publisher") does not validate every cleanup entry"
  /usr/bin/grep -Fq 'safe_remove_work "$WORK" "$WORK_DEVICE" "$WORK_INODE" || fail work-cleanup-failed' "$publisher" ||
    fail "$(/usr/bin/basename "$publisher") does not require WORK cleanup before success evidence"
  /usr/bin/grep -Fq 'and metadata.st_dev == root_device' "$publisher" ||
    fail "$(/usr/bin/basename "$publisher") does not bind traversed directories to the repository device"
  /usr/bin/grep -Fq 'st_dev != root_device' "$publisher" ||
    fail "$(/usr/bin/basename "$publisher") does not bind the source file to the repository device"
done

TMP="$(/usr/bin/mktemp -d /private/tmp/utterink-package-tests.XXXXXX)"
TMP="$(cd "$TMP" && pwd -P)"
trap '/bin/rm -rf "$TMP"' EXIT
BASE="$TMP/base"
ORDINARY_LOG="$TMP/ordinary-path.log"
BASH_ENV_MARKER="$TMP/bash-env-loaded"
BASH_ENV_CANARY="$TMP/hostile-bash-env"
printf 'printf loaded > %q\n' "$BASH_ENV_MARKER" > "$BASH_ENV_CANARY"

set_fixture_hex_xattr() {
  local path="$1"
  local name="$2"
  local value="$3"
  local output actual
  if ! output="$(/usr/bin/xattr -wx "$name" "$value" "$path" 2>&1)"; then
    if [[ "$output" == *'Operation not supported'* || "$output" == *'not supported'* || "$output" == *'Operation not permitted'* ]]; then
      return 77
    fi
    return 1
  fi
  [[ -z "$output" ]] || return 1
  if ! actual="$(/usr/bin/xattr -px "$name" "$path" 2>/dev/null | /usr/bin/tr -d '[:space:]' | /usr/bin/tr '[:upper:]' '[:lower:]')"; then
    return 1
  fi
  if [[ "$actual" != "$value" ]]; then
    [[ "$name" != com.apple.provenance ]] || return 77
    return 1
  fi
}

set_fixture_canonical_provenance() {
  local path="$1"
  local output actual
  if ! output="$(/usr/bin/xattr -wx com.apple.provenance 0102001122334455667788 "$path" 2>&1)"; then
    if [[ "$output" == *'Operation not supported'* || "$output" == *'not supported'* || "$output" == *'Operation not permitted'* ]]; then
      return 77
    fi
    return 1
  fi
  [[ -z "$output" ]] || return 1
  if ! actual="$(/usr/bin/xattr -px com.apple.provenance "$path" 2>/dev/null | /usr/bin/tr -d '[:space:]' | /usr/bin/tr '[:upper:]' '[:lower:]')"; then
    return 1
  fi
  [[ "$actual" =~ ^010200[0-9a-f]{16}$ ]]
}

PROVENANCE_XATTR_SUPPORTED=1
PROVENANCE_WRONG_PREFIX_SUPPORTED=1
PROVENANCE_WRONG_LENGTH_SUPPORTED=1
PROVENANCE_PROBE="$TMP/provenance-probe"
/usr/bin/printf '%s\n' 'provenance capability probe' > "$PROVENANCE_PROBE"
if set_fixture_canonical_provenance "$PROVENANCE_PROBE"; then
  :
else
  xattr_status=$?
  if [[ "$xattr_status" -eq 77 ]]; then
    PROVENANCE_XATTR_SUPPORTED=0
  else
    fail 'custom provenance xattr capability probe failed unexpectedly'
  fi
fi
if [[ "$PROVENANCE_XATTR_SUPPORTED" -eq 1 ]]; then
  if set_fixture_hex_xattr "$PROVENANCE_PROBE" com.apple.provenance 0102011122334455667788; then
    :
  else
    xattr_status=$?
    [[ "$xattr_status" -eq 77 ]] || fail 'wrong-prefix provenance capability probe failed unexpectedly'
    PROVENANCE_WRONG_PREFIX_SUPPORTED=0
  fi
  if set_fixture_hex_xattr "$PROVENANCE_PROBE" com.apple.provenance 01020011223344556677; then
    :
  else
    xattr_status=$?
    [[ "$xattr_status" -eq 77 ]] || fail 'wrong-length provenance capability probe failed unexpectedly'
    PROVENANCE_WRONG_LENGTH_SUPPORTED=0
  fi
else
  PROVENANCE_WRONG_PREFIX_SUPPORTED=0
  PROVENANCE_WRONG_LENGTH_SUPPORTED=0
fi
/bin/mkdir -p \
  "$BASE/Config" \
  "$BASE/FixtureTools" \
  "$BASE/OrdinaryPath" \
  "$BASE/Scripts/release" \
  "$BASE/Tests/Scripts"
/usr/bin/printf 'committed\n' > "$BASE/Config/source-sentinel"

/bin/cp "$PACKAGER" "$BASE/Scripts/package-unsigned-smoke.sh"
/bin/cp "$CLEANER" "$BASE/Scripts/clean-distribution-output.sh"
/bin/cp "$CREATE_DMG" "$BASE/Scripts/create-dmg.sh"
/bin/chmod 0755 \
  "$BASE/Scripts/package-unsigned-smoke.sh" \
  "$BASE/Scripts/clean-distribution-output.sh" \
  "$BASE/Scripts/create-dmg.sh"

printf '%s\n' \
  '/Tools/bin/' \
  '/.release-work/' \
  '/dist/' \
  '/build/' \
  '/.fixture-*' \
  '*.xcarchive' \
  '*.dmg' > "$BASE/.gitignore"
printf 'utterink-offline-package-fixture-v1\n' > "$BASE/FixtureTools/.utterink-package-test-fixture"
printf 'utterink-offline-dmg-fixture-v1\n' > "$BASE/FixtureTools/.utterink-dmg-test-fixture"

cat > "$BASE/FixtureTools/repository-xcodegen-source" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'repository-xcodegen:%s' "$0"
  for argument in "$@"; do printf '\t%s' "$argument"; done
  printf '\n'
} >> "${UTTERINK_FIXTURE_LOG:?}"
[[ "${1-}" == '--version' ]] || exit 2
xcodegen_directory="$(cd "$(/usr/bin/dirname "$0")" && /bin/pwd -P)"
[[ -f "$xcodegen_directory/XcodeGen_XcodeGenKit.bundle/SettingPresets/base.yml" ]]
[[ -f "$xcodegen_directory/XcodeGen_XcodeGenKit.bundle/SettingPresets/Platforms/macOS.yml" ]]
printf 'Version: 2.45.4\n'
EOF

cat > "$BASE/FixtureTools/xcodebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'boundary:xcodebuild-pwd\t%s\n' "$PWD" >> "${UTTERINK_FIXTURE_LOG:?}"
printf 'boundary:xcodebuild-home\t%s\n' "${HOME:-}" >> "${UTTERINK_FIXTURE_LOG:?}"
printf 'boundary:source-sentinel\t%s\n' "$(/bin/cat Config/source-sentinel)" >> "${UTTERINK_FIXTURE_LOG:?}"
{
  printf 'xcodebuild'
  for argument in "$@"; do printf '\t%s' "$argument"; done
  printf '\n'
} >> "${UTTERINK_FIXTURE_LOG:?}"
[[ "${1-}" == archive ]] || exit 2
archive=''
previous=''
for argument in "$@"; do
  if [[ "$previous" == '-archivePath' ]]; then archive="$argument"; fi
  previous="$argument"
done
[[ -n "$archive" ]]
app="$archive/Products/Applications/UtterInk.app"
/bin/mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
# SwiftPM creates these private-work descendants as mode 0777 on current
# Xcode releases. The enclosing packaging WORK remains mode 0700, so cleanup
# must validate ownership/device/identity without rejecting the generated mode.
/bin/mkdir -p "$PWD/.release-work/SourcePackages/checkouts/fixture/.swiftpm/xcode"
/bin/chmod 0777 \
  "$PWD/.release-work/SourcePackages/checkouts/fixture/.swiftpm" \
  "$PWD/.release-work/SourcePackages/checkouts/fixture/.swiftpm/xcode"
printf 'fixture Mach-O bytes\n' > "$app/Contents/MacOS/UtterInk"
/bin/chmod 0755 "$app/Contents/MacOS/UtterInk"
if [[ -f "${UTTERINK_FIXTURE_LOG:?}.source-mode-0644" ]]; then
  /bin/chmod 0644 "$app/Contents/MacOS/UtterInk"
fi
printf '%s\n' '<?xml version="1.0"?><plist version="1.0"><dict/></plist>' > "$app/Contents/Info.plist"
# Recent macOS versions may attach system provenance xattrs to newly-created
# fixture files. The clean baseline intentionally removes them; the adversarial
# case below then adds one deterministic private attribute.
/usr/bin/xattr -cr "$app"
if [[ -f "${UTTERINK_FIXTURE_LOG:?}.source-xattr" ]]; then
  /usr/bin/xattr -w com.utterink.fixture private-metadata "$app/Contents/MacOS/UtterInk"
fi
if [[ -f "$UTTERINK_FIXTURE_LOG.source-provenance-canonical" ]]; then
  /usr/bin/xattr -wx com.apple.provenance 0102001122334455667788 "$app/Contents/MacOS/UtterInk"
fi
if [[ -f "$UTTERINK_FIXTURE_LOG.source-provenance-wrong-prefix" ]]; then
  /usr/bin/xattr -wx com.apple.provenance 0102011122334455667788 "$app/Contents/MacOS/UtterInk"
fi
if [[ -f "$UTTERINK_FIXTURE_LOG.source-provenance-wrong-length" ]]; then
  /usr/bin/xattr -wx com.apple.provenance 01020011223344556677 "$app/Contents/MacOS/UtterInk"
fi
if [[ -f "$UTTERINK_FIXTURE_LOG.source-provenance-extra-xattr" ]]; then
  /usr/bin/xattr -wx com.apple.provenance 0102001122334455667788 "$app/Contents/MacOS/UtterInk"
  /usr/bin/xattr -w com.utterink.fixture extra-metadata "$app/Contents/MacOS/UtterInk"
fi
EOF

cat > "$BASE/FixtureTools/file" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'file\t%s\n' "$*" >> "${UTTERINK_FIXTURE_LOG:?}"
case "${*: -1}" in
  */Contents/MacOS/UtterInk) printf 'Mach-O 64-bit executable arm64\n' ;;
  *) printf 'ASCII text\n' ;;
esac
EOF

cat > "$BASE/FixtureTools/lipo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'lipo\t%s\n' "$*" >> "${UTTERINK_FIXTURE_LOG:?}"
[[ "${1-}" == '-archs' ]]
if [[ -f "${UTTERINK_FIXTURE_LOG:?}.non-arm64" ]]; then
  printf 'x86_64\n'
  exit 0
fi
printf 'arm64\n'
EOF

cat > "$BASE/FixtureTools/otool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'otool\t%s\n' "$*" >> "${UTTERINK_FIXTURE_LOG:?}"
[[ "${1-}" == '-l' ]]
if [[ -f "${UTTERINK_FIXTURE_LOG:?}.code-signature" ]]; then
  printf '%s\n' \
    'Load command 1' \
    '      cmd LC_CODE_SIGNATURE' \
    '  cmdsize 16'
  exit 0
fi
printf '%s\n' \
  'Load command 0' \
  '      cmd LC_SEGMENT_64' \
  '  cmdsize 72'
EOF

cat > "$BASE/FixtureTools/ditto" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'boundary:ditto-script\t%s\n' "$0" >> "${UTTERINK_FIXTURE_LOG:?}"
printf 'boundary:ditto-pwd\t%s\n' "$PWD" >> "${UTTERINK_FIXTURE_LOG:?}"
printf 'ditto\t%s\n' "$*" >> "${UTTERINK_FIXTURE_LOG:?}"
source_path="${1:?}"
destination="${2:?}"
/bin/mkdir -p "$(/usr/bin/dirname "$destination")"
/bin/cp -Rp "$source_path" "$destination"
cleanup_canary="$(/usr/bin/dirname "$(/usr/bin/dirname "$destination")")/generated-writable-directory"
/bin/mkdir -m 0777 "$cleanup_canary"
if [[ -f "${UTTERINK_FIXTURE_LOG:?}.strip-mode" ]]; then
  /bin/chmod 0644 "$destination/Contents/MacOS/UtterInk"
fi
EOF

cat > "$BASE/FixtureTools/hdiutil" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'boundary:hdiutil-script\t%s\n' "$0" >> "${UTTERINK_FIXTURE_LOG:?}"
printf 'boundary:hdiutil-pwd\t%s\n' "$PWD" >> "${UTTERINK_FIXTURE_LOG:?}"
printf 'hdiutil\t%s\n' "$*" >> "${UTTERINK_FIXTURE_LOG:?}"
output="${*: -1}"
/bin/mkdir -p "$(/usr/bin/dirname "$output")"
printf 'fixture disk image\n' > "$output"
EOF

/bin/chmod 0755 "$BASE/FixtureTools/"{repository-xcodegen-source,xcodebuild,file,lipo,otool,ditto,hdiutil}

/bin/mkdir -p \
  "$BASE/FixtureTools/XcodeGen_XcodeGenKit.bundle/SettingPresets/Configs" \
  "$BASE/FixtureTools/XcodeGen_XcodeGenKit.bundle/SettingPresets/Platforms"
printf 'SWIFT_ACTIVE_COMPILATION_CONDITIONS: DEBUG\n' > \
  "$BASE/FixtureTools/XcodeGen_XcodeGenKit.bundle/SettingPresets/Configs/debug.yml"
printf 'SUPPORTED_PLATFORMS: macosx\n' > \
  "$BASE/FixtureTools/XcodeGen_XcodeGenKit.bundle/SettingPresets/Platforms/macOS.yml"
printf 'SDKROOT: auto\n' > \
  "$BASE/FixtureTools/XcodeGen_XcodeGenKit.bundle/SettingPresets/base.yml"

cat > "$BASE/Scripts/release/verify-candidate.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
commit=''
output=''
expected_origin=''
expected_count=0
for argument in "$@"; do
  printf 'verify-arg:%s\n' "$argument" >> "${UTTERINK_FIXTURE_LOG:?}"
done
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --commit) commit="${2:?}"; shift 2 ;;
    --output) output="${2:?}"; shift 2 ;;
    --expected-origin)
      expected_count=$((expected_count + 1))
      expected_origin="${2:?}"
      shift 2
      ;;
    *) exit 64 ;;
  esac
done
[[ "$expected_count" -le 1 && "$commit" == "$(/usr/bin/git rev-parse HEAD)" ]]
[[ -z "$(/usr/bin/git status --porcelain=v1 --untracked-files=all)" ]]
case "$output" in "$PWD"/.release-work/*) ;; *) exit 29 ;; esac
origin="$(/usr/bin/git remote get-url origin 2>/dev/null || :)"
if [[ -n "$origin" ]]; then
  [[ -n "$expected_origin" && "$expected_origin" == "$origin" ]] || exit 25
else
  [[ -z "$expected_origin" ]] || exit 25
fi
/bin/mkdir -p "$output"
cat > "$output/candidate.json" <<JSON
{"product":"UtterInk","release":{"architecture":"arm64","marketingVersion":"0.1.0"},"source":{"commit":"$commit"}}
JSON
if [[ -f "${UTTERINK_FIXTURE_LOG:?}.mutate-root" ]]; then
  printf 'mutated-after-candidate\n' > Config/source-sentinel
fi
EOF

cat > "$BASE/Scripts/release/read-metadata.py" <<'EOF'
#!/usr/bin/env python3
from __future__ import annotations

import json
import sys

if sys.argv[1:] != ["--json"]:
    raise SystemExit(2)
print(json.dumps({
    "product": "UtterInk",
    "marketingVersion": "0.1.0",
    "buildNumber": "1",
    "bundleIdentifier": "dev.utterink.UtterInk",
    "deploymentTarget": "14.0",
    "architecture": "arm64",
    "configuration": "Release",
    "dmgFilename": "UtterInk-0.1.0-arm64.dmg",
    "releaseTag": "v0.1.0",
}, sort_keys=True, separators=(",", ":")))
EOF
/bin/chmod 0755 "$BASE/Scripts/release/read-metadata.py"

cat > "$BASE/Scripts/inspect-dmg.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -eq 4 && "$1" == '--dmg' && -f "$2" && "$3" == '--mode' && "$4" == unsigned ]]
printf 'boundary:inspect-script\t%s\n' "$0" >> "${UTTERINK_FIXTURE_LOG:?}"
printf 'boundary:inspect-pwd\t%s\n' "$PWD" >> "${UTTERINK_FIXTURE_LOG:?}"
printf 'inspect-dmg\t--dmg\t%s\t--mode\t%s\n' "$2" "$4" >> "${UTTERINK_FIXTURE_LOG:?}"
digest="$(/usr/bin/shasum -a 256 "$2" | /usr/bin/awk 'NR == 1 { print $1 }')"
if [[ -f "${UTTERINK_FIXTURE_LOG:?}.inspection-hash-mismatch" ]]; then
  digest='0000000000000000000000000000000000000000000000000000000000000000'
fi
printf '{"dmgSHA256":"%s","mode":"unsigned","ok":true}\n' "$digest"
EOF
/bin/chmod 0755 \
  "$BASE/Scripts/release/verify-candidate.sh" \
  "$BASE/Scripts/inspect-dmg.sh"

for command_name in bash xcodegen xcodebuild file lipo otool codesign notarytool stapler spctl curl wget gh upload; do
  cat > "$BASE/OrdinaryPath/$command_name" <<EOF
#!/usr/bin/env bash
printf '$command_name\\n' >> '$ORDINARY_LOG'
exit 97
EOF
  /bin/chmod 0755 "$BASE/OrdinaryPath/$command_name"
done

XCODEGEN_HASH="$(/usr/bin/shasum -a 256 "$BASE/FixtureTools/repository-xcodegen-source" | /usr/bin/awk 'NR == 1 { print $1 }')"
SETTING_PRESETS_ROOT="$BASE/FixtureTools/XcodeGen_XcodeGenKit.bundle/SettingPresets"
/usr/bin/python3 -I - "$BASE/Config/ci-toolchain.json" "$XCODEGEN_HASH" "$SETTING_PRESETS_ROOT" <<'PY'
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import struct
import sys

path = Path(sys.argv[1])
binary_hash = sys.argv[2]
presets_root = Path(sys.argv[3])
items = sorted(
    (preset.relative_to(presets_root).as_posix().encode("utf-8"), preset.read_bytes())
    for preset in presets_root.rglob("*")
    if preset.is_file()
)
digest = hashlib.sha256()
for relative, content in items:
    digest.update(struct.pack(">Q", len(relative)))
    digest.update(relative)
    digest.update(struct.pack(">Q", len(content)))
    digest.update(content)
presets_hash = digest.hexdigest()
value = {
    "schemaVersion": 1,
    "runnerImage": {
        "label": "macos-26",
        "releaseTag": "macos-26-arm64/20260630.0213",
        "commit": "afadebc447d1a69fc726b50cd5aba055c0cfdf82",
        "imageVersion": "20260630.0213.1",
        "osVersion": "26.4",
        "osBuild": "25E246",
        "architecture": "arm64",
    },
    "xcode": {
        "version": "26.4.1",
        "build": "17E202",
        "developerDir": "/Applications/Xcode_26.4.app/Contents/Developer",
    },
    "sdk": {"version": "26.4", "build": "25E999"},
    "swift": {"version": "Apple Swift version 6.3.1 (swiftlang-6.3.1.1.2 clang-2100.0.123.102)"},
    "xcodegen": {
        "version": "2.45.4",
        "sourceCommit": "8d3d3476a69ae3e5d68e1adccc701c410c05eb36",
        "archiveURL": "https://github.com/yonaskolb/XcodeGen/releases/download/2.45.4/xcodegen.zip",
        "archiveSHA256": "090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef",
        "binarySHA256": binary_hash,
        "settingPresetsSHA256": presets_hash,
    },
    "sources": {
        "runnerRelease": "https://github.com/actions/runner-images/releases/tag/macos-26-arm64%2F20260630.0213",
        "runnerReadme": "https://github.com/actions/runner-images/blob/afadebc447d1a69fc726b50cd5aba055c0cfdf82/images/macos/macos-26-arm64-Readme.md",
        "xcodegenRelease": "https://github.com/yonaskolb/XcodeGen/releases/tag/2.45.4",
        "xcodegenCommit": "https://github.com/yonaskolb/XcodeGen/commit/8d3d3476a69ae3e5d68e1adccc701c410c05eb36",
    },
}
path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

/usr/bin/git -C "$BASE" init -q
/usr/bin/git -C "$BASE" config user.name 'UtterInk Packaging Test'
/usr/bin/git -C "$BASE" config user.email 'packaging-test@example.invalid'
/usr/bin/git -C "$BASE" add .
/usr/bin/git -C "$BASE" commit -q -m 'offline unsigned packaging fixture'

FIXTURE_LOG="$TMP/fixture.log"
STDOUT="$TMP/stdout"
STDERR="$TMP/stderr"
PACKAGE_STATUS=0

install_xcodegen() {
  local repository="$1"
  /bin/mkdir -p "$repository/Tools/bin"
  /bin/rm -rf "$repository/Tools/bin/XcodeGen_XcodeGenKit.bundle"
  /bin/cp "$repository/FixtureTools/repository-xcodegen-source" "$repository/Tools/bin/xcodegen"
  /bin/cp -R \
    "$repository/FixtureTools/XcodeGen_XcodeGenKit.bundle" \
    "$repository/Tools/bin/XcodeGen_XcodeGenKit.bundle"
  /bin/chmod 0755 "$repository/Tools/bin/xcodegen"
}

run_package() {
  local repository="$1"
  shift
  : > "$FIXTURE_LOG"
  /bin/rm -f "$ORDINARY_LOG" "$STDOUT" "$STDERR"
  set +e
  (
    cd "$repository"
    /usr/bin/env \
      PATH="$repository/OrdinaryPath:/usr/bin:/bin:/usr/sbin:/sbin" \
      BASH_ENV="$BASH_ENV_CANARY" \
      UTTERINK_ORDINARY_PATH_LOG="$ORDINARY_LOG" \
      UTTERINK_RELEASE_TEST_MODE=1 \
      UTTERINK_RELEASE_TEST_TOOL_ROOT="$repository/FixtureTools" \
      UTTERINK_FIXTURE_LOG="$FIXTURE_LOG" \
      ./Scripts/package-unsigned-smoke.sh "$@"
  ) > "$STDOUT" 2> "$STDERR"
  PACKAGE_STATUS=$?
  set -e
}

start_package_publish_race() {
  local repository="$1"
  shift
  : > "$FIXTURE_LOG"
  /bin/rm -f "$ORDINARY_LOG" "$STDOUT" "$STDERR"
  (
    cd "$repository"
    /usr/bin/env \
      PATH="$repository/OrdinaryPath:/usr/bin:/bin:/usr/sbin:/sbin" \
      BASH_ENV="$BASH_ENV_CANARY" \
      UTTERINK_ORDINARY_PATH_LOG="$ORDINARY_LOG" \
      UTTERINK_RELEASE_TEST_MODE=1 \
      UTTERINK_RELEASE_TEST_TOOL_ROOT="$repository/FixtureTools" \
      UTTERINK_FIXTURE_LOG="$FIXTURE_LOG" \
      UTTERINK_PACKAGE_TEST_PUBLISH_RACE=1 \
      ./Scripts/package-unsigned-smoke.sh "$@"
  ) > "$STDOUT" 2> "$STDERR" &
  RACE_PID=$!
}

start_create_publish_race() {
  local repository="$1"
  shift
  : > "$FIXTURE_LOG"
  /bin/rm -f "$ORDINARY_LOG" "$STDOUT" "$STDERR"
  (
    cd "$repository"
    /usr/bin/env \
      PATH="$repository/OrdinaryPath:/usr/bin:/bin:/usr/sbin:/sbin" \
      BASH_ENV="$BASH_ENV_CANARY" \
      UTTERINK_ORDINARY_PATH_LOG="$ORDINARY_LOG" \
      UTTERINK_RELEASE_TEST_MODE=1 \
      UTTERINK_RELEASE_TEST_TOOL_ROOT="$repository/FixtureTools" \
      UTTERINK_FIXTURE_LOG="$FIXTURE_LOG" \
      UTTERINK_DMG_TEST_PUBLISH_RACE=1 \
      ./Scripts/create-dmg.sh "$@"
  ) > "$STDOUT" 2> "$STDERR" &
  RACE_PID=$!
}

wait_for_race_ready() {
  local marker="$1"
  local attempt
  for attempt in {1..1500}; do
    if [[ -f "$marker" && ! -L "$marker" ]]; then
      return 0
    fi
    if ! /bin/kill -0 "$RACE_PID" 2>/dev/null; then
      set +e
      wait "$RACE_PID"
      PACKAGE_STATUS=$?
      set -e
      fail "publish-race process exited before synchronization (status $PACKAGE_STATUS): $(/bin/cat "$STDERR")"
    fi
    /bin/sleep 0.01
  done
  /bin/kill "$RACE_PID" 2>/dev/null || true
  set +e
  wait "$RACE_PID"
  set -e
  fail 'publish-race process did not reach the deterministic synchronization point'
}

finish_race_process() {
  set +e
  wait "$RACE_PID"
  PACKAGE_STATUS=$?
  set -e
}

run_production_preflight() {
  local repository="$1"
  shift
  : > "$FIXTURE_LOG"
  /bin/rm -f "$ORDINARY_LOG" "$STDOUT" "$STDERR"
  set +e
  (
    cd "$repository"
    /usr/bin/env \
      PATH="$repository/OrdinaryPath:/usr/bin:/bin:/usr/sbin:/sbin" \
      BASH_ENV="$BASH_ENV_CANARY" \
      UTTERINK_ORDINARY_PATH_LOG="$ORDINARY_LOG" \
      UTTERINK_FIXTURE_LOG="$FIXTURE_LOG" \
      ./Scripts/package-unsigned-smoke.sh "$@"
  ) > "$STDOUT" 2> "$STDERR"
  PACKAGE_STATUS=$?
  set -e
}

assert_xcodegen_resource_rejected() {
  local description="$1"
  local output_name="$2"
  run_package "$BASE" --commit "$BASE_COMMIT" --output "dist/$output_name"
  [[ "$PACKAGE_STATUS" -eq 24 ]] ||
    fail "$description returned $PACKAGE_STATUS, expected 24"
  /usr/bin/grep -Fq 'unsigned packaging error: repository-xcodegen-mismatch; run ./Scripts/bootstrap-xcodegen.sh' "$STDERR" ||
    fail "$description did not produce the stable resource mismatch diagnostic"
  [[ ! -e "$BASE/dist/$output_name" ]] || fail "$description emitted an artifact directory"
  if /usr/bin/grep -Ev '^verify-arg:' "$FIXTURE_LOG" | /usr/bin/grep -q . || [[ -e "$ORDINARY_LOG" ]]; then
    fail "$description executed XcodeGen, a build tool, or an ordinary-PATH tool: $(/bin/cat "$FIXTURE_LOG" 2>/dev/null || : )"
  fi
}

BASE_COMMIT="$(/usr/bin/git -C "$BASE" rev-parse HEAD)"
run_production_preflight "$BASE" --commit "$BASE_COMMIT" --output dist/missing-xcodegen
[[ "$PACKAGE_STATUS" -eq 24 ]] || fail "missing repository XcodeGen returned $PACKAGE_STATUS, expected 24"
/usr/bin/grep -Fq 'repository-xcodegen-missing; run ./Scripts/bootstrap-xcodegen.sh' "$STDERR" ||
  fail 'missing repository XcodeGen did not provide the bootstrap instruction'
[[ ! -e "$BASE/dist/missing-xcodegen" ]] || fail 'missing repository XcodeGen emitted an artifact directory'
[[ ! -s "$FIXTURE_LOG" && ! -e "$ORDINARY_LOG" ]] || fail 'missing repository XcodeGen invoked a build or ordinary-PATH tool'

MISSING_LOCK="$TMP/missing-lock"
/usr/bin/git clone -q --no-hardlinks "$BASE" "$MISSING_LOCK"
/usr/bin/git -C "$MISSING_LOCK" remote remove origin
/bin/rm "$MISSING_LOCK/Config/ci-toolchain.json"
run_production_preflight "$MISSING_LOCK" \
  --commit "$(/usr/bin/git -C "$MISSING_LOCK" rev-parse HEAD)" \
  --output dist/missing-lock
[[ "$PACKAGE_STATUS" -eq 24 ]] || fail "missing toolchain lock returned $PACKAGE_STATUS, expected 24"
[[ "$(/bin/cat "$STDERR")" == 'unsigned packaging error: toolchain-lock-missing' ]] || fail 'missing lock diagnostic was not stable'
[[ ! -e "$MISSING_LOCK/dist/missing-lock" && ! -s "$FIXTURE_LOG" && ! -e "$ORDINARY_LOG" ]] ||
  fail 'missing toolchain lock reached a build or emitted output'

/bin/mkdir -p "$BASE/Tools/bin"
/bin/cp "$BASE/FixtureTools/repository-xcodegen-source" "$BASE/Tools/bin/xcodegen"
/bin/chmod 0755 "$BASE/Tools/bin/xcodegen"
assert_xcodegen_resource_rejected 'missing XcodeGen companion resources' 'missing-xcodegen-resources'

install_xcodegen "$BASE"

/bin/rm "$BASE/Tools/bin/XcodeGen_XcodeGenKit.bundle/SettingPresets/Configs/debug.yml"
assert_xcodegen_resource_rejected 'missing XcodeGen setting preset' 'missing-xcodegen-resource'
install_xcodegen "$BASE"

printf 'tampered setting preset\n' > \
  "$BASE/Tools/bin/XcodeGen_XcodeGenKit.bundle/SettingPresets/Configs/debug.yml"
assert_xcodegen_resource_rejected 'tampered XcodeGen setting preset' 'tampered-xcodegen-resource'
install_xcodegen "$BASE"

printf 'unexpected setting preset\n' > \
  "$BASE/Tools/bin/XcodeGen_XcodeGenKit.bundle/SettingPresets/extra.yml"
assert_xcodegen_resource_rejected 'extra XcodeGen setting preset' 'extra-xcodegen-resource'
install_xcodegen "$BASE"

printf 'unexpected bundle resource\n' > \
  "$BASE/Tools/bin/XcodeGen_XcodeGenKit.bundle/extra.txt"
assert_xcodegen_resource_rejected 'extra XcodeGen bundle resource' 'extra-xcodegen-bundle-resource'
install_xcodegen "$BASE"

/bin/mkdir \
  "$BASE/Tools/bin/XcodeGen_XcodeGenKit.bundle/SettingPresets/empty-extra-directory"
assert_xcodegen_resource_rejected 'empty XcodeGen setting preset directory' 'empty-xcodegen-resource-directory'
install_xcodegen "$BASE"

/bin/rm "$BASE/Tools/bin/XcodeGen_XcodeGenKit.bundle/SettingPresets/Configs/debug.yml"
/bin/ln -s ../base.yml \
  "$BASE/Tools/bin/XcodeGen_XcodeGenKit.bundle/SettingPresets/Configs/debug.yml"
assert_xcodegen_resource_rejected 'symlinked XcodeGen setting preset' 'symlinked-xcodegen-resource'
install_xcodegen "$BASE"

/usr/bin/mkfifo \
  "$BASE/Tools/bin/XcodeGen_XcodeGenKit.bundle/SettingPresets/unexpected.fifo"
assert_xcodegen_resource_rejected 'special XcodeGen setting preset' 'special-xcodegen-resource'
install_xcodegen "$BASE"

run_package "$BASE" --commit "$BASE_COMMIT" --output dist/no-remote
[[ "$PACKAGE_STATUS" -eq 0 ]] || fail "no-remote fixture failed: $(/bin/cat "$STDERR")"
DMG="$BASE/dist/no-remote/UtterInk-0.1.0-arm64-UNSIGNED-DO-NOT-DISTRIBUTE.dmg"
[[ -f "$DMG" && ! -L "$DMG" ]] || fail 'success did not emit the fixed unsigned-only filename'
DMG_SHA="$(/usr/bin/shasum -a 256 "$DMG" | /usr/bin/awk 'NR == 1 { print $1 }')"
[[ "$(/bin/cat "$STDOUT")" == "{\"dmgSHA256\":\"$DMG_SHA\",\"mode\":\"unsigned\",\"ok\":true}" && ! -s "$STDERR" ]] ||
  fail 'success did not expose only sanitized inspection evidence'

printf 'mismatched inspection hash\n' > "$FIXTURE_LOG.inspection-hash-mismatch"
run_package "$BASE" --commit "$BASE_COMMIT" --output dist/inspection-hash-mismatch
[[ "$PACKAGE_STATUS" -eq 33 ]] ||
  fail "inspection hash mismatch returned $PACKAGE_STATUS, expected 33"
/usr/bin/grep -Fq 'unsigned packaging error: output-publish-failed' "$STDERR" ||
  fail 'inspection hash mismatch did not fail at the final publisher'
[[ ! -e "$BASE/dist/inspection-hash-mismatch" ]] ||
  fail 'inspection hash mismatch emitted a package output'
/bin/rm "$FIXTURE_LOG.inspection-hash-mismatch"
if /usr/bin/grep -Fq 'verify-arg:--expected-origin' "$FIXTURE_LOG"; then
  fail 'no-remote invocation synthesized an expected origin'
fi

for required_argument in \
  $'xcodebuild\tarchive' \
  $'\t-configuration\tRelease' \
  $'\t-destination\tgeneric/platform=macOS' \
  $'\tARCHS=arm64' \
  $'\tOTHER_LDFLAGS=-Wl,-no_adhoc_codesign' \
  $'\tCODE_SIGNING_ALLOWED=NO' \
  $'\tCODE_SIGNING_REQUIRED=NO' \
  $'\tCODE_SIGN_IDENTITY='; do
  /usr/bin/grep -Fq "$required_argument" "$FIXTURE_LOG" || fail "archive command omitted $required_argument"
done
/usr/bin/grep -Eq '^repository-xcodegen:/private/tmp/utterink-unsigned-preflight[.][^/]+/xcodegen[[:space:]]+--version$' "$FIXTURE_LOG" ||
  fail 'packaging did not execute a private hash-verified copy of repository XcodeGen'
/usr/bin/grep -Fq $'inspect-dmg\t--dmg' "$FIXTURE_LOG" || fail 'packaging did not call inspect-dmg.sh'
/usr/bin/grep -Fq $'ditto\t' "$FIXTURE_LOG" || fail 'offline DMG creation did not reach fake ditto'
/usr/bin/grep -Fq $'hdiutil\tcreate' "$FIXTURE_LOG" || fail 'offline DMG creation did not reach fake hdiutil'
[[ ! -e "$ORDINARY_LOG" ]] || fail "ordinary PATH was consulted: $(/bin/cat "$ORDINARY_LOG")"
[[ ! -e "$BASH_ENV_MARKER" ]] || fail 'packaging loaded a hostile BASH_ENV before sanitizing the launch environment'
if /usr/bin/grep -Eq '^(codesign|notarytool|stapler|spctl|curl|wget|gh|upload)([[:space:]]|$)' "$FIXTURE_LOG"; then
  fail 'unsigned packaging ran a signing, notarization, network, or upload command'
fi
if [[ -d "$BASE/.release-work" && -n "$(/usr/bin/find "$BASE/.release-work" -mindepth 1 -print -quit)" ]]; then
  fail 'success left candidate/archive working material behind'
fi

XCODEBUILD_PWD="$(/usr/bin/awk -F '\t' '$1 == "boundary:xcodebuild-pwd" { print $2; exit }' "$FIXTURE_LOG")"
XCODEBUILD_HOME="$(/usr/bin/awk -F '\t' '$1 == "boundary:xcodebuild-home" { print $2; exit }' "$FIXTURE_LOG")"
DITTO_SCRIPT="$(/usr/bin/awk -F '\t' '$1 == "boundary:ditto-script" { print $2; exit }' "$FIXTURE_LOG")"
DITTO_PWD="$(/usr/bin/awk -F '\t' '$1 == "boundary:ditto-pwd" { print $2; exit }' "$FIXTURE_LOG")"
HDIUTIL_SCRIPT="$(/usr/bin/awk -F '\t' '$1 == "boundary:hdiutil-script" { print $2; exit }' "$FIXTURE_LOG")"
HDIUTIL_PWD="$(/usr/bin/awk -F '\t' '$1 == "boundary:hdiutil-pwd" { print $2; exit }' "$FIXTURE_LOG")"
INSPECT_SCRIPT="$(/usr/bin/awk -F '\t' '$1 == "boundary:inspect-script" { print $2; exit }' "$FIXTURE_LOG")"
INSPECT_PWD="$(/usr/bin/awk -F '\t' '$1 == "boundary:inspect-pwd" { print $2; exit }' "$FIXTURE_LOG")"
SOURCE_SENTINEL="$(/usr/bin/awk -F '\t' '$1 == "boundary:source-sentinel" { print $2; exit }' "$FIXTURE_LOG")"
case "$XCODEBUILD_PWD" in
  "$BASE"/.release-work/unsigned-package.*/exact-source) ;;
  *) fail 'xcodebuild did not run from the isolated exact-commit clone' ;;
esac
[[ "$XCODEBUILD_HOME" == "$XCODEBUILD_PWD/.release-work/home" ]] ||
  fail 'xcodebuild did not receive the isolated exact-source HOME'
case "$DITTO_SCRIPT" in
  "$XCODEBUILD_PWD"/FixtureTools/ditto) ;;
  *) fail 'DMG creation did not use ditto from the exact-commit clone' ;;
esac
[[ "$DITTO_PWD" == "$XCODEBUILD_PWD" ]] || fail 'ditto did not run from the exact-commit clone'
case "$HDIUTIL_SCRIPT" in
  "$XCODEBUILD_PWD"/FixtureTools/hdiutil) ;;
  *) fail 'DMG creation did not use hdiutil from the exact-commit clone' ;;
esac
[[ "$HDIUTIL_PWD" == "$XCODEBUILD_PWD" ]] || fail 'hdiutil did not run from the exact-commit clone'
[[ "$INSPECT_SCRIPT" == "$XCODEBUILD_PWD/Scripts/inspect-dmg.sh" ]] ||
  fail 'DMG inspection did not use the exact-commit script'
[[ "$INSPECT_PWD" == "$XCODEBUILD_PWD" ]] || fail 'DMG inspection did not run from the exact-commit clone'
[[ "$SOURCE_SENTINEL" == committed ]] || fail 'isolated build did not read committed source content'

printf 'mutate main worktree after candidate verification\n' > "$FIXTURE_LOG.mutate-root"
run_package "$BASE" --commit "$BASE_COMMIT" --output dist/concurrent-mutation
[[ "$PACKAGE_STATUS" -eq 0 ]] || fail "isolated concurrent-mutation fixture failed: $(/bin/cat "$STDERR")"
[[ "$(/bin/cat "$BASE/Config/source-sentinel")" == mutated-after-candidate ]] ||
  fail 'concurrency fixture did not mutate the original worktree'
[[ "$(/usr/bin/awk -F '\t' '$1 == "boundary:source-sentinel" { print $2; exit }' "$FIXTURE_LOG")" == committed ]] ||
  fail 'archive build consumed a post-candidate main-worktree mutation'
/usr/bin/git -C "$BASE" checkout -- Config/source-sentinel
/bin/rm "$FIXTURE_LOG.mutate-root"

printf 'strip copied executable mode\n' > "$FIXTURE_LOG.strip-mode"
run_package "$BASE" --commit "$BASE_COMMIT" --output dist/stripped-executable-mode
[[ "$PACKAGE_STATUS" -ne 0 ]] || fail 'DMG creation accepted a copied app with changed executable mode'
/usr/bin/grep -Fq 'DMG creation error: app-copy-mismatch' "$STDERR" ||
  fail 'copied executable mode drift did not fail at the create-dmg content boundary'
[[ ! -e "$BASE/dist/stripped-executable-mode" ]] || fail 'mode-drift failure left a package output'
/bin/rm "$FIXTURE_LOG.strip-mode"

printf 'source executable is not owner-executable\n' > "$FIXTURE_LOG.source-mode-0644"
run_package "$BASE" --commit "$BASE_COMMIT" --output dist/source-executable-mode
[[ "$PACKAGE_STATUS" -eq 31 ]] || fail "non-executable source main binary returned $PACKAGE_STATUS, expected 31"
/usr/bin/grep -Fq 'archived-app-executable-invalid' "$STDERR" ||
  fail 'non-executable source main binary did not fail at the archive boundary'
[[ ! -e "$BASE/dist/source-executable-mode" ]] || fail 'non-executable source main binary left a package output'
/bin/rm "$FIXTURE_LOG.source-mode-0644"

printf 'source app carries private xattr\n' > "$FIXTURE_LOG.source-xattr"
run_package "$BASE" --commit "$BASE_COMMIT" --output dist/source-app-xattr
[[ "$PACKAGE_STATUS" -ne 0 ]] || fail 'source app with an xattr passed DMG creation'
/usr/bin/grep -Fq 'DMG creation error: unsafe-app-bundle' "$STDERR" ||
  fail 'source app xattr did not fail at the create-dmg source boundary'
[[ ! -e "$BASE/dist/source-app-xattr" ]] || fail 'source app xattr left a package output'
/bin/rm "$FIXTURE_LOG.source-xattr"

if [[ "$PROVENANCE_XATTR_SUPPORTED" -eq 1 ]]; then
  /usr/bin/printf '%s\n' 'source app carries canonical provenance' > "$FIXTURE_LOG.source-provenance-canonical"
  run_package "$BASE" --commit "$BASE_COMMIT" --output dist/source-provenance-canonical
  [[ "$PACKAGE_STATUS" -eq 0 ]] ||
    fail "canonical source provenance was rejected: $(/bin/cat "$STDERR")"
  [[ -f "$BASE/dist/source-provenance-canonical/UtterInk-0.1.0-arm64-UNSIGNED-DO-NOT-DISTRIBUTE.dmg" ]] ||
    fail 'canonical source provenance did not emit the unsigned DMG'
  /bin/rm "$FIXTURE_LOG.source-provenance-canonical"

  provenance_scenarios=(source-provenance-extra-xattr)
  if [[ "$PROVENANCE_WRONG_PREFIX_SUPPORTED" -eq 1 ]]; then
    provenance_scenarios+=(source-provenance-wrong-prefix)
  else
    /usr/bin/printf '%s\n' 'unsigned packaging tests: SKIP wrong-prefix provenance fixture (macOS canonicalized the custom value)' >&2
  fi
  if [[ "$PROVENANCE_WRONG_LENGTH_SUPPORTED" -eq 1 ]]; then
    provenance_scenarios+=(source-provenance-wrong-length)
  else
    /usr/bin/printf '%s\n' 'unsigned packaging tests: SKIP wrong-length provenance fixture (macOS canonicalized the custom value)' >&2
  fi
  for provenance_scenario in "${provenance_scenarios[@]}"; do
    /usr/bin/printf '%s\n' "adversarial provenance fixture: $provenance_scenario" > "$FIXTURE_LOG.$provenance_scenario"
    run_package "$BASE" --commit "$BASE_COMMIT" --output "dist/$provenance_scenario"
    [[ "$PACKAGE_STATUS" -ne 0 ]] || fail "$provenance_scenario passed DMG creation"
    /usr/bin/grep -Fq 'DMG creation error: unsafe-app-bundle' "$STDERR" ||
      fail "$provenance_scenario did not fail at the create-dmg source boundary"
    [[ ! -e "$BASE/dist/$provenance_scenario" ]] || fail "$provenance_scenario left a package output"
    /bin/rm "$FIXTURE_LOG.$provenance_scenario"
  done
else
  /usr/bin/printf '%s\n' 'unsigned packaging tests: SKIP custom provenance fixtures (macOS refused custom com.apple.provenance)' >&2
fi

printf 'fixture\n' > "$FIXTURE_LOG.non-arm64"
run_package "$BASE" --commit "$BASE_COMMIT" --output dist/non-arm64
[[ "$PACKAGE_STATUS" -eq 31 ]] || fail "non-arm64 Mach-O returned $PACKAGE_STATUS, expected 31"
/usr/bin/grep -Fq 'archived-app-architecture-mismatch' "$STDERR" || fail 'non-arm64 Mach-O diagnostic was not stable'
[[ ! -e "$BASE/dist/non-arm64" ]] || fail 'non-arm64 Mach-O emitted a DMG output directory'
/bin/rm "$FIXTURE_LOG.non-arm64"

printf 'fixture\n' > "$FIXTURE_LOG.code-signature"
run_package "$BASE" --commit "$BASE_COMMIT" --output dist/has-code-signature
[[ "$PACKAGE_STATUS" -eq 31 ]] || fail "LC_CODE_SIGNATURE returned $PACKAGE_STATUS, expected 31"
/usr/bin/grep -Fq 'archived-app-unexpected-signature' "$STDERR" || fail 'LC_CODE_SIGNATURE diagnostic was not stable'
[[ ! -e "$BASE/dist/has-code-signature" ]] || fail 'signed Mach-O emitted an unsigned DMG output directory'
/bin/rm "$FIXTURE_LOG.code-signature"

MATCHING="$TMP/matching-origin"
/usr/bin/git clone -q --no-hardlinks "$BASE" "$MATCHING"
ORIGIN='https://example.invalid/owner/UtterInk.git'
/usr/bin/git -C "$MATCHING" remote set-url origin "$ORIGIN"
install_xcodegen "$MATCHING"
MATCHING_COMMIT="$(/usr/bin/git -C "$MATCHING" rev-parse HEAD)"
run_package "$MATCHING" \
  --commit "$MATCHING_COMMIT" \
  --output dist/matching-origin \
  --expected-origin "$ORIGIN"
[[ "$PACKAGE_STATUS" -eq 0 ]] || fail "matching expected origin failed: $(/bin/cat "$STDERR")"
[[ "$(/usr/bin/grep -Fxc 'verify-arg:--expected-origin' "$FIXTURE_LOG")" -eq 1 ]] ||
  fail 'expected-origin flag was not forwarded exactly once'
[[ "$(/usr/bin/grep -Fxc "verify-arg:$ORIGIN" "$FIXTURE_LOG")" -eq 1 ]] ||
  fail 'expected-origin value was not forwarded exactly once and unchanged'

MISSING_EXPECTED="$TMP/missing-expected-origin"
/usr/bin/git clone -q --no-hardlinks "$BASE" "$MISSING_EXPECTED"
/usr/bin/git -C "$MISSING_EXPECTED" remote set-url origin "$ORIGIN"
install_xcodegen "$MISSING_EXPECTED"
run_package "$MISSING_EXPECTED" \
  --commit "$(/usr/bin/git -C "$MISSING_EXPECTED" rev-parse HEAD)" \
  --output dist/missing-expected-origin
[[ "$PACKAGE_STATUS" -ne 0 ]] || fail 'repository with origin passed without --expected-origin'
if /usr/bin/grep -Fq $'xcodebuild\tarchive' "$FIXTURE_LOG"; then
  fail 'missing expected origin reached the archive build'
fi
[[ ! -e "$MISSING_EXPECTED/dist/missing-expected-origin" ]] || fail 'missing expected origin emitted output'

MISMATCHED="$TMP/mismatched-origin"
/usr/bin/git clone -q --no-hardlinks "$BASE" "$MISMATCHED"
/usr/bin/git -C "$MISMATCHED" remote set-url origin "$ORIGIN"
install_xcodegen "$MISMATCHED"
run_package "$MISMATCHED" \
  --commit "$(/usr/bin/git -C "$MISMATCHED" rev-parse HEAD)" \
  --output dist/mismatched-origin \
  --expected-origin 'https://example.invalid/other/repository.git'
[[ "$PACKAGE_STATUS" -ne 0 ]] || fail 'mismatched expected origin passed'
if /usr/bin/grep -Fq $'xcodebuild\tarchive' "$FIXTURE_LOG"; then
  fail 'mismatched expected origin reached the archive build'
fi
[[ ! -e "$MISMATCHED/dist/mismatched-origin" ]] || fail 'mismatched expected origin emitted output'

DMG_FILENAME='UtterInk-0.1.0-arm64-UNSIGNED-DO-NOT-DISTRIBUTE.dmg'
PACKAGE_RACE_OUTPUT="$BASE/dist/package-publish-race"
PACKAGE_RACE_DETACHED="$BASE/dist/package-publish-race-detached"
PACKAGE_RACE_EXTERNAL="$TMP/package-publish-race-external"
PACKAGE_RACE_READY="$BASE/FixtureTools/.utterink-package-publish-race-ready"
PACKAGE_RACE_GO="$BASE/FixtureTools/.utterink-package-publish-race-go"
/bin/mkdir -m 0700 "$PACKAGE_RACE_EXTERNAL"
/bin/rm -f "$PACKAGE_RACE_READY" "$PACKAGE_RACE_GO"
start_package_publish_race "$BASE" \
  --commit "$BASE_COMMIT" \
  --output dist/package-publish-race
wait_for_race_ready "$PACKAGE_RACE_READY"
[[ -d "$PACKAGE_RACE_OUTPUT" && ! -L "$PACKAGE_RACE_OUTPUT" ]] ||
  fail 'package publish hook fired before opening the output directory'
/bin/mv "$PACKAGE_RACE_OUTPUT" "$PACKAGE_RACE_DETACHED"
/bin/ln -s "$PACKAGE_RACE_EXTERNAL" "$PACKAGE_RACE_OUTPUT"
printf 'continue\n' > "$PACKAGE_RACE_GO"
finish_race_process
[[ "$PACKAGE_STATUS" -eq 33 ]] ||
  fail "package parent replacement returned $PACKAGE_STATUS, expected 33"
/usr/bin/grep -Fq 'unsigned packaging error: output-publish-failed' "$STDERR" ||
  fail 'package parent replacement did not fail closed at final publish'
[[ -z "$(/usr/bin/find "$PACKAGE_RACE_EXTERNAL" -mindepth 1 -print -quit)" ]] ||
  fail 'package parent replacement created a file outside the repository'
[[ ! -e "$PACKAGE_RACE_DETACHED/$DMG_FILENAME" ]] ||
  fail 'package parent replacement left the published inode in the detached directory'
[[ ! -e "$PACKAGE_RACE_READY" && ! -e "$PACKAGE_RACE_GO" ]] ||
  fail 'package publish-race synchronization markers were not cleaned'
/bin/rm "$PACKAGE_RACE_OUTPUT"
/bin/rm -rf "$PACKAGE_RACE_DETACHED"

CREATE_RACE_APP="$BASE/build/UtterInk.app"
/bin/mkdir -p "$CREATE_RACE_APP/Contents/MacOS" "$CREATE_RACE_APP/Contents/Resources"
printf 'fixture Mach-O bytes\n' > "$CREATE_RACE_APP/Contents/MacOS/UtterInk"
/bin/chmod 0755 "$CREATE_RACE_APP/Contents/MacOS/UtterInk"
printf '%s\n' '<?xml version="1.0"?><plist version="1.0"><dict/></plist>' > "$CREATE_RACE_APP/Contents/Info.plist"
CREATE_RACE_OUTPUT_PARENT="$BASE/dist/create-publish-race"
CREATE_RACE_OUTPUT="$CREATE_RACE_OUTPUT_PARENT/$DMG_FILENAME"
CREATE_RACE_DETACHED="$BASE/dist/create-publish-race-detached"
CREATE_RACE_EXTERNAL="$TMP/create-publish-race-external"
CREATE_RACE_READY="$BASE/FixtureTools/.utterink-dmg-publish-race-ready"
CREATE_RACE_GO="$BASE/FixtureTools/.utterink-dmg-publish-race-go"
/bin/mkdir -m 0700 "$CREATE_RACE_EXTERNAL"
/bin/rm -f "$CREATE_RACE_READY" "$CREATE_RACE_GO"
start_create_publish_race "$BASE" \
  --app "$CREATE_RACE_APP" \
  --output "$CREATE_RACE_OUTPUT" \
  --mode unsigned
wait_for_race_ready "$CREATE_RACE_READY"
[[ -d "$CREATE_RACE_OUTPUT_PARENT" && ! -L "$CREATE_RACE_OUTPUT_PARENT" ]] ||
  fail 'create-dmg publish hook fired before opening the output parent'
/bin/mv "$CREATE_RACE_OUTPUT_PARENT" "$CREATE_RACE_DETACHED"
/bin/ln -s "$CREATE_RACE_EXTERNAL" "$CREATE_RACE_OUTPUT_PARENT"
printf 'continue\n' > "$CREATE_RACE_GO"
finish_race_process
[[ "$PACKAGE_STATUS" -ne 0 ]] || fail 'create-dmg accepted a concurrently replaced output parent'
/usr/bin/grep -Fq 'DMG creation error: output-publish-failed' "$STDERR" ||
  fail 'create-dmg parent replacement did not fail closed at final publish'
[[ -z "$(/usr/bin/find "$CREATE_RACE_EXTERNAL" -mindepth 1 -print -quit)" ]] ||
  fail 'create-dmg parent replacement created a file outside the repository'
[[ ! -e "$CREATE_RACE_DETACHED/$DMG_FILENAME" ]] ||
  fail 'create-dmg parent replacement left the published inode in the detached directory'
[[ ! -e "$CREATE_RACE_READY" && ! -e "$CREATE_RACE_GO" ]] ||
  fail 'create-dmg publish-race synchronization markers were not cleaned'
/bin/rm "$CREATE_RACE_OUTPUT_PARENT"
/bin/rm -rf "$CREATE_RACE_DETACHED"

run_package "$BASE" --commit "$BASE_COMMIT" --output '../escape'
[[ "$PACKAGE_STATUS" -eq 29 ]] || fail 'parent-traversal output was not rejected as unsafe-output'
[[ ! -e "$TMP/escape" ]] || fail 'parent-traversal output escaped the repository'

/bin/mkdir -p "$BASE/dist" "$TMP/symlink-target"
/bin/ln -s "$TMP/symlink-target" "$BASE/dist/symlink-parent"
run_package "$BASE" --commit "$BASE_COMMIT" --output dist/symlink-parent/child
[[ "$PACKAGE_STATUS" -eq 29 ]] || fail 'symlinked output parent was not rejected as unsafe-output'
[[ ! -e "$TMP/symlink-target/child" ]] || fail 'symlinked output parent was followed'

run_package "$BASE" --commit "$BASE_COMMIT" --output "$TMP/outside/output"
[[ "$PACKAGE_STATUS" -eq 29 ]] || fail 'absolute output outside the repository was accepted'

/bin/rm "$BASE/dist/symlink-parent"
(
  cd "$BASE"
  ./Scripts/clean-distribution-output.sh dist .release-work
)
[[ ! -e "$BASE/dist" && ! -e "$BASE/.release-work" ]] || fail 'cleanup did not remove all packaging outputs'
[[ -x "$BASE/Tools/bin/xcodegen" ]] || fail 'output cleanup removed the repository toolchain unexpectedly'
[[ -f "$BASE/Tools/bin/XcodeGen_XcodeGenKit.bundle/SettingPresets/base.yml" ]] ||
  fail 'output cleanup removed the repository XcodeGen companion resources unexpectedly'

printf 'unsigned packaging tests passed\n'
