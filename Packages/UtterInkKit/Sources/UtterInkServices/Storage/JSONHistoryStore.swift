import CryptoKit
import Darwin
import Foundation
import UtterInkCore

enum HistoryMutationKind: Sendable {
    case append
    case update
}

enum HistoryWritePhase: String, Sendable {
    case permission
    case tempCreate
    case tempWrite
    case tempSync
    case backupCreate
    case backupWrite
    case backupSync
    case replace
    case parentSyncAfterReplace
    case rollbackReplace
    case journalCreate
    case journalWrite
    case journalSync
    case commitRecordCreate
    case commitRecordPrepareSync
    case armedDirectorySync
    case primaryReplace
    case primarySync
    case commitRecordPublish
    case rollbackRestore
    case rollbackSync
    case rollbackCleanupSync
    case cleanupBackup
    case cleanupJournal
    case cleanupArmedDirectorySync
    case cleanupCommit
    case cleanupFinalDirectorySync
}

actor HistoryCommitGate {
    private var paused = false
    private var released = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        guard !released else { return }
        paused = true
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                releaseContinuation = continuation
            }
        }
    }

    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { continuation in
            pauseWaiters.append(continuation)
        }
    }

    func resume() {
        guard !released else { return }
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

final class HistoryStoreHooks: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [HistoryWritePhase] = []
    private let gate: HistoryCommitGate?
    private let gatedOperation: HistoryMutationKind?
    private var gateConsumed = false
    let ownerOverride: UInt32?

    init(
        gate: HistoryCommitGate? = nil,
        gatedOperation: HistoryMutationKind? = nil,
        ownerOverride: UInt32? = nil
    ) {
        self.gate = gate
        self.gatedOperation = gatedOperation
        self.ownerOverride = ownerOverride
    }

    func failNext(_ phase: HistoryWritePhase) {
        lock.lock()
        failures.append(phase)
        lock.unlock()
    }

    func consumeFailure(_ phase: HistoryWritePhase) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard failures.first == phase else { return false }
        failures.removeFirst()
        return true
    }

    func takeGate(for operation: HistoryMutationKind) -> HistoryCommitGate? {
        lock.lock()
        defer { lock.unlock() }
        guard !gateConsumed, gatedOperation == operation else { return nil }
        gateConsumed = true
        return gate
    }
}

public actor JSONHistoryStore: HistoryStore {
    private let directoryDescriptor: Int32
    private let lockDescriptor: Int32
    private let clock: any AppClock
    private let hooks: HistoryStoreHooks
    private var envelope: HistoryEnvelope
    private var seenSessionIDs: Set<SessionID>
    private var processTombstones: Set<SessionID> = []
    private var pendingAppendIDs: Set<SessionID> = []
    private var revision: UInt64 = 0
    private var dirtyPrivacyState = false
    private var poisoned = false

    public init(directory: URL, enabled: Bool, clock: any AppClock) throws {
        let hooks = HistoryStoreHooks()
        let state = try HistoryPersistence.bootstrap(
            directory: directory,
            initialEnabled: enabled,
            hooks: hooks
        )
        directoryDescriptor = state.directoryDescriptor
        lockDescriptor = state.lockDescriptor
        envelope = state.envelope
        seenSessionIDs = Set(state.envelope.records.map(\.sessionID))
        self.clock = clock
        self.hooks = hooks
    }

    init(
        directory: URL,
        enabled: Bool,
        clock: any AppClock,
        hooks: HistoryStoreHooks
    ) throws {
        let state = try HistoryPersistence.bootstrap(
            directory: directory,
            initialEnabled: enabled,
            hooks: hooks
        )
        directoryDescriptor = state.directoryDescriptor
        lockDescriptor = state.lockDescriptor
        envelope = state.envelope
        seenSessionIDs = Set(state.envelope.records.map(\.sessionID))
        self.clock = clock
        self.hooks = hooks
    }

    deinit {
        close(lockDescriptor)
        close(directoryDescriptor)
    }

    public func generation() async -> UInt64 {
        envelope.generation
    }

    public func appendRaw(
        _ record: HistoryRecord,
        expectedGeneration: UInt64
    ) async throws {
        try requireNormalWrite(expectedGeneration: expectedGeneration)
        guard HistoryPersistence.isValidRawRecord(record) else {
            throw HistoryStoreError.invalidRecord
        }
        if processTombstones.contains(record.sessionID) || envelope.tombstones.contains(record.sessionID) {
            throw HistoryStoreError.tombstoned
        }
        if seenSessionIDs.contains(record.sessionID) || pendingAppendIDs.contains(record.sessionID) {
            throw HistoryStoreError.duplicateSession
        }

        pendingAppendIDs.insert(record.sessionID)
        defer { pendingAppendIDs.remove(record.sessionID) }

        var candidate = envelope
        candidate.records.append(record)
        candidate.records = Array(HistoryPersistence.sorted(candidate.records).prefix(20))
        let capturedRevision = revision
        if let gate = hooks.takeGate(for: .append) {
            await gate.pause()
        }
        try revalidateSuspendedWrite(
            expectedGeneration: expectedGeneration,
            capturedRevision: capturedRevision,
            sessionID: record.sessionID
        )
        try commitNormal(candidate)
        envelope = candidate
        seenSessionIDs.insert(record.sessionID)
        revision &+= 1
        _ = clock
    }

    public func updateResult(
        sessionID: SessionID,
        finalText: String,
        source: ResultSource,
        warning: DiagnosticCode?,
        delivery: DeliveryOutcome?,
        outcome: HistoryOutcome,
        expectedGeneration: UInt64
    ) async throws {
        try requireNormalWrite(expectedGeneration: expectedGeneration)
        if processTombstones.contains(sessionID) || envelope.tombstones.contains(sessionID) {
            throw HistoryStoreError.tombstoned
        }
        guard let index = envelope.records.firstIndex(where: { $0.sessionID == sessionID }) else {
            throw HistoryStoreError.missingRecord
        }

        var candidate = envelope
        candidate.records[index].finalText = finalText
        candidate.records[index].source = source
        candidate.records[index].warning = warning
        candidate.records[index].delivery = delivery
        candidate.records[index].outcome = outcome
        guard HistoryPersistence.isValidRecord(candidate.records[index]) else {
            throw HistoryStoreError.invalidRecord
        }
        let capturedRevision = revision
        if let gate = hooks.takeGate(for: .update) {
            await gate.pause()
        }
        try revalidateSuspendedWrite(
            expectedGeneration: expectedGeneration,
            capturedRevision: capturedRevision,
            sessionID: sessionID
        )
        try commitNormal(candidate)
        envelope = candidate
        revision &+= 1
    }

    public func delete(sessionID: SessionID) async throws {
        try requireNotPoisoned()
        if dirtyPrivacyState,
           processTombstones.contains(sessionID),
           !envelope.records.contains(where: { $0.sessionID == sessionID }) {
            try persistDirtyPrivacyState()
            return
        }
        if !dirtyPrivacyState,
           processTombstones.contains(sessionID),
           !envelope.records.contains(where: { $0.sessionID == sessionID }) {
            return
        }

        processTombstones.insert(sessionID)
        envelope.tombstones.insert(sessionID)
        envelope.records.removeAll { $0.sessionID == sessionID }
        dirtyPrivacyState = true
        revision &+= 1
        try persistDirtyPrivacyState()
    }

    public func setEnabled(_ enabled: Bool) async throws -> UInt64 {
        try requireNotPoisoned()
        if dirtyPrivacyState {
            if enabled == envelope.enabled {
                try persistDirtyPrivacyState()
                return envelope.generation
            }
            throw HistoryStoreError.dirty
        }
        guard enabled != envelope.enabled else {
            return envelope.generation
        }
        guard envelope.generation < UInt64.max else {
            throw HistoryStoreError.generationOverflow
        }

        if enabled {
            var candidate = envelope
            candidate.generation += 1
            candidate.enabled = true
            try commitNormal(candidate)
            envelope = candidate
            revision &+= 1
            return candidate.generation
        }

        envelope.generation += 1
        envelope.enabled = false
        dirtyPrivacyState = true
        revision &+= 1
        try persistDirtyPrivacyState()
        return envelope.generation
    }

    public func clear() async throws -> UInt64 {
        try requireNotPoisoned()
        guard envelope.generation < UInt64.max else {
            throw HistoryStoreError.generationOverflow
        }
        envelope.generation += 1
        envelope.records.removeAll()
        envelope.tombstones.removeAll()
        processTombstones.removeAll()
        dirtyPrivacyState = true
        revision &+= 1
        try persistDirtyPrivacyState()
        return envelope.generation
    }

    public func load() async throws -> [HistoryRecord] {
        HistoryPersistence.sorted(envelope.records)
    }

    private func requireNotPoisoned() throws {
        if poisoned {
            throw HistoryStoreError.poisoned
        }
    }

    private func requireNormalWrite(expectedGeneration: UInt64) throws {
        try requireNotPoisoned()
        if dirtyPrivacyState {
            throw HistoryStoreError.dirty
        }
        guard expectedGeneration == envelope.generation else {
            throw HistoryStoreError.staleGeneration
        }
        guard envelope.enabled else {
            throw HistoryStoreError.disabled
        }
    }

    private func revalidateSuspendedWrite(
        expectedGeneration: UInt64,
        capturedRevision: UInt64,
        sessionID: SessionID
    ) throws {
        try requireNotPoisoned()
        if processTombstones.contains(sessionID) || envelope.tombstones.contains(sessionID) {
            throw HistoryStoreError.tombstoned
        }
        if dirtyPrivacyState {
            throw HistoryStoreError.dirty
        }
        guard expectedGeneration == envelope.generation else {
            throw HistoryStoreError.staleGeneration
        }
        guard envelope.enabled else {
            throw HistoryStoreError.disabled
        }
        guard capturedRevision == revision else {
            throw HistoryStoreError.staleOperation
        }
    }

    private func commitNormal(_ candidate: HistoryEnvelope) throws {
        do {
            try HistoryPersistence.commit(
                candidate,
                directoryDescriptor: directoryDescriptor,
                hooks: hooks
            )
        } catch TransactionFailure.unrecoverable {
            poisoned = true
            throw HistoryStoreError.writeFailed
        } catch TransactionFailure.invalidCandidate {
            throw HistoryStoreError.invalidRecord
        } catch {
            throw HistoryStoreError.writeFailed
        }
    }

    private func persistDirtyPrivacyState() throws {
        do {
            try HistoryPersistence.commit(
                envelope,
                directoryDescriptor: directoryDescriptor,
                hooks: hooks
            )
            dirtyPrivacyState = false
        } catch TransactionFailure.unrecoverable {
            poisoned = true
            throw HistoryStoreError.writeFailed
        } catch TransactionFailure.invalidCandidate {
            throw HistoryStoreError.invalidRecord
        } catch {
            throw HistoryStoreError.writeFailed
        }
    }
}

private struct HistoryBootstrapState {
    let directoryDescriptor: Int32
    let lockDescriptor: Int32
    let envelope: HistoryEnvelope
}

private enum TransactionFailure: Error {
    case ordinary
    case unrecoverable
    case invalidCandidate
}

private enum HistoryPersistence {
    private static let primaryName = "history-v1.json"
    private static let lockName = "history-v1.lock"
    private static let tempName = "history-v1.tmp"
    private static let backupName = "history-v1.backup"
    private static let journalName = "history-v1.txn"
    private static let commitName = "history-v1.commit"
    private static let maximumEnvelopeBytes = 16 * 1_024 * 1_024

    private struct SchemaProbe: Decodable {
        let schemaVersion: Int
    }

    private struct SchemaZeroEnvelope: Decodable {
        let schemaVersion: Int
        let generation: UInt64
        let enabled: Bool
        let records: [HistoryRecord]
    }

    private struct SchemaOneEnvelope: Decodable {
        let schemaVersion: Int
        let generation: UInt64
        let enabled: Bool
        let records: [HistoryRecord]
        let tombstones: [SessionID]
    }

    private struct PersistedEnvelope: Encodable {
        let schemaVersion: Int
        let generation: UInt64
        let enabled: Bool
        let records: [HistoryRecord]
        let tombstones: [SessionID]
    }

    private struct DecodedEnvelope {
        let envelope: HistoryEnvelope
        let requiresMigration: Bool
    }

    private struct TransactionManifest: Codable, Equatable {
        let formatVersion: Int
        let transactionID: String
        let priorExists: Bool
        let priorSHA256: String
        let candidateSHA256: String
    }

    private struct CommitPayload: Codable {
        let formatVersion: Int
        let transactionID: String
        let candidateSHA256: String
    }

    private struct CommitRecord: Codable {
        let formatVersion: Int
        let transactionID: String
        let candidateSHA256: String
        let checksumSHA256: String
    }

    static func bootstrap(
        directory: URL,
        initialEnabled: Bool,
        hooks: HistoryStoreHooks
    ) throws -> HistoryBootstrapState {
        let directoryDescriptor = try openVerifiedDirectory(directory, hooks: hooks)
        var keepDirectory = false
        defer {
            if !keepDirectory {
                close(directoryDescriptor)
            }
        }

        let lockDescriptor = try openVerifiedLock(
            directoryDescriptor: directoryDescriptor,
            hooks: hooks
        )
        var keepLock = false
        defer {
            if !keepLock {
                close(lockDescriptor)
            }
        }

        if flock(lockDescriptor, LOCK_EX | LOCK_NB) != 0 {
            if errno == EWOULDBLOCK || errno == EAGAIN {
                throw HistoryStoreError.locked
            }
            throw HistoryStoreError.unsafeStorage
        }

        try verifyArtifactIfPresent(
            primaryName,
            directoryDescriptor: directoryDescriptor,
            hooks: hooks
        )
        try verifyArtifactIfPresent(
            tempName,
            directoryDescriptor: directoryDescriptor,
            hooks: hooks
        )
        try verifyArtifactIfPresent(
            backupName,
            directoryDescriptor: directoryDescriptor,
            hooks: hooks
        )
        try verifyArtifactIfPresent(
            journalName,
            directoryDescriptor: directoryDescriptor,
            hooks: hooks
        )
        try verifyArtifactIfPresent(
            commitName,
            directoryDescriptor: directoryDescriptor,
            hooks: hooks
        )

        try resolveTransactionArtifacts(
            directoryDescriptor: directoryDescriptor,
            hooks: hooks,
            startup: true
        )

        let loaded: HistoryEnvelope
        if try artifactExists(primaryName, directoryDescriptor: directoryDescriptor) {
            let bytes = try readArtifact(
                primaryName,
                directoryDescriptor: directoryDescriptor,
                hooks: hooks
            )
            let decoded = try decodeEnvelope(bytes)
            var candidate = decoded.envelope
            let shouldPruneTombstones = !candidate.tombstones.isEmpty
            if shouldPruneTombstones {
                candidate.tombstones.removeAll()
            }
            if decoded.requiresMigration || shouldPruneTombstones {
                do {
                    try commit(
                        candidate,
                        directoryDescriptor: directoryDescriptor,
                        hooks: hooks
                    )
                } catch {
                    throw HistoryStoreError.writeFailed
                }
            }
            loaded = candidate
        } else {
            loaded = HistoryEnvelope(
                schemaVersion: 1,
                generation: 0,
                enabled: initialEnabled,
                records: [],
                tombstones: []
            )
        }

        keepDirectory = true
        keepLock = true
        return HistoryBootstrapState(
            directoryDescriptor: directoryDescriptor,
            lockDescriptor: lockDescriptor,
            envelope: loaded
        )
    }

    static func isValidRawRecord(_ record: HistoryRecord) -> Bool {
        isValidRecord(record) && record.outcome == .rawSaved
    }

    static func isValidRecord(_ record: HistoryRecord) -> Bool {
        guard !record.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              record.startedAt.timeIntervalSinceReferenceDate.isFinite else {
            return false
        }
        let nonemptyFinal = record.finalText.map {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if record.source != .raw, nonemptyFinal != true {
            return false
        }

        switch record.outcome {
        case .rawSaved:
            return record.source == .raw
                && record.finalText == nil
                && record.warning == nil
                && record.delivery == nil
        case .finalized:
            return nonemptyFinal == true && record.delivery == nil
        case .delivered:
            return nonemptyFinal == true && record.delivery != nil
        case .cancelled, .failed:
            return record.delivery == nil && nonemptyFinal != false
        }
    }

    static func sorted(_ records: [HistoryRecord]) -> [HistoryRecord] {
        records.sorted { lhs, rhs in
            if lhs.startedAt != rhs.startedAt {
                return lhs.startedAt > rhs.startedAt
            }
            return lhs.sessionID.rawValue.uuidString < rhs.sessionID.rawValue.uuidString
        }
    }

    static func commit(
        _ envelope: HistoryEnvelope,
        directoryDescriptor: Int32,
        hooks: HistoryStoreHooks
    ) throws {
        let bytes: Data
        do {
            let persisted = PersistedEnvelope(
                schemaVersion: 1,
                generation: envelope.generation,
                enabled: envelope.enabled,
                records: sorted(envelope.records),
                tombstones: envelope.tombstones.sorted {
                    $0.rawValue.uuidString < $1.rawValue.uuidString
                }
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            bytes = try encoder.encode(persisted)
        } catch {
            throw TransactionFailure.ordinary
        }
        guard bytes.count <= maximumEnvelopeBytes else {
            throw TransactionFailure.invalidCandidate
        }
        try commitBytes(
            bytes,
            directoryDescriptor: directoryDescriptor,
            hooks: hooks
        )
    }

    private static func openVerifiedDirectory(
        _ directory: URL,
        hooks: HistoryStoreHooks
    ) throws -> Int32 {
        guard directory.isFileURL, directory.path.hasPrefix("/") else {
            throw HistoryStoreError.unsafeStorage
        }

        var metadata = stat()
        if lstat(directory.path, &metadata) != 0 {
            guard errno == ENOENT else {
                throw HistoryStoreError.unsafeStorage
            }
            guard mkdir(directory.path, 0o700) == 0 else {
                throw HistoryStoreError.unsafeStorage
            }
            guard lstat(directory.path, &metadata) == 0 else {
                throw HistoryStoreError.unsafeStorage
            }
        }
        try verifyMetadata(metadata, expectedType: S_IFDIR, expectedMode: 0o700, hooks: hooks)

        let descriptor = open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw HistoryStoreError.unsafeStorage
        }
        do {
            var openedMetadata = stat()
            guard fstat(descriptor, &openedMetadata) == 0 else {
                throw HistoryStoreError.unsafeStorage
            }
            try verifyMetadata(
                openedMetadata,
                expectedType: S_IFDIR,
                expectedMode: 0o700,
                hooks: hooks
            )
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func openVerifiedLock(
        directoryDescriptor: Int32,
        hooks: HistoryStoreHooks
    ) throws -> Int32 {
        let descriptor = openat(
            directoryDescriptor,
            lockName,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw HistoryStoreError.unsafeStorage
        }
        do {
            try verifyFileDescriptor(descriptor, hooks: hooks)
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func verifyArtifactIfPresent(
        _ name: String,
        directoryDescriptor: Int32,
        hooks: HistoryStoreHooks
    ) throws {
        guard try artifactExists(name, directoryDescriptor: directoryDescriptor) else {
            return
        }
        let descriptor = openat(
            directoryDescriptor,
            name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw HistoryStoreError.unsafeStorage
        }
        defer { close(descriptor) }
        try verifyFileDescriptor(descriptor, hooks: hooks)
    }

    private static func verifyFileDescriptor(
        _ descriptor: Int32,
        hooks: HistoryStoreHooks
    ) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw HistoryStoreError.unsafeStorage
        }
        try verifyMetadata(
            metadata,
            expectedType: S_IFREG,
            expectedMode: 0o600,
            hooks: hooks
        )
    }

    private static func verifyMetadata(
        _ metadata: stat,
        expectedType: mode_t,
        expectedMode: mode_t,
        hooks: HistoryStoreHooks
    ) throws {
        guard metadata.st_mode & S_IFMT == expectedType else {
            throw HistoryStoreError.unsafeStorage
        }
        guard metadata.st_mode & 0o777 == expectedMode else {
            throw HistoryStoreError.unsafeStorage
        }
        let observedOwner = hooks.ownerOverride ?? UInt32(metadata.st_uid)
        guard observedOwner == UInt32(getuid()) else {
            throw HistoryStoreError.unsafeStorage
        }
    }

    private static func artifactExists(
        _ name: String,
        directoryDescriptor: Int32
    ) throws -> Bool {
        var metadata = stat()
        if fstatat(directoryDescriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 {
            return true
        }
        if errno == ENOENT {
            return false
        }
        throw HistoryStoreError.unsafeStorage
    }

    private static func readArtifact(
        _ name: String,
        directoryDescriptor: Int32,
        hooks: HistoryStoreHooks
    ) throws -> Data {
        let descriptor = openat(
            directoryDescriptor,
            name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw HistoryStoreError.unsafeStorage
        }
        defer { close(descriptor) }
        try verifyFileDescriptor(descriptor, hooks: hooks)

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_size >= 0,
              metadata.st_size <= maximumEnvelopeBytes else {
            throw HistoryStoreError.corrupt
        }
        var result = Data()
        result.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                guard let baseAddress = bytes.baseAddress else { return -1 }
                return Darwin.read(descriptor, baseAddress, bytes.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw HistoryStoreError.corrupt
            }
            result.append(contentsOf: buffer.prefix(count))
            if result.count > maximumEnvelopeBytes {
                throw HistoryStoreError.corrupt
            }
        }
        return result
    }

    private static func decodeEnvelope(_ bytes: Data) throws -> DecodedEnvelope {
        let root: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                throw HistoryStoreError.corrupt
            }
            root = object
        } catch let error as HistoryStoreError {
            throw error
        } catch {
            throw HistoryStoreError.corrupt
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let probe: SchemaProbe
        do {
            probe = try decoder.decode(SchemaProbe.self, from: bytes)
        } catch {
            throw HistoryStoreError.corrupt
        }

        let envelope: HistoryEnvelope
        let migration: Bool
        switch probe.schemaVersion {
        case 0:
            do {
                guard Set(root.keys) == ["schemaVersion", "generation", "enabled", "records"] else {
                    throw HistoryStoreError.corrupt
                }
                let legacy = try decoder.decode(SchemaZeroEnvelope.self, from: bytes)
                guard try hasCanonicalElements(
                    root["records"],
                    matching: legacy.records
                ) else {
                    throw HistoryStoreError.corrupt
                }
                envelope = HistoryEnvelope(
                    schemaVersion: 1,
                    generation: legacy.generation,
                    enabled: legacy.enabled,
                    records: sorted(legacy.records),
                    tombstones: []
                )
                migration = true
            } catch let error as HistoryStoreError {
                throw error
            } catch {
                throw HistoryStoreError.corrupt
            }
        case 1:
            do {
                guard Set(root.keys) == [
                    "schemaVersion", "generation", "enabled", "records", "tombstones"
                ] else {
                    throw HistoryStoreError.corrupt
                }
                let current = try decoder.decode(SchemaOneEnvelope.self, from: bytes)
                guard try hasCanonicalElements(
                    root["records"],
                    matching: current.records
                ),
                try hasCanonicalElements(
                    root["tombstones"],
                    matching: current.tombstones
                ),
                Set(current.tombstones).count == current.tombstones.count else {
                    throw HistoryStoreError.corrupt
                }
                envelope = HistoryEnvelope(
                    schemaVersion: 1,
                    generation: current.generation,
                    enabled: current.enabled,
                    records: sorted(current.records),
                    tombstones: Set(current.tombstones)
                )
                migration = false
            } catch let error as HistoryStoreError {
                throw error
            } catch {
                throw HistoryStoreError.corrupt
            }
        default:
            throw HistoryStoreError.unsupportedSchema
        }
        try validateDecodedEnvelope(envelope)
        return DecodedEnvelope(envelope: envelope, requiresMigration: migration)
    }

    private static func hasCanonicalElements<Value: Encodable>(
        _ rawValue: Any?,
        matching values: [Value]
    ) throws -> Bool {
        guard let rawElements = rawValue as? [Any], rawElements.count == values.count else {
            return false
        }
        return try zip(rawElements, values).allSatisfy { raw, value in
            try isCanonicalJSON(raw, matching: value)
        }
    }

    private static func isCanonicalJSON<Value: Encodable>(
        _ rawValue: Any,
        matching value: Value
    ) throws -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(value)
        let canonicalObject = try JSONSerialization.jsonObject(with: encoded)
        let rawBytes = try JSONSerialization.data(
            withJSONObject: rawValue,
            options: [.sortedKeys, .fragmentsAllowed]
        )
        let canonicalBytes = try JSONSerialization.data(
            withJSONObject: canonicalObject,
            options: [.sortedKeys, .fragmentsAllowed]
        )
        return rawBytes == canonicalBytes
    }

    private static func validateDecodedEnvelope(_ envelope: HistoryEnvelope) throws {
        guard envelope.schemaVersion == 1,
              envelope.records.count <= 20 else {
            throw HistoryStoreError.corrupt
        }
        var identifiers: Set<SessionID> = []
        for record in envelope.records {
            guard isValidRecord(record),
                  identifiers.insert(record.sessionID).inserted,
                  !envelope.tombstones.contains(record.sessionID) else {
                throw HistoryStoreError.corrupt
            }
        }
    }

    private static func resolveTransactionArtifacts(
        directoryDescriptor: Int32,
        hooks: HistoryStoreHooks,
        startup: Bool
    ) throws {
        do {
            try resolveTransactionArtifactsUnchecked(
                directoryDescriptor: directoryDescriptor,
                hooks: hooks
            )
        } catch let error as HistoryStoreError {
            throw error
        } catch {
            if startup {
                throw HistoryStoreError.writeFailed
            }
            throw TransactionFailure.unrecoverable
        }
    }

    private static func resolveTransactionArtifactsUnchecked(
        directoryDescriptor: Int32,
        hooks: HistoryStoreHooks
    ) throws {
        let hasJournal = try artifactExists(
            journalName,
            directoryDescriptor: directoryDescriptor
        )
        let hasCommit = try artifactExists(
            commitName,
            directoryDescriptor: directoryDescriptor
        )
        let hasBackup = try artifactExists(
            backupName,
            directoryDescriptor: directoryDescriptor
        )
        let hasTemp = try artifactExists(
            tempName,
            directoryDescriptor: directoryDescriptor
        )

        guard hasJournal || hasCommit else {
            guard !hasBackup, !hasTemp else {
                throw HistoryStoreError.corrupt
            }
            return
        }

        let commitBytes = hasCommit
            ? try readArtifact(
                commitName,
                directoryDescriptor: directoryDescriptor,
                hooks: hooks
            )
            : Data()
        let validCommit = commitBytes.isEmpty ? nil : try? decodeCommitRecord(commitBytes)

        if let commit = validCommit {
            if hasJournal {
                let manifest = try decodeManifest(
                    readArtifact(
                        journalName,
                        directoryDescriptor: directoryDescriptor,
                        hooks: hooks
                    )
                )
                guard manifest.transactionID == commit.transactionID,
                      manifest.candidateSHA256 == commit.candidateSHA256 else {
                    throw HistoryStoreError.corrupt
                }
            }
            guard try artifactExists(
                primaryName,
                directoryDescriptor: directoryDescriptor
            ) else {
                throw HistoryStoreError.corrupt
            }
            let primary = try readArtifact(
                primaryName,
                directoryDescriptor: directoryDescriptor,
                hooks: hooks
            )
            guard sha256(primary) == commit.candidateSHA256 else {
                throw HistoryStoreError.corrupt
            }
            if hasTemp {
                let temp = try readArtifact(
                    tempName,
                    directoryDescriptor: directoryDescriptor,
                    hooks: hooks
                )
                guard sha256(temp) == commit.candidateSHA256 else {
                    throw HistoryStoreError.corrupt
                }
            }
            try cleanupCommittedArtifacts(
                directoryDescriptor: directoryDescriptor,
                hooks: hooks
            )
            return
        }

        guard hasJournal else {
            throw HistoryStoreError.corrupt
        }
        let manifest = try decodeManifest(
            readArtifact(
                journalName,
                directoryDescriptor: directoryDescriptor,
                hooks: hooks
            )
        )
        try resolveArmedTransaction(
            manifest,
            directoryDescriptor: directoryDescriptor,
            hooks: hooks
        )
    }

    private static func resolveArmedTransaction(
        _ manifest: TransactionManifest,
        directoryDescriptor: Int32,
        hooks: HistoryStoreHooks
    ) throws {
        let primary = try readArtifactIfPresent(
            primaryName,
            directoryDescriptor: directoryDescriptor,
            hooks: hooks
        )
        let backup = try readArtifactIfPresent(
            backupName,
            directoryDescriptor: directoryDescriptor,
            hooks: hooks
        )
        let temp = try readArtifactIfPresent(
            tempName,
            directoryDescriptor: directoryDescriptor,
            hooks: hooks
        )

        if let backup {
            guard sha256(backup) == manifest.priorSHA256,
                  manifest.priorExists || backup.isEmpty else {
                throw HistoryStoreError.corrupt
            }
            if manifest.priorExists {
                do {
                    _ = try decodeEnvelope(backup)
                } catch {
                    throw HistoryStoreError.corrupt
                }
            }
        }
        if let temp, sha256(temp) != manifest.candidateSHA256 {
            throw HistoryStoreError.corrupt
        }

        let priorAlreadyRestored: Bool
        if manifest.priorExists {
            priorAlreadyRestored = primary.map(sha256) == manifest.priorSHA256
        } else {
            priorAlreadyRestored = primary == nil
        }

        if !priorAlreadyRestored {
            guard let backup,
                  sha256(backup) == manifest.priorSHA256,
                  manifest.priorExists || backup.isEmpty else {
                throw HistoryStoreError.corrupt
            }
            let primaryIsCandidate = primary.map(sha256) == manifest.candidateSHA256
            let tempIsCandidate = temp.map(sha256) == manifest.candidateSHA256
            guard primaryIsCandidate || tempIsCandidate else {
                throw HistoryStoreError.corrupt
            }
            guard let candidate = tempIsCandidate ? temp : primary else {
                throw HistoryStoreError.corrupt
            }
            try restoreArmedPrior(
                manifest,
                backup: backup,
                candidate: candidate,
                candidateTempExists: tempIsCandidate,
                directoryDescriptor: directoryDescriptor,
                hooks: hooks
            )
        }

        try cleanupRolledBackArtifacts(
            directoryDescriptor: directoryDescriptor,
            hooks: hooks
        )
    }

    private static func restoreArmedPrior(
        _ manifest: TransactionManifest,
        backup: Data,
        candidate: Data,
        candidateTempExists: Bool,
        directoryDescriptor: Int32,
        hooks: HistoryStoreHooks
    ) throws {
        try inject(.rollbackReplace, hooks: hooks)

        if !candidateTempExists {
            let descriptor = openat(
                directoryDescriptor,
                tempName,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
            guard descriptor >= 0 else { throw TransactionFailure.unrecoverable }
            do {
                defer { close(descriptor) }
                try verifyFileDescriptor(descriptor, hooks: hooks)
                try writeAll(candidate, descriptor: descriptor)
                try synchronizeFile(descriptor)
                try synchronizeFile(directoryDescriptor)
            } catch {
                throw TransactionFailure.unrecoverable
            }
        }

        try inject(.rollbackRestore, hooks: hooks)

        if manifest.priorExists {
            let descriptor = openat(
                directoryDescriptor,
                primaryName,
                O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
            guard descriptor >= 0 else { throw TransactionFailure.unrecoverable }
            do {
                defer { close(descriptor) }
                try verifyFileDescriptor(descriptor, hooks: hooks)
                try writeAll(backup, descriptor: descriptor)
                try synchronizeFile(descriptor)
            } catch {
                throw TransactionFailure.unrecoverable
            }
        } else if try artifactExists(
            primaryName,
            directoryDescriptor: directoryDescriptor
        ) {
            guard unlinkat(directoryDescriptor, primaryName, 0) == 0 else {
                throw TransactionFailure.unrecoverable
            }
        }

        try inject(.rollbackSync, hooks: hooks)
        do {
            try synchronizeFile(directoryDescriptor)
        } catch {
            throw TransactionFailure.unrecoverable
        }
    }

    private static func cleanupRolledBackArtifacts(
        directoryDescriptor: Int32,
        hooks: HistoryStoreHooks
    ) throws {
        do {
            try removeArtifactIfPresent(tempName, directoryDescriptor: directoryDescriptor)
            try removeArtifactIfPresent(backupName, directoryDescriptor: directoryDescriptor)
            try removeArtifactIfPresent(commitName, directoryDescriptor: directoryDescriptor)
            try inject(.rollbackCleanupSync, hooks: hooks)
            try synchronizeFile(directoryDescriptor)

            try removeArtifactIfPresent(journalName, directoryDescriptor: directoryDescriptor)
            try synchronizeFile(directoryDescriptor)
        } catch {
            throw TransactionFailure.unrecoverable
        }
    }

    private static func cleanupCommittedArtifacts(
        directoryDescriptor: Int32,
        hooks: HistoryStoreHooks
    ) throws {
        try inject(.cleanupBackup, hooks: hooks)
        try removeArtifactIfPresent(backupName, directoryDescriptor: directoryDescriptor)
        try removeArtifactIfPresent(tempName, directoryDescriptor: directoryDescriptor)

        try inject(.cleanupJournal, hooks: hooks)
        try removeArtifactIfPresent(journalName, directoryDescriptor: directoryDescriptor)

        try inject(.cleanupArmedDirectorySync, hooks: hooks)
        try synchronizeFile(directoryDescriptor)

        try inject(.cleanupCommit, hooks: hooks)
        try removeArtifactIfPresent(commitName, directoryDescriptor: directoryDescriptor)

        try inject(.cleanupFinalDirectorySync, hooks: hooks)
        try synchronizeFile(directoryDescriptor)
    }

    private static func commitBytes(
        _ candidate: Data,
        directoryDescriptor: Int32,
        hooks: HistoryStoreHooks
    ) throws {
        do {
            try resolveTransactionArtifacts(
                directoryDescriptor: directoryDescriptor,
                hooks: hooks,
                startup: false
            )
        } catch {
            throw TransactionFailure.unrecoverable
        }

        let priorExists: Bool
        let priorBytes: Data
        do {
            priorExists = try artifactExists(
                primaryName,
                directoryDescriptor: directoryDescriptor
            )
            priorBytes = priorExists
                ? try readArtifact(
                    primaryName,
                    directoryDescriptor: directoryDescriptor,
                    hooks: hooks
                )
                : Data()
        } catch {
            throw TransactionFailure.ordinary
        }

        let priorHash = sha256(priorBytes)
        let candidateHash = sha256(candidate)
        let transactionID = transactionIdentifier(
            priorExists: priorExists,
            priorSHA256: priorHash,
            candidateSHA256: candidateHash
        )
        let manifest = TransactionManifest(
            formatVersion: 1,
            transactionID: transactionID,
            priorExists: priorExists,
            priorSHA256: priorHash,
            candidateSHA256: candidateHash
        )
        let manifestBytes: Data
        let validCommitBytes: Data
        do {
            manifestBytes = try encodeSorted(manifest)
            validCommitBytes = try encodeCommitRecord(
                transactionID: transactionID,
                candidateSHA256: candidateHash
            )
        } catch {
            throw TransactionFailure.ordinary
        }

        var tempDescriptor: Int32 = -1
        var backupDescriptor: Int32 = -1
        var journalDescriptor: Int32 = -1
        var commitDescriptor: Int32 = -1
        var tempCreated = false
        var backupCreated = false
        var journalCreated = false
        var commitCreated = false
        var armedArtifactsPrepared = false

        defer {
            if tempDescriptor >= 0 { close(tempDescriptor) }
            if backupDescriptor >= 0 { close(backupDescriptor) }
            if journalDescriptor >= 0 { close(journalDescriptor) }
            if commitDescriptor >= 0 { close(commitDescriptor) }
        }

        do {
            try inject(.permission, hooks: hooks)
            try inject(.tempCreate, hooks: hooks)
            tempDescriptor = openat(
                directoryDescriptor,
                tempName,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
            guard tempDescriptor >= 0 else { throw TransactionFailure.ordinary }
            tempCreated = true
            do {
                try verifyFileDescriptor(tempDescriptor, hooks: hooks)
            } catch {
                throw TransactionFailure.ordinary
            }

            try inject(.tempWrite, hooks: hooks)
            try writeAll(candidate, descriptor: tempDescriptor)
            try inject(.tempSync, hooks: hooks)
            try synchronizeFile(tempDescriptor)
            guard close(tempDescriptor) == 0 else { throw TransactionFailure.ordinary }
            tempDescriptor = -1

            try inject(.backupCreate, hooks: hooks)
            backupDescriptor = openat(
                directoryDescriptor,
                backupName,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
            guard backupDescriptor >= 0 else { throw TransactionFailure.ordinary }
            backupCreated = true
            do {
                try verifyFileDescriptor(backupDescriptor, hooks: hooks)
            } catch {
                throw TransactionFailure.ordinary
            }

            try inject(.backupWrite, hooks: hooks)
            if priorExists {
                try writeAll(priorBytes, descriptor: backupDescriptor)
            }
            try inject(.backupSync, hooks: hooks)
            try synchronizeFile(backupDescriptor)
            guard close(backupDescriptor) == 0 else { throw TransactionFailure.ordinary }
            backupDescriptor = -1

            try inject(.journalCreate, hooks: hooks)
            journalDescriptor = openat(
                directoryDescriptor,
                journalName,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
            guard journalDescriptor >= 0 else { throw TransactionFailure.ordinary }
            journalCreated = true
            do {
                try verifyFileDescriptor(journalDescriptor, hooks: hooks)
            } catch {
                throw TransactionFailure.ordinary
            }
            try inject(.journalWrite, hooks: hooks)
            try writeAll(manifestBytes, descriptor: journalDescriptor)
            try inject(.journalSync, hooks: hooks)
            try synchronizeFile(journalDescriptor)
            guard close(journalDescriptor) == 0 else { throw TransactionFailure.ordinary }
            journalDescriptor = -1

            try inject(.commitRecordCreate, hooks: hooks)
            commitDescriptor = openat(
                directoryDescriptor,
                commitName,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
            guard commitDescriptor >= 0 else { throw TransactionFailure.ordinary }
            commitCreated = true
            do {
                try verifyFileDescriptor(commitDescriptor, hooks: hooks)
            } catch {
                throw TransactionFailure.ordinary
            }
            try inject(.commitRecordPrepareSync, hooks: hooks)
            try synchronizeFile(commitDescriptor)
            armedArtifactsPrepared = true

            try inject(.armedDirectorySync, hooks: hooks)
            try synchronizeFile(directoryDescriptor)

            try inject(.replace, hooks: hooks)
            try inject(.primaryReplace, hooks: hooks)
            guard renameat(
                directoryDescriptor,
                tempName,
                directoryDescriptor,
                primaryName
            ) == 0 else {
                throw TransactionFailure.ordinary
            }
            tempCreated = false

            try inject(.parentSyncAfterReplace, hooks: hooks)
            try inject(.primarySync, hooks: hooks)
            try synchronizeFile(directoryDescriptor)

            try inject(.commitRecordPublish, hooks: hooks)
            try publishCommitRecord(
                validCommitBytes,
                descriptor: commitDescriptor
            )

            try? cleanupCommittedArtifacts(
                directoryDescriptor: directoryDescriptor,
                hooks: hooks
            )
        } catch {
            if tempDescriptor >= 0 {
                close(tempDescriptor)
                tempDescriptor = -1
            }
            if backupDescriptor >= 0 {
                close(backupDescriptor)
                backupDescriptor = -1
            }
            if journalDescriptor >= 0 {
                close(journalDescriptor)
                journalDescriptor = -1
            }
            if commitDescriptor >= 0 {
                close(commitDescriptor)
                commitDescriptor = -1
            }

            if armedArtifactsPrepared {
                do {
                    try resolveTransactionArtifacts(
                        directoryDescriptor: directoryDescriptor,
                        hooks: hooks,
                        startup: false
                    )
                    throw TransactionFailure.ordinary
                } catch TransactionFailure.ordinary {
                    throw TransactionFailure.ordinary
                } catch {
                    throw TransactionFailure.unrecoverable
                }
            }

            do {
                if tempCreated {
                    try removeArtifactIfPresent(
                        tempName,
                        directoryDescriptor: directoryDescriptor
                    )
                }
                if backupCreated {
                    try removeArtifactIfPresent(
                        backupName,
                        directoryDescriptor: directoryDescriptor
                    )
                }
                if journalCreated {
                    try removeArtifactIfPresent(
                        journalName,
                        directoryDescriptor: directoryDescriptor
                    )
                }
                if commitCreated {
                    try removeArtifactIfPresent(
                        commitName,
                        directoryDescriptor: directoryDescriptor
                    )
                }
                try synchronizeFile(directoryDescriptor)
            } catch {
                throw TransactionFailure.unrecoverable
            }
            throw TransactionFailure.ordinary
        }
    }

    private static func readArtifactIfPresent(
        _ name: String,
        directoryDescriptor: Int32,
        hooks: HistoryStoreHooks
    ) throws -> Data? {
        guard try artifactExists(name, directoryDescriptor: directoryDescriptor) else {
            return nil
        }
        return try readArtifact(
            name,
            directoryDescriptor: directoryDescriptor,
            hooks: hooks
        )
    }

    private static func removeArtifactIfPresent(
        _ name: String,
        directoryDescriptor: Int32
    ) throws {
        if unlinkat(directoryDescriptor, name, 0) == 0 || errno == ENOENT {
            return
        }
        throw TransactionFailure.ordinary
    }

    private static func encodeSorted<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func transactionIdentifier(
        priorExists: Bool,
        priorSHA256: String,
        candidateSHA256: String
    ) -> String {
        sha256(Data(
            "history-v1|1|\(priorExists ? 1 : 0)|\(priorSHA256)|\(candidateSHA256)".utf8
        ))
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    private static func decodeManifest(_ bytes: Data) throws -> TransactionManifest {
        do {
            guard let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  Set(root.keys) == [
                    "formatVersion", "transactionID", "priorExists",
                    "priorSHA256", "candidateSHA256"
                  ] else {
                throw HistoryStoreError.corrupt
            }
            let manifest = try JSONDecoder().decode(TransactionManifest.self, from: bytes)
            guard manifest.formatVersion == 1,
                  isSHA256(manifest.transactionID),
                  isSHA256(manifest.priorSHA256),
                  isSHA256(manifest.candidateSHA256),
                  manifest.transactionID == transactionIdentifier(
                    priorExists: manifest.priorExists,
                    priorSHA256: manifest.priorSHA256,
                    candidateSHA256: manifest.candidateSHA256
                  ),
                  manifest.priorExists || manifest.priorSHA256 == sha256(Data()) else {
                throw HistoryStoreError.corrupt
            }
            return manifest
        } catch let error as HistoryStoreError {
            throw error
        } catch {
            throw HistoryStoreError.corrupt
        }
    }

    private static func encodeCommitRecord(
        transactionID: String,
        candidateSHA256: String
    ) throws -> Data {
        let payload = CommitPayload(
            formatVersion: 1,
            transactionID: transactionID,
            candidateSHA256: candidateSHA256
        )
        let checksum = sha256(try encodeSorted(payload))
        return try encodeSorted(CommitRecord(
            formatVersion: 1,
            transactionID: transactionID,
            candidateSHA256: candidateSHA256,
            checksumSHA256: checksum
        ))
    }

    private static func decodeCommitRecord(_ bytes: Data) throws -> CommitRecord {
        do {
            guard let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  Set(root.keys) == [
                    "formatVersion", "transactionID", "candidateSHA256", "checksumSHA256"
                  ] else {
                throw HistoryStoreError.corrupt
            }
            let record = try JSONDecoder().decode(CommitRecord.self, from: bytes)
            guard record.formatVersion == 1,
                  isSHA256(record.transactionID),
                  isSHA256(record.candidateSHA256),
                  isSHA256(record.checksumSHA256) else {
                throw HistoryStoreError.corrupt
            }
            let expected = try encodeCommitRecord(
                transactionID: record.transactionID,
                candidateSHA256: record.candidateSHA256
            )
            let expectedRecord = try JSONDecoder().decode(CommitRecord.self, from: expected)
            guard record.checksumSHA256 == expectedRecord.checksumSHA256 else {
                throw HistoryStoreError.corrupt
            }
            return record
        } catch let error as HistoryStoreError {
            throw error
        } catch {
            throw HistoryStoreError.corrupt
        }
    }

    private static func publishCommitRecord(
        _ bytes: Data,
        descriptor: Int32
    ) throws {
        guard lseek(descriptor, 0, SEEK_SET) == 0,
              ftruncate(descriptor, 0) == 0 else {
            throw TransactionFailure.ordinary
        }
        try writeAll(bytes, descriptor: descriptor)
        try synchronizeFile(descriptor)
    }

    private static func inject(
        _ phase: HistoryWritePhase,
        hooks: HistoryStoreHooks
    ) throws {
        if hooks.consumeFailure(phase) {
            throw TransactionFailure.ordinary
        }
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    bytes.count - written
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw TransactionFailure.ordinary
                }
                if result == 0 {
                    throw TransactionFailure.ordinary
                }
                written += result
            }
        }
    }

    private static func synchronizeFile(_ descriptor: Int32) throws {
        while fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw TransactionFailure.ordinary
        }
    }

}
