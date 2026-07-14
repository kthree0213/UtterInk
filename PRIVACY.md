# UtterInk Privacy

UtterInk is a local-first macOS dictation app. Speech recognition runs on this Mac with Whisper. UtterInk has no analytics service, does not automatically upload diagnostics, and does not provide cloud sync. Optional text polishing is the only feature that sends transcript content to a user-configured provider.

This document describes the current source release. It does not claim that ordinary filesystem deletion is forensic secure erasure.

## Data inventory

| Data | Why it exists | Where it goes | Retention and controls |
| --- | --- | --- | --- |
| Transient audio (`.caf`) | Records the active dictation for local transcription. | A private, user-only, backup-excluded UtterInk directory on this Mac, then local Whisper. Audio is never sent to a polishing provider. | Deleted through the common session cleanup path after success, failure, or cancellation. UtterInk also sweeps orphan files at launch and before a new capture. There is no audio history or audio-based recovery. A crash, power loss, APFS snapshot, or storage behavior can leave recoverable blocks until a later sweep or system reuse; normal deletion is not guaranteed secure erasure. |
| Raw and final transcript history | Makes recent results recoverable. | A versioned local JSON store in UtterInk's Application Support directory. | History is enabled by default and retains the newest 20 non-empty original sessions. A record can include a random session ID, start time, raw text, final/polished text when available, source, delivery outcome, and sanitized warning/outcome codes. It does not include audio, provider credentials, polishing instructions, target app identity, full provider URL, model files, or diagnostic logs. Atomic storage may temporarily use local journal, temporary, or backup files. |
| Volatile transcript results | Preserves results during the current app process when persistent History is off or storage cannot safely advance. | Process memory only. | Up to 20 results; they disappear when UtterInk quits. They can be copied or cleared while the process is running. |
| Provider profile settings | Lets the user select an optional OpenAI-compatible endpoint and model. | Stored locally in UtterInk settings. | The profile name, endpoint/base URL, model identifier, and non-secret settings remain until changed or the profile is deleted. Credentials are handled separately in Keychain. |
| Optional polishing request | Rewrites a transcript only when a polishing output mode is selected. | Sent to the exact user-configured provider endpoint. The UI displays the normalized destination host before use. | The request can contain the raw transcript, resolved polishing instructions, selected model identifier, an Authorization credential, and ordinary network metadata. Audio is not included. Raw mode makes no transcript-polishing request, but model downloads and an explicit provider connection test are separate network operations. |
| Provider credential | Authenticates an optional provider request. | Persisted as a generic-password item in macOS Keychain. During a request, an in-memory session copy is placed only in the Authorization header sent to the configured provider. | New credentials are not placed in History, diagnostics, UserDefaults, URLs, or logs. An audited legacy plaintext setting can remain temporarily when migration cannot complete, but it is blocked from runtime use. Session memory is cleared and released during cleanup. Keychain deletion and legacy migration can fail and are reported rather than treated as completed. UtterInk does not claim cryptographic erasure of process memory. |
| Whisper model and tokenizer downloads | Enables local transcription. | Downloaded from the pinned model repositories into UtterInk's local Application Support cache. The model host receives the requested model identifiers and ordinary network metadata, not microphone audio or transcript text. | Cached across launches. A user can request deletion only when a model is neither selected nor preparing, loaded, or leased by an active operation. Cancellation does not promise that every partial or old-revision cache artifact has already been removed. Model caches are not transcript history. |
| Automatic-paste snapshot | Allows UtterInk to attempt restoration of the user's previous pasteboard after a guarded automatic paste. | Process memory only; UtterInk does not deliberately write it to History, app-managed diagnostics, or logs. | UtterInk materializes only a complete readable snapshot, bounded to 16 MiB and 500 ms. It attempts restoration only while it owns the pasteboard change count; the platform restore can still fail. Change-count checks avoid overwriting a copy already visible at each check, but `NSPasteboard` has no atomic compare-and-write or compare-and-restore operation, so a copy in either small check/action interval can still be overwritten. **Copy** and **Copy Only** intentionally leave the transcript on the pasteboard and do not restore the old value. Memory disposal is not claimed as secure erasure. |
| Diagnostics | Helps a user inspect or report a problem without exporting content. | A local preview and a user-initiated local JSON export. UtterInk does not automatically upload it. | The allowlist is limited to app/build and OS/architecture information; microphone and Accessibility states; model identifier/state without a filesystem path; normalized provider host and model without a credential, path, query, header, or body; sanitized pipeline stages/status codes; and History enabled/count without History content. Transcript text, audio, credentials, instructions, pasteboard contents, target/window titles, raw errors, response bodies, and full URLs are excluded. |
| Local system logs | Records bounded operational stages and sanitized codes. | Apple's local unified logging system. | Log calls use static messages and allowlisted typed fields. They exclude transcripts, audio, credentials, instructions, pasteboard contents, raw errors, response bodies, and full URLs. UtterInk does not claim that it produces no local logs. |

## History controls

History provides text recovery; it is not analytics.

- **Turn off History:** immediately prevents new and already in-flight operations from creating or updating persistent History. Existing saved records are not silently deleted. New completed results can remain in process memory until quit.
- **Clear History:** asks for confirmation, cancels the active dictation if one exists, removes persistent History and completed volatile results, and invalidates stale in-flight writes so they cannot restore cleared data.
- **Delete one item:** immediately removes the result from the current UI, asks the local store to delete it, and prevents a matching in-flight operation from resurrecting it. If persistent deletion fails, the current UI does not surface that failure or restore the row; UtterInk records a sanitized local diagnostic, and the item can reappear after relaunch.

Storage or permission failures can prevent deletion. Clear History reports its failure; the per-item limitation is described above. Neither control promises that data was removed when its storage operation fails. Clear and per-item delete use ordinary filesystem deletion; APFS, backups, snapshots, SSD behavior, and forensic recovery are outside UtterInk's secure-erasure guarantees.

Turning History off is different from clearing it. To remove previously saved transcript records, use **Clear History** or delete individual items.

## Network boundaries

UtterInk performs local speech recognition. Network access can occur in these separate situations:

1. Downloading a selected Whisper model and tokenizer.
2. Running a user-requested provider connection test. The test can authenticate to the configured provider but does not send transcript text.
3. Sending transcript text for optional polishing after the user selects a polishing output mode.

Remote provider endpoints require HTTPS. Plain HTTP is accepted only for an explicitly configured canonical loopback endpoint on the same Mac (`localhost`, a dotted-decimal address in `127.0.0.0/8`, or `::1`). UtterInk rejects plain-HTTP LAN and public hosts, cross-origin credential forwarding, and redirects that violate the original transport policy.

Provider requests use an ephemeral URL session without a persistent URL cache, shared cookie store, or shared credential store. The third-party provider and model host operate under their own terms and privacy practices; UtterInk cannot control their server-side retention.

## Pasteboard and target information

Before automatic paste, UtterInk checks the intended external process and focused editable element. Target information and transient window titles are used at runtime and are not persisted in History or diagnostics.

If UtterInk cannot capture a complete bounded pasteboard snapshot, revalidate the exact target, or safely dispatch the paste event, it does not perform that automatic paste and leaves the result available for an explicit Copy. A dispatched Command-V event does not prove that every target application accepted the text.

## Permissions

- **Microphone** is required to record audio for local transcription.
- **Accessibility** is used for exact-target validation and guarded automatic paste. Local transcription and explicit Copy remain available without it.

The current app uses Hardened Runtime and user-only permissions for its private data directories. These protections are not substitutes for the controls and limitations described above.

## Backups and sync

UtterInk provides no cloud sync for History or settings. The transient-audio directory is marked backup-excluded. Other local settings, History transaction files, and model caches live under normal application storage and may be handled by macOS or user-configured backup software according to those systems' policies.

## Sensitive reports

For a sensitive privacy or security report, email [swallowclever.k3@gmail.com](mailto:swallowclever.k3@gmail.com) with only the smallest sanitized proof needed. Do not send live credentials, real transcripts, audio, pasteboard contents, or unrelated personal data by email, and do not put sensitive evidence in a public issue.

For the ordered processing and delivery path, see [Privacy data flow](docs/privacy-data-flow.md).
