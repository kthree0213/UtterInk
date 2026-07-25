# UtterInk 0.1.0

UtterInk is a privacy-minded macOS menu-bar dictation app. Version 0.1.0 is
the first public release. A copy of these notes in the source tree does not by
itself prove that a binary has been published; use the GitHub Release page and
its checksums as the distribution record.

## Highlights

- Local Whisper transcription with no audio history or provider audio upload.
- Right Option as the default dictation shortcut, with custom shortcut,
  Toggle, and Hold to Talk options.
- Guarded Automatic Paste, Copy Only, and text-only recovery for the newest 20
  sessions.
- Simple provider setup that tests the API key, loads compatible models, and
  stores the selected credential in macOS Keychain.
- Raw output plus Clean Up, AI Prompt, Translate to English, Work Message,
  Classical Chinese, and user-created polishing modes.

## Requirements

- macOS 14 or later.
- Apple Silicon (arm64) only.
- An internet connection is required the first time a selected Whisper model
  and tokenizer are downloaded. The model remains cached locally afterward.

## Privacy and data handling

Recording audio is held in a short-lived local file and transcription is
performed locally on this Mac. Audio is not stored in History and is never
sent to an optional text-polishing provider. Normal filesystem deletion is
best-effort cleanup and does not guarantee secure erasure.

Raw mode sends no transcript text to a provider. If the user explicitly
configures and selects optional OpenAI-compatible text polishing, UtterInk
sends transcript text, the selected model ID, saved instructions, and any
configured authorization credential to the host shown in Settings. That
provider and the network remain subject to their own privacy and retention
policies.

## Updates

UtterInk 0.1.0 has no automatic updater. Install future versions manually
after reviewing their release notes and checksums.

## Known limitations

- The interface is English-only and speech recognition is Automatic or fixed
  English.
- Live and streaming transcription are not supported; transcription begins
  after recording stops.
- There is no cloud sync, no bundled API key, and no Intel Mac build.
- Whisper model downloads are large, remain cached until manually deleted,
  and have no automatic eviction.
- Clipboard restoration and ordinary filesystem deletion are best-effort
  platform operations; the recoverable text result is retained when guarded
  delivery cannot finish safely.

## Verify checksums

Keep all five release assets in one directory. From that directory, inspect
`SHA256SUMS`, then verify the four content files it lists:

```bash
shasum -a 256 -c SHA256SUMS
```

Every line uses a lowercase SHA-256 digest followed by exactly two spaces and
the asset filename. Stop if any file is missing, unexpected, or reports a
checksum mismatch.
