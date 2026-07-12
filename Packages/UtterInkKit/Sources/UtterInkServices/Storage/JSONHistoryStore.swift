import Darwin
import Foundation
import UtterInkCore

enum HistoryStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case corrupt
    case dirty
    case disabled
    case duplicateSession
    case generationOverflow
    case invalidRecord
    case locked
    case missingRecord
    case poisoned
    case staleGeneration
    case staleOperation
    case tombstoned
    case unsafeStorage
    case unsupportedSchema
    case writeFailed

    var description: String {
        switch self {
        case .corrupt: return "history-store-corrupt"
        case .dirty: return "history-store-dirty"
        case .disabled: return "history-store-disabled"
        case .duplicateSession: return "history-store-duplicate-session"
        case .generationOverflow: return "history-store-generation-overflow"
        case .invalidRecord: return "history-store-invalid-record"
        case .locked: return "history-store-locked"
        case .missingRecord: return "history-store-missing-record"
        case .poisoned: return "history-store-poisoned"
        case .staleGeneration: return "history-store-stale-generation"
        case .staleOperation: return "history-store-stale-operation"
        case .tombstoned: return "history-store-tombstoned"
        case .unsafeStorage: return "history-store-unsafe-storage"
        case .unsupportedSchema: return "history-store-unsupported-schema"
        case .writeFailed: return "history-store-write-failed"
        }
    }
}

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
    case backupRemove
    case finalParentSync
    case rollbackReplace
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
}

private enum HistoryPersistence {
    private static let primaryName = "history-v1.json"
    private static let lockName = "history-v1.lock"
    private static let tempName = "history-v1.tmp"
    private static let backupName = "history-v1.backup"
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

        try recoverInterruptedTransaction(
            directoryDescriptor: directoryDescriptor,
            hooks: hooks
        )
        if try artifactExists(tempName, directoryDescriptor: directoryDescriptor) {
            guard unlinkat(directoryDescriptor, tempName, 0) == 0 else {
                throw HistoryStoreError.writeFailed
            }
            try synchronizeDirectory(directoryDescriptor, as: HistoryStoreError.writeFailed)
        }

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
        !record.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && record.startedAt.timeIntervalSinceReferenceDate.isFinite
            && record.finalText == nil
            && record.source == .raw
            && record.warning == nil
            && record.delivery == nil
            && record.outcome == .rawSaved
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
                let legacy = try decoder.decode(SchemaZeroEnvelope.self, from: bytes)
                envelope = HistoryEnvelope(
                    schemaVersion: 1,
                    generation: legacy.generation,
                    enabled: legacy.enabled,
                    records: sorted(legacy.records),
                    tombstones: []
                )
                migration = true
            } catch {
                throw HistoryStoreError.corrupt
            }
        case 1:
            do {
                let current = try decoder.decode(HistoryEnvelope.self, from: bytes)
                envelope = HistoryEnvelope(
                    schemaVersion: 1,
                    generation: current.generation,
                    enabled: current.enabled,
                    records: sorted(current.records),
                    tombstones: current.tombstones
                )
                migration = false
            } catch {
                throw HistoryStoreError.corrupt
            }
        default:
            throw HistoryStoreError.unsupportedSchema
        }
        try validateDecodedEnvelope(envelope)
        return DecodedEnvelope(envelope: envelope, requiresMigration: migration)
    }

    private static func validateDecodedEnvelope(_ envelope: HistoryEnvelope) throws {
        guard envelope.schemaVersion == 1,
              envelope.records.count <= 20 else {
            throw HistoryStoreError.corrupt
        }
        var identifiers: Set<SessionID> = []
        for record in envelope.records {
            guard !record.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  record.startedAt.timeIntervalSinceReferenceDate.isFinite,
                  identifiers.insert(record.sessionID).inserted,
                  !envelope.tombstones.contains(record.sessionID) else {
                throw HistoryStoreError.corrupt
            }
        }
    }

    private static func recoverInterruptedTransaction(
        directoryDescriptor: Int32,
        hooks: HistoryStoreHooks
    ) throws {
        guard try artifactExists(backupName, directoryDescriptor: directoryDescriptor) else {
            return
        }
        let backup = try readArtifact(
            backupName,
            directoryDescriptor: directoryDescriptor,
            hooks: hooks
        )
        if backup.isEmpty {
            if try artifactExists(primaryName, directoryDescriptor: directoryDescriptor),
               unlinkat(directoryDescriptor, primaryName, 0) != 0 {
                throw HistoryStoreError.writeFailed
            }
            guard unlinkat(directoryDescriptor, backupName, 0) == 0 else {
                throw HistoryStoreError.writeFailed
            }
            try synchronizeDirectory(directoryDescriptor, as: HistoryStoreError.writeFailed)
            return
        }

        do {
            _ = try decodeEnvelope(backup)
        } catch {
            throw HistoryStoreError.corrupt
        }
        guard renameat(directoryDescriptor, backupName, directoryDescriptor, primaryName) == 0 else {
            throw HistoryStoreError.writeFailed
        }
        try synchronizeDirectory(directoryDescriptor, as: HistoryStoreError.writeFailed)
    }

    private static func commitBytes(
        _ candidate: Data,
        directoryDescriptor: Int32,
        hooks: HistoryStoreHooks
    ) throws {
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

        var tempDescriptor: Int32 = -1
        var backupDescriptor: Int32 = -1
        var tempCreated = false
        var backupCreated = false
        var replaced = false
        var backupRemoved = false

        defer {
            if tempDescriptor >= 0 { close(tempDescriptor) }
            if backupDescriptor >= 0 { close(backupDescriptor) }
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
            try synchronizeFile(directoryDescriptor)

            try inject(.replace, hooks: hooks)
            guard renameat(
                directoryDescriptor,
                tempName,
                directoryDescriptor,
                primaryName
            ) == 0 else {
                throw TransactionFailure.ordinary
            }
            replaced = true
            tempCreated = false

            try inject(.parentSyncAfterReplace, hooks: hooks)
            try synchronizeFile(directoryDescriptor)

            try inject(.backupRemove, hooks: hooks)
            guard unlinkat(directoryDescriptor, backupName, 0) == 0 else {
                throw TransactionFailure.ordinary
            }
            backupRemoved = true
            backupCreated = false

            try inject(.finalParentSync, hooks: hooks)
            try synchronizeFile(directoryDescriptor)
        } catch {
            if replaced {
                if backupRemoved {
                    do {
                        try establishRecoveryBackup(
                            priorBytes: priorBytes,
                            directoryDescriptor: directoryDescriptor,
                            hooks: hooks
                        )
                        backupCreated = true
                        backupRemoved = false
                    } catch {
                        throw TransactionFailure.unrecoverable
                    }
                }
                if hooks.consumeFailure(.rollbackReplace) {
                    throw TransactionFailure.unrecoverable
                }
                do {
                    try rollbackReplacement(
                        priorExists: priorExists,
                        directoryDescriptor: directoryDescriptor
                    )
                    backupCreated = false
                    throw TransactionFailure.ordinary
                } catch TransactionFailure.ordinary {
                    throw TransactionFailure.ordinary
                } catch {
                    throw TransactionFailure.unrecoverable
                }
            }

            if tempDescriptor >= 0 {
                close(tempDescriptor)
                tempDescriptor = -1
            }
            if backupDescriptor >= 0 {
                close(backupDescriptor)
                backupDescriptor = -1
            }
            var cleanupSucceeded = true
            if tempCreated,
               unlinkat(directoryDescriptor, tempName, 0) != 0,
               errno != ENOENT {
                cleanupSucceeded = false
            }
            if backupCreated,
               unlinkat(directoryDescriptor, backupName, 0) != 0,
               errno != ENOENT {
                cleanupSucceeded = false
            }
            if fsync(directoryDescriptor) != 0 {
                cleanupSucceeded = false
            }
            throw cleanupSucceeded
                ? TransactionFailure.ordinary
                : TransactionFailure.unrecoverable
        }
    }

    private static func establishRecoveryBackup(
        priorBytes: Data,
        directoryDescriptor: Int32,
        hooks: HistoryStoreHooks
    ) throws {
        if try artifactExists(backupName, directoryDescriptor: directoryDescriptor) {
            return
        }
        let descriptor = openat(
            directoryDescriptor,
            backupName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw TransactionFailure.unrecoverable }
        defer { close(descriptor) }
        do {
            try verifyFileDescriptor(descriptor, hooks: hooks)
            try writeAll(priorBytes, descriptor: descriptor)
            try synchronizeFile(descriptor)
            try synchronizeFile(directoryDescriptor)
        } catch {
            throw TransactionFailure.unrecoverable
        }
    }

    private static func rollbackReplacement(
        priorExists: Bool,
        directoryDescriptor: Int32
    ) throws {
        if priorExists {
            guard renameat(
                directoryDescriptor,
                backupName,
                directoryDescriptor,
                primaryName
            ) == 0 else {
                throw TransactionFailure.unrecoverable
            }
        } else {
            if try artifactExists(primaryName, directoryDescriptor: directoryDescriptor),
               unlinkat(directoryDescriptor, primaryName, 0) != 0 {
                throw TransactionFailure.unrecoverable
            }
            if try artifactExists(backupName, directoryDescriptor: directoryDescriptor),
               unlinkat(directoryDescriptor, backupName, 0) != 0 {
                throw TransactionFailure.unrecoverable
            }
        }
        try synchronizeFile(directoryDescriptor)
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

    private static func synchronizeDirectory(
        _ descriptor: Int32,
        as error: HistoryStoreError
    ) throws {
        do {
            try synchronizeFile(descriptor)
        } catch {
            throw error
        }
    }
}
