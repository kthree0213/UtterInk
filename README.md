# UtterInk

UtterInk is a privacy-minded macOS menu-bar dictation app that turns speech into locally transcribed text and safely delivers it where you are writing.

[简体中文](README.zh-CN.md)

## Identity

![UtterInk wordmark](Brand/wordmark-lockup.svg)

_Brand identity artwork — not a product screenshot._

## Privacy Summary

- **Local Whisper transcription.** UtterInk records a short-lived local CAF for the active session and transcribes it on this Mac with WhisperKit after you stop recording.
- **No audio retention.** Audio is not stored in history or sent to a text-polishing provider. The common cleanup path deletes the temporary file, and launch and pre-capture sweeps remove crash or power-loss orphans. Normal APFS deletion is best-effort cleanup, not guaranteed secure erasure.
- **Text-only 20-session history.** History is on by default and keeps at most 20 text-only sessions, including raw and final text, under `~/Library/Application Support/UtterInk`.
- **Optional text egress.** Raw mode uses no text provider. Optional OpenAI-compatible text polishing sends the selected model ID, saved polish instructions, raw transcript text, and, when configured, an authorization credential to the host shown in Settings; it never sends audio.
- **Protected credentials.** Current provider API keys are stored per profile in macOS Keychain rather than normal settings or history. A failed legacy plaintext migration is blocked and surfaced instead of being treated as complete.
- **Local product data.** The current source has no analytics or tracking SDK and no cloud sync. Diagnostics contain only allowlisted operational fields and are exported only after you preview them and choose a save location.

See [Privacy](PRIVACY.md) and the [privacy data flow](docs/privacy-data-flow.md) for the complete boundaries and deletion caveats.

## Features

- Menu-bar controls plus an optional floating recorder.
- Right Option as the default recorder shortcut, plus configurable custom shortcuts and Toggle or Hold to Talk behavior.
- Local Whisper speech recognition through WhisperKit, with `base`, `small`, and `large-v3` model choices.
- Raw output by default, five built-in polishing modes, and optional custom polishing instructions.
- Automatic Paste with guarded clipboard restoration, or Copy Only delivery.
- Per-session recovery, Copy, Paste Again, Delete, and Clear History controls.
- Automatic or fixed English speech-recognition language selection.

## Requirements

- macOS 14+
- Apple Silicon / arm64 only
- Xcode 26.4.1 build 17E202, Apple Swift 6.3.1, and XcodeGen 2.45.4 for the documented source workflow
- An internet connection for the first runtime download of a selected speech model and tokenizer

Speech weights are not included in the repository or app. They are downloaded from pinned Hugging Face revisions and cached under `~/Library/Application Support/UtterInk/huggingface`. Catalog sizes are approximately 149 MB for `base`, 489 MB for `small`, and 3.1 GB for `large-v3`; Settings can delete a cached model only while it is not selected, preparing, loaded, or leased by an active operation.

## Install a Release

Signed and notarized builds are distributed only through the project's
[GitHub Releases](https://github.com/kthree0213/UtterInk/releases) page. If that
page does not show a DMG asset, no installable release has been published yet;
use the source workflow below instead.

For a published release, download the DMG together with `SHA256SUMS`, verify the
checksum as described in the release notes, open the DMG, and drag UtterInk to
Applications. Speech models are downloaded separately on first use and are not
bundled in the DMG.

## Build from Source

Use XcodeGen 2.45.4, generate the project, and keep build products outside the
checkout. The subshell preserves a failed build status while still removing
its scratch directory:

```bash
(
  set -e
  test "$(xcodegen --version | sed 's/^Version: //')" = '2.45.4'
  xcodegen generate
  BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/utterink-readme-build.XXXXXX")"
  trap 'status=$?; trap - EXIT; rm -rf -- "$BUILD_ROOT" || status=$?; exit "$status"' EXIT
  xcodebuild \
    -project UtterInk.xcodeproj \
    -scheme UtterInk \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$BUILD_ROOT/DerivedData" \
    -clonedSourcePackagesDirPath "$BUILD_ROOT/SourcePackages" \
    CODE_SIGNING_ALLOWED=NO \
    build
)
```

You can also open `UtterInk.xcodeproj` and run the `UtterInk` scheme from Xcode. On first launch, choose and download a speech model in onboarding or Settings.

## Test

Run the Swift package tests:

```bash
(
  set -e
  PACKAGE_TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/utterink-package-test.XXXXXX")"
  trap 'status=$?; trap - EXIT; rm -rf -- "$PACKAGE_TEST_ROOT" || status=$?; exit "$status"' EXIT
  swift test \
    --package-path Packages/UtterInkKit \
    --scratch-path "$PACKAGE_TEST_ROOT/UtterInkKit-build" \
    --disable-sandbox \
    --force-resolved-versions
)
```

Run the app unit tests without UI automation:

```bash
(
  set -e
  test "$(xcodegen --version | sed 's/^Version: //')" = '2.45.4'
  xcodegen generate
  APP_TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/utterink-app-test.XXXXXX")"
  trap 'status=$?; trap - EXIT; rm -rf -- "$APP_TEST_ROOT" || status=$?; exit "$status"' EXIT
  xcodebuild \
    -project UtterInk.xcodeproj \
    -scheme UtterInk \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$APP_TEST_ROOT/DerivedData" \
    -clonedSourcePackagesDirPath "$APP_TEST_ROOT/SourcePackages" \
    -parallel-testing-enabled NO \
    CODE_SIGNING_ALLOWED=NO \
    test \
    -only-testing:UtterInkAppTests
)
```

Run the repository's complete local verification, including directed UI smoke tests:

```bash
./Scripts/ci-local.sh
```

## Unsigned Package

The source command above produces an unsigned development build. It is not
notarized or intended for redistribution. Official signed builds, when
available, are published only on the GitHub Releases page linked above.

The fail-closed packaging path below requires the reviewed
`Config/ci-toolchain.json` lock, which is committed with its reviewed source
identities and hashes. Contributors can run the same verification path without
Apple credentials; any toolchain or generated-project drift fails closed:

```bash
(
  set -e
  trap 'status=$?; trap - EXIT; ./Scripts/clean-distribution-output.sh || status=$?; exit "$status"' EXIT
  ./Scripts/bootstrap-xcodegen.sh
  UTTERINK_EXPECTED_ORIGIN='https://github.com/kthree0213/UtterInk.git' \
    ./Scripts/ci-local.sh --unsigned-package-smoke
)
```

Keep the expected origin byte-for-byte identical to the separately reviewed
canonical `origin`; if the checkout intentionally has no remote, omit
`UTTERINK_EXPECTED_ORIGIN`.
Any output is named `UNSIGNED-DO-NOT-DISTRIBUTE`, must remain local, and is
removed by the exit cleanup. Signing, notarization, final verification, and
publication are separate maintainer phases documented in
[Releasing](docs/RELEASING.md); none is authorized by running these commands.

## Optional Provider Setup

Raw mode is the default and works without a provider or credential. To enable custom text polishing:

1. Open **Settings → Provider** and select a provider template. Choose **Custom** only when you need to enter your own OpenAI-compatible base URL.
2. Enter the API key, review the normalized destination host shown by UtterInk, and choose **Test Key & Load Models**. Remote hosts require HTTPS; plain HTTP is accepted only for an explicitly selected canonical loopback host on the same Mac.
3. Select one of the compatible models returned by the provider, then choose **Save & Use**. The API key is stored in macOS Keychain; it is not placed in ordinary settings, History, or diagnostics.
4. Open **Settings → Output Modes** and select **Clean Up**, **AI Prompt**, **Translate to English**, **Work Message**, **Classical Chinese**, or a custom mode. Keep **Raw** selected when no text should be sent to a provider.

For a polishing request, UtterInk sends the model ID, saved instructions, and raw transcript in a `POST /chat/completions` request. When the profile has an API key, it is sent as a Bearer credential. Audio is never sent. The provider and network remain subject to their own privacy and retention policies.

## History and Recovery

History is on by default. It stores the newest 20 raw/final text sessions locally in `history-v1.json`; it never stores audio. When history is enabled, UtterInk saves the raw transcript before optional remote polishing so a provider or delivery failure does not lose the original text.

Turning History off immediately blocks new persistent writes and invalidates History writes already in flight, but it does not delete entries already saved. Use per-session **Delete** or **Clear History** to remove them. Results created while History is off remain in memory only and disappear when UtterInk quits.

Automatic Paste temporarily holds an in-memory snapshot of the current pasteboard, capped at 16 MiB and a 0.5-second capture window. UtterInk attempts a guarded restore only if the pasteboard is unchanged; the platform restore can still fail, and the snapshot is not written to app storage. `NSPasteboard` has no atomic compare-and-write or compare-and-restore operation, so another copy in either small check/action interval can still be overwritten. Copy Only and explicit Copy intentionally replace the clipboard and do not restore it. If delivery cannot complete safely, the result remains available for recovery.

## Permissions

- **Microphone — required for recording.** Audio is used for local transcription.
- **Accessibility — optional.** It enables precise target validation and guarded Automatic Paste. Local transcription and explicit Copy remain available without it.

Permission state can be reviewed in Settings. UtterInk does not need Accessibility permission merely to transcribe locally.

## Current Limitations

- Apple Silicon / arm64 only.
- The interface is currently English; speech-recognition selection is Automatic or fixed English.
- No live or streaming transcription; transcription begins after recording stops.
- No automatic updates; update a source build manually.
- No cloud sync; settings and history remain local to this Mac.
- No bundled API keys; optional providers require a user-supplied credential, except an explicitly configured keyless loopback service.
- Model downloads are large, remain cached until deleted, and have no automatic eviction.
- Audio cleanup and history deletion use normal filesystem deletion and do not guarantee secure erasure.
- A per-item History deletion can disappear from the current UI even if its persistent deletion fails; the failure is recorded as a sanitized local diagnostic, and the item can reappear after relaunch.
- When the target or clipboard changes, Automatic Paste aborts or attempts the guarded recovery described above; the platform restore can still fail, while the text result remains recoverable from the latest result or history view.
- Installable builds, when available, are published manually on GitHub Releases; UtterInk has no automatic updater.

## Contributing and Security

Before contributing, read [Contributing](CONTRIBUTING.md), the [Code of Conduct](CODE_OF_CONDUCT.md), and the [trademark policy](TRADEMARKS.md).

Report suspected vulnerabilities privately to `swallowclever.k3@gmail.com` and follow [Security](SECURITY.md). Do not include credentials, transcripts, or other sensitive data in a public issue. The same address is the approved Code of Conduct enforcement contact.

## License

UtterInk source code is licensed under [Apache-2.0](LICENSE), copyright 2026 kthree0213. The source license does not grant rights to the UtterInk name, logo, icon, or other brand identifiers; see [TRADEMARKS.md](TRADEMARKS.md).

Dependency licenses and runtime-downloaded model notices are recorded in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Redistribution must preserve the applicable [NOTICE](NOTICE) material.
