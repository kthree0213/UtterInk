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

@MainActor
final class FloatingWindowController {
    private let model: AppModel
    private let clock: any AppClock
    private let panel: FloatingRecorderPanel

    private var isStarted = false
    private var isEnabled = false
    private var observationGeneration: UInt64 = 0

    init(model: AppModel, clock: any AppClock) {
        self.model = model
        self.clock = clock

        let panel = FloatingRecorderPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 180),
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
        let stage = model.pipeline.stage
        let shouldShow = FloatingVisibilityPolicy.shouldShow(
            isEnabled: isEnabled,
            readiness: readiness,
            stage: stage
        )

        if shouldShow {
            positionPanelIfNeeded()
            if !panel.isVisible {
                // A nonactivating panel may become key without making UtterInk
                // the active application, so its responder can receive Escape.
                panel.makeKeyAndOrderFront(nil)
            }
        } else if panel.isVisible {
            panel.orderOut(nil)
        }
    }

    private func positionPanelIfNeeded() {
        guard !panel.isVisible, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 34
        )
        panel.setFrameOrigin(origin)
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
