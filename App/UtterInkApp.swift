import Accessibility
import SwiftUI
import UtterInkCore

@main
struct UtterInkApp: App {
    private let composition: AppComposition?
    @State private var model: AppModel

    @MainActor
    init() {
#if DEBUG
        if let scenario = UITestScenario.requested(
            in: ProcessInfo.processInfo.arguments
        ) {
            self.init(
                isHostedUnitTest: false,
                compositionFactory: { AppComposition.uiTest(scenario: scenario) }
            )
            return
        }
#endif
        self.init(
            isHostedUnitTest:
                ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
            compositionFactory: AppComposition.live
        )
    }

    @MainActor
    init(
        isHostedUnitTest: Bool,
        compositionFactory: @MainActor () throws -> AppComposition
    ) {
        if isHostedUnitTest {
            composition = nil
            _model = State(initialValue: AppModel(controller: InertAppController()))
            return
        }

        let composition: AppComposition
        do {
            composition = try compositionFactory()
        } catch {
            self.composition = nil
            _model = State(
                initialValue: AppModel.unavailable(controller: InertAppController())
            )
            return
        }
        self.composition = composition
        _model = State(initialValue: composition.model)

        Task { @MainActor [composition] in
            await composition.start()
        }
    }

    var usesLiveComposition: Bool { composition != nil }
    var readinessForTests: AppReadiness { model.readiness }

    var body: some Scene {
        MenuBarExtra {
            MenuBarRootView(
                model: model,
                settingsStore: composition?.features.settings,
                openOnboarding: composition.map { composition in
                    { composition.showOnboarding() }
                },
                settingsNavigation: composition?.settingsModel.navigation
            )
        } label: {
            MenuBarStatusLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window(EnglishCopy.latestResult, id: AppWindowID.lastResult) {
            LastResultView(
                model: HistoryViewModel(controller: model.controller)
            )
            .frame(minWidth: 420, minHeight: 280)
        }
        .defaultSize(width: 520, height: 420)

        Window(EnglishCopy.history, id: AppWindowID.history) {
            HistoryView(
                model: HistoryViewModel(controller: model.controller)
            )
            .frame(minWidth: 620, minHeight: 420)
        }
        .defaultSize(width: 760, height: 620)

        Settings {
            if let settingsModel = composition?.settingsModel {
                SettingsRootView(model: settingsModel)
            } else {
                ContentUnavailableView(
                    "Settings Unavailable",
                    systemImage: "exclamationmark.triangle.fill",
                    description: Text("Quit and reopen UtterInk to try again.")
                )
            }
        }
    }
}

private struct MenuBarStatusLabel: View {
    @Bindable var model: AppModel

    var body: some View {
        let status = MenuBarStatusAccessibilityPresentation(
            readiness: model.readiness,
            state: model.pipeline,
            sessionPresentation: model.sessionPresentation
        )

        Label {
            Text(ProductIdentity.name)
        } icon: {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .accessibilityHidden(true)
        }
            .labelStyle(.iconOnly)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ProductIdentity.name)
            .accessibilityValue(status.value)
            .accessibilityIdentifier("menu.statusItem")
            .onChange(of: status) { _, status in
                AccessibilityNotification.Announcement(status.announcement).post()
            }
    }
}

struct MenuBarStatusAccessibilityPresentation: Equatable {
    let value: String

    var announcement: String {
        "\(EnglishCopy.status): \(value)"
    }

    init(
        readiness: AppReadiness,
        state: PipelineState,
        sessionPresentation: SessionPresentationContext?
    ) {
        switch readiness {
        case .pending:
            value = EnglishCopy.starting
        case .failed:
            value = EnglishCopy.appUnavailable
        case .ready:
            let stage = StagePresentation(
                state: state,
                sessionPresentation: sessionPresentation
            )
            var components = [stage.accessibilityValue]
            if let result = state.result ?? state.failure?.recoverableResult {
                components.append(Self.resultVariant(result.source))
                if let delivery = result.delivery {
                    components.append(Self.deliveryOutcome(delivery))
                }
            }
            value = components.joined(separator: ". ")
        }
    }

    private static func resultVariant(_ source: ResultSource) -> String {
        switch source {
        case .raw:
            return "Raw result"
        case .polished:
            return "Polished result"
        case .rawFallback:
            return "Raw fallback result"
        }
    }

    private static func deliveryOutcome(_ outcome: DeliveryOutcome) -> String {
        switch outcome {
        case .pasteEventDispatched:
            return "Paste event sent"
        case .deliveredToOnboardingTest:
            return "Sent to Onboarding Test"
        case .copiedByPreference:
            return "Copied to Clipboard by preference"
        case .copiedByUser:
            return "Copied by you"
        case .manualCopyRequired:
            return "Manual copy required"
        }
    }
}

@MainActor
private final class InertAppController: DictationControlling {
    var state: PipelineState = .idle
    var speechModelState: SpeechModelState = .missing(modelID: "small")
    var speechModelCacheActionStatus: SpeechModelCacheActionStatus = .idle
    var volatileResults: [DictationResult] = []
    var historyRecords: [HistoryRecord] = []
    var historyControlStatus: HistoryControlStatus = .settled(enabled: true)
    var recordingTelemetry: RecordingTelemetry?
    var sessionPresentation: SessionPresentationContext?
    var speechModelCatalog: [SpeechModelDescriptor] = []
    var activeSpeechModelID: String?
    var preparingSpeechModelID: String?

    func bootstrap() async {}
    func send(_ intent: UserIntent) {}
    func prepareSpeechModel(_ modelID: String) {}
    func cancelSpeechModelPreparation() {}
    func deleteCachedSpeechModel(_ modelID: String) {}
}
