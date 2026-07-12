import Darwin
import Foundation
import XCTest
import UtterInkCore
@testable import UtterInkServices

private let coreHistoryErrorVisibilityProof: UtterInkCore.HistoryStoreError = .corrupt

final class JSONHistoryStoreTests: XCTestCase {
    func testModelsAndSchemaOneEnvelopeRoundTripUseOnlyAllowlistedKeys() throws {
        let record = makeRecord(
            index: 7,
            rawText: "sample raw",
            finalText: "sample final",
            source: .polished,
            warning: .polishTransport,
            delivery: .copiedByPreference,
            outcome: .delivered
        )
        XCTAssertEqual(record.id, record.sessionID)

        let encodedRecord = try JSONEncoder.historyEncoder.encode(record)
        XCTAssertEqual(try JSONDecoder.historyDecoder.decode(HistoryRecord.self, from: encodedRecord), record)

        let envelope = HistoryEnvelope(
            schemaVersion: 1,
            generation: 9,
            enabled: true,
            records: [record],
            tombstones: [SessionID(rawValue: fixedUUID(99))]
        )
        let data = try JSONEncoder.historyEncoder.encode(envelope)
        let decoded = try JSONDecoder.historyDecoder.decode(HistoryEnvelope.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.generation, 9)
        XCTAssertTrue(decoded.enabled)
        XCTAssertEqual(decoded.records, [record])
        XCTAssertEqual(decoded.tombstones, envelope.tombstones)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(
            Set(json.keys),
            ["schemaVersion", "generation", "enabled", "records", "tombstones"]
        )
        let records = try XCTUnwrap(json["records"] as? [[String: Any]])
        XCTAssertEqual(
            Set(try XCTUnwrap(records.first).keys),
            ["sessionID", "startedAt", "rawText", "finalText", "source", "warning", "delivery", "outcome"]
        )
        let keys = recursiveJSONKeys(json)
        for forbidden in [
            "audio", "target", "application", "provider", "url", "prompt", "instruction",
            "credential", "secret", "model", "log"
        ] {
            XCTAssertFalse(keys.contains(where: { $0.localizedCaseInsensitiveContains(forbidden) }))
        }
    }

    func testCapsByOriginalStartDateAndRejectsStaleGeneration() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try JSONHistoryStore(
            directory: directory,
            enabled: true,
            clock: TestHistoryClock()
        )
        let generation = await store.generation()

        for index in 0..<21 {
            let record = HistoryRecord(
                sessionID: SessionID(),
                startedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                rawText: "raw-\(index)",
                finalText: nil,
                source: .raw,
                warning: nil,
                delivery: nil,
                outcome: .rawSaved
            )
            try await store.appendRaw(record, expectedGeneration: generation)
        }

        let loaded = try await store.load()
        XCTAssertEqual(loaded.count, 20)
        XCTAssertEqual(loaded.first?.startedAt, Date(timeIntervalSince1970: 20))
        XCTAssertEqual(loaded.last?.startedAt, Date(timeIntervalSince1970: 1))

        _ = try await store.setEnabled(false)
        let stale = HistoryRecord(
            sessionID: SessionID(),
            startedAt: Date(timeIntervalSince1970: 21),
            rawText: "stale",
            finalText: nil,
            source: .raw,
            warning: nil,
            delivery: nil,
            outcome: .rawSaved
        )
        await XCTAssertThrowsErrorAsync {
            try await store.appendRaw(stale, expectedGeneration: generation)
        }
    }

    func testDeleteTombstonePreventsLateUpdate() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try JSONHistoryStore(
            directory: directory,
            enabled: true,
            clock: TestHistoryClock()
        )
        let generation = await store.generation()
        let record = HistoryRecord(
            sessionID: SessionID(),
            startedAt: Date(timeIntervalSince1970: 1),
            rawText: "raw",
            finalText: nil,
            source: .raw,
            warning: nil,
            delivery: nil,
            outcome: .rawSaved
        )

        try await store.appendRaw(record, expectedGeneration: generation)
        try await store.delete(sessionID: record.sessionID)

        await XCTAssertThrowsErrorAsync {
            try await store.updateResult(
                sessionID: record.sessionID,
                finalText: "late",
                source: .polished,
                warning: nil,
                delivery: .pasteEventDispatched,
                outcome: .delivered,
                expectedGeneration: generation
            )
        }
    }

    func testRejectsEmptyMalformedAndDuplicateRawWithoutPrimaryMutation() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try JSONHistoryStore(directory: directory, enabled: true, clock: TestHistoryClock())
        let generation = await store.generation()
        let primary = historyArtifact("history-v1.json", in: directory)

        let malformed = [
            makeRecord(index: 1, rawText: ""),
            makeRecord(index: 2, rawText: " \n\t "),
            makeRecord(index: 3, finalText: "not raw"),
            makeRecord(index: 4, source: .polished),
            makeRecord(index: 5, warning: .polishTransport),
            makeRecord(index: 6, delivery: .copiedByUser),
            makeRecord(index: 7, outcome: .finalized)
        ]
        for record in malformed {
            await XCTAssertHistoryError(.invalidRecord) {
                try await store.appendRaw(record, expectedGeneration: generation)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: primary.path))
        }

        let valid = makeRecord(index: 8)
        try await store.appendRaw(valid, expectedGeneration: generation)
        let priorBytes = try Data(contentsOf: primary)
        await XCTAssertHistoryError(.duplicateSession) {
            try await store.appendRaw(valid, expectedGeneration: generation)
        }
        XCTAssertEqual(try Data(contentsOf: primary), priorBytes)
        try await XCTAssertEqualAsync( store.load(), [valid])
    }

    func testEqualTimeTieBreakIsDeterministicAndEvictedIDCannotReturnInProcess() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try JSONHistoryStore(directory: directory, enabled: true, clock: TestHistoryClock())
        let generation = await store.generation()
        let timestamp = Date(timeIntervalSince1970: 50)
        let records = (1...21).map {
            makeRecord(index: $0, startedAt: timestamp)
        }
        for record in records.reversed() {
            try await store.appendRaw(record, expectedGeneration: generation)
        }

        let expected = records.sorted { lhs, rhs in
            lhs.sessionID.rawValue.uuidString < rhs.sessionID.rawValue.uuidString
        }.prefix(20)
        try await XCTAssertEqualAsync( store.load(), Array(expected))

        let evicted = try XCTUnwrap(records.first { !expected.contains($0) })
        await XCTAssertHistoryError(.duplicateSession) {
            try await store.appendRaw(evicted, expectedGeneration: generation)
        }
    }

    func testUpdateReplacesAllMutableFieldsAtomicallyAndPreservesImmutableOrder() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try JSONHistoryStore(directory: directory, enabled: true, clock: TestHistoryClock())
        let generation = await store.generation()
        let newer = makeRecord(index: 2, startedAt: Date(timeIntervalSince1970: 20))
        let older = makeRecord(index: 1, startedAt: Date(timeIntervalSince1970: 10))
        try await store.appendRaw(older, expectedGeneration: generation)
        try await store.appendRaw(newer, expectedGeneration: generation)

        try await store.updateResult(
            sessionID: older.sessionID,
            finalText: "final-safe",
            source: .rawFallback,
            warning: .polishInvalidResponse,
            delivery: .manualCopyRequired(.deliveryTargetChanged),
            outcome: .delivered,
            expectedGeneration: generation
        )

        let loaded = try await store.load()
        XCTAssertEqual(loaded.map(\.sessionID), [newer.sessionID, older.sessionID])
        let updated = try XCTUnwrap(loaded.last)
        XCTAssertEqual(updated.sessionID, older.sessionID)
        XCTAssertEqual(updated.startedAt, older.startedAt)
        XCTAssertEqual(updated.rawText, older.rawText)
        XCTAssertEqual(updated.finalText, "final-safe")
        XCTAssertEqual(updated.source, .rawFallback)
        XCTAssertEqual(updated.warning, .polishInvalidResponse)
        XCTAssertEqual(updated.delivery, .manualCopyRequired(.deliveryTargetChanged))
        XCTAssertEqual(updated.outcome, .delivered)

        let priorBytes = try Data(contentsOf: historyArtifact("history-v1.json", in: directory))
        await XCTAssertHistoryError(.missingRecord) {
            try await store.updateResult(
                sessionID: SessionID(rawValue: fixedUUID(404)),
                finalText: "missing",
                source: .polished,
                warning: nil,
                delivery: nil,
                outcome: .finalized,
                expectedGeneration: generation
            )
        }
        XCTAssertEqual(try Data(contentsOf: historyArtifact("history-v1.json", in: directory)), priorBytes)
    }

    func testFailedUpdateCommitKeepsPriorMutableVariantInActorAndOnReopen() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hooks = HistoryStoreHooks()
        var store: JSONHistoryStore? = try JSONHistoryStore(
            directory: directory,
            enabled: true,
            clock: TestHistoryClock(),
            hooks: hooks
        )
        let generation = await store!.generation()
        let raw = makeRecord(index: 1)
        try await store!.appendRaw(raw, expectedGeneration: generation)
        let primary = historyArtifact("history-v1.json", in: directory)
        let priorBytes = try Data(contentsOf: primary)

        hooks.failNext(.tempWrite)
        await XCTAssertHistoryError(.writeFailed) {
            try await store!.updateResult(
                sessionID: raw.sessionID,
                finalText: "failed-final",
                source: .polished,
                warning: nil,
                delivery: .copiedByPreference,
                outcome: .delivered,
                expectedGeneration: generation
            )
        }
        try await XCTAssertEqualAsync( store!.load(), [raw])
        XCTAssertEqual(try Data(contentsOf: primary), priorBytes)

        store = nil
        let reopened = try JSONHistoryStore(directory: directory, enabled: false, clock: TestHistoryClock())
        try await XCTAssertEqualAsync( reopened.load(), [raw])
    }

    func testAllInjectedTransactionFailuresReturnNoFalseSuccessAndKeepPriorVariant() async throws {
        let phases: [HistoryWritePhase] = [
            .permission, .tempCreate, .tempWrite, .tempSync,
            .backupCreate, .backupWrite, .backupSync,
            .journalCreate, .journalWrite, .journalSync,
            .commitRecordCreate, .commitRecordPrepareSync, .armedDirectorySync,
            .replace, .primaryReplace,
            .parentSyncAfterReplace, .primarySync,
            .commitRecordPublish
        ]

        for (offset, phase) in phases.enumerated() {
            let directory = temporaryDirectory()
            let hooks = HistoryStoreHooks()
            var store: JSONHistoryStore? = try JSONHistoryStore(
                directory: directory,
                enabled: true,
                clock: TestHistoryClock(),
                hooks: hooks
            )
            let generation = await store!.generation()
            let prior = makeRecord(index: 100 + offset)
            try await store!.appendRaw(prior, expectedGeneration: generation)
            let primary = historyArtifact("history-v1.json", in: directory)
            let priorBytes = try Data(contentsOf: primary)

            hooks.failNext(phase)
            await XCTAssertHistoryError(.writeFailed) {
                try await store!.appendRaw(
                    self.makeRecord(index: 200 + offset),
                    expectedGeneration: generation
                )
            }
            try await XCTAssertEqualAsync( store!.load(), [prior], "phase=\(phase)")
            XCTAssertEqual(try Data(contentsOf: primary), priorBytes, "phase=\(phase)")

            store = nil
            var reopened: JSONHistoryStore? = try JSONHistoryStore(
                directory: directory,
                enabled: false,
                clock: TestHistoryClock()
            )
            try await XCTAssertEqualAsync( reopened!.load(), [prior], "phase=\(phase)")
            reopened = nil
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testFailedPostReplaceRollbackPoisonsActorAndStartupRecoveryRestoresPriorPrimary() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hooks = HistoryStoreHooks()
        var store: JSONHistoryStore? = try JSONHistoryStore(
            directory: directory,
            enabled: true,
            clock: TestHistoryClock(),
            hooks: hooks
        )
        let generation = await store!.generation()
        let prior = makeRecord(index: 1)
        try await store!.appendRaw(prior, expectedGeneration: generation)

        hooks.failNext(.parentSyncAfterReplace)
        hooks.failNext(.rollbackReplace)
        await XCTAssertHistoryError(.writeFailed) {
            try await store!.appendRaw(self.makeRecord(index: 2), expectedGeneration: generation)
        }
        await XCTAssertHistoryError(.poisoned) {
            try await store!.appendRaw(self.makeRecord(index: 3), expectedGeneration: generation)
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: historyArtifact("history-v1.backup", in: directory).path
        ))

        store = nil
        let recovered = try JSONHistoryStore(directory: directory, enabled: false, clock: TestHistoryClock())
        try await XCTAssertEqualAsync( recovered.load(), [prior])
    }

    func testEveryPostcommitCleanupFailureReturnsSuccessAndReopenKeepsCandidate() async throws {
        let cleanupPhases: [HistoryWritePhase] = [
            .cleanupBackup,
            .cleanupJournal,
            .cleanupArmedDirectorySync,
            .cleanupCommit,
            .cleanupFinalDirectorySync
        ]
        for (offset, phase) in cleanupPhases.enumerated() {
            let directory = temporaryDirectory()
            let hooks = HistoryStoreHooks()
            var store: JSONHistoryStore? = try JSONHistoryStore(
                directory: directory,
                enabled: true,
                clock: TestHistoryClock(),
                hooks: hooks
            )
            let generation = await store!.generation()
            let prior = makeRecord(index: 500 + offset)
            let candidate = makeRecord(index: 600 + offset)
            let followup = makeRecord(index: 700 + offset)
            try await store!.appendRaw(prior, expectedGeneration: generation)

            hooks.failNext(phase)
            try await store!.appendRaw(candidate, expectedGeneration: generation)
            try await XCTAssertEqualAsync(
                store!.load(),
                sortedHistory([prior, candidate]),
                "phase=\(phase)"
            )
            try await store!.appendRaw(followup, expectedGeneration: generation)
            try await XCTAssertEqualAsync(
                store!.load(),
                sortedHistory([prior, candidate, followup]),
                "followup phase=\(phase)"
            )

            store = nil
            var reopened: JSONHistoryStore? = try JSONHistoryStore(
                directory: directory,
                enabled: false,
                clock: TestHistoryClock()
            )
            try await XCTAssertEqualAsync(
                reopened!.load(),
                sortedHistory([prior, candidate, followup]),
                "phase=\(phase)"
            )
            reopened = nil
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testCompoundCleanupAndRecoveryCreationFaultsNeverTurnCommittedCandidateIntoFailure() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hooks = HistoryStoreHooks()
        var store: JSONHistoryStore? = try JSONHistoryStore(
            directory: directory,
            enabled: true,
            clock: TestHistoryClock(),
            hooks: hooks
        )
        let generation = await store!.generation()
        let prior = makeRecord(index: 1)
        let candidate = makeRecord(index: 2)
        try await store!.appendRaw(prior, expectedGeneration: generation)

        hooks.failNext(.cleanupJournal)
        hooks.failNext(.backupCreate)
        hooks.failNext(.backupWrite)
        hooks.failNext(.backupSync)
        try await store!.appendRaw(candidate, expectedGeneration: generation)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: historyArtifact("history-v1.backup", in: directory).path
        ))
        try await XCTAssertEqualAsync(store!.load(), sortedHistory([prior, candidate]))

        store = nil
        let reopened = try JSONHistoryStore(directory: directory, enabled: false, clock: TestHistoryClock())
        try await XCTAssertEqualAsync(reopened.load(), sortedHistory([prior, candidate]))
    }

    func testArmedRollbackInterruptionRestoresByteIdenticalPriorOnReopen() async throws {
        for (offset, rollbackPhase) in [
            HistoryWritePhase.rollbackRestore,
            .rollbackSync
        ].enumerated() {
            let directory = temporaryDirectory()
            let hooks = HistoryStoreHooks()
            var store: JSONHistoryStore? = try JSONHistoryStore(
                directory: directory,
                enabled: true,
                clock: TestHistoryClock(),
                hooks: hooks
            )
            let generation = await store!.generation()
            let prior = makeRecord(index: 10 + offset)
            try await store!.appendRaw(prior, expectedGeneration: generation)
            let primary = historyArtifact("history-v1.json", in: directory)
            let priorBytes = try Data(contentsOf: primary)

            hooks.failNext(.primarySync)
            hooks.failNext(rollbackPhase)
            await XCTAssertHistoryError(.writeFailed) {
                try await store!.appendRaw(
                    self.makeRecord(index: 20 + offset),
                    expectedGeneration: generation
                )
            }
            await XCTAssertHistoryError(.poisoned) {
                try await store!.appendRaw(
                    self.makeRecord(index: 30 + offset),
                    expectedGeneration: generation
                )
            }
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: historyArtifact("history-v1.txn", in: directory).path
            ))
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: historyArtifact("history-v1.tmp", in: directory).path
            ))

            store = nil
            var reopened: JSONHistoryStore? = try JSONHistoryStore(
                directory: directory,
                enabled: false,
                clock: TestHistoryClock()
            )
            XCTAssertEqual(try Data(contentsOf: primary), priorBytes)
            try await XCTAssertEqualAsync(reopened!.load(), [prior])
            reopened = nil
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testArmedNoPriorRollbackUsesManifestStateInsteadOfEmptyBackupInference() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hooks = HistoryStoreHooks()
        var store: JSONHistoryStore? = try JSONHistoryStore(
            directory: directory,
            enabled: true,
            clock: TestHistoryClock(),
            hooks: hooks
        )
        hooks.failNext(.primarySync)
        hooks.failNext(.rollbackRestore)
        await XCTAssertHistoryError(.writeFailed) {
            try await store!.appendRaw(self.makeRecord(index: 1), expectedGeneration: 0)
        }

        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: historyArtifact("history-v1.txn", in: directory))
            ) as? [String: Any]
        )
        XCTAssertEqual(manifest["priorExists"] as? Bool, false)
        XCTAssertEqual(
            try Data(contentsOf: historyArtifact("history-v1.backup", in: directory)).count,
            0
        )

        store = nil
        let reopened = try JSONHistoryStore(directory: directory, enabled: true, clock: TestHistoryClock())
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: historyArtifact("history-v1.json", in: directory).path
        ))
        try await XCTAssertEqualAsync(reopened.load(), [])
    }

    func testRollbackCleanupDurablyDropsNonAuthorityBeforeJournal() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hooks = HistoryStoreHooks()
        var store: JSONHistoryStore? = try JSONHistoryStore(
            directory: directory,
            enabled: true,
            clock: TestHistoryClock(),
            hooks: hooks
        )
        let prior = makeRecord(index: 41)
        try await store!.appendRaw(prior, expectedGeneration: 0)
        let primary = historyArtifact("history-v1.json", in: directory)
        let priorBytes = try Data(contentsOf: primary)

        hooks.failNext(.primarySync)
        hooks.failNext(.rollbackCleanupSync)
        await XCTAssertHistoryError(.writeFailed) {
            try await store!.appendRaw(self.makeRecord(index: 42), expectedGeneration: 0)
        }
        await XCTAssertHistoryError(.poisoned) {
            try await store!.appendRaw(self.makeRecord(index: 43), expectedGeneration: 0)
        }
        XCTAssertEqual(try Data(contentsOf: primary), priorBytes)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: historyArtifact("history-v1.txn", in: directory).path
        ))
        for name in ["history-v1.tmp", "history-v1.backup", "history-v1.commit"] {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: historyArtifact(name, in: directory).path
            ))
        }

        store = nil
        let reopened = try JSONHistoryStore(
            directory: directory,
            enabled: false,
            clock: TestHistoryClock()
        )
        XCTAssertEqual(try Data(contentsOf: primary), priorBytes)
        try await XCTAssertEqualAsync(reopened.load(), [prior])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: historyArtifact("history-v1.txn", in: directory).path
        ))
    }

    func testDisableEnableGenerationIdempotenceConstructorMismatchAndReadableDisabledHistory() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var store: JSONHistoryStore? = try JSONHistoryStore(
            directory: directory,
            enabled: true,
            clock: TestHistoryClock()
        )
        let generation0 = await store!.generation()
        let existing = makeRecord(index: 1)
        try await store!.appendRaw(existing, expectedGeneration: generation0)

        let generation1 = try await store!.setEnabled(false)
        XCTAssertEqual(generation1, generation0 + 1)
        try await XCTAssertEqualAsync( store!.setEnabled(false), generation1)
        try await XCTAssertEqualAsync( store!.load(), [existing])
        await XCTAssertHistoryError(.disabled) {
            try await store!.appendRaw(self.makeRecord(index: 2), expectedGeneration: generation1)
        }
        await XCTAssertHistoryError(.disabled) {
            try await store!.updateResult(
                sessionID: existing.sessionID,
                finalText: "blocked",
                source: .polished,
                warning: nil,
                delivery: nil,
                outcome: .finalized,
                expectedGeneration: generation1
            )
        }

        store = nil
        store = try JSONHistoryStore(directory: directory, enabled: true, clock: TestHistoryClock())
        await XCTAssertEqualAsync( store!.generation(), generation1)
        try await XCTAssertEqualAsync( store!.load(), [existing])
        await XCTAssertHistoryError(.disabled) {
            try await store!.appendRaw(self.makeRecord(index: 3), expectedGeneration: generation1)
        }

        let generation2 = try await store!.setEnabled(true)
        XCTAssertEqual(generation2, generation1 + 1)
        try await XCTAssertEqualAsync( store!.setEnabled(true), generation2)
        await XCTAssertHistoryError(.staleGeneration) {
            try await store!.appendRaw(self.makeRecord(index: 4), expectedGeneration: generation1)
        }
        try await store!.appendRaw(makeRecord(index: 5), expectedGeneration: generation2)
    }

    func testFailedPrivacyWritesKeepStricterMemoryDirtyAndSameValueRetriesWithoutExtraGeneration() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hooks = HistoryStoreHooks()
        var store: JSONHistoryStore? = try JSONHistoryStore(
            directory: directory,
            enabled: true,
            clock: TestHistoryClock(),
            hooks: hooks
        )
        let originalGeneration = await store!.generation()
        let record = makeRecord(index: 1)
        try await store!.appendRaw(record, expectedGeneration: originalGeneration)

        hooks.failNext(.tempWrite)
        await XCTAssertHistoryError(.writeFailed) {
            try await store!.setEnabled(false)
        }
        let disabledGeneration = await store!.generation()
        XCTAssertEqual(disabledGeneration, originalGeneration + 1)
        try await XCTAssertEqualAsync( store!.load(), [record])
        await XCTAssertHistoryError(.dirty) {
            try await store!.appendRaw(
                self.makeRecord(index: 2),
                expectedGeneration: disabledGeneration
            )
        }
        try await XCTAssertEqualAsync( store!.setEnabled(false), disabledGeneration)

        store = nil
        store = try JSONHistoryStore(directory: directory, enabled: true, clock: TestHistoryClock())
        await XCTAssertEqualAsync( store!.generation(), disabledGeneration)
        await XCTAssertHistoryError(.disabled) {
            try await store!.appendRaw(
                self.makeRecord(index: 3),
                expectedGeneration: disabledGeneration
            )
        }
    }

    func testPostcommitCleanupDebtPublishesDurablePrivacyMutations() async throws {
        for mutation in PrivacyMutation.allCases {
            let directory = temporaryDirectory()
            let hooks = HistoryStoreHooks()
            var store: JSONHistoryStore? = try JSONHistoryStore(
                directory: directory,
                enabled: true,
                clock: TestHistoryClock(),
                hooks: hooks
            )
            let generation = await store!.generation()
            let record = makeRecord(index: 800 + mutation.fixtureIndex)
            try await store!.appendRaw(record, expectedGeneration: generation)

            hooks.failNext(.cleanupJournal)
            let expectedGeneration: UInt64
            switch mutation {
            case .disable:
                expectedGeneration = try await store!.setEnabled(false)
                try await XCTAssertEqualAsync(store!.load(), [record])
            case .clear:
                expectedGeneration = try await store!.clear()
                try await XCTAssertEqualAsync(store!.load(), [])
            case .delete:
                try await store!.delete(sessionID: record.sessionID)
                expectedGeneration = generation
                try await XCTAssertEqualAsync(store!.load(), [])
            }

            store = nil
            var reopened: JSONHistoryStore? = try JSONHistoryStore(
                directory: directory,
                enabled: true,
                clock: TestHistoryClock()
            )
            await XCTAssertEqualAsync(reopened!.generation(), expectedGeneration)
            switch mutation {
            case .disable:
                try await XCTAssertEqualAsync(reopened!.load(), [record])
                await XCTAssertHistoryError(.disabled) {
                    try await reopened!.appendRaw(
                        self.makeRecord(index: 900 + mutation.fixtureIndex),
                        expectedGeneration: expectedGeneration
                    )
                }
            case .clear, .delete:
                try await XCTAssertEqualAsync(reopened!.load(), [])
            }
            reopened = nil
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testFailedEnableDoesNotPublishRelaxedStateOrGeneration() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hooks = HistoryStoreHooks()
        let store = try JSONHistoryStore(
            directory: directory,
            enabled: false,
            clock: TestHistoryClock(),
            hooks: hooks
        )
        hooks.failNext(.tempCreate)
        await XCTAssertHistoryError(.writeFailed) {
            try await store.setEnabled(true)
        }
        await XCTAssertEqualAsync( store.generation(), 0)
        await XCTAssertHistoryError(.disabled) {
            try await store.appendRaw(self.makeRecord(index: 1), expectedGeneration: 0)
        }
        try await XCTAssertEqualAsync( store.setEnabled(true), 1)
        try await store.appendRaw(makeRecord(index: 2), expectedGeneration: 1)
    }

    func testClearAlwaysIncrementsGenerationAndBlocksOldAppendAndUpdate() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try JSONHistoryStore(directory: directory, enabled: true, clock: TestHistoryClock())
        let generation0 = await store.generation()
        let prior = makeRecord(index: 1)
        try await store.appendRaw(prior, expectedGeneration: generation0)

        let generation1 = try await store.clear()
        XCTAssertEqual(generation1, generation0 + 1)
        try await XCTAssertEqualAsync( store.load(), [])
        await XCTAssertHistoryError(.staleGeneration) {
            try await store.appendRaw(self.makeRecord(index: 2), expectedGeneration: generation0)
        }
        await XCTAssertHistoryError(.staleGeneration) {
            try await store.updateResult(
                sessionID: prior.sessionID,
                finalText: "late",
                source: .polished,
                warning: nil,
                delivery: nil,
                outcome: .finalized,
                expectedGeneration: generation0
            )
        }
        try await XCTAssertEqualAsync( store.clear(), generation1 + 1)
    }

    func testGenerationOverflowFailsWithoutChangingDurableBytes() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try createSecureDirectory(directory)
        let envelope = HistoryEnvelope(
            schemaVersion: 1,
            generation: UInt64.max,
            enabled: true,
            records: [],
            tombstones: []
        )
        let primary = historyArtifact("history-v1.json", in: directory)
        try writeSecure(try JSONEncoder.historyEncoder.encode(envelope), to: primary)
        let priorBytes = try Data(contentsOf: primary)
        let store = try JSONHistoryStore(directory: directory, enabled: false, clock: TestHistoryClock())

        await XCTAssertHistoryError(.generationOverflow) {
            try await store.clear()
        }
        await XCTAssertHistoryError(.generationOverflow) {
            try await store.setEnabled(false)
        }
        XCTAssertEqual(try Data(contentsOf: primary), priorBytes)
    }

    func testDeleteTombstoneBlocksLateAppendUpdateAndPrunesOnlyOnNewLockedStore() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var store: JSONHistoryStore? = try JSONHistoryStore(
            directory: directory,
            enabled: true,
            clock: TestHistoryClock()
        )
        let generation = await store!.generation()
        let record = makeRecord(index: 1)
        try await store!.appendRaw(record, expectedGeneration: generation)
        try await store!.delete(sessionID: record.sessionID)
        try await XCTAssertEqualAsync( store!.load(), [])
        await XCTAssertHistoryError(.tombstoned) {
            try await store!.appendRaw(record, expectedGeneration: generation)
        }
        await XCTAssertHistoryError(.tombstoned) {
            try await store!.updateResult(
                sessionID: record.sessionID,
                finalText: "late",
                source: .polished,
                warning: nil,
                delivery: nil,
                outcome: .finalized,
                expectedGeneration: generation
            )
        }
        let primary = historyArtifact("history-v1.json", in: directory)
        let persistedBeforeRestart = try JSONDecoder.historyDecoder.decode(
            HistoryEnvelope.self,
            from: Data(contentsOf: primary)
        )
        XCTAssertEqual(persistedBeforeRestart.tombstones, [record.sessionID])

        store = nil
        store = try JSONHistoryStore(directory: directory, enabled: false, clock: TestHistoryClock())
        let persistedAfterRestart = try JSONDecoder.historyDecoder.decode(
            HistoryEnvelope.self,
            from: Data(contentsOf: primary)
        )
        XCTAssertTrue(persistedAfterRestart.tombstones.isEmpty)
        try await store!.appendRaw(record, expectedGeneration: generation)
        try await XCTAssertEqualAsync( store!.load(), [record])
    }

    func testStartupTombstonePruneFailurePreservesPriorSchemaOneBytes() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try createSecureDirectory(directory)
        let envelope = HistoryEnvelope(
            schemaVersion: 1,
            generation: 6,
            enabled: true,
            records: [],
            tombstones: [SessionID(rawValue: fixedUUID(1))]
        )
        let primary = historyArtifact("history-v1.json", in: directory)
        let priorBytes = try JSONEncoder.historyEncoder.encode(envelope)
        try writeSecure(priorBytes, to: primary)
        let hooks = HistoryStoreHooks()
        hooks.failNext(.tempSync)

        XCTAssertThrowsError(
            try JSONHistoryStore(
                directory: directory,
                enabled: true,
                clock: TestHistoryClock(),
                hooks: hooks
            )
        ) { error in
            XCTAssertEqual(error as? HistoryStoreError, .writeFailed)
        }
        XCTAssertEqual(try Data(contentsOf: primary), priorBytes)
    }

    func testFailedDeleteKeepsTombstoneDirtyAndRetryPersistsStricterState() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hooks = HistoryStoreHooks()
        var store: JSONHistoryStore? = try JSONHistoryStore(
            directory: directory,
            enabled: true,
            clock: TestHistoryClock(),
            hooks: hooks
        )
        let generation = await store!.generation()
        let record = makeRecord(index: 1)
        try await store!.appendRaw(record, expectedGeneration: generation)

        hooks.failNext(.tempSync)
        await XCTAssertHistoryError(.writeFailed) {
            try await store!.delete(sessionID: record.sessionID)
        }
        try await XCTAssertEqualAsync( store!.load(), [])
        await XCTAssertHistoryError(.dirty) {
            try await store!.appendRaw(record, expectedGeneration: generation)
        }
        try await store!.delete(sessionID: record.sessionID)

        store = nil
        let reopened = try JSONHistoryStore(directory: directory, enabled: true, clock: TestHistoryClock())
        try await XCTAssertEqualAsync( reopened.load(), [])
    }

    func testGatedAppendCannotOutrunDisableClearOrDelete() async throws {
        for mutation in PrivacyMutation.allCases {
            try await assertGatedAppendIsInvalidated(by: mutation)
        }
    }

    func testGatedUpdateCannotOutrunDisableClearOrDelete() async throws {
        for mutation in PrivacyMutation.allCases {
            try await assertGatedUpdateIsInvalidated(by: mutation)
        }
    }

    func testCorruptTruncatedFutureAndInvalidSchemaOnePreserveExactPrimaryBytes() throws {
        let duplicate = makeRecord(index: 1)
        let fixtures: [(Data, HistoryStoreError)] = [
            (Data("{\"schemaVersion\":1,".utf8), .corrupt),
            (Data("not-json-safe-fixture".utf8), .corrupt),
            (Data("{\"schemaVersion\":2,\"generation\":0,\"enabled\":true,\"records\":[],\"tombstones\":[]}".utf8), .unsupportedSchema),
            (
                try JSONEncoder.historyEncoder.encode(
                    HistoryEnvelope(
                        schemaVersion: 1,
                        generation: 0,
                        enabled: true,
                        records: [duplicate, duplicate],
                        tombstones: []
                    )
                ),
                .corrupt
            ),
            (
                try JSONEncoder.historyEncoder.encode(
                    HistoryEnvelope(
                        schemaVersion: 1,
                        generation: 0,
                        enabled: true,
                        records: [makeRecord(index: 2, rawText: " \t")],
                        tombstones: []
                    )
                ),
                .corrupt
            )
        ]

        for (bytes, expectedError) in fixtures {
            let directory = temporaryDirectory()
            try createSecureDirectory(directory)
            let primary = historyArtifact("history-v1.json", in: directory)
            try writeSecure(bytes, to: primary)

            XCTAssertThrowsError(
                try JSONHistoryStore(directory: directory, enabled: true, clock: TestHistoryClock())
            ) { error in
                XCTAssertEqual(error as? HistoryStoreError, expectedError)
            }
            XCTAssertEqual(try Data(contentsOf: primary), bytes)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: historyArtifact("history-v1.backup", in: directory).path
            ))
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: historyArtifact("history-v1.tmp", in: directory).path
            ))
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testHostileUnknownAndPrivacyJSONKeysFailClosedWithExactBytePreservation() throws {
        for bytes in try hostileEnvelopeFixtures() {
            let directory = temporaryDirectory()
            try createSecureDirectory(directory)
            let primary = historyArtifact("history-v1.json", in: directory)
            try writeSecure(bytes, to: primary)

            XCTAssertHistoryInitError(.corrupt, directory: directory)
            XCTAssertEqual(try Data(contentsOf: primary), bytes)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: historyArtifact("history-v1.tmp", in: directory).path
            ))
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: historyArtifact("history-v1.backup", in: directory).path
            ))
            try FileManager.default.removeItem(at: directory)
        }
        _ = coreHistoryErrorVisibilityProof
    }

    func testInconsistentDecodedRecordsFailClosedWithoutChangingPrimary() throws {
        let invalidRecords = [
            makeRecord(index: 1, finalText: "unexpected-final"),
            makeRecord(index: 2, warning: .cancelled),
            makeRecord(index: 3, source: .polished, outcome: .finalized),
            makeRecord(index: 4, finalText: " \t", source: .polished, outcome: .finalized),
            makeRecord(
                index: 5,
                finalText: "final",
                source: .polished,
                delivery: .copiedByPreference,
                outcome: .finalized
            ),
            makeRecord(index: 6, finalText: "final", source: .polished, outcome: .delivered),
            makeRecord(
                index: 7,
                finalText: "final",
                source: .polished,
                delivery: .copiedByUser,
                outcome: .cancelled
            ),
            makeRecord(
                index: 8,
                finalText: "final",
                source: .rawFallback,
                delivery: .copiedByUser,
                outcome: .failed
            )
        ]
        for record in invalidRecords {
            let directory = temporaryDirectory()
            try createSecureDirectory(directory)
            let primary = historyArtifact("history-v1.json", in: directory)
            let bytes = try JSONEncoder.historyEncoder.encode(
                HistoryEnvelope(
                    schemaVersion: 1,
                    generation: 0,
                    enabled: true,
                    records: [record],
                    tombstones: []
                )
            )
            try writeSecure(bytes, to: primary)
            XCTAssertHistoryInitError(.corrupt, directory: directory)
            XCTAssertEqual(try Data(contentsOf: primary), bytes)
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testInvalidUpdateCandidatesAreRejectedBeforeFilesystemMutation() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try JSONHistoryStore(directory: directory, enabled: true, clock: TestHistoryClock())
        let generation = await store.generation()
        let raw = makeRecord(index: 1)
        try await store.appendRaw(raw, expectedGeneration: generation)
        let primary = historyArtifact("history-v1.json", in: directory)
        let priorBytes = try Data(contentsOf: primary)
        let invalidUpdates: [(String, ResultSource, DiagnosticCode?, DeliveryOutcome?, HistoryOutcome)] = [
            ("final", .raw, nil, nil, .rawSaved),
            ("", .polished, nil, nil, .finalized),
            (" \t", .rawFallback, nil, nil, .failed),
            ("final", .polished, nil, .copiedByPreference, .finalized),
            ("final", .polished, nil, nil, .delivered),
            ("final", .polished, nil, .copiedByUser, .cancelled),
            ("final", .rawFallback, nil, .copiedByUser, .failed)
        ]

        for (finalText, source, warning, delivery, outcome) in invalidUpdates {
            await XCTAssertHistoryError(.invalidRecord) {
                try await store.updateResult(
                    sessionID: raw.sessionID,
                    finalText: finalText,
                    source: source,
                    warning: warning,
                    delivery: delivery,
                    outcome: outcome,
                    expectedGeneration: generation
                )
            }
            XCTAssertEqual(try Data(contentsOf: primary), priorBytes)
            try await XCTAssertEqualAsync(store.load(), [raw])
        }
    }

    func testOversizedRawAndFinalCandidatesAreRejectedBeforeAnyFilesystemMutation() async throws {
        let oversized = String(repeating: "x", count: 16 * 1_024 * 1_024 + 1_024)

        let emptyDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: emptyDirectory) }
        let emptyStore = try JSONHistoryStore(
            directory: emptyDirectory,
            enabled: true,
            clock: TestHistoryClock()
        )
        await XCTAssertHistoryError(.invalidRecord) {
            try await emptyStore.appendRaw(
                self.makeRecord(index: 1, rawText: oversized),
                expectedGeneration: 0
            )
        }
        for name in ["history-v1.json", "history-v1.tmp", "history-v1.backup", "history-v1.txn", "history-v1.commit"] {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: historyArtifact(name, in: emptyDirectory).path
            ))
        }

        let priorDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: priorDirectory) }
        var store: JSONHistoryStore? = try JSONHistoryStore(
            directory: priorDirectory,
            enabled: true,
            clock: TestHistoryClock()
        )
        let raw = makeRecord(index: 2)
        try await store!.appendRaw(raw, expectedGeneration: 0)
        let primary = historyArtifact("history-v1.json", in: priorDirectory)
        let priorBytes = try Data(contentsOf: primary)

        await XCTAssertHistoryError(.invalidRecord) {
            try await store!.updateResult(
                sessionID: raw.sessionID,
                finalText: oversized,
                source: .polished,
                warning: nil,
                delivery: nil,
                outcome: .finalized,
                expectedGeneration: 0
            )
        }
        XCTAssertEqual(try Data(contentsOf: primary), priorBytes)
        try await XCTAssertEqualAsync(store!.load(), [raw])
        store = nil

        let reopened = try JSONHistoryStore(
            directory: priorDirectory,
            enabled: false,
            clock: TestHistoryClock()
        )
        try await XCTAssertEqualAsync(reopened.load(), [raw])
    }

    func testSchemaZeroMigratesAtomicallyWithIdenticalFieldsAndEmptyTombstones() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try createSecureDirectory(directory)
        let records = [makeRecord(index: 1), makeRecord(index: 2)]
        let schemaZero = HistoryEnvelopeV0(
            schemaVersion: 0,
            generation: 7,
            enabled: false,
            records: records
        )
        let primary = historyArtifact("history-v1.json", in: directory)
        try writeSecure(try JSONEncoder.historyEncoder.encode(schemaZero), to: primary)

        let store = try JSONHistoryStore(directory: directory, enabled: true, clock: TestHistoryClock())
        await XCTAssertEqualAsync( store.generation(), 7)
        try await XCTAssertEqualAsync( store.load(), sortedHistory(records))

        let migrated = try JSONDecoder.historyDecoder.decode(
            HistoryEnvelope.self,
            from: Data(contentsOf: primary)
        )
        XCTAssertEqual(migrated.schemaVersion, 1)
        XCTAssertEqual(migrated.generation, 7)
        XCTAssertFalse(migrated.enabled)
        XCTAssertEqual(migrated.records, sortedHistory(records))
        XCTAssertTrue(migrated.tombstones.isEmpty)
    }

    func testSchemaZeroMigrationFailurePreservesOriginalBytes() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try createSecureDirectory(directory)
        let schemaZero = HistoryEnvelopeV0(
            schemaVersion: 0,
            generation: 3,
            enabled: true,
            records: [makeRecord(index: 1)]
        )
        let primary = historyArtifact("history-v1.json", in: directory)
        let original = try JSONEncoder.historyEncoder.encode(schemaZero)
        try writeSecure(original, to: primary)
        let hooks = HistoryStoreHooks()
        hooks.failNext(.tempWrite)

        XCTAssertThrowsError(
            try JSONHistoryStore(
                directory: directory,
                enabled: false,
                clock: TestHistoryClock(),
                hooks: hooks
            )
        ) { error in
            XCTAssertEqual(error as? HistoryStoreError, .writeFailed)
        }
        XCTAssertEqual(try Data(contentsOf: primary), original)
    }

    func testOrphanBackupAndTempFailClosedWithoutChangingArtifacts() throws {
        let previous = HistoryEnvelope(
            schemaVersion: 1,
            generation: 4,
            enabled: false,
            records: [makeRecord(index: 1)],
            tombstones: []
        )
        let candidate = HistoryEnvelope(
            schemaVersion: 1,
            generation: 5,
            enabled: true,
            records: [makeRecord(index: 2)],
            tombstones: []
        )
        let primaryBytes = try JSONEncoder.historyEncoder.encode(candidate)
        let artifactFixtures: [(String, Data)] = [
            ("history-v1.backup", try JSONEncoder.historyEncoder.encode(previous)),
            ("history-v1.backup", Data()),
            ("history-v1.tmp", primaryBytes)
        ]

        for (name, artifactBytes) in artifactFixtures {
            let directory = temporaryDirectory()
            try createSecureDirectory(directory)
            let primary = historyArtifact("history-v1.json", in: directory)
            let artifact = historyArtifact(name, in: directory)
            try writeSecure(primaryBytes, to: primary)
            try writeSecure(artifactBytes, to: artifact)

            XCTAssertHistoryInitError(.corrupt, directory: directory)
            XCTAssertEqual(try Data(contentsOf: primary), primaryBytes)
            XCTAssertEqual(try Data(contentsOf: artifact), artifactBytes)
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testInvalidTransactionBackupFailsClosedWithoutChangingArtifacts() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try createSecureDirectory(directory)
        let primary = historyArtifact("history-v1.json", in: directory)
        let backup = historyArtifact("history-v1.backup", in: directory)
        let primaryBytes = try JSONEncoder.historyEncoder.encode(
            HistoryEnvelope(
                schemaVersion: 1,
                generation: 1,
                enabled: true,
                records: [makeRecord(index: 1)],
                tombstones: []
            )
        )
        let backupBytes = Data("invalid-safe-backup".utf8)
        try writeSecure(primaryBytes, to: primary)
        try writeSecure(backupBytes, to: backup)

        XCTAssertThrowsError(
            try JSONHistoryStore(directory: directory, enabled: true, clock: TestHistoryClock())
        ) { error in
            XCTAssertEqual(error as? HistoryStoreError, .corrupt)
        }
        XCTAssertEqual(try Data(contentsOf: primary), primaryBytes)
        XCTAssertEqual(try Data(contentsOf: backup), backupBytes)
    }

    func testThrowingInitializerReleasesProcessLockDescriptor() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try createSecureDirectory(directory)
        let primary = historyArtifact("history-v1.json", in: directory)
        try writeSecure(Data("bad-safe-envelope".utf8), to: primary)
        XCTAssertHistoryInitError(.corrupt, directory: directory)

        try FileManager.default.removeItem(at: primary)
        let store = try JSONHistoryStore(directory: directory, enabled: true, clock: TestHistoryClock())
        XCTAssertNotNil(store as any HistoryStore)
    }

    func testCreatedArtifactsUseExactUserOnlyModes() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try JSONHistoryStore(directory: directory, enabled: true, clock: TestHistoryClock())
        XCTAssertEqual(try permissionBits(directory), 0o700)
        XCTAssertEqual(try permissionBits(historyArtifact("history-v1.lock", in: directory)), 0o600)

        let generation = await store.generation()
        try await store.appendRaw(makeRecord(index: 1), expectedGeneration: generation)
        XCTAssertEqual(try permissionBits(historyArtifact("history-v1.json", in: directory)), 0o600)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: historyArtifact("history-v1.tmp", in: directory).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: historyArtifact("history-v1.backup", in: directory).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: historyArtifact("history-v1.txn", in: directory).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: historyArtifact("history-v1.commit", in: directory).path
        ))
    }

    func testUnsafeDirectorySymlinkWrongTypeAndWrongOwnerAreRejected() throws {
        let permissive = temporaryDirectory()
        try FileManager.default.createDirectory(at: permissive, withIntermediateDirectories: true)
        try chmodPath(permissive, mode: 0o755)
        XCTAssertHistoryInitError(.unsafeStorage, directory: permissive)
        try FileManager.default.removeItem(at: permissive)

        let target = temporaryDirectory()
        try createSecureDirectory(target)
        let link = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertHistoryInitError(.unsafeStorage, directory: link)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.removeItem(at: target)

        let regularFile = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: regularFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeSecure(Data(), to: regularFile)
        XCTAssertHistoryInitError(.unsafeStorage, directory: regularFile)
        try FileManager.default.removeItem(at: regularFile)

        let wrongOwnerDirectory = temporaryDirectory()
        let hooks = HistoryStoreHooks(ownerOverride: currentUserID() &+ 1)
        XCTAssertThrowsError(
            try JSONHistoryStore(
                directory: wrongOwnerDirectory,
                enabled: true,
                clock: TestHistoryClock(),
                hooks: hooks
            )
        ) { error in
            XCTAssertEqual(error as? HistoryStoreError, .unsafeStorage)
        }
        try? FileManager.default.removeItem(at: wrongOwnerDirectory)
    }

    func testUnsafePrimaryLockTempAndBackupObjectsAreRejected() throws {
        let names = [
            "history-v1.json", "history-v1.lock", "history-v1.tmp", "history-v1.backup",
            "history-v1.txn", "history-v1.commit"
        ]
        let validEnvelope = try JSONEncoder.historyEncoder.encode(
            HistoryEnvelope(schemaVersion: 1, generation: 0, enabled: true, records: [], tombstones: [])
        )

        for name in names {
            let permissiveDirectory = temporaryDirectory()
            try createSecureDirectory(permissiveDirectory)
            let permissive = historyArtifact(name, in: permissiveDirectory)
            try writeSecure(name == "history-v1.json" ? validEnvelope : Data(), to: permissive)
            try chmodPath(permissive, mode: 0o644)
            XCTAssertHistoryInitError(.unsafeStorage, directory: permissiveDirectory)
            try FileManager.default.removeItem(at: permissiveDirectory)

            let wrongTypeDirectory = temporaryDirectory()
            try createSecureDirectory(wrongTypeDirectory)
            try FileManager.default.createDirectory(
                at: historyArtifact(name, in: wrongTypeDirectory),
                withIntermediateDirectories: false
            )
            XCTAssertHistoryInitError(.unsafeStorage, directory: wrongTypeDirectory)
            try FileManager.default.removeItem(at: wrongTypeDirectory)

            let symlinkDirectory = temporaryDirectory()
            try createSecureDirectory(symlinkDirectory)
            let outside = temporaryDirectory()
            try FileManager.default.createDirectory(
                at: outside.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try writeSecure(Data(), to: outside)
            try FileManager.default.createSymbolicLink(
                at: historyArtifact(name, in: symlinkDirectory),
                withDestinationURL: outside
            )
            XCTAssertHistoryInitError(.unsafeStorage, directory: symlinkDirectory)
            try FileManager.default.removeItem(at: symlinkDirectory)
            try FileManager.default.removeItem(at: outside)
        }
    }

    func testRealChildProcessLockBlocksStoreThenReopenSucceedsAfterHandshakeRelease() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try createSecureDirectory(directory)
        let holder = try ChildLockHolder(lockURL: historyArtifact("history-v1.lock", in: directory))
        XCTAssertEqual(try holder.waitUntilReady(), "READY")

        XCTAssertHistoryInitError(.locked, directory: directory)
        try holder.releaseAndWait()

        let store = try JSONHistoryStore(directory: directory, enabled: true, clock: TestHistoryClock())
        await XCTAssertEqualAsync( store.generation(), 0)
    }

    func testActorHeldLockMakesRealChildFailNonblockingWithoutSleep() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try JSONHistoryStore(directory: directory, enabled: true, clock: TestHistoryClock())
        let result = try childNonblockingLockResult(
            lockURL: historyArtifact("history-v1.lock", in: directory)
        )
        XCTAssertEqual(result, "LOCKED")
        _ = store
    }

    func testErrorsAndReflectionNeverExposePathTranscriptOrUnderlyingOSText() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try createSecureDirectory(directory)
        let canary = "fixture-transcript-canary"
        try writeSecure(Data("{\"schemaVersion\":1,\"rawText\":\"\(canary)\"".utf8), to: historyArtifact("history-v1.json", in: directory))

        do {
            _ = try JSONHistoryStore(directory: directory, enabled: true, clock: TestHistoryClock())
            XCTFail("Expected corrupt history")
        } catch {
            assertSanitized(error, excluding: [directory.path, canary, "Operation not permitted", "errno"])
        }

        try FileManager.default.removeItem(at: historyArtifact("history-v1.json", in: directory))
        let hooks = HistoryStoreHooks()
        let store = try JSONHistoryStore(
            directory: directory,
            enabled: true,
            clock: TestHistoryClock(),
            hooks: hooks
        )
        hooks.failNext(.tempWrite)
        do {
            try await store.appendRaw(makeRecord(index: 1), expectedGeneration: 0)
            XCTFail("Expected write failure")
        } catch {
            assertSanitized(error, excluding: [directory.path, "raw-1", "No space left", "errno"])
        }
    }

    private func makeRecord(
        index: Int,
        startedAt: Date? = nil,
        rawText: String? = nil,
        finalText: String? = nil,
        source: ResultSource = .raw,
        warning: DiagnosticCode? = nil,
        delivery: DeliveryOutcome? = nil,
        outcome: HistoryOutcome = .rawSaved
    ) -> HistoryRecord {
        HistoryRecord(
            sessionID: SessionID(rawValue: fixedUUID(index)),
            startedAt: startedAt ?? Date(timeIntervalSince1970: TimeInterval(index)),
            rawText: rawText ?? "raw-\(index)",
            finalText: finalText,
            source: source,
            warning: warning,
            delivery: delivery,
            outcome: outcome
        )
    }

    private func assertGatedAppendIsInvalidated(by mutation: PrivacyMutation) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = HistoryCommitGate()
        let hooks = HistoryStoreHooks(gate: gate, gatedOperation: .append)
        let store = try JSONHistoryStore(
            directory: directory,
            enabled: true,
            clock: TestHistoryClock(),
            hooks: hooks
        )
        let generation = await store.generation()
        let record = makeRecord(index: mutation.fixtureIndex)
        let pending = Task {
            try await store.appendRaw(record, expectedGeneration: generation)
        }
        await gate.waitUntilPaused()
        switch mutation {
        case .disable:
            _ = try await store.setEnabled(false)
        case .clear:
            _ = try await store.clear()
        case .delete:
            try await store.delete(sessionID: record.sessionID)
        }
        await gate.resume()
        await XCTAssertAnyHistoryError { try await pending.value }
        try await XCTAssertEqualAsync( store.load(), [], "mutation=\(mutation)")
    }

    private func assertGatedUpdateIsInvalidated(by mutation: PrivacyMutation) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = HistoryCommitGate()
        let hooks = HistoryStoreHooks(gate: gate, gatedOperation: .update)
        let store = try JSONHistoryStore(
            directory: directory,
            enabled: true,
            clock: TestHistoryClock(),
            hooks: hooks
        )
        let generation = await store.generation()
        let record = makeRecord(index: 20 + mutation.fixtureIndex)
        try await store.appendRaw(record, expectedGeneration: generation)
        let pending = Task {
            try await store.updateResult(
                sessionID: record.sessionID,
                finalText: "gated-final",
                source: .polished,
                warning: nil,
                delivery: .copiedByPreference,
                outcome: .delivered,
                expectedGeneration: generation
            )
        }
        await gate.waitUntilPaused()
        switch mutation {
        case .disable:
            _ = try await store.setEnabled(false)
        case .clear:
            _ = try await store.clear()
        case .delete:
            try await store.delete(sessionID: record.sessionID)
        }
        await gate.resume()
        await XCTAssertAnyHistoryError { try await pending.value }
        switch mutation {
        case .disable:
            try await XCTAssertEqualAsync( store.load(), [record])
        case .clear, .delete:
            try await XCTAssertEqualAsync( store.load(), [])
        }
    }

    private func XCTAssertHistoryInitError(
        _ expected: HistoryStoreError,
        directory: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try JSONHistoryStore(directory: directory, enabled: true, clock: TestHistoryClock()),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? HistoryStoreError, expected, file: file, line: line)
        }
    }

    private func assertSanitized(
        _ error: Error,
        excluding forbiddenValues: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNotNil(error as? HistoryStoreError, file: file, line: line)
        let surfaces = [String(describing: error), String(reflecting: error)]
        for surface in surfaces {
            for forbidden in forbiddenValues {
                XCTAssertFalse(surface.contains(forbidden), "leaked=\(forbidden)", file: file, line: line)
            }
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("utterink-history-\(UUID().uuidString)")
    }
}

private func hostileEnvelopeFixtures() throws -> [Data] {
    let record = HistoryRecord(
        sessionID: SessionID(rawValue: fixedUUID(900)),
        startedAt: Date(timeIntervalSince1970: 900),
        rawText: "strict-safe-raw",
        finalText: "strict-safe-final",
        source: .polished,
        warning: nil,
        delivery: .copiedByPreference,
        outcome: .delivered
    )
    let schemaOne = try JSONEncoder.historyEncoder.encode(
        HistoryEnvelope(
            schemaVersion: 1,
            generation: 4,
            enabled: true,
            records: [record],
            tombstones: []
        )
    )
    let schemaZero = try JSONEncoder.historyEncoder.encode(
        HistoryEnvelopeV0(
            schemaVersion: 0,
            generation: 4,
            enabled: true,
            records: [record]
        )
    )
    let schemaOneRoot = try XCTUnwrap(
        JSONSerialization.jsonObject(with: schemaOne) as? [String: Any]
    )
    let schemaZeroRoot = try XCTUnwrap(
        JSONSerialization.jsonObject(with: schemaZero) as? [String: Any]
    )
    var fixtures: [Data] = []

    var topLevel = schemaOneRoot
    topLevel["credential"] = "forbidden-safe-value"
    fixtures.append(try strictJSONData(topLevel))

    var recordLevel = schemaOneRoot
    var records = try XCTUnwrap(recordLevel["records"] as? [[String: Any]])
    records[0]["prompt"] = "forbidden-safe-value"
    recordLevel["records"] = records
    fixtures.append(try strictJSONData(recordLevel))

    var sessionLevel = schemaOneRoot
    records = try XCTUnwrap(sessionLevel["records"] as? [[String: Any]])
    var sessionID = try XCTUnwrap(records[0]["sessionID"] as? [String: Any])
    sessionID["providerURL"] = "forbidden-safe-value"
    records[0]["sessionID"] = sessionID
    sessionLevel["records"] = records
    fixtures.append(try strictJSONData(sessionLevel))

    var deliveryLevel = schemaOneRoot
    records = try XCTUnwrap(deliveryLevel["records"] as? [[String: Any]])
    var delivery = try XCTUnwrap(records[0]["delivery"] as? [String: Any])
    delivery["credential"] = ["unexpected": true]
    records[0]["delivery"] = delivery
    deliveryLevel["records"] = records
    fixtures.append(try strictJSONData(deliveryLevel))

    var schemaZeroTop = schemaZeroRoot
    schemaZeroTop["providerURL"] = "forbidden-safe-value"
    fixtures.append(try strictJSONData(schemaZeroTop))

    var schemaZeroRecord = schemaZeroRoot
    records = try XCTUnwrap(schemaZeroRecord["records"] as? [[String: Any]])
    records[0]["prompt"] = "forbidden-safe-value"
    schemaZeroRecord["records"] = records
    fixtures.append(try strictJSONData(schemaZeroRecord))

    return fixtures
}

private func strictJSONData(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private enum PrivacyMutation: CaseIterable {
    case disable
    case clear
    case delete

    var fixtureIndex: Int {
        switch self {
        case .disable: return 301
        case .clear: return 302
        case .delete: return 303
        }
    }
}

private struct HistoryEnvelopeV0: Codable {
    let schemaVersion: Int
    let generation: UInt64
    let enabled: Bool
    let records: [HistoryRecord]
}

private struct TestHistoryClock: AppClock {
    let now = Date(timeIntervalSince1970: 1_000)

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
    }
}

private extension JSONEncoder {
    static var historyEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var historyDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

private func fixedUUID(_ index: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llX", UInt64(index)))!
}

private func historyArtifact(_ name: String, in directory: URL) -> URL {
    directory.appendingPathComponent(name, isDirectory: false)
}

private func sortedHistory(_ records: [HistoryRecord]) -> [HistoryRecord] {
    records.sorted { lhs, rhs in
        if lhs.startedAt != rhs.startedAt {
            return lhs.startedAt > rhs.startedAt
        }
        return lhs.sessionID.rawValue.uuidString < rhs.sessionID.rawValue.uuidString
    }
}

private func recursiveJSONKeys(_ value: Any) -> [String] {
    if let dictionary = value as? [String: Any] {
        return dictionary.keys.flatMap { [$0] + recursiveJSONKeys(dictionary[$0] as Any) }
    }
    if let array = value as? [Any] {
        return array.flatMap(recursiveJSONKeys)
    }
    return []
}

private func createSecureDirectory(_ directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    try chmodPath(directory, mode: 0o700)
}

private func writeSecure(_ data: Data, to url: URL) throws {
    guard FileManager.default.createFile(
        atPath: url.path,
        contents: data,
        attributes: [.posixPermissions: 0o600]
    ) else {
        throw TestHarnessError.fileCreation
    }
    try chmodPath(url, mode: 0o600)
}

private func chmodPath(_ url: URL, mode: mode_t) throws {
    guard chmod(url.path, mode) == 0 else {
        throw TestHarnessError.posix
    }
}

private func permissionBits(_ url: URL) throws -> mode_t {
    var value = stat()
    guard lstat(url.path, &value) == 0 else {
        throw TestHarnessError.posix
    }
    return value.st_mode & 0o777
}

private func currentUserID() -> UInt32 {
    getuid()
}

private final class ChildLockHolder {
    private let process: Process
    private let input: Pipe
    private let output: Pipe

    init(lockURL: URL) throws {
        process = Process()
        input = Pipe()
        output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            """
            import fcntl, os, sys
            fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
            os.fchmod(fd, 0o600)
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            sys.stdout.write("READY\\n")
            sys.stdout.flush()
            sys.stdin.buffer.readline()
            """,
            lockURL.path
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
    }

    func waitUntilReady() throws -> String {
        try readLine(from: output.fileHandleForReading)
    }

    func releaseAndWait() throws {
        try input.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TestHarnessError.childProcess
        }
    }

    deinit {
        if process.isRunning {
            try? input.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
        }
    }
}

private func childNonblockingLockResult(lockURL: URL) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [
        "-c",
        """
        import fcntl, os, sys
        fd = os.open(sys.argv[1], os.O_RDWR)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            print("ACQUIRED")
        except BlockingIOError:
            print("LOCKED")
        """,
        lockURL.path
    ]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw TestHarnessError.childProcess
    }
    return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func readLine(from handle: FileHandle) throws -> String {
    var bytes = Data()
    while true {
        guard let byte = try handle.read(upToCount: 1), !byte.isEmpty else {
            throw TestHarnessError.childProcess
        }
        if byte[byte.startIndex] == 0x0A {
            return String(decoding: bytes, as: UTF8.self)
        }
        bytes.append(byte)
    }
}

private enum TestHarnessError: Error {
    case childProcess
    case fileCreation
    case posix
}

private func XCTAssertHistoryError<T>(
    _ expected: HistoryStoreError,
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected history error \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? HistoryStoreError, expected, file: file, line: line)
    }
}

private func XCTAssertAnyHistoryError<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected a history error", file: file, line: line)
    } catch {
        XCTAssertNotNil(error as? HistoryStoreError, file: file, line: line)
    }
}

private func XCTAssertEqualAsync<T: Equatable>(
    _ actual: T,
    _ expected: T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(actual, expected, message(), file: file, line: line)
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected async expression to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}
