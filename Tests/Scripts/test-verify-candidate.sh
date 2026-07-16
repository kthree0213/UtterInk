#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERIFIER="$ROOT/Scripts/release/verify-candidate.sh"

fail() {
  printf 'release candidate tests failed: %s\n' "$1" >&2
  exit 1
}

if [[ ! -f "$VERIFIER" ]]; then
  fail 'verifier does not exist: Scripts/release/verify-candidate.sh'
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/utterink-candidate-tests.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
BASE="$TMP/base"
mkdir -p "$BASE"

python3 - "$BASE" "$VERIFIER" "$ROOT/docs/release/evidence-schema.json" <<'PY'
from __future__ import annotations

import json
from pathlib import Path
import shutil
import sys

root = Path(sys.argv[1])
verifier = Path(sys.argv[2])
schema = Path(sys.argv[3])


def write(relative: str, value: str, executable: bool = False) -> None:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value, encoding="utf-8")
    if executable:
        path.chmod(0o755)


destination = root / "Scripts/release/verify-candidate.sh"
destination.parent.mkdir(parents=True, exist_ok=True)
shutil.copyfile(verifier, destination)
destination.chmod(0o755)
(root / "docs/release").mkdir(parents=True, exist_ok=True)
shutil.copyfile(schema, root / "docs/release/evidence-schema.json")
test_schema_path = root / "docs/release/evidence-schema.json"
test_schema = json.loads(test_schema_path.read_text(encoding="utf-8"))
test_schema["properties"]["evidenceType"]["const"] = "release-candidate-test"
test_schema_path.write_text(json.dumps(test_schema, indent=2) + "\n", encoding="utf-8")

write(
    "Scripts/release/read-metadata.py",
    """#!/usr/bin/env python3
import json
print(json.dumps({
    \"product\": \"UtterInk\",
    \"marketingVersion\": \"0.1.0\",
    \"buildNumber\": \"1\",
    \"bundleIdentifier\": \"dev.utterink.UtterInk\",
    \"deploymentTarget\": \"14.0\",
    \"architecture\": \"arm64\",
    \"configuration\": \"Release\",
    \"dmgFilename\": \"UtterInk-0.1.0-arm64.dmg\",
    \"releaseTag\": \"v0.1.0\",
}, sort_keys=True, separators=(\",\", \":\")))
""",
    executable=True,
)
write(
    "Scripts/scan-public-history.sh",
    """#!/usr/bin/env bash
set -euo pipefail
[[ \"$(command -v git)\" == '/usr/bin/git' ]]
[[ -z \"${BASH_ENV-}\" ]]
printf 'history:%s\\n' \"$*\" >> \"${UTTERINK_FIXTURE_LOG:?}\"
""",
    executable=True,
)
write(
    "Scripts/release/verify-entitlements.py",
    """#!/usr/bin/env python3
import os
from pathlib import Path
with Path(os.environ[\"UTTERINK_FIXTURE_LOG\"]).open(\"a\", encoding=\"utf-8\") as handle:
    handle.write(\"entitlements\\n\")
""",
    executable=True,
)
write(
    "Scripts/release/verify-info-policy.py",
    """#!/usr/bin/env python3
import os
from pathlib import Path
with Path(os.environ[\"UTTERINK_FIXTURE_LOG\"]).open(\"a\", encoding=\"utf-8\") as handle:
    handle.write(\"info-policy\\n\")
print(\"release Info policy valid\")
""",
    executable=True,
)

write(
    "FixtureTools/xcodebuild",
    """#!/usr/bin/env bash
set -euo pipefail
printf 'xcodebuild:%s\\n' \"$*\" >> \"${UTTERINK_FIXTURE_LOG:?}\"
case \" $* \" in
  *' -showBuildSettings '*)
    version=0.1.0
    if [[ -f .fixture-metadata-mismatch ]]; then version=0.1.1; fi
    if [[ ! -f .fixture-headerless-settings ]]; then
      printf '%s\\n' 'Build settings for action build and target UtterInk:'
    fi
    printf '%s\\n' \\
      '    ARCHS = arm64' \\
      '    CURRENT_PROJECT_VERSION = 1' \\
      '    ENABLE_HARDENED_RUNTIME = YES' \\
      '    MACOSX_DEPLOYMENT_TARGET = 14.0' \\
      \"    MARKETING_VERSION = $version\" \\
      '    ONLY_ACTIVE_ARCH = NO' \\
      '    PRODUCT_BUNDLE_IDENTIFIER = dev.utterink.UtterInk' \\
      '    SWIFT_VERSION = 5.0'
    ;;
  *' -version -sdk macosx ProductBuildVersion '*) printf '25E999\\n' ;;
  *' -version -sdk macosx SDKVersion '*) printf '26.4\\n' ;;
  *' -version '*) printf 'Xcode 26.4.1\\nBuild version 17E202\\n' ;;
  *' -resolvePackageDependencies '*)
    destination=''
    previous=''
    for argument in \"$@\"; do
      if [[ \"$previous\" == '-clonedSourcePackagesDirPath' ]]; then destination=\"$argument\"; fi
      previous=\"$argument\"
    done
    [[ -n \"$destination\" ]]
    /bin/mkdir -p \"$destination\"
    /bin/cp FixtureTools/workspace-state.json \"$destination/workspace-state.json\"
    ;;
esac
""",
    executable=True,
)
write(
    "FixtureTools/swift",
    """#!/usr/bin/env bash
set -euo pipefail
printf 'swift:%s\\n' \"$*\" >> \"${UTTERINK_FIXTURE_LOG:?}\"
if [[ \"${1-}\" == '--version' ]]; then
  printf '%s\\n' \\
    'swift-driver version: 1.148.6 Apple Swift version 6.3.1 (swiftlang-6.3.1.1.2 clang-2100.0.123.102)' \\
    'Target: arm64-apple-macosx26.0'
fi
""",
    executable=True,
)
write(
    "FixtureTools/xcodegen",
    """#!/usr/bin/env bash
set -euo pipefail
printf 'xcodegen:%s\\n' \"$*\" >> \"${UTTERINK_FIXTURE_LOG:?}\"
xcodegen_directory=\"$(cd \"$(/usr/bin/dirname \"$0\")\" && /bin/pwd -P)\"
[[ -f \"$xcodegen_directory/XcodeGen_XcodeGenKit.bundle/SettingPresets/Base.json\" ]]
[[ -f \"$xcodegen_directory/XcodeGen_XcodeGenKit.bundle/SettingPresets/Platforms/macOS.json\" ]]
if [[ \"${1-}\" == '--version' ]]; then
  printf 'Version: 2.45.4\\n'
fi
""",
    executable=True,
)
write(
    "FixtureTools/XcodeGen_XcodeGenKit.bundle/SettingPresets/Base.json",
    '{"fixture":"base"}\n',
)
write(
    "FixtureTools/XcodeGen_XcodeGenKit.bundle/SettingPresets/Platforms/macOS.json",
    '{"fixture":"macOS"}\n',
)
write(
    "FixtureTools/workspace-state.json",
    '{"object":{"artifacts":[],"dependencies":[],"prebuilts":[]},"version":7}\n',
)

write("Config/release-metadata.json", '{"schemaVersion":1}\n')
write("Config/release-entitlements.json", '{"schemaVersion":1}\n')
write("Config/release-info-policy.json", '{"schemaVersion":1}\n')
write(
    "App/Supporting/UtterInk.entitlements",
    """<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>com.apple.security.device.audio-input</key><true/>
</dict></plist>
""",
)
write("App/Supporting/Info.plist", '<?xml version="1.0"?><plist version="1.0"><dict/></plist>\n')
write("Tests/ATSPolicyProbe/Info.plist", '<?xml version="1.0"?><plist version="1.0"><dict/></plist>\n')
write("Packages/UtterInkKit/Package.resolved", '{"pins":[],"version":2}\n')
write("Packages/UtterInkKit/Package.swift", "// swift-tools-version: 6.0\n")
write("project.yml", "name: UtterInk\n")
write("UtterInk.xcodeproj/project.pbxproj", "// fixture\n")
write("UtterInk.xcodeproj/project.xcworkspace/contents.xcworkspacedata", "// fixture workspace\n")
write("UtterInk.xcodeproj/xcshareddata/xcschemes/UtterInk.xcscheme", "<!-- fixture scheme -->\n")
write("Scripts/ordinary-executable.sh", "#!/bin/bash\nexit 0\n", executable=True)
PY

XCODEGEN_HASH="$(/usr/bin/shasum -a 256 "$BASE/FixtureTools/xcodegen" | awk '{print $1}')"
SETTING_PRESETS_ROOT="$BASE/FixtureTools/XcodeGen_XcodeGenKit.bundle/SettingPresets"
python3 - "$BASE/Config/ci-toolchain.json" "$XCODEGEN_HASH" "$SETTING_PRESETS_ROOT" <<'PY'
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
presets_digest = hashlib.sha256()
for relative, content in items:
    presets_digest.update(struct.pack(">Q", len(relative)))
    presets_digest.update(relative)
    presets_digest.update(struct.pack(">Q", len(content)))
    presets_digest.update(content)
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
    "swift": {
        "version": "swift-driver version: 1.148.6 Apple Swift version 6.3.1 (swiftlang-6.3.1.1.2 clang-2100.0.123.102)"
    },
    "xcodegen": {
        "version": "2.45.4",
        "sourceCommit": "8d3d3476a69ae3e5d68e1adccc701c410c05eb36",
        "archiveURL": "https://github.com/yonaskolb/XcodeGen/archive/8d3d3476a69ae3e5d68e1adccc701c410c05eb36.tar.gz",
        "archiveSHA256": "afe64a4e9b14a91a113ae7bd2c156666ee9be51dfa84c9a6e89c89797e5d871c",
        "binarySHA256": binary_hash,
        "settingPresetsSHA256": presets_digest.hexdigest(),
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

git -C "$BASE" init -q
git -C "$BASE" config user.name 'UtterInk Test'
git -C "$BASE" config user.email 'utterink-test@example.invalid'
git -C "$BASE" add .
git -C "$BASE" commit -q -m fixture

BASH_ENV_CANARY="$TMP/hostile-bash-env"
BASH_ENV_MARKER="$TMP/bash-env-loaded"
BASH_FUNCTION_MARKER="$TMP/bash-function-loaded"
PERL_CANARY_ROOT="$TMP/perl-canary"
PERL_MARKER="$TMP/perl-env-loaded"
mkdir -p "$PERL_CANARY_ROOT"
printf 'printf loaded > %q\n' "$BASH_ENV_MARKER" > "$BASH_ENV_CANARY"
cat > "$PERL_CANARY_ROOT/UtterInkCandidateCanary.pm" <<EOF
package UtterInkCandidateCanary;
BEGIN {
    open my \$handle, '>>', '$PERL_MARKER' or die \$!;
    print {\$handle} "loaded\\n";
    close \$handle or die \$!;
}
1;
EOF

run_candidate() {
  local repository="$1"
  local output="$2"
  local commit="$3"
  shift 3
  local log="$TMP/fixture.log"
  : > "$log"
  set +e
  (
    cd "$repository"
    env \
      UTTERINK_RELEASE_TEST_MODE=1 \
      UTTERINK_RELEASE_TEST_TOOL_ROOT="$repository/FixtureTools" \
      UTTERINK_FIXTURE_LOG="$log" \
      BASH_ENV="$BASH_ENV_CANARY" \
      SHELLOPTS=xtrace \
      BASHOPTS=extdebug \
      BASH_XTRACEFD=2 \
      PS4='candidate-xtrace-canary ' \
      "BASH_FUNC_printf%%=() { builtin echo loaded > '$BASH_FUNCTION_MARKER'; builtin printf \"\$@\"; }" \
      PERL5LIB="$PERL_CANARY_ROOT" \
      PERL5OPT=-MUtterInkCandidateCanary \
      ./Scripts/release/verify-candidate.sh \
        --commit "$commit" \
        --output "$output" \
        "$@"
  ) > "$TMP/stdout" 2> "$TMP/stderr"
  CANDIDATE_STATUS=$?
  set -e
}

run_candidate_with_output_fd() {
  local repository="$1"
  local output="$2"
  local descriptor_path="$3"
  local commit="$4"
  shift 4
  local log="$TMP/fixture.log"
  : > "$log"
  set +e
  (
    cd "$repository"
    exec 9< "$descriptor_path"
    env \
      UTTERINK_RELEASE_TEST_MODE=1 \
      UTTERINK_RELEASE_TEST_TOOL_ROOT="$repository/FixtureTools" \
      UTTERINK_FIXTURE_LOG="$log" \
      ./Scripts/release/verify-candidate.sh \
        --commit "$commit" \
        --output "$output" \
        --output-dir-fd 9 \
        "$@"
  ) > "$TMP/stdout" 2> "$TMP/stderr"
  CANDIDATE_STATUS=$?
  set -e
}

expect_failure() {
  local repository="$1"
  local expected_status="$2"
  local expected_category="$3"
  local commit="$4"
  local output="$TMP/output-$expected_category"
  run_candidate "$repository" "$output" "$commit"
  if [[ "$CANDIDATE_STATUS" -ne "$expected_status" ]]; then
    fail "$expected_category returned $CANDIDATE_STATUS, expected $expected_status"
  fi
  if [[ -s "$TMP/stdout" ]]; then
    fail "$expected_category wrote to stdout"
  fi
  if [[ "$(cat "$TMP/stderr")" != "release candidate error: $expected_category" ]]; then
    fail "$expected_category emitted a non-sanitized diagnostic: $(tr '\n' ' ' < "$TMP/stderr")"
  fi
  if [[ -e "$output/candidate.json" || -L "$output/candidate.json" ]]; then
    fail "$expected_category emitted candidate.json"
  fi
}

BASE_COMMIT="$(git -C "$BASE" rev-parse HEAD)"
printf 'dirty\n' > "$BASE/dirty.txt"
expect_failure "$BASE" 20 dirty-checkout "$BASE_COMMIT"
rm "$BASE/dirty.txt"

expect_failure "$BASE" 21 commit-mismatch '0000000000000000000000000000000000000000'

EXISTING_COMMIT_MISMATCH="$TMP/existing-commit-mismatch"
git clone -q "$BASE" "$EXISTING_COMMIT_MISMATCH"
git -C "$EXISTING_COMMIT_MISMATCH" config user.name 'UtterInk Test'
git -C "$EXISTING_COMMIT_MISMATCH" config user.email 'utterink-test@example.invalid'
printf 'second commit\n' > "$EXISTING_COMMIT_MISMATCH/second-commit.txt"
git -C "$EXISTING_COMMIT_MISMATCH" add second-commit.txt
git -C "$EXISTING_COMMIT_MISMATCH" commit -q -m 'second fixture commit'
expect_failure "$EXISTING_COMMIT_MISMATCH" 21 commit-mismatch "$BASE_COMMIT"

TAG_OBJECT="$TMP/tag-object"
git clone -q "$BASE" "$TAG_OBJECT"
git -C "$TAG_OBJECT" config user.name 'UtterInk Test'
git -C "$TAG_OBJECT" config user.email 'utterink-test@example.invalid'
git -C "$TAG_OBJECT" tag -a candidate-tag -m 'candidate tag object'
TAG_OBJECT_ID="$(git -C "$TAG_OBJECT" rev-parse candidate-tag)"
printf '%s\n' "$TAG_OBJECT_ID" > "$TAG_OBJECT/.git/HEAD"
expect_failure "$TAG_OBJECT" 21 commit-mismatch "$TAG_OBJECT_ID"

GC_AUTO_ZERO="$TMP/gc-auto-zero"
GC_AUTO_ZERO_OUTPUT="$TMP/gc-auto-zero-output"
git clone -q "$BASE" "$GC_AUTO_ZERO"
git -C "$GC_AUTO_ZERO" config gc.auto 0
mkdir -p "$GC_AUTO_ZERO_OUTPUT"
run_candidate "$GC_AUTO_ZERO" "$GC_AUTO_ZERO_OUTPUT" "$(git -C "$GC_AUTO_ZERO" rev-parse HEAD)"
if [[ "$CANDIDATE_STATUS" -ne 0 || -s "$TMP/stdout" || -s "$TMP/stderr" ||
  ! -f "$GC_AUTO_ZERO_OUTPUT/candidate.json" ]]; then
  fail 'actions/checkout gc.auto=0 config was not accepted exactly'
fi

CHECKOUT_WORKTREE_CONFIG="$TMP/checkout-worktree-config"
CHECKOUT_WORKTREE_CONFIG_OUTPUT="$TMP/checkout-worktree-config-output"
git clone -q "$BASE" "$CHECKOUT_WORKTREE_CONFIG"
git -C "$CHECKOUT_WORKTREE_CONFIG" config gc.auto 0
git -C "$CHECKOUT_WORKTREE_CONFIG" config extensions.worktreeConfig true
git -C "$CHECKOUT_WORKTREE_CONFIG" sparse-checkout disable
git -C "$CHECKOUT_WORKTREE_CONFIG" config --local --unset-all extensions.worktreeConfig
mkdir -p "$CHECKOUT_WORKTREE_CONFIG_OUTPUT"
run_candidate \
  "$CHECKOUT_WORKTREE_CONFIG" \
  "$CHECKOUT_WORKTREE_CONFIG_OUTPUT" \
  "$(git -C "$CHECKOUT_WORKTREE_CONFIG" rev-parse HEAD)"
if [[ "$CANDIDATE_STATUS" -ne 0 || -s "$TMP/stdout" || -s "$TMP/stderr" ||
  ! -f "$CHECKOUT_WORKTREE_CONFIG_OUTPUT/candidate.json" ]]; then
  fail 'actions/checkout sparse-worktree cleanup config was not accepted exactly'
fi

WORKTREE_CONFIG_DRIFT="$TMP/worktree-config-drift"
git clone -q "$BASE" "$WORKTREE_CONFIG_DRIFT"
git -C "$WORKTREE_CONFIG_DRIFT" config extensions.worktreeConfig true
git -C "$WORKTREE_CONFIG_DRIFT" sparse-checkout disable
git -C "$WORKTREE_CONFIG_DRIFT" config --local --unset-all extensions.worktreeConfig
git -C "$WORKTREE_CONFIG_DRIFT" config --file .git/config.worktree index.sparse true
expect_failure \
  "$WORKTREE_CONFIG_DRIFT" \
  20 \
  unsafe-git-config \
  "$(git -C "$WORKTREE_CONFIG_DRIFT" rev-parse HEAD)"

WORKTREE_CONFIG_SYMLINK="$TMP/worktree-config-symlink"
git clone -q "$BASE" "$WORKTREE_CONFIG_SYMLINK"
ln -s /dev/null "$WORKTREE_CONFIG_SYMLINK/.git/config.worktree"
expect_failure \
  "$WORKTREE_CONFIG_SYMLINK" \
  20 \
  unsafe-git-config \
  "$(git -C "$WORKTREE_CONFIG_SYMLINK" rev-parse HEAD)"

GC_AUTO_WRONG="$TMP/gc-auto-wrong"
git clone -q "$BASE" "$GC_AUTO_WRONG"
git -C "$GC_AUTO_WRONG" config gc.auto 1
expect_failure "$GC_AUTO_WRONG" 20 unsafe-git-config "$(git -C "$GC_AUTO_WRONG" rev-parse HEAD)"

GC_AUTO_DUPLICATE="$TMP/gc-auto-duplicate"
git clone -q "$BASE" "$GC_AUTO_DUPLICATE"
git -C "$GC_AUTO_DUPLICATE" config gc.auto 0
git -C "$GC_AUTO_DUPLICATE" config --add gc.auto 0
expect_failure "$GC_AUTO_DUPLICATE" 20 unsafe-git-config "$(git -C "$GC_AUTO_DUPLICATE" rev-parse HEAD)"

UNSAFE_CONFIG="$TMP/unsafe-git-config"
UNSAFE_CONFIG_MARKER="$TMP/unsafe-git-config-executed"
git clone -q "$BASE" "$UNSAFE_CONFIG"
git -C "$UNSAFE_CONFIG" config core.fsmonitor "$UNSAFE_CONFIG_MARKER"
expect_failure "$UNSAFE_CONFIG" 20 unsafe-git-config "$(git -C "$UNSAFE_CONFIG" rev-parse HEAD)"
if [[ -e "$UNSAFE_CONFIG_MARKER" ]]; then
  fail 'unsafe repository config executed before rejection'
fi

MODE_DRIFT="$TMP/executable-mode-drift"
git clone -q "$BASE" "$MODE_DRIFT"
git -C "$MODE_DRIFT" config core.filemode false
chmod 0401 "$MODE_DRIFT/Scripts/ordinary-executable.sh"
expect_failure "$MODE_DRIFT" 20 dirty-checkout "$(git -C "$MODE_DRIFT" rev-parse HEAD)"

SKIP_WORKTREE="$TMP/skip-worktree"
git clone -q "$BASE" "$SKIP_WORKTREE"
git -C "$SKIP_WORKTREE" update-index --skip-worktree Config/release-metadata.json
printf '{"hidden":"replacement"}\n' > "$SKIP_WORKTREE/Config/release-metadata.json"
expect_failure "$SKIP_WORKTREE" 20 dirty-checkout "$(git -C "$SKIP_WORKTREE" rev-parse HEAD)"

ASSUME_UNCHANGED="$TMP/assume-unchanged"
git clone -q "$BASE" "$ASSUME_UNCHANGED"
git -C "$ASSUME_UNCHANGED" update-index --assume-unchanged Config/release-metadata.json
printf '{"hidden":"replacement"}\n' > "$ASSUME_UNCHANGED/Config/release-metadata.json"
expect_failure "$ASSUME_UNCHANGED" 20 dirty-checkout "$(git -C "$ASSUME_UNCHANGED" rev-parse HEAD)"

LOCK_DRIFT="$TMP/lock-drift"
git clone -q "$BASE" "$LOCK_DRIFT"
git -C "$LOCK_DRIFT" config user.name 'UtterInk Test'
git -C "$LOCK_DRIFT" config user.email 'utterink-test@example.invalid'
python3 - "$LOCK_DRIFT/Config/ci-toolchain.json" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["runnerImage"]["commit"] = "0" * 40
path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
git -C "$LOCK_DRIFT" add Config/ci-toolchain.json
git -C "$LOCK_DRIFT" commit -q -m 'drift official toolchain source'
expect_failure "$LOCK_DRIFT" 24 toolchain-lock-invalid "$(git -C "$LOCK_DRIFT" rev-parse HEAD)"

MISSING_LOCK="$TMP/missing-toolchain-lock"
git clone -q "$BASE" "$MISSING_LOCK"
git -C "$MISSING_LOCK" config user.name 'UtterInk Test'
git -C "$MISSING_LOCK" config user.email 'utterink-test@example.invalid'
git -C "$MISSING_LOCK" rm -q Config/ci-toolchain.json
git -C "$MISSING_LOCK" commit -q -m 'remove toolchain lock'
expect_failure "$MISSING_LOCK" 24 toolchain-lock-missing "$(git -C "$MISSING_LOCK" rev-parse HEAD)"

IGNORED_REQUIRED="$TMP/ignored-required"
git clone -q "$BASE" "$IGNORED_REQUIRED"
git -C "$IGNORED_REQUIRED" config user.name 'UtterInk Test'
git -C "$IGNORED_REQUIRED" config user.email 'utterink-test@example.invalid'
git -C "$IGNORED_REQUIRED" rm -q Config/release-metadata.json
printf 'Config/release-metadata.json\n' >> "$IGNORED_REQUIRED/.gitignore"
git -C "$IGNORED_REQUIRED" add .gitignore
git -C "$IGNORED_REQUIRED" commit -q -m 'remove required metadata'
printf '{"schemaVersion":1}\n' > "$IGNORED_REQUIRED/Config/release-metadata.json"
expect_failure "$IGNORED_REQUIRED" 1 required-input-mismatch "$(git -C "$IGNORED_REQUIRED" rev-parse HEAD)"

MISSING="$TMP/missing-package"
git clone -q "$BASE" "$MISSING"
git -C "$MISSING" config user.name 'UtterInk Test'
git -C "$MISSING" config user.email 'utterink-test@example.invalid'
git -C "$MISSING" rm -q Packages/UtterInkKit/Package.resolved
git -C "$MISSING" commit -q -m 'remove package lock'
expect_failure "$MISSING" 22 missing-package-resolution "$(git -C "$MISSING" rev-parse HEAD)"

MISMATCH="$TMP/metadata-mismatch"
git clone -q "$BASE" "$MISMATCH"
git -C "$MISMATCH" config user.name 'UtterInk Test'
git -C "$MISMATCH" config user.email 'utterink-test@example.invalid'
printf 'mismatch\n' > "$MISMATCH/.fixture-metadata-mismatch"
git -C "$MISMATCH" add .fixture-metadata-mismatch
git -C "$MISMATCH" commit -q -m 'drift effective metadata'
expect_failure "$MISMATCH" 23 metadata-mismatch "$(git -C "$MISMATCH" rev-parse HEAD)"

HEADERLESS="$TMP/headerless-settings"
git clone -q "$BASE" "$HEADERLESS"
git -C "$HEADERLESS" config user.name 'UtterInk Test'
git -C "$HEADERLESS" config user.email 'utterink-test@example.invalid'
printf 'headerless\n' > "$HEADERLESS/.fixture-headerless-settings"
git -C "$HEADERLESS" add .fixture-headerless-settings
git -C "$HEADERLESS" commit -q -m 'remove build settings target identity'
expect_failure "$HEADERLESS" 23 metadata-mismatch "$(git -C "$HEADERLESS" rev-parse HEAD)"

ENTITLEMENT_FAILURE="$TMP/entitlement-policy-failure"
git clone -q "$BASE" "$ENTITLEMENT_FAILURE"
git -C "$ENTITLEMENT_FAILURE" config user.name 'UtterInk Test'
git -C "$ENTITLEMENT_FAILURE" config user.email 'utterink-test@example.invalid'
printf '#!/usr/bin/env python3\nraise SystemExit(1)\n' > "$ENTITLEMENT_FAILURE/Scripts/release/verify-entitlements.py"
git -C "$ENTITLEMENT_FAILURE" add Scripts/release/verify-entitlements.py
git -C "$ENTITLEMENT_FAILURE" commit -q -m 'fail entitlement policy'
expect_failure "$ENTITLEMENT_FAILURE" 26 entitlement-policy-failed "$(git -C "$ENTITLEMENT_FAILURE" rev-parse HEAD)"

INFO_POLICY_FAILURE="$TMP/info-policy-failure"
git clone -q "$BASE" "$INFO_POLICY_FAILURE"
git -C "$INFO_POLICY_FAILURE" config user.name 'UtterInk Test'
git -C "$INFO_POLICY_FAILURE" config user.email 'utterink-test@example.invalid'
printf '#!/usr/bin/env python3\nraise SystemExit(1)\n' > "$INFO_POLICY_FAILURE/Scripts/release/verify-info-policy.py"
git -C "$INFO_POLICY_FAILURE" add Scripts/release/verify-info-policy.py
git -C "$INFO_POLICY_FAILURE" commit -q -m 'fail Info policy'
expect_failure "$INFO_POLICY_FAILURE" 26 info-policy-failed "$(git -C "$INFO_POLICY_FAILURE" rev-parse HEAD)"

HELPER_SWAP="$TMP/helper-swap-restore"
git clone -q "$BASE" "$HELPER_SWAP"
git -C "$HELPER_SWAP" config user.name 'UtterInk Test'
git -C "$HELPER_SWAP" config user.email 'utterink-test@example.invalid'
cat > "$HELPER_SWAP/Scripts/release/read-metadata.py" <<'PY'
#!/usr/bin/env python3
import json
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[2]
target = root / "Scripts/release/verify-entitlements.py"
original = target.with_name("verify-entitlements.original")
target.rename(original)
target.write_text("#!/usr/bin/env python3\nraise SystemExit(97)\n", encoding="utf-8")
target.chmod(0o755)
restorer = r'''
from pathlib import Path
import sys
import time
time.sleep(0.5)
target = Path(sys.argv[1])
original = Path(sys.argv[2])
target.unlink()
original.rename(target)
'''
subprocess.Popen(
    ["/usr/bin/python3", "-I", "-c", restorer, str(target), str(original)],
    close_fds=True,
    start_new_session=True,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
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
PY
chmod 0755 "$HELPER_SWAP/Scripts/release/read-metadata.py"
git -C "$HELPER_SWAP" add Scripts/release/read-metadata.py
git -C "$HELPER_SWAP" commit -q -m 'transiently replace tracked helper'
expect_failure "$HELPER_SWAP" 1 required-input-mismatch "$(git -C "$HELPER_SWAP" rev-parse HEAD)"
for _ in {1..200}; do
  [[ ! -e "$HELPER_SWAP/Scripts/release/verify-entitlements.original" ]] && break
  /bin/sleep 0.01
done
[[ ! -e "$HELPER_SWAP/Scripts/release/verify-entitlements.original" ]] || fail 'transient helper replacement was not restored'
git -C "$HELPER_SWAP" diff --quiet -- Scripts/release/verify-entitlements.py || fail 'transient helper replacement changed restored content'

TMP_NAME_REBIND="$TMP/tmp-name-rebind-repository"
TMP_NAME_REBIND_MARKER="$TMP/tmp-name-rebind-record"
git clone -q "$BASE" "$TMP_NAME_REBIND"
git -C "$TMP_NAME_REBIND" config user.name 'UtterInk Test'
git -C "$TMP_NAME_REBIND" config user.email 'utterink-test@example.invalid'
python3 - "$TMP_NAME_REBIND/Scripts/release/verify-info-policy.py" "$TMP_NAME_REBIND_MARKER" <<'PY'
from pathlib import Path
import sys

helper = Path(sys.argv[1])
marker = sys.argv[2]
helper.write_text(f'''#!/usr/bin/env python3
import os
from pathlib import Path

temporary = Path(os.environ['TMPDIR']).parent
moved = temporary.with_name(temporary.name + '.held-original')
temporary.rename(moved)
temporary.mkdir(mode=0o700)
(temporary / 'sentinel').write_text('replacement sentinel\\n', encoding='utf-8')
Path({marker!r}).write_text(str(temporary) + '\\n' + str(moved) + '\\n', encoding='utf-8')
with Path(os.environ['UTTERINK_FIXTURE_LOG']).open('a', encoding='utf-8') as handle:
    handle.write('info-policy\\n')
print('release Info policy valid')
''', encoding="utf-8")
helper.chmod(0o755)
PY
git -C "$TMP_NAME_REBIND" add Scripts/release/verify-info-policy.py
git -C "$TMP_NAME_REBIND" commit -q -m 'replace verifier temporary directory name'
run_candidate "$TMP_NAME_REBIND" "$TMP/tmp-name-rebind-output" "$(git -C "$TMP_NAME_REBIND" rev-parse HEAD)"
[[ "$CANDIDATE_STATUS" -ne 0 ]] || fail 'temporary directory name replacement unexpectedly succeeded'
[[ -f "$TMP_NAME_REBIND_MARKER" ]] || fail 'temporary directory name replacement did not run'
TMP_NAME_REPLACEMENT_PATH="$(sed -n '1p' "$TMP_NAME_REBIND_MARKER")"
TMP_NAME_HELD_PATH="$(sed -n '2p' "$TMP_NAME_REBIND_MARKER")"
[[ "$TMP_NAME_REPLACEMENT_PATH" == /tmp/utterink-release-candidate.* ]] || fail 'temporary replacement path was unexpected'
[[ "$TMP_NAME_HELD_PATH" == "$TMP_NAME_REPLACEMENT_PATH.held-original" ]] || fail 'held temporary path was unexpected'
[[ "$(cat "$TMP_NAME_REPLACEMENT_PATH/sentinel")" == 'replacement sentinel' ]] || fail 'held cleanup changed the replacement sentinel'
[[ -d "$TMP_NAME_HELD_PATH" ]] || fail 'renamed held temporary directory disappeared unsafely'
[[ -z "$(find "$TMP_NAME_HELD_PATH" -mindepth 1 -print -quit)" ]] || fail 'held temporary directory was not cleared through its descriptor'
rm -rf "$TMP_NAME_REPLACEMENT_PATH"
rmdir "$TMP_NAME_HELD_PATH"

WORKSPACE_MISMATCH="$TMP/workspace-mismatch"
git clone -q "$BASE" "$WORKSPACE_MISMATCH"
git -C "$WORKSPACE_MISMATCH" config user.name 'UtterInk Test'
git -C "$WORKSPACE_MISMATCH" config user.email 'utterink-test@example.invalid'
printf '%s\n' '{"object":{"artifacts":[],"dependencies":[{"basedOn":null,"packageRef":{"identity":"unexpected","kind":"remoteSourceControl","location":"https://example.invalid/unexpected","name":"unexpected"},"state":{"checkoutState":{"revision":"1111111111111111111111111111111111111111","version":"1.0.0"},"name":"sourceControlCheckout"},"subpath":"unexpected"}],"prebuilts":[]},"version":7}' > "$WORKSPACE_MISMATCH/FixtureTools/workspace-state.json"
git -C "$WORKSPACE_MISMATCH" add FixtureTools/workspace-state.json
git -C "$WORKSPACE_MISMATCH" commit -q -m 'drift workspace resolution'
expect_failure "$WORKSPACE_MISMATCH" 22 package-resolution-mismatch "$(git -C "$WORKSPACE_MISMATCH" rev-parse HEAD)"

expect_schema_failure() {
  local name="$1"
  local mutation="$2"
  local repository="$TMP/schema-$name"
  git clone -q "$BASE" "$repository"
  git -C "$repository" config user.name 'UtterInk Test'
  git -C "$repository" config user.email 'utterink-test@example.invalid'
  python3 - "$repository/docs/release/evidence-schema.json" "$mutation" <<'PY'
from __future__ import annotations

import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
mutation = sys.argv[2]
if mutation == "duplicate":
    text = path.read_text(encoding="utf-8")
    marker = '  "title": "UtterInk release candidate evidence",'
    if text.count(marker) != 1:
        raise SystemExit("schema title marker mismatch")
    path.write_text(text.replace(marker, marker + "\n" + marker, 1), encoding="utf-8")
else:
    value = json.loads(path.read_text(encoding="utf-8"))
    if mutation == "production-boundary":
        value["properties"]["evidenceType"]["const"] = "release-candidate"
    elif mutation == "unknown-keyword":
        value["unevaluatedProperties"] = False
    elif mutation == "open-object":
        value["additionalProperties"] = True
    elif mutation == "const-type":
        value["properties"]["schemaVersion"]["const"] = "1"
    elif mutation == "wrong-dialect":
        value["$schema"] = "http://json-schema.org/draft-07/schema#"
    else:
        raise SystemExit("unknown schema mutation")
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
PY
  git -C "$repository" add docs/release/evidence-schema.json
  git -C "$repository" commit -q -m "mutate schema: $name"
  expect_failure "$repository" 28 evidence-schema-mismatch "$(git -C "$repository" rev-parse HEAD)"
}

expect_schema_failure production-boundary production-boundary
expect_schema_failure duplicate-key duplicate
expect_schema_failure unknown-keyword unknown-keyword
expect_schema_failure open-object open-object
expect_schema_failure const-type const-type
expect_schema_failure wrong-dialect wrong-dialect

XCODEGEN_MISMATCH="$TMP/xcodegen-mismatch"
git clone -q "$BASE" "$XCODEGEN_MISMATCH"
git -C "$XCODEGEN_MISMATCH" config user.name 'UtterInk Test'
git -C "$XCODEGEN_MISMATCH" config user.email 'utterink-test@example.invalid'
printf '# changed before verification\n' >> "$XCODEGEN_MISMATCH/FixtureTools/xcodegen"
git -C "$XCODEGEN_MISMATCH" add FixtureTools/xcodegen
git -C "$XCODEGEN_MISMATCH" commit -q -m 'drift xcodegen binary'
expect_failure "$XCODEGEN_MISMATCH" 24 toolchain-mismatch "$(git -C "$XCODEGEN_MISMATCH" rev-parse HEAD)"
if grep -Fq 'xcodegen:' "$TMP/fixture.log"; then
  fail 'hash-mismatched xcodegen executed before verification'
fi

XCODEGEN_RESOURCES_MISSING="$TMP/xcodegen-resources-missing"
git clone -q "$BASE" "$XCODEGEN_RESOURCES_MISSING"
git -C "$XCODEGEN_RESOURCES_MISSING" config user.name 'UtterInk Test'
git -C "$XCODEGEN_RESOURCES_MISSING" config user.email 'utterink-test@example.invalid'
git -C "$XCODEGEN_RESOURCES_MISSING" rm -qr FixtureTools/XcodeGen_XcodeGenKit.bundle
git -C "$XCODEGEN_RESOURCES_MISSING" commit -q -m 'remove xcodegen companion resources'
expect_failure \
  "$XCODEGEN_RESOURCES_MISSING" 24 toolchain-mismatch \
  "$(git -C "$XCODEGEN_RESOURCES_MISSING" rev-parse HEAD)"
if grep -Fq 'xcodegen:' "$TMP/fixture.log"; then
  fail 'missing XcodeGen companion resources reached XcodeGen execution'
fi

XCODEGEN_RESOURCES_TAMPERED="$TMP/xcodegen-resources-tampered"
git clone -q "$BASE" "$XCODEGEN_RESOURCES_TAMPERED"
git -C "$XCODEGEN_RESOURCES_TAMPERED" config user.name 'UtterInk Test'
git -C "$XCODEGEN_RESOURCES_TAMPERED" config user.email 'utterink-test@example.invalid'
printf '{"tampered":true}\n' > \
  "$XCODEGEN_RESOURCES_TAMPERED/FixtureTools/XcodeGen_XcodeGenKit.bundle/SettingPresets/Base.json"
git -C "$XCODEGEN_RESOURCES_TAMPERED" add FixtureTools/XcodeGen_XcodeGenKit.bundle/SettingPresets/Base.json
git -C "$XCODEGEN_RESOURCES_TAMPERED" commit -q -m 'tamper xcodegen companion resource'
expect_failure \
  "$XCODEGEN_RESOURCES_TAMPERED" 24 toolchain-mismatch \
  "$(git -C "$XCODEGEN_RESOURCES_TAMPERED" rev-parse HEAD)"
if grep -Fq 'xcodegen:' "$TMP/fixture.log"; then
  fail 'tampered XcodeGen companion resources reached XcodeGen execution'
fi

XCODEGEN_RESOURCES_EXTRA="$TMP/xcodegen-resources-extra"
git clone -q "$BASE" "$XCODEGEN_RESOURCES_EXTRA"
git -C "$XCODEGEN_RESOURCES_EXTRA" config user.name 'UtterInk Test'
git -C "$XCODEGEN_RESOURCES_EXTRA" config user.email 'utterink-test@example.invalid'
printf 'unexpected bundle resource\n' > \
  "$XCODEGEN_RESOURCES_EXTRA/FixtureTools/XcodeGen_XcodeGenKit.bundle/extra.txt"
git -C "$XCODEGEN_RESOURCES_EXTRA" add FixtureTools/XcodeGen_XcodeGenKit.bundle/extra.txt
git -C "$XCODEGEN_RESOURCES_EXTRA" commit -q -m 'add xcodegen bundle root resource'
expect_failure \
  "$XCODEGEN_RESOURCES_EXTRA" 24 toolchain-mismatch \
  "$(git -C "$XCODEGEN_RESOURCES_EXTRA" rev-parse HEAD)"
if grep -Fq 'xcodegen:' "$TMP/fixture.log"; then
  fail 'extra XcodeGen bundle-root resource reached XcodeGen execution'
fi

SUCCESS_OUTPUT="$TMP/success-output"
mkdir -p "$SUCCESS_OUTPUT"
run_candidate \
  "$BASE" \
  "$SUCCESS_OUTPUT" \
  "$BASE_COMMIT" \
  --expected-origin 'https://github.com/example/UtterInk.git'
if [[ "$CANDIDATE_STATUS" -ne 0 ]]; then
  fail "clean exact commit failed: $(cat "$TMP/stderr")"
fi
if [[ -s "$TMP/stdout" || -s "$TMP/stderr" ]]; then
  fail 'clean exact commit emitted prose'
fi
if [[ ! -f "$SUCCESS_OUTPUT/candidate.json" || -L "$SUCCESS_OUTPUT/candidate.json" ]]; then
  fail 'clean exact commit did not emit a regular candidate.json'
fi
if [[ "$(stat -f '%Lp' "$SUCCESS_OUTPUT/candidate.json")" != 644 ]]; then
  fail 'candidate.json did not use mode 0644'
fi
if [[ -n "$(find "$SUCCESS_OUTPUT" -maxdepth 1 -name '.candidate.json.*' -print -quit)" ]]; then
  fail 'candidate output left a temporary file behind'
fi

python3 - "$SUCCESS_OUTPUT/candidate.json" "$BASE_COMMIT" <<'PY'
from __future__ import annotations

import json
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
commit = sys.argv[2]
value = json.loads(path.read_text(encoding="utf-8"))
if value["schemaVersion"] != 1 or value["evidenceType"] != "release-candidate-test":
    raise SystemExit("candidate identity mismatch")
if value["source"]["commit"] != commit or value["source"]["clean"] is not True:
    raise SystemExit("candidate source mismatch")
if value["release"]["dmgFilename"] != "UtterInk-0.1.0-arm64.dmg":
    raise SystemExit("candidate release mismatch")
if value["toolchain"]["xcodeBuild"] != "17E202":
    raise SystemExit("candidate toolchain mismatch")
if set(value["checks"].values()) != {True}:
    raise SystemExit("candidate checks were not all true")
serialized = path.read_text(encoding="utf-8")
users_prefix = "/" + "Users" + "/"
home_prefix = "/" + "home" + "/"
if any(value in serialized for value in (users_prefix, home_prefix, "FixtureTools", "UtterInk Test", "example.invalid")):
    raise SystemExit("candidate leaked a private or fixture value")
PY

for expected in \
  'history:--expected-origin https://github.com/example/UtterInk.git' \
  'entitlements' \
  'info-policy' \
  'swift:package --package-path Packages/UtterInkKit --scratch-path ' \
  'xcodebuild:-resolvePackageDependencies -project UtterInk.xcodeproj -scheme UtterInk' \
  'xcodegen:generate' \
  'xcodebuild:-project UtterInk.xcodeproj -scheme UtterInk -configuration Release -showBuildSettings'; do
  if ! grep -Fq "$expected" "$TMP/fixture.log"; then
    fail "clean exact commit skipped required command: $expected"
  fi
done

EXISTING_CANDIDATE_OUTPUT="$TMP/existing-candidate-output"
mkdir -m 0700 "$EXISTING_CANDIDATE_OUTPUT"
printf '{"priorEvidence":true}\n' > "$EXISTING_CANDIDATE_OUTPUT/candidate.json"
chmod 0600 "$EXISTING_CANDIDATE_OUTPUT/candidate.json"
EXISTING_CANDIDATE_RECORD="$(stat -f '%d:%i:%Lp:%l:%z' "$EXISTING_CANDIDATE_OUTPUT/candidate.json")"
run_candidate "$BASE" "$EXISTING_CANDIDATE_OUTPUT" "$BASE_COMMIT"
if [[ "$CANDIDATE_STATUS" -ne 29 || "$(cat "$TMP/stderr")" != 'release candidate error: unsafe-output' ]]; then
  fail 'existing candidate evidence was not rejected fail-closed'
fi
[[ "$(cat "$EXISTING_CANDIDATE_OUTPUT/candidate.json")" == '{"priorEvidence":true}' ]] || fail 'existing candidate evidence content changed'
[[ "$(stat -f '%d:%i:%Lp:%l:%z' "$EXISTING_CANDIDATE_OUTPUT/candidate.json")" == "$EXISTING_CANDIDATE_RECORD" ]] || fail 'existing candidate evidence identity or metadata changed'
[[ -z "$(find "$EXISTING_CANDIDATE_OUTPUT" -maxdepth 1 -name '.candidate.json.*' -print -quit)" ]] || fail 'existing candidate rejection left a temporary file'

LATE_FAILURE_REPOSITORY="$TMP/candidate-late-failure-repository"
LATE_FAILURE_OUTPUT="$TMP/candidate-late-failure-output"
LATE_FAILURE_MARKER="$TMP/candidate-late-failure-marker"
git clone -q "$BASE" "$LATE_FAILURE_REPOSITORY"
git -C "$LATE_FAILURE_REPOSITORY" config user.name 'UtterInk Test'
git -C "$LATE_FAILURE_REPOSITORY" config user.email 'utterink-test@example.invalid'
mkdir -m 0700 "$LATE_FAILURE_OUTPUT"
printf 'prior sidecar evidence\n' > "$LATE_FAILURE_OUTPUT/prior-candidate.json"
chmod 0600 "$LATE_FAILURE_OUTPUT/prior-candidate.json"
LATE_FAILURE_PRIOR_RECORD="$(stat -f '%d:%i:%Lp:%l:%z' "$LATE_FAILURE_OUTPUT/prior-candidate.json")"
python3 - \
  "$LATE_FAILURE_REPOSITORY/Scripts/release/verify-info-policy.py" \
  "$LATE_FAILURE_OUTPUT" \
  "$LATE_FAILURE_REPOSITORY/Config/release-metadata.json" \
  "$LATE_FAILURE_MARKER" <<'PY'
from pathlib import Path
import sys

helper = Path(sys.argv[1])
output, tracked_input, marker = sys.argv[2:]
helper.write_text(f'''#!/usr/bin/env python3
import os
from pathlib import Path
import signal
import subprocess

watcher = r"""
import os
from pathlib import Path
import signal
import sys
import time

pid = int(sys.argv[1])
output = Path(sys.argv[2])
tracked_input = Path(sys.argv[3])
marker = Path(sys.argv[4])
deadline = time.monotonic() + 30
while time.monotonic() < deadline:
    if (output / 'candidate.json').is_file():
        stopped = False
        try:
            os.kill(pid, signal.SIGSTOP)
            stopped = True
            with tracked_input.open('a', encoding='utf-8') as handle:
                handle.write('\\n')
            marker.write_text('late input mutation\\n', encoding='utf-8')
        finally:
            if stopped:
                os.kill(pid, signal.SIGCONT)
        raise SystemExit(0)
    time.sleep(0.0002)
raise SystemExit(1)
"""
subprocess.Popen(
    ['/usr/bin/python3', '-I', '-c', watcher, str(os.getppid()), {output!r}, {tracked_input!r}, {marker!r}],
    close_fds=True,
    start_new_session=True,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
with Path(os.environ['UTTERINK_FIXTURE_LOG']).open('a', encoding='utf-8') as handle:
    handle.write('info-policy\\n')
print('release Info policy valid')
''', encoding="utf-8")
helper.chmod(0o755)
PY
git -C "$LATE_FAILURE_REPOSITORY" add Scripts/release/verify-info-policy.py
git -C "$LATE_FAILURE_REPOSITORY" commit -q -m 'mutate tracked input after candidate publication'
run_candidate \
  "$LATE_FAILURE_REPOSITORY" \
  "$LATE_FAILURE_OUTPUT" \
  "$(git -C "$LATE_FAILURE_REPOSITORY" rev-parse HEAD)"
if [[ "$CANDIDATE_STATUS" -ne 20 || "$(cat "$TMP/stderr")" != 'release candidate error: dirty-checkout' ]]; then
  fail 'late post-publication input mutation was not rejected'
fi
for _ in {1..200}; do
  [[ -e "$LATE_FAILURE_MARKER" ]] && break
  /bin/sleep 0.01
done
[[ -e "$LATE_FAILURE_MARKER" ]] || fail 'late post-publication input mutation did not run'
[[ ! -e "$LATE_FAILURE_OUTPUT/candidate.json" && ! -L "$LATE_FAILURE_OUTPUT/candidate.json" ]] || fail 'late post-publication failure left candidate evidence'
[[ "$(cat "$LATE_FAILURE_OUTPUT/prior-candidate.json")" == 'prior sidecar evidence' ]] || fail 'late post-publication rollback changed prior sidecar content'
[[ "$(stat -f '%d:%i:%Lp:%l:%z' "$LATE_FAILURE_OUTPUT/prior-candidate.json")" == "$LATE_FAILURE_PRIOR_RECORD" ]] || fail 'late post-publication rollback changed prior sidecar identity or metadata'
[[ -z "$(find "$LATE_FAILURE_OUTPUT" -maxdepth 1 -name '.candidate.json.*' -print -quit)" ]] || fail 'late post-publication failure left a temporary file'

FD_SUCCESS_OUTPUT="$TMP/fd-success-output"
mkdir -m 0700 "$FD_SUCCESS_OUTPUT"
run_candidate_with_output_fd \
  "$BASE" \
  "$FD_SUCCESS_OUTPUT" \
  "$FD_SUCCESS_OUTPUT" \
  "$BASE_COMMIT"
if [[ "$CANDIDATE_STATUS" -ne 0 || -s "$TMP/stdout" || -s "$TMP/stderr" ]]; then
  fail 'inherited output directory FD was not accepted safely'
fi
if [[ ! -f "$FD_SUCCESS_OUTPUT/candidate.json" || -L "$FD_SUCCESS_OUTPUT/candidate.json" ]]; then
  fail 'inherited output directory FD did not receive candidate.json'
fi

CLOSED_FD_OUTPUT="$TMP/closed-fd-output"
run_candidate "$BASE" "$CLOSED_FD_OUTPUT" "$BASE_COMMIT" --output-dir-fd 19
if [[ "$CANDIDATE_STATUS" -ne 29 || "$(cat "$TMP/stderr")" != 'release candidate error: unsafe-output' ]]; then
  fail 'closed output directory FD was not rejected safely'
fi
[[ ! -e "$CLOSED_FD_OUTPUT/candidate.json" ]] || fail 'closed output directory FD emitted candidate.json'

MISMATCHED_FD_OUTPUT="$TMP/mismatched-fd-output"
MISMATCHED_FD_TARGET="$TMP/mismatched-fd-target"
mkdir -m 0700 "$MISMATCHED_FD_OUTPUT" "$MISMATCHED_FD_TARGET"
printf 'outside sentinel\n' > "$MISMATCHED_FD_TARGET/sentinel"
run_candidate_with_output_fd \
  "$BASE" \
  "$MISMATCHED_FD_OUTPUT" \
  "$MISMATCHED_FD_TARGET" \
  "$BASE_COMMIT"
if [[ "$CANDIDATE_STATUS" -ne 29 || "$(cat "$TMP/stderr")" != 'release candidate error: unsafe-output' ]]; then
  fail 'mismatched output directory FD was not rejected safely'
fi
[[ ! -e "$MISMATCHED_FD_OUTPUT/candidate.json" ]] || fail 'mismatched output path received candidate.json'
[[ ! -e "$MISMATCHED_FD_TARGET/candidate.json" ]] || fail 'mismatched output FD target received candidate.json'
[[ "$(cat "$MISMATCHED_FD_TARGET/sentinel")" == 'outside sentinel' ]] || fail 'mismatched output FD changed outside sentinel'

WORLD_WRITABLE_FD_OUTPUT="$TMP/world-writable-fd-output"
mkdir -m 0777 "$WORLD_WRITABLE_FD_OUTPUT"
run_candidate_with_output_fd \
  "$BASE" \
  "$WORLD_WRITABLE_FD_OUTPUT" \
  "$WORLD_WRITABLE_FD_OUTPUT" \
  "$BASE_COMMIT"
if [[ "$CANDIDATE_STATUS" -ne 29 || "$(cat "$TMP/stderr")" != 'release candidate error: unsafe-output' ]]; then
  fail 'world-writable output directory FD was not rejected safely'
fi
[[ ! -e "$WORLD_WRITABLE_FD_OUTPUT/candidate.json" ]] || fail 'world-writable output directory FD emitted candidate.json'

expect_unsafe_output() {
  local output="$1"
  local description="$2"
  run_candidate "$BASE" "$output" "$BASE_COMMIT"
  if [[ "$CANDIDATE_STATUS" -ne 29 ]]; then
    fail "$description returned $CANDIDATE_STATUS, expected 29"
  fi
  if [[ -s "$TMP/stdout" || "$(cat "$TMP/stderr")" != 'release candidate error: unsafe-output' ]]; then
    fail "$description emitted a non-sanitized diagnostic"
  fi
  if [[ -e "$output/candidate.json" || -L "$output/candidate.json" ]]; then
    fail "$description emitted candidate.json"
  fi
}

expect_unsafe_output "$BASE/not-release-work" 'non-allowlisted repository output'

WORLD_WRITABLE_OUTPUT="$TMP/world-writable-output"
mkdir -p "$WORLD_WRITABLE_OUTPUT"
chmod 0777 "$WORLD_WRITABLE_OUTPUT"
expect_unsafe_output "$WORLD_WRITABLE_OUTPUT" 'world-writable output directory'

SYMLINK_TARGET="$TMP/symlink-output-target"
SYMLINK_OUTPUT="$TMP/symlink-output"
mkdir -p "$SYMLINK_TARGET"
ln -s "$SYMLINK_TARGET" "$SYMLINK_OUTPUT"
expect_unsafe_output "$SYMLINK_OUTPUT/child" 'symlinked output parent'

CANDIDATE_SYMLINK_OUTPUT="$TMP/candidate-symlink-output"
CANDIDATE_SYMLINK_TARGET="$TMP/candidate-symlink-target"
mkdir -p "$CANDIDATE_SYMLINK_OUTPUT"
printf 'unchanged\n' > "$CANDIDATE_SYMLINK_TARGET"
ln -s "$CANDIDATE_SYMLINK_TARGET" "$CANDIDATE_SYMLINK_OUTPUT/candidate.json"
run_candidate "$BASE" "$CANDIDATE_SYMLINK_OUTPUT" "$BASE_COMMIT"
if [[ "$CANDIDATE_STATUS" -ne 29 || "$(cat "$TMP/stderr")" != 'release candidate error: unsafe-output' ]]; then
  fail 'existing candidate symlink was not rejected safely'
fi
if [[ ! -L "$CANDIDATE_SYMLINK_OUTPUT/candidate.json" || "$(cat "$CANDIDATE_SYMLINK_TARGET")" != unchanged ]]; then
  fail 'existing candidate symlink target was modified'
fi
if [[ -n "$(find "$CANDIDATE_SYMLINK_OUTPUT" -maxdepth 1 -name '.candidate.json.*' -print -quit)" ]]; then
  fail 'candidate symlink failure left a temporary file behind'
fi

OUTPUT_REBIND="$TMP/candidate-output-rebind-repository"
git clone -q "$BASE" "$OUTPUT_REBIND"
git -C "$OUTPUT_REBIND" config user.name 'UtterInk Test'
git -C "$OUTPUT_REBIND" config user.email 'utterink-test@example.invalid'
OUTPUT_REBIND_PATH="$TMP/candidate-output-rebind/live"
OUTPUT_REBIND_ORIGINAL="$TMP/candidate-output-rebind/original"
OUTPUT_REBIND_MARKER="$TMP/candidate-output-rebind/swapped"
mkdir -p "$(dirname "$OUTPUT_REBIND_PATH")"
python3 - \
  "$OUTPUT_REBIND/Scripts/release/verify-info-policy.py" \
  "$OUTPUT_REBIND_PATH" "$OUTPUT_REBIND_ORIGINAL" "$OUTPUT_REBIND_MARKER" <<'PY'
from pathlib import Path
import sys

helper = Path(sys.argv[1])
output, original, marker = sys.argv[2:]
helper.write_text(f'''#!/usr/bin/env python3
import os
from pathlib import Path
import signal
import subprocess

watcher = r"""
import os
from pathlib import Path
import signal
import sys
import time
pid = int(sys.argv[1])
output = Path(sys.argv[2])
original = Path(sys.argv[3])
marker = Path(sys.argv[4])
deadline = time.monotonic() + 30
while time.monotonic() < deadline:
    if (output / 'candidate.json').is_file():
        os.kill(pid, signal.SIGSTOP)
        output.rename(original)
        output.mkdir(mode=0o700)
        (output / 'sentinel').write_text('replacement sentinel\\n', encoding='utf-8')
        marker.write_text('swapped\\n', encoding='utf-8')
        os.kill(pid, signal.SIGCONT)
        raise SystemExit(0)
    time.sleep(0.0002)
raise SystemExit(1)
"""
subprocess.Popen(
    ['/usr/bin/python3', '-I', '-c', watcher, str(os.getppid()), {output!r}, {original!r}, {marker!r}],
    close_fds=True,
    start_new_session=True,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
with Path(os.environ['UTTERINK_FIXTURE_LOG']).open('a', encoding='utf-8') as handle:
    handle.write('info-policy\\n')
print('release Info policy valid')
''', encoding="utf-8")
helper.chmod(0o755)
PY
git -C "$OUTPUT_REBIND" add Scripts/release/verify-info-policy.py
git -C "$OUTPUT_REBIND" commit -q -m 'rebind candidate output after publication'
run_candidate "$OUTPUT_REBIND" "$OUTPUT_REBIND_PATH" "$(git -C "$OUTPUT_REBIND" rev-parse HEAD)"
if [[ "$CANDIDATE_STATUS" -ne 29 || "$(cat "$TMP/stderr")" != 'release candidate error: unsafe-output' ]]; then
  fail 'candidate output directory rebind was not rejected safely'
fi
for _ in {1..200}; do
  [[ -e "$OUTPUT_REBIND_MARKER" ]] && break
  /bin/sleep 0.01
done
[[ -e "$OUTPUT_REBIND_MARKER" ]] || fail 'candidate output directory rebind did not run'
[[ ! -e "$OUTPUT_REBIND_ORIGINAL/candidate.json" ]] || fail 'candidate output rebind rollback left exact candidate behind'
[[ "$(cat "$OUTPUT_REBIND_PATH/sentinel")" == 'replacement sentinel' ]] || fail 'candidate output rebind changed replacement sentinel'
[[ ! -e "$OUTPUT_REBIND_PATH/candidate.json" ]] || fail 'candidate output rebind published into replacement directory'

FORGED_MARKER_OUTPUT="$TMP/forged-marker-output"
set +e
(
  cd "$BASE"
  /usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    LC_ALL=C \
    UTTERINK_RELEASE_ENV_CLEAN=1 \
    TMPDIR=/definitely/not/a/release-directory \
    /bin/bash -p Scripts/release/verify-candidate.sh \
      --commit "$BASE_COMMIT" \
      --output "$FORGED_MARKER_OUTPUT"
) > "$TMP/forged-marker-stdout" 2> "$TMP/forged-marker-stderr"
FORGED_MARKER_STATUS=$?
set -e
if [[ "$FORGED_MARKER_STATUS" -ne 2 ]]; then
  fail "forged clean-environment marker returned $FORGED_MARKER_STATUS, expected 2"
fi
if [[ -s "$TMP/forged-marker-stdout" || "$(cat "$TMP/forged-marker-stderr")" != 'release candidate error: unsafe-launch-environment' ]]; then
  fail 'forged clean-environment marker emitted a non-sanitized diagnostic'
fi
if [[ -e "$FORGED_MARKER_OUTPUT/candidate.json" ]]; then
  fail 'forged clean-environment marker emitted candidate.json'
fi

CANARY_TOOLS="$TMP/path-canary"
CANARY_LOG="$TMP/path-canary.log"
mkdir -p "$CANARY_TOOLS"
for name in xcodebuild swift xcodegen; do
  printf '#!/usr/bin/env bash\nprintf "used\\n" >> "%s"\n' "$CANARY_LOG" > "$CANARY_TOOLS/$name"
  chmod +x "$CANARY_TOOLS/$name"
done
set +e
(
  cd "$BASE"
  PATH="$CANARY_TOOLS:$PATH" \
    ./Scripts/release/verify-candidate.sh \
      --commit "$BASE_COMMIT" \
      --output "$TMP/production-output"
) > "$TMP/production-stdout" 2> "$TMP/production-stderr"
PRODUCTION_STATUS=$?
set -e
if [[ "$PRODUCTION_STATUS" -eq 0 ]]; then
  fail 'production mode accepted the fixture toolchain'
fi
if [[ -e "$CANARY_LOG" ]]; then
  fail 'production mode consulted ordinary PATH tools'
fi
if [[ -e "$TMP/production-output/candidate.json" ]]; then
  fail 'production toolchain failure emitted candidate.json'
fi
if [[ -e "$BASH_ENV_MARKER" ]]; then
  fail 'candidate verifier loaded BASH_ENV before sanitizing the environment'
fi
if [[ -e "$BASH_FUNCTION_MARKER" ]]; then
  fail 'candidate verifier imported an exported Bash function'
fi
if [[ -e "$PERL_MARKER" ]]; then
  fail 'candidate verifier allowed Perl environment injection into shasum'
fi

printf 'release candidate tests passed\n'
