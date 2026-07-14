import Darwin
import Foundation

final class OutputPublication {
    let destination: URL
    let stagingDirectory: URL
    private var committed = false

    init(destination: URL) throws {
        self.destination = destination.standardizedFileURL
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
        try Self.requireRealDirectory(stagingDirectory, label: "output staging directory")
        switch Self.kind(at: destination) {
        case .missing:
            guard Darwin.rename(stagingDirectory.path, destination.path) == 0 else {
                throw IdentityExporterError.invalidInput("could not publish identity output")
            }
        case .directory:
            let result = stagingDirectory.path.withCString { stagingPath in
                destination.path.withCString { destinationPath in
                    renameatx_np(
                        AT_FDCWD,
                        stagingPath,
                        AT_FDCWD,
                        destinationPath,
                        UInt32(RENAME_SWAP)
                    )
                }
            }
            guard result == 0 else {
                throw IdentityExporterError.invalidInput("could not replace identity output")
            }
            do {
                try FileManager.default.removeItem(at: stagingDirectory)
            } catch {
                // The new output is already atomically published. A cleanup
                // failure must be visible rather than reported as full success.
                throw IdentityExporterError.invalidInput("published output but could not remove prior output")
            }
        case .other:
            throw IdentityExporterError.invalidInput("output path changed during publication")
        }
        committed = true
    }

    func discardIfNeeded() {
        guard !committed, Self.kind(at: stagingDirectory) != .missing else { return }
        try? FileManager.default.removeItem(at: stagingDirectory)
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
}
