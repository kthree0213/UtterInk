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
if [[ \"${1-}\" == '--version' ]]; then
  printf 'Version: 2.45.4\\n'
fi
""",
    executable=True,
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
python3 - "$BASE/Config/ci-toolchain.json" "$XCODEGEN_HASH" <<'PY'
from __future__ import annotations

import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
binary_hash = sys.argv[2]
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

SUCCESS_OUTPUT="$TMP/success-output"
mkdir -p "$SUCCESS_OUTPUT"
printf 'replace-me\n' > "$SUCCESS_OUTPUT/candidate.json"
chmod 0644 "$SUCCESS_OUTPUT/candidate.json"
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
