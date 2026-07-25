import AppKit
import Observation
import SwiftUI
import UtterInkCore

enum FloatingVisibilityPolicy {
    static func shouldShow(
        isEnabled: Bool,
        readiness: AppReadiness,
        stage: PipelineStage
    ) -> Bool {
        isEnabled && readiness == .ready && stage != .idle
    }
}

enum FloatingPanelLayout {
    static func size(for state: PipelineState) -> NSSize {
        switch state.stage {
        case .recording:
            return NSSize(width: 340, height: 92)
        case .requestingPermission, .stopping, .transcribing, .polishing, .delivering:
            return NSSize(width: 330, height: 84)
        case .completed:
            if FloatingCompletionPolicy.requiresRecovery(state) {
                return NSSize(width: 390, height: 162)
            }
            return FloatingCompletionPolicy.nonBlockingNotice(for: state.result) == nil
                ? NSSize(width: 270, height: 72)
                : NSSize(width: 290, height: 84)
        case .failed:
            return NSSize(width: 390, height: 162)
        case .idle:
            return NSSize(width: 300, height: 80)
        }
    }
}

@MainActor
final class FloatingWindowController {
    private let model: AppModel
    private let clock: any AppClock
    private let panel: FloatingRecorderPanel
    private let completionDismissDelay: Duration

    private var isStarted = false
    private var isEnabled = false
    private var observationGeneration: UInt64 = 0
    private var completionDismissTask: Task<Void, Never>?
    private var completionDismissSessionID: SessionID?

    init(
        model: AppModel,
        clock: any AppClock,
        completionDismissDelay: Duration = .seconds(2)
    ) {
        self.model = model
        self.clock = clock
        self.completionDismissDelay = completionDismissDelay

        let panel = FloatingRecorderPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 92),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.panel = panel

        panel.contentViewController = NSHostingController(
            rootView: FloatingRecorderView(model: model, clock: clock)
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.onCancel = { [weak model] in
            model?.performEscape()
        }
    }

    func start(isEnabled: Bool) {
        self.isEnabled = isEnabled
        guard !isStarted else {
            updateVisibility()
            return
        }
        isStarted = true
        observationGeneration &+= 1
        trackVisibility(generation: observationGeneration)
    }

    func setEnabled(_ isEnabled: Bool) {
        self.isEnabled = isEnabled
        guard isStarted else { return }
        updateVisibility()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        observationGeneration &+= 1
        cancelCompletionDismissal()
        panel.orderOut(nil)
    }

    var panelForTesting: NSPanel { panel }

    func sendEscapeForTesting() {
        panel.cancelOperation(nil)
    }

    private func trackVisibility(generation: UInt64) {
        guard isStarted, generation == observationGeneration else { return }
        withObservationTracking {
            updateVisibility()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.trackVisibility(generation: generation)
            }
        }
    }

    private func updateVisibility() {
        // Read both observable values even while disabled so re-enabling the
        // panel cannot leave visibility tracking detached from the model.
        let readiness = model.readiness
        let state = model.pipeline
        let stage = state.stage
        let shouldShow = FloatingVisibilityPolicy.shouldShow(
            isEnabled: isEnabled,
            readiness: readiness,
            stage: stage
        )
        updateCompletionDismissal(for: state)

        if shouldShow {
            updatePanelFrame(for: state)
            if !panel.isVisible {
                // Keep the recorder visible without making UtterInk the key or
                // frontmost application. TargetTracker must continue to see the
                // editable control that owned focus when dictation began.
                panel.orderFrontRegardless()
            }
        } else if panel.isVisible {
            panel.orderOut(nil)
        }
    }

    private func updatePanelFrame(for state: PipelineState) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = FloatingPanelLayout.size(for: state)
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 34
        )
        let frame = NSRect(origin: origin, size: size)
        if panel.frame != frame {
            panel.setFrame(frame, display: panel.isVisible, animate: false)
        }
    }

    private func updateCompletionDismissal(for state: PipelineState) {
        guard FloatingCompletionPolicy.shouldAutoDismiss(state),
              let sessionID = state.result?.sessionID else {
            cancelCompletionDismissal()
            return
        }
        guard completionDismissSessionID != sessionID else { return }

        cancelCompletionDismissal()
        completionDismissSessionID = sessionID
        let delay = completionDismissDelay
        completionDismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.isStarted,
                  self.completionDismissSessionID == sessionID,
                  self.model.pipeline.result?.sessionID == sessionID,
                  FloatingCompletionPolicy.shouldAutoDismiss(self.model.pipeline) else {
                return
            }
            self.completionDismissTask = nil
            self.completionDismissSessionID = nil
            self.model.acknowledge()
        }
    }

    private func cancelCompletionDismissal() {
        completionDismissTask?.cancel()
        completionDismissTask = nil
        completionDismissSessionID = nil
    }
}

private final class FloatingRecorderPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }
}
