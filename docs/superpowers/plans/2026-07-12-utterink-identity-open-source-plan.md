# UtterInk Identity and Open-Source Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce user-approved deterministic Ink Caret identity assets and the complete Apache-2.0 open-source documentation, provenance, privacy, security, contribution, and community package.

**Architecture:** Canonical identity inputs are rights-reviewed and hash-locked, then parsed and rendered by a deterministic Swift/CoreGraphics tool into Xcode assets and local review sheets. Public documents are checked by local scripts for required claims, broken local links, private paths, secret patterns, dependency notices, and forbidden support promises.

**Tech Stack:** SVG source, Swift 5/CoreGraphics/ImageIO, Xcode asset catalogs, XCTest, Markdown, Bash, Git full-history scanning, SwiftPM dependency metadata.

## Global Constraints

- Identity is Ink Caret Monogram / B · Right Cursor: open U bowl, interrupted right cursor, quiet/native/privacy-first/crafted.
- Menu-bar output is transparent single-color template artwork and must work at 16, 18, and 20pt in light/dark/high-contrast modes.
- Avoid microphones, waveforms, speech bubbles, droplets, quills, sparkles, gradients, OpenAI-like swirls, power-button geometry, a wide `UI` reading, filled wells, folded notches, enclosing blocks, white matte edges, raster cutouts, and round-one generated typography as production art.
- The upper cursor segment must not become a stray dot; status cannot rely on color alone.
- Final production assets require a local user approval after pixel-fitting/similarity/trademark-risk review.
- License is Apache-2.0; it does not grant trademark rights. Every imported source/asset/dependency/model needs compatible rights/notices.
- Required public docs: English/Chinese README, PRIVACY, SECURITY, CONTRIBUTING, CODE_OF_CONDUCT, CHANGELOG, third-party notices, issue templates, PR template.
- Public docs must state macOS 14+, Apple Silicon, no automatic updates, no cloud sync/live transcription/audio history, and optional remote text processing.
- No repository publication or release occurs in this plan.

---

### Task 1: Freeze canonical identity inputs and test the deterministic exporter

**Files:**
- Create: `Brand/Source/selected-logo-route.json`
- Create: `Brand/Source/identity-handoff.md`
- Create: `Brand/Source/B-right-cursor.svg`
- Create: `Brand/Source/provenance.json`
- Copy locally only: `dist/identity-input-review/menu-bar-comparison.png` (ignored)
- Create: `Brand/palettes.json`
- Modify: `Packages/UtterInkKit/Package.swift`
- Create: `Packages/UtterInkKit/Sources/UtterInkIdentityExporter/**`
- Create: `Packages/UtterInkKit/Tests/UtterInkIdentityExporterTests/IdentityExporterTests.swift`
- Generate: `dist/identity-review/**` (ignored, local review only)

**Interfaces:**
- Consumes: four canonical paths/hashes recorded in the design.
- Produces: menu template PNGs, three App Icon palette directions, a comparison sheet, and machine-verifiable metadata.

- [ ] **Step 1: Verify all four canonical inputs before copying anything**

```bash
shasum -a 256 \
  "$HOME/Documents/codexprojects/playground/outputs/logos/utterink/data/selected-logo-route.json" \
  "$HOME/Documents/codexprojects/playground/outputs/logos/utterink/data/handoff.md" \
  "$HOME/Documents/codexprojects/playground/outputs/logos/utterink/menu-bar-round2/variants/B-right-cursor.svg" \
  "$HOME/Documents/codexprojects/playground/outputs/logos/utterink/menu-bar-round2/menu-bar-comparison.png"
```

Expected hashes:

```text
15963ac872c2385170408029c86b450c4e2bdfc3b1c970f88d945adb8e7c4f08  selected-logo-route.json
0464a616dad340ded1672781c014a4421c7f04779bd4c1af4f38877fc225d3aa  handoff.md
8bd098aedf9dee4bd5d1752eea513557a1bc756b78e82c00f647a8fc77932839  B-right-cursor.svg
5e02410fdac93b6e2fcde790e7afa55fea7556c3a0604041b4c786d13857b506  menu-bar-comparison.png
```

- [ ] **Step 2: Obtain and validate publication-rights facts**

Before creating any tracked brand file, ask the user to confirm creator/copyright owner, publication authority, asset license, trademark treatment, and reviewer for each canonical input. Write `Brand/Source/provenance.json` with one exact row per hash and no absolute personal path. A validator rejects missing/provisional values or a file whose hash differs.

The comparison PNG is a review montage rather than production source and may contain system/reference imagery. Keep it only at ignored `dist/identity-input-review/menu-bar-comparison.png`; record its hash and `publicDistribution: false` in provenance. After the other three inputs are confirmed publishable, copy them with `apply_patch`/binary-safe copy into `Brand/Source`, renaming `handoff.md` to `identity-handoff.md`, then reverify their hashes. Unknown or incompatible rights stop the plan before commit.

- [ ] **Step 3: Write the failing exporter test**

Add executable target `UtterInkIdentityExporter` and test target `UtterInkIdentityExporterTests` to the local package. The test renders into a temporary directory, loads PNGs with ImageIO, and asserts:

```swift
XCTAssertEqual(try imageSize("menu-16@1x.png"), CGSize(width: 16, height: 16))
XCTAssertEqual(try imageSize("menu-16@2x.png"), CGSize(width: 32, height: 32))
XCTAssertEqual(try imageSize("menu-18@1x.png"), CGSize(width: 18, height: 18))
XCTAssertEqual(try imageSize("menu-18@2x.png"), CGSize(width: 36, height: 36))
XCTAssertEqual(try imageSize("menu-20@1x.png"), CGSize(width: 20, height: 20))
XCTAssertEqual(try imageSize("menu-20@2x.png"), CGSize(width: 40, height: 40))
XCTAssertTrue(try allVisibleRGBIsBlack(in: outputDirectory))
XCTAssertEqual(try imageSize("appicon-night-ink-1024.png"), CGSize(width: 1024, height: 1024))
```

Also mutate each SVG path/stroke/viewBox attribute in fixtures and assert locked-input validation fails; no hard-coded duplicate geometry may silently render instead.

- [ ] **Step 4: Run to verify failure**

Run `swift test --package-path Packages/UtterInkKit --filter IdentityExporterTests`.

Expected: FAIL because the exporter target does not exist.

- [ ] **Step 5: Define exact palette candidates**

Create `Brand/palettes.json`:

```json
{
  "night-ink": { "background": "#171821", "mark": "#F3F0E8" },
  "warm-paper": { "background": "#ECE6DA", "mark": "#1D1E25" },
  "slate": { "background": "#24303A", "mark": "#EEF1F2" }
}
```

- [ ] **Step 6: Implement the deterministic exporter**

The exporter parses the canonical XML/SVG directly with `XMLParser`; it requires `viewBox="0 0 24 24"`, exactly the reviewed two paths, their path commands/numeric values, fill/stroke/cap/join properties, and no external references/scripts/fonts/raster data. It samples the parsed cubic bowl at 128 points and renders through a fixed RGBA8 premultiplied bitmap context at 16× supersampling, then downsamples with one explicitly tested Lanczos implementation in the tool (not an OS-selected thumbnail API).

Menu outputs use black RGB plus alpha only. App Icon outputs use one solid candidate background, an optically centered mark, no gradient, and macOS icon-safe padding. Encode PNG through ImageIO with a fixed property dictionary and no timestamps/user metadata. Generate 1x/2x 16/18/20pt files, all App Icon slots, output SHA-256 metadata, and `identity-review.png` showing every scale in light/dark/high-contrast simulations plus all three App Icon candidates. Rendering the same locked input twice must produce byte-identical files.

- [ ] **Step 7: Verify and commit sources/tooling**

```bash
swift test --package-path Packages/UtterInkKit --filter IdentityExporterTests
swift run --package-path Packages/UtterInkKit UtterInkIdentityExporter --output dist/identity-review
git add Brand Packages/UtterInkKit/Package.swift Packages/UtterInkKit/Sources/UtterInkIdentityExporter Packages/UtterInkKit/Tests/UtterInkIdentityExporterTests
git commit -m "build: add deterministic UtterInk identity pipeline"
```

Do not commit `dist/identity-review`.

---

### Task 2: Final identity review, lock, and Xcode asset integration

**Files:**
- Create after palette/geometry approval: `Brand/identity-selection.json`
- Create only after the complete asset-family approval/export: `Brand/identity-lock.json`
- Create: `Brand/wordmark-lockup.svg`
- Create: `Brand/states/{recording,processing,success,failure}.svg`
- Generate: `App/Resources/Assets.xcassets/MenuBarIcon.imageset/**`
- Generate: `App/Resources/Assets.xcassets/AppIcon.appiconset/**`
- Generate: `App/Resources/Assets.xcassets/BrandMark.imageset/**`
- Modify: `project.yml`
- Modify: `App/UtterInkApp.swift`
- Modify: `Scripts/ci-local.sh`
- Test: `Packages/UtterInkKit/Tests/UtterInkIdentityExporterTests/IdentityExporterTests.swift`

**Interfaces:**
- Produces: one user-approved palette/geometry lock and deterministic assets used by the app.

- [ ] **Step 1: Present the local review sheet and request one selection**

Show `dist/identity-review/identity-review.png` plus the local, non-public menu-bar comparison. Ask the user to select Night Ink, Warm Paper, or Slate and approve the pixel-fitted 16/18/20pt geometry at both 1x/2x. This is a required local asset approval, not an external action. Record only the selected palette/geometry, canonical input hashes, brand copyright owner, asset license, trademark treatment, reviewer, and approval timestamp in provisional `Brand/identity-selection.json`; do not create the final lock or claim final approval yet.

- [ ] **Step 2: Produce the state family and lockup for review**

All state marks retain the open-U/right-cursor base. Recording uses the base plus a filled cursor segment; Processing uses two separated cursor segments; Success adds a check cut into the bowl's negative space; Failure adds an x cut into the same negative space. Each remains single-color and is paired with complete adjacent status text/VoiceOver announcements, so the icon itself is decorative and never the sole status channel. The production `wordmark-lockup.svg` uses custom outlined letterforms or a font with explicit redistribution/outline rights recorded in provenance; live product UI may separately typeset `UtterInk` with the system font, but that runtime text is not called a deterministic wordmark asset.

Present the state sheet, deterministic/custom outlined wordmark source, font/letterform rights provenance, competitor-similarity notes, and internal trademark-risk search notes. Require a second explicit local approval for this complete source family before integration. Paid legal clearance is outside this task. Store the approved state/wordmark source hashes and rights facts alongside the provisional selection; missing source/provenance/approval blocks export.

- [ ] **Step 3: Export and integrate the approved assets**

Extend the exporter to read the approved selection/source-family record and render into a temporary directory: all AppIcon slots, 16/18/20pt menu assets at 1x/2x with `template-rendering-intent`, and state/brand mark assets. Compute every output hash, then atomically create final `Brand/identity-lock.json` containing schema version, all source/provenance hashes, palette/geometry, exporter source/toolchain identity, both approval records, and every Xcode asset output hash. Validate the complete lock before copying outputs into the asset catalog; no partially locked integration is allowed. Update `project.yml` with `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`. Replace the temporary `text.cursor` symbol with `Image("MenuBarIcon").renderingMode(.template).accessibilityHidden(true)` while the `MenuBarExtra` label and adjacent authoritative status text provide the accessible name/value and stage-change announcements.

Add `UtterInkIdentityExporter --check --lock Brand/identity-lock.json --asset-catalog App/Resources/Assets.xcassets`: it rerenders into a temporary directory with the locked input/toolchain, compares every file byte-for-byte and against recorded SHA-256 values, reports only filenames on mismatch, and leaves the tree untouched. `ci-local.sh` runs this check once the lock exists.

- [ ] **Step 4: Verify exact asset constraints**

```bash
swift test --package-path Packages/UtterInkKit --filter IdentityExporterTests
swift run --package-path Packages/UtterInkKit UtterInkIdentityExporter --check --lock Brand/identity-lock.json --asset-catalog App/Resources/Assets.xcassets
xcodegen generate
xcodebuild -project UtterInk.xcodeproj -scheme UtterInk -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build
git add UtterInk.xcodeproj
./Scripts/ci-local.sh
```

Expected: tests/build pass; cursor gap remains visible at 16pt; no white matte or non-black visible menu pixels.

- [ ] **Step 5: Commit**

```bash
git add Brand App/Resources App/UtterInkApp.swift project.yml UtterInk.xcodeproj Packages/UtterInkKit Scripts/ci-local.sh
git commit -m "feat: integrate approved UtterInk identity"
```

---

### Task 3: Apache license, trademark policy, and dependency/model notices

**Files:**
- Create: `LICENSE`
- Create: `NOTICE`
- Create: `TRADEMARKS.md`
- Create: `THIRD_PARTY_NOTICES.md`
- Create: `Scripts/collect-third-party-notices.sh`
- Test: `Tests/Scripts/test-third-party-notices.sh`

**Interfaces:**
- Produces: public licensing set and reproducible dependency inventory.

- [ ] **Step 1: Write the failing notice test**

The test requires exact headings/entries for KeyboardShortcuts 2.4.0, WhisperKit 0.18.0, every transitive package in `Packages/UtterInkKit/Package.resolved`, and every entry in `Config/speech-model-catalog.json`. Each row requires immutable revision, source/license URL, and shipped/downloaded status; model weights must be identified as runtime downloads rather than repository/DMG content. It also fails if an Xcode workspace/package lock exists and resolves a different revision than the authoritative committed package lock.

- [ ] **Step 2: Run to verify failure**

Run `bash Tests/Scripts/test-third-party-notices.sh`; expect missing files/script.

- [ ] **Step 3: Add legal files with exact scope**

- `LICENSE`: unmodified Apache License 2.0 text.
- `NOTICE`: UtterInk copyright/attribution plus only third-party notices whose licenses require NOTICE propagation.
- `TRADEMARKS.md`: source license does not grant rights to the UtterInk name/marks; descriptive nominative use and unmodified redistribution identification are allowed; no implication of endorsement.
- `THIRD_PARTY_NOTICES.md`: dependency name, exact resolved version/revision, source URL, license name, shipped/downloaded status, and notice obligations.

The collector first runs `swift package resolve --package-path Packages/UtterInkKit`, requires the authoritative lock to remain unchanged, then reads `Packages/UtterInkKit/Package.resolved`, `Packages/UtterInkKit/.build/checkouts/*/LICENSE*`, and `Config/speech-model-catalog.json`; it therefore works in a clean clone without old checkout residue. It fails if a resolved identity/model lacks a reviewed notice row, immutable revision, or license source. Do not infer licenses from package/model names. If Xcode generates a workspace-level resolution file, verify it matches the authoritative package lock byte-for-byte in identity/revision terms.

- [ ] **Step 4: Verify and commit**

```bash
chmod +x Scripts/collect-third-party-notices.sh Tests/Scripts/test-third-party-notices.sh
test -x Scripts/collect-third-party-notices.sh
bash Tests/Scripts/test-third-party-notices.sh
./Scripts/collect-third-party-notices.sh --check
git add LICENSE NOTICE TRADEMARKS.md THIRD_PARTY_NOTICES.md Scripts/collect-third-party-notices.sh Tests/Scripts/test-third-party-notices.sh
git commit -m "docs: add source and trademark licensing"
```

---

### Task 4: README, privacy, and security documents

**Files:**
- Create: `README.md`
- Create: `README.zh-CN.md`
- Create: `PRIVACY.md`
- Create: `SECURITY.md`
- Create: `docs/privacy-data-flow.md`
- Test: `Tests/Scripts/test-public-claims.sh`

**Interfaces:**
- Produces: matching English/Chinese product/install/build/use/privacy/support docs.

- [ ] **Step 1: Write a failing claim matrix test**

The test requires both READMEs to contain UtterInk, macOS 14+, Apple Silicon/arm64, local Whisper, optional OpenAI-compatible text polishing, Keychain, text-only 20-session history, no audio retention, Apache-2.0, build/test commands, and current limitations. It rejects FlowType product branding, Intel/Universal claims, auto-update, cloud sync, live transcription, bundled API keys, and any DMG URL before release. It also rejects empty/example/TBD security-reporting or conduct-enforcement contacts.

- [ ] **Step 2: Run to verify failure**

Run `bash Tests/Scripts/test-public-claims.sh`; expect missing docs.

- [ ] **Step 3: Obtain the two public contact facts, then write exact document content**

**STOP gate:** Ask the user to select the exact public private-security-reporting channel and Contributor Covenant enforcement contact that will appear in the public repository. Do not invent an email/address or rely on a future repository feature. Record the approved literal values in the documents and validator fixture; if either is absent, example-only, or not approved, Tasks 4–5 and the plan completion gate must fail.

README order: one-sentence value, screenshot/identity, privacy summary, features, requirements, source build, test, unsigned package, optional provider setup, history/recovery, permissions, limitations, contributing/security, license. Chinese README mirrors claims and commands rather than introducing extra promises.

`PRIVACY.md` data table covers transient local audio, local raw/final text history, optional remote text/host/model, Keychain credential, model downloads/cache, pasteboard transient snapshot, diagnostics allowlist, disable/clear controls, no analytics/cloud sync, orphan cleanup, and the fact that normal APFS deletion is not guaranteed secure erasure. `SECURITY.md` defines supported versions, the exact approved private reporting channel, expected response process, credential-handling rules, dependency reporting, and no public sensitive issue. `docs/privacy-data-flow.md` maps capture → local transcription → durable raw → optional text host → safe delivery → cleanup.

- [ ] **Step 4: Verify and commit**

```bash
bash Tests/Scripts/test-public-claims.sh
git add README.md README.zh-CN.md PRIVACY.md SECURITY.md docs/privacy-data-flow.md Tests/Scripts/test-public-claims.sh
git commit -m "docs: explain UtterInk use privacy and security"
```

---

### Task 5: Contribution/community files and documentation validation

**Files:**
- Create: `CONTRIBUTING.md`
- Create: `CODE_OF_CONDUCT.md`
- Create: `CHANGELOG.md`
- Create: `.github/ISSUE_TEMPLATE/bug_report.yml`
- Create: `.github/ISSUE_TEMPLATE/feature_request.yml`
- Create: `.github/pull_request_template.md`
- Create: `Scripts/check-public-docs.py`
- Modify: `Scripts/scan-public-history.sh`
- Modify: `Tests/Scripts/test-scan-public-history.sh`
- Test: `Tests/Scripts/test-check-public-docs.py`
- Modify: `Scripts/ci-local.sh`

**Interfaces:**
- Produces: contributor workflow and full-history/public-file validation used by CI/release evidence.

- [ ] **Step 1: Write failing validator tests**

Fixtures must prove rejection of broken relative links, `/Users/name` paths, `file://`, private transcript canaries, PEM blocks, common token prefixes, nonempty `.apiKey = "..."`, tracked forbidden paths, and missing required headings. Extend the existing history-scanner fixtures with all public-document/provider patterns while retaining the unreachable-object, deleted-secret, ref/remote, alternates/grafts/replace, and redacted-output cases from Foundation.

- [ ] **Step 2: Run to verify failure**

Run `python3 Tests/Scripts/test-check-public-docs.py`; expect missing validator.

- [ ] **Step 3: Write contributor/community files**

`CONTRIBUTING.md` requires an issue/design discussion for behavior changes, TDD, `./Scripts/ci-local.sh`, privacy-safe fixtures, SPM-only dependencies, deterministic project/assets, accessibility review, and signed-off license compatibility. `CODE_OF_CONDUCT.md` uses Contributor Covenant 2.1 with the exact enforcement contact approved in Task 4; its test rejects examples/placeholders or disagreement with the approved fixture. `CHANGELOG.md` follows Keep a Changelog with `[Unreleased]` and `0.1.0` sections. Templates collect macOS/build/architecture, sanitized diagnostics, reproduction, expected/actual, accessibility impact, tests, privacy/security, and screenshots without transcripts/secrets.

- [ ] **Step 4: Implement validators**

`check-public-docs.py` parses local Markdown links, verifies targets, scans all public text for private absolute paths/forbidden claims/canaries, and confirms required files/headings/approved contacts. Extend `scan-public-history.sh` with the same public-document/provider signatures without weakening its full reachable/unreachable object scan or expected-origin semantics. It reports only object/file/line/category; it never prints matched values. Modify `ci-local.sh` to run public-doc, full-history, brand-provenance/lock, and third-party/model-notice validators after package resolution on every invocation.

- [ ] **Step 5: Verify and commit**

```bash
chmod +x Scripts/scan-public-history.sh
test -x Scripts/scan-public-history.sh
python3 Tests/Scripts/test-check-public-docs.py
python3 Scripts/check-public-docs.py
./Scripts/scan-public-history.sh
./Scripts/ci-local.sh
git add CONTRIBUTING.md CODE_OF_CONDUCT.md CHANGELOG.md .github Scripts Tests/Scripts/test-check-public-docs.py Tests/Scripts/test-scan-public-history.sh
git commit -m "docs: add contributor and community standards"
```

## Plan completion gate

```bash
python3 Scripts/check-public-docs.py
./Scripts/scan-public-history.sh
./Scripts/collect-third-party-notices.sh --check
swift test --package-path Packages/UtterInkKit --filter IdentityExporterTests
swift run --package-path Packages/UtterInkKit UtterInkIdentityExporter --check --lock Brand/identity-lock.json --asset-catalog App/Resources/Assets.xcassets
./Scripts/ci-local.sh
git status --short
```

Expected: all pass, selected identity is locally approved/locked, required docs exist, full-history scan reports zero findings, and tree is clean.
