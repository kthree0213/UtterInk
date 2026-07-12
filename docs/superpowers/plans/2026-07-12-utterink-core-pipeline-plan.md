# UtterInk Core Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement and fully test UtterInk's authoritative dictation state machine, immutable snapshots, local history, Keychain migration, secure polishing, transient audio, Whisper model lifecycle, safe delivery, diagnostics, and end-to-end orchestration.

**Architecture:** `UtterInkCore` contains values, protocols, the pure reducer, and a main-actor controller. `UtterInkServices` contains replaceable actors/adapters for macOS and external libraries. Every async effect carries `EffectToken(sessionID:generation:)`; the controller discards stale completions and waits for cleanup before accepting another session.

**Tech Stack:** Swift 5.9 language mode, Observation, Foundation, Security, AVFoundation, ApplicationServices, AppKit, URLSession, WhisperKit 0.18.0, XCTest.

## Global Constraints

- State sequence is `idle -> requestingPermission -> recording -> stopping -> transcribing -> polishing? -> delivering -> completed | failed`.
- Speech model state is independent; no dictation session exists until the selected model is ready.
- Raw text becomes volatile and, when history is enabled, durable before polish or paste.
- History is local text-only, default-on, 20-session capped, atomically versioned, immediately disableable/clearable, and audio-free.
- Cancel stops all downstream automation; it never silently means “continue with raw.”
- LLM failure falls back to raw with a warning. Remote text is HTTPS-only; explicit HTTP is canonical loopback-only.
- Target/focus change prevents automatic paste; the pasteboard is never blindly overwritten or restored over a newer copy.
- API keys never enter UserDefaults, diagnostics, logs, URLs, history, or printable/debug descriptions.
- Every task ends with `swift test --package-path Packages/UtterInkKit` and a focused commit.

---

### Task 1: Core identifiers, states, results, and error codes

**Files:**
- Create: `Packages/UtterInkKit/Sources/UtterInkCore/Domain/SessionID.swift`
- Create: `Packages/UtterInkKit/Sources/UtterInkCore/Domain/PipelineState.swift`
- Create: `Packages/UtterInkKit/Sources/UtterInkCore/Domain/SpeechModelState.swift`
- Create: `Packages/UtterInkKit/Sources/UtterInkCore/Domain/DictationResult.swift`
- Create: `Packages/UtterInkKit/Sources/UtterInkCore/Diagnostics/DiagnosticsModels.swift`
- Test: `Packages/UtterInkKit/Tests/UtterInkCoreTests/DomainModelTests.swift`

**Interfaces:**
- Produces: `SessionID`, `EffectToken`, `PipelineStage`, `PipelineState`, `SpeechModelState`, `DictationResult`, `DiagnosticCode`.

- [ ] **Step 1: Write the failing model tests**

```swift
import XCTest
@testable import UtterInkCore

final class DomainModelTests: XCTestCase {
    func testEffectTokenSeparatesGenerationsWithinOneSession() {
        let id = SessionID(rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
        XCTAssertNotEqual(EffectToken(sessionID: id, generation: 1), EffectToken(sessionID: id, generation: 2))
    }

    func testPipelineStartsIdleWithoutParallelFlags() {
        XCTAssertEqual(PipelineState.idle.stage, .idle)
        XCTAssertNil(PipelineState.idle.sessionID)
        XCTAssertNil(PipelineState.idle.result)
    }

    func testPolishFailureResultSelectsRawText() {
        let result = DictationResult(
            sessionID: SessionID(), rawText: "raw", finalText: "raw",
            source: .rawFallback, warning: .polishTransport, delivery: nil
        )
        XCTAssertEqual(result.finalText, result.rawText)
        XCTAssertEqual(result.source, .rawFallback)
    }
}
```

- [ ] **Step 2: Run to verify compile failure**

Run `swift test --package-path Packages/UtterInkKit --filter DomainModelTests`.

Expected: FAIL because the domain types do not exist.

- [ ] **Step 3: Add the minimal complete models**

Implement these exact public shapes:

```swift
import Foundation

public struct SessionID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct EffectToken: Hashable, Sendable {
    public let sessionID: SessionID
    public let generation: UInt64
    public init(sessionID: SessionID, generation: UInt64) {
        self.sessionID = sessionID
        self.generation = generation
    }
}

public enum DiagnosticCode: String, Codable, CaseIterable, Sendable {
    case permissionMicrophone = "permission.microphone"
    case permissionAccessibility = "permission.accessibility"
    case audioStart = "audio.start"
    case audioFinalize = "audio.finalize"
    case transcriptionEmpty = "transcription.empty"
    case transcriptionFailed = "transcription.failed"
    case historyWrite = "history.write"
    case historyCorrupt = "history.corrupt"
    case credentialMissing = "credential.missing"
    case credentialMigrationConflict = "credential.migration_conflict"
    case polishTransport = "polish.transport"
    case polishAuthentication = "polish.authentication"
    case polishInvalidResponse = "polish.invalid_response"
    case deliveryTargetUnavailable = "delivery.target_unavailable"
    case deliveryTargetChanged = "delivery.target_changed"
    case deliveryPasteboardChanged = "delivery.pasteboard_changed"
    case deliveryDispatch = "delivery.dispatch"
    case cancelled = "session.cancelled"
}

public enum PipelineStage: String, Codable, Sendable {
    case idle, requestingPermission, recording, stopping, transcribing, polishing, delivering, completed, failed
}

public enum ResultSource: String, Codable, Sendable { case raw, polished, rawFallback }
public enum ResultPersistence: String, Codable, Sendable { case volatile, persistent }
public enum DeliveryOutcome: Equatable, Codable, Sendable {
    case pasteEventDispatched
    case deliveredToOnboardingTest
    case copiedByPreference
    case copiedByUser
    case manualCopyRequired(DiagnosticCode)
}

public struct DictationResult: Equatable, Codable, Sendable {
    public let sessionID: SessionID
    public let startedAt: Date
    public let rawText: String
    public let finalText: String
    public let source: ResultSource
    public let warning: DiagnosticCode?
    public let delivery: DeliveryOutcome?
    public let persistence: ResultPersistence
    public init(sessionID: SessionID, startedAt: Date = Date(), rawText: String, finalText: String, source: ResultSource, warning: DiagnosticCode?, delivery: DeliveryOutcome?, persistence: ResultPersistence = .volatile) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.rawText = rawText
        self.finalText = finalText
        self.source = source
        self.warning = warning
        self.delivery = delivery
        self.persistence = persistence
    }
}

public struct PipelineFailure: Equatable, Sendable {
    public let code: DiagnosticCode
    public let recoverableResult: DictationResult?
    public init(code: DiagnosticCode, recoverableResult: DictationResult?) {
        self.code = code
        self.recoverableResult = recoverableResult
    }
}

public struct PipelineState: Equatable, Sendable {
    public var stage: PipelineStage
    public var sessionID: SessionID?
    public var token: EffectToken?
    public var result: DictationResult?
    public var failure: PipelineFailure?
    public init(stage: PipelineStage, sessionID: SessionID?, token: EffectToken?, result: DictationResult?, failure: PipelineFailure?) {
        self.stage = stage
        self.sessionID = sessionID
        self.token = token
        self.result = result
        self.failure = failure
    }
    public static let idle = PipelineState(stage: .idle, sessionID: nil, token: nil, result: nil, failure: nil)
}

public enum SpeechModelState: Equatable, Sendable {
    case missing(modelID: String)
    case downloading(modelID: String, progress: Double)
    case loading(modelID: String)
    case ready(modelID: String)
    case failed(modelID: String, code: DiagnosticCode, retryable: Bool)
}

public struct SpeechModelLease: Hashable, Sendable {
    public let id: UUID
    public let modelID: String
    public let generation: UInt64
    public init(id: UUID = UUID(), modelID: String, generation: UInt64) {
        self.id = id
        self.modelID = modelID
        self.generation = generation
    }
}

public struct SpeechModelDescriptor: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let displayName: String
    public let approximateBytes: UInt64
    public let preset: String?
    public init(id: String, displayName: String, approximateBytes: UInt64, preset: String?) {
        self.id = id
        self.displayName = displayName
        self.approximateBytes = approximateBytes
        self.preset = preset
    }
}
```

- [ ] **Step 4: Run focused and full tests**

```bash
swift test --package-path Packages/UtterInkKit --filter DomainModelTests
swift test --package-path Packages/UtterInkKit
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/UtterInkKit/Sources/UtterInkCore Packages/UtterInkKit/Tests/UtterInkCoreTests/DomainModelTests.swift
git commit -m "feat: add dictation domain models"
```

---

### Task 2: Immutable settings and session snapshots

**Files:**
- Create: `Packages/UtterInkKit/Sources/UtterInkCore/Domain/SettingsModels.swift`
- Create: `Packages/UtterInkKit/Sources/UtterInkCore/Domain/SessionSnapshot.swift`
- Create: `Packages/UtterInkKit/Sources/UtterInkCore/Security/SessionSecret.swift`
- Test: `Packages/UtterInkKit/Tests/UtterInkCoreTests/SessionSnapshotTests.swift`

**Interfaces:**
- Produces: `RecognitionConfiguration`, `OutputMode`, `ProviderProfile`, `ProviderSelection`, `ShortcutMode`, `UserSettings`, `DeliveryTarget`, `DeliveryPreference`, `SessionSecret`, `SessionSnapshot`.

- [ ] **Step 1: Write snapshot immutability tests**

```swift
import XCTest
@testable import UtterInkCore

final class SessionSnapshotTests: XCTestCase {
    func testP0DefaultsAreRawLocalAndHistoryEnabled() {
        XCTAssertEqual(UserSettings.p0Default.speechModelID, "small")
        XCTAssertEqual(UserSettings.p0Default.selectedOutputModeID, OutputMode.rawID)
        XCTAssertTrue(UserSettings.p0Default.outputModes[0].skipsPolishing)
        XCTAssertTrue(UserSettings.p0Default.historyEnabled)
        XCTAssertNil(UserSettings.p0Default.selectedProviderProfileID)
    }

    func testSnapshotCopiesOutputModeAndCredential() throws {
        var mode = OutputMode(id: UUID(), title: "Polish", skipsPolishing: false, instructions: "first")
        let secret = SessionSecret(utf8: "key-one")
        let snapshot = SessionSnapshot(
            id: SessionID(), target: .copyOnly,
            recognition: .fixed(languageCode: "en"), speechModelID: "small",
            outputMode: mode,
            provider: ProviderSelection(profileID: UUID(), baseURL: URL(string: "https://api.example.test/v1")!, modelID: "model", policy: .remoteHTTPS),
            historyGeneration: 4, historyEnabled: true, deliveryPreference: .automaticPaste,
            credential: secret.copy()
        )
        mode.instructions = "changed"
        secret.clear()
        XCTAssertEqual(snapshot.outputMode.instructions, "first")
        XCTAssertEqual(try snapshot.credential?.withUTF8 { $0 }, "key-one")
    }

    func testSecretDescriptionNeverContainsValue() {
        let secret = SessionSecret(utf8: "CANARY_SECRET")
        XCTAssertFalse(String(describing: secret).contains("CANARY_SECRET"))
        XCTAssertFalse(String(reflecting: secret).contains("CANARY_SECRET"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run `swift test --package-path Packages/UtterInkKit --filter SessionSnapshotTests`.

Expected: compile failure for missing snapshot types.

- [ ] **Step 3: Implement exact value types**

```swift
import Foundation

public enum RecognitionConfiguration: Equatable, Codable, Sendable {
    case fixed(languageCode: String)
    case automatic
}

public struct OutputMode: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var title: String
    public var skipsPolishing: Bool
    public var instructions: String
    public init(id: UUID, title: String, skipsPolishing: Bool, instructions: String) {
        self.id = id
        self.title = title
        self.skipsPolishing = skipsPolishing
        self.instructions = instructions
    }
    public static let rawID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public static let raw = OutputMode(id: rawID, title: "Raw", skipsPolishing: true, instructions: "")
}

public enum EndpointPolicy: String, Codable, Sendable { case remoteHTTPS, loopbackHTTP }

public struct ProviderSelection: Equatable, Sendable {
    public let profileID: UUID
    public let baseURL: URL
    public let modelID: String
    public let policy: EndpointPolicy
    public init(profileID: UUID, baseURL: URL, modelID: String, policy: EndpointPolicy) {
        self.profileID = profileID
        self.baseURL = baseURL
        self.modelID = modelID
        self.policy = policy
    }
}

public struct ProviderProfile: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var title: String
    public var baseURL: URL
    public var modelID: String
    public var policy: EndpointPolicy
    public init(id: UUID, title: String, baseURL: URL, modelID: String, policy: EndpointPolicy) {
        self.id = id
        self.title = title
        self.baseURL = baseURL
        self.modelID = modelID
        self.policy = policy
    }
}

public struct DeliveryTargetID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public enum DeliveryTarget: Equatable, Sendable {
    case external(DeliveryTargetID)
    case onboardingTest
    case copyOnly
}

public enum DeliveryPreference: String, Codable, Sendable { case automaticPaste, copyOnly }
public enum ShortcutMode: String, Codable, Sendable { case toggle, holdToTalk }

public struct UserSettings: Equatable, Codable, Sendable {
    public var launchAtLogin: Bool
    public var showFloatingRecorder: Bool
    public var recognition: RecognitionConfiguration
    public var speechModelID: String
    public var outputModes: [OutputMode]
    public var selectedOutputModeID: UUID
    public var providerProfiles: [ProviderProfile]
    public var selectedProviderProfileID: UUID?
    public var shortcutMode: ShortcutMode
    public var historyEnabled: Bool
    public var deliveryPreference: DeliveryPreference
    public var onboardingCompletedV2: Bool
    public var onboardingStep: Int
    public init(launchAtLogin: Bool, showFloatingRecorder: Bool, recognition: RecognitionConfiguration, speechModelID: String, outputModes: [OutputMode], selectedOutputModeID: UUID, providerProfiles: [ProviderProfile], selectedProviderProfileID: UUID?, shortcutMode: ShortcutMode, historyEnabled: Bool, deliveryPreference: DeliveryPreference, onboardingCompletedV2: Bool, onboardingStep: Int) {
        self.launchAtLogin = launchAtLogin
        self.showFloatingRecorder = showFloatingRecorder
        self.recognition = recognition
        self.speechModelID = speechModelID
        self.outputModes = outputModes
        self.selectedOutputModeID = selectedOutputModeID
        self.providerProfiles = providerProfiles
        self.selectedProviderProfileID = selectedProviderProfileID
        self.shortcutMode = shortcutMode
        self.historyEnabled = historyEnabled
        self.deliveryPreference = deliveryPreference
        self.onboardingCompletedV2 = onboardingCompletedV2
        self.onboardingStep = onboardingStep
    }
    public static let p0Default = UserSettings(
        launchAtLogin: false, showFloatingRecorder: true, recognition: .automatic,
        speechModelID: "small", outputModes: [.raw], selectedOutputModeID: OutputMode.rawID,
        providerProfiles: [], selectedProviderProfileID: nil, shortcutMode: .toggle,
        historyEnabled: true, deliveryPreference: .automaticPaste,
        onboardingCompletedV2: false, onboardingStep: 0
    )
}

public final class SessionSecret: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let lock = NSLock()
    private var bytes: Data
    public init(utf8: String) { self.bytes = Data(utf8.utf8) }
    private init(bytes: Data) { self.bytes = bytes }
    public func copy() -> SessionSecret { lock.withLock { SessionSecret(bytes: bytes) } }
    public func withUTF8<T>(_ body: (String) throws -> T) throws -> T {
        try lock.withLock {
            guard let value = String(data: bytes, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
            return try body(value)
        }
    }
    public func clear() { lock.withLock { bytes.resetBytes(in: 0..<bytes.count); bytes.removeAll() } }
    public var description: String { "<SessionSecret>" }
    public var debugDescription: String { "<SessionSecret>" }
    deinit { clear() }
}

public struct SessionSnapshot: Sendable {
    public let id: SessionID
    public let startedAt: Date
    public let target: DeliveryTarget
    public let recognition: RecognitionConfiguration
    public let speechModelID: String
    public let outputMode: OutputMode
    public let provider: ProviderSelection?
    public let historyGeneration: UInt64
    public let historyEnabled: Bool
    public let deliveryPreference: DeliveryPreference
    public let credential: SessionSecret?
    public init(id: SessionID, startedAt: Date = Date(), target: DeliveryTarget, recognition: RecognitionConfiguration, speechModelID: String, outputMode: OutputMode, provider: ProviderSelection?, historyGeneration: UInt64, historyEnabled: Bool, deliveryPreference: DeliveryPreference, credential: SessionSecret?) {
        self.id = id
        self.startedAt = startedAt
        self.target = target
        self.recognition = recognition
        self.speechModelID = speechModelID
        self.outputMode = outputMode
        self.provider = provider
        self.historyGeneration = historyGeneration
        self.historyEnabled = historyEnabled
        self.deliveryPreference = deliveryPreference
        self.credential = credential
    }
}
```

- [ ] **Step 4: Verify and commit**

```bash
swift test --package-path Packages/UtterInkKit --filter SessionSnapshotTests
swift test --package-path Packages/UtterInkKit
git add Packages/UtterInkKit
git commit -m "feat: add immutable session snapshots"
```

Expected: PASS.

---

### Task 3: Pure reducer and service protocols

**Files:**
- Create: `Packages/UtterInkKit/Sources/UtterInkCore/Pipeline/DictationIntent.swift`
- Create: `Packages/UtterInkKit/Sources/UtterInkCore/Pipeline/DictationEffect.swift`
- Create: `Packages/UtterInkKit/Sources/UtterInkCore/Pipeline/ServiceProtocols.swift`
- Create: `Packages/UtterInkKit/Sources/UtterInkCore/Domain/AppClock.swift`
- Create: `Packages/UtterInkKit/Sources/UtterInkServices/System/SystemAppClock.swift`
- Create: `Packages/UtterInkKit/Sources/UtterInkServices/Permissions/SystemPermissionService.swift`
- Create: `Packages/UtterInkKit/Sources/UtterInkServices/Hotkey/KeyboardShortcutsHotkeyService.swift`
- Test: `Packages/UtterInkKit/Tests/UtterInkServicesTests/SystemPermissionServiceTests.swift`
- Test: `Packages/UtterInkKit/Tests/UtterInkServicesTests/HotkeyServiceTests.swift`
- Create: `Packages/UtterInkKit/Sources/UtterInkCore/Pipeline/DictationReducer.swift`
- Test: `Packages/UtterInkKit/Tests/UtterInkCoreTests/DictationReducerTests.swift`

**Interfaces:**
- Produces: `AppClock`, `RecordingTelemetry`, `SessionPresentationContext`, `DictationIntent`, `DictationEffect`, `ReducerContext`, `Reduction`, `DictationReducer.reduce(state:intent:context:)`, and all service protocols consumed by Task 10.

- [ ] **Step 1: Write transition and ordering tests**

```swift
import XCTest
@testable import UtterInkCore

final class DictationReducerTests: XCTestCase {
    private let snapshot = SessionSnapshot(
        id: SessionID(), target: .copyOnly, recognition: .fixed(languageCode: "en"),
        speechModelID: "small",
        outputMode: OutputMode(id: UUID(), title: "Polish", skipsPolishing: false, instructions: "clean"),
        provider: nil, historyGeneration: 1, historyEnabled: true,
        deliveryPreference: .copyOnly, credential: nil
    )

    func testTranscriptionPersistsRawBeforePolishing() {
        let state = PipelineState(stage: .transcribing, sessionID: snapshot.id, token: EffectToken(sessionID: snapshot.id, generation: 4), result: nil, failure: nil)
        let reduction = DictationReducer.reduce(state: state, intent: .transcriptionSucceeded(" raw "), context: .polishing)
        XCTAssertEqual(reduction.state.result?.rawText, "raw")
        XCTAssertEqual(reduction.effects.map(\.kind), [.persistRaw])
    }

    func testCancelAfterRawNeverDelivers() {
        let result = DictationResult(sessionID: snapshot.id, rawText: "raw", finalText: "raw", source: .raw, warning: nil, delivery: nil)
        let state = PipelineState(stage: .polishing, sessionID: snapshot.id, token: EffectToken(sessionID: snapshot.id, generation: 8), result: result, failure: nil)
        let reduction = DictationReducer.reduce(state: state, intent: .cancel, context: .polishing)
        XCTAssertEqual(reduction.state.stage, .completed)
        XCTAssertEqual(reduction.state.result?.warning, .cancelled)
        XCTAssertFalse(reduction.effects.contains { $0.kind == .deliver })
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run `swift test --package-path Packages/UtterInkKit --filter DictationReducerTests`.

Expected: compile failure for missing reducer types.

- [ ] **Step 3: Implement intent/effect contracts and reducer**

Use these exact cases:

```swift
public struct RecordingHandle: Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}
public enum PermissionState: Equatable, Sendable { case notDetermined, denied, granted }

public enum DictationIntent: Sendable {
    case start(SessionSnapshot)
    case microphoneResolved(PermissionState)
    case recordingStarted(RecordingHandle)
    case recordingStartFailed(DiagnosticCode)
    case stopRequested
    case audioFinalized(URL)
    case audioFinalizationFailed(DiagnosticCode)
    case transcriptionSucceeded(String)
    case transcriptionFailed(DiagnosticCode)
    case rawPersisted
    case rawPersistenceFailed(DiagnosticCode)
    case polishSucceeded(String)
    case polishFailed(DiagnosticCode)
    case finalPersisted
    case finalPersistenceFailed(DiagnosticCode)
    case deliveryFinished(DeliveryOutcome)
    case deliveryPersisted
    case deliveryPersistenceFailed(DiagnosticCode)
    case cancel
    case acknowledge
}

public enum DictationEffectKind: Equatable, Sendable {
    case requestMicrophone, startRecording, stopRecording, transcribe, persistRaw, polish, persistFinal, deliver, persistDelivery, cleanup
}

public struct DictationEffect: Sendable {
    public let kind: DictationEffectKind
    public let token: EffectToken
    public let payload: Payload
    public enum Payload: Sendable {
        case none
        case recording(RecordingHandle)
        case audio(URL)
        case text(String)
    }
    public init(kind: DictationEffectKind, token: EffectToken, payload: Payload) {
        self.kind = kind
        self.token = token
        self.payload = payload
    }
}

public struct ReducerContext: Equatable, Sendable {
    public let skipsPolishing: Bool
    public let historyEnabled: Bool
    public init(skipsPolishing: Bool, historyEnabled: Bool) {
        self.skipsPolishing = skipsPolishing
        self.historyEnabled = historyEnabled
    }
    public static let raw = ReducerContext(skipsPolishing: true, historyEnabled: true)
    public static let polishing = ReducerContext(skipsPolishing: false, historyEnabled: true)
    public static let polishingWithoutHistory = ReducerContext(skipsPolishing: false, historyEnabled: false)
}

public struct Reduction: Sendable {
    public let state: PipelineState
    public let effects: [DictationEffect]
    public init(state: PipelineState, effects: [DictationEffect]) {
        self.state = state
        self.effects = effects
    }
}
```

`DictationReducer.reduce` must implement the complete transition table below. The controller derives `ReducerContext` once from the immutable snapshot and passes it on every reduction; the reducer never reads mutable settings. Every emitted effect carries the current token.

| Current stage | Intent / condition | Next stage | Ordered effects and payload source |
|---|---|---|---|
| `idle`, `completed`, `failed` | `start(snapshot)` after controller cleanup gate | `requestingPermission` | `requestMicrophone(.none)` |
| `requestingPermission` | `microphoneResolved(.granted)` | `requestingPermission` | `startRecording(.none)` |
| `requestingPermission` | `microphoneResolved(.denied/.notDetermined)` | `failed(permissionMicrophone)` | `cleanup(.none)` |
| `requestingPermission` | `recordingStarted(handle)` | `recording` | none; controller retains handle |
| `requestingPermission` | `recordingStartFailed(code)` | `failed(code)` | `cleanup(.none)` |
| `recording` | `stopRequested` | `stopping` | `stopRecording(.recording(currentHandle))` |
| `stopping` | `audioFinalized(url)` | `transcribing` | `transcribe(.audio(url))` using snapshot model lease/language |
| `stopping` | `audioFinalizationFailed(code)` | `failed(code)` | `cleanup(.none)` |
| `transcribing` | `transcriptionSucceeded(text)` non-empty, history enabled | `transcribing` | set volatile raw/final result; `persistRaw(.text(trimmed))` |
| `transcribing` | `transcriptionSucceeded(text)` non-empty, history disabled + raw context | `delivering` | set volatile raw/final result; `deliver(.text(trimmed))` |
| `transcribing` | `transcriptionSucceeded(text)` non-empty, history disabled + polishing context | `polishing` | set volatile raw/final result; `polish(.text(trimmed))` |
| `transcribing` | `transcriptionSucceeded` empty or `transcriptionFailed(code)` | `failed(transcriptionEmpty/code)` | `cleanup(.none)` |
| `transcribing` | `rawPersisted`, raw context | `delivering` | mark persistent; `deliver(.text(finalText))` |
| `transcribing` | `rawPersisted`, polishing context | `polishing` | mark persistent; `polish(.text(rawText))` |
| `transcribing` | `rawPersistenceFailed(code)` | `failed(code)` with volatile recoverable raw | `cleanup(.none)`; no network/delivery |
| `polishing` | `polishSucceeded(non-empty text)`, history enabled | `polishing` | select polished; `persistFinal(.text(polished))` |
| `polishing` | `polishSucceeded(non-empty text)`, history disabled | `delivering` | select polished; `deliver(.text(polished))` |
| `polishing` | `polishSucceeded(empty)` or `polishFailed(code)`, history enabled | `polishing` | select raw fallback with sanitized warning; `persistFinal(.text(raw))` |
| `polishing` | `polishSucceeded(empty)` or `polishFailed(code)`, history disabled | `delivering` | select raw fallback with sanitized warning; `deliver(.text(raw))` |
| `polishing` | `finalPersisted` | `delivering` | `deliver(.text(finalText))` |
| `polishing` | `finalPersistenceFailed(code)` | `failed(code)` with recoverable selected text | `cleanup(.none)`; no delivery |
| `delivering` | `deliveryFinished(outcome)`, history enabled | `delivering` | store outcome in result; `persistDelivery(.none)` |
| `delivering` | `deliveryFinished(outcome)`, history disabled | `completed` | store outcome; `cleanup(.none)` |
| `delivering` | `deliveryPersisted` | `completed` | `cleanup(.none)` |
| `delivering` | `deliveryPersistenceFailed(historyWrite)` | `completed` with history warning | `cleanup(.none)`; never deliver twice |
| `requestingPermission` through `delivering` | `cancel` before a raw result | `idle` | cancel current effect; `cleanup(.none)` |
| `transcribing` through `delivering` | `cancel` after raw result exists | `completed` with `cancelled` warning | cancel current effect; `cleanup(.none)`; no downstream automation |
| `completed`, `failed` | `acknowledge` | `idle` | none (terminal cleanup already completed) |

All unlisted `PipelineStage × DictationIntent` pairs return byte-for-byte equal state and zero effects. A table-driven test enumerates every enum case and uses this table as its fixture, asserting next stage, failure/result mutation, exact effect order/kind/payload, and invalid-pair no-op behavior. Add focused raw/polishing and history-enabled/disabled context tests.

- [ ] **Step 4: Define service protocols in one dependency boundary**

Add the exact protocols from the implementation index plus:

```swift
public protocol SettingsStore: Sendable {
    func current() async throws -> UserSettings
    func save(_ settings: UserSettings) async throws
}
public protocol TargetSnapshotService: Sendable { func snapshotTarget() async -> DeliveryTarget }
public protocol PermissionService: Sendable {
    func microphoneState() async -> PermissionState
    func accessibilityState() async -> PermissionState
}
public protocol DiagnosticsSink: Sendable { func record(stage: PipelineStage, code: DiagnosticCode?) async }
```

`AppClock` exposes `now: Date` plus cancellable `sleep(for: Duration)`. Add `SystemAppClock` in Services and a deterministic advancing fake in test support; controller timestamps, recording elapsed presentation, delivery settle timing, approval-expiry tests, and retry timing use this protocol rather than `Date()`, `Task.sleep`, or wall-clock sleeps.

Implement `SystemPermissionService` through injected AV/AX query clients so tests read granted/denied/not-determined without displaying prompts. Implement the hotkey adapter's public `Event.startRequested/stopRequested`, `ShortcutMode.toggle/holdToTalk`, probe stream, and callback initializer now; it emits intents/events and owns no recording boolean. Service tests cover toggle, hold-to-talk, repeat-key suppression, shortcut conflicts, probe delivery, teardown, and MainActor callback isolation.

- [ ] **Step 5: Verify and commit**

```bash
swift test --package-path Packages/UtterInkKit --filter DictationReducerTests
swift test --package-path Packages/UtterInkKit --filter SystemPermissionServiceTests
swift test --package-path Packages/UtterInkKit --filter HotkeyServiceTests
swift test --package-path Packages/UtterInkKit
git add Packages/UtterInkKit
git commit -m "feat: add authoritative dictation reducer"
```

---

### Task 4: Versioned local history with privacy generations

**Files:**
- Create: `Packages/UtterInkKit/Sources/UtterInkCore/History/HistoryModels.swift`
- Create: `Packages/UtterInkKit/Sources/UtterInkServices/Storage/JSONHistoryStore.swift`
- Test: `Packages/UtterInkKit/Tests/UtterInkServicesTests/JSONHistoryStoreTests.swift`

**Interfaces:**
- Produces: `HistoryRecord`, `HistoryOutcome`, and the `HistoryStore` implementation used by Task 10.

- [ ] **Step 1: Write actor tests for ordering, cap, generation, and tombstones**

```swift
import XCTest
import UtterInkCore
@testable import UtterInkServices

final class JSONHistoryStoreTests: XCTestCase {
    func testCapsByOriginalStartDateAndRejectsStaleGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try JSONHistoryStore(directory: directory, enabled: true, clock: TestClock())
        let generation = await store.generation()
        for index in 0..<21 {
            let record = HistoryRecord(sessionID: SessionID(), startedAt: Date(timeIntervalSince1970: TimeInterval(index)), rawText: "raw-\(index)", finalText: nil, source: .raw, warning: nil, delivery: nil, outcome: .rawSaved)
            try await store.appendRaw(record, expectedGeneration: generation)
        }
        let loaded = try await store.load()
        XCTAssertEqual(loaded.count, 20)
        _ = try await store.setEnabled(false)
        let stale = HistoryRecord(sessionID: SessionID(), startedAt: Date(), rawText: "stale", finalText: nil, source: .raw, warning: nil, delivery: nil, outcome: .rawSaved)
        await XCTAssertThrowsErrorAsync { try await store.appendRaw(stale, expectedGeneration: generation) }
    }

    func testDeleteTombstonePreventsLateUpdate() async throws {
        let store = try JSONHistoryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), enabled: true, clock: TestClock())
        let generation = await store.generation()
        let record = HistoryRecord(sessionID: SessionID(), startedAt: Date(), rawText: "raw", finalText: nil, source: .raw, warning: nil, delivery: nil, outcome: .rawSaved)
        try await store.appendRaw(record, expectedGeneration: generation)
        try await store.delete(sessionID: record.sessionID)
        await XCTAssertThrowsErrorAsync {
            try await store.updateResult(sessionID: record.sessionID, finalText: "late", source: .polished, warning: nil, delivery: .pasteEventDispatched, outcome: .delivered, expectedGeneration: generation)
        }
    }
}
```

Add an async `XCTAssertThrowsErrorAsync` test helper in the same test target. Add deterministic cases for disable → enable generation changes, clear/delete racing an awaited update, corrupt and truncated envelopes, unsupported schema, disk-full/write failure, permission denial, backup recovery, and two-process/single-instance locking. None may recreate a disabled/cleared/deleted record.

- [ ] **Step 2: Run to verify failure**

Run `swift test --package-path Packages/UtterInkKit --filter JSONHistoryStoreTests`.

Expected: compile failure for missing history types/store.

- [ ] **Step 3: Implement records and the versioned envelope**

```swift
public enum HistoryOutcome: String, Codable, Sendable { case rawSaved, finalized, delivered, cancelled, failed }

public struct HistoryRecord: Identifiable, Equatable, Codable, Sendable {
    public var id: SessionID { sessionID }
    public let sessionID: SessionID
    public let startedAt: Date
    public let rawText: String
    public var finalText: String?
    public var source: ResultSource
    public var warning: DiagnosticCode?
    public var delivery: DeliveryOutcome?
    public var outcome: HistoryOutcome
    public init(sessionID: SessionID, startedAt: Date, rawText: String, finalText: String?, source: ResultSource, warning: DiagnosticCode?, delivery: DeliveryOutcome?, outcome: HistoryOutcome) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.rawText = rawText
        self.finalText = finalText
        self.source = source
        self.warning = warning
        self.delivery = delivery
        self.outcome = outcome
    }
}

struct HistoryEnvelope: Codable {
    let schemaVersion: Int
    var generation: UInt64
    var enabled: Bool
    var records: [HistoryRecord]
    var tombstones: Set<SessionID>
}
```

Implement `public actor JSONHistoryStore: HistoryStore` with these exact invariants:

- file path `Application Support/UtterInk/history-v1.json` in production, injected directory in tests;
- mode `0700` directory and `0600` file/temp verification;
- decode schema version `1`; on corrupt data preserve the original file and throw `HistoryStoreError.corrupt`;
- append/update require matching generation and enabled state; `updateResult` persists final text, source, sanitized fallback warning, delivery result, and lifecycle outcome without replacing immutable raw/start fields;
- every `setEnabled(_:)` transition and `clear()` increments generation; disabling preserves existing records but rejects all older/new persistent writes immediately, enabling accepts only sessions created against the new generation; clear empties records/tombstones; delete adds a tombstone;
- append sorts by `startedAt` and keeps the newest 20 original session IDs; tombstones remain for the entire process lifetime and are never guessed safe to remove while a task could still complete;
- startup takes an exclusive single-instance file lock, proves no prior process operation survives, then prunes persisted tombstones before serving calls; a second process fails closed rather than writing concurrently;
- encode to a sibling temp file, synchronize the file descriptor, replace atomically, then synchronize the parent directory;
- never write audio, target, provider URL, prompt, credential, or logs.

- [ ] **Step 4: Verify and commit**

```bash
swift test --package-path Packages/UtterInkKit --filter JSONHistoryStoreTests
swift test --package-path Packages/UtterInkKit
git add Packages/UtterInkKit
git commit -m "feat: add privacy-safe local history"
```

---

### Task 5: Keychain credentials and legacy plaintext migration

**Files:**
- Create: `docs/provenance/legacy-defaults-map.tsv`
- Create: `Scripts/generate-legacy-defaults-map.swift`
- Generate: `Packages/UtterInkKit/Sources/UtterInkServices/Generated/LegacyDefaultsMap.generated.swift`
- Create: `Packages/UtterInkKit/Sources/UtterInkServices/Security/KeychainCredentialStore.swift`
- Create: `Packages/UtterInkKit/Sources/UtterInkServices/Security/LegacyCredentialMigrator.swift`
- Create: `Packages/UtterInkKit/Sources/UtterInkServices/Storage/LegacyDefaultsReader.swift`
- Create: `Packages/UtterInkKit/Sources/UtterInkServices/Storage/UserDefaultsSettingsStore.swift`
- Test: `Packages/UtterInkKit/Tests/UtterInkServicesTests/LegacyCredentialMigratorTests.swift`
- Test: `Tests/Scripts/test-generate-legacy-defaults-map.sh`

**Interfaces:**
- Consumes: audited `docs/provenance/legacy-defaults-map.tsv`, legacy defaults domain `dev.flowtype.FlowType`, and keys `llmProviderProfilesV1`, `llmP.<UUID>.apiKey`, `openRouterApiKey`, `minimaxApiKey`.
- Produces: Keychain service `dev.utterink.UtterInk.provider-credentials`, account `<profile UUID>`, `CredentialMigrationResult`, and explicit conflict resolution that never reveals either value.

- [ ] **Step 1: Freeze the audited legacy mapping and write migration tests**

Read the imported hash-locked legacy snapshot, then create a committed TSV with columns `legacy_domain`, `legacy_key_or_pattern`, `value_shape`, `profile_mapping`, `legacy_bundle_id`, `new_bundle_id`, `legacy_sandboxed`, `keychain_access_group`, `evidence_path`, and `evidence_hash`. It must record:

```text
dev.flowtype.FlowType  llmProviderProfilesV1    non-secret provider profile JSON
dev.flowtype.FlowType  llmP.<UUID>.apiKey       profile-scoped plaintext secret
dev.flowtype.FlowType  openRouterApiKey         legacy OpenRouter plaintext secret
dev.flowtype.FlowType  minimaxApiKey            legacy MiniMax plaintext secret
```

Record legacy/new bundle IDs, that P0 uses no shared Keychain access group, and the signing/sandbox assumptions that may make the old domain inaccessible. A test hashes the cited imported evidence paths and rejects map drift or an undocumented secret-looking key.

The map resolves `llmP.<UUID>.apiKey` directly to that profile UUID. It resolves each global `openRouterApiKey`/`minimaxApiKey` only to the unique migrated non-secret profile of the matching provider; zero or multiple candidates returns `.conflict` and never guesses/duplicates a secret.

`generate-legacy-defaults-map.swift` validates/canonicalizes the TSV and emits immutable `LegacyDefaultsMap.bundled` Swift source plus the authority TSV SHA-256. `test-generate-legacy-defaults-map.sh` covers duplicates, unknown keys, incomplete rights/evidence, escaping, deterministic ordering, and two byte-identical runs. `--check` regenerates to a temporary file and compares both source and embedded authority hash. Production initializers use `.bundled`; no installed app tries to read `docs/` or a repository path.

After the audit TSV is final, run `swift Scripts/generate-legacy-defaults-map.swift --emit --input docs/provenance/legacy-defaults-map.tsv --swift-output Packages/UtterInkKit/Sources/UtterInkServices/Generated/LegacyDefaultsMap.generated.swift`, then use only `--check` in CI.

Then write migration tests for every mapped key/pattern and for absent, equal, conflict, inaccessible, write failure, readback mismatch, explicit keep-secure, and explicit replace-secure cases:

```swift
func testMigratesAndDeletesPlaintextOnlyAfterReadbackMatch() async throws {
    let profile = UUID()
    let legacy = FakeLegacyDefaults(values: ["llmP.\(profile.uuidString).apiKey": "secret"])
    let keychain = FakeCredentialStore()
    let migrator = try LegacyCredentialMigrator(legacy: legacy, credentials: keychain)
    let result = await migrator.migrate(profileID: profile)
    XCTAssertEqual(result, .migrated)
    XCTAssertNil(legacy.value(forKey: "llmP.\(profile.uuidString).apiKey"))
}

func testConflictKeepsBothAndBlocksPolishing() async throws {
    let profile = UUID()
    let legacy = FakeLegacyDefaults(values: ["llmP.\(profile.uuidString).apiKey": "legacy"])
    let keychain = FakeCredentialStore(values: [profile: SessionSecret(utf8: "current")])
    let migrator = try LegacyCredentialMigrator(legacy: legacy, credentials: keychain)
    let result = await migrator.migrate(profileID: profile)
    XCTAssertEqual(result, .conflict)
    XCTAssertEqual(legacy.value(forKey: "llmP.\(profile.uuidString).apiKey"), "legacy")
}
```

- [ ] **Step 2: Run to verify failure**

Run `swift test --package-path Packages/UtterInkKit --filter LegacyCredentialMigratorTests`.

Expected: compile failure.

- [ ] **Step 3: Implement Keychain CRUD through an injectable client**

Use `kSecClassGenericPassword`, service `dev.utterink.UtterInk.provider-credentials`, UTF-8 profile UUID account, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, and `SecItemAdd`/`SecItemUpdate`/`SecItemCopyMatching`/`SecItemDelete`. Map `errSecItemNotFound` to nil and every other status to a sanitized `KeychainError(status:)`; never include the secret in an error.

Define:

```swift
public enum CredentialMigrationResult: Equatable, Sendable { case noLegacyValue, migrated, alreadySecure, conflict, inaccessible }
public enum CredentialConflictChoice: Equatable, Sendable { case keepSecure, replaceSecureWithLegacy }
```

`LegacyDefaultsReader` reads the audited domain explicitly with `persistentDomain(forName:)` and removes only a mapped key from that same domain; it never assumes renamed-app defaults visibility or creates a new suite as a side effect. Define package-internal `LegacyDefaultsAccess` for read/remove operations; the concrete reader conforms, the public migrator initializer remains the exact `LegacyDefaultsReader` signature in the implementation index, and an internal initializer accepts `any LegacyDefaultsAccess` for `@testable` fakes. `LegacyCredentialMigrator: CredentialMigrationService` must write then read back and compare in memory before calling the access seam's remove operation. Existing-equal values remove plaintext; existing-different values return `.conflict`; write/read failures return `.inaccessible`; plaintext is never used as a runtime credential after migration starts.

Define `CredentialConflictChoice.keepSecure` and `.replaceSecureWithLegacy`. Conflict resolution requires an explicit UI intent: keep-secure re-reads the secure item, then removes plaintext; replace-secure writes the legacy value, reads back an exact match, clears the in-memory legacy bytes, then removes plaintext. Any failure retains plaintext for recovery, blocks polishing for that profile, and leaves Raw usable. Inaccessible values cannot be resolved until access is restored or the user explicitly enters a replacement key; no API returns either secret to UI.

`UserDefaultsSettingsStore` implements both `current()` and atomic `save(_:)`, migrates non-secret provider profiles, output modes, selected model/language, shortcut mode, launch/floating preferences, onboarding progress, and history preference into the new domain, but excludes every `.apiKey` key.

- [ ] **Step 4: Verify and commit**

```bash
bash Tests/Scripts/test-generate-legacy-defaults-map.sh
swift Scripts/generate-legacy-defaults-map.swift --check --input docs/provenance/legacy-defaults-map.tsv --swift-output Packages/UtterInkKit/Sources/UtterInkServices/Generated/LegacyDefaultsMap.generated.swift
swift test --package-path Packages/UtterInkKit --filter LegacyCredentialMigratorTests
swift test --package-path Packages/UtterInkKit
git add docs/provenance/legacy-defaults-map.tsv Scripts/generate-legacy-defaults-map.swift Tests/Scripts/test-generate-legacy-defaults-map.sh Packages/UtterInkKit
git commit -m "feat: migrate provider secrets to Keychain"
```

---

### Task 6: Secure endpoint policy and OpenAI-compatible client

**Files:**
- Create: `Packages/UtterInkKit/Sources/UtterInkServices/Polishing/EndpointValidator.swift`
- Create: `Packages/UtterInkKit/Sources/UtterInkServices/Polishing/SecureRedirectDelegate.swift`
- Create: `Packages/UtterInkKit/Sources/UtterInkServices/Polishing/OpenAICompatibleClient.swift`
- Test: `Packages/UtterInkKit/Tests/UtterInkServicesTests/EndpointValidatorTests.swift`
- Test: `Packages/UtterInkKit/Tests/UtterInkServicesTests/OpenAICompatibleClientTests.swift`
- Create: `Tests/ATSPolicyProbe/ATSPolicyProbeApp.swift`
- Create: `Tests/ATSPolicyProbe/Info.plist`
- Create: `Tests/Scripts/test-ats-policy.sh`
- Create: `docs/provenance/ats-policy.md`
- Modify only if the signed probe proves necessary: `App/Supporting/Info.plist`
- Modify: `project.yml`
- Generate: `UtterInk.xcodeproj/**`

**Interfaces:**
- Produces: `ValidatedEndpoint`, `EndpointValidator.validate(_:)`, and `OpenAICompatibleClient: PolishingService & ProviderValidationService`.

- [ ] **Step 1: Write the endpoint security matrix**

```swift
let accepted = ["https://api.example.com/v1", "http://localhost:11434/v1", "http://127.0.0.1:11434/v1", "http://[::1]:11434/v1"]
let rejected = ["http://api.example.com/v1", "http://192.168.1.2:11434/v1", "http://2130706433/v1", "http://0x7f000001/v1", "https://user:pass@example.com/v1", "https://example.com/v1?key=x", "https://example.com/v1#fragment"]
for value in accepted { XCTAssertNoThrow(try EndpointValidator.validate(value)) }
for value in rejected { XCTAssertThrowsError(try EndpointValidator.validate(value)) }
```

Inject a `HostResolver` in endpoint tests. Prove that `localhost` returning only `127.0.0.1`/`::1` is rewritten to a selected literal-loopback request URL, and that empty, mixed loopback/non-loopback, IPv4-mapped non-loopback, or changed resolution is rejected. Write client tests using a custom `URLProtocol`: assert POST `/chat/completions`, bounded timeout/body, Authorization header only on the validated host, sanitized status mapping, empty/structured response rejection, and raw response text absent from errors.

- [ ] **Step 2: Run to verify failure**

```bash
swift test --package-path Packages/UtterInkKit --filter EndpointValidatorTests
swift test --package-path Packages/UtterInkKit --filter OpenAICompatibleClientTests
```

Expected: compile failure.

- [ ] **Step 3: Implement strict validation and ephemeral networking**

`EndpointValidator` must use `URLComponents`, require only `http`/`https`, reject user/password/query/fragment, normalize trailing slashes, preserve a base path such as `/v1`, and accept HTTP only for canonical `localhost`, dotted-decimal `127/8`, or literal `::1`. For `localhost`, resolve through an injected resolver, require every answer to be loopback, select a literal loopback address, and build the request URL against that literal so DNS cannot redirect the connection later. `ValidatedEndpoint` separately retains the sanitized original display host for privacy UI, never a path/query. Revalidate the connection literal immediately before request creation. Plain-HTTP redirects are disabled; HTTPS host changes are rejected before any Authorization header is attached.

`OpenAICompatibleClient` must:

- create `URLSessionConfiguration.ephemeral` with no cache/cookies/credential storage;
- set 30-second request and resource timeouts, a 2 MiB response limit, and one request at a time per session;
- construct JSON with `model`, system instructions, and raw user text;
- attach `Authorization: Bearer <secret>` immediately before dispatch;
- decode only `choices[0].message.content` string/text parts;
- trim, strip fenced output/known hidden-reasoning tags, and reject blank or residual JSON objects/arrays;
- map network/auth/429/5xx/decoding conditions to `DiagnosticCode` without response body or transcript.

It also conforms to `ProviderValidationService`. `validate(profile:credential:)` runs the same endpoint/redirect/ephemeral-session policy against `GET /models`, requires the configured model ID to appear in a bounded valid response, and returns only `.ready(normalizedHost:modelID:)` or `.failed(DiagnosticCode)`. It never returns/logs a response body, credential, URL path, or query. Add focused tests for ready, model-missing, auth, redirect, oversized body, and malformed response.

- [ ] **Step 4: Add the real ATS policy probe**

Add an XcodeGen `ATSPolicyProbe` macOS application target under `Tests/ATSPolicyProbe`, depending on `UtterInkServices`, whose ATS dictionary is generated from the same policy as the app. Start with no ATS exception. The probe accepts one loopback URL, performs one ephemeral request through the production validated client transport, prints only `ATS_LOOPBACK_PASS` or a sanitized diagnostic code, and exits. It contains no provider key or transcript fixture.

`Tests/Scripts/test-ats-policy.sh` must:

1. Start a repository-local Python HTTP fixture bound only to `127.0.0.1` on an ephemeral port.
2. Build the probe with ad-hoc signing enabled (`CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=`).
3. Require `codesign --verify --strict` to pass on the probe app.
4. Inspect the built app's effective `Info.plist` and fail if global arbitrary-load or domain exceptions exist.
5. Launch the signed probe against the loopback fixture and require `ATS_LOOPBACK_PASS`.
6. Stop the fixture and delete build/output state through a trap on every exit.

Run `bash Tests/Scripts/test-ats-policy.sh` with no exception. If and only if its captured system error proves ATS blocks supported loopback on the pinned supported runtime, add exactly `NSAppTransportSecurity.NSAllowsLocalNetworking=true` to both effective plists, rerun, and record the toolchain/error/before-after result in `docs/provenance/ats-policy.md`. The test always rejects `NSAllowsArbitraryLoads`, web-content exceptions, per-domain public exceptions, or any key beyond the objectively required local-network key. Endpoint tests still reject LAN/public HTTP before URLSession. This evidence-driven branch has exactly two accepted final plist shapes: no ATS dictionary, or local-network true only.

- [ ] **Step 5: Verify and commit**

```bash
swift test --package-path Packages/UtterInkKit --filter EndpointValidatorTests
swift test --package-path Packages/UtterInkKit --filter OpenAICompatibleClientTests
bash Tests/Scripts/test-ats-policy.sh
swift test --package-path Packages/UtterInkKit
git add Packages/UtterInkKit Tests/ATSPolicyProbe Tests/Scripts/test-ats-policy.sh docs/provenance/ats-policy.md App/Supporting/Info.plist project.yml UtterInk.xcodeproj
git commit -m "feat: add secure OpenAI-compatible polishing"
```

---

### Task 7: Transient audio and Whisper model/transcription adapters

**Files:**
- Create: `Config/speech-model-catalog.json`
- Create: `docs/provenance/speech-model-catalog.md`
- Create: `Scripts/lock-speech-model-catalog.swift`
- Generate: `Packages/UtterInkKit/Sources/UtterInkServices/Generated/SpeechModelCatalog.generated.swift`
- Create: `Packages/UtterInkKit/Sources/UtterInkServices/Audio/TransientAudioStore.swift`
- Create: `Packages/UtterInkKit/Sources/UtterInkServices/Audio/AVAudioRecordingService.swift`
- Create: `Packages/UtterInkKit/Sources/UtterInkServices/Speech/WhisperModelCatalog.swift`
- Create: `Packages/UtterInkKit/Sources/UtterInkServices/Speech/WhisperModelService.swift`
- Create: `Packages/UtterInkKit/Sources/UtterInkServices/Speech/WhisperTranscriber.swift`
- Test: `Packages/UtterInkKit/Tests/UtterInkServicesTests/TransientAudioStoreTests.swift`
- Test: `Packages/UtterInkKit/Tests/UtterInkServicesTests/WhisperModelServiceTests.swift`
- Test: `Packages/UtterInkKit/Tests/UtterInkServicesTests/SpeechModelCatalogTests.swift`
- Test: `Tests/Scripts/test-lock-speech-model-catalog.sh`

**Interfaces:**
- Produces: a locked model provenance catalog, `AVAudioRecordingService: AudioRecordingService`, `WhisperModelService: SpeechModelService`, `WhisperTranscriber: TranscriptionService`.

- [ ] **Step 1: Write catalog, transient-file, and stale-model-completion tests**

`SpeechModelCatalogTests` must reject any entry without an exact WhisperKit-facing model ID, immutable upstream revision/commit, source URL, license identifier and license URL, exact downloaded byte count, preset/Advanced placement, and macOS 14 Apple Silicon verification evidence reference. It requires exactly one Fast=`base`, Recommended=`small`, and Best Quality=`large-v3` mapping; Advanced is exactly the remaining entries in the committed catalog, not an independently hard-coded list.

`Tests/Scripts/test-lock-speech-model-catalog.sh` runs the generator against local HTTP/JSON fixtures and proves rejection of mutable revisions, redirects to unapproved hosts, unknown licenses, duplicate IDs/presets, size overflow, unsorted output, and non-deterministic timestamps. Two refreshes from identical fixtures must be byte-identical.

```swift
func testLaunchSweepDeletesOnlyOpaqueCAFChildren() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = try TransientAudioStore(root: root, clock: TestClock())
    let audio = try await store.createURL()
    try Data("audio".utf8).write(to: audio)
    try await store.sweep()
    XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
}

func testLateModelGenerationCannotReplaceCurrentModel() async throws {
    let backend = ControllableWhisperBackend()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let service = try WhisperModelService(backend: backend, root: root, clock: TestClock())
    let first = await service.prepare(modelID: "small", token: EffectToken(sessionID: SessionID(), generation: 1))
    let second = await service.prepare(modelID: "medium", token: EffectToken(sessionID: SessionID(), generation: 2))
    _ = (first, second)
    await backend.finish(modelID: "small")
    let state = await service.state()
    XCTAssertEqual(state, .loading(modelID: "medium"))
}
```

- [ ] **Step 2: Run to verify failure**

Run both focused test classes; expect compile failure.

- [ ] **Step 3: Implement adapters**

- `TransientAudioStore` uses `Application Support/UtterInk/TransientAudio`, mode `0700`, backup exclusion, opaque UUID `.caf` names, explicit delete, and launch/pre-capture orphan sweep. Documentation states normal APFS deletion is best-effort cleanup, not guaranteed secure erasure.
- `AVAudioRecordingService` adapts the rescued `AVAudioEngine` tap and `AVAudioApplication.requestRecordPermission`, but owns handles rather than booleans and always removes the tap/engine/file on cancel/failure.
- `lock-speech-model-catalog.swift` interrogates only WhisperKit 0.18.0-compatible official metadata and immutable upstream model manifests, resolves redirect-free HTTPS sources to immutable revisions, computes downloaded sizes, records license sources, and emits sorted JSON, a human provenance report, and immutable `WhisperModelCatalog.bundled` Swift source containing the authoritative JSON SHA-256. It fails closed on mutable-only revisions, unknown/missing licenses, or a failed preset. No model weight enters Git or the DMG.
- `WhisperModelCatalog` can decode injected data in tests; production uses compiled `.bundled` and exposes three presets: Fast=`base`, Recommended=`small`, Best Quality=`large-v3`; Advanced exposes exactly the other locked compatible entries. No installed app reads repository-root `Config`. The same authority JSON drives UI disk impact and third-party/model notices.
- `WhisperModelService` stores models under `Application Support/UtterInk/huggingface`. Define a package-internal `WhisperBackend` protocol and internal `init(backend:root:clock:)` for deterministic `@testable` fakes; the only public initializer remains `init(catalog:root:clock:)` from the implementation index and constructs the real WhisperKit backend. `prepare` returns its `AsyncStream<SpeechModelState>` immediately while a child task reports missing/downloading/loading/ready/failed; starting a newer preparation cancels/finishes the older stream and generation-checks every emission. It issues a `SpeechModelLease` only for the exact ready model ID, retains that model until the lease is released, and deletes cache only for an inactive/non-preparing model.
- `WhisperTranscriber` resolves only the exact leased model instance, rejects a lease/model/token mismatch, maps `.fixed`/`.automatic` to `DecodingOptions`, joins/trim results, and throws `.transcriptionEmpty` for whitespace-only text. The controller releases the lease in terminal cleanup on every path.

Add interrupted-download, checksum/size mismatch, retry, load failure, stale completion, lease retention/release, inactive cache deletion, active cache rejection, and exact disk-impact tests. Record the macOS 14 Apple Silicon smoke result for each shipped preset before this task's final gate; if a preset cannot be proven, stop rather than substituting an unreviewed model.

The generator CLI is exact:

```bash
swift Scripts/lock-speech-model-catalog.swift --refresh --whisperkit-version 0.18.0 --output Config/speech-model-catalog.json --report docs/provenance/speech-model-catalog.md --swift-output Packages/UtterInkKit/Sources/UtterInkServices/Generated/SpeechModelCatalog.generated.swift
swift Scripts/lock-speech-model-catalog.swift --check --input Config/speech-model-catalog.json --report docs/provenance/speech-model-catalog.md --swift-output Packages/UtterInkKit/Sources/UtterInkServices/Generated/SpeechModelCatalog.generated.swift
```

`--refresh` is the only network mode and writes all three outputs atomically only after all checks; `--check` is offline, canonicalizes into temporary files, compares JSON/report/generated Swift byte-for-byte, validates embedded authority/evidence hashes, and leaves the tree untouched. Archive/external-construction tests instantiate `.bundled` without the repository `Config` directory.

- [ ] **Step 4: Verify and commit**

```bash
swift test --package-path Packages/UtterInkKit --filter TransientAudioStoreTests
swift test --package-path Packages/UtterInkKit --filter WhisperModelServiceTests
swift test --package-path Packages/UtterInkKit --filter SpeechModelCatalogTests
bash Tests/Scripts/test-lock-speech-model-catalog.sh
swift Scripts/lock-speech-model-catalog.swift --check --input Config/speech-model-catalog.json --report docs/provenance/speech-model-catalog.md --swift-output Packages/UtterInkKit/Sources/UtterInkServices/Generated/SpeechModelCatalog.generated.swift
swift test --package-path Packages/UtterInkKit
git add Config/speech-model-catalog.json docs/provenance/speech-model-catalog.md Scripts/lock-speech-model-catalog.swift Tests/Scripts/test-lock-speech-model-catalog.sh Packages/UtterInkKit
git commit -m "feat: add local audio and Whisper services"
```

---

### Task 8: Target tracking and serialized safe delivery

**Files:**
- Create: `Packages/UtterInkKit/Sources/UtterInkServices/Delivery/TargetTracker.swift`
- Create: `Packages/UtterInkKit/Sources/UtterInkServices/Delivery/PasteboardClient.swift`
- Create: `Packages/UtterInkKit/Sources/UtterInkServices/Delivery/DeliveryCoordinator.swift`
- Create: `Packages/UtterInkKit/Sources/UtterInkServices/Delivery/InMemoryOnboardingTestSink.swift`
- Test: `Packages/UtterInkKit/Tests/UtterInkServicesTests/DeliveryCoordinatorTests.swift`

**Interfaces:**
- Produces: `TargetTracker: TargetSnapshotService` and `DeliveryCoordinator: DeliveryService`.

- [ ] **Step 1: Write adversarial delivery tests**

Cover these schedules with fakes: external app/window/element changes; pasteboard changes after snapshot and immediately before write; snapshot exceeds 16 MiB or 500 ms; second delivery requests the lease; dispatch fails after write; cancellation after write; user copies during the 250 ms settle window. Assert no target receives text after identity change and no newer pasteboard value is restored over.

Add a table-driven authorization matrix that distinguishes the independent snapshot fields. `.onboardingTest` always uses only the in-app sink. For every non-onboarding target, a snapshotted `.copyOnly` preference is a user pre-authorization to replace the clipboard once, without restoration or key dispatch, and returns `.copiedByPreference`. A `.automaticPaste` preference paired with `.copyOnly` target means safe target capture/revalidation was unavailable: it returns `.manualCopyRequired(.deliveryTargetUnavailable)` with byte-for-byte unchanged pasteboard state and zero event dispatch. Only `.automaticPaste` plus `.external` enters the guarded paste transaction. The tests must prove all four paths, exact pasteboard change counts, lease serialization, and that `.copiedByPreference` cannot be confused with the separate `.copiedByUser` explicit action.

Representative test:

```swift
func testUserCopyBeforeWriteAbortsWithoutMutation() async {
    let pasteboard = FakePasteboard(items: [.text("original")], changeCount: 1)
    let target = FakeTarget(valid: true)
    let coordinator = DeliveryCoordinator(pasteboard: pasteboard, target: target, onboardingSink: InMemoryOnboardingTestSink(), clock: TestClock())
    pasteboard.beforePrewriteCheck = { pasteboard.userCopy("new-user-copy") }
    let outcome = await coordinator.deliver(text: "result", to: .external(target.id), preference: .automaticPaste, token: target.token)
    XCTAssertEqual(outcome, .manualCopyRequired(.deliveryPasteboardChanged))
    XCTAssertEqual(pasteboard.string, "new-user-copy")
    XCTAssertEqual(target.dispatchCount, 0)
}
```

- [ ] **Step 2: Run to verify failure**

Run `swift test --package-path Packages/UtterInkKit --filter DeliveryCoordinatorTests`; expect compile failure.

- [ ] **Step 3: Implement the exact transaction**

`TargetTracker` is MainActor-isolated, monitors `NSWorkspace.didActivateApplicationNotification` and AX focused window/element changes, stores non-persisted `AXUIElement` references behind `DeliveryTargetID`, and invalidates IDs on external focus epoch changes.

`PasteboardClient` is MainActor-isolated, materializes readable types up to 16 MiB/500 ms, records `changeCount`, provides pre-write comparison, writes text, and restores captured bytes only if UtterInk still owns the count. Snapshot bytes have no debug description and are cleared after use.

`DeliveryCoordinator` is an actor whose one lease spans snapshot through cleanup. Its exact public entry point is `deliver(text:to:preference:token:)`; it evaluates `.onboardingTest` first, then the snapshotted preference, then the external-target transaction. The public initializer remains the exact concrete production signature in the implementation index; package-internal `PasteboardAccess` and `TargetValidating` protocols plus an internal initializer with the same dependency labels allow `@testable` fakes without exposing extra public API. For `.onboardingTest`, it bypasses workspace/AX/event/pasteboard code entirely, sends the result to the injected `OnboardingTestSink`, and returns `.deliveredToOnboardingTest`. For a non-onboarding `.copyOnly` preference, it serializes through the lease, replaces the clipboard once without restoration or event dispatch, and returns `.copiedByPreference`. For `.automaticPaste` with target `.copyOnly`, it performs zero pasteboard/AX/event mutation and returns `.manualCopyRequired(.deliveryTargetUnavailable)`. Only `.automaticPaste` with `.external` revalidates process/window/element before write and before dispatch, posts Command-V key down/up to the captured PID, waits an injected 250 ms, and runs guarded restoration exactly once from success or cancellation. Any unverifiable external target remains recoverable without touching the pasteboard. `copyExplicitly(text:token:)` is the separate point-in-time user-authorized path: it serializes through the same actor, replaces the clipboard without restoration, and returns `.copiedByUser`.

- [ ] **Step 4: Verify and commit**

```bash
swift test --package-path Packages/UtterInkKit --filter DeliveryCoordinatorTests
swift test --package-path Packages/UtterInkKit
git add Packages/UtterInkKit
git commit -m "feat: add target-aware safe delivery"
```

---

### Task 9: Allowlisted diagnostics and safe logging

**Files:**
- Create: `Packages/UtterInkKit/Sources/UtterInkServices/Diagnostics/DiagnosticsExporter.swift`
- Create: `Packages/UtterInkKit/Sources/UtterInkServices/Diagnostics/SafeLogger.swift`
- Create: `Packages/UtterInkKit/Sources/UtterInkServices/Diagnostics/SafeDiagnosticsSink.swift`
- Test: `Packages/UtterInkKit/Tests/UtterInkServicesTests/DiagnosticsRedactionTests.swift`

**Interfaces:**
- Produces: `DiagnosticsSnapshot`, `DiagnosticsExporter.export(_:) -> Data`, closed-input `SafeLogger`, and `SafeDiagnosticsSink: DiagnosticsSink` used by app composition.

- [ ] **Step 1: Write canary redaction tests**

Build surrounding fake errors containing `CANARY_TRANSCRIPT`, `CANARY_KEY`, `CANARY_PROMPT`, `https://host/private?key=CANARY`, pasteboard bytes, and response bodies. Export diagnostics and capture test logs; assert none of those substrings occur. Assert version/build, OS, architecture, permission states, model ID/state, provider host/model, stage, history enabled/count, and diagnostic codes do occur.

- [ ] **Step 2: Run to verify failure**

Run `swift test --package-path Packages/UtterInkKit --filter DiagnosticsRedactionTests`; expect compile failure.

- [ ] **Step 3: Implement allowlisted DTO/export/logger**

`DiagnosticsSnapshot` must contain only Codable bools/counts, closed enums, version strings from build metadata, normalized provider host, and a bounded provider-model identifier that has passed a dedicated diagnostic sanitizer. The sanitizer rejects URL/path/query/control forms, credential/token prefixes, high-entropy key-like values, and overlong input; rejected model IDs export `redacted-invalid-model-id`, never the raw value. The DTO must not accept `Error`, `URL`, `SessionSnapshot`, `HistoryRecord`, transcript, prompt, secret, pasteboard data, window title, or endpoint path/query. `DiagnosticsExporter` uses sorted/pretty JSON with schema version `1`.

Define closed `DiagnosticComponent` (`audio`, `speechModel`, `transcription`, `history`, `credential`, `polishing`, `delivery`, `permissions`) and `DiagnosticModelPhase` enums. `SafeLogger` exposes only `stageChanged(PipelineStage)`, `serviceFailed(component: DiagnosticComponent, code: DiagnosticCode)`, and `modelStateChanged(catalogIndex: Int, phase: DiagnosticModelPhase)`; it rejects out-of-range catalog indexes and all messages are static templates. No logger method accepts arbitrary `String`, `Error`, `URL`, or domain object. Canary tests exercise every permitted scalar/enum factory and assert sensitive strings cannot enter the DTO/logger; a source-policy test also rejects new `SafeLogger` method parameters of type `String`, `Error`, `URL`, `Data`, or `Any`.

`SafeDiagnosticsSink` conforms to the core `DiagnosticsSink`, maps each stage/code only through the closed logger API, and owns the bounded in-memory sanitized event counters used by `DiagnosticsExporter`. Its public initializer and conformance are compiled in the external-consumer test.

- [ ] **Step 4: Verify and commit**

```bash
swift test --package-path Packages/UtterInkKit --filter DiagnosticsRedactionTests
swift test --package-path Packages/UtterInkKit
git add Packages/UtterInkKit
git commit -m "feat: add privacy-safe diagnostics"
```

---

### Task 10: Main-actor session controller and end-to-end pipeline

**Files:**
- Create: `Packages/UtterInkKit/Sources/UtterInkCore/Pipeline/DictationSessionController.swift`
- Create: `Packages/UtterInkKit/Tests/UtterInkCoreTests/DictationSessionControllerTests.swift`
- Create: `Packages/UtterInkKit/Tests/UtterInkExternalConsumerTests/ExternalConstructionTests.swift`
- Modify: `Packages/UtterInkKit/Package.swift`
- Modify: `Packages/UtterInkKit/Sources/UtterInkCore/Pipeline/ServiceProtocols.swift`

**Interfaces:**
- Consumes: every protocol from Tasks 3–9.
- Produces: `@MainActor public protocol DictationControlling` plus `@MainActor @Observable public final class DictationSessionController: DictationControlling` with pipeline/result/telemetry/model catalog state and typed dictation/model-management methods.

- [ ] **Step 1: Write ordering, cancellation, and stale-completion integration tests**

Add a SwiftPM `UtterInkExternalConsumerTests` target depending on both library products. Its source uses only ordinary `import UtterInkCore` and `import UtterInkServices` and defines compile-time factory functions that call every exact public construction signature in the implementation index. It must not use `@testable`, SPI, reflection, or implementation-only imports; a missing/non-public initializer makes this task's first test run fail to compile. Runtime assertions instantiate `LegacyDefaultsMap.bundled` and `WhisperModelCatalog.bundled` after changing the working directory to an empty temporary directory, proving production does not depend on repository `docs/` or `Config/` paths and embedded authority hashes are present.

Use deterministic fakes and an event log. Required assertions:

```swift
XCTAssertEqual(log, ["volatile.raw", "history.appendRaw", "polish.request", "history.updateFinal", "delivery.request", "history.updateDelivery"])
```

Also prove: duplicate start creates no second task; model-not-ready creates no session; microphone denial fails with guidance; history failure stops network/delivery; polish failure delivers saved raw with warning; delivery-history failure does not dispatch twice; cancel at every await produces no later automation; generation-1 completion is ignored after generation-2 session starts; cleanup finishes before new start; bootstrap reloads persistent history; durable append/update/delete/clear refresh `historyRecords`; disable immediately invalidates in-flight writes, re-enable gets a new generation, and clear-history cancels active work and removes persistent/volatile results.

Prove the controller forwards both immutable delivery fields exactly: a session with external target plus `.copyOnly` preference records one `deliver(... preference: .copyOnly)` and completes with `.copiedByPreference`; a session whose target resolver returned `.copyOnly` plus `.automaticPaste` records one automatic-paste request and completes with `.manualCopyRequired(.deliveryTargetUnavailable)` while the delivery fake records zero pasteboard/event mutation. Change mutable delivery settings during transcription in both tests and assert the snapshotted preference still wins. An onboarding target must remain sink-only regardless of ordinary settings.

Add explicit result-action integration tests:

- `copyResult(id)` resolves the current final text (volatile overlay first, then persistent), calls `DeliveryService.copyExplicitly` exactly once, never schedules guarded restoration/automatic paste, and persists only the resulting `.copiedByUser` metadata when allowed.
- `pasteAgain(id)` resolves final text, captures a fresh current target through `TargetSnapshotService` (never the original non-persisted target), obtains a new action token, calls safe `deliver` exactly once with `.automaticPaste` regardless of the ordinary copy-only setting, respects delivery serialization/stale cancellation, and updates only delivery metadata—never creates a new original session/history row or reruns polishing. A fresh `.copyOnly` target therefore yields manual-copy-required with zero clipboard mutation.
- missing, deleted, or tombstoned IDs produce a sanitized recoverable action error and zero clipboard/network/history mutation.
- `deleteResult(id)` removes persistent and matching volatile state; a late copy/paste/retry completion cannot resurrect it.
- copy/paste-again racing the active session is serialized by `DeliveryCoordinator`, and cancellation cannot trigger duplicate delivery.

Add real-controller speech-model management tests with a call-logging `SpeechModelService` fake: `prepareSpeechModel(id)` consumes missing/downloading/loading/ready emissions in order; emissions from an older preparation generation are ignored; `cancelSpeechModelPreparation()` cancels/finishes the active stream exactly once; `deleteCachedSpeechModel(id)` forwards only for inactive/non-selected IDs; active/preparing deletion is rejected; and service failures publish only sanitized `SpeechModelState.failed`. A no-op implementation of any of the three public controller methods must fail these tests.

- [ ] **Step 2: Run to verify failure**

Run `swift test --package-path Packages/UtterInkKit --filter DictationSessionControllerTests`.

Expected: compile failure.

- [ ] **Step 3: Implement the controller as the only active-session authority**

Use `@MainActor` plus `@Observable`. Store one `Task<Void,Never>?`, current `SessionSnapshot?`, current `RecordingHandle?`, current `SpeechModelLease?`, `nextGeneration`, and `cleanupInProgress`. `bootstrap()` loads persistent `historyRecords`, current settings/model state, and performs no capture/network work. `send(.start(.focusedExternal))` resolves the current external/copy-only target; `send(.start(.onboardingTest))` uses only `.onboardingTest` and never captures or dispatches to an external app. Both check bootstrap/model readiness and cleanup barrier, resolve settings/credential/history generation into a snapshot with the injected clock's start time, increment generation, then feed the reducer. Execute reducer effects sequentially in a task; every completion calls `isCurrent(token)` before sending its resulting intent. The deliver effect passes both `snapshot.target` and `snapshot.deliveryPreference` to `DeliveryService`; it never infers authorization from the target enum or rereads mutable settings. Acquire a lease for the snapshot's exact speech model before transcription. Put transient raw text into `volatileResults` before calling history; on durable append, mark the corresponding result persistent and refresh `historyRecords`. Clear the session secret, release the model lease, and delete audio in one idempotent `finishCleanup` path.

`prepareSpeechModel` starts a controller-owned task that immediately consumes the service's `AsyncStream` into observable `speechModelState`; cancel/delete methods call only the typed service methods and publish sanitized failures. Recording level callbacks update `recordingTelemetry` on MainActor; telemetry and immutable `sessionPresentation` are set at session start and cleared only during terminal cleanup. Tests advance `AppClock` and prove elapsed/level/presentation values never read mutable current settings.

Use these public action shapes:

```swift
@MainActor
public protocol DictationControlling: AnyObject {
    var state: PipelineState { get }
    var speechModelState: SpeechModelState { get }
    var volatileResults: [DictationResult] { get }
    var historyRecords: [HistoryRecord] { get }
    var recordingTelemetry: RecordingTelemetry? { get }
    var sessionPresentation: SessionPresentationContext? { get }
    var speechModelCatalog: [SpeechModelDescriptor] { get }
    func bootstrap() async
    func send(_ intent: UserIntent)
    func prepareSpeechModel(_ modelID: String)
    func cancelSpeechModelPreparation()
    func deleteCachedSpeechModel(_ modelID: String)
}

public enum StartContext: Equatable, Sendable { case focusedExternal, onboardingTest }

public enum UserIntent: Equatable, Sendable {
    case start(StartContext)
    case stop
    case cancel
    case acknowledge
    case copyResult(SessionID)
    case pasteAgain(SessionID)
    case retryPolishing(SessionID)
    case deleteResult(SessionID)
    case setHistoryEnabled(Bool)
    case clearHistory
}
```

The controller retains up to 20 `volatileResults` for the process when history is disabled and labels them non-persistent through their model. Copy/Paste Again follow the tested action contracts above. Retry polishing snapshots current output/provider/credential, updates the same history record only after success, and cannot resurrect a tombstoned record.

- [ ] **Step 4: Run focused and whole-project regression**

```bash
swift test --package-path Packages/UtterInkKit --filter DictationSessionControllerTests
swift test --package-path Packages/UtterInkKit --filter ExternalConstructionTests
swift test --package-path Packages/UtterInkKit
./Scripts/ci-local.sh
```

Expected: all tests and builds pass; no network/key/microphone is required by unit tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/UtterInkKit
git commit -m "feat: orchestrate recoverable dictation sessions"
```

## Plan completion gate

```bash
swift test --package-path Packages/UtterInkKit
./Scripts/ci-local.sh
git status --short
```

Expected: zero failures, Xcode build succeeds, clean tree. Do not begin app UI wiring until this gate passes.
