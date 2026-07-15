# UtterInk 0.1.0 Manual Verification Matrix

This matrix records release evidence for one immutable, final, stapled DMG. It
is not a checklist whose boxes imply success. Every executed or unexecuted row
must be recorded as exactly `pass`, `fail`, or `not-run`; there is no default
`pass` state.

The checked-in rows intentionally start as `not-run`. Before using this file as
evidence, replace every `required` or angle-bracket placeholder, including on a
`not-run` row. A `pass` is valid only when the expected result was observed on
the exact candidate commit and final DMG SHA-256 recorded below. Any `fail`,
`not-run`, missing field, placeholder, hash mismatch, or contradictory result
keeps the release status `NOT_RELEASE_READY`.

## Candidate binding

| Field | Required value |
|---|---|
| Candidate commit | `<40 lowercase hexadecimal characters>` |
| Candidate tree | `<40 lowercase hexadecimal characters>` |
| Product/version/build | `UtterInk 0.1.0 (1)` |
| Architecture | `arm64` |
| Minimum-runtime test OS | `macOS 14.x` |
| Final DMG filename | `UtterInk-0.1.0-arm64.dmg` |
| Final post-staple DMG size | `<integer bytes>` |
| Final post-staple DMG SHA-256 | `<64 lowercase hexadecimal characters>` |
| Final-DMG verification evidence | `<sanitized repository-relative evidence reference>` |
| Shipped UI localizations | `en` unless another localization has its own complete matrix |

All rows in one evidence set must repeat the same final post-staple SHA-256.
Do not record the pre-staple notarization hash in a final-hash column. Append a
new dated result when retesting; do not erase a previous failure.

## Record-field rules

- `Tester` is a stable reviewer label, not an account name or home-directory
  path.
- `Model class` is a coarse Apple Silicon class such as `Mac mini (M-series)`;
  do not record a serial number, hardware UUID, or machine name.
- `macOS` is the observed version, including the patch version when available.
- `UTC timestamp` is RFC 3339. A `not-run` row still records who classified it,
  on which available test environment, and when.
- `Observation` is concise and sanitized. Do not include transcript text,
  clipboard contents, API keys, prompts, full provider URLs, response bodies,
  certificate bodies, usernames, or absolute local paths.
- `Locale` is the shipped UI locale exercised in that row. Duplicate every
  UI-facing row for every shipped localization. Version `0.1.0` ships English
  only unless the added locale has a complete product and accessibility matrix.
- A deployment target, simulator result, unit test, or successful compilation
  is never a substitute for the macOS 14.x real-hardware rows.

## Minimum-runtime installation and launch

Run these rows on a real Apple Silicon Mac running macOS 14.x. The input is the
final stapled DMG with quarantine preserved.

| ID | Locale | Scenario and required observation | Status | Tester | Model class | macOS | UTC timestamp | Final DMG SHA-256 | Observation |
|---|---|---|---|---|---|---|---|---|---|
| MR-01 | en | Confirm quarantine is present, the DMG bytes match the bound final hash, and the DMG opens without removing quarantine. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| MR-02 | en | Copy `UtterInk.app` from the mounted DMG to `/Applications`; do not launch an app left inside the mounted image. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| MR-03 | en | First launch from Applications succeeds through Gatekeeper on actual macOS 14.x hardware and presents onboarding. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| MR-04 | en | Onboarding accurately explains local audio processing, local optional text history, optional provider text egress, permissions, language, model preset, shortcut test, and first dictation. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| MR-05 | en | Closing incomplete onboarding does not mark it complete; reopening or relaunching resumes it until a recoverable non-empty local result exists. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| MR-06 | en | Quit and relaunch the installed app; the second launch succeeds and the menu-bar item, Settings, History/last result, and onboarding completion state are coherent. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| MR-07 | en | Complete a minimum-runtime smoke covering permissions, model readiness, local dictation, result recovery, history, provider configuration, delivery fallback, and accessibility entry points. | not-run | required | required | required | required | `<final hash>` | Not executed. |

## Permission paths

Reset or revoke only the permission under test. Record recovery without relying
on a previously approved state.

| ID | Locale | Scenario and required observation | Status | Tester | Model class | macOS | UTC timestamp | Final DMG SHA-256 | Observation |
|---|---|---|---|---|---|---|---|---|---|
| PM-01 | en | Deny microphone access. Recording does not start; the denial and recovery action are specific and no empty history item is created. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| PM-02 | en | Grant microphone access after denial and retry. Local recording becomes available without reinstalling or corrupting session state. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| PM-03 | en | Deny Accessibility access. Local recording/transcription and explicit Copy remain available while global control and automatic paste are clearly unavailable. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| PM-04 | en | Grant Accessibility access after denial and retry. The global shortcut and eligible automatic delivery recover without relaunching when supported by macOS. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| PM-05 | en | Revoke microphone or Accessibility access between attempts. The next attempt rechecks current authorization and uses the safe denial/fallback path. | not-run | required | required | required | required | `<final hash>` | Not executed. |

## Speech-model lifecycle and offline transcription

Use a real runtime-downloaded model covered by the reviewed model notice. Do not
include a cache path in the observation.

| ID | Locale | Scenario and required observation | Status | Tester | Model class | macOS | UTC timestamp | Final DMG SHA-256 | Observation |
|---|---|---|---|---|---|---|---|---|---|
| MD-01 | en | Select a preset whose model is missing. Readiness is shown before a dictation session is created, with truthful disk-impact information. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| MD-02 | en | Start model download. Missing, downloading, and loading states are distinguishable and progress is not presented as dictation progress. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| MD-03 | en | Interrupt or force a controlled download/load failure. A sanitized failure and Retry action appear; no partial model is labeled ready. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| MD-04 | en | Retry after failure. The selected model reaches `ready`, disk presentation updates, and an older preparation result does not replace the current selection. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| MD-05 | en | After readiness, disable network access and complete a real recording and local transcription. Audio remains local and the non-empty result is recoverable. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| MD-06 | en | Exercise each shipped preset and the Advanced catalog entry point. Active or preparing models cannot be deleted through an unsafe path. | not-run | required | required | required | required | `<final hash>` | Not executed. |

## Recording, surfaces, and delivery

Use an ordinary editable target application for successful delivery and a
different external window or field for focus-change tests. Observations describe
outcomes without copying target-window titles or clipboard payloads.

| ID | Locale | Scenario and required observation | Status | Tester | Model class | macOS | UTC timestamp | Final DMG SHA-256 | Observation |
|---|---|---|---|---|---|---|---|---|---|
| DD-01 | en | Start from the menu and from the configured shortcut. Menu-bar and floating-recorder surfaces show the same authoritative session state. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| DD-02 | en | Stop an active recording. The UI moves through Stopping and Transcribing once, then exposes the recoverable result. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| DD-03 | en | Cancel during recording and during a downstream stage. Downstream automation stops, cleanup completes, and no stale completion mutates the next session. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| DD-04 | en | Observe Requesting Permission, Listening, Stopping, Transcribing, Polishing, Pasting or Copying, Done, and specific recoverable-error labels; no generic or invented progress is shown. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| DD-05 | en | With the exact snapshotted target unchanged, automatic delivery dispatches to that process and reports only the verifiable delivery outcome. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| DD-06 | en | Change the external application, window, or focused field before delivery. Automatic paste is withheld and explicit Copy remains available. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| DD-07 | en | With a bounded readable pasteboard snapshot, successful automatic delivery restores the previous pasteboard after the consumption interval. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| DD-08 | en | Copy something new between snapshot, write, dispatch, and restoration checkpoints. The newer user copy is never overwritten and a conflict/fallback is visible. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| DD-09 | en | Exercise an unreadable, promised, oversized, or timed-out pasteboard snapshot. UtterInk leaves the pasteboard unchanged and offers explicit Copy. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| DD-10 | en | Choose explicit Copy. It intentionally replaces the pasteboard and is not automatically restored. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| DD-11 | en | Choose Paste again from History/last result. A fresh target snapshot is taken; the original target is not silently reused. | not-run | required | required | required | required | `<final hash>` | Not executed. |

## History, recovery, and transient audio

Use only disposable test text. Evidence records whether behavior passed; it
never records the test text itself.

| ID | Locale | Scenario and required observation | Status | Tester | Model class | macOS | UTC timestamp | Final DMG SHA-256 | Observation |
|---|---|---|---|---|---|---|---|---|---|
| HI-01 | en | With History enabled and polishing delayed or failed, the non-empty raw result is durable before any provider request or pasteboard mutation. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| HI-02 | en | Complete raw and polished modes. Raw and final variants and sanitized warnings are labeled, and only the newest 20 non-empty sessions remain. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| HI-03 | en | Turn History off before and during an attempt. No new persistent record is created or resurrected; volatile results remain clearly non-persistent until quit. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| HI-04 | en | Clear History after confirmation. Active work is canceled, persistent/completed volatile results disappear, and stale work cannot recreate them. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| HI-05 | en | Delete one item while idle and while matching work is in flight. The selected item disappears and is not resurrected. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| HI-06 | en | Retry polishing. Current output/provider settings are snapshotted, raw text is retained, and the prior polished value changes only after a successful replacement write. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| HI-07 | en | Exercise Copy and Paste again from both History and last result. Actions match the selected variant and preserve safe-delivery behavior. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| HI-08 | en | Simulate an interrupted process that leaves transient audio, then relaunch. The launch/pre-capture sweep removes the orphan before a new capture and no audio history is exposed. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| HI-09 | en | Induce a controlled history storage failure. The unreadable data is not replaced, automation stops, and the current raw result remains available only through a safe recovery action. | not-run | required | required | required | required | `<final hash>` | Not executed. |

## Provider and privacy behavior

Use a dedicated disposable provider profile. The result record may contain only
the normalized host and model identifier permitted by diagnostics policy; it
must never contain credentials, path/query components, headers, or bodies.

| ID | Locale | Scenario and required observation | Status | Tester | Model class | macOS | UTC timestamp | Final DMG SHA-256 | Observation |
|---|---|---|---|---|---|---|---|---|---|
| PV-01 | en | Raw mode works without a provider or API key and sends no provider request. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| PV-02 | en | A valid OpenAI-compatible HTTPS provider can be saved, tested, selected, and used for text-only polishing. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| PV-03 | en | Before saving/selecting a provider, disclosure shows the normalized destination host and states that audio stays local while polishing sends transcript text. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| PV-04 | en | An explicitly enabled canonical loopback HTTP endpoint on the same Mac works; no LAN or public plain-HTTP endpoint is accepted. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| PV-05 | en | Unsafe userinfo, query, ambiguous host, transport downgrade, loopback redirect, or cross-host redirect is rejected without forwarding credentials. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| PV-06 | en | Timeout, invalid output, and sanitized provider failure fall back to saved raw text with a visible warning and no transcript, key, prompt, URL path/query, or response-body leakage. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| PV-07 | en | An incomplete provider profile is labeled incomplete rather than In use; Keychain-backed key state reveals only whether a key exists. | not-run | required | required | required | required | `<final hash>` | Not executed. |

## Accessibility surface matrix

Duplicate this entire section for every shipped UI localization. For each row,
test VoiceOver name/role/value/action and ordering, keyboard-only traversal,
visible focus, absence of keyboard traps, and correct focus restoration. Icon
status must have a non-color distinction. A single smoke on one surface does
not pass another surface.

| ID | Locale | Surface and required observation | Status | Tester | Model class | macOS | UTC timestamp | Final DMG SHA-256 | Observation |
|---|---|---|---|---|---|---|---|---|---|
| AX-01 | en | Menu-bar item and menu: meaningful status and actions, valid action set for current state, predictable order, keyboard operation, and restored focus. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| AX-02 | en | Floating recorder/result: elapsed time, stop/cancel, state/error announcement, recovery actions, keyboard path, and restored focus. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| AX-03 | en | Onboarding: every page, permission state, model state, shortcut test, built-in dictation/copy fallback, close/resume, and completion behavior. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| AX-04 | en | Every Settings group: General, Permissions, Recognition Language, Speech Model/Advanced, Shortcuts, Output Modes, Provider, and Diagnostics preview/export. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| AX-05 | en | History list, empty state, item selection, raw/polished variants, warning state, Copy, Paste again, Retry polishing, Delete, and Clear History confirmation. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| AX-06 | en | Last-result surface: result variants, warnings, delivery outcome, and all valid recovery actions are announced and keyboard reachable. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| AX-07 | en | Every dialog, confirmation, permission guidance, provider failure, model failure, storage failure, and delivery fallback has initial focus, clear text, and a return path. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| AX-08 | en | Increase Contrast preserves readable text, controls, focus, icons, and status meaning across every listed surface/state. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| AX-09 | en | Differentiate Without Color preserves every status and error distinction across every listed surface/state. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| AX-10 | en | Reduce Motion removes nonessential motion without hiding state transitions, progress meaning, controls, or announcements. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| AX-11 | en | Light and dark appearances preserve contrast, template-image behavior, visible focus, and legibility across every listed surface/state. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| AX-12 | en | Supported larger text and display settings do not clip essential controls, hide state/error text, create traps, or require nested scrolling. | not-run | required | required | required | required | `<final hash>` | Not executed. |

## Accessibility pipeline-state matrix

Run every row below for every shipped localization across every surface on
which the state appears. VoiceOver must announce the specific state or warning;
keyboard focus and available actions must match the authoritative state.

| ID | Locale | Pipeline state and required observation | Status | Tester | Model class | macOS | UTC timestamp | Final DMG SHA-256 | Observation |
|---|---|---|---|---|---|---|---|---|---|
| ST-01 | en | Requesting Permission: state and available cancel/recovery action are announced. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| ST-02 | en | Listening: elapsed time and stop/cancel controls remain meaningful without color alone. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| ST-03 | en | Stopping: duplicate stop is unavailable and transition is announced once. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| ST-04 | en | Transcribing: local-processing label is announced without invented completion progress. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| ST-05 | en | Polishing: optional text-egress state and cancel behavior are clear. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| ST-06 | en | Pasting and Copying: the UI names the actual delivery operation and exposes safe fallback where needed. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| ST-07 | en | Done: result, raw/polished variant, warning, and recovery actions are announced in logical order. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| ST-08 | en | Permission, model, transcription, provider, history/storage, and delivery failures each use a specific sanitized message and valid recovery action. | not-run | required | required | required | required | `<final hash>` | Not executed. |

## Local quarantined-copy Gatekeeper evidence

The immutable release original is never quarantined, stripped, rewritten, or
launched for this test. Use a byte-identical ephemeral copy, verify the copy's
hash before applying quarantine, and keep the original final hash unchanged.

| ID | Locale | Scenario and required observation | Status | Tester | Model class | macOS | UTC timestamp | Final DMG SHA-256 | Observation |
|---|---|---|---|---|---|---|---|---|---|
| LG-01 | en | Create an ephemeral byte-identical DMG copy; its SHA-256 equals the immutable final DMG before quarantine is applied to the copy. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| LG-02 | en | Open the quarantined copy, copy the app to Applications, and complete first launch and relaunch through Gatekeeper. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| LG-03 | en | Re-hash the immutable release original after the local test; it still equals the bound final hash and was never modified. | not-run | required | required | required | required | `<final hash>` | Not executed. |

## Second-Mac clean-user offline Gatekeeper evidence

These rows require a **second physical supported Apple Silicon Mac**. Another
user account, VM, volume, or partition on the development Mac is not a second
Mac and cannot satisfy this gate. The second Mac must not have the development
certificate or a cached notarization ticket/result for this artifact.

The user may perform the test on another Mac they own and return only this
sanitized, hash-bound record. Sending the DMG to any other person or through a
transfer channel first requires a separate one-time beta-transfer approval
naming the recipient, channel, exact final SHA-256, and notarization state.
Nothing in this matrix authorizes that transfer.

| ID | Locale | Scenario and required observation | Status | Tester | Model class | macOS | UTC timestamp | Final DMG SHA-256 | Observation |
|---|---|---|---|---|---|---|---|---|---|
| SM-01 | en | Confirm this is a second physical supported Apple Silicon Mac, not the development Mac under another account or environment. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| SM-02 | en | Confirm the clean test user has no development certificate and the machine has no cached ticket/result for this exact artifact. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| SM-03 | en | Receive or locally transfer the final stapled/quarantined DMG without changing bytes; verify its SHA-256 equals the bound final hash before opening. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| SM-04 | en | Disconnect all network interfaces before first launch and keep the machine offline throughout the Gatekeeper launch observation. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| SM-05 | en | From the quarantined DMG, copy the app to Applications under the clean user and complete the first launch while offline. Gatekeeper accepts the stapled ticket. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| SM-06 | en | Quit and relaunch the installed app while still offline; the app opens normally and displays its local onboarding surface. | not-run | required | required | required | required | `<final hash>` | Not executed. |
| SM-07 | en | Re-hash the received DMG after the test; it still equals the immutable final SHA-256 and the record contains no user/machine identifier. | not-run | required | required | required | required | `<final hash>` | Not executed. |

If any second-Mac row is missing, `fail`, `not-run`, substituted with another
account on the development Mac, or bound to another hash, the evidence
collector must report `NOT_RELEASE_READY`. It must never transfer an artifact
to fill this gap.

## Completion review

Before handing records to the collector, verify:

- every row for every shipped localization has one explicit status and all
  required metadata;
- the Candidate binding records the exact commit for the evidence set, and
  every row repeats the exact immutable final post-staple SHA-256;
- macOS 14.x launch evidence came from real Apple Silicon hardware;
- the second-Mac result came from a distinct physical supported Mac under a
  clean user while offline;
- observations are sanitized and contain no prohibited payload or machine/user
  identifier; and
- no manual result is interpreted as permission to upload, transfer, make a
  repository public, or publish a release.
