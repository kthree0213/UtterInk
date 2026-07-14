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
- Toggle and Hold to Talk shortcut modes.
- Local Whisper speech recognition through WhisperKit, with `base`, `small`, and `large-v3` model choices.
- Raw output by default, plus optional custom polishing instructions.
- Automatic Paste with guarded clipboard restoration, or Copy Only delivery.
- Per-session recovery, Copy, Paste Again, Delete, and Clear History controls.
- Automatic or fixed English speech-recognition language selection.

## Requirements

- macOS 14+
- Apple Silicon / arm64 only
- Xcode 26.4 and XcodeGen 2.45.4 for the documented source workflow
- An internet connection for the first runtime download of a selected speech model and tokenizer

Speech weights are not included in the repository or app. They are downloaded from pinned Hugging Face revisions and cached under `~/Library/Application Support/UtterInk/huggingface`. Catalog sizes are approximately 149 MB for `base`, 489 MB for `small`, and 3.1 GB for `large-v3`; Settings can delete a cached model only while it is not selected, preparing, loaded, or leased by an active operation.

## Build from Source

Generate the Xcode project, then build an unsigned arm64 Debug app:

```bash
xcodegen generate
xcodebuild \
  -project UtterInk.xcodeproj \
  -scheme UtterInk \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

You can also open `UtterInk.xcodeproj` and run the `UtterInk` scheme from Xcode. On first launch, choose and download a speech model in onboarding or Settings.

## Test

Run the Swift package tests:

```bash
swift test --package-path Packages/UtterInkKit
```

Run the app unit tests without UI automation:

```bash
xcodegen generate
xcodebuild \
  -project UtterInk.xcodeproj \
  -scheme UtterInk \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO \
  test \
  -only-testing:UtterInkAppTests
```

Run the repository's complete local verification, including directed UI smoke tests:

```bash
./Scripts/ci-local.sh
```

## Unsigned Package

The source command above produces an unsigned development build. It is not notarized or intended for redistribution, and this pre-release repository does not currently publish an installable package. Build and run from Xcode for local development.

## Optional Provider Setup

Raw mode is the default and works without a provider or credential. To enable custom text polishing:

1. Open **Settings → Providers** and add an OpenAI-compatible profile.
2. Enter the base URL, model ID, and API key. Remote hosts require HTTPS; plain HTTP is accepted only for an explicitly selected canonical loopback host on the same Mac.
3. Review the normalized host shown by UtterInk and use **Test Connection**. This performs `GET /models`, uses the profile credential when one is configured, and sends no transcript.
4. Create or select a custom output mode with saved polish instructions.

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
- This is pre-release source. No installable package is currently published.

## Contributing and Security

Before contributing, read [Contributing](CONTRIBUTING.md), the [Code of Conduct](CODE_OF_CONDUCT.md), and the [trademark policy](TRADEMARKS.md).

Report suspected vulnerabilities privately to `swallowclever.k3@gmail.com` and follow [Security](SECURITY.md). Do not include credentials, transcripts, or other sensitive data in a public issue. The same address is the approved Code of Conduct enforcement contact.

## License

UtterInk source code is licensed under [Apache-2.0](LICENSE), copyright 2026 kthree0213. The source license does not grant rights to the UtterInk name, logo, icon, or other brand identifiers; see [TRADEMARKS.md](TRADEMARKS.md).

Dependency licenses and runtime-downloaded model notices are recorded in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Redistribution must preserve the applicable [NOTICE](NOTICE) material.
