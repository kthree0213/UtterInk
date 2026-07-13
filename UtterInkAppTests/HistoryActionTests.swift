import XCTest
import UtterInkCore
@testable import UtterInk

@MainActor
final class HistoryActionTests: XCTestCase {
    func testHistoryActionsMapToExplicitControllerIntents() {
        let session = SessionID()
        let spy = RecordingIntentControllerSpy()
        let model = HistoryViewModel(controller: spy)

        model.perform(.copy, sessionID: session)
        model.perform(.pasteAgain, sessionID: session)
        model.perform(.retryPolishing, sessionID: session)
        model.perform(.delete, sessionID: session)
        model.perform(.clearAll)

        XCTAssertEqual(
            spy.intents,
            [
                .copyResult(session),
                .pasteAgain(session),
                .retryPolishing(session),
                .deleteResult(session),
                .clearHistory,
            ]
        )
    }

    func testVolatileCurrentStateOverlaysPersistentBackingWithoutDuplication() {
        let id = SessionID()
        let spy = RecordingIntentControllerSpy()
        spy.volatileResults = [
            DictationResult(
                sessionID: id,
                startedAt: Date(timeIntervalSince1970: 2),
                rawText: "volatile raw must not replace durable backing",
                finalText: "recoverable polished text",
                source: .rawFallback,
                warning: .polishTransport,
                delivery: .manualCopyRequired(.deliveryTargetChanged)
            ),
        ]
        spy.historyRecords = [
            HistoryRecord(
                sessionID: id,
                startedAt: Date(timeIntervalSince1970: 1),
                rawText: "durable raw",
                finalText: nil,
                source: .raw,
                warning: nil,
                delivery: nil,
                outcome: .rawSaved
            ),
        ]

        let items = HistoryViewModel(controller: spy).items

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].persistence, .persistent)
        XCTAssertEqual(items[0].startedAt, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(items[0].rawText, "durable raw")
        XCTAssertEqual(items[0].finalText, "recoverable polished text")
        XCTAssertEqual(items[0].source, .rawFallback)
        XCTAssertEqual(items[0].warning, .polishTransport)
        XCTAssertEqual(
            items[0].delivery,
            .manualCopyRequired(.deliveryTargetChanged)
        )
        XCTAssertEqual(items[0].outcome, .rawSaved)
    }

    func testItemsAreDeduplicatedBeforeNewestFirstTwentyItemLimit() {
        let spy = RecordingIntentControllerSpy()
        var records: [HistoryRecord] = []
        var volatile: [DictationResult] = []

        for index in 0 ..< 23 {
            let id = SessionID()
            records.append(
                HistoryRecord(
                    sessionID: id,
                    startedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                    rawText: "raw \(index)",
                    finalText: nil,
                    source: .raw,
                    warning: nil,
                    delivery: nil,
                    outcome: .rawSaved
                )
            )
            volatile.append(
                DictationResult(
                    sessionID: id,
                    startedAt: Date(timeIntervalSince1970: TimeInterval(index + 100)),
                    rawText: "volatile \(index)",
                    finalText: "current \(index)",
                    source: .polished,
                    warning: nil,
                    delivery: nil
                )
            )
        }
        spy.historyRecords = records.reversed()
        spy.volatileResults = volatile.reversed()

        let items = HistoryViewModel(controller: spy).items

        XCTAssertEqual(items.count, 20)
        XCTAssertEqual(items.map(\.finalText), (3 ... 22).reversed().map { "current \($0)" })
        XCTAssertEqual(Set(items.map(\.sessionID)).count, 20)
        XCTAssertTrue(items.allSatisfy { $0.persistence == .persistent })
    }

    func testPresentationUsesHonestSourceDeliveryAndPersistenceCopy() {
        let persistent = RecoveryItem(
            sessionID: SessionID(),
            startedAt: Date(timeIntervalSince1970: 1),
            rawText: "raw",
            finalText: "polished",
            source: .polished,
            warning: nil,
            delivery: .pasteEventDispatched,
            persistence: .persistent,
            outcome: .delivered
        )
        let volatile = RecoveryItem(
            sessionID: SessionID(),
            startedAt: Date(timeIntervalSince1970: 2),
            rawText: "raw",
            finalText: "raw",
            source: .rawFallback,
            warning: .polishTransport,
            delivery: .copiedByPreference,
            persistence: .volatile,
            outcome: nil
        )
        let copiedByUser = RecoveryItem(
            sessionID: SessionID(),
            startedAt: Date(timeIntervalSince1970: 3),
            rawText: "raw",
            finalText: "raw",
            source: .raw,
            warning: nil,
            delivery: .copiedByUser,
            persistence: .persistent,
            outcome: .delivered
        )

        XCTAssertEqual(persistent.variantLabel, "Polished")
        XCTAssertEqual(persistent.deliveryLabel, "Paste event sent")
        XCTAssertNil(persistent.persistenceLabel)
        XCTAssertEqual(volatile.variantLabel, "Raw")
        XCTAssertEqual(
            volatile.deliveryLabel,
            "Copied to Clipboard (Copy Only)"
        )
        XCTAssertEqual(volatile.persistenceLabel, "Not saved — disappears when UtterInk quits")
        XCTAssertEqual(
            volatile.warningLabel,
            EnglishCopy.warning(for: .polishTransport)
        )
        XCTAssertEqual(copiedByUser.deliveryLabel, "Copied by You")
    }

    func testUnmatchedInProcessResultPreservesItsControllerPersistenceState() {
        let id = SessionID()
        let spy = RecordingIntentControllerSpy()
        spy.volatileResults = [
            DictationResult(
                sessionID: id,
                startedAt: Date(timeIntervalSince1970: 1),
                rawText: "raw",
                finalText: "saved",
                source: .raw,
                warning: nil,
                delivery: nil,
                persistence: .persistent
            ),
        ]

        let items = HistoryViewModel(controller: spy).items

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].persistence, .persistent)
        XCTAssertNil(items[0].persistenceLabel)
    }

    func testSupportedActionsRequireRecoverableTextAndRawBacking() {
        let usable = RecoveryItem(
            sessionID: SessionID(),
            startedAt: Date(),
            rawText: "raw",
            finalText: "result",
            source: .raw,
            warning: nil,
            delivery: nil,
            persistence: .volatile,
            outcome: nil
        )
        let missingRaw = RecoveryItem(
            sessionID: SessionID(),
            startedAt: Date(),
            rawText: "",
            finalText: "result",
            source: .polished,
            warning: nil,
            delivery: nil,
            persistence: .volatile,
            outcome: nil
        )

        XCTAssertEqual(
            usable.supportedActions,
            [.copy, .pasteAgain, .retryPolishing, .delete]
        )
        XCTAssertEqual(
            missingRaw.supportedActions,
            [.copy, .pasteAgain, .delete]
        )
    }

    func testHistoryPreviewNormalizesWhitespaceAndStaysBounded() {
        let item = RecoveryItem(
            sessionID: SessionID(),
            startedAt: Date(),
            rawText: "raw",
            finalText: Array(repeating: "word\n", count: 100).joined(),
            source: .raw,
            warning: nil,
            delivery: nil,
            persistence: .persistent,
            outcome: .finalized
        )

        XCTAssertLessThanOrEqual(item.preview.count, RecoveryItem.previewCharacterLimit)
        XCTAssertFalse(item.preview.contains("\n"))
        XCTAssertTrue(item.preview.hasSuffix("…"))
    }
}
