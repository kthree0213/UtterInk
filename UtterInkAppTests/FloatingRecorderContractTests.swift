import AppKit
import SwiftUI
import XCTest
import UtterInkCore
@testable import UtterInk

final class FloatingRecorderMetricsTests: XCTestCase {
    func testReducedMotionSelectsOpacityOnlyPolicy() {
        XCTAssertEqual(FloatingMotionPolicy(reduceMotion: true), .opacityOnly)
        XCTAssertEqual(FloatingMotionPolicy(reduceMotion: false), .springAndScale)
    }

    func testMetricsUseOnlyInjectedNowAndControllerTelemetry() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let metrics = FloatingRecorderMetrics(
            telemetry: RecordingTelemetry(startedAt: startedAt, inputLevel: 1.4),
            now: Date(timeIntervalSince1970: 112.75)
        )

        XCTAssertEqual(metrics.elapsed, 12.75)
        XCTAssertEqual(metrics.inputLevel, 1)
        XCTAssertEqual(FloatingRecorderView.elapsedText(metrics.elapsed!), "00:12")

        let future = FloatingRecorderMetrics(
            telemetry: RecordingTelemetry(startedAt: startedAt, inputLevel: -0.5),
            now: Date(timeIntervalSince1970: 90)
        )
        XCTAssertEqual(future.elapsed, 0)
        XCTAssertEqual(future.inputLevel, 0)

        XCTAssertEqual(
            FloatingRecorderMetrics(telemetry: nil, now: startedAt),
            FloatingRecorderMetrics(telemetry: nil, now: .distantFuture)
        )
    }

    func testWaveformBufferUsesLiveClampedSamples() {
        var buffer = FloatingWaveformBuffer(sampleCount: 3)

        XCTAssertEqual(buffer.samples, [0.06, 0.06, 0.06])
        buffer.append(1.4)
        XCTAssertEqual(buffer.samples, [0.06, 0.06, 1])
        buffer.append(-0.5)
        XCTAssertEqual(buffer.samples, [0.06, 1, 0.06])
        buffer.reset()
        XCTAssertEqual(buffer.samples, [0.06, 0.06, 0.06])
    }

    func testCompletionPolicyAutoDismissesOnlyUnambiguousSuccess() {
        let pasted = Self.state(delivery: .pasteEventDispatched)
        let copied = Self.state(delivery: .copiedByPreference)
        let manual = Self.state(
            delivery: .manualCopyRequired(.deliveryTargetUnavailable)
        )
        let warning = Self.state(
            delivery: .pasteEventDispatched,
            warning: .historyWrite
        )

        XCTAssertTrue(FloatingCompletionPolicy.shouldAutoDismiss(pasted))
        XCTAssertTrue(FloatingCompletionPolicy.shouldAutoDismiss(copied))
        XCTAssertFalse(FloatingCompletionPolicy.requiresRecovery(pasted))
        XCTAssertTrue(FloatingCompletionPolicy.requiresRecovery(manual))
        XCTAssertFalse(FloatingCompletionPolicy.requiresRecovery(warning))
        XCTAssertFalse(FloatingCompletionPolicy.shouldAutoDismiss(manual))
        XCTAssertTrue(FloatingCompletionPolicy.shouldAutoDismiss(warning))
        XCTAssertEqual(
            FloatingCompletionPolicy.nonBlockingNotice(for: warning.result),
            "Not saved to History"
        )
        XCTAssertEqual(
            FloatingCompletionPolicy.successLabel(for: pasted.result),
            "Pasted"
        )
        XCTAssertEqual(
            FloatingCompletionPolicy.successLabel(for: copied.result),
            "Copied"
        )
        XCTAssertGreaterThan(
            FloatingPanelLayout.size(for: manual).height,
            FloatingPanelLayout.size(for: pasted).height
        )
    }

    func testVisibilityPolicyRequiresEnabledReadyAndNonIdleState() {
        XCTAssertFalse(
            FloatingVisibilityPolicy.shouldShow(
                isEnabled: false,
                readiness: .ready,
                stage: .recording
            )
        )
        XCTAssertFalse(
            FloatingVisibilityPolicy.shouldShow(
                isEnabled: true,
                readiness: .pending,
                stage: .recording
            )
        )
        XCTAssertFalse(
            FloatingVisibilityPolicy.shouldShow(
                isEnabled: true,
                readiness: .ready,
                stage: .idle
            )
        )

        for stage in [
            PipelineStage.requestingPermission,
            .recording,
            .stopping,
            .transcribing,
            .polishing,
            .delivering,
            .completed,
            .failed,
        ] {
            XCTAssertTrue(
                FloatingVisibilityPolicy.shouldShow(
                    isEnabled: true,
                    readiness: .ready,
                    stage: stage
                )
            )
        }
    }

    private static func state(
        delivery: DeliveryOutcome,
        warning: DiagnosticCode? = nil
    ) -> PipelineState {
        let sessionID = SessionID(
            rawValue: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        )
        let result = DictationResult(
            sessionID: sessionID,
            rawText: "raw",
            finalText: "final",
            source: .raw,
            warning: warning,
            delivery: delivery
        )
        return PipelineState(
            stage: .completed,
            sessionID: sessionID,
            token: nil,
            result: result,
            failure: nil
        )
    }
}

@MainActor
final class FloatingRecorderVisualTests: XCTestCase {
    func testRecordingOverlayRendersAtContractSize() async throws {
        let controller = RecordingIntentControllerSpy()
        let clock = AppClockFake()
        let sessionID = SessionID(
            rawValue: UUID(uuidString: "20000000-0000-0000-0000-000000000004")!
        )
        controller.state = PipelineState(
            stage: .recording,
            sessionID: sessionID,
            token: nil,
            result: nil,
            failure: nil
        )
        controller.recordingTelemetry = RecordingTelemetry(
            startedAt: clock.now.addingTimeInterval(-8),
            inputLevel: 0.72
        )

        let model = AppModel(controller: controller)
        await model.bootstrap()
        let size = FloatingPanelLayout.size(for: controller.state)
        let hostingView = NSHostingView(
            rootView: FloatingRecorderView(model: model, clock: clock)
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .dark)
        )
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        guard let representation = hostingView.bitmapImageRepForCachingDisplay(
            in: hostingView.bounds
        ) else {
            return XCTFail("The recording overlay could not be rendered.")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            return XCTFail("The recording overlay PNG could not be encoded.")
        }

        XCTAssertEqual(hostingView.frame.size, size)
        XCTAssertGreaterThanOrEqual(representation.pixelsWide, Int(size.width))
        XCTAssertGreaterThanOrEqual(representation.pixelsHigh, Int(size.height))

        let attachment = XCTAttachment(
            data: png,
            uniformTypeIdentifier: "public.png"
        )
        attachment.name = "UtterInk recording overlay"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testIdleMenuRendersAsCompactNonScrollingSurface() async throws {
        let controller = RecordingIntentControllerSpy()
        controller.state = .idle
        let model = AppModel(controller: controller)
        await model.bootstrap()

        let settings = AppSettingsFake()
        let hostingView = NSHostingView(
            rootView: MenuBarRootView(
                model: model,
                settingsStore: settings,
                openHistory: {},
                openLastResult: {},
                openOnboarding: {}
            )
            .background(.regularMaterial)
            .environment(\.colorScheme, .dark)
        )
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        guard let representation = hostingView.bitmapImageRepForCachingDisplay(
            in: hostingView.bounds
        ) else {
            return XCTFail("The idle menu could not be rendered.")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            return XCTFail("The idle menu PNG could not be encoded.")
        }

        XCTAssertEqual(fittingSize.width, 320, accuracy: 1)
        XCTAssertLessThan(fittingSize.height, 420)

        let attachment = XCTAttachment(
            data: png,
            uniformTypeIdentifier: "public.png"
        )
        attachment.name = "UtterInk idle menu"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
final class FloatingWindowControllerTests: XCTestCase {
    func testPanelIsNonactivatingKeyCapableAndEscapeUsesTypedIntent() async {
        let controller = RecordingIntentControllerSpy()
        let model = AppModel(controller: controller)
        await model.bootstrap()
        controller.state = PipelineState(
            stage: .recording,
            sessionID: nil,
            token: nil,
            result: nil,
            failure: nil
        )
        let windowController = FloatingWindowController(
            model: model,
            clock: AppClockFake()
        )
        let panel = windowController.panelForTesting

        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertTrue(panel.isFloatingPanel)
        XCTAssertFalse(panel.isReleasedWhenClosed)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(panel === windowController.panelForTesting)

        windowController.start(isEnabled: true)
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(panel.isKeyWindow)
        windowController.sendEscapeForTesting()
        windowController.stop()
        XCTAssertFalse(panel.isVisible)
        windowController.stop()

        XCTAssertEqual(controller.intents, [.cancel])
    }

    func testSuccessfulCompletionAutomaticallyAcknowledges() async {
        let controller = RecordingIntentControllerSpy()
        let sessionID = SessionID(
            rawValue: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        )
        let result = DictationResult(
            sessionID: sessionID,
            rawText: "raw",
            finalText: "final",
            source: .raw,
            warning: nil,
            delivery: .pasteEventDispatched
        )
        controller.state = PipelineState(
            stage: .completed,
            sessionID: sessionID,
            token: nil,
            result: result,
            failure: nil
        )
        let model = AppModel(controller: controller)
        await model.bootstrap()
        let windowController = FloatingWindowController(
            model: model,
            clock: AppClockFake(),
            completionDismissDelay: .milliseconds(1)
        )

        windowController.start(isEnabled: true)
        try? await Task.sleep(for: .milliseconds(30))
        windowController.stop()

        XCTAssertEqual(controller.intents, [.acknowledge])
    }

    func testRecoveryCompletionDoesNotAutomaticallyAcknowledge() async {
        let controller = RecordingIntentControllerSpy()
        let sessionID = SessionID(
            rawValue: UUID(uuidString: "20000000-0000-0000-0000-000000000003")!
        )
        let result = DictationResult(
            sessionID: sessionID,
            rawText: "raw",
            finalText: "final",
            source: .raw,
            warning: nil,
            delivery: .manualCopyRequired(.deliveryTargetUnavailable)
        )
        controller.state = PipelineState(
            stage: .completed,
            sessionID: sessionID,
            token: nil,
            result: result,
            failure: nil
        )
        let model = AppModel(controller: controller)
        await model.bootstrap()
        let windowController = FloatingWindowController(
            model: model,
            clock: AppClockFake(),
            completionDismissDelay: .milliseconds(1)
        )

        windowController.start(isEnabled: true)
        try? await Task.sleep(for: .milliseconds(30))
        windowController.stop()

        XCTAssertTrue(controller.intents.isEmpty)
    }
}
