#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
BUILDER="$ROOT/Scripts/release/build-candidate.sh"

fail() {
  printf 'build candidate tests failed: %s\n' "$1" >&2
  exit 1
}

[[ -x "$BUILDER" ]] || fail 'Scripts/release/build-candidate.sh is missing or not executable'
for helper in \
  Scripts/release/read-metadata.py \
  Scripts/release/verify-entitlements.py \
  Scripts/release/verify-info-policy.py; do
  [[ -f "$ROOT/$helper" && -x "$ROOT/$helper" && ! -L "$ROOT/$helper" ]] ||
    fail "$helper is missing, linked, or not executable"
done

TMP="$(/usr/bin/mktemp -d /private/tmp/utterink-build-candidate-tests.XXXXXX)"
TMP="$(cd "$TMP" && pwd -P)"
trap '/bin/rm -rf "$TMP"' EXIT
BASE="$TMP/base"
ORDINARY_LOG="$TMP/ordinary-path.log"
BASH_ENV_MARKER="$TMP/bash-env-loaded"
BASH_ENV_CANARY="$TMP/hostile-bash-env"
printf 'printf loaded > %q\n' "$BASH_ENV_MARKER" > "$BASH_ENV_CANARY"

/bin/mkdir -p \
  "$BASE/App/Supporting" \
  "$BASE/Config" \
  "$BASE/docs/release" \
  "$BASE/FixtureTools" \
  "$BASE/OrdinaryPath" \
  "$BASE/Packages/UtterInkKit" \
  "$BASE/Scripts/release" \
  "$BASE/UtterInk.xcodeproj"

/bin/cp "$BUILDER" "$BASE/Scripts/release/build-candidate.sh"
/bin/chmod 0755 "$BASE/Scripts/release/build-candidate.sh"
/usr/bin/printf '%s\n' \
  '/Tools/bin/' \
  '/.release-work/' \
  '.swiftpm/' \
  '/.fixture-*' \
  '*.xcarchive' > "$BASE/.gitignore"
/usr/bin/printf 'committed-source\n' > "$BASE/Config/source-sentinel"
/usr/bin/printf '{"schemaVersion":1,"kind":"metadata"}\n' > "$BASE/Config/release-metadata.json"
/usr/bin/printf '{"schemaVersion":1,"kind":"entitlements"}\n' > "$BASE/Config/release-entitlements.json"
/usr/bin/printf '{"schemaVersion":1,"kind":"info"}\n' > "$BASE/Config/release-info-policy.json"
/usr/bin/printf '{"pins":[],"version":3}\n' > "$BASE/Packages/UtterInkKit/Package.resolved"
/usr/bin/printf 'name: UtterInk\n' > "$BASE/project.yml"
/usr/bin/printf '// generated project fixture\n' > "$BASE/UtterInk.xcodeproj/project.pbxproj"
/usr/bin/printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>com.apple.security.device.audio-input</key><true/></dict></plist>' > "$BASE/App/Supporting/UtterInk.entitlements"
/usr/bin/printf 'utterink-offline-build-candidate-fixture-v1\n' > "$BASE/FixtureTools/.utterink-build-candidate-test-fixture"
/bin/cp "$ROOT/docs/release/evidence-schema.json" "$BASE/docs/release/evidence-schema.json"

cat > "$BASE/Scripts/release/verify-candidate.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
commit=''
output=''
expected_origin=''
origin_count=0
for argument in "$@"; do
  printf 'verify-arg\t%s\n' "$argument" >> "${UTTERINK_FIXTURE_LOG:?}"
done
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --commit) [[ -z "$commit" && "$#" -ge 2 ]] || exit 64; commit="$2"; shift 2 ;;
    --output) [[ -z "$output" && "$#" -ge 2 ]] || exit 64; output="$2"; shift 2 ;;
    --expected-origin)
      origin_count=$((origin_count + 1))
      expected_origin="${2:?}"
      shift 2
      ;;
    *) exit 64 ;;
  esac
done
[[ "$origin_count" -le 1 ]] || exit 64
[[ "$commit" == "$(/usr/bin/git rev-parse HEAD)" ]] || exit 21
candidate_status="$(/usr/bin/git status --porcelain=v1 --untracked-files=all)"
printf 'verify-status\t%s\n' "$candidate_status" >> "${UTTERINK_FIXTURE_LOG:?}"
[[ -z "$candidate_status" ]] || exit 20
case "$output" in "$PWD"/.release-work/*) ;; *) exit 29 ;; esac
origin="$(/usr/bin/git remote get-url origin 2>/dev/null || :)"
if [[ -n "$origin" ]]; then
  [[ -n "$expected_origin" && "$expected_origin" == "$origin" ]] || exit 25
else
  [[ -z "$expected_origin" ]] || exit 25
fi
/bin/mkdir -p "$output"
/usr/bin/python3 -I - "$output/candidate.json" "$commit" "$(/usr/bin/git rev-parse "$commit^{tree}")" <<'PY'
from pathlib import Path
import hashlib
import json
import os
import sys

output, commit, tree = sys.argv[1:4]
root = Path.cwd()
lock = json.loads((root / "Config/ci-toolchain.json").read_text(encoding="utf-8"))

def digest(relative):
    return hashlib.sha256((root / relative).read_bytes()).hexdigest()

value = {
    "schemaVersion": 1,
    "evidenceType": "release-candidate-test",
    "product": "UtterInk",
    "source": {"commit": commit, "tree": tree, "releaseTag": "v0.1.0", "clean": True},
    "release": {
        "configuration": "Release",
        "marketingVersion": "0.1.0",
        "buildNumber": "1",
        "bundleIdentifier": "dev.utterink.UtterInk",
        "deploymentTarget": "14.0",
        "architecture": "arm64",
        "dmgFilename": "UtterInk-0.1.0-arm64.dmg",
    },
    "toolchain": {
        "lockSHA256": digest("Config/ci-toolchain.json"),
        "xcodeVersion": lock["xcode"]["version"],
        "xcodeBuild": lock["xcode"]["build"],
        "sdkVersion": lock["sdk"]["version"],
        "sdkBuild": lock["sdk"]["build"],
        "swiftVersion": lock["swift"]["version"],
        "xcodegenVersion": lock["xcodegen"]["version"],
        "xcodegenBinarySHA256": lock["xcodegen"]["binarySHA256"],
    },
    "packageResolution": {
        "path": "Packages/UtterInkKit/Package.resolved",
        "sha256": digest("Packages/UtterInkKit/Package.resolved"),
    },
    "policies": {
        "releaseMetadataSHA256": digest("Config/release-metadata.json"),
        "releaseEntitlementsSHA256": digest("Config/release-entitlements.json"),
        "releaseInfoPolicySHA256": digest("Config/release-info-policy.json"),
        "ciToolchainSHA256": digest("Config/ci-toolchain.json"),
    },
    "checks": {
        "history": True,
        "metadata": True,
        "entitlements": True,
        "infoPolicy": True,
        "packageResolution": True,
        "generatedProjectClean": True,
    },
}
log = Path(os.environ["UTTERINK_FIXTURE_LOG"])
if Path(f"{log}.candidate-checks-swap").exists():
    value["checks"]["history"] = False
if Path(f"{log}.candidate-policy-swap").exists():
    value["policies"]["releaseInfoPolicySHA256"] = "0" * 64
if Path(f"{log}.candidate-toolchain-swap").exists():
    value["toolchain"]["xcodeBuild"] = "ATTACK"
Path(output).write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
if [[ -f "${UTTERINK_FIXTURE_LOG:?}.mutate-verifier" ]]; then
  /usr/bin/touch "$0"
fi
if [[ -f "${UTTERINK_FIXTURE_LOG:?}.mutate-root" ]]; then
  /usr/bin/printf 'mutated-after-verification\n' > Config/source-sentinel
fi
EOF

cat > "$BASE/Scripts/release/read-metadata.py" <<'EOF'
#!/usr/bin/env python3
import json
import os
import sys
if sys.argv[1:] != ["--json"]:
    raise SystemExit(2)
with open(os.environ["UTTERINK_FIXTURE_LOG"], "a", encoding="utf-8") as handle:
    handle.write("read-metadata\n")
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

cat > "$BASE/Scripts/release/verify-entitlements.py" <<'EOF'
#!/usr/bin/env python3
import os
import sys
if sys.argv[1:]:
    raise SystemExit(2)
with open(os.environ["UTTERINK_FIXTURE_LOG"], "a", encoding="utf-8") as handle:
    handle.write("verify-entitlements\n")
EOF

cat > "$BASE/Scripts/release/verify-info-policy.py" <<'EOF'
#!/usr/bin/env python3
import os
from pathlib import Path
import plistlib
import sys
if len(sys.argv) != 3 or sys.argv[1] != "--archived":
    raise SystemExit(2)
with Path(sys.argv[2]).open("rb") as handle:
    info = plistlib.load(handle)
expected = {
    "CFBundleDisplayName": "UtterInk",
    "CFBundleExecutable": "UtterInk",
    "CFBundleIdentifier": "dev.utterink.UtterInk",
    "CFBundleName": "UtterInk",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "0.1.0",
    "CFBundleVersion": "1",
    "LSMinimumSystemVersion": "14.0",
}
if any(info.get(key) != value for key, value in expected.items()):
    raise SystemExit(1)
with open(os.environ["UTTERINK_FIXTURE_LOG"], "a", encoding="utf-8") as log:
    log.write("verify-info-policy\n")
print("release Info policy valid")
EOF

cat > "$BASE/Scripts/collect-third-party-notices.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -eq 1 && "$1" == '--check' ]]
printf 'third-party-notices\n' >> "${UTTERINK_FIXTURE_LOG:?}"
EOF

/bin/chmod 0755 \
  "$BASE/Scripts/release/verify-candidate.sh" \
  "$BASE/Scripts/release/read-metadata.py" \
  "$BASE/Scripts/release/verify-entitlements.py" \
  "$BASE/Scripts/release/verify-info-policy.py" \
  "$BASE/Scripts/collect-third-party-notices.sh"

cat > "$BASE/FixtureTools/xcodegen-source" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'xcodegen'
  for argument in "$@"; do printf '\t%s' "$argument"; done
  printf '\n'
} >> "${UTTERINK_FIXTURE_LOG:?}"
case "${1-}" in
  --version) printf 'Version: 2.45.4\n' ;;
  generate)
    [[ "$PWD" == */.release-work/.build-candidate.*/.transient/exact-source ]]
    [[ -n "${USER:-}" && "${LOGNAME:-}" == "$USER" ]]
    [[ -z "${DYLD_INSERT_LIBRARIES+x}" ]]
    xcodegen_directory="$(cd "$(/usr/bin/dirname "$0")" && /bin/pwd -P)"
    [[ -f "$xcodegen_directory/XcodeGen_XcodeGenKit.bundle/SettingPresets/Base.json" ]]
    [[ -f "$xcodegen_directory/XcodeGen_XcodeGenKit.bundle/SettingPresets/Platforms/macOS.json" ]]
    printf 'xcodegen-user\t%s\n' "$USER" >> "${UTTERINK_FIXTURE_LOG:?}"
    if [[ -f "${UTTERINK_FIXTURE_LOG:?}.mutate-project" ]]; then
      printf '// generator drift\n' >> UtterInk.xcodeproj/project.pbxproj
    fi
    if [[ -f "${UTTERINK_FIXTURE_LOG:?}.swiftpm-xcodegen-inject" ]]; then
      printf 'unexpected generator state\n' \
        > Packages/UtterInkKit/.swiftpm/configuration/registries.json
    fi
    if [[ -f "${UTTERINK_FIXTURE_LOG:?}.swiftpm-xcodegen-write-delete" ]]; then
      printf 'transient generator state\n' \
        > Packages/UtterInkKit/.swiftpm/xcode/transient
      /bin/rm Packages/UtterInkKit/.swiftpm/xcode/transient
    fi
    ;;
  *) exit 64 ;;
esac
EOF

/bin/mkdir -p "$BASE/FixtureTools/XcodeGen_XcodeGenKit.bundle/SettingPresets/Platforms"
/usr/bin/printf '{"fixture":"base"}\n' \
  > "$BASE/FixtureTools/XcodeGen_XcodeGenKit.bundle/SettingPresets/Base.json"
/usr/bin/printf '{"fixture":"macOS"}\n' \
  > "$BASE/FixtureTools/XcodeGen_XcodeGenKit.bundle/SettingPresets/Platforms/macOS.json"

cat > "$BASE/FixtureTools/xcodebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec 2>> "${UTTERINK_FIXTURE_LOG:?}"
trap 'status=$?; printf "xcodebuild-error\tline=%s\tstatus=%s\n" "$LINENO" "$status" >> "${UTTERINK_FIXTURE_LOG:?}"' ERR
printf 'boundary-pwd\t%s\n' "$PWD" >> "${UTTERINK_FIXTURE_LOG:?}"
printf 'boundary-home\t%s\n' "${HOME:-}" >> "${UTTERINK_FIXTURE_LOG:?}"
printf 'boundary-source\t%s\n' "$(/bin/cat Config/source-sentinel)" >> "${UTTERINK_FIXTURE_LOG:?}"
{
  printf 'xcodebuild'
  for argument in "$@"; do printf '\t%s' "$argument"; done
  printf '\n'
} >> "${UTTERINK_FIXTURE_LOG:?}"

if [[ " $* " == *' -resolvePackageDependencies '* ]]; then
  swiftpm_state=Packages/UtterInkKit/.swiftpm
  if [[ -d "$swiftpm_state" && ! -L "$swiftpm_state" &&
    -d "$swiftpm_state/configuration" && ! -L "$swiftpm_state/configuration" &&
    -d "$swiftpm_state/xcode" && ! -L "$swiftpm_state/xcode" &&
    "$(/usr/bin/stat -f '%Lp' "$swiftpm_state")" == 700 &&
    "$(/usr/bin/stat -f '%Lp' "$swiftpm_state/configuration")" == 700 &&
    "$(/usr/bin/stat -f '%Lp' "$swiftpm_state/xcode")" == 700 ]]; then
    printf 'swiftpm-state\tprecreated\n' >> "${UTTERINK_FIXTURE_LOG:?}"
  else
    printf 'swiftpm-state\tcreated-by-xcode\n' >> "${UTTERINK_FIXTURE_LOG:?}"
  fi
  /bin/mkdir -p "$swiftpm_state/configuration" "$swiftpm_state/xcode"
  if [[ -f "${UTTERINK_FIXTURE_LOG:?}.swiftpm-extra-state" ]]; then
    /usr/bin/printf 'unexpected state\n' > "$swiftpm_state/configuration/injected"
  fi
  if [[ -f "${UTTERINK_FIXTURE_LOG:?}.swiftpm-mode-mutation" ]]; then
    /bin/chmod 0777 "$swiftpm_state/xcode"
  fi
  if [[ -f "${UTTERINK_FIXTURE_LOG:?}.mutate-lock" ]]; then
    printf 'changed\n' >> Packages/UtterInkKit/Package.resolved
  fi
  if [[ -f "${UTTERINK_FIXTURE_LOG:?}.swap-source-restore" ]]; then
    /bin/mv Config/source-sentinel Config/source-sentinel.saved
    /bin/cp Config/source-sentinel.saved Config/source-sentinel
    /bin/rm Config/source-sentinel
    /bin/mv Config/source-sentinel.saved Config/source-sentinel
  fi
  if [[ -f "${UTTERINK_FIXTURE_LOG:?}.candidate-output-swap" ]]; then
    /usr/bin/printf '{}\n' > ../verified-candidate/candidate.json
  fi
  if [[ -f "${UTTERINK_FIXTURE_LOG:?}.candidate-snapshot-swap" ]]; then
    /bin/chmod 0600 ../candidate.snapshot.json
    /usr/bin/printf '{}\n' > ../candidate.snapshot.json
    /bin/chmod 0400 ../candidate.snapshot.json
  fi
  exit 0
fi

if [[ " $* " == *' -showBuildSettings '* ]]; then
  hardened=YES
  version=0.1.0
  if [[ -f "${UTTERINK_FIXTURE_LOG:?}.hardened-mismatch" ]]; then hardened=NO; fi
  if [[ -f "${UTTERINK_FIXTURE_LOG:?}.metadata-mismatch" ]]; then version=0.1.1; fi
  printf '%s\n' \
    'Build settings for action build and target UtterInk:' \
    '    ARCHS = arm64' \
    '    CODE_SIGN_ENTITLEMENTS = App/Supporting/UtterInk.entitlements' \
    '    CURRENT_PROJECT_VERSION = 1' \
    "    ENABLE_HARDENED_RUNTIME = $hardened" \
    '    MACOSX_DEPLOYMENT_TARGET = 14.0' \
    "    MARKETING_VERSION = $version" \
    '    ONLY_ACTIVE_ARCH = NO' \
    '    PRODUCT_BUNDLE_IDENTIFIER = dev.utterink.UtterInk' \
    '    SWIFT_VERSION = 5.0'
  exit 0
fi

if [[ "${1-}" == archive ]]; then
  if [[ -f "${UTTERINK_FIXTURE_LOG:?}.cleanup-writable" ]]; then
    /bin/mkdir -p ../../writable-cleanup/nested
    /bin/chmod 0777 ../../writable-cleanup ../../writable-cleanup/nested
    /usr/bin/printf 'cleanup fixture\n' > ../../writable-cleanup/nested/output
    exit 70
  fi
  [[ ! -f "${UTTERINK_FIXTURE_LOG:?}.archive-failure" ]] || exit 70
  archive=''
  previous=''
  for argument in "$@"; do
    if [[ "$previous" == '-archivePath' ]]; then archive="$argument"; fi
    previous="$argument"
  done
  [[ -n "$archive" ]]
  app="$archive/Products/Applications/UtterInk.app"
  dsym_resources="$archive/dSYMs/UtterInk.app.dSYM/Contents/Resources"
  /bin/mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  /bin/mkdir -p \
    "$dsym_resources/DWARF" \
    "$dsym_resources/Relocations/aarch64"
  build_system_marker=true
  if [[ -f "${UTTERINK_FIXTURE_LOG:?}.archive-build-marker-wrong-value" ]]; then
    build_system_marker=false
  fi
  /usr/bin/xattr -w \
    com.apple.xcode.CreatedByBuildSystem \
    "$build_system_marker" \
    "$archive/Products"
  if [[ -f "${UTTERINK_FIXTURE_LOG:?}.archive-build-marker-extra-xattr" ]]; then
    /usr/bin/xattr -w \
      com.utterink.attack \
      unexpected-metadata \
      "$archive/Products"
  fi
  if [[ -f "${UTTERINK_FIXTURE_LOG:?}.archive-build-marker-wrong-path" ]]; then
    /usr/bin/xattr -w \
      com.apple.xcode.CreatedByBuildSystem \
      true \
      "$archive/Products/Applications"
  fi
  /usr/bin/printf 'fixture Mach-O arm64\n' > "$app/Contents/MacOS/UtterInk"
  /bin/chmod 0755 "$app/Contents/MacOS/UtterInk"
  /usr/bin/printf '%s\n' \
    '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0"><dict>' \
    '<key>CFBundleDisplayName</key><string>UtterInk</string>' \
    '<key>CFBundleExecutable</key><string>UtterInk</string>' \
    '<key>CFBundleIdentifier</key><string>dev.utterink.UtterInk</string>' \
    '<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>' \
    '<key>CFBundleName</key><string>UtterInk</string>' \
    '<key>CFBundlePackageType</key><string>APPL</string>' \
    '<key>CFBundleShortVersionString</key><string>0.1.0</string>' \
    '<key>CFBundleVersion</key><string>1</string>' \
    '<key>LSMinimumSystemVersion</key><string>14.0</string>' \
    '</dict></plist>' > "$app/Contents/Info.plist"
  /usr/bin/printf 'safe symlink target\n' > "$app/Contents/Resources/symlink-target.txt"
  /bin/ln -s symlink-target.txt "$app/Contents/Resources/symlink-current"
  fixture_user_root="/""Users/fixture"
  /usr/bin/printf 'fixture DWARF source path: %s\n' \
    "$fixture_user_root/UtterInk/App/Main.swift" \
    > "$dsym_resources/DWARF/UtterInk"
  /usr/bin/printf "binary-path: '%s'\n" \
    "$fixture_user_root/Library/Developer/Xcode/DerivedData/UtterInk/Build/UtterInk.app/Contents/MacOS/UtterInk" \
    > "$dsym_resources/Relocations/aarch64/UtterInk.yml"
  if [[ -f "${UTTERINK_FIXTURE_LOG:?}.archive-app-path-marker" ]]; then
    /usr/bin/printf 'unexpected app path: %s\n' \
      "$fixture_user_root/secret" \
      > "$app/Contents/Resources/local-path.txt"
  fi
  if [[ -f "${UTTERINK_FIXTURE_LOG:?}.archive-wrong-dsym-path" ]]; then
    wrong_dsym="$archive/dSYMs/Wrong.app.dSYM/Contents/Resources/DWARF"
    /bin/mkdir -p "$wrong_dsym"
    /usr/bin/printf 'unexpected DWARF source path: %s\n' \
      "$fixture_user_root/Wrong/App/Main.swift" \
      > "$wrong_dsym/Wrong"
  fi
  if [[ -f "${UTTERINK_FIXTURE_LOG:?}.archive-dsym-secret-marker" ]]; then
    /usr/bin/printf '%s\n' \
      'OPENAI_API_KEY=fixture-not-a-secret' \
      >> "$dsym_resources/DWARF/UtterInk"
  fi
  if [[ -f "${UTTERINK_FIXTURE_LOG:?}.archive-outside-secret" ]]; then
    /bin/mkdir -p "$archive/Metadata"
    /usr/bin/printf '%s%s\n' '-----BEGIN ' 'PRIVATE KEY-----' > "$archive/Metadata/leak.txt"
  fi
  if [[ -f "${UTTERINK_FIXTURE_LOG:?}.archive-outside-abnormal" ]]; then
    /bin/ln -s /private/tmp "$archive/unsafe-link"
  fi
  if [[ -f "${UTTERINK_FIXTURE_LOG:?}.archive-relocating-symlink" ]]; then
    stage_name="$(/usr/bin/basename "$(cd ../.. && /bin/pwd -P)")"
    /bin/mkdir -p "$archive/Relocation"
    /usr/bin/printf 'relocation target\n' > "$archive/Relocation/target.txt"
    /bin/ln -s build ".release-work/$stage_name"
    /bin/ln -s \
      "../../../$stage_name/UtterInk.xcarchive/Relocation/target.txt" \
      "$archive/Relocation/escapes-after-publish"
  fi
  if [[ -f "${UTTERINK_FIXTURE_LOG:?}.archive-world-writable" ]]; then
    /usr/bin/printf 'writable archive entry\n' > "$app/Contents/Resources/writable.txt"
    /bin/chmod 0666 "$app/Contents/Resources/writable.txt"
  fi
  if [[ -f "${UTTERINK_FIXTURE_LOG:?}.archive-hardlink" ]]; then
    /usr/bin/printf 'hard-linked archive entry\n' > "$app/Contents/Resources/hardlink-source.txt"
    /bin/ln "$app/Contents/Resources/hardlink-source.txt" "$app/Contents/Resources/hardlink-alias.txt"
  fi
  exit 0
fi
exit 64
EOF

cat > "$BASE/FixtureTools/file" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'file\t%s\n' "$*" >> "${UTTERINK_FIXTURE_LOG:?}"
case "${*: -1}" in
  */Contents/MacOS/UtterInk)
    if [[ -f "${UTTERINK_FIXTURE_LOG:?}.main-not-macho" ]]; then
      printf 'ASCII text\n'
    else
      printf 'Mach-O 64-bit executable arm64\n'
    fi
    ;;
  *) printf 'ASCII text\n' ;;
esac
EOF

cat > "$BASE/FixtureTools/lipo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'lipo\t%s\n' "$*" >> "${UTTERINK_FIXTURE_LOG:?}"
[[ "${1-}" == '-archs' ]]
if [[ -f "${UTTERINK_FIXTURE_LOG:?}.non-arm64" ]]; then printf 'x86_64\n'; else printf 'arm64\n'; fi
EOF

cat > "$BASE/FixtureTools/otool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'otool\t%s\n' "$*" >> "${UTTERINK_FIXTURE_LOG:?}"
[[ "${1-}" == '-l' ]]
if [[ -f "${UTTERINK_FIXTURE_LOG:?}.unexpected-signature" ]]; then
  printf '      cmd LC_CODE_SIGNATURE\n'
else
  printf '      cmd LC_SEGMENT_64\n'
fi
EOF

cat > "$BASE/FixtureTools/ditto" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ditto\t%s\t%s\n' "$1" "$2" >> "${UTTERINK_FIXTURE_LOG:?}"
/bin/mkdir -p "$(/usr/bin/dirname "$2")"
/bin/cp -Rp "$1" "$2"
EOF

cat > "$BASE/FixtureTools/build-candidate-hook" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
phase="${1:?}"
printf 'build-hook\t%s\n' "$phase" >> "${UTTERINK_FIXTURE_LOG:?}"
case "$phase" in
  before-candidate-copy)
    snapshot="${2:?}"
    if [[ -f "${UTTERINK_FIXTURE_LOG}.candidate-snapshot-late-swap" ]]; then
      /bin/chmod 0600 "$snapshot"
      /usr/bin/printf '{}\n' > "$snapshot"
      /bin/chmod 0400 "$snapshot"
    fi
    ;;
  after-source-checked)
    archive="${2:?}"
    if [[ -f "${UTTERINK_FIXTURE_LOG}.source-swap-after-check" ]]; then
      /usr/bin/printf 'replaced after inspection\n' > "$archive/Products/Applications/UtterInk.app/Contents/MacOS/UtterInk"
      /bin/chmod 0755 "$archive/Products/Applications/UtterInk.app/Contents/MacOS/UtterInk"
    fi
    ;;
  after-stage-checked)
    stage="${2:?}"
    evidence="${3:?}"
    if [[ -f "${UTTERINK_FIXTURE_LOG}.stage-swap-app" ]]; then
      /usr/bin/printf 'replaced after stage inspection\n' > "$stage/candidate/UtterInk.app/Contents/MacOS/UtterInk"
      /bin/chmod 0755 "$stage/candidate/UtterInk.app/Contents/MacOS/UtterInk"
    fi
    if [[ -f "${UTTERINK_FIXTURE_LOG}.stage-swap-evidence" ]]; then
      /usr/bin/printf '{}\n' > "$evidence"
      /bin/chmod 0644 "$evidence"
    fi
    if [[ -f "${UTTERINK_FIXTURE_LOG}.stage-add-xattr" ]]; then
      /usr/bin/xattr -w com.utterink.attack attack "$stage/candidate/candidate.json"
      /usr/bin/xattr -p com.utterink.attack "$stage/candidate/candidate.json" >/dev/null
    fi
    ;;
  before-publish)
    stage="${2:?}"
    if [[ -f "${UTTERINK_FIXTURE_LOG}.publish-add-xattr" ]]; then
      /usr/bin/xattr -w com.utterink.publish-attack attack "$stage/candidate/candidate.json"
      /usr/bin/xattr -p com.utterink.publish-attack "$stage/candidate/candidate.json" >/dev/null
    fi
    ;;
  after-publish-rename)
    published="${2:?}"
    if [[ -f "${UTTERINK_FIXTURE_LOG}.post-rename-replacement" ]]; then
      /bin/mv "$published" "$published.expected-original"
      /bin/mkdir -m 0700 "$published"
      /usr/bin/printf 'replacement must survive cleanup\n' > "$published/replacement-sentinel"
      exit 75
    fi
    if [[ -f "${UTTERINK_FIXTURE_LOG}.post-rename-failure" ]]; then
      exit 75
    fi
    ;;
  *) exit 64 ;;
esac
EOF

/bin/chmod 0755 "$BASE/FixtureTools/"{xcodegen-source,xcodebuild,file,lipo,otool,ditto,build-candidate-hook}

for command_name in bash xcodegen xcodebuild file lipo otool ditto codesign security xcrun curl wget git; do
  cat > "$BASE/OrdinaryPath/$command_name" <<EOF
#!/usr/bin/env bash
printf '$command_name\n' >> '$ORDINARY_LOG'
exit 97
EOF
  /bin/chmod 0755 "$BASE/OrdinaryPath/$command_name"
done

XCODEGEN_HASH="$(/usr/bin/shasum -a 256 "$BASE/FixtureTools/xcodegen-source" | /usr/bin/awk 'NR == 1 { print $1 }')"
/usr/bin/python3 -I - \
  "$BASE/Config/ci-toolchain.json" \
  "$XCODEGEN_HASH" \
  "$BASE/FixtureTools/XcodeGen_XcodeGenKit.bundle/SettingPresets" <<'PY'
from pathlib import Path
import hashlib
import json
import os
import stat
import struct
import sys
path = Path(sys.argv[1])
binary_hash = sys.argv[2]
presets_root = Path(sys.argv[3])

files = []
for directory, directory_names, file_names in os.walk(presets_root):
    directory_names.sort(key=lambda value: value.encode("utf-8", errors="strict"))
    file_names.sort(key=lambda value: value.encode("utf-8", errors="strict"))
    for file_name in file_names:
        file_path = Path(directory) / file_name
        metadata = os.lstat(file_path)
        if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
            raise SystemExit(1)
        relative = file_path.relative_to(presets_root).as_posix().encode("utf-8", errors="strict")
        files.append((relative, file_path.read_bytes()))
if not files:
    raise SystemExit(1)
presets_digest = hashlib.sha256()
for relative, content in sorted(files, key=lambda value: value[0]):
    presets_digest.update(struct.pack(">Q", len(relative)))
    presets_digest.update(relative)
    presets_digest.update(struct.pack(">Q", len(content)))
    presets_digest.update(content)
value = {
    "schemaVersion": 1,
    "runnerImage": {
        "label": "macos-26",
        "releaseTag": "macos-26-arm64/20260720.0258",
        "commit": "4872600e5cdb875ed132ff1c98e2599546c51337",
        "imageVersion": "20260720.0258.1",
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
        "settingPresetsSHA256": presets_digest.hexdigest(),
    },
    "sources": {
        "runnerRelease": "https://github.com/actions/runner-images/releases/tag/macos-26-arm64%2F20260720.0258",
        "runnerReadme": "https://github.com/actions/runner-images/blob/4872600e5cdb875ed132ff1c98e2599546c51337/images/macos/macos-26-arm64-Readme.md",
        "xcodegenRelease": "https://github.com/yonaskolb/XcodeGen/releases/tag/2.45.4",
        "xcodegenCommit": "https://github.com/yonaskolb/XcodeGen/commit/8d3d3476a69ae3e5d68e1adccc701c410c05eb36",
    },
}
path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

/usr/bin/git -C "$BASE" init -q
/usr/bin/git -C "$BASE" config user.name 'UtterInk Build Candidate Test'
/usr/bin/git -C "$BASE" config user.email 'build-candidate@example.invalid'
/usr/bin/git -C "$BASE" add .
/usr/bin/git -C "$BASE" commit -q -m 'offline build candidate fixture'

install_xcodegen() {
  local repository="$1"
  /bin/mkdir -p "$repository/Tools/bin"
  /bin/cp "$repository/FixtureTools/xcodegen-source" "$repository/Tools/bin/xcodegen"
  /bin/cp -R \
    "$repository/FixtureTools/XcodeGen_XcodeGenKit.bundle" \
    "$repository/Tools/bin/XcodeGen_XcodeGenKit.bundle"
  /bin/chmod 0755 "$repository/Tools/bin/xcodegen"
}

FIXTURE_LOG="$TMP/fixture.log"
STDOUT="$TMP/stdout"
STDERR="$TMP/stderr"
BUILD_STATUS=0

run_build() {
  local repository="$1"
  shift
  : > "$FIXTURE_LOG"
  /bin/rm -f "$ORDINARY_LOG" "$BASH_ENV_MARKER" "$STDOUT" "$STDERR"
  set +e
  (
    cd "$repository"
    # A nonexistent injected library aborts the shebang interpreter on
    # macOS 26 before the script can sanitize its environment. A trusted
    # dyld shared-cache library keeps the launch executable while retaining
    # the downstream absence check above.
    /usr/bin/env \
      PATH="$repository/OrdinaryPath:/usr/bin:/bin:/usr/sbin:/sbin" \
      BASH_ENV="$BASH_ENV_CANARY" \
      DEVELOPMENT_TEAM=ATTACKTEAM \
      CODE_SIGN_IDENTITY=ATTACKIDENTITY \
      PROVISIONING_PROFILE_SPECIFIER=ATTACKPROFILE \
      XCODE_XCCONFIG_FILE=/private/tmp/attack.xcconfig \
      DYLD_INSERT_LIBRARIES=/usr/lib/libSystem.B.dylib \
      UTTERINK_RELEASE_TEST_MODE=1 \
      UTTERINK_RELEASE_TEST_TOOL_ROOT="$repository/FixtureTools" \
      UTTERINK_FIXTURE_LOG="$FIXTURE_LOG" \
      ./Scripts/release/build-candidate.sh "$@"
  ) > "$STDOUT" 2> "$STDERR"
  BUILD_STATUS=$?
  set -e
}

assert_no_partial() {
  local repository="$1"
  local work="$2"
  [[ ! -e "$repository/$work" && ! -L "$repository/$work" ]] || fail "failure left output: $work"
  if [[ -d "$repository/.release-work" ]] && /usr/bin/find "$repository/.release-work" -maxdepth 1 -name '.build-candidate.*' -print -quit | /usr/bin/grep -q .; then
    fail "failure left a hidden candidate staging directory: $work"
  fi
}

assert_failed_before_xcode() {
  if /usr/bin/grep -q '^xcodebuild\|^xcodegen' "$FIXTURE_LOG"; then
    fail 'verification failure invoked Xcode or XcodeGen'
  fi
}

BASE_COMMIT="$(/usr/bin/git -C "$BASE" rev-parse HEAD)"
install_xcodegen "$BASE"

run_build "$BASE" --commit "$BASE_COMMIT" --work .release-work/baseline
[[ "$BUILD_STATUS" -eq 0 ]] || fail "baseline build failed: $(/bin/cat "$STDERR"); fixture log: $(/usr/bin/tr '\n' '|' < "$FIXTURE_LOG")"
[[ ! -s "$STDOUT" && ! -s "$STDERR" ]] || fail 'baseline build emitted non-sanitized output'
[[ -d "$BASE/.release-work/baseline/UtterInk.xcarchive" && ! -L "$BASE/.release-work/baseline/UtterInk.xcarchive" ]] || fail 'baseline archive missing'
[[ -f "$BASE/.release-work/baseline/candidate/candidate.json" && ! -L "$BASE/.release-work/baseline/candidate/candidate.json" ]] || fail 'candidate.json missing'
[[ -f "$BASE/.release-work/baseline/candidate/unsigned-build-evidence.json" && ! -L "$BASE/.release-work/baseline/candidate/unsigned-build-evidence.json" ]] || fail 'unsigned build evidence missing'
[[ -d "$BASE/.release-work/baseline/candidate/UtterInk.app" && ! -L "$BASE/.release-work/baseline/candidate/UtterInk.app" ]] || fail 'candidate app missing'
[[ "$(/usr/bin/find "$BASE/.release-work/baseline" -mindepth 1 -maxdepth 1 -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == 2 ]] || fail 'candidate output layout contains extras'
[[ "$(/usr/bin/find "$BASE/.release-work/baseline/candidate" -mindepth 1 -maxdepth 1 -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == 3 ]] || fail 'candidate directory layout does not contain exactly three outputs'
BASELINE_ARCHIVE="$BASE/.release-work/baseline/UtterInk.xcarchive"
FIXTURE_USER_ROOT="/""Users/fixture"
if /usr/bin/xattr -p com.apple.xcode.CreatedByBuildSystem "$BASELINE_ARCHIVE/Products" >/dev/null 2>&1; then
  fail 'normalized archive retained the removable Xcode build-system marker'
fi
/usr/bin/printf 'fixture DWARF source path: %s\n' \
  "$FIXTURE_USER_ROOT/UtterInk/App/Main.swift" |
  /usr/bin/cmp - "$BASELINE_ARCHIVE/dSYMs/UtterInk.app.dSYM/Contents/Resources/DWARF/UtterInk" ||
  fail 'canonical DWARF bytes changed during archive inspection or publication'
/usr/bin/printf "binary-path: '%s'\n" \
  "$FIXTURE_USER_ROOT/Library/Developer/Xcode/DerivedData/UtterInk/Build/UtterInk.app/Contents/MacOS/UtterInk" |
  /usr/bin/cmp - "$BASELINE_ARCHIVE/dSYMs/UtterInk.app.dSYM/Contents/Resources/Relocations/aarch64/UtterInk.yml" ||
  fail 'canonical dSYM relocation bytes changed during archive inspection or publication'
/usr/bin/python3 -I - \
  "$BASE/.release-work/baseline/candidate/candidate.json" \
  "$BASE/.release-work/baseline/candidate/unsigned-build-evidence.json" \
  "$BASE/.release-work/baseline/candidate/UtterInk.app" \
  "$BASE/.release-work/baseline/UtterInk.xcarchive" \
  "$BASE_COMMIT" <<'PY'
from pathlib import Path, PurePosixPath
import hashlib
import json
import os
import stat
import sys

candidate_path, evidence_path, app, archive = map(Path, sys.argv[1:5])
commit = sys.argv[5]
value = json.loads(candidate_path.read_text(encoding="utf-8"))
if value["source"]["commit"] != commit:
    raise SystemExit("candidate commit mismatch")
if value["release"] != {
    "architecture": "arm64",
    "buildNumber": "1",
    "bundleIdentifier": "dev.utterink.UtterInk",
    "configuration": "Release",
    "deploymentTarget": "14.0",
    "dmgFilename": "UtterInk-0.1.0-arm64.dmg",
    "marketingVersion": "0.1.0",
}:
    raise SystemExit("candidate metadata mismatch")

def checked(value):
    value.encode("utf-8", errors="strict")
    if not value or any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise ValueError
    return value

def collect(root):
    records = []
    root = root.resolve(strict=True)
    root_metadata = os.lstat(root)
    if root_metadata.st_uid != os.geteuid() or root_metadata.st_mode & 0o022:
        raise ValueError
    def visit(directory, relative):
        for name in sorted(os.listdir(directory), key=lambda item: checked(item).encode("utf-8")):
            path = directory / name
            child_relative = checked(name if relative == "." else f"{relative}/{name}")
            metadata = os.lstat(path)
            if metadata.st_uid != os.geteuid() or metadata.st_dev != root_metadata.st_dev:
                raise ValueError
            if stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode):
                if metadata.st_mode & 0o022:
                    raise ValueError
                visit(path, child_relative)
            elif stat.S_ISREG(metadata.st_mode):
                if metadata.st_nlink != 1 or metadata.st_mode & 0o022:
                    raise ValueError
                records.append([child_relative, "file", stat.S_IMODE(metadata.st_mode), hashlib.sha256(path.read_bytes()).hexdigest()])
            elif stat.S_ISLNK(metadata.st_mode):
                target = checked(os.readlink(path))
                target_path = PurePosixPath(target)
                joined = PurePosixPath(child_relative).parent.joinpath(target_path)
                if (
                    not target_path.parts
                    or target_path.is_absolute()
                    or ".." in target_path.parts
                    or joined.is_absolute()
                    or ".." in joined.parts
                ):
                    raise ValueError
                (path.parent / target).resolve(strict=True).relative_to(root)
                records.append([child_relative, "symlink", stat.S_IMODE(metadata.st_mode), target])
            else:
                raise ValueError
        if relative != ".":
            metadata = os.lstat(directory)
            records.append([relative, "directory", stat.S_IMODE(metadata.st_mode), ""])
    visit(root, ".")
    records.sort(key=lambda item: checked(item[0]).encode("utf-8"))
    payload = b"".join(
        json.dumps(record, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8") + b"\n"
        for record in records
    )
    return hashlib.sha256(payload).hexdigest()

evidence_bytes = evidence_path.read_bytes()
evidence = json.loads(evidence_bytes.decode("utf-8"))
expected = {
    "appTreeSHA256": collect(app),
    "archiveTreeSHA256": collect(archive),
    "candidateCommit": commit,
    "candidateJSONSHA256": hashlib.sha256(candidate_path.read_bytes()).hexdigest(),
    "evidenceType": "unsigned-build",
    "product": "UtterInk",
    "schemaVersion": 1,
    "status": "valid",
    "treeAlgorithm": "utterink-logical-tree-v1",
}
if evidence != expected:
    raise SystemExit("unsigned build evidence mismatch")
if evidence_bytes != (json.dumps(evidence, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8"):
    raise SystemExit("unsigned build evidence is not canonical JSON")
PY

for expected in \
  $'verify-arg\t--commit' \
  $'verify-arg\t--output' \
  'read-metadata' \
  'verify-entitlements' \
  'verify-info-policy' \
  'third-party-notices' \
  $'xcodegen\tgenerate' \
  $'xcodebuild\t-resolvePackageDependencies' \
  $'swiftpm-state\tprecreated' \
  $'xcodebuild\t-project\tUtterInk.xcodeproj\t-scheme\tUtterInk\t-configuration\tRelease\t-showBuildSettings' \
  $'xcodebuild\tarchive\t-project\tUtterInk.xcodeproj\t-scheme\tUtterInk\t-configuration\tRelease\t-destination\tgeneric/platform=macOS' \
  $'ARCHS=arm64\tONLY_ACTIVE_ARCH=NO\tOTHER_LDFLAGS=-Wl,-no_adhoc_codesign\tCODE_SIGNING_ALLOWED=NO\tCODE_SIGNING_REQUIRED=NO\tCODE_SIGN_IDENTITY=\tDEVELOPMENT_TEAM=\tPROVISIONING_PROFILE_SPECIFIER='; do
  /usr/bin/grep -Fq "$expected" "$FIXTURE_LOG" || fail "baseline skipped or changed required command: $expected"
done
/usr/bin/grep -Eq '^xcodegen-user\t[A-Za-z0-9._-]+$' "$FIXTURE_LOG" ||
  fail 'XcodeGen did not receive a sanitized system username'
if /usr/bin/grep -q $'verify-arg\t--expected-origin' "$FIXTURE_LOG"; then
  fail 'originless build forwarded an implicit origin'
fi
[[ ! -e "$ORDINARY_LOG" && ! -e "$BASH_ENV_MARKER" ]] || fail 'hostile PATH or BASH_ENV was used'
if /usr/bin/grep -Eq 'ATTACKTEAM|ATTACKIDENTITY|ATTACKPROFILE|attack[.]xcconfig|libSystem[.]B[.]dylib' "$FIXTURE_LOG"; then
  fail 'inherited signing or tool injection reached a subprocess'
fi

MISSING_LOCK_REPO="$TMP/missing-lock-repository"
/usr/bin/git clone -q --no-hardlinks "$BASE" "$MISSING_LOCK_REPO"
/usr/bin/git -C "$MISSING_LOCK_REPO" remote remove origin
/usr/bin/git -C "$MISSING_LOCK_REPO" rm -q Config/ci-toolchain.json
/usr/bin/git -C "$MISSING_LOCK_REPO" \
  -c user.name='UtterInk Fixture' -c user.email='fixture@example.invalid' \
  commit -q -m 'remove toolchain lock'
MISSING_LOCK_COMMIT="$(/usr/bin/git -C "$MISSING_LOCK_REPO" rev-parse HEAD)"
run_build "$MISSING_LOCK_REPO" \
  --commit "$MISSING_LOCK_COMMIT" \
  --work .release-work/missing-toolchain-lock
[[ "$BUILD_STATUS" -eq 24 ]] || fail 'missing toolchain lock did not use the stable failure status'
[[ "$(/bin/cat "$STDERR")" == 'build candidate error: toolchain-lock-missing' ]] ||
  fail 'missing toolchain lock diagnostic was not stable'
assert_failed_before_xcode
assert_no_partial "$MISSING_LOCK_REPO" .release-work/missing-toolchain-lock

ORIGIN_REPO="$TMP/origin-repository"
/usr/bin/git clone -q --no-hardlinks "$BASE" "$ORIGIN_REPO"
/usr/bin/git -C "$ORIGIN_REPO" remote remove origin
/usr/bin/git -C "$ORIGIN_REPO" remote add origin 'https://example.invalid/UtterInk.git'
install_xcodegen "$ORIGIN_REPO"
ORIGIN_COMMIT="$(/usr/bin/git -C "$ORIGIN_REPO" rev-parse HEAD)"
run_build "$ORIGIN_REPO" --commit "$ORIGIN_COMMIT" --work .release-work/matching-origin --expected-origin 'https://example.invalid/UtterInk.git'
[[ "$BUILD_STATUS" -eq 0 ]] || fail "matching origin failed: $(/bin/cat "$STDERR")"
[[ "$(/usr/bin/grep -c $'verify-arg\t--expected-origin' "$FIXTURE_LOG")" -eq 1 ]] || fail 'expected origin was not forwarded exactly once'
/usr/bin/grep -Fq $'verify-arg\thttps://example.invalid/UtterInk.git' "$FIXTURE_LOG" || fail 'expected origin value changed in transit'

RESOURCE_BUNDLE="$ORIGIN_REPO/Tools/bin/XcodeGen_XcodeGenKit.bundle"
SETTING_PRESETS="$RESOURCE_BUNDLE/SettingPresets"
RESOURCE_FAILURE_DIAGNOSTIC='build candidate error: repository-xcodegen-mismatch; run ./Scripts/bootstrap-xcodegen.sh'

/bin/mv "$RESOURCE_BUNDLE" "$TMP/missing-XcodeGen_XcodeGenKit.bundle"
run_build "$ORIGIN_REPO" --commit "$ORIGIN_COMMIT" --work .release-work/missing-xcodegen-resources --expected-origin 'https://example.invalid/UtterInk.git'
/bin/mv "$TMP/missing-XcodeGen_XcodeGenKit.bundle" "$RESOURCE_BUNDLE"
[[ "$BUILD_STATUS" -eq 24 ]] || fail 'missing XcodeGen resources did not fail closed with status 24'
[[ "$(/bin/cat "$STDERR")" == "$RESOURCE_FAILURE_DIAGNOSTIC" ]] || fail 'missing XcodeGen resources diagnostic was not stable'
assert_failed_before_xcode
assert_no_partial "$ORIGIN_REPO" .release-work/missing-xcodegen-resources

/bin/cp -p "$SETTING_PRESETS/Base.json" "$TMP/Base.json.saved"
/usr/bin/printf '{"tampered":true}\n' > "$SETTING_PRESETS/Base.json"
run_build "$ORIGIN_REPO" --commit "$ORIGIN_COMMIT" --work .release-work/tampered-xcodegen-resources --expected-origin 'https://example.invalid/UtterInk.git'
/bin/cp -p "$TMP/Base.json.saved" "$SETTING_PRESETS/Base.json"
[[ "$BUILD_STATUS" -eq 24 ]] || fail 'tampered XcodeGen resources did not fail closed with status 24'
[[ "$(/bin/cat "$STDERR")" == "$RESOURCE_FAILURE_DIAGNOSTIC" ]] || fail 'tampered XcodeGen resources diagnostic was not stable'
assert_failed_before_xcode
assert_no_partial "$ORIGIN_REPO" .release-work/tampered-xcodegen-resources

/usr/bin/printf '{"unexpected":true}\n' > "$SETTING_PRESETS/Unexpected.json"
run_build "$ORIGIN_REPO" --commit "$ORIGIN_COMMIT" --work .release-work/extra-xcodegen-resource --expected-origin 'https://example.invalid/UtterInk.git'
/bin/rm "$SETTING_PRESETS/Unexpected.json"
[[ "$BUILD_STATUS" -eq 24 ]] || fail 'extra XcodeGen resource did not fail closed with status 24'
assert_failed_before_xcode
assert_no_partial "$ORIGIN_REPO" .release-work/extra-xcodegen-resource

/usr/bin/printf 'unexpected bundle root entry\n' > "$RESOURCE_BUNDLE/UnexpectedRoot"
run_build "$ORIGIN_REPO" --commit "$ORIGIN_COMMIT" --work .release-work/extra-xcodegen-bundle-entry --expected-origin 'https://example.invalid/UtterInk.git'
/bin/rm "$RESOURCE_BUNDLE/UnexpectedRoot"
[[ "$BUILD_STATUS" -eq 24 ]] || fail 'extra XcodeGen bundle root entry did not fail closed with status 24'
[[ "$(/bin/cat "$STDERR")" == "$RESOURCE_FAILURE_DIAGNOSTIC" ]] || fail 'extra XcodeGen bundle root entry diagnostic was not stable'
assert_failed_before_xcode
assert_no_partial "$ORIGIN_REPO" .release-work/extra-xcodegen-bundle-entry

/bin/ln -s Base.json "$SETTING_PRESETS/UnsafeLink.json"
run_build "$ORIGIN_REPO" --commit "$ORIGIN_COMMIT" --work .release-work/symlink-xcodegen-resource --expected-origin 'https://example.invalid/UtterInk.git'
/bin/rm "$SETTING_PRESETS/UnsafeLink.json"
[[ "$BUILD_STATUS" -eq 24 ]] || fail 'symlink XcodeGen resource did not fail closed with status 24'
assert_failed_before_xcode
assert_no_partial "$ORIGIN_REPO" .release-work/symlink-xcodegen-resource

/usr/bin/mkfifo "$SETTING_PRESETS/UnsafeSpecial"
run_build "$ORIGIN_REPO" --commit "$ORIGIN_COMMIT" --work .release-work/special-xcodegen-resource --expected-origin 'https://example.invalid/UtterInk.git'
/bin/rm "$SETTING_PRESETS/UnsafeSpecial"
[[ "$BUILD_STATUS" -eq 24 ]] || fail 'special XcodeGen resource did not fail closed with status 24'
assert_failed_before_xcode
assert_no_partial "$ORIGIN_REPO" .release-work/special-xcodegen-resource

run_build "$ORIGIN_REPO" --commit "$ORIGIN_COMMIT" --work .release-work/mismatched-origin --expected-origin 'https://example.invalid/Wrong.git'
[[ "$BUILD_STATUS" -ne 0 ]] || fail 'mismatched origin passed'
assert_failed_before_xcode
assert_no_partial "$ORIGIN_REPO" .release-work/mismatched-origin

/usr/bin/printf 'dirty\n' >> "$ORIGIN_REPO/Config/source-sentinel"
[[ -n "$(/usr/bin/git -C "$ORIGIN_REPO" status --porcelain=v1 --untracked-files=all)" ]] || fail 'dirty fixture did not become dirty'
run_build "$ORIGIN_REPO" --commit "$ORIGIN_COMMIT" --work .release-work/dirty --expected-origin 'https://example.invalid/UtterInk.git'
[[ "$BUILD_STATUS" -ne 0 ]] || fail "dirty checkout passed; fixture log: $(/usr/bin/tr '\n' '|' < "$FIXTURE_LOG")"
assert_failed_before_xcode
assert_no_partial "$ORIGIN_REPO" .release-work/dirty
/usr/bin/printf 'committed-source\n' > "$ORIGIN_REPO/Config/source-sentinel"

run_build "$ORIGIN_REPO" --commit 0000000000000000000000000000000000000000 --work .release-work/commit-mismatch --expected-origin 'https://example.invalid/UtterInk.git'
[[ "$BUILD_STATUS" -ne 0 ]] || fail 'commit mismatch passed'
assert_failed_before_xcode
assert_no_partial "$ORIGIN_REPO" .release-work/commit-mismatch

for scenario in candidate-checks-swap candidate-policy-swap candidate-toolchain-swap; do
  /usr/bin/touch "$FIXTURE_LOG.$scenario"
  run_build "$ORIGIN_REPO" --commit "$ORIGIN_COMMIT" --work ".release-work/failure-$scenario" --expected-origin 'https://example.invalid/UtterInk.git'
  /bin/rm -f "$FIXTURE_LOG.$scenario"
  [[ "$BUILD_STATUS" -ne 0 ]] || fail "$scenario candidate evidence unexpectedly passed"
  assert_failed_before_xcode
  assert_no_partial "$ORIGIN_REPO" ".release-work/failure-$scenario"
done

/bin/cp -p "$ORIGIN_REPO/Scripts/release/verify-candidate.sh" "$TMP/verify-candidate.saved"
/usr/bin/printf '# verifier drift\n' >> "$ORIGIN_REPO/Scripts/release/verify-candidate.sh"
run_build "$ORIGIN_REPO" --commit "$ORIGIN_COMMIT" --work .release-work/verifier-blob-mismatch --expected-origin 'https://example.invalid/UtterInk.git'
/bin/cp "$TMP/verify-candidate.saved" "$ORIGIN_REPO/Scripts/release/verify-candidate.sh"
/bin/chmod 0755 "$ORIGIN_REPO/Scripts/release/verify-candidate.sh"
[[ "$BUILD_STATUS" -ne 0 ]] || fail 'verifier bytes differing from the commit blob unexpectedly passed'
assert_failed_before_xcode
assert_no_partial "$ORIGIN_REPO" .release-work/verifier-blob-mismatch

/usr/bin/touch "$FIXTURE_LOG.mutate-verifier"
run_build "$ORIGIN_REPO" --commit "$ORIGIN_COMMIT" --work .release-work/verifier-mutation --expected-origin 'https://example.invalid/UtterInk.git'
/bin/rm -f "$FIXTURE_LOG.mutate-verifier"
[[ "$BUILD_STATUS" -ne 0 ]] || fail 'verifier physical mutation unexpectedly passed'
assert_failed_before_xcode
assert_no_partial "$ORIGIN_REPO" .release-work/verifier-mutation

/usr/bin/touch "$FIXTURE_LOG.mutate-root"
run_build "$ORIGIN_REPO" --commit "$ORIGIN_COMMIT" --work .release-work/exact-clone --expected-origin 'https://example.invalid/UtterInk.git'
/bin/rm -f "$FIXTURE_LOG.mutate-root"
[[ "$BUILD_STATUS" -eq 0 ]] || fail "exact-clone mutation test failed: $(/bin/cat "$STDERR")"
/usr/bin/grep -Fq $'boundary-source\tcommitted-source' "$FIXTURE_LOG" || fail 'build read post-verification worktree bytes instead of exact commit'
/usr/bin/printf 'committed-source\n' > "$ORIGIN_REPO/Config/source-sentinel"

/usr/bin/touch "$FIXTURE_LOG.candidate-output-swap"
run_build "$ORIGIN_REPO" --commit "$ORIGIN_COMMIT" --work .release-work/candidate-snapshot --expected-origin 'https://example.invalid/UtterInk.git'
/bin/rm -f "$FIXTURE_LOG.candidate-output-swap"
[[ "$BUILD_STATUS" -eq 0 ]] || fail "candidate output swap affected sealed snapshot: $(/bin/cat "$STDERR")"
/usr/bin/python3 -I - "$ORIGIN_REPO/.release-work/candidate-snapshot/candidate/candidate.json" "$ORIGIN_COMMIT" <<'PY'
from pathlib import Path
import json
import sys
value = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if value.get("source", {}).get("commit") != sys.argv[2] or value.get("checks", {}).get("history") is not True:
    raise SystemExit(1)
PY

for scenario in swiftpm-extra-state swiftpm-mode-mutation; do
  /usr/bin/touch "$FIXTURE_LOG.$scenario"
  run_build "$ORIGIN_REPO" --commit "$ORIGIN_COMMIT" --work ".release-work/failure-$scenario" --expected-origin 'https://example.invalid/UtterInk.git'
  /bin/rm -f "$FIXTURE_LOG.$scenario"
  [[ "$BUILD_STATUS" -eq 31 ]] || fail "$scenario did not fail at the exact-source inventory boundary"
  [[ "$(/bin/cat "$STDERR")" == 'build candidate error: exact-source-mutated' ]] ||
    fail "$scenario did not emit the stable exact-source mutation diagnostic"
  assert_no_partial "$ORIGIN_REPO" ".release-work/failure-$scenario"
done

for scenario in swiftpm-xcodegen-inject swiftpm-xcodegen-write-delete; do
  /usr/bin/touch "$FIXTURE_LOG.$scenario"
  run_build "$ORIGIN_REPO" --commit "$ORIGIN_COMMIT" --work ".release-work/failure-$scenario" --expected-origin 'https://example.invalid/UtterInk.git'
  /bin/rm -f "$FIXTURE_LOG.$scenario"
  [[ "$BUILD_STATUS" -eq 32 ]] || fail "$scenario did not fail before the final inventory"
  [[ "$(/bin/cat "$STDERR")" == 'build candidate error: exact-source-mutated' ]] ||
    fail "$scenario did not emit the stable exact-source mutation diagnostic"
  assert_no_partial "$ORIGIN_REPO" ".release-work/failure-$scenario"
done

for scenario in \
  archive-build-marker-wrong-value \
  archive-build-marker-extra-xattr \
  archive-build-marker-wrong-path \
  archive-app-path-marker \
  archive-wrong-dsym-path \
  archive-dsym-secret-marker; do
  /usr/bin/touch "$FIXTURE_LOG.$scenario"
  run_build "$ORIGIN_REPO" --commit "$ORIGIN_COMMIT" --work ".release-work/failure-$scenario" --expected-origin 'https://example.invalid/UtterInk.git'
  /bin/rm -f "$FIXTURE_LOG.$scenario"
  [[ "$BUILD_STATUS" -eq 35 ]] || fail "$scenario did not fail at the archive content boundary"
  [[ "$(/bin/cat "$STDERR")" == 'build candidate error: forbidden-archive-content' ]] ||
    fail "$scenario did not emit the stable forbidden archive content diagnostic"
  assert_no_partial "$ORIGIN_REPO" ".release-work/failure-$scenario"
done

for scenario in \
  hardened-mismatch \
  metadata-mismatch \
  mutate-lock \
  mutate-project \
  non-arm64 \
  unexpected-signature \
  archive-failure \
  candidate-snapshot-swap \
  swap-source-restore \
  archive-outside-secret \
  archive-outside-abnormal \
  archive-relocating-symlink \
  archive-world-writable \
  archive-hardlink \
  main-not-macho \
  source-swap-after-check \
  candidate-snapshot-late-swap \
  stage-swap-app \
  stage-swap-evidence \
  stage-add-xattr \
  publish-add-xattr \
  post-rename-failure \
  cleanup-writable; do
  /usr/bin/touch "$FIXTURE_LOG.$scenario"
  run_build "$ORIGIN_REPO" --commit "$ORIGIN_COMMIT" --work ".release-work/failure-$scenario" --expected-origin 'https://example.invalid/UtterInk.git'
  /bin/rm -f "$FIXTURE_LOG.$scenario"
  [[ "$BUILD_STATUS" -ne 0 ]] || fail "$scenario unexpectedly passed"
  assert_no_partial "$ORIGIN_REPO" ".release-work/failure-$scenario"
done

/usr/bin/touch "$FIXTURE_LOG.post-rename-replacement"
replacement_work=.release-work/failure-post-rename-replacement
run_build "$ORIGIN_REPO" --commit "$ORIGIN_COMMIT" --work "$replacement_work" --expected-origin 'https://example.invalid/UtterInk.git'
/bin/rm -f "$FIXTURE_LOG.post-rename-replacement"
[[ "$BUILD_STATUS" -ne 0 ]] || fail 'post-rename path replacement unexpectedly passed'
replacement_path="$ORIGIN_REPO/$replacement_work"
original_path="$replacement_path.expected-original"
[[ "$(/bin/cat "$replacement_path/replacement-sentinel")" == 'replacement must survive cleanup' ]] ||
  fail 'cleanup deleted or changed the post-rename replacement'
[[ -d "$original_path" && ! -L "$original_path" ]] ||
  fail 'post-rename replacement fixture lost the original generated tree'
/bin/rm -rf "$replacement_path" "$original_path"

run_build "$ORIGIN_REPO" --commit "$ORIGIN_COMMIT" --work ../outside --expected-origin 'https://example.invalid/UtterInk.git'
[[ "$BUILD_STATUS" -ne 0 ]] || fail 'parent traversal work path passed'
assert_failed_before_xcode

run_build "$ORIGIN_REPO" --commit "$ORIGIN_COMMIT" --work "$TMP/outside" --expected-origin 'https://example.invalid/UtterInk.git'
[[ "$BUILD_STATUS" -ne 0 ]] || fail 'outside absolute work path passed'
assert_failed_before_xcode

/bin/mkdir -p "$ORIGIN_REPO/.release-work/existing"
run_build "$ORIGIN_REPO" --commit "$ORIGIN_COMMIT" --work .release-work/existing --expected-origin 'https://example.invalid/UtterInk.git'
[[ "$BUILD_STATUS" -ne 0 ]] || fail 'existing work directory was clobbered'
assert_failed_before_xcode

/bin/ln -s "$TMP" "$ORIGIN_REPO/.release-work/symlink-output"
run_build "$ORIGIN_REPO" --commit "$ORIGIN_COMMIT" --work .release-work/symlink-output --expected-origin 'https://example.invalid/UtterInk.git'
[[ "$BUILD_STATUS" -ne 0 ]] || fail 'symlink work path passed'
assert_failed_before_xcode
[[ -L "$ORIGIN_REPO/.release-work/symlink-output" ]] || fail 'symlink work path was modified'

run_build "$ORIGIN_REPO" --commit "$ORIGIN_COMMIT" --work .release-work/duplicate --work .release-work/duplicate-2 --expected-origin 'https://example.invalid/UtterInk.git'
[[ "$BUILD_STATUS" -eq 64 ]] || fail 'duplicate work flag did not return usage status 64'
assert_failed_before_xcode

run_build "$ORIGIN_REPO" --commit "$ORIGIN_COMMIT" --work .release-work/unknown --unknown --expected-origin 'https://example.invalid/UtterInk.git'
[[ "$BUILD_STATUS" -eq 64 ]] || fail 'unknown flag did not return usage status 64'
assert_failed_before_xcode

[[ ! -e "$ORDINARY_LOG" && ! -e "$BASH_ENV_MARKER" ]] || fail 'a failure path used hostile PATH or BASH_ENV'
/usr/bin/printf 'build candidate tests passed\n'
