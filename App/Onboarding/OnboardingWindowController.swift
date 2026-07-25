import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let model: OnboardingViewModel
    private let window: NSWindow
    private var presentationTask: Task<Void, Never>?
    private var isClosing = false

    init(model: OnboardingViewModel) {
        self.model = model
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = "Welcome to UtterInk"
        window.contentViewController = NSHostingController(
            rootView: OnboardingFlow(model: model)
        )
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 560)
        window.setFrameAutosaveName("UtterInk.Onboarding")
        window.center()

        model.setCloseHandler { [weak self] in
            self?.finishClosing()
        }
    }

    func show() {
        present(requireIncomplete: false)
    }

    func showFromBeginning() {
        present(requireIncomplete: false, startingAt: .privacy)
    }

    func showIfNeeded() async {
        await model.prepareForPresentation(requireIncomplete: true)
        guard !model.onboardingCompleted else { return }
        showPreparedWindow()
    }

    func requestClose() {
        beginClosing()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        beginClosing()
        return false
    }

    var windowForTesting: NSWindow { window }

    private func present(
        requireIncomplete: Bool,
        startingAt initialStep: OnboardingStep? = nil
    ) {
        presentationTask?.cancel()
        presentationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.model.prepareForPresentation(requireIncomplete: requireIncomplete)
            guard !Task.isCancelled else { return }
            if requireIncomplete, self.model.onboardingCompleted { return }
            if let initialStep {
                self.model.go(to: initialStep)
            }
            self.showPreparedWindow()
        }
    }

    private func showPreparedWindow() {
        isClosing = false
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func beginClosing() {
        guard !isClosing else { return }
        isClosing = true
        presentationTask?.cancel()
        presentationTask = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.model.close()
        }
    }

    private func finishClosing() {
        window.orderOut(nil)
        isClosing = false
    }
}
