#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
BOOTSTRAP="$ROOT/Scripts/bootstrap-xcodegen.sh"
VERIFY="$ROOT/Scripts/verify-toolchain.sh"

fail() {
  printf 'XcodeGen bootstrap tests failed: %s\n' "$1" >&2
  exit 1
}

[[ -f "$BOOTSTRAP" ]] || fail 'Scripts/bootstrap-xcodegen.sh is missing'
[[ -f "$VERIFY" ]] || fail 'Scripts/verify-toolchain.sh is missing'

TMP="$(mktemp -d /private/tmp/utterink-xcodegen-tests.XXXXXX)"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
FIXTURE="$TMP/repository"
mkdir -p \
  "$FIXTURE/Scripts" \
  "$FIXTURE/Config" \
  "$FIXTURE/FixtureTools" \
  "$FIXTURE/FixtureBinary" \
  "$FIXTURE/FixtureSource/archive-root"
cp "$BOOTSTRAP" "$FIXTURE/Scripts/bootstrap-xcodegen.sh"
cp "$VERIFY" "$FIXTURE/Scripts/verify-toolchain.sh"
chmod 0755 "$FIXTURE/Scripts/bootstrap-xcodegen.sh" "$FIXTURE/Scripts/verify-toolchain.sh"
printf 'utterink-offline-toolchain-fixture-v1\n' > "$FIXTURE/FixtureTools/.utterink-toolchain-test-fixture"

SOURCE_COMMIT=0123456789abcdef0123456789abcdef01234567
SOURCE_ROOT="$FIXTURE/FixtureSource/archive-root/XcodeGen-$SOURCE_COMMIT"
mkdir -p \
  "$SOURCE_ROOT/Sources" \
  "$SOURCE_ROOT/SettingPresets/Configs" \
  "$SOURCE_ROOT/SettingPresets/Platforms"
printf '// swift-tools-version: 6.0\n' > "$SOURCE_ROOT/Package.swift"
printf '{"pins":[],"version":3}\n' > "$SOURCE_ROOT/Package.resolved"
printf 'locked source marker\n' > "$SOURCE_ROOT/Sources/marker.txt"
printf 'SWIFT_ACTIVE_COMPILATION_CONDITIONS: DEBUG\n' > "$SOURCE_ROOT/SettingPresets/Configs/debug.yml"
printf 'SUPPORTED_PLATFORMS: macosx\n' > "$SOURCE_ROOT/SettingPresets/Platforms/macOS.yml"
printf 'SDKROOT: auto\n' > "$SOURCE_ROOT/SettingPresets/base.yml"

cat > "$FIXTURE/FixtureBinary/xcodegen" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ "${1-}" == '--version' ]] || exit 64
printf 'Version: 2.45.4\n'
EOF
chmod 0755 "$FIXTURE/FixtureBinary/xcodegen"
BINARY_SHA="$(/usr/bin/shasum -a 256 "$FIXTURE/FixtureBinary/xcodegen" | /usr/bin/awk '{print $1}')"

SETTING_PRESETS_SHA="$(/usr/bin/python3 -I - "$SOURCE_ROOT/SettingPresets" <<'PY'
from __future__ import annotations

import hashlib
from pathlib import Path
import struct
import sys

root = Path(sys.argv[1])
items = sorted(
    (path.relative_to(root).as_posix().encode("utf-8"), path.read_bytes())
    for path in root.rglob("*")
    if path.is_file()
)
digest = hashlib.sha256()
for relative, content in items:
    digest.update(struct.pack(">Q", len(relative)))
    digest.update(relative)
    digest.update(struct.pack(">Q", len(content)))
    digest.update(content)
print(digest.hexdigest())
PY
)"

ARCHIVE="$FIXTURE/FixtureSource/XcodeGen-$SOURCE_COMMIT.tar.gz"
(cd "$FIXTURE/FixtureSource/archive-root" && COPYFILE_DISABLE=1 /usr/bin/tar -czf "$ARCHIVE" "XcodeGen-$SOURCE_COMMIT")
ARCHIVE_SHA="$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{print $1}')"

cat > "$FIXTURE/FixtureTools/swift" <<'EOF'
#!/bin/bash
set -euo pipefail
SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
printf 'swift:%s\n' "$*" >> "$SCRIPT_ROOT/fixture-tools.log"
if [[ "${1-}" == '--version' ]]; then
  printf '%s\n' \
    'swift-driver version: 1.148.6 Apple Swift version 6.3.1 (swiftlang-6.3.1.1.2 clang-2100.0.123.102)' \
    'Target: arm64-apple-macosx26.0'
  exit 0
fi
[[ "${1-}" == 'build' ]] || exit 64
scratch=''
cache=''
config=''
security=''
dependency_cache_disabled=0
show_bin=0
previous=''
for argument in "$@"; do
  if [[ "$previous" == '--scratch-path' ]]; then scratch="$argument"; fi
  if [[ "$previous" == '--cache-path' ]]; then cache="$argument"; fi
  if [[ "$previous" == '--config-path' ]]; then config="$argument"; fi
  if [[ "$previous" == '--security-path' ]]; then security="$argument"; fi
  if [[ "$argument" == '--disable-dependency-cache' ]]; then dependency_cache_disabled=1; fi
  if [[ "$argument" == '--show-bin-path' ]]; then show_bin=1; fi
  previous="$argument"
done
[[ "$scratch" == /* ]]
canonical_root="$(dirname "$scratch")"
[[ "$cache" == "$canonical_root/swiftpm-cache" ]]
[[ "$config" == "$canonical_root/swiftpm-config" ]]
[[ "$security" == "$canonical_root/swiftpm-security" ]]
[[ "$dependency_cache_disabled" -eq 1 ]]
[[ "${SWIFT_MODULECACHE_PATH:-}" == "$canonical_root/swift-module-cache" ]]
[[ "${CLANG_MODULE_CACHE_PATH:-}" == "$canonical_root/clang-module-cache" ]]
[[ "${SOURCE_DATE_EPOCH:-}" == 0 ]]
[[ "${ZERO_AR_DATE:-}" == 1 ]]
[[ -z "${SWIFT_EXEC+x}" && -z "${DYLD_INSERT_LIBRARIES+x}" ]]
if [[ "$show_bin" -eq 1 ]]; then
  printf '%s/release\n' "$scratch"
else
  mkdir -p "$scratch/release"
  cp "$SCRIPT_ROOT/FixtureBinary/xcodegen" "$scratch/release/xcodegen"
  chmod 0755 "$scratch/release/xcodegen"
fi
EOF

cat > "$FIXTURE/FixtureTools/xcodebuild" <<'EOF'
#!/bin/bash
set -euo pipefail
SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
printf 'xcodebuild:%s\n' "$*" >> "$SCRIPT_ROOT/fixture-tools.log"
case " $* " in
  *' -version -sdk macosx SDKVersion '*) printf '26.4\n' ;;
  *' -version -sdk macosx ProductBuildVersion '*) printf '25E999\n' ;;
  *' -version '*) printf 'Xcode 26.4.1\nBuild version 17E202\n' ;;
  *) exit 64 ;;
esac
EOF

cat > "$FIXTURE/FixtureTools/uname" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ "${1-}" == '-m' ]] || exit 64
printf 'arm64\n'
EOF

cat > "$FIXTURE/FixtureTools/sw_vers" <<'EOF'
#!/bin/bash
set -euo pipefail
case "${1-}" in
  -productVersion) printf '26.4\n' ;;
  -buildVersion) printf '25E246\n' ;;
  *) exit 64 ;;
esac
EOF
chmod 0755 "$FIXTURE/FixtureTools/"*

python3 - "$FIXTURE/Config/ci-toolchain.json" "$SOURCE_COMMIT" "$ARCHIVE_SHA" "$BINARY_SHA" "$SETTING_PRESETS_SHA" <<'PY'
from __future__ import annotations

import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
commit, archive_sha, binary_sha, setting_presets_sha = sys.argv[2:]
lock = {
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
    "swift": {
        "version": "swift-driver version: 1.148.6 Apple Swift version 6.3.1 (swiftlang-6.3.1.1.2 clang-2100.0.123.102)"
    },
    "xcodegen": {
        "version": "2.45.4",
        "sourceCommit": commit,
        "archiveURL": f"https://github.com/yonaskolb/XcodeGen/archive/{commit}.tar.gz",
        "archiveSHA256": archive_sha,
        "binarySHA256": binary_sha,
        "settingPresetsSHA256": setting_presets_sha,
    },
    "sources": {
        "runnerRelease": "https://github.com/actions/runner-images/releases/tag/macos-26-arm64%2F20260630.0213",
        "runnerReadme": "https://github.com/actions/runner-images/blob/afadebc447d1a69fc726b50cd5aba055c0cfdf82/images/macos/macos-26-arm64-Readme.md",
        "xcodegenRelease": "https://github.com/yonaskolb/XcodeGen/releases/tag/2.45.4",
        "xcodegenCommit": f"https://github.com/yonaskolb/XcodeGen/commit/{commit}",
    },
}
path.write_text(json.dumps(lock, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

mkdir -p "$FIXTURE/HostilePath"
cat > "$FIXTURE/HostilePath/xcodegen" <<EOF
#!/bin/bash
printf 'ordinary PATH xcodegen was used\n' > '$FIXTURE/path-fallback-used'
printf 'Version: 2.45.4\n'
EOF
chmod 0755 "$FIXTURE/HostilePath/xcodegen"

set +e
(
  cd "$FIXTURE"
  PATH="$FIXTURE/HostilePath:/usr/bin:/bin:/usr/sbin:/sbin" \
    ./Scripts/bootstrap-xcodegen.sh
) > "$TMP/stdout" 2> "$TMP/stderr"
STATUS=$?
set -e
[[ "$STATUS" -ne 0 ]] || fail 'production mode accepted a fixture source commit'
grep -q 'toolchain-lock-invalid' "$TMP/stderr" || fail 'production source pin did not fail closed'
[[ ! -e "$FIXTURE/path-fallback-used" ]] || fail 'production pin check consulted ordinary PATH'

run_bootstrap() {
  set +e
  (
    cd "$FIXTURE"
    # Keep the interpreter launchable on macOS 26 while retaining the fake
    # Swift tool's downstream absence check above.
    env \
      PATH="$FIXTURE/HostilePath:/usr/bin:/bin:/usr/sbin:/sbin" \
      UTTERINK_TOOLCHAIN_TEST_MODE=1 \
      UTTERINK_TOOLCHAIN_TEST_TOOL_ROOT="$FIXTURE/FixtureTools" \
      UTTERINK_TOOLCHAIN_TEST_ARCHIVE="$ARCHIVE" \
      SWIFT_EXEC="$FIXTURE/HostilePath/swiftc" \
      DYLD_INSERT_LIBRARIES=/usr/lib/libSystem.B.dylib \
      ./Scripts/bootstrap-xcodegen.sh
  ) > "$TMP/stdout" 2> "$TMP/stderr"
  STATUS=$?
  set -e
}

run_verify() {
  local context="$1"
  shift
  set +e
  (
    cd "$FIXTURE"
    env \
      PATH="$FIXTURE/HostilePath:/usr/bin:/bin:/usr/sbin:/sbin" \
      UTTERINK_TOOLCHAIN_TEST_MODE=1 \
      UTTERINK_TOOLCHAIN_TEST_TOOL_ROOT="$FIXTURE/FixtureTools" \
      "$@" \
      ./Scripts/verify-toolchain.sh --context "$context"
  ) > "$TMP/stdout" 2> "$TMP/stderr"
  STATUS=$?
  set -e
}

rm -f "$FIXTURE/Config/ci-toolchain.json.saved"
mv "$FIXTURE/Config/ci-toolchain.json" "$FIXTURE/Config/ci-toolchain.json.saved"
run_bootstrap
[[ "$STATUS" -ne 0 ]] || fail 'bootstrap accepted a missing production lock'
grep -q 'toolchain-lock-missing' "$TMP/stderr" || fail 'missing lock did not fail closed'
mv "$FIXTURE/Config/ci-toolchain.json.saved" "$FIXTURE/Config/ci-toolchain.json"

CANONICAL_BUILD_ROOT="/private/tmp/utterink-xcodegen-bootstrap-$SOURCE_COMMIT"
CANONICAL_BUILD_LOCK="$CANONICAL_BUILD_ROOT.lock"
[[ ! -e "$CANONICAL_BUILD_ROOT" && ! -e "$CANONICAL_BUILD_LOCK" ]] ||
  fail 'canonical bootstrap test root was already occupied'
mkdir -m 0700 "$CANONICAL_BUILD_LOCK"
run_bootstrap
[[ "$STATUS" -ne 0 ]] || fail 'bootstrap ignored an occupied canonical build lock'
grep -q 'canonical-build-root-busy; after confirming no bootstrap is running' "$TMP/stderr" ||
  fail 'busy canonical root did not provide a bounded recovery diagnostic'
rmdir "$CANONICAL_BUILD_LOCK"

run_verify local
[[ "$STATUS" -ne 0 ]] || fail 'local verification passed before bootstrap'
grep -q 'repository-xcodegen-missing' "$TMP/stderr" || fail 'pre-bootstrap local failure was not actionable'
run_verify ci \
  RUNNER_OS=macOS RUNNER_ARCH=ARM64 ImageOS=macos26 ImageVersion=20260630.0213.1 \
  DEVELOPER_DIR=/Applications/Xcode_26.4.app/Contents/Developer \
  UTTERINK_CI_RUNNER_LABEL=macos-26
[[ "$STATUS" -ne 0 ]] || fail 'CI verification passed before bootstrap'
grep -q 'repository-xcodegen-missing' "$TMP/stderr" || fail "pre-bootstrap CI failure was not actionable: $(tr '\n' ' ' < "$TMP/stderr")"
[[ ! -e "$FIXTURE/path-fallback-used" ]] || fail 'ordinary PATH fallback ran before bootstrap'

/bin/mkdir -p "$FIXTURE/Tools/bin"
cat > "$FIXTURE/Tools/bin/xcodegen" <<EOF
#!/bin/bash
/usr/bin/touch '$FIXTURE/untrusted-existing-xcodegen-ran'
printf 'Version: 2.45.4\n'
EOF
/bin/chmod 0755 "$FIXTURE/Tools/bin/xcodegen"
run_bootstrap
[[ "$STATUS" -eq 0 ]] || fail "bootstrap failed: $(tr '\n' ' ' < "$TMP/stderr")"
[[ ! -e "$FIXTURE/untrusted-existing-xcodegen-ran" ]] ||
  fail 'bootstrap executed an existing XcodeGen binary before verifying its hash and companion resources'
[[ -x "$FIXTURE/Tools/bin/xcodegen" && ! -L "$FIXTURE/Tools/bin/xcodegen" ]] || fail 'bootstrap did not install a regular executable'
INSTALLED_BUNDLE="$FIXTURE/Tools/bin/XcodeGen_XcodeGenKit.bundle"
INSTALLED_SETTING_PRESETS="$INSTALLED_BUNDLE/SettingPresets"
[[ -d "$INSTALLED_BUNDLE" && ! -L "$INSTALLED_BUNDLE" ]] || fail 'bootstrap did not install a regular companion bundle'
[[ -d "$INSTALLED_SETTING_PRESETS" && ! -L "$INSTALLED_SETTING_PRESETS" ]] || fail 'bootstrap did not install regular setting presets'
diff -r "$SOURCE_ROOT/SettingPresets" "$INSTALLED_SETTING_PRESETS" >/dev/null || fail 'installed setting presets drifted'
ACTUAL_BINARY_SHA="$(/usr/bin/shasum -a 256 "$FIXTURE/Tools/bin/xcodegen" | /usr/bin/awk '{print $1}')"
[[ "$ACTUAL_BINARY_SHA" == "$BINARY_SHA" ]] || fail 'installed binary hash drifted'
[[ ! -e "$FIXTURE/path-fallback-used" ]] || fail 'bootstrap consulted ordinary PATH'
grep -q -- '--force-resolved-versions' "$FIXTURE/fixture-tools.log" || fail 'source build did not force resolved versions'

BUILDS_BEFORE_EARLY_RETURN="$(grep -c '^swift:build ' "$FIXTURE/fixture-tools.log")"
run_bootstrap
[[ "$STATUS" -eq 0 ]] || fail "complete-install early return failed: $(tr '\n' ' ' < "$TMP/stderr")"
grep -q 'locked XcodeGen already installed' "$TMP/stdout" || fail 'complete install did not report an early return'
[[ "$(grep -c '^swift:build ' "$FIXTURE/fixture-tools.log")" -eq "$BUILDS_BEFORE_EARLY_RETURN" ]] ||
  fail 'complete-install early return rebuilt XcodeGen'

run_verify local
[[ "$STATUS" -eq 0 ]] || fail "local verification failed: $(tr '\n' ' ' < "$TMP/stderr")"
grep -q 'context=local' "$TMP/stdout" || fail 'local verification did not identify its context'

run_verify ci \
  RUNNER_OS=macOS RUNNER_ARCH=ARM64 ImageOS=macos26 ImageVersion=20260630.0213.1 \
  DEVELOPER_DIR=/Applications/Xcode_26.4.app/Contents/Developer \
  UTTERINK_CI_RUNNER_LABEL=macos-26
[[ "$STATUS" -eq 0 ]] || fail "CI verification failed: $(tr '\n' ' ' < "$TMP/stderr")"
grep -q 'context=ci' "$TMP/stdout" || fail 'CI verification did not identify its context'
[[ ! -e "$FIXTURE/path-fallback-used" ]] || fail 'verification consulted ordinary PATH'

rm -rf "$FIXTURE/Tools"
run_bootstrap
[[ "$STATUS" -eq 0 ]] || fail "second canonical bootstrap failed: $(tr '\n' ' ' < "$TMP/stderr")"
SECOND_BINARY_SHA="$(/usr/bin/shasum -a 256 "$FIXTURE/Tools/bin/xcodegen" | /usr/bin/awk '{print $1}')"
[[ "$SECOND_BINARY_SHA" == "$BINARY_SHA" ]] || fail 'two canonical source builds produced different binary hashes'
[[ ! -e "$CANONICAL_BUILD_ROOT" && ! -e "$CANONICAL_BUILD_ROOT.lock" ]] || fail 'canonical build root was not cleaned'
if grep '^swift:build ' "$FIXTURE/fixture-tools.log" | grep -F "$FIXTURE" >/dev/null; then
  fail 'source build arguments included the randomized fixture path'
fi
[[ "$(grep -c '^swift:build ' "$FIXTURE/fixture-tools.log")" -eq 4 ]] || fail 'expected two build/show-bin-path pairs'
grep '^swift:build ' "$FIXTURE/fixture-tools.log" \
  | grep -F -- "--package-path $CANONICAL_BUILD_ROOT/source/XcodeGen-$SOURCE_COMMIT" >/dev/null \
  || fail 'source package path was not canonical'
grep '^swift:build ' "$FIXTURE/fixture-tools.log" \
  | grep -F -- "--scratch-path $CANONICAL_BUILD_ROOT/build" >/dev/null \
  || fail 'SwiftPM scratch path was not canonical'
grep '^swift:build ' "$FIXTURE/fixture-tools.log" \
  | grep -F -- "-debug-prefix-map -Xswiftc $CANONICAL_BUILD_ROOT=/__UTTERINK_XCODEGEN_BUILD__" >/dev/null \
  || fail 'Swift source paths were not prefix-mapped'

assert_resource_rejected_and_repaired() {
  local expected_category="$1"
  local description="$2"
  run_verify local
  [[ "$STATUS" -ne 0 ]] || fail "verification accepted $description"
  grep -q "$expected_category" "$TMP/stderr" ||
    fail "$description did not produce $expected_category: $(tr '\n' ' ' < "$TMP/stderr")"
  run_bootstrap
  [[ "$STATUS" -eq 0 ]] || fail "bootstrap did not repair $description: $(tr '\n' ' ' < "$TMP/stderr")"
  diff -r "$SOURCE_ROOT/SettingPresets" "$INSTALLED_SETTING_PRESETS" >/dev/null ||
    fail "bootstrap repair drifted after $description"
  run_verify local
  [[ "$STATUS" -eq 0 ]] || fail "verification failed after repairing $description: $(tr '\n' ' ' < "$TMP/stderr")"
}

rm "$INSTALLED_SETTING_PRESETS/Configs/debug.yml"
assert_resource_rejected_and_repaired repository-xcodegen-unusable 'a missing setting preset resource'

printf 'drifted setting preset\n' > "$INSTALLED_SETTING_PRESETS/Configs/debug.yml"
assert_resource_rejected_and_repaired repository-xcodegen-mismatch 'a modified setting preset resource'

printf 'unexpected setting preset\n' > "$INSTALLED_SETTING_PRESETS/extra.yml"
assert_resource_rejected_and_repaired repository-xcodegen-mismatch 'an extra setting preset resource'

mkdir "$INSTALLED_SETTING_PRESETS/empty-extra-directory"
assert_resource_rejected_and_repaired repository-xcodegen-unusable 'an extra empty setting preset directory'

printf 'unexpected bundle resource\n' > "$INSTALLED_BUNDLE/extra.txt"
assert_resource_rejected_and_repaired repository-xcodegen-unusable 'an extra companion bundle resource'

rm "$INSTALLED_SETTING_PRESETS/Configs/debug.yml"
ln -s ../base.yml "$INSTALLED_SETTING_PRESETS/Configs/debug.yml"
assert_resource_rejected_and_repaired repository-xcodegen-unusable 'a symlinked setting preset resource'

/usr/bin/mkfifo "$INSTALLED_SETTING_PRESETS/unexpected.fifo"
assert_resource_rejected_and_repaired repository-xcodegen-unusable 'a special setting preset resource'

run_verify ci \
  RUNNER_OS=macOS RUNNER_ARCH=ARM64 ImageOS=macos26 ImageVersion=drifted \
  DEVELOPER_DIR=/Applications/Xcode_26.4.app/Contents/Developer \
  UTTERINK_CI_RUNNER_LABEL=macos-26
[[ "$STATUS" -ne 0 ]] || fail 'CI verification accepted runner image drift'
grep -q 'runner-environment-mismatch' "$TMP/stderr" || fail 'runner drift diagnostic was not stable'

set +e
(cd "$FIXTURE" && ./Scripts/verify-toolchain.sh --context other) > "$TMP/stdout" 2> "$TMP/stderr"
STATUS=$?
set -e
[[ "$STATUS" -eq 64 ]] || fail 'unknown context did not return usage status 64'
grep -q 'invalid-arguments' "$TMP/stderr" || fail 'unknown context diagnostic was not stable'

cp "$FIXTURE/Config/ci-toolchain.json" "$TMP/original-lock.json"
python3 - "$FIXTURE/Config/ci-toolchain.json" <<'PY'
import json
from pathlib import Path
import sys
path = Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["xcodegen"]["binarySHA256"] = "0" * 64
path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
run_verify local
[[ "$STATUS" -ne 0 ]] || fail 'verification accepted installed binary hash drift'
grep -q 'repository-xcodegen-mismatch' "$TMP/stderr" || fail 'binary drift diagnostic was not stable'
cp "$TMP/original-lock.json" "$FIXTURE/Config/ci-toolchain.json"

rm -rf "$FIXTURE/Tools"
python3 - "$FIXTURE/Config/ci-toolchain.json" <<'PY'
import json
from pathlib import Path
import sys
path = Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["xcodegen"]["binarySHA256"] = "0" * 64
path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
run_bootstrap
[[ "$STATUS" -ne 0 ]] || fail 'bootstrap accepted built binary hash drift'
grep -q 'built-binary-hash-mismatch' "$TMP/stderr" || fail 'built binary drift diagnostic was not stable'
[[ ! -e "$FIXTURE/Tools/bin/xcodegen" ]] || fail 'built binary drift installed a binary'
cp "$TMP/original-lock.json" "$FIXTURE/Config/ci-toolchain.json"

python3 - "$FIXTURE/Config/ci-toolchain.json" <<'PY'
import json
from pathlib import Path
import sys
path = Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["xcodegen"]["archiveSHA256"] = "0" * 64
path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
run_bootstrap
[[ "$STATUS" -ne 0 ]] || fail 'bootstrap accepted archive hash drift'
grep -q 'archive-hash-mismatch' "$TMP/stderr" || fail 'archive drift diagnostic was not stable'
[[ ! -e "$FIXTURE/Tools/bin/xcodegen" ]] || fail 'archive drift installed a binary'
cp "$TMP/original-lock.json" "$FIXTURE/Config/ci-toolchain.json"

OUTSIDE_ARCHIVE="$TMP/outside.tar.gz"
cp "$ARCHIVE" "$OUTSIDE_ARCHIVE"
set +e
(
  cd "$FIXTURE"
  env \
    UTTERINK_TOOLCHAIN_TEST_MODE=1 \
    UTTERINK_TOOLCHAIN_TEST_TOOL_ROOT="$FIXTURE/FixtureTools" \
    UTTERINK_TOOLCHAIN_TEST_ARCHIVE="$OUTSIDE_ARCHIVE" \
    ./Scripts/bootstrap-xcodegen.sh
) > "$TMP/stdout" 2> "$TMP/stderr"
STATUS=$?
set -e
[[ "$STATUS" -ne 0 ]] || fail 'test mode accepted a source archive outside the fixture repository'
grep -q 'invalid-test-source' "$TMP/stderr" || fail 'outside-source diagnostic was not stable'

rm "$SOURCE_ROOT/SettingPresets/Platforms/macOS.yml"
ln -s ../base.yml "$SOURCE_ROOT/SettingPresets/Platforms/macOS.yml"
(cd "$FIXTURE/FixtureSource/archive-root" && COPYFILE_DISABLE=1 /usr/bin/tar -czf "$ARCHIVE" "XcodeGen-$SOURCE_COMMIT")
SYMLINK_ARCHIVE_SHA="$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{print $1}')"
python3 - "$FIXTURE/Config/ci-toolchain.json" "$SYMLINK_ARCHIVE_SHA" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["xcodegen"]["archiveSHA256"] = sys.argv[2]
path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
rm -rf "$FIXTURE/Tools"
run_bootstrap
[[ "$STATUS" -ne 0 ]] || fail 'bootstrap accepted a symlinked source setting preset'
grep -q 'source-setting-presets-invalid' "$TMP/stderr" || fail 'source resource symlink diagnostic was not stable'
[[ ! -e "$FIXTURE/Tools/bin/xcodegen" ]] || fail 'source resource symlink installed a binary'
[[ ! -e "$FIXTURE/Tools/bin/XcodeGen_XcodeGenKit.bundle" ]] || fail 'source resource symlink installed a companion bundle'

printf 'XcodeGen bootstrap tests passed\n'
