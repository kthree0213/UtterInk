# UtterInk macOS Product Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the tested package into a complete native menu-bar product with intent-only controls, stage-specific floating UI, recovery/history, P0 settings, first-success onboarding, and accessibility evidence.

**Architecture:** `AppComposition` constructs production adapters once and injects the package controller into `AppModel`. SwiftUI/AppKit surfaces read the controller's observable aggregate and send `UserIntent`; no view or hotkey service owns recording/processing state. UI tests use an explicit in-memory composition selected only by launch arguments.

**Tech Stack:** SwiftUI, AppKit, Observation, KeyboardShortcuts, XCTest/XCUITest, XcodeGen, macOS 14+, arm64.

## Global Constraints

- UI renders the authoritative `PipelineState` and independent `SpeechModelState`; it does not recreate state with booleans.
- Visible pipeline labels are Requesting Permission, Listening, Stopping, Transcribing, Polishing, Pasting/Copying, Done, or a specific recoverable failure.
- Accessibility denial still allows local transcription and explicit Copy; microphone denial blocks recording with guidance.
- History/last-result actions are Copy, Paste Again, Retry Polishing, and Delete with exact semantics from the design.
- Onboarding closes without completion; only a non-empty recoverable result marks it complete.
- Raw mode is first and works without an API key. Provider setup/custom modes are deferred from onboarding.
- English is the required app UI baseline; no unverified localization is exposed as shipped P0 behavior.
- Menu-bar art remains a template image and status meaning is not color-only.
- No external publication, notarization, beta transfer, or repository action is part of this plan.

---

### Task 1: Live composition, app model, and lifecycle

**Files:**
- Create: `App/AppComposition.swift`
- Create: `App/AppModel.swift`
- Create: `App/Services/AppFeatureProtocols.swift`
- Create: `App/Services/LaunchAtLoginService.swift`
- Modify: `App/UtterInkApp.swift`
- Modify: `project.yml`
- Generate: `UtterInk.xcodeproj/**`
- Create: `UtterInkAppTests/Support/RecordingIntentControllerSpy.swift`
- Create: `UtterInkAppTests/Support/AppFeatureFakes.swift`
- Create: `UtterInkAppTests/AppModelContractTests.swift`

**Interfaces:**
- Consumes: `DictationSessionController` and services from the core pipeline plan.
- Produces: `AppComposition.live()`, `AppFeatureDependencies`, and `@MainActor @Observable final class AppModel`; deterministic UI-test composition is added only with its typed scenario in Task 8.

- [ ] **Step 1: Write an intent-forwarding contract test**

Place the spy in `UtterInkAppTests/Support/RecordingIntentControllerSpy.swift` and the test class in `AppModelContractTests.swift` (shown together here for the contract):

```swift
import XCTest
import UtterInkCore
@testable import UtterInk

@MainActor
final class RecordingIntentControllerSpy: DictationControlling {
    var state: PipelineState = .idle
    var speechModelState: SpeechModelState = .ready(modelID: "small")
    var volatileResults: [DictationResult] = []
    var historyRecords: [HistoryRecord] = []
    var recordingTelemetry: RecordingTelemetry? = nil
    var sessionPresentation: SessionPresentationContext? = nil
    var speechModelCatalog: [SpeechModelDescriptor] = []
    var intents: [UserIntent] = []
    var bootstrapCount = 0
    func bootstrap() async { bootstrapCount += 1 }
    func send(_ intent: UserIntent) { intents.append(intent) }
    func prepareSpeechModel(_ modelID: String) {}
    func cancelSpeechModelPreparation() {}
    func deleteCachedSpeechModel(_ modelID: String) {}
}

@MainActor
final class AppModelContractTests: XCTestCase {
    func testAppModelBootstrapsAndForwardsStartWithoutOwningRecordingFlag() async {
        let controller = RecordingIntentControllerSpy()
        let model = AppModel(controller: controller)
        await model.bootstrap()
        model.startOrStop()
        XCTAssertEqual(controller.bootstrapCount, 1)
        XCTAssertEqual(controller.intents, [.start(.focusedExternal)])
        XCTAssertFalse(Mirror(reflecting: model).children.contains { $0.label == "isRecording" })
    }
}
```

`AppFeatureFakes.swift` initially provides in-memory settings, launch-at-login, hotkey, onboarding-sink, system-navigation, credential, provider, migration, and diagnostics fakes plus a concrete `DictationResult.fixture(finalText:)`; every helper records ordered calls. Task 7 extends it with `OnboardingHarness` after that view model exists.

- [ ] **Step 2: Run to verify failure**

Add this XcodeGen target and include it in the `UtterInk` scheme's `test.targets`, then generate the project:

```yaml
  UtterInkAppTests:
    type: bundle.unit-test
    platform: macOS
    deploymentTarget: "14.0"
    sources:
      - path: UtterInkAppTests
    dependencies:
      - target: UtterInk
      - package: UtterInkKit
        product: UtterInkCore
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
        TEST_HOST: "$(BUILT_PRODUCTS_DIR)/UtterInk.app/Contents/MacOS/UtterInk"
        BUNDLE_LOADER: "$(TEST_HOST)"
schemes:
  UtterInk:
    build:
      targets:
        UtterInk: all
        UtterInkAppTests: [test]
    run:
      config: Debug
    test:
      config: Debug
      targets:
        - name: UtterInkAppTests
    archive:
      config: Release
```

Replace the prior scheme mapping with this single merged mapping; do not append a second `schemes:`/`UtterInk:` YAML key.

```bash
xcodegen generate
xcodebuild -project UtterInk.xcodeproj -scheme UtterInk -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO -only-testing:UtterInkAppTests/AppModelContractTests test
```

Expected: compile failure because `AppModel` does not exist. App-layer tests must stay in `UtterInkAppTests`; they must not be placed in either Swift Package test target.

- [ ] **Step 3: Implement the app model contract**

```swift
import Observation
import UtterInkCore

@MainActor @Observable
final class AppModel {
    let controller: any DictationControlling
    init(controller: any DictationControlling) { self.controller = controller }

    var pipeline: PipelineState { controller.state }
    var speechModel: SpeechModelState { controller.speechModelState }
    var volatileResults: [DictationResult] { controller.volatileResults }
    var historyRecords: [HistoryRecord] { controller.historyRecords }
    var recordingTelemetry: RecordingTelemetry? { controller.recordingTelemetry }
    var sessionPresentation: SessionPresentationContext? { controller.sessionPresentation }
    var speechModelCatalog: [SpeechModelDescriptor] { controller.speechModelCatalog }

    func bootstrap() async { await controller.bootstrap() }

    func startOrStop() {
        switch pipeline.stage {
        case .recording: controller.send(.stop)
        case .idle, .completed, .failed: controller.send(.start(.focusedExternal))
        default: break
        }
    }
    func cancel() { controller.send(.cancel) }
}
```

`AppComposition.live()` must create one settings store, Keychain store/migrator, history store, target tracker, permission service, launch-at-login adapter, hotkey adapter, transient audio store, recorder, Whisper model/transcriber, secure polish client factory, delivery coordinator/onboarding sink, safe diagnostics sink/exporter, and controller through the public construction interfaces in the index. `AppFeatureDependencies` exposes only protocol-typed settings, permission/system-navigation, launch-at-login, hotkey-probe/configuration, credential-store/migration, provider-validation, diagnostics-export, onboarding-sink, and clock dependencies. A wiring contract test constructs `AppComposition.live()` through non-interactive clients and proves every dependency slot is present. Each Settings/Onboarding view model below has an explicit initializer accepting only the subset it uses; no View reaches into concrete services or global singletons. App startup awaits `model.bootstrap()`, orphan-audio sweep, and credential migration before enabling dictation/polishing.

`AppFeatureProtocols.swift` defines `@MainActor SystemSettingsNavigating` with typed microphone/accessibility destinations, `LaunchAtLoginManaging`, `HotkeyProbing` with `arm() async -> AsyncStream<Void>`, `HotkeyConfiguring` for current/conflict/reset operations, and `DiagnosticsExporting` returning only the safe DTO/data. Live adapters wrap ServiceManagement/AppKit/KeyboardShortcuts/DiagnosticsExporter; the app-test support file supplies fakes.

- [ ] **Step 4: Wire the SwiftUI app lifecycle**

`UtterInkApp` owns one `@State` model created from composition, calls `await model.bootstrap()` from a single app task before starting the hotkey listener, and supplies the same model to menu, floating panel, Settings, History, and Onboarding. Use `NSApplicationDelegateAdaptor` only for lifecycle hooks that SwiftUI scenes cannot express; it must not own pipeline state.

- [ ] **Step 5: Verify and commit**

```bash
xcodegen generate
xcodebuild -project UtterInk.xcodeproj -scheme UtterInk -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO -only-testing:UtterInkAppTests/AppModelContractTests test
git add UtterInk.xcodeproj
./Scripts/ci-local.sh
git add App UtterInkAppTests project.yml UtterInk.xcodeproj Packages/UtterInkKit
git commit -m "feat: compose the UtterInk application"
```

---

### Task 2: Intent-only menu, hotkey, and floating recorder

**Files:**
- Create: `App/MenuBar/MenuBarRootView.swift`
- Create: `App/Floating/FloatingRecorderView.swift`
- Create: `App/Floating/FloatingWindowController.swift`
- Create: `App/Localization/EnglishCopy.swift`
- Modify: `Packages/UtterInkKit/Sources/UtterInkServices/Hotkey/KeyboardShortcutsHotkeyService.swift`
- Test: `UtterInkAppTests/StagePresentationTests.swift`
- Test: `Packages/UtterInkKit/Tests/UtterInkServicesTests/HotkeyServiceTests.swift`
- Generate: `UtterInk.xcodeproj/**`

**Interfaces:**
- Produces: `StagePresentation`, `KeyboardShortcutsHotkeyService.Event`, nonactivating floating panel.

- [ ] **Step 1: Write stage-copy and hotkey behavior tests**

```swift
import XCTest
import UtterInkCore
@testable import UtterInk

final class StagePresentationTests: XCTestCase {
    func testEveryStageHasSpecificAccessibleCopy() {
        let expected: [PipelineStage: String] = [
            .idle: "Ready", .requestingPermission: "Requesting Permission",
            .recording: "Listening", .stopping: "Stopping", .transcribing: "Transcribing",
            .polishing: "Polishing", .delivering: "Pasting", .completed: "Done", .failed: "Needs Attention"
        ]
        for (stage, label) in expected {
            XCTAssertEqual(StagePresentation(stage: stage, deliveryPreference: .automaticPaste).label, label)
        }
        XCTAssertEqual(StagePresentation(stage: .delivering, deliveryPreference: .copyOnly).label, "Copying")
    }
}
```

In `HotkeyServiceTests.swift`:

```swift
import XCTest
@testable import UtterInkServices

@MainActor
final class HotkeyServiceTests: XCTestCase {
    func testPushToTalkEventsDoNotOwnRecordingState() {
        var events: [KeyboardShortcutsHotkeyService.Event] = []
        let service = KeyboardShortcutsHotkeyService(mode: .holdToTalk) { events.append($0) }
        service.simulateKeyDown()
        service.simulateKeyUp()
        XCTAssertEqual(events, [.startRequested, .stopRequested])
        XCTAssertFalse(Mirror(reflecting: service).children.contains { $0.label == "isRecording" })
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run both focused test classes; expect compile failure:

```bash
xcodegen generate
xcodebuild -project UtterInk.xcodeproj -scheme UtterInk -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO -only-testing:UtterInkAppTests/StagePresentationTests test
swift test --package-path Packages/UtterInkKit --filter HotkeyServiceTests
```

- [ ] **Step 3: Implement the presenter and hotkey event adapter**

`StagePresentation` is a pure value with `label`, `systemImage`, `primaryAction`, `canCancel`, `accessibilityValue`, and `warning`. `KeyboardShortcutsHotkeyService` emits `.startRequested` on toggle/hold key-down and `.stopRequested` on toggle second key-down or hold key-up; the app model decides whether that event is valid. The service has no `isRecording` property.

- [ ] **Step 4: Implement menu and floating surfaces**

The menu contains current status, Start/Stop/Cancel as valid, latest-result recovery, Raw-first output selection, recognition language, speech-model readiness, History, Onboarding, Settings, and Quit. The floating panel is `.nonactivatingPanel`, ignores UtterInk as an external focus change, and reads elapsed time/input level only from controller `recordingTelemetry` using `AppClock`; it reads Pasting/Copying from snapshotted `sessionPresentation`, never mutable Settings. It shows no invented progress during transcription/polish. Escape sends `.cancel`; Reduce Motion replaces spring/pulse animations with opacity changes.

Every icon-only button has a label/help string. Warning and success states combine symbol and text, never color alone.

- [ ] **Step 5: Verify and commit**

```bash
xcodegen generate
xcodebuild -project UtterInk.xcodeproj -scheme UtterInk -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO -only-testing:UtterInkAppTests/StagePresentationTests test
swift test --package-path Packages/UtterInkKit --filter HotkeyServiceTests
git add UtterInk.xcodeproj
./Scripts/ci-local.sh
git add App UtterInkAppTests Packages/UtterInkKit UtterInk.xcodeproj
git commit -m "feat: add intent-only dictation controls"
```

---

### Task 3: History and last-result recovery UI

**Files:**
- Create: `App/History/LastResultView.swift`
- Create: `App/History/HistoryView.swift`
- Create: `App/History/HistoryViewModel.swift`
- Test: `UtterInkAppTests/HistoryActionTests.swift`
- Generate: `UtterInk.xcodeproj/**`

**Interfaces:**
- Produces: `RecoveryItem`, `HistoryAction.copy`, `.pasteAgain`, `.retryPolishing`, `.delete`, `.clearAll`; `HistoryViewModel` merges persistent/volatile results and maps actions exactly to `UserIntent`.

- [ ] **Step 1: Write action mapping tests**

```swift
import XCTest
import UtterInkCore
@testable import UtterInk

@MainActor
final class HistoryActionTests: XCTestCase {
    func testHistoryActionsMapToExplicitControllerIntents() {
        let session = SessionID()
        let spy = RecordingIntentControllerSpy()
        let model = HistoryViewModel(controller: spy)
        model.perform(.copy, sessionID: session)
        model.perform(.pasteAgain, sessionID: session)
        model.perform(.retryPolishing, sessionID: session)
        model.perform(.delete, sessionID: session)
        XCTAssertEqual(spy.intents, [.copyResult(session), .pasteAgain(session), .retryPolishing(session), .deleteResult(session)])
    }

    func testVolatileCurrentStateOverlaysPersistentBackingWithoutDuplication() {
        let id = SessionID()
        let spy = RecordingIntentControllerSpy()
        spy.volatileResults = [DictationResult(sessionID: id, startedAt: Date(timeIntervalSince1970: 1), rawText: "raw", finalText: "raw", source: .rawFallback, warning: .polishTransport, delivery: .manualCopyRequired(.deliveryTargetChanged))]
        spy.historyRecords = [HistoryRecord(sessionID: id, startedAt: Date(timeIntervalSince1970: 1), rawText: "raw", finalText: nil, source: .raw, warning: nil, delivery: nil, outcome: .rawSaved)]
        let items = HistoryViewModel(controller: spy).items
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].persistence, .persistent)
        XCTAssertEqual(items[0].warning, .polishTransport)
        XCTAssertEqual(items[0].delivery, .manualCopyRequired(.deliveryTargetChanged))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run:

```bash
xcodegen generate
xcodebuild -project UtterInk.xcodeproj -scheme UtterInk -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO -only-testing:UtterInkAppTests/HistoryActionTests test
```

Expected: compile failure for missing history view model/action types.

- [ ] **Step 3: Implement result/history surfaces**

`HistoryViewModel.items` maps `historyRecords` and `volatileResults` into `RecoveryItem`, deduplicates by session ID, uses current in-process volatile presentation fields over their persistent raw backing, marks that merged item persistent, and sorts by `startedAt` descending. This preserves an in-memory polished/failure result when its final history update failed; after restart, only the durable record remains. Last Result is reachable from the menu/floating panel without Settings. It labels Raw versus Polished, displays the sanitized fallback/delivery warning, renders `.pasteEventDispatched` as “Paste event sent” rather than claiming target acceptance, renders `.copiedByPreference` as “Copied to Clipboard (Copy Only)” and `.copiedByUser` as “Copied by You,” and provides only actions supported by the record. History shows newest 20 original sessions, timestamp, a bounded text preview, non-persistent badge for volatile-only results, and confirmation for Delete/Clear. Turning history off states that existing saved records remain until Clear; Clear sends the immediate cancel-and-clear intent.

- [ ] **Step 4: Verify and commit**

```bash
xcodegen generate
xcodebuild -project UtterInk.xcodeproj -scheme UtterInk -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO -only-testing:UtterInkAppTests/HistoryActionTests test
git add UtterInk.xcodeproj
./Scripts/ci-local.sh
git add App/History App/MenuBar App/Floating UtterInkAppTests UtterInk.xcodeproj
git commit -m "feat: add transcript recovery history"
```

---

### Task 4: General, permission, recognition, and shortcut settings

**Files:**
- Create: `App/Settings/SettingsRootView.swift`
- Create: `App/Settings/GeneralSettingsView.swift`
- Create: `App/Settings/PermissionSettingsView.swift`
- Create: `App/Settings/RecognitionLanguageSettingsView.swift`
- Create: `App/Settings/ShortcutSettingsView.swift`
- Test: `UtterInkAppTests/SettingsPresentationTests.swift`
- Generate: `UtterInk.xcodeproj/**`

**Interfaces:**
- Produces: typed `SettingsRoute` plus feature view models initialized from `AppFeatureDependencies`; ordinary values persist through `SettingsStore`, while history enable/disable/clear also send their explicit immediate privacy intents to `DictationControlling`.

- [ ] **Step 1: Write settings boundary tests**

Prove: English baseline only; launch/floating visibility settings round-trip; recognition fixed/automatic round-trips through its own route; history defaults true; disable is immediate and re-enable uses a new generation; delivery defaults to Automatic Paste and both Automatic Paste/Copy Only round-trip; the Copy Only explanation explicitly says each completed dictation replaces the clipboard without automatic restoration or simulated paste; microphone/accessibility statuses are distinct; shortcut conflict/empty states are visible; changing language/model/output/provider/delivery preference does not mutate an active `SessionSnapshot`.

- [ ] **Step 2: Run to verify failure**

Run:

```bash
xcodegen generate
xcodebuild -project UtterInk.xcodeproj -scheme UtterInk -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO -only-testing:UtterInkAppTests/SettingsPresentationTests test
```

Expected: compile failure for missing settings types.

- [ ] **Step 3: Implement navigation and controls**

Initialize the route/root model with `SettingsStore`, `DictationControlling`, `PermissionService`, `LaunchAtLoginManaging`, `SystemSettingsNavigating`, and hotkey configuration/probe abstractions. `LaunchAtLoginService` adapts `SMAppService.mainApp`, reports enabled/requires-approval/failed states, and never pretends a denied registration succeeded. Use a `NavigationSplitView` with routes General, Permissions, Recognition Language, Speech Model, Shortcuts, Output Modes, Provider, and Diagnostics. General contains launch-at-login, floating-recorder visibility, history enable/Clear, and a two-value delivery preference. Automatic Paste describes target validation plus guarded restoration; Copy Only describes the snapshotted pre-authorization to replace the clipboard at completion, with no Command-V and no automatic restoration. The separate safety fallback never claims it copied and still exposes explicit Copy. Recognition Language owns fixed/auto-detect selection and current effective choice. Permissions explains microphone versus Accessibility, shows current status text/symbol, and opens the exact System Settings pane. Shortcuts exposes Toggle/Hold to Talk and `KeyboardShortcuts.Recorder`, plus conflict and reset states. Settings changes write future-session values; history enable/disable/clear also send their immediate controller intents.

- [ ] **Step 4: Verify and commit**

```bash
xcodegen generate
xcodebuild -project UtterInk.xcodeproj -scheme UtterInk -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO -only-testing:UtterInkAppTests/SettingsPresentationTests test
git add UtterInk.xcodeproj
./Scripts/ci-local.sh
git add App/Settings UtterInkAppTests UtterInk.xcodeproj
git commit -m "feat: add privacy and input settings"
```

---

### Task 5: Speech-model settings and readiness UI

**Files:**
- Create: `App/Settings/SpeechModelSettingsView.swift`
- Create: `App/Settings/SpeechModelSettingsViewModel.swift`
- Test: `UtterInkAppTests/SpeechModelPresentationTests.swift`
- Generate: `UtterInk.xcodeproj/**`

**Interfaces:**
- Consumes: independent `SpeechModelState` and preset catalog.
- Produces: Fast/Recommended/Best Quality and Advanced model-selection UI.

- [ ] **Step 1: Write presentation tests**

Verify exact preset mapping (`base`, `small`, `large-v3`) from the locked catalog, progress clamping, missing/download/load/ready/failure copy, Retry and Cancel intent forwarding, disk-size display, deletion dispatch for inactive models, and deletion disabled for the selected/active/preparing model.

- [ ] **Step 2: Run to verify failure**

Run:

```bash
xcodegen generate
xcodebuild -project UtterInk.xcodeproj -scheme UtterInk -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO -only-testing:UtterInkAppTests/SpeechModelPresentationTests test
```

Expected: compile failure for missing view model/presentation types.

- [ ] **Step 3: Implement the settings surface**

`SpeechModelSettingsViewModel` is initialized with `DictationControlling` and `SettingsStore`; it never talks to WhisperKit directly. Default view shows three presets and exact catalog disk impact; Advanced shows exactly the other committed catalog entries. Selecting an unready model calls `prepareSpeechModel`, not dictation start. Progress includes the authoritative phase and fraction. Error state shows a sanitized code and explicit Retry; Cancel calls `cancelSpeechModelPreparation`. Cache deletion confirms and calls `deleteCachedSpeechModel` only for an inactive, non-selected model; the user must select and finish preparing another model before deleting the active one.

- [ ] **Step 4: Verify and commit**

```bash
xcodegen generate
xcodebuild -project UtterInk.xcodeproj -scheme UtterInk -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO -only-testing:UtterInkAppTests/SpeechModelPresentationTests test
git add UtterInk.xcodeproj
./Scripts/ci-local.sh
git add App/Settings UtterInkAppTests UtterInk.xcodeproj
git commit -m "feat: add speech model readiness settings"
```

---

### Task 6: Output modes, providers, and diagnostics settings

**Files:**
- Create: `App/Settings/OutputModeSettingsView.swift`
- Create: `App/Settings/ProviderSettingsView.swift`
- Create: `App/Settings/DiagnosticsSettingsView.swift`
- Test: `UtterInkAppTests/ProviderPresentationTests.swift`
- Generate: `UtterInk.xcodeproj/**`

**Interfaces:**
- Produces: Raw-first output editor, provider readiness state, endpoint egress disclosure, diagnostics preview/export.

- [ ] **Step 1: Write provider/readiness tests**

Assert: an incomplete profile is never labeled In Use; the selected ready profile is; Raw works without profile/key; disclosure equals `Audio never leaves this Mac. When polishing is enabled, transcript text is sent to api.example.test.`; HTTP LAN endpoint is rejected; loopback opt-in is explicit; provider validation uses the typed service; migration conflict offers keep-secure/replace-secure, calls the exact `CredentialConflictChoice`, and never exposes values; diagnostics preview contains no canary transcript/key/prompt/path/query.

- [ ] **Step 2: Run to verify failure**

Run:

```bash
xcodegen generate
xcodebuild -project UtterInk.xcodeproj -scheme UtterInk -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO -only-testing:UtterInkAppTests/ProviderPresentationTests test
```

Expected: compile failure for missing presenter/settings types.

- [ ] **Step 3: Implement P0 settings behavior**

`OutputModeSettingsViewModel` is initialized with `SettingsStore`; `ProviderSettingsViewModel` with `SettingsStore`, `CredentialStore`, `CredentialMigrationService`, and `ProviderValidationService`; `DiagnosticsSettingsViewModel` with the safe diagnostics exporter. Output Modes keeps immutable built-in Raw first and supports add/edit/delete for polish modes with non-empty instruction validation. Provider supports the rescued hosted templates plus Custom, stores profile/model/non-secret metadata in settings and keys only in Keychain, displays normalized host/model/readiness, tests `/models` through the typed secure validation service, and resolves migration conflict only after explicit keep/replace action without showing values. Diagnostics previews the exact allowlisted JSON fields before Save Panel export.

- [ ] **Step 4: Verify and commit**

```bash
xcodegen generate
xcodebuild -project UtterInk.xcodeproj -scheme UtterInk -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO -only-testing:UtterInkAppTests/ProviderPresentationTests test
git add UtterInk.xcodeproj
./Scripts/ci-local.sh
git add App/Settings UtterInkAppTests UtterInk.xcodeproj
git commit -m "feat: add output provider and diagnostics settings"
```

---

### Task 7: First-success onboarding v2

**Files:**
- Create: `App/Onboarding/OnboardingFlow.swift`
- Create: `App/Onboarding/OnboardingViewModel.swift`
- Create: `App/Onboarding/OnboardingWindowController.swift`
- Test: `UtterInkAppTests/OnboardingViewModelTests.swift`
- Modify: `UtterInkAppTests/Support/AppFeatureFakes.swift`
- Generate: `UtterInk.xcodeproj/**`

**Interfaces:**
- Produces: steps Privacy, Readiness, Shortcut Test, Test Dictation; setting key `onboardingCompletedV2` written only after a recoverable non-empty result.

- [ ] **Step 1: Write completion-gate tests**

```swift
import XCTest
import UtterInkCore
@testable import UtterInk

@MainActor
final class OnboardingViewModelTests: XCTestCase {
    func testClosingDoesNotCompleteOnboarding() async throws {
        let harness = OnboardingHarness()
        await harness.model.close()
        let settings = try await harness.settings.current()
        XCTAssertFalse(settings.onboardingCompletedV2)
    }

    func testEmptyCancelledAndFailedResultsDoNotComplete() async throws {
        let harness = OnboardingHarness()
        await harness.model.handleRecoverableResult(nil)
        await harness.model.handleRecoverableResult(.fixture(finalText: ""))
        let settings = try await harness.settings.current()
        XCTAssertFalse(settings.onboardingCompletedV2)
    }

    func testRecoverableRawOrPolishedResultCompletes() async throws {
        let harness = OnboardingHarness()
        await harness.model.handleRecoverableResult(.fixture(finalText: "non-empty"))
        let settings = try await harness.settings.current()
        XCTAssertTrue(settings.onboardingCompletedV2)
    }

    func testHistoryChoiceIsSavedBeforeOnboardingStartIntent() async throws {
        let harness = OnboardingHarness()
        await harness.model.setHistoryEnabled(false)
        await harness.model.startTestDictation()
        let settings = try await harness.settings.current()
        XCTAssertFalse(settings.historyEnabled)
        XCTAssertEqual(harness.controller.intents, [.start(.onboardingTest)])
    }

    func testShortcutProbeCompletesInPlaceWithoutOpeningSettings() async {
        let harness = OnboardingHarness()
        await harness.model.armShortcutProbe()
        await harness.hotkeyProbe.emitConfiguredShortcut()
        XCTAssertTrue(harness.model.shortcutTestPassed)
        XCTAssertEqual(harness.systemSettings.openCount, 0)
    }
}
```

Extend `AppFeatureFakes.swift` with `OnboardingHarness`, wiring the existing in-memory settings/controller/hotkey/sink/navigator fakes into a real `OnboardingViewModel`; no assertion body may remain empty or comment-only.

- [ ] **Step 2: Run to verify failure**

Run:

```bash
xcodegen generate
xcodebuild -project UtterInk.xcodeproj -scheme UtterInk -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO -only-testing:UtterInkAppTests/OnboardingViewModelTests test
```

Expected: compile failure for missing onboarding model.

- [ ] **Step 3: Implement the four-step flow**

`OnboardingViewModel` is initialized with `SettingsStore`, `DictationControlling`, `HotkeyProbing`, `OnboardingTestSink`, and system-settings navigation abstractions; tests use `OnboardingHarness` fakes. Privacy states local audio/no retention, default-on text history with toggle, and exact remote-text behavior. Readiness handles microphone, Accessibility limitation, recognition language, model preset/download/load. Shortcut Test arms a probe in the hotkey adapter and observes the actual configured shortcut in place. Test Dictation sends `.start(.onboardingTest)` and consumes only the shared onboarding sink, showing Raw result, explicit Copy, and safe in-app paste field; it never calls external target tracking/event dispatch. Closing saves progress position only; the completion key is written after a trimmed non-empty recoverable result event.

- [ ] **Step 4: Verify and commit**

```bash
xcodegen generate
xcodebuild -project UtterInk.xcodeproj -scheme UtterInk -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO -only-testing:UtterInkAppTests/OnboardingViewModelTests test
git add UtterInk.xcodeproj
./Scripts/ci-local.sh
git add App/Onboarding UtterInkAppTests Packages/UtterInkKit UtterInk.xcodeproj
git commit -m "feat: add first-success onboarding"
```

---

### Task 8: UI tests and accessibility acceptance matrix

**Files:**
- Modify: `project.yml`
- Generate: `UtterInk.xcodeproj/**`
- Create: `UtterInkUITests/LaunchAndNavigationTests.swift`
- Create: `UtterInkUITests/PipelineStateTests.swift`
- Create: `App/UITestSupport/UITestScenario.swift`
- Modify: `App/AppComposition.swift`
- Modify: `App/UtterInkApp.swift`
- Modify: `App/MenuBar/MenuBarRootView.swift`
- Modify: `App/Floating/FloatingRecorderView.swift`
- Modify: `App/History/LastResultView.swift`
- Modify: `App/History/HistoryView.swift`
- Modify: `App/Settings/SettingsRootView.swift`
- Modify: `App/Settings/GeneralSettingsView.swift`
- Modify: `App/Settings/PermissionSettingsView.swift`
- Modify: `App/Settings/RecognitionLanguageSettingsView.swift`
- Modify: `App/Settings/ShortcutSettingsView.swift`
- Modify: `App/Settings/SpeechModelSettingsView.swift`
- Modify: `App/Settings/OutputModeSettingsView.swift`
- Modify: `App/Settings/ProviderSettingsView.swift`
- Modify: `App/Settings/DiagnosticsSettingsView.swift`
- Modify: `App/Onboarding/OnboardingFlow.swift`
- Create: `docs/parity/accessibility-matrix.md`
- Modify: `Scripts/ci-local.sh`
- Create: `Tests/Scripts/test-ci-local-matrix.sh`

**Interfaces:**
- Consumes: `AppComposition.uiTest(scenario:)`.
- Produces: deterministic UI test scenarios and manual accessibility evidence rows.

- [ ] **Step 1: Add failing XCUITests**

Add an XcodeGen `bundle.ui-testing` target dependent on `UtterInk`, then modify the single existing `UtterInk` scheme so build/run/archive remain unchanged and test targets are exactly `UtterInkAppTests` plus `UtterInkUITests`:

```yaml
  UtterInkUITests:
    type: bundle.ui-testing
    platform: macOS
    deploymentTarget: "14.0"
    sources:
      - path: UtterInkUITests
    dependencies:
      - target: UtterInk
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
schemes:
  UtterInk:
    build:
      targets:
        UtterInk: all
        UtterInkAppTests: [test]
        UtterInkUITests: [test]
    run:
      config: Debug
    test:
      config: Debug
      targets:
        - name: UtterInkAppTests
        - name: UtterInkUITests
    archive:
      config: Release
```

Tests launch with `-uiTesting idle`, `recording`, `transcribing`, `polishFallback`, `targetChanged`, `history`, and `onboarding`. Assert each stage label, action availability, accessibility identifier, Settings route, and recovery behavior. Assert every icon-only control has a non-empty label.

- [ ] **Step 2: Run to verify failure**

```bash
xcodegen generate
xcodebuild -project UtterInk.xcodeproj -scheme UtterInk -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test
```

Expected: UI tests fail because scenario composition/identifiers are missing.

- [ ] **Step 3: Add deterministic UI-test composition and identifiers**

`UITestScenario` parses only the known scenario names and `AppComposition.uiTest(scenario:)` builds in-memory services. Under `#if DEBUG`, `UtterInkApp` recognizes `-uiTesting <known-scenario>` and selects that composition before creating its single model; missing/unknown values fail launch loudly. The Release build contains no UI-test selector/fixture strings and always uses `.live()`; add a source/build-policy assertion for that boundary. Modify the real menu, floating, history/result, every Settings route, and onboarding views listed in this task—not test-only mirrors—to add stable identifiers, non-empty icon-control labels, and state/error announcements. Required identifiers are `menu.status`, `menu.start`, `floating.status`, `floating.cancel`, `history.list`, `settings.sidebar`, `onboarding.next`, and `onboarding.testResult`; route controls may add deterministic names beneath those roots. Extend `ci-local.sh` to run package tests, the signed ATS probe, `UtterInkAppTests`, and a deterministic UI smoke subset. `test-ci-local-matrix.sh` injects command spies and proves every required command executes exactly once, unknown flags fail, and no branch silently skips App/ATS/UI tests.

- [ ] **Step 4: Create and execute the manual matrix**

`docs/parity/accessibility-matrix.md` rows cover menu, floating recorder, onboarding, each Settings route, history/result, dialogs, and each pipeline stage. Columns: name/role/value/actions, state/error VoiceOver announcement, keyboard traversal/visible focus/no trap/focus return, icon-only label, non-color distinction, light/dark, Increase Contrast, Differentiate Without Color, Reduce Motion, larger text/display clipping, result, macOS/build/architecture, reviewer/date. Require at least 4.5:1 normal-text contrast, 3:1 large text and essential non-text controls/focus indicators, or a documented stricter native-system equivalent. No blank result is accepted at release.

- [ ] **Step 5: Verify and commit**

```bash
xcodegen generate
xcodebuild -project UtterInk.xcodeproj -scheme UtterInk -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test
bash Tests/Scripts/test-ci-local-matrix.sh
git add UtterInk.xcodeproj
./Scripts/ci-local.sh
git add project.yml UtterInk.xcodeproj UtterInkUITests App/UITestSupport App/AppComposition.swift App/UtterInkApp.swift App/MenuBar App/Floating App/History App/Settings App/Onboarding docs/parity/accessibility-matrix.md Scripts/ci-local.sh Tests/Scripts/test-ci-local-matrix.sh
git commit -m "test: cover product states and accessibility"
```

---

### Task 9: Prove parity and remove the temporary source snapshot

**Files:**
- Create: `Scripts/check-parity-replacement.sh`
- Create: `docs/parity/utterink-parity-evidence.md`
- Delete: `LegacyParity/**`
- Modify: `Scripts/ci-local.sh`

**Interfaces:**
- Produces: final working tree with no temporary FlowType implementation and a durable test-evidence map.

- [ ] **Step 1: Write the evidence checker before deleting parity source**

The script must require one existing test/evidence path for every row in `flowtype-behavior-baseline.md`: lifecycle, hotkey, audio, model, language, output modes, providers, fallback, delivery, floating UI, onboarding/settings. It fails on `pending`, missing files, or failed matrix rows.

- [ ] **Step 2: Run it to verify failure**

Expected: FAIL until `docs/parity/utterink-parity-evidence.md` maps every behavior to an exact passing test or manual result.

- [ ] **Step 3: Fill evidence from actual passing commands, then remove the snapshot**

Record test class/method, command, date, commit, and intentional safety difference for each baseline row. Run the checker. Only after it passes, delete `LegacyParity/` and remove its test command from `Scripts/ci-local.sh`. Do not rewrite history; the approved import remains reviewable in earlier commits.

- [ ] **Step 4: Verify final product plan**

```bash
./Scripts/check-parity-replacement.sh
swift test --package-path Packages/UtterInkKit
xcodegen generate
xcodebuild -project UtterInk.xcodeproj -scheme UtterInk -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test
./Scripts/ci-local.sh
test ! -e LegacyParity
```

Expected: all pass; temporary parity directory is absent.

- [ ] **Step 5: Commit**

```bash
git add -A LegacyParity Scripts/ci-local.sh Scripts/check-parity-replacement.sh docs/parity/utterink-parity-evidence.md
git commit -m "refactor: complete UtterInk parity migration"
```

## Plan completion gate

Run the Task 9 verification command plus `git status --short`. Expected: all automated checks pass, matrix contains no failed/blank shipped-English rows, and tree is clean.
