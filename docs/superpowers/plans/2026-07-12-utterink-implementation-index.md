# UtterInk Implementation Plan Set

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver UtterInk `0.1.0` as a macOS 14+, Apple Silicon menu-bar dictation app with local Whisper transcription, optional secure OpenAI-compatible polishing, recoverable target-aware delivery, open-source project materials, and a signed/notarized DMG release path.

**Architecture:** A generated-but-committed standard Xcode macOS app target owns lifecycle, UI, `Info.plist`, assets, entitlements, signing, and packaging. A local Swift package exposes `UtterInkCore` for pure domain/orchestration code and `UtterInkServices` for macOS, WhisperKit, Keychain, file, URLSession, Accessibility, and pasteboard adapters. The existing FlowType working tree is imported only as a reviewed, hash-locked parity reference and removed from the final working tree after parity is proven.

**Tech Stack:** Xcode 26.4+, Swift 5 language mode under Swift 6.3, SwiftUI/AppKit, Observation, AVFoundation, ApplicationServices, Security, CoreGraphics/ImageIO, URLSession, WhisperKit 0.18.0, KeyboardShortcuts 2.4.0, Swift Package Manager, XcodeGen 2.45.4, XCTest, Bash.

## Global Constraints

- Product spelling is exactly `UtterInk`; local bundle identifier is `dev.utterink.UtterInk` and the legacy defaults domain is `dev.flowtype.FlowType`.
- Minimum deployment target is macOS 14.0; release architecture is `arm64`; Intel/Universal support is deferred.
- Local Whisper/WhisperKit transcription works without any API key; audio never leaves the Mac and is never retained as history.
- Optional polishing uses only a user-configured OpenAI-compatible endpoint/model; remote endpoints require HTTPS and explicit plain HTTP is loopback-only.
- Third-party source dependencies remain in Swift Package Manager; runtime versions are locked by committed `Package.resolved`.
- One authoritative dictation state machine owns the active session; menu, hotkey, floating UI, onboarding, settings, and history issue intents only.
- A non-empty raw transcript becomes recoverable before any polish request or pasteboard mutation.
- Persistent history is enabled by default, text-only, local, capped at 20 original sessions, immediately disableable, and clearable.
- Provider secrets use Keychain service `dev.utterink.UtterInk.provider-credentials`; legacy plaintext is deleted only after verified Keychain storage.
- No global `NSAllowsArbitraryLoads`, no Sparkle, no cloud sync, no live transcription, no voice commands, and no second speech engine in P0.
- App UI ships with English as the required baseline. Additional localization ships only after its complete manual accessibility/state matrix passes; English and Chinese READMEs are mandatory.
- License is Apache-2.0; source/asset ownership and third-party license compatibility must be explicit before public visibility.
- No GitHub repository creation/push, Apple notarization upload, beta transfer, public transition, or GitHub Release occurs without its separate artifact-scoped user approval.
- The approved design is `docs/superpowers/specs/2026-07-12-utterink-open-source-productization-design.md`; when this plan conflicts with it, the design wins and the plan must be corrected before implementation continues.

---

## Why this is a plan set

The approved design spans five reviewer-independent subsystems. Implement them in this order; do not start a later plan until the preceding plan's completion gate passes.

| Order | Plan | Independently testable result | Depends on |
|---|---|---|---|
| 1 | [Foundation and parity](2026-07-12-utterink-foundation-parity-plan.md) | Reviewed FlowType parity snapshot plus a clean, buildable UtterInk Xcode/SPM skeleton | Approved design |
| 2 | [Core pipeline](2026-07-12-utterink-core-pipeline-plan.md) | Fully tested domain, storage, security, network, audio, speech, delivery, diagnostics, and orchestration package | Plan 1 |
| 3 | [macOS product](2026-07-12-utterink-macos-product-plan.md) | Runnable menu-bar app with complete P0 UI/onboarding/history/settings and parity evidence | Plans 1–2 |
| 4 | [Identity and open source](2026-07-12-utterink-identity-open-source-plan.md) | Approved deterministic identity assets and complete public documentation/license set | Plan 3 |
| 5 | [Distribution and release](2026-07-12-utterink-distribution-release-plan.md) | Secret-free CI, unsigned packaging smoke, guarded local signing/notarization tooling, evidence template | Plans 1–4 |

## Fixed project/tooling decisions

- Generate `UtterInk.xcodeproj` from committed `project.yml` using local XcodeGen 2.45.4, then commit both. XcodeGen is a development-time project generator, not a runtime dependency or package manager.
- Use `// swift-tools-version: 5.9` and Swift 5 language mode initially to preserve the known-good legacy behavior while Xcode 26.4/Swift 6.3 builds it. Strict Swift 6 concurrency migration is not a P0 deliverable.
- Use the `macos-26` arm64 GitHub-hosted runner. Select `/Applications/Xcode_26.4.app/Contents/Developer`; the runner image provides the Xcode 26.4.1 line under that symlink.
- Pin checkout to `actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd` (`v6.0.2`), with `fetch-depth: 0` and `persist-credentials: false`.
- Do not upload unsigned CI artifacts by default. The packaging smoke test verifies locally inside the job and deletes its output.
- Use a temporary `LegacyParity/` Swift package only to lock the rescued implementation's behavior. It never becomes a dependency of the final app and is removed after the parity gate.

## Cross-plan interface inventory

These names are authoritative. A plan task may add details but must not rename them without updating every later plan first.

```swift
public struct SessionID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}
public struct EffectToken: Hashable, Sendable {
    public let sessionID: SessionID
    public let generation: UInt64
    public init(sessionID: SessionID, generation: UInt64) { self.sessionID = sessionID; self.generation = generation }
}

public protocol AppClock: Sendable {
    var now: Date { get }
    func sleep(for duration: Duration) async throws
}

public struct RecordingTelemetry: Equatable, Sendable {
    public let startedAt: Date
    public let inputLevel: Float
    public init(startedAt: Date, inputLevel: Float) { self.startedAt = startedAt; self.inputLevel = inputLevel }
}

public struct SessionPresentationContext: Equatable, Sendable {
    public let deliveryPreference: DeliveryPreference
    public init(deliveryPreference: DeliveryPreference) { self.deliveryPreference = deliveryPreference }
}

public enum PipelineStage: String, Codable, Sendable {
    case idle, requestingPermission, recording, stopping, transcribing, polishing, delivering, completed, failed
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
        self.id = id; self.modelID = modelID; self.generation = generation
    }
}

public struct SpeechModelDescriptor: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let displayName: String
    public let approximateBytes: UInt64
    public let preset: String?
    public init(id: String, displayName: String, approximateBytes: UInt64, preset: String?) {
        self.id = id; self.displayName = displayName; self.approximateBytes = approximateBytes; self.preset = preset
    }
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
        self.id = id; self.startedAt = startedAt; self.target = target; self.recognition = recognition; self.speechModelID = speechModelID
        self.outputMode = outputMode; self.provider = provider; self.historyGeneration = historyGeneration
        self.historyEnabled = historyEnabled; self.deliveryPreference = deliveryPreference; self.credential = credential
    }
}

public protocol SettingsStore: Sendable {
    func current() async throws -> UserSettings
    func save(_ settings: UserSettings) async throws
}

public protocol HistoryStore: Sendable {
    func generation() async -> UInt64
    func appendRaw(_ record: HistoryRecord, expectedGeneration: UInt64) async throws
    func updateResult(sessionID: SessionID, finalText: String, source: ResultSource, warning: DiagnosticCode?, delivery: DeliveryOutcome?, outcome: HistoryOutcome, expectedGeneration: UInt64) async throws
    func delete(sessionID: SessionID) async throws
    func setEnabled(_ enabled: Bool) async throws -> UInt64
    func clear() async throws -> UInt64
    func load() async throws -> [HistoryRecord]
}

public protocol CredentialStore: Sendable {
    func read(profileID: UUID) async throws -> SessionSecret?
    func write(_ secret: SessionSecret, profileID: UUID) async throws
    func delete(profileID: UUID) async throws
}

public enum CredentialConflictChoice: Equatable, Sendable { case keepSecure, replaceSecureWithLegacy }
public protocol CredentialMigrationService: Sendable {
    func migrate(profileID: UUID) async -> CredentialMigrationResult
    func resolve(profileID: UUID, choice: CredentialConflictChoice) async -> CredentialMigrationResult
}

public protocol AudioRecordingService: Sendable {
    func requestPermission() async -> PermissionState
    func start(levels: @escaping @Sendable (Float) -> Void) async throws -> RecordingHandle
    func stop(_ handle: RecordingHandle) async throws -> URL
    func cancel(_ handle: RecordingHandle) async
}

public protocol SpeechModelService: Sendable {
    func state() async -> SpeechModelState
    func prepare(modelID: String, token: EffectToken) async -> AsyncStream<SpeechModelState>
    func cancelPreparation() async
    func acquireReadyModel(modelID: String, token: EffectToken) async throws -> SpeechModelLease
    func release(_ lease: SpeechModelLease) async
    func deleteCachedModel(modelID: String) async throws
}

public protocol TranscriptionService: Sendable {
    func transcribe(audioURL: URL, model: SpeechModelLease, configuration: RecognitionConfiguration, token: EffectToken) async throws -> String
}

public protocol PolishingService: Sendable {
    func polish(rawText: String, snapshot: SessionSnapshot, token: EffectToken) async throws -> String
}

public enum ProviderValidationResult: Equatable, Sendable {
    case ready(normalizedHost: String, modelID: String)
    case failed(DiagnosticCode)
}

public protocol ProviderValidationService: Sendable {
    func validate(profile: ProviderProfile, credential: SessionSecret) async -> ProviderValidationResult
}

public protocol DeliveryService: Sendable {
    func deliver(text: String, to target: DeliveryTarget, preference: DeliveryPreference, token: EffectToken) async -> DeliveryOutcome
    func copyExplicitly(text: String, token: EffectToken) async -> DeliveryOutcome
}

public protocol OnboardingTestSink: Sendable {
    func deliver(_ text: String, sessionID: SessionID) async
    func values() async -> AsyncStream<(SessionID, String)>
}

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
```

## Public construction inventory

Swift's synthesized/memberwise initializers are not public. These production construction entry points are therefore required and are compile-tested from a test target that uses ordinary `import UtterInkCore` / `import UtterInkServices`, never `@testable`:

```swift
public struct SystemAppClock: AppClock { public init() }
public actor JSONHistoryStore: HistoryStore {
    public init(directory: URL, enabled: Bool, clock: any AppClock) throws
}
public actor UserDefaultsSettingsStore: SettingsStore {
    public init(defaults: UserDefaults, legacyMap: LegacyDefaultsMap = .bundled) throws
}
public struct LegacyDefaultsReader: Sendable { public init(suiteName: String) throws }
public struct LegacyDefaultsMap: Sendable { public static let bundled: LegacyDefaultsMap }
public actor KeychainCredentialStore: CredentialStore {
    public init(service: String = "dev.utterink.UtterInk.provider-credentials", accessGroup: String? = nil)
}
public actor LegacyCredentialMigrator: CredentialMigrationService {
    public init(legacy: LegacyDefaultsReader, credentials: any CredentialStore, map: LegacyDefaultsMap = .bundled) throws
}
public actor TransientAudioStore {
    public init(root: URL, clock: any AppClock) throws
    public func sweep() async throws
}
public actor AVAudioRecordingService: AudioRecordingService { public init(store: TransientAudioStore) }
public struct WhisperModelCatalog: Sendable {
    public let descriptors: [SpeechModelDescriptor]
    public init(data: Data) throws
    public static let bundled: WhisperModelCatalog
}
public actor WhisperModelService: SpeechModelService {
    public init(catalog: WhisperModelCatalog, root: URL, clock: any AppClock) throws
}
public actor WhisperTranscriber: TranscriptionService { public init(models: WhisperModelService) }
public actor OpenAICompatibleClient: PolishingService, ProviderValidationService {
    public init(clock: any AppClock)
}
public actor InMemoryOnboardingTestSink: OnboardingTestSink { public init() }
@MainActor public final class TargetTracker: TargetSnapshotService, @unchecked Sendable { public init(clock: any AppClock) }
@MainActor public final class PasteboardClient: @unchecked Sendable { public init(clock: any AppClock) }
public actor DeliveryCoordinator: DeliveryService {
    public init(pasteboard: PasteboardClient, target: TargetTracker, onboardingSink: any OnboardingTestSink, clock: any AppClock, settleDelay: Duration = .milliseconds(250))
}
public struct SystemPermissionService: PermissionService { public init() }
public final class KeyboardShortcutsHotkeyService: @unchecked Sendable {
    public init(mode: ShortcutMode, onEvent: @escaping @MainActor @Sendable (Event) -> Void)
}
public actor SafeDiagnosticsSink: DiagnosticsSink { public init() }
public struct DiagnosticsExporter: Sendable { public init() }
@MainActor public final class DictationSessionController: DictationControlling {
    public init(settings: any SettingsStore, target: any TargetSnapshotService, permissions: any PermissionService, history: any HistoryStore, credentials: any CredentialStore, audio: any AudioRecordingService, models: any SpeechModelService, transcription: any TranscriptionService, polishing: any PolishingService, delivery: any DeliveryService, diagnostics: any DiagnosticsSink, modelCatalog: [SpeechModelDescriptor], clock: any AppClock)
}
```

Test-only lower-level clients/backends remain internal or package-scoped. If any signature changes during implementation, update this inventory and the external-consumer compile test before changing App composition.

## Target file map

```text
UtterInk/
├── App/
│   ├── UtterInkApp.swift
│   ├── AppModel.swift
│   ├── AppComposition.swift
│   ├── MenuBar/MenuBarRootView.swift
│   ├── Floating/FloatingRecorderView.swift
│   ├── Floating/FloatingWindowController.swift
│   ├── History/HistoryView.swift
│   ├── History/LastResultView.swift
│   ├── Onboarding/OnboardingFlow.swift
│   ├── Onboarding/OnboardingWindowController.swift
│   ├── Settings/SettingsRootView.swift
│   ├── Settings/GeneralSettingsView.swift
│   ├── Settings/SpeechModelSettingsView.swift
│   ├── Settings/ShortcutSettingsView.swift
│   ├── Settings/OutputModeSettingsView.swift
│   ├── Settings/ProviderSettingsView.swift
│   ├── Settings/DiagnosticsSettingsView.swift
│   ├── Localization/EnglishCopy.swift
│   ├── Resources/Assets.xcassets/...
│   └── Supporting/{Info.plist,UtterInk.entitlements}
├── Packages/UtterInkKit/
│   ├── Package.swift
│   ├── Package.resolved
│   ├── Sources/UtterInkCore/
│   │   ├── Domain/{SessionID,PipelineState,SpeechModelState,SessionSnapshot,DictationResult,SettingsModels}.swift
│   │   ├── Pipeline/{DictationIntent,DictationEffect,DictationReducer,DictationSessionController,ServiceProtocols}.swift
│   │   ├── History/HistoryModels.swift
│   │   ├── Diagnostics/DiagnosticsModels.swift
│   │   └── Security/SessionSecret.swift
│   ├── Sources/UtterInkServices/
│   │   ├── Audio/{TransientAudioStore,AVAudioRecordingService}.swift
│   │   ├── Speech/{WhisperModelCatalog,WhisperModelService,WhisperTranscriber}.swift
│   │   ├── Storage/{JSONHistoryStore,UserDefaultsSettingsStore,LegacyDefaultsReader}.swift
│   │   ├── Security/{KeychainCredentialStore,LegacyCredentialMigrator}.swift
│   │   ├── Polishing/{EndpointValidator,OpenAICompatibleClient,SecureRedirectDelegate}.swift
│   │   ├── Delivery/{TargetTracker,PasteboardClient,DeliveryCoordinator}.swift
│   │   ├── Diagnostics/{DiagnosticsExporter,SafeLogger}.swift
│   │   ├── Permissions/SystemPermissionService.swift
│   │   └── Hotkey/KeyboardShortcutsHotkeyService.swift
│   └── Tests/{UtterInkCoreTests,UtterInkServicesTests}/...
├── UtterInkUITests/
├── UtterInkAppTests/
├── Config/
├── Scripts/
├── Tests/Scripts/
├── docs/{parity,provenance,release}/
├── project.yml
└── UtterInk.xcodeproj/
```

## Execution discipline

1. At execution time, use an isolated worktree before Task 1.
2. Run each listed failing test and confirm the stated failure before writing production code.
3. Implement only enough for that test/task, run its focused test, then run the plan-level regression command.
4. Review the diff for secrets, transcript fixtures, personal paths, generated build output, and unrelated changes before every commit.
5. Use the exact commit messages in each task unless the implementation materially changes and the message must become more accurate.
6. Never run notarization submission, create/push a GitHub repository, send a DMG, change visibility, or publish a release from these plans. Those are later user-approved operations, not implementation steps.
7. In every task that creates a shell script invoked as `./Scripts/...`, run `chmod +x` and `test -x` before the task commit; executable mode is part of the reviewed diff.
8. After a task intentionally changes `project.yml` or adds/removes Xcode source files, run `xcodegen generate`, finish the focused test, then stage only `UtterInk.xcodeproj` before `ci-local.sh`; its generated-project drift check compares the regenerated working tree with that staged baseline. Stage the rest only after verification succeeds.

## Approved-spec coverage map

Every approved P0 requirement has one primary implementation owner and at least one verification owner. Do not delete or merge a mapped task without updating this table and rechecking the approved design.

| Approved requirement | Primary implementation task(s) | Verification/release evidence |
|---|---|---|
| One authoritative dictation state machine | Core Tasks 3, 10 | Core reducer/controller tests; Product Tasks 1–2 |
| Independent speech-model lifecycle | Core Task 7 | Product Task 5; Product Task 8 UI scenarios |
| UI and hotkey emit intents only | Product Tasks 1–2 | App model/hotkey tests; parity evidence in Product Task 9 |
| Immutable session settings, credential, and target snapshot | Core Tasks 2, 5, 8, 10 | Snapshot, stale-completion, focus-generation, and migration tests |
| Save non-empty raw text before polish or paste | Core Tasks 3–4, 10 | Controller event-order tests; Product Task 3 recovery UI |
| Raw fallback on polishing failure | Core Tasks 3, 6, 10 | Reducer/network/controller tests; Product Tasks 2–3 |
| Default-on local latest-20 text history; no audio | Core Tasks 4, 7, 10 | History adversarial tests; Product Tasks 3–4; Distribution evidence |
| Target-aware delivery and guarded pasteboard restore | Core Task 8 | Delivery race tests; Product Tasks 2–3; manual matrix |
| Safe UserDefaults-to-Keychain credential migration | Core Task 5 | Migration conflict/inaccessibility tests; Product Task 6 |
| Privacy/readiness/shortcut/dictation onboarding | Product Task 7 | Onboarding unit/UI tests; Product Task 8 manual matrix |
| Sanitized diagnostics with no key/transcript/payload | Core Task 9 | Canary tests; Product Task 6 preview/export; evidence scan |
| No global arbitrary loads; narrow explicit loopback HTTP | Foundation Task 3; Core Task 6 | plist inspection, endpoint/redirect tests, signed-app local-server check |
| Clean reviewed source import and Apache-compatible rights | Foundation Tasks 1–2; Identity Tasks 3–5 | Import hashes, full-history scans, provenance/license evidence |
| Approved deterministic visual identity and accessibility | Identity Tasks 1–2; Product Task 8 | Local asset approval, asset tests, complete accessibility matrix |
| Secret-free reproducible CI | Foundation Task 4; Distribution Tasks 1–3 | Workflow policy test and unsigned package smoke |
| Exact-source signed/notarized DMG and release packet | Distribution Tasks 4–7 | Signature/notary/log/staple/Gatekeeper/hash/evidence gates |

## Deliberate human and external gates

These are concrete stop points, not unfinished plan content:

1. Foundation Task 1 waits for factual source/asset ownership and Apache-2.0 relicensing authority; unknown rights block import/public visibility.
2. Identity Task 2 waits for local approval of one pixel-fitted production asset set after similarity/trademark-risk review.
3. Distribution Task 5 may implement/test the notarization wrapper but stops before any real upload; one exact pre-staple DMG hash and attempt needs fresh approval.
4. Distribution Task 6 needs a second supported Apple Silicon Mac for the final quarantined/offline Gatekeeper result.
5. GitHub creation/first push, beta transfer, public transition, and GitHub Release remain separate artifact-scoped actions outside implementation execution.

## Whole-project regression commands

```bash
swift test --package-path Packages/UtterInkKit
xcodegen generate
xcodebuild -project UtterInk.xcodeproj -scheme UtterInk -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build
./Scripts/ci-local.sh
git diff --check
git status --short
```

Expected final result: all commands exit 0; `git status --short` is empty after each task commit.
