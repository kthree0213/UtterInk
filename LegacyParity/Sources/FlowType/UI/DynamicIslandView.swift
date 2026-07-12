import SwiftUI

struct DynamicIslandView: View {
    @ObservedObject var appState: AppState
    @AppStorage(AppUILanguage.storageKey) private var uiLanguage = "en"
    @AppStorage("dynamicIslandMicCalloutDismissed") private var micCalloutDismissed = false

    private var l10n: MenuLocalization { MenuLocalization(useChinese: AppUILanguage.isChinese(uiLanguage)) }

    private var showFirstCallout: Bool {
        !micCalloutDismissed && !appState.isRecording && !appState.isProcessing
    }

    private var isProminent: Bool {
        showFirstCallout || appState.isRecording || appState.isProcessing || appState.accessibilityNotice != nil
            || appState.whisperModelLoadPhase != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showFirstCallout {
                firstCalloutBanner
            }

            HStack(alignment: .top, spacing: 12) {
                if appState.isProcessing {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text(l10n.processing)
                        .foregroundColor(.white)
                } else {
                    VStack(spacing: 5) {
                        Button(action: micButtonTapped) {
                            micButtonLabel
                        }
                        .buttonStyle(.plain)
                        .help(l10n.dynamicIslandMicHelp)

                        Text(l10n.dynamicIslandMicFootnote)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.42))
                            .multilineTextAlignment(.center)
                            .frame(minWidth: 100, maxWidth: 120)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        if appState.isRecording {
                            if let start = appState.recordingStartedAt {
                                TimelineView(.animation(minimumInterval: 0.25)) { _ in
                                    Text(Self.formatMMSS(since: start))
                                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                                        .foregroundStyle(.white)
                                }
                            }
                            Text(l10n.listening)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.white)
                            Text(l10n.dynamicIslandHintRecording)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.72))
                        } else {
                            Text(l10n.dynamicIslandHintIdle)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.58))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if appState.whisperModelLoadPhase != nil, !appState.isProcessing {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        appState.whisperModelLoadPhase == .downloading
                            ? l10n.downloadingModel
                            : l10n.loadingModel
                    )
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.9))
                    if let p = appState.whisperModelLoadProgress {
                        ProgressView(value: p, total: 1)
                            .tint(.white)
                    } else {
                        ProgressView()
                            .scaleEffect(0.85)
                            .tint(.white)
                    }
                }
            }

            if let notice = appState.accessibilityNotice, !notice.isEmpty {
                Text(notice)
                    .font(.caption2)
                    .foregroundColor(.yellow.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
                switch appState.userNoticeAction {
                case .accessibility:
                    Button(l10n.openAXSettings) {
                        TextInjector.openSystemAccessibilitySettings()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundColor(.accentColor)
                case .microphone:
                    Button(l10n.openMicrophonePrivacy) {
                        TextInjector.openSystemMicrophonePrivacySettings()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundColor(.accentColor)
                case .none:
                    EmptyView()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 400)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(red: 0.06, green: 0.06, blue: 0.08).opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        )
        .opacity(isProminent ? 1.0 : 0.78)
        .animation(.spring(), value: appState.isRecording)
        .animation(.easeOut(duration: 0.12), value: appState.microphoneInputLevel)
        .animation(.spring(), value: appState.isProcessing)
        .animation(.spring(), value: appState.accessibilityNotice)
        .animation(.spring(), value: appState.userNoticeAction)
        .animation(.spring(), value: appState.whisperModelLoadPhase)
        .animation(.spring(), value: appState.whisperModelLoadProgress)
        .gesture(
            DragGesture(minimumDistance: 24)
                .onChanged { _ in
                    guard let event = NSApp.currentEvent, let window = event.window else { return }
                    window.performDrag(with: event)
                }
        )
    }

    private var firstCalloutBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "hand.point.up.left.fill")
                .font(.caption)
                .foregroundStyle(.cyan.opacity(0.95))
                .padding(.top, 2)
            Text(l10n.dynamicIslandFirstCallout)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.cyan.opacity(0.35), lineWidth: 1)
        )
    }

    private var micButtonLabel: some View {
        Group {
            if appState.isRecording {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                    micRecordingContent(
                        level: appState.microphoneInputLevel,
                        t: context.date.timeIntervalSince1970
                    )
                }
            } else {
                micIdleGlyph
            }
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }

    private var micIdleGlyph: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 26, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.95))
            .shadow(color: Color.white.opacity(0.35), radius: 5, y: 1)
    }

    /// 录音中：静音时为纯白；有声时随 `level` 缩放并叠加水感波纹（浅青白渐变）。
    private func micRecordingContent(level: CGFloat, t: TimeInterval) -> some View {
        let gate: CGFloat = 0.07
        let active = min(1, max(0, (level - gate) / max(0.001, 1 - gate)))
        let micScale: CGFloat = 1.0 + 0.16 * active
        let glowAqua = Color(red: 0.45, green: 0.82, blue: 0.98)

        return ZStack {
            ForEach(0..<3, id: \.self) { i in
                let phase = t * 2.15 + Double(i) * 2.05
                let wobble = 0.05 * sin(phase)
                let ringScale: CGFloat = 1.12 + 0.42 * active + CGFloat(wobble)
                let ringOpacity = 0.05 + 0.38 * active * (1 - CGFloat(i) * 0.26)
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                glowAqua.opacity(ringOpacity),
                                Color.white.opacity(ringOpacity * 0.9)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.15
                    )
                    .frame(width: 36, height: 36)
                    .scaleEffect(ringScale)
            }

            Image(systemName: "mic.fill")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color.white,
                            Color(red: 0.82, green: 0.95, blue: 1.0).opacity(0.88 + 0.12 * Double(active))
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .scaleEffect(micScale)
                .shadow(color: glowAqua.opacity(0.2 + 0.5 * Double(active)), radius: 4 + 16 * active, y: 0)
                .shadow(color: Color.white.opacity(0.3 + 0.35 * Double(active)), radius: 2 + 7 * active, y: 1)
        }
    }

    private func micButtonTapped() {
        if !micCalloutDismissed {
            micCalloutDismissed = true
        }
        if appState.isRecording {
            appState.coordinator?.stopRecording()
        } else {
            appState.coordinator?.startRecording()
        }
    }

    private static func formatMMSS(since start: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
