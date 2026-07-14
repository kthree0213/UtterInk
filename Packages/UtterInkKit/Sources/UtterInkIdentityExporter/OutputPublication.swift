import Darwin
import Foundation

final class OutputPublication {
    let destination: URL
    let stagingDirectory: URL
    private let removeItem: (URL) throws -> Void
    private enum PublicationState: Equatable {
        case staged
        case publishedFromMissing
        case publishedBySwap
        case cleanupOnly
        case finalized
    }
    private var state: PublicationState = .staged

    init(
        destination: URL,
        removeItem: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) throws {
        self.destination = destination.standardizedFileURL
        self.removeItem = removeItem
        let parent = self.destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Self.requireRealDirectory(parent, label: "output parent")

        switch Self.kind(at: self.destination) {
        case .missing, .directory:
            break
        case .other:
            throw IdentityExporterError.invalidInput("output path must be a real directory")
        }

        stagingDirectory = parent.appendingPathComponent(
            ".\(self.destination.lastPathComponent).utterink-staging-\(UUID().uuidString)",
            isDirectory: true
        )
        guard mkdir(stagingDirectory.path, S_IRWXU) == 0 else {
            throw IdentityExporterError.invalidInput("could not create output staging directory")
        }
    }

    func commit() throws {
        try commitKeepingPrior()
        try finalizeCommit()
    }

    func commitKeepingPrior() throws {
        guard state == .staged else {
            throw IdentityExporterError.invalidInput("identity output publication already used")
        }
        try Self.requireRealDirectory(stagingDirectory, label: "output staging directory")
        switch Self.kind(at: destination) {
        case .missing:
            guard Self.renameExclusive(stagingDirectory, destination) == 0 else {
                throw IdentityExporterError.invalidInput("could not publish identity output")
            }
            state = .publishedFromMissing
        case .directory:
            let result = Self.swap(stagingDirectory, destination)
            guard result == 0 else {
                throw IdentityExporterError.invalidInput("could not replace identity output")
            }
            state = .publishedBySwap
        case .other:
            throw IdentityExporterError.invalidInput("output path changed during publication")
        }
    }

    func finalizeCommit() throws {
        switch state {
        case .publishedFromMissing:
            state = .finalized
        case .publishedBySwap:
            // The new output is already authoritative. Move to a cleanup-only
            // state before a throwing operation so a deferred discard can
            // never swap the prior output back into place.
            state = .cleanupOnly
            do { try finishCleanup() } catch {
                throw IdentityExporterError.invalidInput(
                    "published output but could not remove prior output"
                )
            }
        case .staged, .cleanupOnly, .finalized:
            throw IdentityExporterError.invalidInput("identity output is not awaiting finalization")
        }
    }

    func rollbackCommit() throws {
        switch state {
        case .publishedFromMissing:
            guard Self.renameExclusive(destination, stagingDirectory) == 0 else {
                throw IdentityExporterError.invalidInput("could not roll back published identity output")
            }
            // The destination is restored as soon as rename succeeds. From
            // this point onward only staging cleanup may be retried.
            state = .cleanupOnly
            try finishCleanup()
        case .publishedBySwap:
            guard Self.swap(stagingDirectory, destination) == 0 else {
                throw IdentityExporterError.invalidInput("could not roll back replaced identity output")
            }
            // The prior destination is restored as soon as swap succeeds.
            // Record that transition before removal, which can fail.
            state = .cleanupOnly
            try finishCleanup()
        case .staged, .cleanupOnly, .finalized:
            throw IdentityExporterError.invalidInput("identity output is not awaiting rollback")
        }
    }

    func discardIfNeeded() {
        switch state {
        case .staged:
            if Self.kind(at: stagingDirectory) != .missing {
                try? removeItem(stagingDirectory)
            }
        case .publishedFromMissing, .publishedBySwap:
            try? rollbackCommit()
        case .cleanupOnly:
            try? finishCleanup()
        case .finalized:
            break
        }
    }

    private enum PathKind: Equatable {
        case missing
        case directory
        case other
    }

    private static func kind(at url: URL) -> PathKind {
        var info = stat()
        let result = url.path.withCString { Darwin.lstat($0, &info) }
        if result != 0 {
            return errno == ENOENT ? .missing : .other
        }
        return (info.st_mode & S_IFMT) == S_IFDIR ? .directory : .other
    }

    private static func requireRealDirectory(_ url: URL, label: String) throws {
        guard kind(at: url) == .directory else {
            throw IdentityExporterError.invalidInput("\(label) must be a real directory")
        }
    }

    private static func swap(_ first: URL, _ second: URL) -> Int32 {
        first.path.withCString { firstPath in
            second.path.withCString { secondPath in
                renameatx_np(
                    AT_FDCWD,
                    firstPath,
                    AT_FDCWD,
                    secondPath,
                    UInt32(RENAME_SWAP)
                )
            }
        }
    }

    private static func renameExclusive(_ source: URL, _ destination: URL) -> Int32 {
        source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                renameatx_np(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
    }

    private func finishCleanup() throws {
        guard state == .cleanupOnly else {
            throw IdentityExporterError.invalidInput("identity output cleanup is not pending")
        }
        if Self.kind(at: stagingDirectory) != .missing {
            try removeItem(stagingDirectory)
        }
        state = .finalized
    }
}
