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
  "$FIXTURE/FixtureArchive/staging/xcodegen/bin" \
  "$FIXTURE/FixtureArchive/staging/xcodegen/share/xcodegen/SettingPresets/Configs" \
  "$FIXTURE/FixtureArchive/staging/xcodegen/share/xcodegen/SettingPresets/Platforms"
cp "$BOOTSTRAP" "$FIXTURE/Scripts/bootstrap-xcodegen.sh"
cp "$VERIFY" "$FIXTURE/Scripts/verify-toolchain.sh"
chmod 0755 "$FIXTURE/Scripts/bootstrap-xcodegen.sh" "$FIXTURE/Scripts/verify-toolchain.sh"
printf 'utterink-offline-toolchain-fixture-v1\n' > "$FIXTURE/FixtureTools/.utterink-toolchain-test-fixture"

SOURCE_COMMIT=0123456789abcdef0123456789abcdef01234567
ARCHIVE_ROOT="$FIXTURE/FixtureArchive/staging/xcodegen"
ARCHIVE_SETTING_PRESETS="$ARCHIVE_ROOT/share/xcodegen/SettingPresets"
printf 'fixture license\n' > "$ARCHIVE_ROOT/LICENSE"
printf '#!/bin/bash\nexit 1\n' > "$ARCHIVE_ROOT/install.sh"
chmod 0755 "$ARCHIVE_ROOT/install.sh"
printf 'SWIFT_ACTIVE_COMPILATION_CONDITIONS: DEBUG\n' > "$ARCHIVE_SETTING_PRESETS/Configs/debug.yml"
printf 'SUPPORTED_PLATFORMS: macosx\n' > "$ARCHIVE_SETTING_PRESETS/Platforms/macOS.yml"
printf 'SDKROOT: auto\n' > "$ARCHIVE_SETTING_PRESETS/base.yml"

cat > "$FIXTURE/FixtureBinary/xcodegen" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ "${1-}" == '--version' ]] || exit 64
printf 'Version: 2.45.4\n'
EOF
chmod 0755 "$FIXTURE/FixtureBinary/xcodegen"
/bin/cp "$FIXTURE/FixtureBinary/xcodegen" "$ARCHIVE_ROOT/bin/xcodegen"
BINARY_SHA="$(/usr/bin/shasum -a 256 "$FIXTURE/FixtureBinary/xcodegen" | /usr/bin/awk '{print $1}')"

SETTING_PRESETS_SHA="$(/usr/bin/python3 -I - "$ARCHIVE_SETTING_PRESETS" <<'PY'
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

build_archive() {
  local output="$1"
  /usr/bin/python3 -I - "$ARCHIVE_ROOT" "$output" <<'PY'
from pathlib import Path
import os
import stat
import sys
import zipfile

root, output = map(Path, sys.argv[1:])
with zipfile.ZipFile(output, mode="w", compression=zipfile.ZIP_DEFLATED) as archive:
    for path in sorted((root, *root.rglob("*")), key=lambda value: value.relative_to(root.parent).as_posix()):
        relative = path.relative_to(root.parent).as_posix()
        metadata = os.lstat(path)
        if path.is_dir():
            info = zipfile.ZipInfo(relative + "/")
            info.create_system = 3
            info.external_attr = (stat.S_IFDIR | 0o755) << 16
            archive.writestr(info, b"")
        elif path.is_file() and not path.is_symlink():
            mode = 0o755 if metadata.st_mode & 0o111 else 0o644
            info = zipfile.ZipInfo(relative)
            info.create_system = 3
            info.external_attr = (stat.S_IFREG | mode) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, path.read_bytes())
        else:
            raise SystemExit(1)
PY
}

ARCHIVE="$FIXTURE/FixtureArchive/xcodegen.zip"
build_archive "$ARCHIVE"
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

cat > "$FIXTURE/FixtureTools/lipo" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ "$#" -eq 2 && "$1" == '-archs' && -f "$2" ]]
if /usr/bin/grep -q 'UTTERINK_WRONG_ARCH_FIXTURE' "$2"; then
  printf 'arm64\n'
else
  printf 'x86_64 arm64\n'
fi
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
        "archiveURL": "https://github.com/yonaskolb/XcodeGen/releases/download/2.45.4/xcodegen.zip",
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

cp "$FIXTURE/Config/ci-toolchain.json" "$TMP/fixture-lock.json"
python3 - "$FIXTURE/Config/ci-toolchain.json" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
commit = "8d3d3476a69ae3e5d68e1adccc701c410c05eb36"
value["xcodegen"]["sourceCommit"] = commit
value["xcodegen"]["archiveSHA256"] = "090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef"
value["xcodegen"]["binarySHA256"] = "6aa2b4da95304b343bea12890c59f9655aa428c08b351d57d592cfab4e88a9f1"
value["xcodegen"]["settingPresetsSHA256"] = "0" * 64
value["sources"]["xcodegenCommit"] = f"https://github.com/yonaskolb/XcodeGen/commit/{commit}"
path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
set +e
(
  cd "$FIXTURE"
  ./Scripts/bootstrap-xcodegen.sh
) > "$TMP/stdout" 2> "$TMP/stderr"
STATUS=$?
set -e
[[ "$STATUS" -ne 0 ]] || fail 'production bootstrap accepted setting presets hash drift'
grep -q 'toolchain-lock-invalid' "$TMP/stderr" || fail 'production bootstrap presets pin did not fail closed'
set +e
(
  cd "$FIXTURE"
  ./Scripts/verify-toolchain.sh --context local
) > "$TMP/stdout" 2> "$TMP/stderr"
STATUS=$?
set -e
[[ "$STATUS" -ne 0 ]] || fail 'production verification accepted setting presets hash drift'
grep -q 'toolchain-lock-invalid' "$TMP/stderr" || fail 'production verifier presets pin did not fail closed'
cp "$TMP/fixture-lock.json" "$FIXTURE/Config/ci-toolchain.json"

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
diff -r "$ARCHIVE_SETTING_PRESETS" "$INSTALLED_SETTING_PRESETS" >/dev/null || fail 'installed setting presets drifted'
ACTUAL_BINARY_SHA="$(/usr/bin/shasum -a 256 "$FIXTURE/Tools/bin/xcodegen" | /usr/bin/awk '{print $1}')"
[[ "$ACTUAL_BINARY_SHA" == "$BINARY_SHA" ]] || fail 'installed binary hash drifted'
[[ ! -e "$FIXTURE/path-fallback-used" ]] || fail 'bootstrap consulted ordinary PATH'
/bin/cp "$ARCHIVE" "$TMP/valid-xcodegen.zip"
printf 'not the locked archive\n' > "$ARCHIVE"
run_bootstrap
[[ "$STATUS" -eq 0 ]] || fail "complete-install early return failed: $(tr '\n' ' ' < "$TMP/stderr")"
grep -q 'locked XcodeGen already installed' "$TMP/stdout" || fail 'complete install did not report an early return'
/bin/cp "$TMP/valid-xcodegen.zip" "$ARCHIVE"

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
[[ "$STATUS" -eq 0 ]] || fail "second pinned-asset bootstrap failed: $(tr '\n' ' ' < "$TMP/stderr")"
SECOND_BINARY_SHA="$(/usr/bin/shasum -a 256 "$FIXTURE/Tools/bin/xcodegen" | /usr/bin/awk '{print $1}')"
[[ "$SECOND_BINARY_SHA" == "$BINARY_SHA" ]] || fail 'two pinned-asset installs produced different binary hashes'
if grep -q '^swift:build ' "$FIXTURE/fixture-tools.log"; then
  fail 'official release bootstrap unexpectedly built XcodeGen from source'
fi

assert_resource_rejected_and_repaired() {
  local expected_category="$1"
  local description="$2"
  run_verify local
  [[ "$STATUS" -ne 0 ]] || fail "verification accepted $description"
  grep -q "$expected_category" "$TMP/stderr" ||
    fail "$description did not produce $expected_category: $(tr '\n' ' ' < "$TMP/stderr")"
  run_bootstrap
  [[ "$STATUS" -eq 0 ]] || fail "bootstrap did not repair $description: $(tr '\n' ' ' < "$TMP/stderr")"
  diff -r "$ARCHIVE_SETTING_PRESETS" "$INSTALLED_SETTING_PRESETS" >/dev/null ||
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
[[ "$STATUS" -ne 0 ]] || fail 'bootstrap accepted release binary hash drift'
grep -q 'release-binary-hash-mismatch' "$TMP/stderr" || fail 'release binary drift diagnostic was not stable'
[[ ! -e "$FIXTURE/Tools/bin/xcodegen" ]] || fail 'release binary drift installed a binary'
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

OUTSIDE_ARCHIVE="$TMP/outside.zip"
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
[[ "$STATUS" -ne 0 ]] || fail 'test mode accepted a release archive outside the fixture repository'
grep -q 'invalid-test-source' "$TMP/stderr" || fail 'outside-source diagnostic was not stable'

set_lock_artifact_hashes() {
  local archive_sha="$1"
  local binary_sha="${2:-$BINARY_SHA}"
  local presets_sha="${3:-$SETTING_PRESETS_SHA}"
  /usr/bin/python3 -I - \
    "$FIXTURE/Config/ci-toolchain.json" \
    "$archive_sha" \
    "$binary_sha" \
    "$presets_sha" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["xcodegen"]["archiveSHA256"] = sys.argv[2]
value["xcodegen"]["binarySHA256"] = sys.argv[3]
value["xcodegen"]["settingPresetsSHA256"] = sys.argv[4]
path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

assert_unsafe_archive_rejected() {
  local candidate="$1"
  local description="$2"
  local saved_archive="$ARCHIVE"
  local candidate_sha
  candidate_sha="$(/usr/bin/shasum -a 256 "$candidate" | /usr/bin/awk '{print $1}')"
  set_lock_artifact_hashes "$candidate_sha"
  ARCHIVE="$candidate"
  rm -rf "$FIXTURE/Tools"
  run_bootstrap
  [[ "$STATUS" -ne 0 ]] || fail "bootstrap accepted $description"
  grep -q 'unsafe-release-archive' "$TMP/stderr" ||
    fail "$description did not produce unsafe-release-archive: $(tr '\n' ' ' < "$TMP/stderr")"
  [[ ! -e "$FIXTURE/Tools/bin/xcodegen" ]] || fail "$description installed a binary"
  [[ ! -e "$FIXTURE/Tools/bin/XcodeGen_XcodeGenKit.bundle" ]] || fail "$description installed resources"
  ARCHIVE="$saved_archive"
  /bin/cp "$TMP/original-lock.json" "$FIXTURE/Config/ci-toolchain.json"
}

SYMLINK_ARCHIVE="$FIXTURE/FixtureArchive/symlink.zip"
/bin/cp "$ARCHIVE" "$SYMLINK_ARCHIVE"
/usr/bin/python3 -I - "$SYMLINK_ARCHIVE" <<'PY'
import stat
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], mode="a") as archive:
    info = zipfile.ZipInfo("xcodegen/share/xcodegen/SettingPresets/symlink.yml")
    info.create_system = 3
    info.external_attr = (stat.S_IFLNK | 0o777) << 16
    archive.writestr(info, b"base.yml")
PY
assert_unsafe_archive_rejected "$SYMLINK_ARCHIVE" 'a symlinked release resource'

TRAVERSAL_ARCHIVE="$FIXTURE/FixtureArchive/traversal.zip"
/bin/cp "$ARCHIVE" "$TRAVERSAL_ARCHIVE"
/usr/bin/python3 -I - "$TRAVERSAL_ARCHIVE" <<'PY'
import stat
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], mode="a") as archive:
    info = zipfile.ZipInfo("xcodegen/share/xcodegen/SettingPresets/../../../../escape")
    info.create_system = 3
    info.external_attr = (stat.S_IFREG | 0o644) << 16
    archive.writestr(info, b"escape")
PY
assert_unsafe_archive_rejected "$TRAVERSAL_ARCHIVE" 'a path-traversing release member'

DUPLICATE_ARCHIVE="$FIXTURE/FixtureArchive/duplicate.zip"
/bin/cp "$ARCHIVE" "$DUPLICATE_ARCHIVE"
/usr/bin/python3 -I - "$DUPLICATE_ARCHIVE" <<'PY'
import stat
import sys
import warnings
import zipfile

warnings.simplefilter("ignore", UserWarning)
with zipfile.ZipFile(sys.argv[1], mode="a") as archive:
    info = zipfile.ZipInfo("xcodegen/bin/xcodegen")
    info.create_system = 3
    info.external_attr = (stat.S_IFREG | 0o755) << 16
    archive.writestr(info, b"duplicate")
PY
assert_unsafe_archive_rejected "$DUPLICATE_ARCHIVE" 'a duplicate release member'

printf 'drifted archive preset\n' > "$ARCHIVE_SETTING_PRESETS/Platforms/macOS.yml"
PRESET_DRIFT_ARCHIVE="$FIXTURE/FixtureArchive/preset-drift.zip"
build_archive "$PRESET_DRIFT_ARCHIVE"
set_lock_artifact_hashes "$(/usr/bin/shasum -a 256 "$PRESET_DRIFT_ARCHIVE" | /usr/bin/awk '{print $1}')"
ARCHIVE="$PRESET_DRIFT_ARCHIVE"
rm -rf "$FIXTURE/Tools"
run_bootstrap
[[ "$STATUS" -ne 0 ]] || fail 'bootstrap accepted a drifted archived setting preset'
grep -q 'release-setting-presets-hash-mismatch' "$TMP/stderr" ||
  fail "archived preset drift diagnostic was not stable: $(tr '\n' ' ' < "$TMP/stderr")"
[[ ! -e "$FIXTURE/Tools/bin/xcodegen" ]] || fail 'archived preset drift installed a binary'
printf 'SUPPORTED_PLATFORMS: macosx\n' > "$ARCHIVE_SETTING_PRESETS/Platforms/macOS.yml"
/bin/cp "$TMP/original-lock.json" "$FIXTURE/Config/ci-toolchain.json"
ARCHIVE="$FIXTURE/FixtureArchive/xcodegen.zip"

/bin/cp "$FIXTURE/FixtureBinary/xcodegen" "$TMP/fixture-binary.original"
cat > "$ARCHIVE_ROOT/bin/xcodegen" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ "${1-}" == '--version' ]] || exit 64
printf 'Version: 9.9.9\n'
EOF
chmod 0755 "$ARCHIVE_ROOT/bin/xcodegen"
WRONG_VERSION_ARCHIVE="$FIXTURE/FixtureArchive/wrong-version.zip"
build_archive "$WRONG_VERSION_ARCHIVE"
WRONG_VERSION_BINARY_SHA="$(/usr/bin/shasum -a 256 "$ARCHIVE_ROOT/bin/xcodegen" | /usr/bin/awk '{print $1}')"
set_lock_artifact_hashes \
  "$(/usr/bin/shasum -a 256 "$WRONG_VERSION_ARCHIVE" | /usr/bin/awk '{print $1}')" \
  "$WRONG_VERSION_BINARY_SHA"
ARCHIVE="$WRONG_VERSION_ARCHIVE"
rm -rf "$FIXTURE/Tools"
run_bootstrap
[[ "$STATUS" -ne 0 ]] || fail 'bootstrap accepted the wrong release binary version'
grep -q 'release-binary-version-mismatch' "$TMP/stderr" ||
  fail "release binary version diagnostic was not stable: $(tr '\n' ' ' < "$TMP/stderr")"
[[ ! -e "$FIXTURE/Tools/bin/xcodegen" ]] || fail 'wrong release binary version was installed'

cat > "$ARCHIVE_ROOT/bin/xcodegen" <<'EOF'
#!/bin/bash
# UTTERINK_WRONG_ARCH_FIXTURE
set -euo pipefail
[[ "${1-}" == '--version' ]] || exit 64
printf 'Version: 2.45.4\n'
EOF
chmod 0755 "$ARCHIVE_ROOT/bin/xcodegen"
WRONG_ARCH_ARCHIVE="$FIXTURE/FixtureArchive/wrong-arch.zip"
build_archive "$WRONG_ARCH_ARCHIVE"
WRONG_ARCH_BINARY_SHA="$(/usr/bin/shasum -a 256 "$ARCHIVE_ROOT/bin/xcodegen" | /usr/bin/awk '{print $1}')"
set_lock_artifact_hashes \
  "$(/usr/bin/shasum -a 256 "$WRONG_ARCH_ARCHIVE" | /usr/bin/awk '{print $1}')" \
  "$WRONG_ARCH_BINARY_SHA"
ARCHIVE="$WRONG_ARCH_ARCHIVE"
rm -rf "$FIXTURE/Tools"
run_bootstrap
[[ "$STATUS" -ne 0 ]] || fail 'bootstrap accepted the wrong release binary architecture set'
grep -q 'release-binary-architecture-mismatch' "$TMP/stderr" ||
  fail "release binary architecture diagnostic was not stable: $(tr '\n' ' ' < "$TMP/stderr")"
[[ ! -e "$FIXTURE/Tools/bin/xcodegen" ]] || fail 'wrong release binary architecture was installed'

/bin/cp "$TMP/fixture-binary.original" "$ARCHIVE_ROOT/bin/xcodegen"
chmod 0755 "$ARCHIVE_ROOT/bin/xcodegen"
/bin/cp "$TMP/original-lock.json" "$FIXTURE/Config/ci-toolchain.json"
ARCHIVE="$FIXTURE/FixtureArchive/xcodegen.zip"
run_bootstrap
[[ "$STATUS" -eq 0 ]] || fail "final valid release bootstrap failed: $(tr '\n' ' ' < "$TMP/stderr")"
[[ "$(/usr/bin/shasum -a 256 "$FIXTURE/Tools/bin/xcodegen" | /usr/bin/awk '{print $1}')" == "$BINARY_SHA" ]] ||
  fail 'final valid release bootstrap installed the wrong binary'

printf 'XcodeGen bootstrap tests passed\n'
