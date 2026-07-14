# Contributing to UtterInk

Thank you for helping improve UtterInk. Contributions should preserve the
project's local-first privacy boundary, recoverable user results, deterministic
source workflow, and accessible macOS experience.

## Code of Conduct

Participation in the project is governed by the
[Code of Conduct](CODE_OF_CONDUCT.md).

## Before opening an issue or pull request

Open an issue or design discussion before implementing any behavior, privacy,
security, architecture, dependency, or visual-identity change. Agreement to
discuss a change is not approval to publish or release it.

Report suspected vulnerabilities privately as described in
[SECURITY.md](SECURITY.md); never place sensitive evidence in a public issue,
discussion, or pull request.

Keep each contribution focused. Describe the user-visible problem, the proposed
behavior, relevant tradeoffs, and observable acceptance criteria before making
a large implementation change.

## Development requirements

The documented source workflow requires:

- macOS 14 or later on Apple Silicon / arm64;
- Xcode 26.4;
- XcodeGen 2.45.4; and
- network access only when resolving source dependencies or downloading a
  selected runtime speech model for an explicit manual test.

Ordinary development and verification must not require Apple signing,
notarization, provider, or other private credentials. Automated tests must not
depend on a real network service, microphone, accessibility permission, or
runtime speech-model download.

## Test-driven workflow

Add or update a test that fails for the intended reason before changing
production code. Make the smallest change that passes, then refactor while the
tests remain green.

Run the narrowest relevant tests while iterating. For Swift package work, that
often begins with:

```bash
(
  swift_scratch="$(mktemp -d "${TMPDIR:-/tmp}/utterink-swift.XXXXXX")"
  trap 'rm -rf "$swift_scratch"' EXIT
  swift test \
    --package-path Packages/UtterInkKit \
    --scratch-path "$swift_scratch" \
    --disable-sandbox \
    --force-resolved-versions
)
```

Before opening or updating a pull request, run the complete zero-argument local
verification from the repository root:

```bash
./Scripts/ci-local.sh
```

The complete script includes repository hygiene, source and package checks,
deterministic project generation, unsigned builds, unit tests, and directed UI
smoke tests. A focused test run does not replace this command. Record the
failing test observed before implementation, the focused commands run during
development, the final complete verification result, and any manual checks in
the pull request.

## Privacy-safe tests and fixtures

Tests and fixtures must use synthetic, non-personal content. Prefer temporary
directories, deterministic fakes, injected clocks and ordering, and custom URL
protocol handlers over global state or real services.

Do not commit or attach:

- real dictation audio, transcripts, clipboard contents, or history data;
- API keys, access tokens, passwords, private keys, certificates, signing
  material, or Keychain exports;
- provider URLs containing private paths, query data, or credentials;
- usernames, private home-directory paths, local file URLs, or unrelated
  diagnostics; or
- fixtures that require a real provider, network request, microphone capture,
  or user credential.

Use neutral placeholders that cannot be mistaken for working credentials.
Diagnostics and screenshots must be reviewed and reduced to the smallest
sanitized evidence needed to explain the behavior. Tests of privacy-sensitive
flows should also prove failure safety, cleanup behavior, retention boundaries,
and that unexpected content is excluded from diagnostics.

## Dependencies and license review

UtterInk accepts third-party source dependencies through Swift Package Manager
only. Do not add another package manager or copy a dependency's source into a
vendor tree.

For every dependency change:

1. Explain why the dependency is necessary and identify its authoritative
   source.
2. Pin and review the intended version or immutable revision in the relevant
   `Package.swift` file.
3. Commit and review the resulting
   `Packages/UtterInkKit/Package.resolved` change.
4. Determine whether the dependency ships in the app, is used only for
   development, or is downloaded at runtime.
5. Review its license, notices, redistribution terms, and transitive
   obligations.
6. Update [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and any required
   notice material.
7. Verify the notice inventory:

   ```bash
   (
     notice_scratch="$(mktemp -d "${TMPDIR:-/tmp}/utterink-notices.XXXXXX")"
     trap 'rm -rf "$notice_scratch"' EXIT
     UTTERINK_NOTICE_SCRATCH_PATH="$notice_scratch" ./Scripts/collect-third-party-notices.sh --check
   )
   ```

By checking the dependency-license item in the pull request, you confirm that
you reviewed the dependency's license and notice obligations, that the proposed
distribution is compatible with Apache-2.0, and that every required attribution
is included. Maintainer review is still required.

## Deterministic project and identity assets

`project.yml` is the source of truth for the generated Xcode project. Change the
declarative source, run `xcodegen generate`, and review the complete generated
diff. Do not make a standalone hand edit to generated project output.

Identity assets must be regenerated from the approved vector sources and lock
data under `Brand/`. Do not extract or hand-edit raster identity outputs. Run:

```bash
(
  swift_scratch="$(mktemp -d "${TMPDIR:-/tmp}/utterink-swift.XXXXXX")"
  trap 'rm -rf "$swift_scratch"' EXIT
  swift run \
    --package-path Packages/UtterInkKit \
    --scratch-path "$swift_scratch" \
    --disable-sandbox \
    --force-resolved-versions \
    UtterInkIdentityExporter \
    --check \
    --lock Brand/identity-lock.json \
    --asset-catalog App/Resources/Assets.xcassets
)
```

Visual-identity changes require prior design discussion and explicit owner
approval. The source license does not grant rights in the UtterInk marks; review
the [trademark policy](TRADEMARKS.md) before changing or redistributing identity
assets.

## Accessibility review

For every user-interface change, review and test the affected path for:

- accurate VoiceOver names, roles, values, hints, and actions;
- complete keyboard traversal, a visible focus indicator, no keyboard trap,
  and predictable focus return after a sheet, popover, or dialog closes;
- meaningful labels for icon-only controls and status that is not conveyed by
  color alone;
- legibility in light and dark appearances, high contrast, Increase Contrast,
  and Differentiate Without Color;
- Reduce Motion behavior; and
- larger text, localization expansion, and the absence of clipping or hidden
  controls.

Update the [accessibility matrix](docs/parity/accessibility-matrix.md) when a
change affects a covered surface. Record automated and manual evidence
separately, and do not mark a manual check as passed unless it was actually run.
Review every localization shipped by the changed interface.

## Pull request checklist

Before requesting review, confirm that the pull request:

- links the relevant issue or design discussion for a behavior-changing
  proposal;
- shows the intended failing test before the implementation and the passing
  evidence afterward;
- passes `./Scripts/ci-local.sh` from a clean repository root;
- contains only synthetic, sanitized fixtures and attachments;
- explains any privacy, security, permission, history, clipboard, Keychain,
  diagnostics, or network-boundary effect;
- records the required accessibility review and updates the accessibility
  matrix when applicable;
- regenerates and reviews deterministic XcodeGen and identity outputs;
- includes the dependency and license compatibility signoff, or clearly marks
  it not applicable; and
- updates user-facing documentation and [CHANGELOG.md](CHANGELOG.md) when the
  change is notable.

## Contribution license

Unless explicitly stated otherwise, a contribution intentionally submitted for
inclusion is provided under Apache-2.0 as described in Section 5 of
[LICENSE](LICENSE). Submit only material you have the right to contribute,
preserve applicable notices, and follow [TRADEMARKS.md](TRADEMARKS.md).
