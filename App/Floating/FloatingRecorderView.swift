import SwiftUI
import UtterInkCore

enum FloatingMotionPolicy: Equatable {
    case opacityOnly
    case springAndScale

    init(reduceMotion: Bool) {
        self = reduceMotion ? .opacityOnly : .springAndScale
    }
}

struct FloatingRecorderMetrics: Equatable {
    let elapsed: TimeInterval?
    let inputLevel: Double?

    init(telemetry: RecordingTelemetry?, now: Date) {
        guard let telemetry else {
            elapsed = nil
            inputLevel = nil
            return
        }
        elapsed = max(0, now.timeIntervalSince(telemetry.startedAt))
        inputLevel = min(1, max(0, Double(telemetry.inputLevel)))
    }
}

struct FloatingWaveformBuffer: Equatable {
    static let defaultSampleCount = 19
    static let restingLevel = 0.06

    private(set) var samples: [Double]

    init(sampleCount: Int = defaultSampleCount) {
        samples = Array(
            repeating: Self.restingLevel,
            count: max(3, sampleCount)
        )
    }

    mutating func append(_ inputLevel: Double) {
        let normalized = min(1, max(0, inputLevel))
        samples.removeFirst()
        samples.append(max(Self.restingLevel, normalized))
    }

    mutating func reset() {
        samples = Array(repeating: Self.restingLevel, count: samples.count)
    }
}

enum FloatingCompletionPolicy {
    static func requiresPasteRecovery(
        stage: PipelineStage,
        result: DictationResult
    ) -> Bool {
        if case .manualCopyRequired = result.delivery {
            return true
        }
        // A result that has not reached any delivery outcome still needs an
        // explicit Copy/Paste action. Warnings attached to an already
        // delivered result (notably History persistence) do not.
        return result.delivery == nil
    }

    static func requiresRecovery(_ state: PipelineState) -> Bool {
        guard state.stage == .completed || state.stage == .failed else {
            return false
        }
        guard let result = state.result ?? state.failure?.recoverableResult else {
            return true
        }
        return requiresPasteRecovery(stage: state.stage, result: result)
    }

    static func shouldAutoDismiss(_ state: PipelineState) -> Bool {
        guard state.stage == .completed,
              !requiresRecovery(state),
              let result = state.result else { return false }
        switch result.delivery {
        case .pasteEventDispatched?, .copiedByPreference?, .copiedByUser?,
             .deliveredToOnboardingTest?:
            return true
        case .manualCopyRequired?, nil:
            return false
        }
    }

    static func successLabel(for result: DictationResult?) -> String {
        switch result?.delivery {
        case .pasteEventDispatched?:
            return EnglishCopy.resultPasted
        case .copiedByPreference?, .copiedByUser?:
            return EnglishCopy.resultCopied
        case .deliveredToOnboardingTest?, .manualCopyRequired?, nil:
            return EnglishCopy.resultSuccess
        }
    }

    static func nonBlockingNotice(for result: DictationResult?) -> String? {
        guard result?.warning == .historyWrite else { return nil }
        return "Not saved to History"
    }
}

struct FloatingRecorderView: View {
    @Bindable var model: AppModel
    let clock: any AppClock

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var waveform = FloatingWaveformBuffer()

    var body: some View {
        let motion = FloatingMotionPolicy(reduceMotion: reduceMotion)
        TimelineView(
            .animation(
                minimumInterval: 0.1,
                paused: model.pipeline.stage != .recording
            )
        ) { _ in
            content(metrics: FloatingRecorderMetrics(
                telemetry: model.recordingTelemetry,
                now: clock.now
            ))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(.separator.opacity(0.55), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        .transition(
            motion == .opacityOnly
                ? .opacity
                : .opacity.combined(with: .scale(scale: 0.97))
        )
        .animation(
            motion == .opacityOnly
                ? .easeOut(duration: 0.12)
                : .spring(response: 0.24, dampingFraction: 0.84),
            value: model.pipeline.stage
        )
        .onAppear {
            if let inputLevel = model.recordingTelemetry?.inputLevel {
                waveform.append(Double(inputLevel))
            }
        }
        .onChange(of: model.recordingTelemetry?.inputLevel) { _, inputLevel in
            guard let inputLevel else { return }
            waveform.append(Double(inputLevel))
        }
        .onChange(of: model.pipeline.stage) { _, stage in
            if stage == .recording {
                waveform.reset()
                if let inputLevel = model.recordingTelemetry?.inputLevel {
                    waveform.append(Double(inputLevel))
                }
            }
        }
        .onExitCommand {
            model.performEscape()
        }
    }

    @ViewBuilder
    private func content(metrics: FloatingRecorderMetrics) -> some View {
        let state = model.pipeline
        let presentation = StagePresentation(
            state: state,
            sessionPresentation: model.sessionPresentation
        )

        switch state.stage {
        case .idle:
            EmptyView()
        case .recording:
            recordingContent(metrics: metrics)
        case .requestingPermission, .stopping, .transcribing, .polishing, .delivering:
            processingContent(presentation: presentation)
        case .completed:
            if FloatingCompletionPolicy.requiresRecovery(state) {
                recoveryContent(presentation: presentation)
            } else {
                successContent(result: state.result)
            }
        case .failed:
            recoveryContent(presentation: presentation)
        }
    }

    private func recordingContent(metrics: FloatingRecorderMetrics) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Listening")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(EnglishCopy.status)
                    .accessibilityValue("Listening")
                    .accessibilityIdentifier("floating.status")
                    .accessibilityAddTraits(.updatesFrequently)

                Text(Self.elapsedText(metrics.elapsed ?? 0))
                    .font(.system(.headline, design: .monospaced))
                    .monospacedDigit()
                    .accessibilityLabel("Recording elapsed time")
                    .accessibilityValue(Self.elapsedText(metrics.elapsed ?? 0))
                    .accessibilityIdentifier("floating.elapsed")
            }

            LiveWaveformView(
                samples: displayedWaveform(currentLevel: metrics.inputLevel),
                reduceMotion: reduceMotion
            )
            .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Microphone input level")
            .accessibilityValue(
                "\(Int(((metrics.inputLevel ?? 0) * 100).rounded())) percent"
            )
            .accessibilityIdentifier("floating.inputLevel")

            Button {
                model.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .accessibilityLabel(EnglishCopy.stop)
            .accessibilityIdentifier("floating.stop")
            .help(EnglishCopy.stop)
        }
    }

    private func processingContent(presentation: StagePresentation) -> some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)

            Text(presentation.label)
                .font(.headline)
                .accessibilityLabel(EnglishCopy.status)
                .accessibilityValue(presentation.label)
                .accessibilityIdentifier("floating.status")
                .accessibilityAddTraits(.updatesFrequently)

            Spacer(minLength: 8)

            Button(role: .cancel) {
                model.performEscape()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .accessibilityLabel(EnglishCopy.cancel)
            .accessibilityIdentifier("floating.cancel")
            .help("Cancel the active dictation")
        }
    }

    private func successContent(result: DictationResult?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(FloatingCompletionPolicy.successLabel(for: result))
                    .font(.headline)
                    .accessibilityLabel(EnglishCopy.status)
                    .accessibilityValue(FloatingCompletionPolicy.successLabel(for: result))
                    .accessibilityIdentifier("floating.status")

                if let notice = FloatingCompletionPolicy.nonBlockingNotice(for: result) {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Notice")
                        .accessibilityValue(notice)
                        .accessibilityIdentifier("floating.notice")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func recoveryContent(presentation: StagePresentation) -> some View {
        let result = model.pipeline.result ?? model.pipeline.failure?.recoverableResult
        let warning = presentation.warning ?? EnglishCopy.failedWarning

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Needs Attention", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                    .accessibilityLabel(EnglishCopy.status)
                    .accessibilityValue("Needs Attention")
                    .accessibilityIdentifier("floating.status")

                Spacer(minLength: 8)

                Button {
                    model.acknowledge()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .accessibilityLabel(EnglishCopy.dismiss)
                .accessibilityIdentifier("floating.dismiss")
                .help("Dismiss the finished dictation")
            }

            Text(warning)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .accessibilityLabel("Warning")
                .accessibilityValue(warning)
                .accessibilityIdentifier("floating.warning")

            if let result {
                HStack(spacing: 8) {
                    Button {
                        model.copyResult(result.sessionID)
                    } label: {
                        Label(EnglishCopy.copyResult, systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("floating.copyLatest")
                    .help(EnglishCopy.copyLatestResult)

                    Button {
                        model.pasteAgain(result.sessionID)
                    } label: {
                        Label(EnglishCopy.pasteLatestResult, systemImage: "arrow.up.doc")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("floating.pasteLatest")
                    .help(EnglishCopy.pasteLatestResult)
                }
            }
        }
    }

    private func displayedWaveform(currentLevel: Double?) -> [Double] {
        guard let currentLevel, !waveform.samples.isEmpty else {
            return waveform.samples
        }
        var samples = waveform.samples
        samples[samples.index(before: samples.endIndex)] = max(
            FloatingWaveformBuffer.restingLevel,
            min(1, max(0, currentLevel))
        )
        return samples
    }

    static func elapsedText(_ elapsed: TimeInterval) -> String {
        let seconds = max(0, Int(elapsed.rounded(.down)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct LiveWaveformView: View {
    let samples: [Double]
    let reduceMotion: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3, height: max(4, 4 + sample * 28))
            }
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.08),
            value: samples
        )
    }
}
