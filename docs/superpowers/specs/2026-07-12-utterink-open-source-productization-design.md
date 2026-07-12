# UtterInk Open-Source Productization Design

- **Date:** 2026-07-12
- **Status:** Draft for written-spec review
- **Implementation authorization:** Not granted. No implementation begins until the user approves this file.

## 1. Purpose

UtterInk is the productized successor to the legacy FlowType macOS menu-bar dictation app. The first public release will provide dependable local speech transcription, optional user-configured text polishing, recoverable delivery, and a privacy-first native macOS experience.

This design defines the P0 product behavior, code boundaries, migration rules, verification strategy, identity direction, and release gates for an open-source `0.1.0` release. It deliberately separates design approval from implementation planning and from every external publication action.

## 2. Product principles

1. **Local dictation is the complete core product.** Recording and Whisper/WhisperKit transcription work without an API key or network text-polishing service.
2. **User text is recoverable before convenience features run.** A non-empty raw transcript is saved before polishing or paste delivery is attempted.
3. **One state authority governs each dictation.** UI surfaces issue intents and render state; they do not maintain competing recording flags.
4. **Privacy claims match observable behavior.** Audio is transient and local, text history is local and controllable, secrets live in Keychain, and the UI identifies any remote text destination.
5. **Failure degrades safely.** Polishing failure returns raw text, changed focus prevents blind paste, and clipboard restoration never overwrites a newer user copy.
6. **The public repository starts clean.** It imports only reviewed source files from the legacy working implementation and carries none of the legacy Git history, build products, secrets, or release artifacts.
7. **Distribution evidence precedes publication.** Signing, notarization, Gatekeeper, privacy, license, and clean-build results are reviewable before any public release.

## 3. Supported release and explicit non-goals

### 3.1 Initial support

- Product and executable name: **UtterInk**.
- Minimum OS: **macOS 14**.
- Architecture: **Apple Silicon (`arm64`)** only for `0.1.0`.
- Speech recognition: local Whisper through WhisperKit.
- Optional polishing: an OpenAI-compatible text provider, base endpoint, and model configured by the user.
- License: Apache-2.0.
- Distribution: open source plus a Developer ID-signed and Apple-notarized DMG.

### 3.2 Out of P0

- Live or streaming transcription.
- Multiple speech-engine backends.
- Cloud history or settings sync.
- Voice commands.
- Intel or Universal binaries.
- Sparkle or any automatic-update mechanism.
- Hosted API keys or a bundled paid AI service.
- Audio history or audio recovery after a session ends.

These are deferred, not silently partially supported. README and release notes must state the macOS and architecture boundary.

### 3.3 Decisions introduced by this written spec

The handoff fixes the product scope and major architecture. This document also makes the following lower-level choices so the implementation plan is unambiguous: two Swift package library targets, a versioned JSON history store, immediate privacy overrides for history disable/clear, an explicit loopback-only HTTP exception, English as the required P0 UI baseline, process-plus-focused-element validation for automatic paste, and a separate trademark-use document for the brand. These choices become approved only when the user approves this written spec; requested revisions are made before implementation planning.

## 4. Source-of-truth and repository bootstrap

The new repository root is `$HOME/Documents/Myprojects/UtterInk`. The legacy directory `$HOME/Documents/Myprojects/FlowType` is read-only input and must never be modified. The new repository receives a fresh Git history; the legacy `.git` directory and commits are never copied or connected.

Before legacy files are imported, implementation work will identify one legacy working-tree snapshot and create a reviewed, hash-based per-file import manifest. Each row records the relative legacy path, destination, content hash, file purpose, copyright/ownership basis, current license or relicensing authority, and reviewer. Unknown, private, or Apache-2.0-incompatible material blocks public visibility. Eligible inputs are Swift source, source-owned resources, tests, package metadata, and human-authored configuration whose content and publication rights have been reviewed. Required copyright and notice text is preserved. The standard Xcode app project, public documentation, CI, signing configuration, and packaging scripts are created cleanly in UtterInk rather than inherited wholesale.

The following are categorically excluded:

- `.git`, `.build`, `.swiftpm`, `dist`, `.DS_Store`.
- Local `.env` files and all credentials, tokens, certificates, provisioning material, or notarization profiles.
- Downloaded model caches and generated audio/transcript data.
- Generated DMGs, archives, derived data, and other build products.

The import is based on reviewed files, not on legacy `HEAD`, because the prior audit established that `HEAD` is older than the current working implementation. The staged allowlist is scanned for secrets, private data, and license conflicts before each import commit. The complete new Git object set and working tree—not merely the current checkout—are scanned again after every import tranche, before first push, and before public visibility.

The new repository must have no legacy parents, tags, branches, remotes, alternates, grafts, or replace refs. If a credential or private file ever enters the unpublished history, the safe response is to discard and reinitialize that unpublished repository rather than hide it in a later commit. `.gitignore` coverage is verified by running build and packaging smoke commands and confirming the tree remains clean.

## 5. Repository and runtime architecture

### 5.1 Top-level ownership

A standard Xcode macOS application target owns:

- `App` lifecycle and dependency composition.
- Menu-bar item, windows, onboarding, settings, history, and floating UI.
- `Info.plist`, asset catalogs, entitlements, build settings, signing, and packaging.
- Registration of global hotkeys and adaptation of platform events into domain intents.

A local Swift package owns:

- Dictation domain models and the authoritative state machine.
- The pipeline coordinator and service protocols.
- Audio capture, model management, transcription, polishing, delivery, history, Keychain, diagnostics, and non-secret settings adapters.
- Unit and integration tests, including test doubles.

All third-party dependencies remain managed through Swift Package Manager. P0 introduces no alternate package manager or copied/vendor dependency tree, and `Package.resolved` is committed and reviewed.

The intended package targets are:

| Target | Responsibility | Important dependency rule |
|---|---|---|
| `UtterInkCore` | Pure state, session snapshots, intents, error codes, coordinator contracts | No SwiftUI or app lifecycle dependency |
| `UtterInkServices` | macOS/WhisperKit/URLSession/Keychain/pasteboard/file-backed implementations | Depends on `UtterInkCore`; WhisperKit is contained here |
| `UtterInkCoreTests` | State-machine and orchestration tests | Uses deterministic fakes, no real network or microphone |
| `UtterInkServicesTests` | Adapter and integration tests | Uses temporary stores and injectable platform facades |

The Xcode app target depends on both package library targets and acts as the composition root. This keeps UI replaceable and prevents AppKit, SwiftUI, WhisperKit, networking, and persistence details from becoming state authorities.

### 5.2 One coordinator and one active session

`DictationSessionController` is the only owner of the active dictation state and active session task. It is main-actor isolated for deterministic UI observation and rejects a duplicate start with no state change and no second task. Long-running services perform their own work asynchronously, but all domain transitions return through the controller and are validated by a pure state reducer.

Every effect request and completion carries both the active session ID and a monotonically increasing effect generation. A completion that does not match the current pair is discarded, so a canceled transcription, permission response, or provider request cannot mutate a later session that happens to be in the same stage. A new session cannot start until the prior session reaches an idempotent cleanup barrier.

The menu item, global hotkey, floating recorder, onboarding test, and history actions send typed intents such as start, stop, cancel, copy result, or deliver again. They never directly start or stop the recorder and never infer state from separate booleans.

The speech-model lifecycle is independent of the dictation lifecycle. Downloading or loading a model cannot masquerade as recording, and a failed model remains explicitly retryable.

The controller's observable aggregate is `pipelineState + speechModelState + volatileResults`, not a collection of recording booleans. `volatileResults` keeps recoverable in-memory text keyed by session ID, including results made while persistent history is disabled; it is cleared on quit and never written implicitly.

A separate `DeliveryCoordinator` actor grants one lease covering pasteboard capture through guarded restoration. Current-session delivery, last-result delivery, and History **Paste again** all use this lease, so clipboard transactions cannot overlap or restore one another's snapshots.

## 6. Domain state and session snapshot

### 6.1 Dictation state

The authoritative high-level sequence is:

`idle -> requestingPermission -> recording -> stopping -> transcribing -> polishing? -> delivering -> completed | failed`

State carries the data needed to render the current stage rather than requiring parallel flags. A state may include a session identifier, elapsed time, safe progress data, a recoverable result reference, a warning, or a sanitized error code. Transcript text is not included in logs or diagnostics merely because it exists in UI state.

Allowed control behavior:

| Current stage | Primary intent | Cancel/Escape behavior | Failure outcome |
|---|---|---|---|
| `idle` | Start creates one session snapshot | No-op | N/A |
| `requestingPermission` | Continue after required permission result | Invalidate the session and return to `idle`; ignore any later permission callback | `failed(permission.*)` with guidance |
| `recording` | Stop finalizes audio | Stop capture, clean transient audio, and return to `idle` without transcription | `failed(audio.*)` |
| `stopping` | Await finalized audio | Invalidate pending work, clean transient audio, and return to `idle` | `failed(audio.finalize)` |
| `transcribing` | Produce raw text | Invalidate transcription, clean transient audio, and return to `idle`; no retry is promised because audio is not retained | `failed(transcription.*)` |
| `polishing` | Produce polished text | Stop all downstream automation; keep saved raw text as a recoverable canceled result | Raw-text fallback plus warning |
| `delivering` | Complete safe paste/copy | If dispatch has not occurred, stop it; always run guarded pasteboard cleanup once and keep the result | Recoverable result plus warning |
| `completed` / `failed` | Acknowledge or start a new session after cleanup | Dismiss to `idle` | N/A |

`cancelSession` never means “skip this step and continue automatically.” Before raw text exists it cleans up and returns to `idle`; after raw text exists it cancels all later effects, performs no automatic paste, and reaches `completed` with a canceled outcome plus a recoverable result. A separate explicit **Use Raw and Deliver** intent may skip polishing.

Terminal state remains until a deterministic acknowledgement or the user starts a new session after cleanup; it does not disappear on an arbitrary timer. Invalid transitions are rejected and tested. Cleanup is idempotent, runs exactly once on success, failure, and cancellation, and reaches a barrier before another session can start.

### 6.2 Speech-model state

Speech-model state is one of:

- `missing(selectedModel)`
- `downloading(selectedModel, progress)`
- `loading(selectedModel)`
- `ready(selectedModel)`
- `failed(selectedModel, sanitizedError, retryable)`

Only `ready` permits creation of an active dictation session. A start intent in `missing`, `downloading`, `loading`, or `failed` routes to the separate model readiness/retry flow; it does not capture a stale target or auto-resume later. Once the model is ready, the user starts again and a fresh target snapshot is taken.

The default model UI exposes **Recommended**, **Fast**, and **Best Quality** choices backed by concrete WhisperKit model identifiers verified on macOS 14 Apple Silicon. The complete compatible model list remains available under **Advanced**. The UI shows download/load progress and disk impact rather than exposing an unexplained catalog first.

### 6.3 Immutable session snapshot

At start, the controller captures one immutable snapshot containing:

- Session ID and start time.
- Delivery target kind: external focused target, internal onboarding test target, or copy-only.
- For an external target, application process identity plus non-persisted Accessibility focused-window and focused-element identity when available.
- Recognition language.
- Selected speech model identifier.
- Resolved output mode, including its polishing instructions.
- Selected provider profile, endpoint policy, and model identifier when polishing is enabled.
- History generation, history-enabled value, and delivery preference.

Changing ordinary settings during recording affects only the next session. History disable and clear are immediate privacy overrides: they increment the store generation so older in-flight writes cannot persist or recreate deleted data.

When polishing is selected, the controller resolves the Keychain item at session start into a non-codable, non-printable in-memory secret wrapper tied to the session. This prevents a mid-session Keychain edit from changing the immutable configuration. The wrapper is released during terminal cleanup and never enters history, diagnostics, logs, crash metadata, or the snapshot's debug representation. If the credential cannot be resolved, the session remains usable in raw mode.

For hotkey starts, the target is the current eligible frontmost application and focused editable element. For starts from UtterInk UI, a target tracker uses the last eligible non-UtterInk focus and records any intervening app, window, or focused-element change. If focused-element identity cannot be captured and revalidated, the target becomes copy-only instead of receiving an automatic paste. The internal onboarding test uses an explicit in-app destination rather than a fabricated external process. Target details and transient window titles are never persisted.

## 7. End-to-end dictation flow

1. A UI surface sends `start`.
2. The controller confirms there is no active session and cleanup barrier outstanding, then checks the separate speech-model state. A non-ready model routes to readiness without creating a dictation session.
3. With a ready model, the controller captures the immutable snapshot and enters `requestingPermission`. Microphone is required for recording; missing Accessibility disables global control/automatic paste but does not disable local transcription.
4. Audio capture starts and the domain enters `recording`.
5. Stop enters `stopping`; successful finalization of transient audio then enters `transcribing`.
6. WhisperKit transcribes locally using the snapshotted language and model.
7. Empty or whitespace-only text produces a recoverable transcription error and is not stored as a history item.
8. A non-empty raw transcript first enters `volatileResults`, then is written to the local history store **before** any remote request or pasteboard change. When history is enabled, the write and matching history generation must succeed before the pipeline advances. On storage failure, automatic polishing and delivery stop; raw text remains recoverable in memory and the UI offers an explicit Copy. When history is disabled, no persistent write occurs and the result remains in process memory for recovery.
9. Raw mode skips networking. A polishing mode sends only the raw text and resolved instructions to the snapshotted provider. Audio never leaves the Mac.
10. A successful polish updates the existing history record with polished/final text before automatic delivery when history is enabled. If that update fails, the saved raw record remains authoritative, polished text stays only in memory, automation stops, and the UI offers explicit Copy or raw fallback. Provider failure, invalid output, or timeout selects the saved raw transcript and attaches a visible warning; it does not fail the entire dictation.
11. Delivery follows the safe-paste algorithm. A focus or clipboard safety failure turns automatic paste into an explicit recoverable copy/manual-paste path.
12. The session reaches `completed` with its delivery outcome, or `failed` with a sanitized error and any recoverable result.
13. Transient audio is deleted in a common cleanup path regardless of outcome. Session audio uses opaque names in a user-only, backup-excluded temporary directory; launch and pre-capture sweeps remove orphan files left by a crash or power loss. The product does not claim APFS deletion is secure erasure.

There is never an automatic retranscription after cleanup because P0 intentionally retains no audio. Recovery labels are specific: **Retry polishing**, **Paste again**, and **Copy**, rather than a generic Retry that implies audio still exists.

## 8. Local history and recovery

History is enabled by default and retains the newest 20 non-empty sessions. It is a local, text-only recovery feature, not an analytics store. The record contains only:

- Random session ID and timestamps.
- Raw transcript.
- Polished/final text when one exists.
- Outcome and sanitized warning/error codes needed to explain recovery state.

Target app identity, provider secret, full endpoint URL, prompt text, audio, model files, and diagnostic logs are not persisted in history.

For P0, `HistoryStore` uses a versioned Codable JSON envelope inside UtterInk's Application Support directory. UtterInk enforces a single app process; writes serialize through one store actor. The directory, temporary file, and replacement file are verified as user-only, and the file plus parent directory are synchronized before the coordinator treats a write as durable. After a write, items older than the newest 20 original session start times are evicted in the same atomic transaction.

On corrupt, truncated, permission-denied, or disk-full storage, the store fails closed: it preserves the unreadable file for recovery, does not overwrite it with an empty history, keeps the current raw result in volatile memory, and blocks downstream automation that assumes durable recovery. The file schema has an explicit version and tested migration path.

Turning history off is an immediate privacy override: it increments a store generation and prevents both new and already in-flight operations from creating or updating records. It does not silently delete existing records; the UI states this plainly. **Clear History** confirms, cancels any active session, deletes persistent and completed volatile results, and increments the generation. Per-item deletion removes the matching volatile result and creates a session tombstone for the lifetime of any matching in-flight operation. Stale append/update completions fail rather than resurrecting disabled, cleared, or deleted data.

When persistent history is off, the controller keeps up to 20 volatile text results for the current app process so a new dictation does not destroy an earlier unsaved result. They are clearly labeled as non-persistent and disappear on quit. Audio is never part of either history form and any transient audio file is removed on every normal exit path or next-launch sweep.

History and the last-result UI expose:

- **Copy**: an explicit user action that places the selected result on the pasteboard.
- **Paste again**: creates a fresh target snapshot and runs safe delivery for the selected text.
- **Retry polishing**: snapshots the currently selected output mode and instructions, provider, model, and credential; it never silently reuses the original prompt. A successful retry atomically replaces the same record's polished/final variant and attempt outcome while retaining its original raw text and session start time. The prior polished variant remains until the replacement write succeeds, and a delete/clear tombstone prevents resurrection.
- **Delete**: removes that record locally.

## 9. Safe target-aware paste

Automatic paste is permitted only when the snapshotted external process, focused window, and focused editable element are still the intended target. Immediately before delivery, the service checks the focus epoch, process liveness, Accessibility identity, and editability. UtterInk's own non-activating UI does not count as a focus change; another external application, window, or field does. If element-level validation or process-addressed event delivery is unavailable, automatic paste is disabled for that attempt and the recoverable result exposes explicit Copy.

All automatic deliveries hold the single `DeliveryCoordinator` lease from snapshot through cleanup. An explicit Copy is different: it is a direct user instruction to replace the clipboard, is never automatically restored, and does not pretend to be a paste transaction.

The delivery algorithm is:

1. Capture each immediately readable pasteboard item/type and the starting `changeCount` before writing anything. Materialization is bounded to 16 MiB total and 500 ms; promised, unreadable, oversized, or timed-out data makes the transaction unsafe. Snapshot data exists only in memory, is never logged or crash-attached, and is disposed immediately after cleanup.
2. If a complete bounded snapshot cannot be made, release the lease without changing the pasteboard. Keep the transcript recoverable and ask for an explicit Copy action.
3. Revalidate the external process, window, focused element, focus epoch, and session/effect generation. If any changed or the target exited, release the lease without modifying the pasteboard and show a focus-changed warning with explicit Copy.
4. Compare the current pasteboard `changeCount` to the captured value again immediately before writing. If it changed, abort without modifying it because the user or another app copied something newer.
5. Write the result and record the resulting service-owned `changeCount`. `NSPasteboard` has no atomic compare-and-swap, so the tiny compare/write race is documented and exercised in adversarial tests; subsequent change-count checks always preserve a newer copy.
6. Revalidate the exact focused target once more, then post Command-V key-down/key-up to the validated process rather than as an unscoped global event. If process-addressed dispatch or exact revalidation fails, do not dispatch; restore the prior snapshot immediately when UtterInk still owns `changeCount`, then report a warning with explicit Copy. A newer third-party pasteboard value is never replaced.
7. After key-up dispatch, wait an injectable, bounded 250 ms consumption interval verified against the supported manual-test application set. Then restore the exact previous snapshot only if the current `changeCount` still equals the service-owned value. Any different value means the user or another app copied something newer; UtterInk must not overwrite it.
8. A cancellation handler performs the same guarded restoration exactly once when cancellation occurs after UtterInk writes. If reliable event consumption cannot be established for an application, the compatibility result is copy-only rather than a claim of successful automatic paste.

The app does not claim it can prove arbitrary target applications accepted text. It reports the verifiable outcome—exact target validated and process-addressed paste event dispatched—or the safe fallback. The saved result remains available in either case.

## 10. Optional OpenAI-compatible polishing

Polishing is an optional text-only step selected by output mode. Raw mode is always usable without a provider or API key.

Provider settings show:

- A user-facing profile name.
- The normalized endpoint host that will receive text.
- The selected model identifier.
- Whether the current output mode sends text off the Mac.
- Connection-test status and sanitized error guidance.

The egress disclosure is explicit rather than inferred: **“Audio never leaves this Mac. When polishing is enabled, transcript text is sent to `<normalized host>`.”** It updates before the user saves or selects a provider.

API keys are stored as generic-password items in macOS Keychain, scoped to the provider profile. UI models and debug descriptions expose only whether a key exists. Keys are never printed, exported, placed in UserDefaults, included in a URL, or sent anywhere except the configured authorization header.

Before implementation, the source audit records the actual FlowType UserDefaults domain/key mapping, provider-profile mapping, bundle/signing assumptions, and stable Keychain service/account/access-group identifiers. The migration adapter reads the audited legacy persistent domain explicitly; it does not assume a renamed app automatically sees the old defaults.

On first launch after migration, each legacy plaintext key is handled independently and idempotently:

1. If the corresponding Keychain item is absent, write the legacy value, read it back through the production lookup, compare in memory, and delete plaintext only after a match.
2. If a Keychain item already exists and matches, verify it through the production lookup and delete the redundant plaintext.
3. If existing and legacy values differ, do not overwrite either, do not polish with the plaintext fallback, and present a non-secret choice to keep the Keychain value or replace it. A replacement is written and verified before plaintext deletion.
4. If the legacy domain or Keychain item is inaccessible because of bundle, signing, sandbox, or access-group changes, retain the plaintext to avoid destructive loss but block its runtime use, show a migration action, and keep raw mode available.

No migration screen displays either secret value. A completed migration records only a non-secret version marker so it is not repeated.

Polishing uses an ephemeral URLSession configuration with no persistent URL cache, shared cookies, or shared credential store. Authorization is attached only after endpoint validation. Request duration and request/response sizes are bounded; redirects are decided by a delegate before they are followed. Polishing has no unbounded automatic retry. HTTP/auth/provider/decoding errors map to stable allowlisted codes before logging; raw `Error` descriptions, provider response bodies, and user text are excluded from logs and diagnostics. A failure selects raw text, marks the session completed with a warning, and keeps delivery available.

## 11. Network and ATS policy

Global `NSAllowsArbitraryLoads` is removed and must not reappear.

- Remote providers require HTTPS.
- Plain HTTP is allowed only for an explicit user-enabled canonical loopback endpoint on the same Mac (`localhost`, a dotted-decimal `127.0.0.0/8` literal, or `::1`).
- Plain-HTTP LAN hosts and public hosts are rejected in P0; they must use HTTPS.
- URL validation happens before saving and again before every request, including redirects.
- Redirects that violate the original transport policy or change host require rejection rather than silent credential forwarding.
- API keys are never forwarded across hosts on redirect.

Endpoint parsing uses `URLComponents`, permits only `http`/`https`, and rejects userinfo, fragments, malformed ports, integer/hex/octal IPv4 forms, and IPv4-mapped IPv6 ambiguity. A base path such as `/v1` is permitted; endpoint query parameters are not. `localhost` must resolve only to loopback addresses for a plain-HTTP request. Plain-HTTP loopback redirects are disabled. HTTPS redirects are revalidated before follow, and any host change is rejected so authorization cannot cross an origin boundary.

If a narrow ATS local-network key is technically required for supported loopback behavior, it is documented and verified as part of the entitlements/Info review. No general web-content or arbitrary-load exception is permitted.

## 12. Onboarding v2

Onboarding is organized around the first successful local dictation, not around advanced configuration.

1. **Privacy and capability:** explain that audio is processed locally and not retained, history is local and optional, and only optional polishing sends text to the displayed provider host. The default-on History toggle appears here before any test recording and states exactly what text will be stored; changing it immediately controls the test session.
2. **Readiness:** guide microphone permission, explain accessibility-dependent global control/paste behavior, choose the recognition language with concise native controls, choose a simple speech-model preset, and show download/load progress and disk impact.
3. **Shortcut test:** show the configured shortcut and let the user test it in place. Onboarding does not send the user to Settings merely to prove the shortcut works.
4. **Test dictation:** record inside UtterInk, show the raw result, then offer Copy and a safe built-in paste test. Provider setup and custom output modes are deferred to Settings.

Microphone permission is required to record. If Accessibility is denied, the user can still complete local transcription and explicitly copy the result, but global-control and automatic-paste limitations are clearly shown.

Closing the onboarding window does not mark onboarding complete. It resumes on the next appropriate launch until a non-empty transcript has been made available as a recoverable result. A safe copy fallback counts as a successful first dictation; an empty transcript, canceled session, or unrecoverable failure does not. Users can reopen onboarding from the menu.

English is the required P0 UI baseline. Recognition languages are independent of app-interface localization. Any additional UI localization is shipped only if the complete manual surface/state matrix passes in that localization; Chinese UI is not promised by P0, while the Chinese README remains required.

## 13. Product surfaces and interaction contract

### 13.1 Menu bar and floating recorder

Both surfaces render the authoritative state with stage-specific text: Requesting Permission, Listening, Stopping, Transcribing, Polishing, Pasting or Copying, Done, or a specific recoverable error. The domain state remains `delivering`, but the UI names the actual operation rather than showing a generic “Delivering.” They provide only intents valid for that state. Escape cancels all downstream automation according to the transition table.

The floating surface provides elapsed recording time, a clear stop/cancel action, and result recovery; it does not display invented progress for transcription or polishing. Reduced Motion removes nonessential animation.

### 13.2 Settings

Settings groups are:

- General: launch/visibility behavior and history enable/clear controls.
- Permissions: current microphone and accessibility status with system-navigation actions.
- Recognition Language: concise supported-language selection and the currently effective choice.
- Speech Model: three presets, readiness/progress, retry, disk impact, and Advanced catalog.
- Shortcuts: current shortcut and conflict-aware capture.
- Output Modes: Raw first, then optional polishing modes and their instructions.
- Provider: endpoint host, model, Keychain-backed key status, privacy explanation, and connection test.
- Diagnostics: preview the exact sanitized fields before export.

An incomplete provider profile is never labeled **In use**. It is either incomplete, ready, selected, or failing validation.

### 13.3 History and last result

The latest result is reachable without reopening Settings. Raw and polished variants are labeled, warnings explain fallback, and Copy/Paste again/Retry polishing/Delete actions match the actual recovery behavior defined above.

## 14. Diagnostics and privacy-safe logging

Diagnostics export is a human-readable JSON file with a schema version. It contains only:

- App version/build, macOS version, and CPU architecture.
- Microphone and Accessibility authorization states.
- Speech-model identifier and lifecycle state, without cache paths.
- Provider host and model identifier, without keys, URL path/query, headers, or response bodies.
- Last pipeline stage and stable sanitized error/warning codes.
- History enabled state and item count, without record content.

It never contains transcript text, audio, API keys, prompts, pasteboard content, target window titles, raw platform errors, or full provider URLs. The export UI previews these fields before saving.

Diagnostics are built from a dedicated allowlisted DTO containing only sanitized enums and scalars; domain models, `Error`, `URL`, request/response objects, and session snapshots are never encoded directly. `Logger` is wrapped by a facade with the same restricted input types. Transcript strings, provider bodies, authorization data, and pasteboard snapshots are prohibited arguments. Canary tests place a known transcript, key, prompt, full URL, pasteboard payload, and response body into surrounding domain errors and prove none appear in debug or release exports/log captures.

## 15. Visual identity and accessibility

The selected identity is **Ink Caret Monogram / B · Right Cursor**. Its foundation is an open U bowl whose right stem is deliberately interrupted as a text cursor. The asymmetry reduces the risk of the centered power-button reading found in rejected directions; it does not constitute final similarity or trademark clearance.

The production identity must preserve:

- Exact spelling `UtterInk`.
- Quiet, native, privacy-first, crafted tone.
- Open U bowl and deliberate right-side cursor gap.
- Transparent, one-color macOS Template Image behavior in the menu bar.
- Shared geometry across menu-bar mark, App Icon, wordmark companion, and state icons.

It must avoid microphones, waveforms, speech bubbles, ink droplets, quills, AI sparkles/gradients, OpenAI-like swirls, power-button geometry, raster cutouts, white matte edges, and small details that collapse at menu-bar size. Rejected geometry must not return as a wide `UI` letter pair, dense filled well, folded notch, enclosing type block, centered caret, concentric form, or generic U.

The upper cursor segment must retain a deliberate gap from the lower right stem and must not read as a stray dot at 16, 18, or 20pt. Round-one generated typography is direction-only and cannot ship as production artwork. Final marks and wordmarks use editable vector sources and reproducible deterministic exports, not raster extraction.

Canonical identity inputs are frozen by path and current SHA-256:

| Artifact | SHA-256 |
|---|---|
| `$HOME/Documents/codexprojects/playground/outputs/logos/utterink/data/selected-logo-route.json` | `15963ac872c2385170408029c86b450c4e2bdfc3b1c970f88d945adb8e7c4f08` |
| `$HOME/Documents/codexprojects/playground/outputs/logos/utterink/data/handoff.md` | `0464a616dad340ded1672781c014a4421c7f04779bd4c1af4f38877fc225d3aa` |
| `$HOME/Documents/codexprojects/playground/outputs/logos/utterink/menu-bar-round2/variants/B-right-cursor.svg` | `8bd098aedf9dee4bd5d1752eea513557a1bc756b78e82c00f647a8fc77932839` |
| `$HOME/Documents/codexprojects/playground/outputs/logos/utterink/menu-bar-round2/menu-bar-comparison.png` | `5e02410fdac93b6e2fcde790e7afa55fea7556c3a0604041b4c786d13857b506` |

Before asset acceptance, the selected vector draft is pixel-fitted and optically checked at 16, 18, and 20pt; then it is used to derive a restrained color App Icon, deterministic wordmark, and recording/processing/success/failure template family. Status is never communicated by color alone. Assets are verified in light mode, dark mode, high contrast, and relevant scale factors. A documented internal competitor-similarity and trademark-risk review is a shipping gate; paid legal clearance is not implied and would require separate user authorization. The final production asset set returns to the user for local approval because the selected SVG is a direction draft, not final artwork.

Native controls, meaningful accessibility names/roles/values/actions, keyboard traversal with visible focus and no traps, correct focus restoration, VoiceOver ordering and state/error announcements, icon-only labels, non-color status distinctions, sufficient contrast, and Reduce Motion are required. Custom content meets at least 4.5:1 contrast for normal text and 3:1 for large text and essential graphical controls; native system controls use platform semantics. Increase Contrast and Differentiate Without Color must preserve meaning; supported larger-text/display settings must not clip essential controls. Dense copy, nested scrolling, and low-contrast captions identified in the audit are not carried forward.

Manual accessibility acceptance covers the menu-bar item, floating recorder, onboarding, every Settings group, History/last result, dialogs, and every pipeline state. Results are recorded per shipped localization and included in the publication evidence packet.

## 16. Build, test, and CI strategy

Behavioral parity is established against the reviewed, buildable legacy working source before broad renaming or restructuring. Migration proceeds in small, tested slices so each behavior change is distinguishable from project-format and naming changes.

### 16.1 Automated tests

The detailed implementation plan will be test-driven. At minimum, automated coverage proves:

- Every valid and invalid dictation-state transition, duplicate start rejection, cancellation, and cleanup.
- Session/effect-generation rejection of late permission, transcription, polish, and delivery completions, including after a replacement session reaches the same stage.
- Speech-model lifecycle independence and retry behavior.
- Session snapshot immutability when settings change mid-session.
- Non-empty raw history write occurs before polishing and delivery.
- Empty transcripts are not persisted.
- Polishing success, timeout, invalid output, and raw fallback.
- History-generation and tombstone behavior during in-flight disable, clear, delete, retry, atomic updates, 20-item eviction, corrupt/truncated files, disk-full, and permission failures.
- Keychain create/read/update/delete, matching/existing/conflicting legacy values, inaccessible legacy domains, and plaintext removal only after verified migration.
- Endpoint canonicalization, HTTPS enforcement, loopback-peer verification, ambiguous-host rejection, redirect host policy, ephemeral-session behavior, and credential stripping.
- Same-app window/field change detection, failed/bounded pasteboard snapshot, a user copy between every delivery step, concurrent delivery leases, cancellation after write, process-addressed event failure, and change-count-protected restoration.
- Diagnostics and logging redaction.
- Onboarding completion only after a recoverable non-empty result.
- Orphan transient-audio cleanup on launch and before capture.

Integration tests use temporary Application Support paths, fake Keychain/pasteboard/workspace/Accessibility/event-sender facades, URLProtocol-backed networking, and deterministic transcription/polishing services. Clock, UUID/date generation, focus epochs, process liveness, task completion ordering, filesystem sync, and credential versions are injectable. Tests cancel at every await boundary and do not require a real API key. A signed-app/local-server integration check plus `Info.plist` inspection covers ATS behavior that URLProtocol cannot prove.

### 16.2 Manual and UI verification

Before release, a real Apple Silicon Mac on supported macOS verifies:

- First launch, microphone and Accessibility grant/deny/retry paths.
- Model download, interrupted download, loading, retry, and disk presentation.
- Real local recording and transcription in supported languages.
- Raw and polished modes, provider failure, focus changes, clipboard restoration, and user-copy races.
- Copy, Paste again, Retry polishing, Delete, history disabled, and Clear History.
- VoiceOver, keyboard-only operation, light/dark mode, high contrast, and Reduce Motion.
- The final stapled, quarantined DMG under a clean user account on a second supported Apple Silicon Mac without the development certificate or a cached notarization result, including an offline launch that proves stapling.
- The complete accessibility surface/state matrix for every shipped localization.

### 16.3 Pull-request CI

PR CI contains no Apple certificates, notarization credentials, API keys, or other secrets. The repository pins `Package.resolved`, the supported Xcode/Swift/macOS runner, and third-party Actions by immutable commit SHA. Workflow permissions default to `contents: read`, and history/privacy scans use a full-history checkout. CI runs:

- Swift package tests.
- Xcode build and app tests for the supported deployment target.
- Static checks, secret scan, and third-party license/notice validation.
- An `arm64` packaging smoke test with signing explicitly disabled. It is not uploaded by default; if temporary upload is approved for debugging, it is marked `UNSIGNED-DO-NOT-DISTRIBUTE`, given minimal retention, and is never reused by a release workflow.

A clean clone must build and test without anything from the legacy directory.

## 17. Open-source deliverables

Before public visibility, the repository contains and cross-checks:

- `LICENSE` with Apache-2.0.
- English `README.md` and Chinese `README.zh-CN.md`.
- `PRIVACY.md`, `SECURITY.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, and `CHANGELOG.md`.
- `TRADEMARKS.md` defining use of the UtterInk name/marks separately from Apache-2.0 source permissions.
- Third-party notices and license attributions for every shipped dependency/model component that requires them, including exact WhisperKit/model versions, source, license, and whether weights are downloaded or redistributed.
- Issue templates and a pull-request template.
- Reproducible local build/test/unsigned-package instructions.
- Supported macOS/architecture, privacy behavior, optional provider behavior, known issues, and security-reporting instructions.
- Source archives generated from the exact release commit, validated for excluded files, and covered by `SHA256SUMS`.

No public document promises Intel, automatic update, cloud sync, live transcription, or retained audio for `0.1.0`.

Publication is blocked until the import provenance/rights manifest has no unknown or incompatible entry, complete Git history and working-tree privacy scans pass, required NOTICE/copyright text is present, and links/Markdown in both READMEs and policy documents validate.

## 18. Signing, notarization, and DMG design

The local release path uses Developer ID Application signing with Hardened Runtime, secure timestamps, and only functionality-justified entitlements. Entitlements and embedded components are inventoried; broad exceptions are rejected. The release candidate is built from a clean checkout of one exact commit with no local overlay.

Release order is:

1. Record candidate commit, clean-tree state, Xcode/SDK/Swift versions, deployment target, `Package.resolved`, bundle identifiers, marketing/build versions, and `arm64` architecture. Tag, filename, app metadata, and release text must agree.
2. Build the Release app from that clean checkout.
3. Sign embedded frameworks/helpers from the inside out, then sign the outer app with secure timestamps. Do not use `--deep` as a substitute for correct signing order.
4. Run strict `codesign` verification and inspect designated requirements, entitlements, architecture, and every nested signature.
5. Build `UtterInk-0.1.0-arm64.dmg`. Its allowed content is `UtterInk.app`, an Applications-folder symlink, and deterministic presentation resources only. Sign the DMG, mount it, verify the content manifest, and recursively verify the contained app and outer DMG.
6. Compute the signed pre-staple DMG SHA-256. After explicit user approval scoped to that hash and submission attempt, submit that exact DMG with `notarytool` and wait for an accepted result.
7. Save the submission ID and `notarytool log`; review the log for warnings even on an accepted result. A rejection or changed artifact requires a new approval before resubmission.
8. Staple the notarization ticket and validate it. Mount the final DMG again and verify that neither its allowed contents nor app signatures changed unexpectedly.
9. Assess the final DMG and the app copied from it separately with `spctl`. Preserve/apply quarantine and complete the second-Mac clean-user and offline Gatekeeper tests.
10. Hash the final stapled DMG only after all mutation is complete; do not modify it afterward. Produce `SHA256SUMS`, release notes, and exact-commit source archives.

Signing and notarization happen locally on the user's Mac. Certificates and notarization credentials are never uploaded to GitHub.

## 19. External-action approval gates

Each action below requires a separate, one-time, artifact-scoped explicit user approval immediately before it occurs:

1. Create and first-push a GitHub private repository. Approval identifies owner/name/visibility, branch, exact commit, and whether the first push may run Actions or retain any CI artifact.
2. Upload a binary to Apple for notarization. Approval identifies Apple team, signed pre-staple DMG SHA-256, and one submission attempt; it does not authorize a changed file or resubmission.
3. Send a beta DMG to another person. Approval identifies recipient, channel, exact artifact hash, and notarization state.
4. Change the GitHub repository to public. Approval identifies repository and exact reviewed commit.
5. Publish the GitHub Release and DMG. Approval identifies tag/commit, final release text, final stapled DMG hash, `SHA256SUMS`, and source archives.

Approval of this design or a later implementation plan does not imply approval for any of these external actions. Any other external state change remains unauthorized until separately approved. Final release approval occurs only after the user reviews the evidence packet.

Before final publication, the user receives one evidence packet containing:

- Repository, branch, and exact commit.
- Complete public file list.
- Import provenance/rights manifest plus full-history/working-tree secret, private-data, and license-scan results.
- Clean build/test and unsigned-package CI evidence, pinned toolchain, and `Package.resolved`.
- Signing, notarization submission/log review, stapling, `codesign`, `spctl`, and second-Mac clean-user/offline Gatekeeper evidence.
- DMG allowed-content manifest, filename, size, pre-staple hash approved for notarization, and final post-staple SHA-256.
- Known issues and supported OS/architecture.
- Rendered English/Chinese README and privacy previews.
- Final identity review and accessibility surface/state results.

Planned release assets are `UtterInk-0.1.0-arm64.dmg`, `SHA256SUMS`, release notes, and source archives.

## 20. P0 approval traceability

| Approved requirement | Design location |
|---|---|
| One authoritative dictation state machine | Sections 5.2, 6.1 |
| Independent model lifecycle | Sections 5.2, 6.2 |
| UI emits intents only | Sections 5.2, 13 |
| Immutable session settings/target snapshot | Sections 6.3, 7 |
| Save raw text before polish/paste | Sections 7, 8 |
| Raw fallback on LLM failure | Sections 7, 10 |
| Default local latest-20 text history; no audio | Section 8 |
| Target-aware safe paste and guarded clipboard restore | Section 9 |
| API keys migrated from UserDefaults to Keychain safely | Section 10 |
| Privacy/readiness/test-focused onboarding | Section 12 |
| Sanitized diagnostics with no keys/transcripts | Section 14 |
| No global arbitrary loads; narrow local policy | Section 11 |

## 21. Principal risks and controls

| Risk | Control |
|---|---|
| Legacy working tree and legacy `HEAD` disagree | Review and import a per-file allowlist from the current buildable working source; start new history |
| Private/licensing material is removed from the tree but survives in Git objects | Scan staged imports plus complete new history; reinitialize the unpublished repository after any sensitive commit |
| Fragmented UI state returns during migration | Route every surface through typed intents and test invalid/duplicate transitions |
| A late async callback mutates a newer session | Bind every effect to session ID/generation, discard stale completions, and enforce a cleanup barrier |
| Text is lost after transcription | Persist raw text first, retain current-session memory when history is off, expose recovery actions |
| Clipboard restoration destroys a newer copy | Restore only when pasteboard `changeCount` still belongs to UtterInk |
| Paste reaches the wrong app, window, or field | Snapshot process plus focused Accessibility target, use process-addressed events, revalidate immediately before delivery, otherwise require explicit Copy |
| Disable/clear/delete races recreate private history | Use immediate store-generation overrides and per-session tombstones |
| Provider secret or transcript leaks | Keychain storage, static privacy-safe logs, sanitized diagnostics, secret scans |
| Local endpoint support weakens all transport security | HTTPS by default; explicit loopback-only HTTP; reject unsafe redirects and global ATS exceptions |
| Brand loses legibility or resembles a power button/competitor | Pixel fitting, multi-mode validation, similarity and trademark review before shipping |
| A signed build is mistaken for a proven release or differs from reviewed source | Bind artifacts to an exact clean commit/toolchain, then require notarization, logs, stapling, strict verification, Gatekeeper testing, final hashes, and evidence packet |

## 22. Design acceptance and next step

This design is accepted when the user confirms that it accurately captures the approved product scope, architecture, privacy behavior, identity direction, open-source deliverables, and release gates.

No source import, Xcode scaffolding, feature implementation, signing, repository creation, upload, or publication is authorized by the existence of this document. After explicit written-spec approval, the next action is to invoke `superpowers:writing-plans` and create a detailed TDD implementation plan. Implementation begins only after that planning transition.
