# Releasing UtterInk

This document separates reproducible unsigned verification from maintainer-only
signing, notarization, final verification, and publication. It describes the
approved release process; it does not authorize any external action.

## Release contract

The planned first release has one fixed identity:

- product: `UtterInk`;
- marketing version and build: `0.1.0` (`1`);
- bundle identifier: `dev.utterink.UtterInk`;
- minimum deployment target: macOS `14.0`;
- release architecture and configuration: `arm64`, `Release`;
- planned tag: `v0.1.0`; and
- planned DMG filename: `UtterInk-0.1.0-arm64.dmg`.

`Config/release-metadata.json` and the configuration files under `Config/` are
the source of these values. A candidate is valid only when the source files,
effective Xcode build settings, generated project, package resolution, release
text, tag, and filename agree.

## Current toolchain-lock status

The reviewed CI and release lock is the official `macos-26` arm64 runner image
`20260720.0258.1` with macOS `26.4` build `25E246`, Xcode `26.4.1` build
`17E202`, macOS SDK `26.4` build `25E251`, Apple Swift `6.3.1`, and the official
XcodeGen `2.45.4` release archive. The archive, exact executable architecture
set, companion presets, upstream source revision, and complete runner tuple are
independently hash- or commit-locked in `Config/ci-toolchain.json`.

A read-only CI attempt captured the replacement runner's image and OS identity;
before the expected image-version gate stopped the workflow, it also passed the
locked Xcode, SDK, Swift, and XcodeGen checks. It used no repository secrets,
signing, notarization, artifact upload, or publication. A prior read-only probe
on the immediately preceding runner image, which carried the same OS and
toolchain tuple, built a clean unsigned `Release` archive using
`-no_adhoc_codesign`, recorded the exact processed `Info.plist` generated-key
set, and confirmed that the app has no nested signable code components. Its
three Swift package `.bundle` directories contain resources rather than
executables and therefore are not nested signing targets.

The current development Mac selects Xcode `26.4.1` build `17E202` and Apple
Swift `6.3.1`, matching the locked local toolchain tuple. Candidate evidence is
accepted only when the complete environment and every committed lock value are
verified; the official CI evidence remains bound to the locked `macos-26`
runner image above.

Toolchain drift fails closed. A rolling runner-image update, dependency update,
Action update, Xcode update, SDK update, Swift update, or XcodeGen update
requires a dedicated reviewed lock change and fresh evidence.

The reviewed immutable release and source identities for the lock are:

- GitHub's official [`macos-26-arm64/20260720.0258` runner release](https://github.com/actions/runner-images/releases/tag/macos-26-arm64%2F20260720.0258)
  and its [commit-pinned software inventory](https://github.com/actions/runner-images/blob/4872600e5cdb875ed132ff1c98e2599546c51337/images/macos/macos-26-arm64-Readme.md);
- XcodeGen [`2.45.4`](https://github.com/yonaskolb/XcodeGen/releases/tag/2.45.4),
  its content-addressed official
  [`xcodegen.zip`](https://github.com/yonaskolb/XcodeGen/releases/download/2.45.4/xcodegen.zip)
  release asset, and upstream source commit
  [`8d3d3476a69ae3e5d68e1adccc701c410c05eb36`](https://github.com/yonaskolb/XcodeGen/commit/8d3d3476a69ae3e5d68e1adccc701c410c05eb36);
  and
- `actions/checkout` at reviewed commit
  [`de0fac2e4500dabe0009e67214ff5f5447ce83dd`](https://github.com/actions/checkout/commit/de0fac2e4500dabe0009e67214ff5f5447ce83dd).

Those references and the runner-observed values are both required. Bootstrap,
toolchain verification, CI mode, and the candidate path stop on any mismatch
rather than fall back to Homebrew, an ordinary `PATH` executable, or guessed
values.

The pull-request workflow is source verification only. It has read-only
repository permission, checks out full history without persisted credentials,
uses only reviewed commit-pinned Actions, never receives Apple or provider
secrets, never signs or notarizes, and never uploads its unsigned output. Its
final cleanup runs even after a failed verification step. Updating a runner,
Xcode, SDK, Swift, XcodeGen, dependency, or Action is a dedicated reviewable
change; routine dependency updates must not silently move any release input.

## Contributor unsigned verification

Contributors do not need an Apple Developer certificate, a notarization
profile, a provider credential, or any maintainer secret. From a clean checkout,
contributors can validate the normalized release metadata and ordinary source
workflow with:

```bash
python3 Scripts/release/read-metadata.py --json
python3 Tests/Scripts/test-release-metadata.py
./Scripts/ci-local.sh
```

The complete local verification performs source, policy, package, build, test,
and generated-project checks with code signing disabled where appropriate. See
[Contributing](../CONTRIBUTING.md) for the development workflow. An unsigned
build or unsigned packaging smoke test is verification only: it is not a
distributable release, is not uploaded by default, and must never be reused as
a signed candidate.

With the reviewed toolchain lock committed, the unsigned packaging smoke path
is invoked from one exact clean commit as follows. This first form is only for
a repository that has no Git remote:

```bash
./Scripts/bootstrap-xcodegen.sh
./Scripts/verify-toolchain.sh --context local
./Scripts/package-unsigned-smoke.sh \
  --commit "$(git rev-parse HEAD)" \
  --output dist/unsigned-smoke
./Scripts/inspect-dmg.sh \
  --dmg dist/unsigned-smoke/UtterInk-0.1.0-arm64-UNSIGNED-DO-NOT-DISTRIBUTE.dmg \
  --mode unsigned
./Scripts/clean-distribution-output.sh
```

For an ordinary clone that has an `origin`, pass the separately reviewed,
canonical URL explicitly; do not derive the expected value from the repository
configuration that it is meant to check:

```bash
EXPECTED_ORIGIN='https://github.com/kthree0213/UtterInk.git'
./Scripts/package-unsigned-smoke.sh \
  --commit "$(git rev-parse HEAD)" \
  --output dist/unsigned-smoke \
  --expected-origin "$EXPECTED_ORIGIN"
```

Gate 1 approved the first push of `kthree0213/UtterInk`, and Gate 4 separately
approved and completed its transition to public visibility. This origin value
and the completed visibility transition do not authorize a tag, GitHub Release,
release-asset publication, or Apple upload.

When repository origin scope is known locally, supply it explicitly with
`--expected-origin` to the package command. For the local packaging mode of
`Scripts/ci-local.sh`, set `UTTERINK_EXPECTED_ORIGIN` explicitly. Local mode
never infers that value from ambient GitHub variables. CI derives exactly the
credential-free `GITHUB_SERVER_URL/GITHUB_REPOSITORY` URL configured by
`actions/checkout` (without a `.git` suffix), passes the same value to both the
history scan and package verifier, runs the CI verifier with both the `--ci`
and `--unsigned-package-smoke` flags, and removes `dist/` in its unconditional
cleanup step. The workflow contains no artifact-upload step.

The smoke filename deliberately contains `UNSIGNED-DO-NOT-DISTRIBUTE`. Its
DMG may contain only `UtterInk.app` and the `Applications -> /Applications`
symlink. Inspection is read-only and rejects unexpected files, metadata,
architectures, links, signatures, or additional mounted volumes. After exact
candidate verification, archive creation, DMG creation, and inspection run
from an isolated local clone detached at that commit; only the inspected bytes
are atomically linked into the requested output directory. The real commands
stop before producing a package if any committed toolchain value is absent or
mismatched; the offline fake-tool tests do not waive that lock.

## Release-candidate evidence

`Scripts/release/verify-candidate.sh` is the entry point for creating
`candidate.json`. It must start from a clean checkout at one exact 40-character
commit, verify the complete history and expected origin scope, resolve packages
without changing the committed lockfile, regenerate the project without a
diff, compare the effective Release build settings, and pass the reviewed
entitlement and Info policy checks.

Invoke that entry point directly as `./Scripts/release/verify-candidate.sh`, not
by supplying another shell interpreter. Its executable entry point starts Bash
in a restricted mode and replaces the inherited process environment with an
allowlisted one before running any candidate logic.

The result must validate against
[`release/evidence-schema.json`](release/evidence-schema.json) before it is
atomically installed. The schema records only allowlisted release identity,
lowercase commit/tree/content hashes, tool versions, fixed repository-relative
policy inputs, and passing check booleans. It rejects extra fields. Candidate
evidence must not contain a username, personal or machine-specific absolute
path, signing identity, Apple team, certificate content, Keychain profile name,
credential, provider detail, environment dump, transcript, prompt, clipboard
content, or diagnostic payload.

Every later release phase consumes the same immutable `candidate.json`. A
different commit, tree, package lock, policy hash, toolchain hash, version,
architecture, tag, or filename is a different candidate and must begin again.

## Local maintainer phases

Signing and notarization are local maintainer operations, never contributor or
pull-request CI requirements. They remain separate phases:

1. Verify the exact clean commit and create the schema-valid candidate record.
2. Build an unsigned `Release`/`arm64` archive from that candidate without a
   local source overlay.
3. Select one explicitly supplied Developer ID Application identity, verify its
   trust and Apple team locally, then sign nested components inside out and the
   app last with Hardened Runtime and secure timestamps. `codesign --deep` is
   forbidden.
4. Verify every component, create and sign the allowlisted DMG, mount it
   read-only, verify its contents, and record the signed pre-staple SHA-256.
5. Stop for the separate, one-use notarization approval described below.
6. Submit the exact approved pre-staple bytes once, save the sanitized result,
   review the complete notarization log, and never retry automatically.
7. After acceptance, staple and validate the ticket, then repeat signature,
   DMG-content, and Gatekeeper verification.
8. Test a byte-identical quarantined copy locally and complete the hash-bound
   clean-user, offline Gatekeeper check on a second supported Apple Silicon Mac.
9. Record the final post-staple SHA-256, assemble exact-commit source archives,
   checksums, release notes, and the evidence packet for user review.

Committed configuration and evidence never contain a signing identity, Apple
team value, certificate or private-key material, notarization profile, or
credential. Those values are supplied and validated locally only when an
authorized phase needs them.

### Guarded local signing pipeline

The guarded local pipeline implements the unsigned build, local Developer ID
signing, signature verification, and signed pre-staple DMG phases. Use a fresh,
ignored work directory for one reviewed commit. A repository with no Git remote
uses:

```bash
COMMIT="$(git rev-parse --verify HEAD)"
WORK='.release-work/v0.1.0-candidate'

./Scripts/release/build-candidate.sh \
  --commit "$COMMIT" \
  --work "$WORK"
```

If the repository has an `origin`, pass its separately reviewed canonical URL
to the same command rather than trusting the configured remote as its own
reference:

```bash
EXPECTED_ORIGIN='https://github.com/kthree0213/UtterInk.git'
./Scripts/release/build-candidate.sh \
  --commit "$COMMIT" \
  --work "$WORK" \
  --expected-origin "$EXPECTED_ORIGIN"
```

On success, the fixed build outputs are `$WORK/UtterInk.xcarchive`,
`$WORK/candidate/candidate.json`,
`$WORK/candidate/unsigned-build-evidence.json`, and
`$WORK/candidate/UtterInk.app`. The unsigned-build evidence binds the exact
candidate commit and candidate record to deterministic SHA-256 tree hashes for
both the archived app and the complete archive. The work path must not already
exist; the command never overwrites an earlier candidate.

After reviewing those outputs, supply the exact local identity and matching
team only as command parameters:

```bash
SIGNING_IDENTITY='<reviewed Developer ID Application identity>'
TEAM_ID='<matching 10-character Apple team ID>'

./Scripts/release/sign-candidate.sh \
  --candidate "$WORK/candidate" \
  --identity "$SIGNING_IDENTITY" \
  --team-id "$TEAM_ID"

./Scripts/release/create-signed-dmg.sh \
  --candidate "$WORK/candidate" \
  --identity "$SIGNING_IDENTITY" \
  --team-id "$TEAM_ID"
```

Successful app signing adds
`$WORK/candidate/signature-verification.json`. Successful signed-DMG creation
then adds `$WORK/candidate/UtterInk-0.1.0-arm64.dmg`,
`$WORK/candidate/pre-staple.sha256`, and
`$WORK/candidate/signing-evidence.json`. The signing identity and team ID are
maintainer-supplied parameters; no concrete value belongs in committed
configuration, documentation, or committed evidence. All generated candidate
and signing evidence remains local and uncommitted under `.release-work`.

The reviewed local toolchain now matches the lock and can create unsigned
release-candidate evidence. The automated tests use only fake tools and fixture
identities; they never select, inspect, or use a real certificate. Real signing
still fails closed unless the maintainer explicitly supplies a matching
Developer ID Application identity and Apple team. These commands do not
notarize, upload, staple, or publish any artifact.

### One-use notarization approval gate

Notarization is a separate external action. The guarded implementation never
derives upload approval from this document, a design approval, a completed
build, a stored profile, or an existing local file. Its automated tests use
only fake Apple tools and never contact Apple or modify a real Keychain.

A real notary profile must first be registered interactively under its own
explicit approval. The registration command validates one exact Developer ID
Application certificate, Team ID, private-key availability, and the profile
with Apple, then writes only a salted, owner-only binding receipt under the
ignored `.notary-profile-bindings/` directory. It never writes the profile
name, Apple ID, password, API key, certificate body, or private key into that
receipt. The future approved command shape is:

```bash
NOTARY_PROFILE='<local Keychain profile name>'
PROFILE_RECEIPT='.notary-profile-bindings/v0.1.0.json'

./Scripts/release/register-notary-profile.sh \
  --identity "$SIGNING_IDENTITY" \
  --team-id "$TEAM_ID" \
  --keychain-profile "$NOTARY_PROFILE" \
  --receipt "$PROFILE_RECEIPT"
```

Do not run that production command without separately approving its Keychain
and network changes. Registration is a prerequisite, not notarization-upload
approval.

After the exact signed pre-staple DMG and retained signing evidence have been
reviewed, create a local sanitized request summary. This step is read-only with
respect to Apple and cannot create an approval:

```bash
REQUEST='.release-requests/v0.1.0.json'

python3 Scripts/release/prepare-notarization-request.py prepare \
  --candidate "$WORK/candidate" \
  --apple-team-id "$TEAM_ID" \
  --profile-binding-receipt "$PROFILE_RECEIPT" \
  --output "$REQUEST"
```

The request binds an unpredictable request ID, candidate commit and tree,
Apple Team ID, complete profile-receipt SHA-256, signed pre-staple DMG name,
size and SHA-256, retained signature-verification evidence, and attempt `1`.
It states that rejection or any changed byte requires a new request and a new
approval. Request summaries remain owner-only and ignored under
`.release-requests/`.

Only after reviewing that summary may the user manually create an owner-only
`0600` approval matching
`docs/release/notarization-approval.schema.json`. The approval expires within
30 minutes and binds the exact request ID, Team ID, candidate commit,
pre-staple DMG SHA-256, profile-receipt SHA-256, and one attempt. No repository
script turns a request into approval.

Gate 2 approval authorizes one invocation only:

```bash
APPROVAL='.release-approvals/<request-id>.json'

./Scripts/release/notarize-approved.sh \
  --dmg "$WORK/candidate/UtterInk-0.1.0-arm64.dmg" \
  --approval "$APPROVAL" \
  --keychain-profile "$NOTARY_PROFILE"
```

Before any DMG upload, the wrapper uniquely locates and revalidates the request
and profile receipt by their bound values, validates the exact DMG, and checks
the local profile with `notarytool history`. That read-only profile check may
contact Apple, but it does not upload the DMG or consume the approval. The
wrapper then refreshes the clock and all pinned inputs before atomically
consuming the approval immediately before the one permitted submission. A
crash, rejection, timeout, or other failure after consumption never restores
it and never triggers an automatic retry. Only an accepted submission with a
completely reviewed log may proceed to stapling, post-staple signature and
manifest verification, and the final DMG hash. Raw Apple responses and local
profile state remain ignored, owner-only local evidence; none of these steps
publishes or transfers the DMG.

### Final-DMG verification and release evidence

After an accepted notarization result has been fully reviewed, the ticket has
been stapled and validated, and the post-staple DMG hash has been recorded,
verify that immutable final artifact without changing it:

```bash
ROOT="$(pwd -P)"
FINAL_DMG="$ROOT/.release-work/v0.1.0-candidate/candidate/UtterInk-0.1.0-arm64.dmg"
FINAL_SHA256='<reviewed 64-character lowercase post-staple SHA-256>'
EVIDENCE="$ROOT/.release-work/v0.1.0-evidence"

./Scripts/release/verify-final-dmg.sh \
  --dmg "$FINAL_DMG" \
  --expected-sha256 "$FINAL_SHA256" \
  --evidence "$EVIDENCE"
```

The verifier checks the current bytes before and after all inspection, validates
the staple, mounts the image read-only, enforces the DMG content allowlist,
strictly verifies the app and every nested signature, and assesses both the DMG
and copied app with Gatekeeper. It never strips quarantine or mutates the
release original. A local launch test instead uses an ephemeral byte-identical
copy, verifies that copy against the final hash before applying quarantine, and
records the copy as ephemeral.

Complete the per-row records in
[`release/manual-verification-matrix.md`](release/manual-verification-matrix.md).
Every row is explicitly `pass`, `fail`, or `not-run` and records a tester label,
coarse Apple Silicon model class, supported macOS version, timestamp, exact
final post-staple SHA-256, locale, and sanitized observation. A successful
macOS 14 deployment-target build is not minimum-runtime evidence: launch and
the required product smoke must run on a real Apple Silicon Mac running macOS
14.x.

The second-Mac Gatekeeper gate requires a distinct physical supported Apple
Silicon Mac, a clean user without the development certificate or a cached
ticket/result for the artifact, quarantine preserved, and a first launch while
offline. Another account, VM, volume, or partition on the development Mac is
not a substitute. The user may run this on another Mac they own and return only
the sanitized hash-bound result. Sending the DMG to another person or channel
requires the separate Gate 3 beta-transfer approval before the transfer; these
instructions do not grant it.

### Exact-commit source archives and local release assets

Only after the immutable final DMG and its reviewed lowercase SHA-256 exist,
assemble the local five-file release inventory. All asset paths below are
physical absolute paths beneath the ignored `.release-work` directory:

```bash
ROOT="$(pwd -P)"
COMMIT="$(git rev-parse --verify HEAD)"
FINAL_DMG="$ROOT/.release-work/v0.1.0-candidate/candidate/UtterInk-0.1.0-arm64.dmg"
FINAL_SHA256='<reviewed 64-character lowercase post-staple SHA-256>'
SOURCE_ARCHIVES="$ROOT/.release-work/v0.1.0-source"
ASSETS="$ROOT/.release-work/v0.1.0-assets"
EVIDENCE="$ROOT/.release-work/v0.1.0-evidence"
ASSET_EVIDENCE="$EVIDENCE/release-assets-evidence.json"

./Scripts/release/create-source-archives.sh \
  --commit "$COMMIT" \
  --output "$SOURCE_ARCHIVES"

./Scripts/release/assemble-release-assets.sh \
  --dmg "$FINAL_DMG" \
  --source-archives "$SOURCE_ARCHIVES" \
  --commit "$COMMIT" \
  --expected-final-dmg-sha256 "$FINAL_SHA256" \
  --output "$ASSETS"

./Scripts/release/verify-release-assets.sh \
  --assets "$ASSETS" \
  --commit "$COMMIT" \
  --expected-final-dmg-sha256 "$FINAL_SHA256" \
  --output "$ASSET_EVIDENCE"
```

If this checkout has an `origin`, pass its separately reviewed canonical URL
to `create-source-archives.sh` with `--expected-origin`; do not derive the
expected value from the remote configuration being checked. Archive creation
uses only the verified tracked tree at `COMMIT`, never the mutable working
tree. If local tag `v0.1.0` already exists it must resolve to that commit; if it
does not exist, the archive command creates a local lightweight tag only after
both archives pass verification. It never moves or pushes a tag.

The asset directory contains exactly `UtterInk-0.1.0-arm64.dmg`, the `.tar.gz`
and `.zip` source archives, `release-notes-0.1.0.md`, and `SHA256SUMS`.
`SHA256SUMS` covers the other four files in byte-sorted filename order. The
verifier independently reconstructs the exact-commit archives, checks the tag,
DMG hash, notes contract, checksums, names, modes, and absence of extra files,
then emits the candidate-bound `release-assets-evidence.json`. That evidence
file stays outside the public asset directory and is not listed in the public
checksums. `EVIDENCE` is the same consolidated directory populated by the
final-DMG, signing, notarization, automated, and manual phases; do not create a
parallel asset-only evidence directory. These commands contain no GitHub
client, push, upload, message, or publication operation.

### Safe incomplete-status initialization

Before real signing and final-release evidence exists, initialize an honest
local status directory from the exact clean candidate commit:

```bash
ROOT="$(pwd -P)"
COMMIT="$(git rev-parse --verify HEAD)"
STATUS_EVIDENCE="$ROOT/.release-work/incomplete-evidence"
STATUS_PACKET="$ROOT/.release-work/incomplete-evidence-packet.review-1.md"

python3 Scripts/release/prepare-incomplete-evidence.py \
  --commit "$COMMIT" \
  --output "$STATUS_EVIDENCE"
python3 Scripts/release/collect-evidence.py \
  --inputs "$STATUS_EVIDENCE" \
  --output "$STATUS_PACKET" \
  --expect-status NOT_RELEASE_READY
```

For a checkout with an `origin`, also pass the separately reviewed canonical
URL through `--expected-origin` to the initializer. The initializer has no
status override: it writes only a canonical `base-evidence.json`, bound to the
exact clean `HEAD`, that classifies every absent real evidence file—including
`candidate.json`, toolchain, and dependency-lock evidence—as `not-run`. It does
not run dependency resolution, XcodeGen, Xcodebuild, or any network operation,
and it does not invent a candidate, signature, artifact hash, approval, tester,
device, timestamp, or pass result. The active baseline itself keeps the packet
`NOT_RELEASE_READY`; after every real evidence class has been supplied and
validated, remove the baseline before requesting a `READY` packet.

Keep every packet outside its `--inputs` directory so a previous packet cannot
be mistaken for an evidence record on the next review. The collector refuses
an output inside the input directory and never overwrites a path. For a later
review, choose a fresh path such as
`.release-work/incomplete-evidence-packet.review-2.md`.

Run exact candidate verification separately when the reviewed toolchain lock
and all candidate prerequisites exist. The initializer never turns an absent
or failed candidate verification into a weaker synthetic candidate record.

After collecting all type-specific JSON records in one ignored evidence
directory, produce the review packet with an explicit expected status:

```bash
ROOT="$(pwd -P)"
EVIDENCE="$ROOT/.release-work/v0.1.0-evidence"
PACKET="$ROOT/.release-work/v0.1.0-final-evidence-packet.review-1.md"

python3 Scripts/release/collect-evidence.py \
  --inputs "$EVIDENCE" \
  --output "$PACKET" \
  --expect-status NOT_RELEASE_READY
```

Use `--expect-status READY` only when every required class is present and
passing. Before real signing, notarization, final-DMG, release-asset, and
second-Mac evidence exists, the honest expected status is
`NOT_RELEASE_READY`. A structurally valid missing or failed gate is listed under
that status; malformed, contradictory, unsafe, stale, or candidate-mismatched
evidence is rejected instead of being laundered as merely incomplete. An
expected/computed status mismatch also exits nonzero.
Use a fresh outside-input packet path for each later collection, for example
`v0.1.0-final-evidence-packet.review-2.md`; do not place a generated packet
among the typed JSON evidence records.

The release candidate record is the one record validated against
[`release/evidence-schema.json`](release/evidence-schema.json). Other Task 6
evidence classes use the collector's closed typed validators; they are not
claimed to share the candidate JSON schema. Every record must agree on the
approved repository/branch scope, exact commit and candidate record, with the
notarization approval bound to the signed pre-staple hash and manual results
bound to the immutable final post-staple hash.

The generated packet's evidence requirements and reviewer worksheet are
documented in
[`release/evidence-packet-template.md`](release/evidence-packet-template.md).
Its summary lists failures/missing gates first, passed automated and manual
gates second, and outstanding external approvals third. A complete packet is
evidence for the user's review only. It does not authorize a push, Apple upload,
beta transfer, visibility change, public asset upload, or release publication.

## Immutable artifact rules

- Build only from the exact clean candidate commit and committed
  `Packages/UtterInkKit/Package.resolved`; a dirty tree or generated-project
  diff invalidates the candidate.
- Treat each mutation boundary as a new artifact. Record hashes after the
  unsigned build, signed app, signed pre-staple DMG, and final stapled DMG as
  required by that phase.
- Compute the pre-staple DMG hash only after every signing and presentation
  mutation is complete. Notarization approval binds that hash, the exact
  candidate commit, the Apple team, and one submission attempt.
- A changed byte, changed team, rejection, expired approval, or second attempt
  invalidates the approval. Stop and obtain a new artifact-scoped approval.
- Compute the final DMG hash only after stapling and all post-staple read-only
  verification. Never modify the release original afterward; quarantine tests
  use a verified byte-identical copy.
- Create source archives only from the exact Git commit, not from the working
  tree. The final asset inventory and `SHA256SUMS` must agree with the immutable
  files and contain no unexpected asset.
- A complete evidence packet is material for user review, not permission to
  push, transfer, change visibility, submit a different artifact, or publish.

## Five independent external-action gates

Each action requires a separate, one-time, artifact-scoped explicit user
approval immediately before it occurs. Approval of this document, a design, an
implementation plan, source changes, or a previous gate does not approve any
other gate.

1. **Create and first-push a GitHub private repository.** Approval identifies
   owner, repository name, private visibility, branch, exact commit, whether
   Actions may run, and whether any CI artifact may be retained.
2. **Upload to Apple for notarization.** Approval identifies the Apple team,
   exact signed pre-staple DMG SHA-256, candidate commit, and exactly one
   submission attempt. It never authorizes a changed file or retry.
3. **Send a beta DMG to another person.** Approval identifies the recipient,
   transfer channel, exact artifact SHA-256, and notarization state. A
   second-Mac test does not silently authorize a beta transfer.
4. **Change the GitHub repository to public.** Approval identifies the
   repository and exact reviewed commit. A private first push does not approve
   public visibility.
5. **Publish the GitHub Release and DMG.** Approval identifies tag and commit,
   final release text, immutable final stapled DMG SHA-256, `SHA256SUMS`, and
   the verified source archives.

Gates 1 and 4 are complete for `kthree0213/UtterInk`. Gates 2, 3, and 5 retain
their independent approval requirements; a second-Mac test does not require
Gate 3 unless the DMG is transferred to another person.

No release command may infer approval from a writable repository file, turn a
request into approval, broaden approval scope, or perform an unapproved retry.
If an expected value or evidence class is missing, inconsistent, malformed, or
stale, the process stops and reports `NOT RELEASE READY`.
