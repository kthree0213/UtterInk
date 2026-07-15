# UtterInk Distribution and Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a secret-free pull-request CI path, deterministic unsigned packaging smoke tests, guarded local Developer ID signing/notarization tooling, final-artifact verification, and a reviewable `0.1.0` evidence bundle without performing any external publication action.

**Architecture:** CI proves source, tests, Xcode generation, policy scans, and an unsigned `arm64` package, then deletes it without upload. Release tooling runs only on the user's Mac from an exact clean commit, separates build/sign/notarize/staple/verify phases, and records hashes at every mutation boundary. Notarization uses a procedural one-use interlock bound to a user-reviewed request nonce, pre-staple DMG hash, candidate commit, and Apple team; it does not pretend a writable local JSON file cryptographically proves human approval. Final release artifacts are generated only after the stapled DMG passes local and second-Mac Gatekeeper checks.

**Tech Stack:** GitHub Actions on `macos-26` arm64, Xcode 26.4, Swift 6.3 in Swift 5 language mode, XcodeGen 2.45.4, Swift Package Manager, Bash, Python 3, `xcodebuild`, `codesign`, `hdiutil`, `xcrun notarytool`, `xcrun stapler`, `spctl`, `ditto`, `shasum`, XCTest.

## Global Constraints

- Release product is `UtterInk 0.1.0`, bundle identifier `dev.utterink.UtterInk`, minimum macOS 14.0, architecture `arm64`.
- Build only from a clean checkout of one exact commit with committed `Package.resolved`; record Xcode, SDK, Swift, XcodeGen, deployment target, bundle IDs, versions, and architecture.
- PR CI has `contents: read`, full-history checkout, immutable third-party Action SHAs, no Apple/API secrets, and no unsigned artifact upload by default. Its exact runner-image/toolchain tuple is locked in `Config/ci-toolchain.json`; drift fails closed for reviewed upgrade.
- The local release path uses Developer ID Application signing, Hardened Runtime, secure timestamps, inside-out component signing, and strict verification. `codesign --deep` is forbidden.
- The DMG allowed-content manifest is exactly `UtterInk.app`, an `Applications` symlink, and deterministic presentation resources explicitly listed in the manifest.
- Notarization credentials stay in the local Keychain. A wrapper may be implemented and tested, but no Apple upload occurs without a separate one-time approval tied to Apple team, exact pre-staple SHA-256, and one submission attempt.
- A rejection, changed byte, different team, or second attempt invalidates approval and requires a new explicit user approval.
- The final stapled DMG is immutable after its final SHA-256 is recorded.
- Release/sign/notary verification scripts invoke Apple/system tools by absolute path and the locked XcodeGen path; fake tool injection is accepted only under explicit test mode in test fixtures.
- GitHub repository creation/push, CI artifact retention, beta transfer, public visibility, and GitHub Release publication each remain separately unauthorized.
- The approved design is `docs/superpowers/specs/2026-07-12-utterink-open-source-productization-design.md`; when this plan conflicts with it, the design wins and the plan must be corrected before implementation continues.

---

### Task 1: Make release metadata and evidence checks machine-verifiable

**Files:**
- Create: `Config/Release.xcconfig`
- Create: `Config/Base.xcconfig`
- Create: `Config/Debug.xcconfig`
- Create: `Config/release-metadata.json`
- Create: `Config/ci-toolchain.json`
- Create: `Config/release-entitlements.json`
- Create: `Config/release-info-policy.json`
- Create: `docs/release/evidence-schema.json`
- Create: `docs/RELEASING.md`
- Create: `Scripts/release/read-metadata.py`
- Create: `Scripts/release/verify-entitlements.py`
- Create: `Scripts/release/verify-info-policy.py`
- Create: `Scripts/release/verify-candidate.sh`
- Create: `Tests/Scripts/test-release-metadata.py`
- Create: `Tests/Scripts/test-release-entitlements.py`
- Create: `Tests/Scripts/test-release-info-policy.py`
- Create: `Tests/Scripts/test-verify-candidate.sh`
- Modify: `project.yml`
- Generate: `UtterInk.xcodeproj/**`
- Modify: `Scripts/ci-local.sh`

**Interfaces:**
- `read-metadata.py --json` prints one normalized JSON object and no human prose.
- `verify-entitlements.py` compares source, archived, and signed entitlements to one reviewed allowlist/inventory.
- `verify-candidate.sh --commit <sha> --output <directory> [--expected-origin <canonical URL>]` writes `candidate.json` only after every source/toolchain invariant passes.
- `candidate.json` is the immutable source identity consumed by every later release script.

- [ ] **Step 1: Write the failing metadata test**

Create `Tests/Scripts/test-release-metadata.py` to execute `Scripts/release/read-metadata.py --json`, parse its output, and require this exact value set:

```python
assert metadata == {
    "product": "UtterInk",
    "marketingVersion": "0.1.0",
    "buildNumber": "1",
    "bundleIdentifier": "dev.utterink.UtterInk",
    "deploymentTarget": "14.0",
    "architecture": "arm64",
    "configuration": "Release",
    "dmgFilename": "UtterInk-0.1.0-arm64.dmg",
    "releaseTag": "v0.1.0",
}
```

- [ ] **Step 2: Run to verify failure**

Run `python3 Tests/Scripts/test-release-metadata.py`.

Expected: FAIL because the metadata reader does not exist.

- [ ] **Step 3: Add one source of version/build truth**

Create `Config/Base.xcconfig`:

```xcconfig
PRODUCT_BUNDLE_IDENTIFIER = dev.utterink.UtterInk
MACOSX_DEPLOYMENT_TARGET = 14.0
ARCHS = arm64
ONLY_ACTIVE_ARCH = NO
SWIFT_VERSION = 5.0
```

Create `Config/Debug.xcconfig` and `Config/Release.xcconfig`; both include Base and own their configuration-specific values. Release is:

```xcconfig
#include "Base.xcconfig"
MARKETING_VERSION = 0.1.0
CURRENT_PROJECT_VERSION = 1
ENABLE_HARDENED_RUNTIME = YES
```

Debug has the same include/version/build values and `ENABLE_HARDENED_RUNTIME = YES`; it may add only debug-optimization/testability flags, not a different identity/support boundary.

Create `Config/release-metadata.json` containing product, release configuration, DMG filename template, supported architecture, and exact planned lightweight tag `v0.1.0`. In the target's single XcodeGen mapping set `configFiles.Debug: Config/Debug.xcconfig` and `configFiles.Release: Config/Release.xcconfig`; remove bundle ID, versions, deployment target, architecture, Swift version, and Hardened Runtime from `settings.base` so project-level settings cannot override the xcconfig. Keep only non-duplicated settings such as product name, Info.plist generation, and signing style in YAML.

Implement `read-metadata.py` to parse the xcconfig include graph plus JSON, reject duplicate/cyclic definitions, unresolved `$(...)` substitutions, unsupported architectures, version/filename disagreement, and an identifier other than `dev.utterink.UtterInk`. `verify-candidate.sh` compares every value to effective `xcodebuild -showBuildSettings -configuration Release`, not merely to source files.

- [ ] **Step 4: Lock the CI toolchain source and entitlement allowlist**

Resolve the current official `macos-26` arm64 runner-image release at implementation time and commit `Config/ci-toolchain.json` containing its immutable release tag/commit, image version, OS version/build, architecture, Xcode `26.4.1` build `17E202`, `/Applications/Xcode_26.4.app/Contents/Developer`, macOS SDK `26.4` build, full `swift --version` line, XcodeGen `2.45.4` source commit/archive SHA-256 and built-binary SHA-256. The lock must cite only the official `actions/runner-images` release/readme and official XcodeGen release source. Weekly rolling-image drift fails until a dedicated reviewed lock update proves the relevant tuple remains acceptable.

Create `Config/release-entitlements.json` with schema version `1` and exactly one app entitlement: `com.apple.security.device.audio-input=true`, reason `Required for local microphone capture`. Nested-component allowlists are empty until an actual component is introduced through a reviewed plan change. `Tests/Scripts/test-release-entitlements.py` proves exact source plist passes and that missing, extra, false-valued, wildcard, debugger, JIT, unsigned-executable-memory, library-validation exception, network-server, or sandbox changes fail.

Create `Config/release-info-policy.json` from the signed ATS probe evidence: it permits exactly the final proven shape (no ATS dictionary, or `NSAllowsLocalNetworking=true` only). `verify-info-policy.py` checks source and archived effective Info.plists and always rejects arbitrary/web-content loads, public-domain exceptions, or undocumented keys. Its tests cover both permitted evidence states and every forbidden widening.

Create the initial `docs/RELEASING.md` with contributor unsigned verification, local maintainer signing phases, immutable-artifact rules, and the five external-action gates; it contains no identity/profile/credential value.

- [ ] **Step 5: Make the candidate verifier fail for dirty or mismatched input**

Create a temporary fixture repository in `Tests/Scripts/test-verify-candidate.sh`; enable an explicit `UTTERINK_RELEASE_TEST_MODE=1` tool-root override and inject fake `xcodebuild`, `swift`, and `xcodegen` executables. Production mode ignores `PATH` overrides and uses locked/absolute tool paths. Assert:

```text
dirty checkout -> exit 20, no candidate.json
requested commit != HEAD -> exit 21, no candidate.json
missing Package.resolved -> exit 22, no candidate.json
metadata mismatch -> exit 23, no candidate.json
clean exact commit -> candidate.json emitted
```

Run `bash Tests/Scripts/test-verify-candidate.sh`.

Expected: FAIL because `verify-candidate.sh` does not exist.

- [ ] **Step 6: Implement exact-commit candidate verification**

`verify-candidate.sh` must:

1. Require a full 40-character commit SHA and verify `HEAD` equals it.
2. Require `git status --porcelain=v1 --untracked-files=all` to be empty.
3. Call the full-history scanner with the same optional expected-origin; reject shallow repositories, replace refs, grafts, alternates, unauthorized remotes, submodules, and uncommitted generated-project changes.
4. Verify `Packages/UtterInkKit/Package.resolved` is committed and unchanged after `swift package resolve`, and any Xcode workspace resolution agrees.
5. Run the entitlement and Info/ATS policy verifiers against source configuration.
6. Run the locked XcodeGen binary, regenerate the project, and require a clean tree afterward.
7. Record `git rev-parse HEAD^{tree}`, planned release tag, local Xcode build/SDK version, Swift version, XcodeGen binary hash/version, deployment target, package-resolution SHA-256, all bundle IDs, marketing/build versions, configuration, and architecture.
8. Refuse to include usernames, absolute home paths, signing identities, Keychain profile names, environment dumps, or secrets in `candidate.json`.
9. Validate the output against `docs/release/evidence-schema.json` before atomically replacing it.

- [ ] **Step 7: Verify and commit**

```bash
chmod +x Scripts/release/verify-candidate.sh Tests/Scripts/test-verify-candidate.sh
test -x Scripts/release/verify-candidate.sh
python3 Tests/Scripts/test-release-metadata.py
python3 Tests/Scripts/test-release-entitlements.py
python3 Tests/Scripts/test-release-info-policy.py
bash Tests/Scripts/test-verify-candidate.sh
xcodegen generate
git add UtterInk.xcodeproj
./Scripts/ci-local.sh
git add Config project.yml UtterInk.xcodeproj docs/release/evidence-schema.json docs/RELEASING.md Scripts/release Tests/Scripts Scripts/ci-local.sh
git commit -m "build: lock UtterInk release metadata"
```

---

### Task 2: Add pinned, secret-free pull-request CI

**Files:**
- Create: `.github/workflows/ci.yml`
- Create: `Scripts/bootstrap-xcodegen.sh`
- Create: `Scripts/verify-toolchain.sh`
- Create: `Scripts/verify-workflow.py`
- Create: `Scripts/clean-distribution-output.sh`
- Create: `Tests/Scripts/test-verify-workflow.py`
- Create: `Tests/Scripts/test-bootstrap-xcodegen.sh`
- Create: `Tests/Scripts/test-clean-distribution-output.sh`
- Modify: `Scripts/ci-local.sh`
- Modify: `docs/RELEASING.md`

**Interfaces:**
- CI is a source-verification workflow only. It never signs, notarizes, publishes, or uploads the unsigned package.
- `verify-workflow.py` enforces immutable Actions, minimum permissions, full history, exact Xcode selection, no secret interpolation, and no artifact upload action.

- [ ] **Step 1: Write the failing workflow-policy test**

Create `Tests/Scripts/test-verify-workflow.py` with valid and mutated temporary YAML fixtures. Require rejection when any fixture contains:

```text
permissions broader than contents: read
an action reference that is a tag or branch rather than a 40-character SHA
checkout fetch-depth other than 0
checkout persist-credentials other than false
macOS runner other than macos-26
DEVELOPER_DIR other than /Applications/Xcode_26.4.app/Contents/Developer
secrets.* or an Apple/API credential name
actions/upload-artifact or a release/push/notary command
```

- [ ] **Step 2: Run to verify failure**

Run `python3 Tests/Scripts/test-verify-workflow.py`.

Expected: FAIL because the verifier/workflow do not exist.

- [ ] **Step 3: Add the exact workflow**

Create `.github/workflows/ci.yml` with:

```yaml
name: CI
on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  verify:
    runs-on: macos-26
    timeout-minutes: 45
    env:
      DEVELOPER_DIR: /Applications/Xcode_26.4.app/Contents/Developer
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd
        with:
          fetch-depth: 0
          persist-credentials: false
      - name: Bootstrap locked XcodeGen
        run: ./Scripts/bootstrap-xcodegen.sh
      - name: Verify toolchain
        run: ./Scripts/verify-toolchain.sh --context ci
      - name: Verify workflow policy
        run: python3 Scripts/verify-workflow.py
      - name: Run source, history, test, and build checks
        run: ./Scripts/ci-local.sh --ci
      - name: Remove unsigned outputs
        if: always()
        run: ./Scripts/clean-distribution-output.sh
```

Keep `push: main` present. A first push is valid only when its artifact-scoped approval chooses one enforceable branch: (a) Actions execution and GitHub log retention are explicitly approved, or (b) repository Actions have been disabled in the separately approved repository settings and read back as disabled before push. A bare “push approved but Actions not approved” is insufficient and must stop. No workflow dispatch, tag, release, deployment, write permission, cache containing user data, or artifact upload is allowed in P0.

- [ ] **Step 4: Implement workflow and toolchain policy checks**

`bootstrap-xcodegen.sh` downloads/builds only the exact official XcodeGen source commit in `Config/ci-toolchain.json`, verifies archive and built-binary SHA-256, and installs it under ignored repository-local `Tools/bin`; it never uses Homebrew or an unpinned release URL. `verify-toolchain.sh --context ci|local` always compares architecture, Xcode `26.4.1` build `17E202`, full Swift/SDK values, and the repository-local XcodeGen binary hash against the lock; `ci` additionally requires the locked runner label/image/OS-build environment, while `local` records the locked local OS build field and does not invent runner metadata. Any missing `Tools/bin/xcodegen`, unknown context, ordinary-`PATH` fallback, or tuple mismatch fails with a reviewed-upgrade/bootstrap message.

`verify-workflow.py` must parse the workflow structurally, allow only the pinned checkout SHA above, and reject `secrets`, `upload-artifact`, `notarytool`, `gh release`, signing identity variables, write permissions, and unrecognized actions. Extend `ci-local.sh` with parsed `--ci` mode (unknown/duplicate flags fail) that uses the locked XcodeGen path and unconditionally runs repository hygiene, full-history/private-data scan with current expected origin, public-doc/link/claim validation, third-party/model notice validation, Swift package tests, generated-project diff, app unit/UI tests, ATS probe, and unsigned Debug build.

`clean-distribution-output.sh` is created before the workflow references it. It accepts only enumerated repository-local generated roots, rejects symlinks/`..`/paths outside the worktree, and cannot remove source/config/docs. Tests prove both cleanup and refusal behavior. `test-bootstrap-xcodegen.sh` starts from a clean-clone fixture with no `Tools/bin`, proves locked CI/local verification and `ci-local --ci` fail before bootstrap without consulting ordinary `PATH`, then uses a fake hash-verified source/build endpoint to install the exact repository-local binary and proves both consumers select it. Mark every invoked script executable in the same commit.

Update `docs/RELEASING.md` with the runner/action source references and the rule that dependency/action upgrades require a dedicated reviewed change. Do not claim that CI produces a distributable binary.

- [ ] **Step 5: Verify and commit**

```bash
chmod +x Scripts/bootstrap-xcodegen.sh Scripts/verify-toolchain.sh Scripts/clean-distribution-output.sh
test -x Scripts/bootstrap-xcodegen.sh
python3 Tests/Scripts/test-verify-workflow.py
bash Tests/Scripts/test-bootstrap-xcodegen.sh
bash Tests/Scripts/test-clean-distribution-output.sh
python3 Scripts/verify-workflow.py
./Scripts/bootstrap-xcodegen.sh
./Scripts/verify-toolchain.sh --context local
./Scripts/ci-local.sh
git add .github Scripts docs/RELEASING.md Tests/Scripts
git commit -m "ci: add pinned secret-free macOS verification"
```

---

### Task 3: Build and inspect a deterministic unsigned packaging smoke artifact

**Files:**
- Create: `Config/dmg-allowed-content.txt`
- Create: `Scripts/package-unsigned-smoke.sh`
- Create: `Scripts/create-dmg.sh`
- Create: `Scripts/inspect-dmg.sh`
- Modify: `Scripts/clean-distribution-output.sh`
- Modify: `Scripts/ci-local.sh`
- Modify: `.github/workflows/ci.yml`
- Modify: `Scripts/verify-workflow.py`
- Create: `Tests/Scripts/test-package-unsigned-smoke.sh`
- Create: `Tests/Scripts/test-inspect-dmg.sh`
- Modify: `Tests/Scripts/test-verify-workflow.py`
- Modify: `.gitignore`
- Modify: `docs/RELEASING.md`

**Interfaces:**
- `package-unsigned-smoke.sh --commit <sha> --output <directory> [--expected-origin <canonical URL>]` creates `UtterInk-0.1.0-arm64-UNSIGNED-DO-NOT-DISTRIBUTE.dmg` with signing explicitly disabled and forwards the optional origin unchanged to candidate verification.
- `inspect-dmg.sh --dmg <path> --mode unsigned|signed|final` checks content, metadata, architecture, signatures appropriate to the mode, and rejects extras.
- CI deletes the entire output directory in an `always()` cleanup step.

- [ ] **Step 1: Write the failing packaging test with fake build tools**

`Tests/Scripts/test-package-unsigned-smoke.sh` must use a temporary clean Git fixture and fake `xcodebuild`, `hdiutil`, and `ditto` commands. It also covers a clean clone with no `Tools/bin/xcodegen`: production-mode packaging must stop before build with the bootstrap instruction and no artifact; after installing the fixture's hash-locked repository-local binary, the same invocation must use that exact path and never an ordinary-`PATH` `xcodegen`. Assert the real command log contains:

```text
xcodebuild archive
-configuration Release
-destination generic/platform=macOS
ARCHS=arm64
CODE_SIGNING_ALLOWED=NO
CODE_SIGNING_REQUIRED=NO
CODE_SIGN_IDENTITY=
```

Assert the output filename contains `UNSIGNED-DO-NOT-DISTRIBUTE`, that no `codesign`, `notarytool`, `stapler`, `spctl --assess`, network command, or upload command runs, and that cleanup removes all outputs. Add fixture repositories with no remote, matching expected `origin`, missing expected-origin in a repo with `origin`, and mismatched origin; only the first two pass, and the packaging script must forward the exact canonical URL once.

- [ ] **Step 2: Run to verify failure**

Run `bash Tests/Scripts/test-package-unsigned-smoke.sh`.

Expected: FAIL because the packaging script does not exist.

- [ ] **Step 3: Define the allowed DMG manifest and inspection failures**

Create `Config/dmg-allowed-content.txt`:

```text
Applications -> /Applications
UtterInk.app directory
```

Create `Tests/Scripts/test-inspect-dmg.sh` fixtures and assert rejection of `.DS_Store`, source files, logs, credentials, extra aliases, unexpected hidden entries, wrong app/bundle/version, non-`arm64` Mach-O content, quarantine-removing helpers, mutable absolute symlinks, or an unsigned-mode app that unexpectedly has a Developer ID signature.

- [ ] **Step 4: Implement unsigned archive, DMG creation, inspection, and cleanup**

`package-unsigned-smoke.sh` calls Task 1 candidate verification and passes its optional `--expected-origin` unchanged, builds into a temporary directory, confirms the app is unsigned, confirms every Mach-O is `arm64`, and calls `create-dmg.sh`. `create-dmg.sh` stages only the app and `/Applications` symlink, normalizes permissions/timestamps used for presentation resources, and creates the named DMG without mutating the app. `inspect-dmg.sh` mounts read-only with a private mountpoint, traps detach/cleanup on every exit, compares a sorted manifest, verifies Info.plist values and Mach-O architecture recursively, and emits sanitized JSON evidence.

Extend `ci-local.sh` so `--unsigned-package-smoke` is accepted only with `--ci` or as the sole explicit local mode, executes this task's real smoke script, and records a test-observable command log; unknown flags fail. In CI it derives exactly `GITHUB_SERVER_URL/GITHUB_REPOSITORY.git`; locally it accepts only explicit `UTTERINK_EXPECTED_ORIGIN`; it passes the resulting URL as `--expected-origin` to both the history scanner and package script, never through an unexported implicit variable. Update the workflow's check command to `./Scripts/ci-local.sh --ci --unsigned-package-smoke`, and extend policy/matrix tests to require the exact command and origin propagation. `.gitignore` must exclude `build/`, `dist/`, `.release-work/`, `Tools/bin/`, `*.xcarchive`, `*.dmg`, notarization logs, evidence working directories, and local approval records. `clean-distribution-output.sh` refuses paths outside repository-local release output roots and removes only known generated directories.

- [ ] **Step 5: Run fake-tool tests and commit the packaging implementation**

```bash
chmod +x Scripts/package-unsigned-smoke.sh Scripts/create-dmg.sh Scripts/inspect-dmg.sh Scripts/clean-distribution-output.sh
test -x Scripts/package-unsigned-smoke.sh
bash Tests/Scripts/test-package-unsigned-smoke.sh
bash Tests/Scripts/test-inspect-dmg.sh
python3 Tests/Scripts/test-verify-workflow.py
python3 Scripts/verify-workflow.py
./Scripts/ci-local.sh
git add Config .gitignore .github/workflows/ci.yml Scripts Tests/Scripts docs/RELEASING.md
git commit -m "build: add unsigned distribution smoke test"
```

Expected: fake adversarial tests/base regression pass and the commit leaves a clean exact candidate.

- [ ] **Step 6: Run the real smoke only from the new clean exact commit**

```bash
./Scripts/bootstrap-xcodegen.sh
./Scripts/verify-toolchain.sh --context local
./Scripts/package-unsigned-smoke.sh --commit "$(git rev-parse HEAD)" --output dist/unsigned-smoke
./Scripts/inspect-dmg.sh --dmg dist/unsigned-smoke/UtterInk-0.1.0-arm64-UNSIGNED-DO-NOT-DISTRIBUTE.dmg --mode unsigned
./Scripts/ci-local.sh --ci --unsigned-package-smoke
./Scripts/clean-distribution-output.sh
test ! -e dist/unsigned-smoke
test -z "$(git status --short)"
```

Expected: real build/inspection pass; unsigned output is deleted; working tree remains clean. If this post-commit smoke finds a defect, fix it in a new focused commit and rerun against that new exact commit.

---

### Task 4: Build, sign, and verify an exact local release candidate

**Files:**
- Create: `Scripts/release/build-candidate.sh`
- Create: `Scripts/release/sign-candidate.sh`
- Create: `Scripts/release/verify-signatures.sh`
- Create: `Scripts/release/create-signed-dmg.sh`
- Create: `Tests/Scripts/test-build-candidate.sh`
- Create: `Tests/Scripts/test-sign-candidate.sh`
- Create: `Tests/Scripts/test-verify-signatures.sh`
- Modify: `docs/RELEASING.md`

**Interfaces:**
- `build-candidate.sh --commit <sha> --work <directory> [--expected-origin <canonical URL>]` emits an unsigned archive plus `candidate.json`; it never accepts a dirty overlay and forwards origin scope unchanged.
- `sign-candidate.sh --candidate <directory> --identity <exact common name> --team-id <10-character Team ID>` signs nested code inside out and the app last only when identity/team match.
- `create-signed-dmg.sh --candidate <directory> --identity <exact common name> --team-id <10-character Team ID>` creates and signs `UtterInk-0.1.0-arm64.dmg`, then emits `pre-staple.sha256` bound to the same team.
- Signing identities are arguments validated against local Keychain output; they are never committed or written into evidence.

- [ ] **Step 1: Write failing clean-build and signing-order tests**

`Tests/Scripts/test-build-candidate.sh` uses fake tool binaries to require an exact clean commit, Release/arm64 archive, Hardened Runtime, and no inherited user signing settings.

`Tests/Scripts/test-sign-candidate.sh` creates a fixture bundle:

```text
UtterInk.app/Contents/Frameworks/A.framework
UtterInk.app/Contents/Frameworks/B.framework/Versions/A/Helpers/BHelper
UtterInk.app/Contents/MacOS/UtterInk
```

The fake `codesign` log must show the helper, inner framework code, frameworks, and outer app in inside-out order. Reject any invocation containing `--deep`, missing `--options runtime`, missing `--timestamp`, ad-hoc identity `-`, a non-Developer-ID identity, absent/malformed `--team-id`, or certificate Organizational Unit different from that Team ID.

- [ ] **Step 2: Run to verify failure**

```bash
bash Tests/Scripts/test-build-candidate.sh
bash Tests/Scripts/test-sign-candidate.sh
```

Expected: FAIL because the release scripts do not exist.

- [ ] **Step 3: Implement exact clean candidate build**

`build-candidate.sh` runs Task 1 verification with the optional expected-origin, resolves packages without changing the lockfile, regenerates the project without a diff, archives to a repository-local ignored work directory, and copies only the app into a candidate staging directory. Tests cover absent/matching/mismatched origin propagation. It verifies:

- Release configuration, `arm64` only, macOS 14.0 minimum, version/build/bundle metadata.
- Hardened Runtime enabled and entitlements exactly equal the reviewed allowlist.
- Archived effective Info.plist exactly matches `Config/release-info-policy.json` and the ATS probe evidence.
- No absolute build-machine paths, local provisioning profiles, API credentials, quarantine-stripping commands, debug dylibs, or `.swiftmodule` paths exposing the home directory.
- Every embedded dependency appears in the third-party notice inventory.

- [ ] **Step 4: Implement inside-out signing and strict verification**

`sign-candidate.sh` discovers signable nested Mach-O/bundles deterministically, rejects ambiguous/unexpected bundle types, signs leaf code before containers, and signs the outer app last. It must not use `--deep` or mutate entitlements.

Before signing, resolve exactly one Developer ID Application identity and verify its certificate chain/trust, validity window covering the release operation, private-key availability, and exact expected Team ID without printing certificate/key material. `verify-signatures.sh` runs recursive component checks plus:

```bash
codesign --verify --strict --verbose=4 <component>
codesign -d --verbose=4 --entitlements :- <component>
codesign -d -r- <component>
lipo -archs <mach-o>
```

It requires Developer ID Application authority, secure timestamps where applicable, Hardened Runtime, the per-component entitlement allowlist from `Config/release-entitlements.json` (extra or missing keys fail), one Team ID across components, and `arm64` only. Evidence records validity dates, trust result, Team ID, hashes, and sanitized signature metadata, never certificate/private-key material.

- [ ] **Step 5: Implement signed pre-staple DMG creation**

`create-signed-dmg.sh` calls the shared DMG creator, signs the outer DMG with the same Developer ID Application identity and timestamp, mounts it read-only, runs the signed-mode manifest/app verification, then writes:

```text
UtterInk-0.1.0-arm64.dmg
pre-staple.sha256
signing-evidence.json
```

`pre-staple.sha256` is computed only after all pre-notarization mutations are complete.

- [ ] **Step 6: Test with a temporary local ad-hoc fixture only**

The automated test suite uses fake `codesign`; it must never select a real Developer ID certificate. A later manual local dry run may use ad-hoc signing solely to validate traversal, but it cannot produce release evidence and its filename must contain `ADHOC-NOT-FOR-DISTRIBUTION`.

```bash
chmod +x Scripts/release/build-candidate.sh Scripts/release/sign-candidate.sh Scripts/release/verify-signatures.sh Scripts/release/create-signed-dmg.sh
test -x Scripts/release/sign-candidate.sh
bash Tests/Scripts/test-build-candidate.sh
bash Tests/Scripts/test-sign-candidate.sh
bash Tests/Scripts/test-verify-signatures.sh
./Scripts/ci-local.sh
git add Scripts/release Tests/Scripts docs/RELEASING.md
git commit -m "build: add guarded local signing pipeline"
```

---

### Task 5: Guard notarization with an artifact-scoped one-use approval

**Files:**
- Create: `docs/release/notarization-approval.schema.json`
- Create: `docs/release/notary-profile-binding.schema.json`
- Create: `Scripts/release/prepare-notarization-request.py`
- Create: `Scripts/release/register-notary-profile.sh`
- Create: `Scripts/release/verify-notary-profile-binding.sh`
- Create: `Scripts/release/notarize-approved.sh`
- Create: `Scripts/release/verify-notarization-result.py`
- Create: `Tests/Scripts/test-notarization-gate.py`
- Create: `Tests/Scripts/test-register-notary-profile.sh`
- Create: `Tests/Scripts/test-notarize-approved.sh`
- Modify: `.gitignore`
- Modify: `docs/RELEASING.md`

**Interfaces:**
- `prepare-notarization-request.py` produces a sanitized request summary for user review; it does not produce approval.
- The preparer creates an unpredictable request ID; after reviewing the summary, the user must explicitly return that exact ID/hash/team/attempt before an ignored approval record may be written.
- `notarize-approved.sh --dmg <path> --approval <path> --keychain-profile <name>` consumes and invalidates the approval before invoking `notarytool`.
- No script can infer approval from design approval, plan approval, environment variables, interactive `yes`, a prior successful submission, or file existence alone.
- This is a procedural interlock backed by agent policy and exact-value checks, not a cryptographic proof of who authored a writable local file.

- [ ] **Step 1: Write the failing approval-gate tests**

`Tests/Scripts/test-notarization-gate.py` must require this exact approval payload:

```json
{
  "action": "apple-notarization-upload",
  "requestID": "<32-byte lowercase hex nonce from the request preparer>",
  "product": "UtterInk",
  "appleTeamID": "ABCDE12345",
  "preStapleDMGSHA256": "<64 lowercase hex characters>",
  "candidateCommit": "<40 lowercase hex characters>",
  "profileBindingReceiptSHA256": "<64 lowercase hex characters>",
  "attempt": 1,
  "approvedAt": "<RFC 3339 timestamp>",
  "expiresAt": "<RFC 3339 timestamp no more than 30 minutes later>"
}
```

Reject wrong action/product/request ID, a request ID not present in the immutable request summary, placeholder values, profile-binding digest/hash/team/commit mismatch, attempt other than the explicitly approved integer, expired/future approval, duration over 30 minutes, unexpected fields, world/group-readable approval files, symlinks, and reused approvals. Tests prove the preparer cannot create an approval record and that the wrapper cannot convert a request into approval automatically.

`Tests/Scripts/test-register-notary-profile.sh` uses fake Apple tools to require: exact 10-character Team ID; Developer ID certificate Organizational Unit equals that Team ID; trusted/unexpired certificate with private key; interactive `notarytool store-credentials <profile> --team-id <team> --validate` shape with no password/Apple ID in argv; successful `notarytool history`; owner-only nonsymlink receipt; and rejection of any identity/team/profile/digest mismatch. The production registration command is never run by automated implementation tests.

The local binding receipt schema contains binding nonce, Team ID, signing-certificate SHA-256, hashed profile name plus salt, `notarytool` version, validated-at/expiry timestamps, and its own canonical SHA-256; no Apple ID, password, API key, issuer private key, or certificate body. A real registration is an explicit interactive user prerequisite and network/Keychain state change; implementation stops and asks before running it.

- [ ] **Step 2: Write the fake-notary integration test**

`Tests/Scripts/test-notarize-approved.sh` injects fake `xcrun`, `shasum`, and clock values. Assert:

```text
no approval -> no xcrun invocation
changed DMG byte -> no xcrun invocation
wrong Team ID/commit -> no xcrun invocation
reused consumed approval -> no xcrun invocation
valid approval -> exactly one notarytool submit invocation
rejected result -> no automatic retry and no stapler invocation
accepted result -> log fetched, reviewed, then stapler invoked
```

The exact submit shape is:

```bash
xcrun notarytool submit <exact-dmg> \
  --keychain-profile <local-profile> \
  --wait \
  --timeout 30m \
  --output-format json
```

The keychain profile name must not enter committed files or public evidence. Test mode uses `UTTERINK_RELEASE_TEST_MODE=1` plus a dedicated fake-tool root; production mode ignores caller `PATH` and invokes `/usr/bin/xcrun`, `/usr/bin/shasum`, `/usr/bin/codesign`, and other Apple/system tools by absolute path.

- [ ] **Step 3: Run to verify failure**

```bash
python3 Tests/Scripts/test-notarization-gate.py
bash Tests/Scripts/test-register-notary-profile.sh
bash Tests/Scripts/test-notarize-approved.sh
```

Expected: FAIL because the guarded notarization scripts do not exist.

- [ ] **Step 4: Implement request preparation and approval consumption**

The request preparer generates a 32-byte random request ID with the OS CSPRNG. Its summary contains that ID, product, candidate commit/tree, Apple Team ID, profile-binding receipt SHA-256, signed pre-staple DMG filename/size/SHA-256, signing verification result, and the statement “one upload attempt only; rejection or any file change requires new approval.” It contains no profile name/credentials and cannot emit the approval schema.

Before approval consumption, `verify-notary-profile-binding.sh` recomputes the supplied profile-name hash from the receipt salt, proves the Developer ID certificate's Organizational Unit/Team ID and certificate digest equal the receipt/approved team, verifies certificate trust/expiry/private-key availability and receipt freshness, authenticates the supplied profile with `/usr/bin/xcrun notarytool history`, and requires the receipt SHA-256 to equal the request and approval. If any authoritative link cannot be established, stop rather than upload. `notarize-approved.sh` opens the approval without following symlinks, checks owner-only `0600` permissions, validates request ID/schema/hash/team/commit/time and the binding result, atomically renames approval to a consumed record before network access, and installs a trap that records whether the attempt was invoked. A crash after consumption does not restore approval.

Ignore `.release-approvals/`, `.notary-profile-bindings/`, consumed approvals, request summaries, Apple JSON/logs, and all profile names. Tests require `git check-ignore` for each local record class.

- [ ] **Step 5: Implement result, log, stapling, and post-staple verification**

Save the sanitized submission ID and raw Apple JSON/log under the ignored release evidence work directory with owner-only permissions. `verify-notarization-result.py` requires status `Accepted`, parses the complete `notarytool log`, fails on invalid/error issues, and emits a reviewer-visible warnings list even when accepted. It never auto-retries.

Only after accepted log review does the wrapper run:

```bash
xcrun stapler staple <exact-dmg>
xcrun stapler validate <exact-dmg>
```

Then re-mount, verify the allowed content manifest, recursively re-verify app/DMG signatures, and compute the final post-staple SHA-256. Any failure quarantines the candidate as unusable and does not modify or resubmit it.

- [ ] **Step 6: Verify the guard without contacting Apple and commit**

```bash
chmod +x Scripts/release/register-notary-profile.sh Scripts/release/verify-notary-profile-binding.sh Scripts/release/notarize-approved.sh
test -x Scripts/release/notarize-approved.sh
python3 Tests/Scripts/test-notarization-gate.py
bash Tests/Scripts/test-register-notary-profile.sh
bash Tests/Scripts/test-notarize-approved.sh
./Scripts/ci-local.sh
git add docs/release/notarization-approval.schema.json docs/release/notary-profile-binding.schema.json docs/RELEASING.md Scripts/release Tests/Scripts .gitignore
git commit -m "build: gate notarization by exact artifact approval"
```

Expected: all tests use fakes; no real `notarytool submit` occurs.

**STOP:** Do not run the real wrapper. Real submission is an external action and requires a fresh user approval after the signed pre-staple hash and request summary exist.

---

### Task 6: Verify the immutable final DMG and collect local/second-Mac evidence

**Files:**
- Create: `docs/release/manual-verification-matrix.md`
- Create: `docs/release/evidence-packet-template.md`
- Create: `Scripts/release/verify-final-dmg.sh`
- Create: `Scripts/release/collect-evidence.py`
- Create: `Tests/Scripts/test-verify-final-dmg.sh`
- Create: `Tests/Scripts/test-collect-evidence.py`
- Modify: `docs/RELEASING.md`

**Interfaces:**
- `verify-final-dmg.sh --dmg <path> --expected-sha256 <hash> --evidence <directory>` is read-only and refuses any mismatch.
- `collect-evidence.py --inputs <directory> --output <file> --expect-status READY|NOT_RELEASE_READY` validates every evidence class, computes one of those exact statuses, redacts machine/user details, and exits nonzero if the computed status does not equal the explicit expectation.
- Manual evidence is recorded as pass/fail/not-run with tester, supported macOS version, Apple Silicon model class, timestamp, exact final hash, and concise observation; no checkbox can default to pass.

- [ ] **Step 1: Write final-artifact verification tests**

`Tests/Scripts/test-verify-final-dmg.sh` injects fake `hdiutil`, `codesign`, `spctl`, `xcrun stapler`, `xattr`, and hash tools. Require these checks in order:

1. Expected final SHA-256 equals current bytes.
2. Staple validates.
3. DMG mounts read-only and matches the allowlist.
4. Contained app and every nested component pass strict signature checks.
5. DMG passes `spctl --assess --type open --context context:primary-signature`.
6. App copied from the mounted DMG passes `spctl --assess --type execute`.
7. Original final DMG metadata is only inspected and never modified; no command strips quarantine.
8. Hash still matches after all read-only validation.

Each injected failure must stop the script with a distinct code and a sanitized diagnostic.

- [ ] **Step 2: Define the complete manual matrix**

`manual-verification-matrix.md` must cover, at minimum:

- A real Apple Silicon Mac running macOS 14.x for minimum-runtime launch, onboarding, permissions, model preset, dictation, history, provider, delivery, and accessibility smoke; compiling with a 14.0 deployment target is not runtime evidence.
- Install from the final stapled/quarantined DMG; copy from DMG to Applications; first launch and relaunch.
- Microphone and Accessibility permission grant/denial/recovery.
- Model missing/download/loading/ready/failure/retry; offline local transcription after model readiness.
- Shortcut, menu, floating recorder, cancel/stop, processing labels, focus-change fallback, explicit Copy, pasteboard restoration/conflict behavior.
- Raw persistence before polishing; history on/off/clear/delete/retry/paste-again; crash-orphan audio sweep.
- OpenAI-compatible HTTPS provider plus loopback HTTP; normalized host disclosure; failure without transcript/key/body leakage.
- Menu bar, floating recorder, onboarding, Settings, History, last-result, and dialogs under VoiceOver, keyboard-only traversal, visible focus, no traps, focus restoration, Increase Contrast, Differentiate Without Color, Reduce Motion, dark/light mode, and supported larger text/display settings.
- Every shipped UI localization across every state; `0.1.0` ships English only unless another localization has the same completed matrix.
- Final stapled/quarantined DMG under a clean user account on a second supported Apple Silicon Mac without the development certificate or cached ticket, including an offline first launch that proves stapling.

The second-Mac record must be bound to the final SHA-256 and may not be substituted with another user account on the development Mac.

This test does not silently authorize beta transfer. The user may run it on another Mac they own, or perform it themselves and return only the hash-bound result record. Before any other person/channel receives the DMG, stop and obtain the separate one-time beta-transfer approval naming recipient, channel, exact final SHA-256, and notarization state. Without second-Mac evidence, the collector reports `NOT RELEASE READY`; it never sends the artifact to fill the gap.

- [ ] **Step 3: Write the failing evidence collector test**

`Tests/Scripts/test-collect-evidence.py` builds complete, incomplete, malformed, and contradictory fixture packets. A complete packet computes `READY`; a structurally valid packet with recognized missing/failed gates computes `NOT_RELEASE_READY` and lists every gap. Malformed/contradictory/canary-bearing evidence is rejected rather than classified. The test runs both expectation values against both computed statuses and proves a mismatch, omitted/unknown `--expect-status`, or any attempt to coerce a missing gate to pass exits nonzero. Required evidence classes are:

```text
candidate/toolchain/dependency lock
approved repository/branch scope and exact commit
complete sorted public file list
full-history secret/private-data scan
source/IP/provenance/license/model notice review
tests/build/unsigned CI smoke
identity approval, separate competitor-similarity and trademark-risk results
accessibility matrix
signing/entitlements/codesign evidence
notarization submission/log review/staple validation
DMG filename/size/manifest/pre-staple approved hash/final hash
local Gatekeeper and second-Mac clean-user offline Gatekeeper
privacy/security/docs/link/Markdown validation plus rendered English README, Chinese README, and Privacy previews
known issues and exact support/non-goal scope
verified `release-assets-evidence.json` for exact public asset/source archive/checksum inventory
```

Canary fields containing a home path, username, credential/profile name, transcript, prompt, provider URL path/query, response body, clipboard data, or signing certificate body must be rejected/redacted.

- [ ] **Step 4: Implement read-only final verification and evidence assembly**

`verify-final-dmg.sh` never calls a mutating command and records only allowlisted values. For local Gatekeeper launch testing, create a byte-identical test copy, verify its SHA-256 equals the final content hash, apply quarantine only to that copy, and record the copied path as ephemeral; the immutable release original is untouched. `collect-evidence.py` validates every JSON input against the evidence schema, confirms repository/branch/commit, public file list, rendered-doc previews, support scope, artifact sizes/hashes, and all other evidence refer to the same candidate. It requires the notarization approval hash to match the pre-staple hash and final-hash manual tests to match the immutable post-staple file. `READY` is possible only when every required gate is present and passing. `NOT_RELEASE_READY` is a successful classification only for structurally valid evidence with at least one enumerated missing/failed gate; it cannot launder malformed data or unknown failures. The output embeds the computed status before the expectation comparison.

The packet summary lists failures first, then passed automated/manual gates, then outstanding external approvals. It must state that a complete packet is evidence for user review—not permission to push, transfer, make public, or release.

- [ ] **Step 5: Verify and commit**

```bash
chmod +x Scripts/release/verify-final-dmg.sh
test -x Scripts/release/verify-final-dmg.sh
bash Tests/Scripts/test-verify-final-dmg.sh
python3 Tests/Scripts/test-collect-evidence.py
./Scripts/ci-local.sh
git add docs/release docs/RELEASING.md Scripts/release Tests/Scripts
git commit -m "test: add final distribution evidence gates"
```

---

### Task 7: Generate exact-commit release assets without publishing them

**Files:**
- Create: `docs/release/release-notes-0.1.0.md`
- Create: `Scripts/release/create-source-archives.sh`
- Create: `Scripts/release/assemble-release-assets.sh`
- Create: `Scripts/release/verify-release-assets.sh`
- Create: `Scripts/release/prepare-incomplete-evidence.py`
- Generate locally: `.release-work/evidence/release-assets-evidence.json` (ignored)
- Generate locally after asset verification: `.release-work/incomplete-evidence-packet.review-1.md` (ignored and outside the evidence input directory)
- Create: `Tests/Scripts/test-create-source-archives.sh`
- Create: `Tests/Scripts/test-verify-release-assets.sh`
- Create: `Tests/Scripts/test-prepare-incomplete-evidence.py`
- Modify: `CHANGELOG.md`
- Modify: `README.md`
- Modify: `README.zh-CN.md`
- Modify: `docs/RELEASING.md`

**Interfaces:**
- `create-source-archives.sh --commit <sha> --output <directory> [--expected-origin <canonical URL>]` creates deterministic `.tar.gz` and `.zip` source archives from that exact verified commit, excluding Git metadata and generated/private files.
- `assemble-release-assets.sh` accepts only the immutable final DMG and already-verified source archives, produces `SHA256SUMS`, and never invokes GitHub/network commands.
- Planned local asset names are exactly:

```text
UtterInk-0.1.0-arm64.dmg
UtterInk-0.1.0-source.tar.gz
UtterInk-0.1.0-source.zip
SHA256SUMS
release-notes-0.1.0.md
```

The evidence packet remains an ignored local review artifact outside the public asset directory and outside public `SHA256SUMS`. It is shown to the user before publication but is never uploaded unless a later separate approval explicitly scopes a sanitized public version.

- [ ] **Step 1: Write failing deterministic-archive tests**

`Tests/Scripts/test-create-source-archives.sh` creates the same fixture commit in two different absolute directories, with different user names, locales, time zones, and umasks. Require byte-identical archives and verify they contain only tracked release-source files at a top-level `UtterInk-0.1.0/` directory.

Reject inclusion of `.git`, `.github` credentials, `.env`, local approvals, evidence work files, `dist`, archives, DMGs, DerivedData, user paths, notarization profiles/logs, certificates, or private import-review notes.

- [ ] **Step 2: Run to verify failure**

Run `bash Tests/Scripts/test-create-source-archives.sh`.

Expected: FAIL because the archive script does not exist.

- [ ] **Step 3: Implement exact-commit archives and release inventory**

Read `releaseTag` from locked metadata and forward optional expected-origin into exact-candidate verification. Create a local lightweight `v0.1.0` tag only if absent; if it exists, require `git rev-parse v0.1.0^{commit}` to equal the candidate commit or fail without moving it. Record tag→commit in local release evidence and candidate/release request. Use `git archive <exact-commit>` as the only source of archive content, normalize prefix and compression metadata, and verify the extracted tree hash against the commit. Do not use the mutable working tree or rely on GitHub-generated archives. Creating/pushing the remote tag remains part of the later separately approved GitHub Release action; this task performs no push.

`verify-release-assets.sh` requires exact filenames, version/tag/commit agreement, final DMG hash agreement, valid sorted two-space `SHA256SUMS`, no extra files, and release notes that state macOS 14+, Apple Silicon, manual updates/no automatic updater, local audio handling, optional remote transcript text processing, known limitations, and checksum instructions. It does not read or require the final evidence packet; on success it emits `release-assets-evidence.json` bound to the exact assets/hashes.

- [ ] **Step 4: Write release notes and update public documentation**

Add `0.1.0` to `CHANGELOG.md`. Update both READMEs with reproducible source build/test/unsigned-package commands and link to signing/releasing documentation without suggesting that contributors need Apple credentials. `docs/RELEASING.md` separates:

1. Reproducible unsigned verification available to contributors.
2. Local maintainer-only signing and evidence preparation.
3. User-approved notarization submission.
4. Second-Mac final verification.
5. Separately approved GitHub/publication actions.

- [ ] **Step 5: Verify the local asset assembler has no publication capability**

`Tests/Scripts/test-verify-release-assets.sh` scans scripts and execution logs. It must reject `gh`, `git push`, GitHub API calls, `curl`/`wget`, release creation, repository visibility changes, email/messaging transfer, and any upload other than the separately guarded `notarytool` wrapper from Task 5. The assembler itself must have zero network calls.

`prepare-incomplete-evidence.py --commit <40-char sha> --output <empty directory> [--expected-origin <canonical URL>]` is a production-safe local status initializer, not a passing fixture. It runs exact clean-commit/origin/schema checks, creates the directory only if absent or empty, and writes a sanitized base-evidence record bound to that commit. Every class without real evidence—signing, notarization approval/submission/log review/stapling, final DMG, local/second-Mac Gatekeeper, verified release assets, beta/publication approvals—is explicitly `not-run` with a stable gate code; the command has no option that can mark a gate passed. It may import an existing hash-bound automated evidence file only after schema/commit validation and never invents test success. `test-prepare-incomplete-evidence.py` proves dirty/mismatched commits, nonempty/symlink/out-of-root outputs, unknown origins, canaries, status overrides, and fabricated pass inputs fail; a clean fixture produces byte-identical `NOT_RELEASE_READY` inputs twice in separate roots.

- [ ] **Step 6: Run fake/base verification and commit the release-asset tooling**

The ordering is mandatory: assemble assets → verify assets → emit `release-assets-evidence.json` → collect the final evidence packet using that result. The final collector may not accept an asset inventory that lacks the verifier's signed-off JSON. Before any real signing/notarization exists, run all automated tests with fixture evidence and expect a clearly labeled `NOT RELEASE READY` result for absent real signatures, notarization, second-Mac results, and real release assets—not a false pass.

```bash
chmod +x Scripts/release/create-source-archives.sh Scripts/release/assemble-release-assets.sh Scripts/release/verify-release-assets.sh
test -x Scripts/release/verify-release-assets.sh
bash Tests/Scripts/test-create-source-archives.sh
bash Tests/Scripts/test-verify-release-assets.sh
python3 Tests/Scripts/test-prepare-incomplete-evidence.py
./Scripts/ci-local.sh
python3 Scripts/check-public-docs.py
./Scripts/scan-public-history.sh
./Scripts/collect-third-party-notices.sh --check
git diff --check
git add CHANGELOG.md README.md README.zh-CN.md docs/RELEASING.md docs/release/release-notes-0.1.0.md Scripts/release Tests/Scripts
git commit -m "docs: prepare UtterInk 0.1.0 release assets"
```

- [ ] **Step 7: Re-run exact-candidate checks from the new clean commit and stop**

```bash
./Scripts/bootstrap-xcodegen.sh
./Scripts/verify-toolchain.sh --context local
./Scripts/ci-local.sh --ci --unsigned-package-smoke
./Scripts/clean-distribution-output.sh
python3 Scripts/release/prepare-incomplete-evidence.py --commit "$(git rev-parse HEAD)" --output .release-work/incomplete-evidence
python3 Scripts/release/collect-evidence.py --inputs .release-work/incomplete-evidence --output .release-work/incomplete-evidence-packet.review-1.md --expect-status NOT_RELEASE_READY
test -f .release-work/incomplete-evidence-packet.review-1.md
test -z "$(git status --short)"
```

Expected: exact-commit unsigned smoke passes and its distributable/build outputs are removed before the status packet is initialized; incomplete real-release evidence is accurately reported as `NOT RELEASE READY`. The ignored final packet remains locally available for the user review required by this plan and is not uploaded or included in public assets. After future authorized signing/notarization/second-Mac work supplies real evidence, rerun the mandatory assemble → verify-assets → collect-final-evidence order against that unchanged commit/artifact set.

**STOP:** At the end of implementation, hand the user the local evidence status and exact missing gates. Do not create a GitHub repository, push, submit to Apple, send a beta, change visibility, tag remotely, or publish a GitHub Release. Each external action requires its own artifact-scoped approval immediately before execution.

---

## Distribution-plan completion gate

This plan is complete only when:

1. CI policy, local CI, core tests, app build, history/privacy scans, and unsigned packaging smoke pass from a clean tree.
2. Release scripts pass fake-tool adversarial tests and cannot bypass exact-commit, hash, approval, or one-attempt gates.
3. No real credential, certificate, Keychain profile, API key, personal path, transcript, provider payload, clipboard content, or notarization upload entered Git/CI.
4. The unsigned CI artifact is deleted and never uploaded.
5. The local pre-publication evidence fixture correctly remains `NOT RELEASE READY` until real signing, artifact-scoped notarization approval/submission, log review, stapling, final verification, and second-Mac testing occur.
6. All source changes and plan-required public docs are committed, `git diff --check` passes, and `git status --short` is empty.

Passing this gate authorizes no external action. It only makes the project ready for the user to review and approve each later external step separately.
