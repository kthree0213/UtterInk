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

struct FloatingRecorderView: View {
    @Bindable var model: AppModel
    let clock: any AppClock

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingLastResult = false

    var body: some View {
        let motion = FloatingMotionPolicy(reduceMotion: reduceMotion)
        TimelineView(.animation(minimumInterval: 0.1, paused: model.pipeline.stage != .recording)) { _ in
            content(metrics: FloatingRecorderMetrics(
                telemetry: model.recordingTelemetry,
                now: clock.now
            ))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minWidth: 268)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.separator.opacity(0.65), lineWidth: 1)
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
        .onExitCommand {
            model.performEscape()
        }
        .onChange(of: model.pipeline.stage) { _, stage in
            if stage != .completed, stage != .failed {
                isShowingLastResult = false
            }
        }
        .onChange(of: model.latestResult?.sessionID) { _, sessionID in
            if sessionID == nil {
                isShowingLastResult = false
            }
        }
    }

    @ViewBuilder
    private func content(metrics: FloatingRecorderMetrics) -> some View {
        let presentation = StagePresentation(
            state: model.pipeline,
            sessionPresentation: model.sessionPresentation
        )

        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Label(presentation.label, systemImage: presentation.systemImage)
                    .font(.headline)
                    .accessibilityLabel(EnglishCopy.status)
                    .accessibilityValue(presentation.accessibilityValue)

                Spacer(minLength: 12)

                if let elapsed = metrics.elapsed, model.pipeline.stage == .recording {
                    Text(Self.elapsedText(elapsed))
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel("Recording elapsed time")
                }
            }

            if model.pipeline.stage == .recording, let inputLevel = metrics.inputLevel {
                ProgressView(value: inputLevel)
                    .progressViewStyle(.linear)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: inputLevel)
                    .accessibilityLabel("Microphone input level")
                    .accessibilityValue("\(Int((inputLevel * 100).rounded())) percent")
            }

            if let warning = presentation.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
            } else if model.pipeline.stage == .completed {
                Label(EnglishCopy.resultSuccess, systemImage: "checkmark")
                    .font(.caption)
            }

            actionRow(presentation: presentation)
        }
    }

    @ViewBuilder
    private func actionRow(presentation: StagePresentation) -> some View {
        HStack(spacing: 10) {
            switch presentation.primaryAction {
            case .start:
                Button {
                    model.start()
                } label: {
                    Label(EnglishCopy.start, systemImage: "text.cursor")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel(EnglishCopy.start)
                .help(EnglishCopy.start)
            case .stop:
                Button {
                    model.stop()
                } label: {
                    Label(EnglishCopy.stop, systemImage: "square.fill")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel(EnglishCopy.stop)
                .help(EnglishCopy.stop)
            case .none:
                EmptyView()
            }

            switch presentation.secondaryAction {
            case .cancel:
                Button(role: .cancel) {
                    model.performEscape()
                } label: {
                    Label(EnglishCopy.cancel, systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel(EnglishCopy.cancel)
                .help("Cancel the active dictation")
            case .dismiss:
                Button {
                    model.acknowledge()
                } label: {
                    Label(EnglishCopy.dismiss, systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel(EnglishCopy.dismiss)
                .help("Dismiss the finished dictation")
            case .none:
                EmptyView()
            }

            Spacer()

            if let result = model.latestResult,
               model.pipeline.stage == .completed || model.pipeline.stage == .failed {
                Button {
                    isShowingLastResult.toggle()
                } label: {
                    Label(EnglishCopy.viewLatestResult, systemImage: "rectangle.on.rectangle")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel(EnglishCopy.viewLatestResult)
                .help(EnglishCopy.viewLatestResult)
                .popover(isPresented: $isShowingLastResult, arrowEdge: .top) {
                    LastResultView(
                        model: HistoryViewModel(controller: model.controller),
                        compact: true
                    )
                    .frame(width: 390, height: 280)
                }

                Button {
                    model.copyResult(result.sessionID)
                } label: {
                    Label(EnglishCopy.copyLatestResult, systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel(EnglishCopy.copyLatestResult)
                .help(EnglishCopy.copyLatestResult)

                Button {
                    model.pasteAgain(result.sessionID)
                } label: {
                    Label(EnglishCopy.pasteLatestResult, systemImage: "arrow.up.doc")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel(EnglishCopy.pasteLatestResult)
                .help(EnglishCopy.pasteLatestResult)
            }
        }
        .buttonStyle(.bordered)
    }

    static func elapsedText(_ elapsed: TimeInterval) -> String {
        let seconds = max(0, Int(elapsed.rounded(.down)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
