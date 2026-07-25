import Accessibility
import SwiftUI
import UtterInkCore
import UtterInkServices

enum OnboardingStep: Int, CaseIterable, Identifiable, Sendable {
    case privacy
    case readiness
    case shortcutTest
    case testDictation

    var id: Self { self }

    var title: String {
        switch self {
        case .privacy: return "Privacy"
        case .readiness: return "Readiness"
        case .shortcutTest: return "Shortcut Test"
        case .testDictation: return "Test Dictation"
        }
    }
}

struct OnboardingFlow: View {
    @Bindable var model: OnboardingViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                stepContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(28)
            }
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.flow")
        .utterInkAccessibilityAnnouncement(model.accessibilityEvent)
        .onChange(of: model.step) { _, step in
            AccessibilityNotification.Announcement(
                "Step \(step.rawValue + 1): \(step.title)"
            ).post()
        }
        .onChange(of: model.failureMessage) { _, message in
            guard let message, model.pipelineState.stage != .failed else { return }
            AccessibilityNotification.Announcement("Error: \(message)").post()
        }
        .onChange(of: model.displayedRawText) { _, result in
            guard result != nil else { return }
            AccessibilityNotification.Announcement("Raw test result is ready.").post()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Welcome to UtterInk")
                .font(.title.bold())
            HStack(spacing: 8) {
                ForEach(OnboardingStep.allCases) { step in
                    VStack(alignment: .leading, spacing: 5) {
                        Capsule()
                            .fill(step.rawValue <= model.step.rawValue ? Color.accentColor : .secondary.opacity(0.25))
                            .frame(height: 5)
                        Text(step.title)
                            .font(.caption)
                            .foregroundStyle(step == model.step ? .primary : .secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Step \(step.rawValue + 1): \(step.title)")
                    .accessibilityValue(step == model.step ? "Current" : "")
                    .accessibilityIdentifier("onboarding.progress.\(step.rawValue)")
                }
            }
        }
        .padding(24)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .privacy:
            privacyStep
        case .readiness:
            readinessStep
        case .shortcutTest:
            shortcutStep
        case .testDictation:
            testDictationStep
        }
    }

    private var privacyStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeading(
                "Privacy",
                detail: "Start with a private local dictation. Provider setup and custom output modes can wait until Settings."
            )
            privacyCard(symbol: "waveform", text: model.audioPrivacyText)
            privacyCard(symbol: "externaldrive", text: model.historyPrivacyText)
            privacyCard(symbol: "network", text: model.remoteTextPrivacyText)

            Toggle(
                "Keep text history on this Mac",
                isOn: Binding(
                    get: { model.historyEnabled },
                    set: { enabled in
                        Task { await model.setHistoryEnabled(enabled) }
                    }
                )
            )
            .disabled(model.isHistoryChangePending)
            .accessibilityLabel("Keep text history on this Mac")
            .accessibilityIdentifier("onboarding.historyToggle")

            Text("When enabled, raw and final transcript text is stored locally. Audio is never kept as history.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.step.privacy")
    }

    private var readinessStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeading(
                "Readiness",
                detail: "Microphone access and a ready local speech model are required. Accessibility remains optional."
            )

            permissionRow(
                title: "Microphone",
                state: model.microphonePermission,
                detail: "Required to record a test dictation.",
                actionTitle: "Open Microphone Settings",
                action: model.openMicrophoneSettings
            )
            permissionRow(
                title: "Accessibility",
                state: model.accessibilityPermission,
                detail: model.accessibilityExplanation,
                actionTitle: "Open Accessibility Settings",
                action: model.openAccessibilitySettings
            )

            Divider()

            Picker(
                "Recognition Language",
                selection: Binding(
                    get: {
                        switch model.recognition {
                        case .automatic: return ""
                        case let .fixed(languageCode): return languageCode
                        }
                    },
                    set: { code in
                        Task {
                            await model.setRecognition(
                                code.isEmpty ? .automatic : .fixed(languageCode: code)
                            )
                        }
                    }
                )
            ) {
                Text("Automatic").tag("")
                Text("English").tag("en")
            }
            .accessibilityLabel("Recognition Language")
            .accessibilityIdentifier("onboarding.recognition")

            VStack(alignment: .leading, spacing: 10) {
                Text("Speech Model").font(.headline)
                ForEach(model.speechModelOptions) { option in
                    Button {
                        Task { await model.selectSpeechModel(option.id) }
                    } label: {
                        HStack {
                            Image(systemName: model.selectedSpeechModelID == option.id
                                ? "largecircle.fill.circle"
                                : "circle")
                            VStack(alignment: .leading) {
                                HStack(spacing: 8) {
                                    Text(option.title)
                                    if option.isRecommended {
                                        SpeechModelRecommendationBadge()
                                            .accessibilityIdentifier("onboarding.speechModel.recommended.\(option.id)")
                                    }
                                }
                                Text("\(option.descriptor.displayName) · \(option.diskImpact) on disk")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.isRecommended
                        ? "Select \(option.title) speech model, recommended"
                        : "Select \(option.title) speech model")
                    .accessibilityValue(model.selectedSpeechModelID == option.id ? "Selected" : "Not selected")
                    .accessibilityIdentifier("onboarding.speechModel.\(option.id)")
                }
            }

            modelReadiness
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.step.readiness")
    }

    private var shortcutStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeading(
                "Shortcut Test",
                detail: "Keep this window open and press the configured shortcut. The test completes here without opening Settings."
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("Configured Shortcut")
                    .font(.headline)
                DictationShortcutRecorder(accessibleName: "Configured Dictation Shortcut")
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("onboarding.shortcutRecorder")
            }
            .padding(12)
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.separator, lineWidth: 1)
            }

            Button(model.isShortcutProbeArmed ? "Waiting for Shortcut…" : "Arm Shortcut Test") {
                Task { await model.armShortcutProbe() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isShortcutProbeArmed)
            .accessibilityIdentifier("onboarding.shortcutArm")

            if model.shortcutTestPassed {
                Label("Shortcut detected in this window.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Shortcut test passed")
                    .accessibilityValue("Detected")
                    .accessibilityIdentifier("onboarding.shortcutResult")
            } else {
                Label(
                    model.isShortcutProbeArmed
                        ? "Press your configured shortcut now."
                        : "Arm the test when you are ready.",
                    systemImage: model.isShortcutProbeArmed ? "keyboard.badge.ellipsis" : "keyboard"
                )
                .foregroundStyle(.secondary)
                .accessibilityLabel("Shortcut test status")
                .accessibilityValue(
                    model.isShortcutProbeArmed
                        ? "Waiting for the configured shortcut"
                        : "Not started"
                )
                .accessibilityIdentifier("onboarding.shortcutResult")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.step.shortcutTest")
    }

    private var testDictationStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeading(
                "Test Dictation",
                detail: "This test always uses local Raw mode and delivers only to this onboarding window."
            )

            dictationControls

            if let rawText = model.displayedRawText {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Raw Result")
                        .font(.headline)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(rawText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel("Raw test result")
                            .accessibilityValue(rawText)
                            .accessibilityIdentifier("onboarding.testResult")
                        Button("Copy") { model.copyResult() }
                            .accessibilityLabel("Copy raw test result")
                            .accessibilityIdentifier("onboarding.copyResult")
                    }
                    .padding(.vertical, 6)
                }
                .padding(12)
                .background(.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.separator, lineWidth: 1)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Safe In-App Paste Test")
                        .font(.headline)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Click below, then paste. This field sends no paste event to another app.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        TextField(
                            "Paste here",
                            text: $model.testPasteText,
                            axis: .vertical
                        )
                            .font(.body)
                            .textFieldStyle(.plain)
                            .lineLimit(4...8)
                            .padding(8)
                            .frame(minHeight: 90)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(.separator, lineWidth: 1)
                            }
                            .accessibilityLabel("In-app paste test field")
                            .accessibilityIdentifier("onboarding.pasteField")
                    }
                    .padding(.vertical, 6)
                }
                .padding(12)
                .background(.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.separator, lineWidth: 1)
                }

                if model.onboardingCompleted {
                    Label("First dictation complete.", systemImage: "checkmark.seal.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                        .accessibilityLabel("Onboarding status")
                        .accessibilityValue("First dictation complete")
                        .accessibilityIdentifier("onboarding.completed")
                }
            } else {
                Text("Your recoverable Raw result will appear here after transcription finishes.")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.step.testDictation")
    }

    @ViewBuilder
    private var dictationControls: some View {
        switch model.pipelineState.stage {
        case .recording:
            HStack {
                Button("Stop", action: model.stopTestDictation)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("onboarding.dictationStop")
                Button("Cancel", role: .cancel, action: model.cancelTestDictation)
                    .accessibilityIdentifier("onboarding.dictationCancel")
            }
        case .requestingPermission, .stopping, .transcribing, .polishing, .delivering:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text(stageLabel)
                    .accessibilityLabel("Test dictation status")
                    .accessibilityValue(stageLabel)
                    .accessibilityIdentifier("onboarding.dictationStatus")
                    .accessibilityAddTraits(.updatesFrequently)
                Spacer()
                Button("Cancel", role: .cancel, action: model.cancelTestDictation)
                    .accessibilityIdentifier("onboarding.dictationCancel")
            }
        case .idle, .completed, .failed:
            Button("Start Test Dictation") {
                Task { await model.startTestDictation() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canStartTestDictation)
            .accessibilityIdentifier("onboarding.dictationStart")
        }
    }

    private var footer: some View {
        HStack {
            if let failureMessage = model.failureMessage {
                Label(failureMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .accessibilityLabel("Error")
                    .accessibilityValue(failureMessage)
                    .accessibilityIdentifier("onboarding.error")
                    .accessibilityAddTraits(.updatesFrequently)
            }
            Spacer()
            Button("Back") { model.goBack() }
                .disabled(model.step == .privacy)
                .accessibilityIdentifier("onboarding.back")
            if model.step != .testDictation {
                Button("Continue") { model.advance() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("onboarding.next")
            } else {
                Button(model.onboardingCompleted ? "Done" : "Close") {
                    Task { await model.close() }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("onboarding.close")
            }
        }
        .padding(20)
    }

    private func stepHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2.bold())
            Text(detail).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(detail)
        .accessibilityIdentifier("onboarding.step")
    }

    private func privacyCard(symbol: String, text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Color.accentColor)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
    }

    private func permissionRow(
        title: String,
        state: PermissionState,
        detail: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: permissionSymbol(state))
                .foregroundStyle(state == .granted ? .green : .orange)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(title): \(permissionLabel(state))").font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if state != .granted {
                Button(actionTitle, action: action)
                    .accessibilityIdentifier("onboarding.permission.\(title.lowercased()).open")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) permission")
        .accessibilityValue(permissionLabel(state))
        .accessibilityIdentifier("onboarding.permission.\(title.lowercased())")
    }

    private var modelReadiness: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(modelStateLabel, systemImage: model.selectedModelIsReady ? "checkmark.circle.fill" : "internaldrive")
                .foregroundStyle(model.selectedModelIsReady ? .green : .primary)
                .accessibilityLabel("Speech model status")
                .accessibilityValue(modelStateLabel)
                .accessibilityIdentifier("onboarding.modelStatus")
                .accessibilityAddTraits(.updatesFrequently)
            if let progress = model.modelProgress {
                ProgressView(value: progress)
                    .accessibilityLabel("Speech model preparation progress")
                    .accessibilityValue("\(Int((progress * 100).rounded())) percent")
                    .accessibilityIdentifier("onboarding.modelProgress")
            }
        }
    }

    private var modelStateLabel: String {
        switch model.speechModelState {
        case let .missing(modelID): return "\(modelID) is not downloaded."
        case let .downloading(modelID, _): return "Downloading \(modelID)…"
        case let .loading(modelID): return "Loading \(modelID)…"
        case let .ready(modelID) where modelID == model.selectedSpeechModelID:
            return "\(modelID) is ready."
        case let .ready(modelID):
            return "\(modelID) is ready, but \(model.selectedSpeechModelID) is selected."
        case let .failed(modelID, code, _): return "\(modelID) failed: \(code.rawValue)."
        }
    }

    private var stageLabel: String {
        switch model.pipelineState.stage {
        case .requestingPermission: return "Requesting microphone permission…"
        case .stopping: return "Finishing recording…"
        case .transcribing: return "Transcribing locally…"
        case .polishing: return "Preparing Raw result…"
        case .delivering: return "Returning result to onboarding…"
        case .idle, .recording, .completed, .failed: return ""
        }
    }

    private func permissionLabel(_ state: PermissionState) -> String {
        switch state {
        case .notDetermined: return "Not Requested"
        case .denied: return "Denied"
        case .granted: return "Allowed"
        }
    }

    private func permissionSymbol(_ state: PermissionState) -> String {
        switch state {
        case .notDetermined: return "questionmark.circle"
        case .denied: return "exclamationmark.triangle.fill"
        case .granted: return "checkmark.circle.fill"
        }
    }
}
