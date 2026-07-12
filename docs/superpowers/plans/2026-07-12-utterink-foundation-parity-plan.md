# UtterInk Foundation and Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish a rights-reviewed, hash-locked FlowType parity baseline and a clean, standard, buildable UtterInk Xcode application plus local Swift package.

**Architecture:** Preserve the rescued implementation temporarily under `LegacyParity/` without its Git/build history, then create the final Xcode/SPM skeleton alongside it. No FlowType code is yet refactored into the final package in this plan; that separation makes baseline behavior and later changes independently reviewable.

**Tech Stack:** Bash, Git, SwiftPM 5.9, Xcode 26.4+, XcodeGen 2.45.4, XCTest, macOS 14 deployment target, arm64.

## Global Constraints

- Treat `$HOME/Documents/Myprojects/FlowType` as read-only; never run a formatter or write-producing build in that directory.
- Import only literal allowlisted files whose current hashes and publication rights have been reviewed.
- Never copy `.git`, `.build`, `.swiftpm`, `dist`, `.DS_Store`, `.env*`, secrets, model caches, or DMGs.
- Final product name is `UtterInk`, bundle ID `dev.utterink.UtterInk`, macOS 14+, arm64, Apache-2.0.
- Third-party dependencies use only Swift Package Manager and committed resolution data.
- No external repository, push, upload, transfer, visibility change, or release action is authorized.

---

### Task 1: Repository hygiene and reviewed import manifest

**Files:**
- Create: `.gitignore`
- Create: `.gitattributes`
- Create: `Config/legacy-import-allowlist.txt`
- Create after concrete user rights response: `Config/legacy-rights.local.tsv` (ignored local review input)
- Create: `Scripts/generate-import-manifest.sh`
- Create: `Scripts/scan-public-history.sh`
- Create: `Tests/Scripts/test-generate-import-manifest.sh`
- Create: `Tests/Scripts/test-scan-public-history.sh`
- Generate: `docs/provenance/legacy-source-import.tsv`

**Interfaces:**
- Consumes: read-only legacy root and a concrete rights assertion from the user/reviewer.
- Produces: a TSV whose columns are `source_path`, `destination_path`, `sha256`, `purpose`, `copyright_owner`, `license_or_authority`, `reviewer`.

- [ ] **Step 1: Write the failing shell test**

Create `Tests/Scripts/test-generate-import-manifest.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/legacy/Sources/App" "$TMP/config" "$TMP/out"
printf 'let value = 1\n' > "$TMP/legacy/Sources/App/Main.swift"
printf 'secret\n' > "$TMP/legacy/.env"
printf 'Sources/App/Main.swift\n' > "$TMP/config/allowlist.txt"
printf 'source_path\tcopyright_owner\tlicense_or_authority\treviewer\nSources/App/Main.swift\tExample Owner\tAuthorized for Apache-2.0\tTest Reviewer\n' > "$TMP/config/rights.tsv"

"$ROOT/Scripts/generate-import-manifest.sh" \
  "$TMP/legacy" "$TMP/config/allowlist.txt" "$TMP/config/rights.tsv" "$TMP/out/manifest.tsv"

grep -F $'Sources/App/Main.swift\tLegacyParity/Sources/App/Main.swift' "$TMP/out/manifest.tsv"
grep -F 'Example Owner' "$TMP/out/manifest.tsv"
if grep -F '.env' "$TMP/out/manifest.tsv"; then
  echo 'forbidden file entered manifest' >&2
  exit 1
fi

printf 'Sources/App/Main.swift\n.build/object.o\n' > "$TMP/config/allowlist.txt"
if "$ROOT/Scripts/generate-import-manifest.sh" \
  "$TMP/legacy" "$TMP/config/allowlist.txt" "$TMP/config/rights.tsv" "$TMP/out/manifest.tsv"; then
  echo 'forbidden allowlist entry was accepted' >&2
  exit 1
fi
```

- [ ] **Step 2: Run it to verify it fails**

Run:

```bash
bash Tests/Scripts/test-generate-import-manifest.sh
```

Expected: FAIL with `Scripts/generate-import-manifest.sh: No such file or directory`.

- [ ] **Step 3: Add repository exclusions and the literal source allowlist**

Create `.gitignore`:

```gitignore
.DS_Store
.build/
.swiftpm/
DerivedData/
dist/
*.dmg
*.xcarchive
*.xcresult
.env
.env.*
!.env.example
*.pem
*.p12
*.cer
*.mobileprovision
secrets/
Models/
*.caf
*.wav
xcuserdata/
Config/legacy-rights.local.tsv
```

Create `.gitattributes`:

```gitattributes
* text=auto
*.swift text eol=lf
*.md text eol=lf
*.sh text eol=lf
*.json text eol=lf
*.plist text eol=lf
*.png binary
*.icns binary
*.dmg binary
```

Create `Config/legacy-import-allowlist.txt` with these exact current-working-tree files and no glob expansion:

```text
Package.swift
Package.resolved
Sources/FlowType/AppLocalization.swift
Sources/FlowType/Core/Constants.swift
Sources/FlowType/Core/FlowCoordinator.swift
Sources/FlowType/Core/HotkeyManager.swift
Sources/FlowType/Core/LLMProcessor.swift
Sources/FlowType/Core/LLMProviderCatalog.swift
Sources/FlowType/Core/LLMProviderProfiles.swift
Sources/FlowType/Core/MicrophoneRecorder.swift
Sources/FlowType/Core/OpenRouterConfig.swift
Sources/FlowType/Core/OutputModesStorage.swift
Sources/FlowType/Core/Progress+WhisperDownload.swift
Sources/FlowType/Core/SpeechTranscriptionSettings.swift
Sources/FlowType/Core/TextInjector.swift
Sources/FlowType/Core/WhisperTranscriptionLanguageCatalog.swift
Sources/FlowType/FlowTypeApp.swift
Sources/FlowType/FlowTypeResourceBundle.swift
Sources/FlowType/Info.plist
Sources/FlowType/MenuBarRootView.swift
Sources/FlowType/OnboardingPreferences.swift
Sources/FlowType/OnboardingView.swift
Sources/FlowType/OnboardingWindowController.swift
Sources/FlowType/OutputModesSettingsPane.swift
Sources/FlowType/Resources/AppDockIcon.png
Sources/FlowType/Resources/Media.xcassets/Contents.json
Sources/FlowType/Resources/Media.xcassets/MenuBarIcon.imageset/Contents.json
Sources/FlowType/Resources/Media.xcassets/MenuBarIcon.imageset/MenuBarIcon.png
Sources/FlowType/Resources/Media.xcassets/MenuBarIcon.imageset/MenuBarIcon@2x.png
Sources/FlowType/Resources/MenuBarIcon_statusbar.png
Sources/FlowType/Resources/MenuBarIcon_statusbar@2x.png
Sources/FlowType/Resources/README.txt
Sources/FlowType/SettingsView.swift
Sources/FlowType/SettingsWindowHelper.swift
Sources/FlowType/SpeechModelsSettingsPane.swift
Sources/FlowType/UI/DynamicIslandView.swift
Sources/FlowType/UI/FloatingWindowController.swift
Sources/FlowType/WhisperModelCacheInspector.swift
Sources/FlowType/WhisperModelCatalog.swift
Tests/FlowTypeTests/HotkeyManagerTests.swift
```

- [ ] **Step 4: Obtain the publication-rights facts before generating the real manifest**

Ask the user/reviewer to identify the copyright owner, Apache-2.0 relicensing authority, and reviewer for the allowlisted source and raster assets. Do not infer legal ownership. Once concrete values are supplied, create ignored local input `Config/legacy-rights.local.tsv` with one row per allowlisted path and no blank or provisional values. If ownership differs by file, preserve that distinction. The generated public manifest retains the necessary reviewed ownership/license facts; the local input itself is never staged. Stop this plan if any row is unknown or incompatible.

- [ ] **Step 5: Implement the manifest generator**

Create `Scripts/generate-import-manifest.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

LEGACY_ROOT="${1:?legacy root required}"
ALLOWLIST="${2:?allowlist required}"
RIGHTS="${3:?rights TSV required}"
OUTPUT="${4:?output TSV required}"

for required in "$LEGACY_ROOT" "$ALLOWLIST" "$RIGHTS"; do
  [[ -e "$required" ]] || { echo "missing: $required" >&2; exit 1; }
done

awk 'NF && seen[$0]++ { exit 1 }' "$ALLOWLIST" || { echo "duplicate allowlist entry" >&2; exit 1; }
awk -F '\t' 'NR > 1 && seen[$1]++ { exit 1 }' "$RIGHTS" || { echo "duplicate rights row" >&2; exit 1; }
legacy_real="$(cd "$LEGACY_ROOT" && pwd -P)"

tmp="${OUTPUT}.tmp.$$"
trap 'rm -f "$tmp"' EXIT
mkdir -p "$(dirname "$OUTPUT")"
printf 'source_path\tdestination_path\tsha256\tpurpose\tcopyright_owner\tlicense_or_authority\treviewer\n' > "$tmp"

purpose_for() {
  case "$1" in
    Package.*) echo package-metadata ;;
    Tests/*) echo parity-test ;;
    *.png|*.json|*.txt) echo parity-resource ;;
    *.plist) echo parity-configuration ;;
    *.swift) echo parity-source ;;
    *) echo unsupported >&2; return 1 ;;
  esac
}

while IFS= read -r path || [[ -n "$path" ]]; do
  [[ -n "$path" ]] || continue
  case "$path" in
    /*|*..*|.git/*|.build/*|.swiftpm/*|dist/*|*.dmg|.DS_Store|*/.DS_Store|.env|.env.*)
      echo "forbidden allowlist entry: $path" >&2
      exit 1
      ;;
  esac
  source="$LEGACY_ROOT/$path"
  [[ -f "$source" && ! -L "$source" ]] || { echo "missing or symlink source: $path" >&2; exit 1; }
  source_real="$(cd "$(dirname "$source")" && pwd -P)/$(basename "$source")"
  case "$source_real" in "$legacy_real"/*) ;; *) echo "source escaped legacy root: $path" >&2; exit 1 ;; esac
  rights_line="$(awk -F '\t' -v key="$path" 'NR > 1 && $1 == key { print $2 "\t" $3 "\t" $4 }' "$RIGHTS")"
  [[ -n "$rights_line" ]] || { echo "missing rights row: $path" >&2; exit 1; }
  owner="${rights_line%%$'\t'*}"
  remainder="${rights_line#*$'\t'}"
  authority="${remainder%%$'\t'*}"
  reviewer="${remainder#*$'\t'}"
  [[ -n "$owner" && -n "$authority" && -n "$reviewer" ]] || { echo "incomplete rights row: $path" >&2; exit 1; }
  sha="$(shasum -a 256 "$source" | awk '{print $1}')"
  printf '%s\tLegacyParity/%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$path" "$path" "$sha" "$(purpose_for "$path")" "$owner" "$authority" "$reviewer" >> "$tmp"
done < "$ALLOWLIST"

mv "$tmp" "$OUTPUT"
trap - EXIT
```

- [ ] **Step 6: Write and prove the full-object history scanner before import**

`Tests/Scripts/test-scan-public-history.sh` creates isolated fixture repositories and proves the scanner catches: a secret/private path in the worktree; a staged value; a value committed then deleted; an unreachable blob after branch deletion; PEM/private-key and common token forms; provider keys/transcript canaries; personal absolute paths; legacy FlowType refs/remotes; a second root; alternates, grafts, and replace refs. It asserts diagnostics contain only object/file/category and never echo the matched value. It also proves a clean single-root fixture passes and that an explicitly supplied sanitized current-repository `origin` is the only permitted remote.

`Scripts/scan-public-history.sh` must inspect the working tree, index, every reachable commit/tree/blob, and all loose/packed unreachable objects from `git cat-file --batch-all-objects`; bound binary reads, classify/redact findings, and fail closed on unscannable text candidates. When the import manifest exists, every `LegacyParity/` blob/path found in any commit must match one manifest destination/hash with complete Apache-compatible rights fields; an unmanifested or hash-divergent legacy blob is a license/provenance failure. It requires one new-history root, no legacy-named refs/tags, no unauthorized remote, no alternates/grafts/replace refs, and no legacy Git linkage. `--expected-origin <canonical URL>` may allow exactly one credential-free `origin`; without it, no remote is allowed. It never runs cleanup or history rewriting.

Run `bash Tests/Scripts/test-scan-public-history.sh`; expect PASS.

- [ ] **Step 7: Run the focused tests and generate/review the real manifest**

Run:

```bash
chmod +x Scripts/generate-import-manifest.sh Scripts/scan-public-history.sh Tests/Scripts/test-generate-import-manifest.sh Tests/Scripts/test-scan-public-history.sh
bash Tests/Scripts/test-generate-import-manifest.sh
bash Tests/Scripts/test-scan-public-history.sh
./Scripts/generate-import-manifest.sh \
  "$HOME/Documents/Myprojects/FlowType" \
  Config/legacy-import-allowlist.txt \
  Config/legacy-rights.local.tsv \
  docs/provenance/legacy-source-import.tsv
wc -l docs/provenance/legacy-source-import.tsv
rg -n '\.git|\.build|\.swiftpm|dist/|\.DS_Store|\.env|\.dmg' docs/provenance/legacy-source-import.tsv
```

Expected: test exits 0; manifest line count is `41` (header plus 40 files); the final `rg` returns no matches.

- [ ] **Step 8: Commit and immediately scan the complete new history**

```bash
git add .gitignore .gitattributes Config Scripts/generate-import-manifest.sh Scripts/scan-public-history.sh Tests/Scripts/test-generate-import-manifest.sh Tests/Scripts/test-scan-public-history.sh docs/provenance/legacy-source-import.tsv
git commit -m "chore: lock reviewed FlowType import manifest"
./Scripts/scan-public-history.sh
```

Confirm `git check-ignore Config/legacy-rights.local.tsv` succeeds before committing. The committed manifest is the public review record; never add the local input with `git add -f`.

If the scanner finds sensitive/private material in any Git object, stop. Because the repository is still unpublished, request the required destructive-operation approval, discard/reinitialize the new UtterInk Git history, and replay only the reviewed clean commits; never “fix” the leak with a later deletion commit.

---

### Task 2: Import and prove the FlowType parity baseline

**Files:**
- Create: `Scripts/import-legacy-parity.sh`
- Create: `Tests/Scripts/test-import-legacy-parity.sh`
- Create: `LegacyParity/**` from the reviewed manifest
- Create: `docs/parity/flowtype-behavior-baseline.md`

**Interfaces:**
- Consumes: `docs/provenance/legacy-source-import.tsv` from Task 1.
- Produces: a hash-identical SwiftPM snapshot that builds/tests without reading the legacy directory afterward.

- [ ] **Step 1: Write the failing importer test**

Create `Tests/Scripts/test-import-legacy-parity.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/legacy/Sources" "$TMP/repo/docs/provenance"
printf 'let parity = true\n' > "$TMP/legacy/Sources/Main.swift"
sha="$(shasum -a 256 "$TMP/legacy/Sources/Main.swift" | awk '{print $1}')"
printf 'source_path\tdestination_path\tsha256\tpurpose\tcopyright_owner\tlicense_or_authority\treviewer\nSources/Main.swift\tLegacyParity/Sources/Main.swift\t%s\tparity-source\tExample Owner\tAuthorized for Apache-2.0\tTest Reviewer\n' "$sha" > "$TMP/repo/docs/provenance/legacy-source-import.tsv"
(cd "$TMP/repo" && "$ROOT/Scripts/import-legacy-parity.sh" "$TMP/legacy" docs/provenance/legacy-source-import.tsv)
cmp "$TMP/legacy/Sources/Main.swift" "$TMP/repo/LegacyParity/Sources/Main.swift"
```

- [ ] **Step 2: Run it to verify it fails**

Run `bash Tests/Scripts/test-import-legacy-parity.sh`.

Expected: FAIL because `Scripts/import-legacy-parity.sh` does not exist.

- [ ] **Step 3: Implement the hash-verifying importer**

Create `Scripts/import-legacy-parity.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
LEGACY_ROOT="${1:?legacy root required}"
MANIFEST="${2:?manifest required}"

[[ ! -e LegacyParity ]] || { echo 'LegacyParity already exists' >&2; exit 1; }
mkdir -p LegacyParity

tail -n +2 "$MANIFEST" | while IFS=$'\t' read -r source destination expected _; do
  [[ "$destination" == LegacyParity/* ]] || { echo "bad destination: $destination" >&2; exit 1; }
  actual="$(shasum -a 256 "$LEGACY_ROOT/$source" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || { echo "hash mismatch: $source" >&2; exit 1; }
  mkdir -p "$(dirname "$destination")"
  cp -p "$LEGACY_ROOT/$source" "$destination"
done

if find LegacyParity -name .DS_Store -o -name .env -o -name .build -o -name .git | grep -q .; then
  echo 'forbidden import artifact found' >&2
  exit 1
fi
```

- [ ] **Step 4: Import the reviewed snapshot and run its original test**

```bash
chmod +x Scripts/import-legacy-parity.sh Tests/Scripts/test-import-legacy-parity.sh
bash Tests/Scripts/test-import-legacy-parity.sh
./Scripts/import-legacy-parity.sh "$HOME/Documents/Myprojects/FlowType" docs/provenance/legacy-source-import.tsv
swift test --package-path LegacyParity
swift build --package-path LegacyParity
```

Expected: importer test passes; SwiftPM resolves KeyboardShortcuts 2.4.0 and WhisperKit 0.18.0; the original `HotkeyManagerTests.testInitialization` passes; build exits 0.

- [ ] **Step 5: Record the behavioral baseline**

Create `docs/parity/flowtype-behavior-baseline.md` with this exact acceptance table:

```markdown
# FlowType parity baseline

Source snapshot: `docs/provenance/legacy-source-import.tsv`.

| Behavior | Rescued implementation evidence | UtterInk replacement gate |
|---|---|---|
| Menu-bar lifecycle | `FlowTypeApp`, `MenuBarRootView` | UtterInk menu and settings launch |
| Toggle and push-to-talk | `HotkeyManager` | Intent-only hotkey tests for both modes |
| Microphone CAF recording and level | `MicrophoneRecorder` | Permission/capture/cleanup adapter tests |
| WhisperKit download/load/transcribe | `FlowCoordinator`, `WhisperModelCacheInspector` | Separate model state plus local transcription integration |
| Language and auto-detect | `SpeechTranscriptionSettings` | Immutable session recognition snapshot |
| Raw and custom output modes | `OutputModesStorage` | Raw-first pipeline and editable modes |
| OpenAI-compatible providers | `LLMProviderCatalog`, `LLMProcessor` | HTTPS/loopback policy, Keychain, sanitized errors |
| Raw fallback | `FlowCoordinator.finishTranscribedPipeline` | Raw persisted before polish; warning on fallback |
| Paste | `TextInjector` | Target/focus validation and guarded restoration |
| Floating status | `DynamicIslandView` | Stage-specific non-authoritative view |
| Onboarding/settings | `OnboardingView`, `SettingsView` | First-success onboarding and complete P0 settings |

The final app may intentionally change unsafe behavior described in the approved design; those changes are not parity regressions.
```

- [ ] **Step 6: Commit and immediately rescan every Git object**

```bash
git add Scripts/import-legacy-parity.sh Tests/Scripts/test-import-legacy-parity.sh LegacyParity docs/parity/flowtype-behavior-baseline.md
git commit -m "chore: import reviewed FlowType parity snapshot"
./Scripts/scan-public-history.sh
```

Expected: zero secret/private-data/history-structure findings. Any finding stops work and uses the unpublished-repository rebuild rule from Task 1; do not proceed to the Xcode skeleton.

---

### Task 3: Create the final Xcode app and local package skeleton

**Files:**
- Create: `project.yml`
- Generate: `UtterInk.xcodeproj/**`
- Create: `App/UtterInkApp.swift`
- Create: `App/Supporting/Info.plist`
- Create: `App/Supporting/UtterInk.entitlements`
- Create: `Packages/UtterInkKit/Package.swift`
- Generate: `Packages/UtterInkKit/Package.resolved`
- Generate if Xcode creates it: `UtterInk.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- Create: `Scripts/check-package-resolution.py`
- Create: `Tests/Scripts/test-check-package-resolution.py`
- Create: `Packages/UtterInkKit/Sources/UtterInkCore/ProductIdentity.swift`
- Create: `Packages/UtterInkKit/Sources/UtterInkServices/ServicesMarker.swift`
- Test: `Packages/UtterInkKit/Tests/UtterInkCoreTests/ProductIdentityTests.swift`

**Interfaces:**
- Produces: Xcode app product `UtterInk`; package products `UtterInkCore` and `UtterInkServices`.

- [ ] **Step 1: Write the first failing package test**

Create `Packages/UtterInkKit/Tests/UtterInkCoreTests/ProductIdentityTests.swift`:

```swift
import XCTest
@testable import UtterInkCore

final class ProductIdentityTests: XCTestCase {
    func testReleaseIdentity() {
        XCTAssertEqual(ProductIdentity.name, "UtterInk")
        XCTAssertEqual(ProductIdentity.bundleIdentifier, "dev.utterink.UtterInk")
        XCTAssertEqual(ProductIdentity.minimumMacOS, "14.0")
        XCTAssertEqual(ProductIdentity.releaseArchitecture, "arm64")
    }
}
```

- [ ] **Step 2: Add the package manifest and verify the test fails to compile**

Create `Packages/UtterInkKit/Package.swift`:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UtterInkKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UtterInkCore", targets: ["UtterInkCore"]),
        .library(name: "UtterInkServices", targets: ["UtterInkServices"])
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "2.4.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "0.18.0")
    ],
    targets: [
        .target(name: "UtterInkCore"),
        .target(
            name: "UtterInkServices",
            dependencies: [
                "UtterInkCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "WhisperKit", package: "WhisperKit")
            ]
        ),
        .testTarget(name: "UtterInkCoreTests", dependencies: ["UtterInkCore"]),
        .testTarget(name: "UtterInkServicesTests", dependencies: ["UtterInkCore", "UtterInkServices"])
    ]
)
```

Create source markers with `apply_patch` so SwiftPM recognizes both targets:

`Packages/UtterInkKit/Sources/UtterInkCore/ProductIdentity.swift`:

```swift
public enum ProductIdentity {}
```

`Packages/UtterInkKit/Sources/UtterInkServices/ServicesMarker.swift`:

```swift
public enum ServicesMarker {}
```

`Packages/UtterInkKit/Tests/UtterInkServicesTests/ServicesMarkerTests.swift`:

```swift
import XCTest
@testable import UtterInkServices

final class ServicesMarkerTests: XCTestCase {}
```

Then run:

```bash
swift test --package-path Packages/UtterInkKit
```

Expected: FAIL because `ProductIdentity` has no `name`, `bundleIdentifier`, `minimumMacOS`, or `releaseArchitecture` member. The failure is the intended contract red light, not an empty/missing-target manifest error.

- [ ] **Step 3: Add the minimal identity implementation**

Replace the empty shell in `Packages/UtterInkKit/Sources/UtterInkCore/ProductIdentity.swift` with:

```swift
public enum ProductIdentity {
    public static let name = "UtterInk"
    public static let bundleIdentifier = "dev.utterink.UtterInk"
    public static let minimumMacOS = "14.0"
    public static let releaseArchitecture = "arm64"
}
```

- [ ] **Step 4: Add the standard app target configuration**

Create `project.yml`:

```yaml
name: UtterInk
options:
  xcodeVersion: "26.4"
  deploymentTarget:
    macOS: "14.0"
  createIntermediateGroups: true
packages:
  UtterInkKit:
    path: Packages/UtterInkKit
targets:
  UtterInk:
    type: application
    platform: macOS
    deploymentTarget: "14.0"
    sources:
      - path: App
    info:
      path: App/Supporting/Info.plist
    entitlements:
      path: App/Supporting/UtterInk.entitlements
    dependencies:
      - package: UtterInkKit
        product: UtterInkCore
      - package: UtterInkKit
        product: UtterInkServices
    settings:
      base:
        PRODUCT_NAME: UtterInk
        PRODUCT_BUNDLE_IDENTIFIER: dev.utterink.UtterInk
        MACOSX_DEPLOYMENT_TARGET: "14.0"
        ARCHS: arm64
        SWIFT_VERSION: "5.0"
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"
        CODE_SIGN_STYLE: Automatic
        ENABLE_HARDENED_RUNTIME: YES
        GENERATE_INFOPLIST_FILE: NO
schemes:
  UtterInk:
    build:
      targets:
        UtterInk: all
    run:
      config: Debug
    archive:
      config: Release
```

Create `App/Supporting/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleDisplayName</key><string>UtterInk</string>
    <key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>UtterInk</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$(MARKETING_VERSION)</string>
    <key>CFBundleVersion</key><string>$(CURRENT_PROJECT_VERSION)</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>UtterInk uses the microphone to transcribe speech locally on this Mac.</string>
</dict>
</plist>
```

Create `App/Supporting/UtterInk.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>com.apple.security.device.audio-input</key><true/>
</dict></plist>
```

Create `App/UtterInkApp.swift`:

```swift
import SwiftUI
import UtterInkCore

@main
struct UtterInkApp: App {
    var body: some Scene {
        MenuBarExtra(ProductIdentity.name, systemImage: "text.cursor") {
            Text("UtterInk foundation ready")
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }

        Settings {
            Text("UtterInk Settings")
                .padding(24)
        }
    }
}
```

- [ ] **Step 5: Write and run the failing resolution-lock test**

`Tests/Scripts/test-check-package-resolution.py` uses matching, mismatching, missing, duplicate-identity, and mutable-branch fixtures. Run it first and expect failure because `Scripts/check-package-resolution.py` does not exist. Then implement the checker with `Packages/UtterInkKit/Package.resolved` as authority.

- [ ] **Step 6: Generate, build, and test**

```bash
swift package resolve --package-path Packages/UtterInkKit
swift test --package-path Packages/UtterInkKit
xcodegen generate
xcodebuild -project UtterInk.xcodeproj -scheme UtterInk -resolvePackageDependencies
python3 Scripts/check-package-resolution.py
xcodebuild -project UtterInk.xcodeproj -scheme UtterInk -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build
if /usr/libexec/PlistBuddy -c 'Print :NSAppTransportSecurity:NSAllowsArbitraryLoads' App/Supporting/Info.plist >/dev/null 2>&1; then
  echo 'global arbitrary loads must be absent' >&2
  exit 1
fi
```

If Xcode emits a workspace resolution file, commit it and require the normalized identity/version/revision graph to equal the authoritative lock; a missing workspace lock is allowed only when Xcode demonstrably consumes the nested graph and generates no second lock. Package resolution/build may not change either file. Expected: package/tests/checker pass; Xcode build ends `** BUILD SUCCEEDED **`; the ATS lookup fails because the key is absent.

- [ ] **Step 7: Commit**

```bash
git add project.yml UtterInk.xcodeproj App Packages/UtterInkKit Scripts/check-package-resolution.py Tests/Scripts/test-check-package-resolution.py
git commit -m "build: add UtterInk Xcode and package skeleton"
./Scripts/scan-public-history.sh
```

---

### Task 4: Add one local verification entrypoint

**Files:**
- Create: `Scripts/ci-local.sh`
- Create: `Scripts/check-repo-hygiene.sh`
- Test: `Tests/Scripts/test-check-repo-hygiene.sh`

**Interfaces:**
- Produces: `./Scripts/ci-local.sh`, the regression entrypoint every later task uses.

- [ ] **Step 1: Write the failing hygiene test**

Create `Tests/Scripts/test-check-repo-hygiene.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" init -q
printf 'ok\n' > "$TMP/README.md"
git -C "$TMP" add README.md
(cd "$TMP" && "$ROOT/Scripts/check-repo-hygiene.sh")
mkdir -p "$TMP/.build"
printf 'bad\n' > "$TMP/.build/object.o"
git -C "$TMP" add -f .build/object.o
if (cd "$TMP" && "$ROOT/Scripts/check-repo-hygiene.sh"); then
  echo 'tracked build output was accepted' >&2
  exit 1
fi
```

- [ ] **Step 2: Run it to verify it fails**

Run `bash Tests/Scripts/test-check-repo-hygiene.sh`.

Expected: FAIL because `Scripts/check-repo-hygiene.sh` does not exist.

- [ ] **Step 3: Implement hygiene and local CI scripts**

Create `Scripts/check-repo-hygiene.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
bad="$(git ls-files | rg '(^|/)(\.git|\.build|\.swiftpm|dist|\.DS_Store)(/|$)|(^|/)\.env($|\.)|\.dmg$|\.caf$|\.wav$' || true)"
[[ -z "$bad" ]] || { printf 'forbidden tracked paths:\n%s\n' "$bad" >&2; exit 1; }
```

Create `Scripts/ci-local.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
./Scripts/check-repo-hygiene.sh
expected_origin="${UTTERINK_EXPECTED_ORIGIN:-}"
if [[ -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_REPOSITORY:-}" ]]; then
  expected_origin="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}.git"
fi
if [[ -n "$expected_origin" ]]; then
  ./Scripts/scan-public-history.sh --expected-origin "$expected_origin"
else
  ./Scripts/scan-public-history.sh
fi
bash Tests/Scripts/test-generate-import-manifest.sh
bash Tests/Scripts/test-scan-public-history.sh
bash Tests/Scripts/test-import-legacy-parity.sh
bash Tests/Scripts/test-check-repo-hygiene.sh
swift test --package-path LegacyParity
swift test --package-path Packages/UtterInkKit
xcodegen generate
python3 Scripts/check-package-resolution.py
git diff --exit-code -- UtterInk.xcodeproj
xcodebuild -project UtterInk.xcodeproj -scheme UtterInk -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build
```

- [ ] **Step 4: Verify the whole foundation**

```bash
chmod +x Scripts/ci-local.sh Scripts/check-repo-hygiene.sh Tests/Scripts/test-check-repo-hygiene.sh
test -x Scripts/ci-local.sh
bash Tests/Scripts/test-check-repo-hygiene.sh
./Scripts/ci-local.sh
git diff --check
```

Expected: all commands exit 0; Xcode reports `BUILD SUCCEEDED`; regenerated project has no diff.

- [ ] **Step 5: Commit**

```bash
git add Scripts/ci-local.sh Scripts/check-repo-hygiene.sh Tests/Scripts/test-check-repo-hygiene.sh
git commit -m "test: add local foundation verification"
```

## Plan completion gate

Run:

```bash
./Scripts/ci-local.sh
git status --short
```

Expected: CI-local exits 0 and the working tree is clean. Keep `LegacyParity/` until the macOS product plan records parity and deletes it.
