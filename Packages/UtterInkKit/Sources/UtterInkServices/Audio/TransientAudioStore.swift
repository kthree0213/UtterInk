import Darwin
import Foundation
import UtterInkCore

enum TransientAudioStoreError: Error, CustomStringConvertible, Sendable {
    case rootUnavailable
    case unsafeRoot
    case invalidCapture
    case fileOperation

    var description: String {
        switch self {
        case .rootUnavailable:
            return "transient audio storage is unavailable"
        case .unsafeRoot:
            return "transient audio storage failed validation"
        case .invalidCapture:
            return "transient audio capture is invalid"
        case .fileOperation:
            return "transient audio operation failed"
        }
    }
}

protocol TransientAudioFileStore: Sendable {
    func makeCaptureFile() async throws -> URL
    func verifyForRecording(_ url: URL) async throws
    func seal(_ url: URL) async throws
    func delete(_ url: URL) async throws
}

final class TransientAudioStoreTestHooks: @unchecked Sendable {
    private let lock = NSLock()
    private var storedAfterRootPinned: (@Sendable () -> Void)?
    private var storedBeforeQuarantine: (@Sendable (String) -> Void)?
    private var storedForcedDirectoryReadErrno: Int32?
    private var storedForcedQuarantinedEntryStatErrno: (@Sendable (String) -> Int32?)?
    private var storedForcedQuarantinedEntryUnlinkErrno: (@Sendable (String) -> Int32?)?

    var afterRootPinned: (@Sendable () -> Void)? {
        get { lock.withLock { storedAfterRootPinned } }
        set { lock.withLock { storedAfterRootPinned = newValue } }
    }

    var beforeQuarantine: (@Sendable (String) -> Void)? {
        get { lock.withLock { storedBeforeQuarantine } }
        set { lock.withLock { storedBeforeQuarantine = newValue } }
    }

    var forcedDirectoryReadErrno: Int32? {
        get { lock.withLock { storedForcedDirectoryReadErrno } }
        set { lock.withLock { storedForcedDirectoryReadErrno = newValue } }
    }

    /// Injects the result of inspecting an entry only after its exclusive
    /// descriptor-relative move to quarantine.
    var forcedQuarantinedEntryStatErrno: (@Sendable (String) -> Int32?)? {
        get { lock.withLock { storedForcedQuarantinedEntryStatErrno } }
        set { lock.withLock { storedForcedQuarantinedEntryStatErrno = newValue } }
    }

    var forcedQuarantinedEntryUnlinkErrno: (@Sendable (String) -> Int32?)? {
        get { lock.withLock { storedForcedQuarantinedEntryUnlinkErrno } }
        set { lock.withLock { storedForcedQuarantinedEntryUnlinkErrno = newValue } }
    }
}

/// Owns short-lived CAF files used by a single application process.
///
/// Removal is best-effort cleanup. Normal APFS deletion is not guaranteed
/// secure erasure of the file's former blocks or snapshots.
public actor TransientAudioStore: TransientAudioFileStore {
    private struct FileIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
        }

        init?(device: UInt64, inode: UInt64) {
            guard let device = dev_t(exactly: device),
                  let inode = ino_t(exactly: inode) else {
                return nil
            }
            self.device = device
            self.inode = inode
        }
    }

    private enum PendingNamespace: String, Sendable {
        case owned
        case unowned
    }

    private struct PendingEntry: Sendable {
        let name: String
        let namespace: PendingNamespace
        let originalName: String
        let expected: FileIdentity
    }

    private enum PendingOutcome: Sendable {
        case removed
        case missing
        case preserved
    }

    private struct SweepResult: Sendable {
        var cleaned: Set<String> = []
        var compromised: Set<String> = []
    }

    private struct PreparedRoot {
        let descriptor: Int32
        let lockDescriptor: Int32
        let identity: FileIdentity
        let lockIdentity: FileIdentity
        let backupExclusion: Data
    }

    private static let lockName = ".utterink-transient-audio.lock"
    private static let backupExclusionName = "com.apple.metadata:com_apple_backup_excludeItem"

    private let root: URL
    private let rootDescriptor: Int32
    private let lockDescriptor: Int32
    private let identity: FileIdentity
    private let lockIdentity: FileIdentity
    private let backupExclusion: Data
    private let clock: any AppClock
    private let testHooks: TransientAudioStoreTestHooks?
    private var issued: [String: FileIdentity] = [:]
    private var pendingIssued: [String: String] = [:]
    private var cleanedNames: Set<String> = []

    public init(root: URL, clock: any AppClock) throws {
        guard root.isFileURL, !root.path.isEmpty else {
            throw TransientAudioStoreError.unsafeRoot
        }
        let normalized = root.standardizedFileURL
        let prepared = try Self.prepareRoot(normalized, testHooks: nil)
        self.root = normalized
        rootDescriptor = prepared.descriptor
        lockDescriptor = prepared.lockDescriptor
        identity = prepared.identity
        lockIdentity = prepared.lockIdentity
        backupExclusion = prepared.backupExclusion
        self.clock = clock
        testHooks = nil
    }

    init(
        root: URL,
        clock: any AppClock,
        testHooks: TransientAudioStoreTestHooks
    ) throws {
        guard root.isFileURL, !root.path.isEmpty else {
            throw TransientAudioStoreError.unsafeRoot
        }
        let normalized = root.standardizedFileURL
        let prepared = try Self.prepareRoot(normalized, testHooks: testHooks)
        self.root = normalized
        rootDescriptor = prepared.descriptor
        lockDescriptor = prepared.lockDescriptor
        identity = prepared.identity
        lockIdentity = prepared.lockIdentity
        backupExclusion = prepared.backupExclusion
        self.clock = clock
        self.testHooks = testHooks
    }

    deinit {
        _ = flock(lockDescriptor, LOCK_UN)
        _ = close(lockDescriptor)
        _ = flock(rootDescriptor, LOCK_UN)
        _ = close(rootDescriptor)
    }

    public func sweep() async throws {
        try validateMutation(requirePublicRoot: true)
        do {
            let result = try Self.sweepFiles(
                rootDescriptor: rootDescriptor,
                protected: issued,
                testHooks: testHooks
            )
            for name in result.cleaned.union(result.compromised) {
                retireIssued(name)
            }
            try validateMutation(requirePublicRoot: true)
            if !result.compromised.isEmpty {
                throw TransientAudioStoreError.invalidCapture
            }
        } catch let error as TransientAudioStoreError {
            throw error
        } catch {
            throw TransientAudioStoreError.fileOperation
        }
    }

    func makeCaptureFile() async throws -> URL {
        _ = clock.now
        try await sweep()
        try validateMutation(requirePublicRoot: true)

        for _ in 0..<16 {
            let name = UUID().uuidString.lowercased() + ".caf"
            let descriptor = openat(
                rootDescriptor,
                name,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
            if descriptor >= 0 {
                var info = stat()
                let hasIdentity = fstat(descriptor, &info) == 0
                let fileIdentity = hasIdentity ? FileIdentity(info) : nil
                let valid = hasIdentity
                    && Self.isRegular(info)
                    && info.st_nlink == 1
                    && fchmod(descriptor, 0o600) == 0
                    && fstat(descriptor, &info) == 0
                    && Self.isRegular(info)
                    && info.st_nlink == 1
                    && (info.st_mode & 0o777) == 0o600
                _ = close(descriptor)
                guard valid else {
                    try? Self.cleanupUnissuedCapture(
                        name: name,
                        expected: fileIdentity,
                        rootDescriptor: rootDescriptor,
                        testHooks: testHooks
                    )
                    throw TransientAudioStoreError.fileOperation
                }
                let verifiedIdentity = FileIdentity(info)
                do {
                    try validateMutation(requirePublicRoot: true)
                } catch {
                    try? Self.cleanupUnissuedCapture(
                        name: name,
                        expected: verifiedIdentity,
                        rootDescriptor: rootDescriptor,
                        testHooks: testHooks
                    )
                    throw error
                }
                issued[name] = verifiedIdentity
                cleanedNames.remove(name)
                return root.appendingPathComponent(name, isDirectory: false)
            }
            if errno != EEXIST {
                throw TransientAudioStoreError.fileOperation
            }
        }
        throw TransientAudioStoreError.fileOperation
    }

    func verifyForRecording(_ url: URL) async throws {
        try validateMutation(requirePublicRoot: true)
        let (name, expected) = try issuedCapture(for: url)
        var relativeInfo = stat()
        guard fstatat(rootDescriptor, name, &relativeInfo, AT_SYMLINK_NOFOLLOW) == 0,
              Self.isRegular(relativeInfo),
              relativeInfo.st_nlink == 1,
              FileIdentity(relativeInfo) == expected else {
            throw TransientAudioStoreError.invalidCapture
        }

        var publicInfo = stat()
        guard lstat(url.path, &publicInfo) == 0,
              Self.isRegular(publicInfo),
              publicInfo.st_nlink == 1,
              FileIdentity(publicInfo) == expected else {
            throw TransientAudioStoreError.invalidCapture
        }
        try validateMutation(requirePublicRoot: true)
    }

    func seal(_ url: URL) async throws {
        try validateMutation(requirePublicRoot: true)
        let (name, expected) = try issuedCapture(for: url)
        let descriptor = openat(rootDescriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw TransientAudioStoreError.fileOperation
        }
        defer { _ = close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              Self.isRegular(info),
              info.st_nlink == 1,
              FileIdentity(info) == expected,
              fchmod(descriptor, 0o600) == 0,
              fstat(descriptor, &info) == 0,
              Self.isRegular(info),
              info.st_nlink == 1,
              FileIdentity(info) == expected,
              (info.st_mode & 0o777) == 0o600 else {
            throw TransientAudioStoreError.invalidCapture
        }
        try validateMutation(requirePublicRoot: true)
    }

    func delete(_ url: URL) async throws {
        // Cleanup intentionally remains descriptor-relative if the public root was renamed.
        try validateMutation(requirePublicRoot: false)
        let name = try ownedName(for: url, allowCleaned: true)
        if cleanedNames.contains(name) {
            return
        }
        guard let expected = issued[name] else {
            throw TransientAudioStoreError.invalidCapture
        }
        let pending: PendingEntry
        if let existing = pendingIssued[name] {
            guard let parsed = Self.parsePendingName(existing),
                  parsed.namespace == .owned,
                  parsed.originalName == name,
                  parsed.expected == expected else {
                throw TransientAudioStoreError.fileOperation
            }
            pending = parsed
        } else {
            guard let moved = try Self.moveToPending(
                name: name,
                namespace: .owned,
                originalName: name,
                expected: expected,
                rootDescriptor: rootDescriptor,
                testHooks: testHooks
            ) else {
                retireIssued(name)
                return
            }
            pendingIssued[name] = moved.name
            pending = moved
        }

        switch try Self.processPending(
            pending,
            rootDescriptor: rootDescriptor,
            testHooks: testHooks
        ) {
        case .removed, .missing:
            retireIssued(name)
        case .preserved:
            retireIssued(name)
            throw TransientAudioStoreError.invalidCapture
        }
    }

    private func retireIssued(_ name: String) {
        pendingIssued.removeValue(forKey: name)
        issued.removeValue(forKey: name)
        cleanedNames.insert(name)
    }

    private func issuedCapture(for url: URL) throws -> (String, FileIdentity) {
        let name = try ownedName(for: url, allowCleaned: false)
        guard let expected = issued[name] else {
            throw TransientAudioStoreError.invalidCapture
        }
        return (name, expected)
    }

    private func validateMutation(requirePublicRoot: Bool) throws {
        if requirePublicRoot {
            try Self.requirePublicRoot(root, identity: identity)
        }

        var info = stat()
        var lockInfo = stat()
        var namedLockInfo = stat()
        guard fstat(rootDescriptor, &info) == 0,
              Self.isDirectory(info),
              FileIdentity(info) == identity,
              fchmod(rootDescriptor, 0o700) == 0,
              Self.writeXattr(backupExclusion, descriptor: rootDescriptor),
              fstat(lockDescriptor, &lockInfo) == 0,
              Self.isRegular(lockInfo),
              lockInfo.st_nlink == 1,
              FileIdentity(lockInfo) == lockIdentity,
              fchmod(lockDescriptor, 0o600) == 0,
              fstatat(rootDescriptor, Self.lockName, &namedLockInfo, AT_SYMLINK_NOFOLLOW) == 0,
              Self.isRegular(namedLockInfo),
              namedLockInfo.st_nlink == 1,
              FileIdentity(namedLockInfo) == lockIdentity,
              (namedLockInfo.st_mode & 0o777) == 0o600,
              fstat(rootDescriptor, &info) == 0,
              Self.isDirectory(info),
              FileIdentity(info) == identity,
              (info.st_mode & 0o777) == 0o700,
              Self.readXattr(descriptor: rootDescriptor) == backupExclusion else {
            throw TransientAudioStoreError.unsafeRoot
        }

        if requirePublicRoot {
            try Self.requirePublicRoot(root, identity: identity)
        }
    }

    private func ownedName(for url: URL, allowCleaned: Bool) throws -> String {
        let normalized = url.standardizedFileURL
        let parent = normalized.deletingLastPathComponent().standardizedFileURL
        let name = normalized.lastPathComponent
        guard parent == root,
              normalized == root.appendingPathComponent(name, isDirectory: false).standardizedFileURL,
              Self.isCanonicalCAFName(name),
              issued[name] != nil || (allowCleaned && cleanedNames.contains(name)) else {
            throw TransientAudioStoreError.invalidCapture
        }
        return name
    }

    private static func prepareRoot(
        _ root: URL,
        testHooks: TransientAudioStoreTestHooks?
    ) throws -> PreparedRoot {
        try createRootIfNeeded(root)

        let rootDescriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootDescriptor >= 0 else {
            throw TransientAudioStoreError.unsafeRoot
        }
        var shouldCloseRoot = true
        var lockDescriptor: Int32 = -1
        defer {
            if lockDescriptor >= 0 { _ = close(lockDescriptor) }
            if shouldCloseRoot { _ = close(rootDescriptor) }
        }

        var info = stat()
        guard fstat(rootDescriptor, &info) == 0, isDirectory(info) else {
            throw TransientAudioStoreError.unsafeRoot
        }
        let identity = FileIdentity(info)
        try requirePublicRoot(root, identity: identity)
        guard flock(rootDescriptor, LOCK_EX | LOCK_NB) == 0,
              fchmod(rootDescriptor, 0o700) == 0 else {
            throw TransientAudioStoreError.rootUnavailable
        }
        testHooks?.afterRootPinned?()

        let backupExclusion: Data
        do {
            backupExclusion = try backupExclusionValue()
        } catch {
            throw TransientAudioStoreError.rootUnavailable
        }
        guard !backupExclusion.isEmpty,
              writeXattr(backupExclusion, descriptor: rootDescriptor),
              readXattr(descriptor: rootDescriptor) == backupExclusion else {
            throw TransientAudioStoreError.rootUnavailable
        }
        try requirePublicRoot(root, identity: identity)

        lockDescriptor = openat(
            rootDescriptor,
            lockName,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard lockDescriptor >= 0 else {
            throw TransientAudioStoreError.unsafeRoot
        }
        var lockInfo = stat()
        guard fstat(lockDescriptor, &lockInfo) == 0,
              isRegular(lockInfo),
              lockInfo.st_nlink == 1,
              fchmod(lockDescriptor, 0o600) == 0,
              flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw TransientAudioStoreError.unsafeRoot
        }
        guard fstat(lockDescriptor, &lockInfo) == 0 else {
            throw TransientAudioStoreError.unsafeRoot
        }
        let lockIdentity = FileIdentity(lockInfo)

        guard fstat(rootDescriptor, &info) == 0,
              isDirectory(info),
              FileIdentity(info) == identity,
              (info.st_mode & 0o777) == 0o700,
              readXattr(descriptor: rootDescriptor) == backupExclusion else {
            throw TransientAudioStoreError.unsafeRoot
        }
        try requirePublicRoot(root, identity: identity)
        let sweepResult = try sweepFiles(
            rootDescriptor: rootDescriptor,
            protected: [:],
            testHooks: testHooks
        )
        guard sweepResult.compromised.isEmpty else {
            throw TransientAudioStoreError.unsafeRoot
        }
        try requirePublicRoot(root, identity: identity)
        guard fstat(rootDescriptor, &info) == 0,
              isDirectory(info),
              FileIdentity(info) == identity else {
            throw TransientAudioStoreError.unsafeRoot
        }

        shouldCloseRoot = false
        let prepared = PreparedRoot(
            descriptor: rootDescriptor,
            lockDescriptor: lockDescriptor,
            identity: identity,
            lockIdentity: lockIdentity,
            backupExclusion: backupExclusion
        )
        lockDescriptor = -1
        return prepared
    }

    private static func createRootIfNeeded(_ root: URL) throws {
        var before = stat()
        if lstat(root.path, &before) == 0 {
            guard isDirectory(before) else {
                throw TransientAudioStoreError.unsafeRoot
            }
            return
        }
        guard errno == ENOENT else {
            throw TransientAudioStoreError.rootUnavailable
        }
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        } catch {
            throw TransientAudioStoreError.rootUnavailable
        }
    }

    private static func requirePublicRoot(_ root: URL, identity: FileIdentity) throws {
        var info = stat()
        guard lstat(root.path, &info) == 0,
              isDirectory(info),
              FileIdentity(info) == identity else {
            throw TransientAudioStoreError.unsafeRoot
        }
    }

    private static func readXattr(descriptor: Int32) -> Data? {
        let size = fgetxattr(descriptor, backupExclusionName, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        let count = bytes.withUnsafeMutableBytes { buffer in
            fgetxattr(descriptor, backupExclusionName, buffer.baseAddress, buffer.count, 0, 0)
        }
        guard count == size else { return nil }
        return Data(bytes)
    }

    private static func backupExclusionValue() throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: "com.apple.backupd",
            format: .binary,
            options: 0
        )
    }

    private static func writeXattr(_ value: Data, descriptor: Int32) -> Bool {
        value.withUnsafeBytes { bytes in
            fsetxattr(
                descriptor,
                backupExclusionName,
                bytes.baseAddress,
                bytes.count,
                0,
                0
            ) == 0
        }
    }

    private static func sweepFiles(
        rootDescriptor: Int32,
        protected: [String: FileIdentity],
        testHooks: TransientAudioStoreTestHooks?
    ) throws -> SweepResult {
        let enumerationDescriptor = openat(
            rootDescriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard enumerationDescriptor >= 0, let directory = fdopendir(enumerationDescriptor) else {
            if enumerationDescriptor >= 0 { _ = close(enumerationDescriptor) }
            throw TransientAudioStoreError.fileOperation
        }
        defer { _ = closedir(directory) }
        var names: [String] = []

        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                let readError = testHooks?.forcedDirectoryReadErrno ?? errno
                guard readError == 0 else {
                    throw TransientAudioStoreError.fileOperation
                }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }
            names.append(name)
        }

        var result = SweepResult()

        // Recover durable in-progress cleanup before inspecting canonical CAFs.
        // Preserved and malformed pending-like names are intentionally ignored.
        let pendingEntries = names.compactMap(parsePendingName).sorted { $0.name < $1.name }
        for pending in pendingEntries {
            let outcome: PendingOutcome
            if pending.namespace == .owned,
               let protectedIdentity = protected[pending.originalName],
               protectedIdentity != pending.expected {
                outcome = try preservePending(pending.name, rootDescriptor: rootDescriptor)
            } else {
                outcome = try processPending(
                    pending,
                    rootDescriptor: rootDescriptor,
                    testHooks: testHooks
                )
            }

            guard pending.namespace == .owned,
                  protected[pending.originalName] != nil else {
                continue
            }
            switch outcome {
            case .removed, .missing:
                result.cleaned.insert(pending.originalName)
            case .preserved:
                result.compromised.insert(pending.originalName)
            }
        }

        for name in names.sorted() where isCanonicalCAFName(name) {
            var info = stat()
            if fstatat(rootDescriptor, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                guard errno == ENOENT else {
                    throw TransientAudioStoreError.fileOperation
                }
                if protected[name] != nil,
                   !result.cleaned.contains(name),
                   !result.compromised.contains(name) {
                    result.compromised.insert(name)
                }
                continue
            }

            if let expected = protected[name] {
                if isRegular(info), info.st_nlink == 1, FileIdentity(info) == expected {
                    // A live canonical file wins over an unrelated pending entry
                    // that happened to encode the same original name.
                    result.cleaned.remove(name)
                    result.compromised.remove(name)
                    continue
                }
                if let pending = try moveToPending(
                    name: name,
                    namespace: .owned,
                    originalName: name,
                    expected: expected,
                    rootDescriptor: rootDescriptor,
                    testHooks: testHooks
                ) {
                    _ = try processPending(
                        pending,
                        rootDescriptor: rootDescriptor,
                        testHooks: testHooks
                    )
                }
                result.cleaned.remove(name)
                result.compromised.insert(name)
                continue
            }

            let expected = FileIdentity(info)
            guard let pending = try moveToPending(
                name: name,
                namespace: .unowned,
                originalName: name,
                expected: expected,
                rootDescriptor: rootDescriptor,
                testHooks: testHooks
            ) else {
                continue
            }
            _ = try processPending(
                pending,
                rootDescriptor: rootDescriptor,
                testHooks: testHooks
            )
        }
        return result
    }

    private static func cleanupUnissuedCapture(
        name: String,
        expected: FileIdentity?,
        rootDescriptor: Int32,
        testHooks: TransientAudioStoreTestHooks?
    ) throws {
        let recoverableIdentity: FileIdentity
        if let expected {
            recoverableIdentity = expected
        } else {
            var info = stat()
            if fstatat(rootDescriptor, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                guard errno == ENOENT else {
                    throw TransientAudioStoreError.fileOperation
                }
                return
            }
            recoverableIdentity = FileIdentity(info)
        }

        guard let pending = try moveToPending(
            name: name,
            namespace: .unowned,
            originalName: name,
            expected: recoverableIdentity,
            rootDescriptor: rootDescriptor,
            testHooks: testHooks
        ) else {
            return
        }
        _ = try processPending(
            pending,
            rootDescriptor: rootDescriptor,
            testHooks: testHooks
        )
    }

    private static func moveToPending(
        name: String,
        namespace: PendingNamespace,
        originalName: String,
        expected: FileIdentity,
        rootDescriptor: Int32,
        testHooks: TransientAudioStoreTestHooks?
    ) throws -> PendingEntry? {
        testHooks?.beforeQuarantine?(name)
        for _ in 0..<16 {
            let pending = PendingEntry(
                name: pendingName(
                    namespace: namespace,
                    originalName: originalName,
                    expected: expected,
                    nonce: UUID()
                ),
                namespace: namespace,
                originalName: originalName,
                expected: expected
            )
            // macOS 14 has no public unlink-by-fd or inode-CAS unlink. This
            // exclusive descriptor-relative rename is the supported atomic
            // selection boundary; hostile same-UID directory mutation remains
            // outside this slice's trust model.
            if renameatx_np(
                rootDescriptor,
                name,
                rootDescriptor,
                pending.name,
                UInt32(RENAME_EXCL)
            ) == 0 {
                return pending
            }
            switch errno {
            case ENOENT:
                return nil
            case EEXIST:
                continue
            default:
                throw TransientAudioStoreError.fileOperation
            }
        }
        throw TransientAudioStoreError.fileOperation
    }

    private static func processPending(
        _ pending: PendingEntry,
        rootDescriptor: Int32,
        testHooks: TransientAudioStoreTestHooks?
    ) throws -> PendingOutcome {
        if let injected = testHooks?.forcedQuarantinedEntryStatErrno?(pending.originalName),
           injected != 0 {
            throw TransientAudioStoreError.fileOperation
        }

        var info = stat()
        if fstatat(rootDescriptor, pending.name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else {
                throw TransientAudioStoreError.fileOperation
            }
            return .missing
        }
        guard isRegular(info),
              info.st_nlink == 1,
              FileIdentity(info) == pending.expected else {
            return try preservePending(pending.name, rootDescriptor: rootDescriptor)
        }

        if let injected = testHooks?.forcedQuarantinedEntryUnlinkErrno?(pending.originalName),
           injected != 0 {
            throw TransientAudioStoreError.fileOperation
        }
        if unlinkat(rootDescriptor, pending.name, 0) == 0 {
            return .removed
        }
        guard errno == ENOENT else {
            throw TransientAudioStoreError.fileOperation
        }
        return .missing
    }

    private static func preservePending(
        _ pendingName: String,
        rootDescriptor: Int32
    ) throws -> PendingOutcome {
        for _ in 0..<16 {
            let preserved = ".utterink-preserved-v1." + UUID().uuidString.lowercased()
            if renameatx_np(
                rootDescriptor,
                pendingName,
                rootDescriptor,
                preserved,
                UInt32(RENAME_EXCL)
            ) == 0 {
                return .preserved
            }
            switch errno {
            case ENOENT:
                return .missing
            case EEXIST:
                continue
            default:
                throw TransientAudioStoreError.fileOperation
            }
        }
        throw TransientAudioStoreError.fileOperation
    }

    private static func pendingName(
        namespace: PendingNamespace,
        originalName: String,
        expected: FileIdentity,
        nonce: UUID
    ) -> String {
        let basename = String(originalName.dropLast(4))
        return ".utterink-pending-\(namespace.rawValue)-v1.\(basename)."
            + String(UInt64(expected.device), radix: 16) + "."
            + String(UInt64(expected.inode), radix: 16) + "."
            + nonce.uuidString.lowercased()
    }

    private static func parsePendingName(_ name: String) -> PendingEntry? {
        let pieces = name.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 6, pieces[0].isEmpty else { return nil }

        let namespace: PendingNamespace
        switch pieces[1] {
        case "utterink-pending-owned-v1":
            namespace = .owned
        case "utterink-pending-unowned-v1":
            namespace = .unowned
        default:
            return nil
        }

        let originalBase = String(pieces[2])
        guard let originalUUID = UUID(uuidString: originalBase),
              originalBase == originalUUID.uuidString.lowercased() else {
            return nil
        }
        let originalName = originalBase + ".caf"
        guard isCanonicalCAFName(originalName) else { return nil }

        let deviceText = String(pieces[3])
        let inodeText = String(pieces[4])
        guard let device = UInt64(deviceText, radix: 16),
              let inode = UInt64(inodeText, radix: 16),
              deviceText == String(device, radix: 16),
              inodeText == String(inode, radix: 16),
              let expected = FileIdentity(device: device, inode: inode) else {
            return nil
        }

        let nonceText = String(pieces[5])
        guard let nonce = UUID(uuidString: nonceText),
              nonceText == nonce.uuidString.lowercased() else {
            return nil
        }
        return PendingEntry(
            name: name,
            namespace: namespace,
            originalName: originalName,
            expected: expected
        )
    }

    private static func isCanonicalCAFName(_ name: String) -> Bool {
        guard name.hasSuffix(".caf") else { return false }
        let basename = String(name.dropLast(4))
        guard let uuid = UUID(uuidString: basename) else { return false }
        return basename == uuid.uuidString.lowercased()
    }

    private static func isDirectory(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFDIR
    }

    private static func isRegular(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFREG
    }
}
