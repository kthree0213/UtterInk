import AppKit
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

        windowController.start(isEnabled: false)
        XCTAssertFalse(panel.isVisible)
        windowController.sendEscapeForTesting()
        windowController.stop()
        windowController.stop()

        XCTAssertEqual(controller.intents, [.cancel])
    }
}
