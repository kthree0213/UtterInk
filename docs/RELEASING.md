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

The planned CI and release lock is the official `macos-26` arm64 runner with
Xcode `26.4.1` build `17E202`, macOS SDK `26.4`, and XcodeGen `2.45.4` built
from an immutable reviewed source revision.

That lock is not yet complete. The current development Mac reports Xcode
`26.4` build `17E192`, which is not the planned Xcode `26.4.1` build `17E202`
tuple and therefore is not acceptable release-candidate evidence. The exact
CI-observed SDK build, full Swift version, and XcodeGen built-binary SHA-256
still require a probe on the approved runner. Until those values and their
official sources are reviewed and committed in `Config/ci-toolchain.json`, no
document, local result, or CI result may claim that the release toolchain lock
has passed.

That probe must also build a clean `Release` archive and capture the exact
processed `Info.plist` generated fields and the nested code-component
inventory. The current empty generated-key and nested-component allowlists are
fail-closed placeholders: source policy checks pass, but archived/signed policy
verification is not complete until the locked archive proves the exact fields,
values, and component set. A Debug test-host product is not acceptable evidence
for either inventory.

Toolchain drift fails closed. A rolling runner-image update, dependency update,
Action update, Xcode update, SDK update, Swift update, or XcodeGen update
requires a dedicated reviewed lock change and fresh evidence.

The reviewed immutable source identities for the pending lock are:

- GitHub's official [`macos-26-arm64/20260630.0213` runner release](https://github.com/actions/runner-images/releases/tag/macos-26-arm64%2F20260630.0213)
  and its [commit-pinned software inventory](https://github.com/actions/runner-images/blob/afadebc447d1a69fc726b50cd5aba055c0cfdf82/images/macos/macos-26-arm64-Readme.md);
- XcodeGen [`2.45.4`](https://github.com/yonaskolb/XcodeGen/releases/tag/2.45.4)
  at source commit
  [`8d3d3476a69ae3e5d68e1adccc701c410c05eb36`](https://github.com/yonaskolb/XcodeGen/commit/8d3d3476a69ae3e5d68e1adccc701c410c05eb36);
  and
- `actions/checkout` at reviewed commit
  [`de0fac2e4500dabe0009e67214ff5f5447ce83dd`](https://github.com/actions/checkout/commit/de0fac2e4500dabe0009e67214ff5f5447ce83dd).

Those references prove source identity only. They do not replace the missing
runner-observed SDK build, complete Swift version, source-built XcodeGen binary
hash, or Release archive inventory. Until those facts are committed, the
bootstrap, toolchain verification, CI mode, and candidate path must stop rather
than fall back to Homebrew, an ordinary `PATH` executable, or guessed values.

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

After the reviewed toolchain lock is complete, the unsigned packaging smoke
path is invoked from one exact clean commit as follows. This first form is only
for a repository that has no Git remote:

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
# Replace only after Gate 1 approval.
EXPECTED_ORIGIN='https://github.com/OWNER/UtterInk.git'
./Scripts/package-unsigned-smoke.sh \
  --commit "$(git rev-parse HEAD)" \
  --output dist/unsigned-smoke \
  --expected-origin "$EXPECTED_ORIGIN"
```

Until Gate 1 approves a real owner, repository, and private first push, the
placeholder above is documentation only and must not be treated as an approved
remote.

When repository origin scope is known locally, supply it explicitly with
`--expected-origin` to the package command. For the local packaging mode of
`Scripts/ci-local.sh`, set `UTTERINK_EXPECTED_ORIGIN` explicitly. Local mode
never infers that value from ambient GitHub variables. CI derives exactly
`GITHUB_SERVER_URL/GITHUB_REPOSITORY.git`, passes the same value to both the
history scan and package verifier, runs the CI verifier with both the `--ci`
and `--unsigned-package-smoke` flags, and removes `dist/` in its unconditional
cleanup step. The workflow contains no artifact-upload step.

The smoke filename deliberately contains `UNSIGNED-DO-NOT-DISTRIBUTE`. Its
DMG may contain only `UtterInk.app` and the `Applications -> /Applications`
symlink. Inspection is read-only and rejects unexpected files, metadata,
architectures, links, signatures, or additional mounted volumes. After exact
candidate verification, archive creation, DMG creation, and inspection run
from an isolated local clone detached at that commit; only the inspected bytes
are atomically linked into the requested output directory. While
`Config/ci-toolchain.json` remains incomplete, the real commands above stop
before producing a package; the offline fake-tool tests do not waive that
lock.

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
EXPECTED_ORIGIN='https://github.com/OWNER/UtterInk.git'
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

The real pipeline currently fails closed because `Config/ci-toolchain.json`
does not yet contain the complete reviewed lock. The automated tests use only
fake tools and fixture identities; they never select, inspect, or use a real
certificate. These commands do not notarize, upload, staple, or publish any
artifact.

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

No release command may infer approval from a writable repository file, turn a
request into approval, broaden approval scope, or perform an unapproved retry.
If an expected value or evidence class is missing, inconsistent, malformed, or
stale, the process stops and reports `NOT RELEASE READY`.
