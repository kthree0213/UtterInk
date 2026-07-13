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
    func seal(_ url: URL) async throws
    func delete(_ url: URL) async throws
}

/// Owns short-lived CAF files used by a single application process.
///
/// Removal is best-effort cleanup. Normal APFS deletion is not guaranteed
/// secure erasure of the file's former blocks or snapshots.
public actor TransientAudioStore: TransientAudioFileStore {
    private struct RootIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
    }

    private let root: URL
    private let identity: RootIdentity
    private let clock: any AppClock
    private var issuedNames: Set<String> = []
    private var cleanedNames: Set<String> = []

    public init(root: URL, clock: any AppClock) throws {
        guard root.isFileURL, !root.path.isEmpty else {
            throw TransientAudioStoreError.unsafeRoot
        }
        let normalized = root.standardizedFileURL
        let identity = try Self.prepareRoot(normalized)
        self.root = normalized
        self.identity = identity
        self.clock = clock
        do {
            try Self.sweepFiles(in: normalized, protectedNames: [])
        } catch let error as TransientAudioStoreError {
            throw error
        } catch {
            throw TransientAudioStoreError.fileOperation
        }
    }

    public func sweep() async throws {
        try validateRoot()
        do {
            try Self.sweepFiles(in: root, protectedNames: issuedNames)
        } catch let error as TransientAudioStoreError {
            throw error
        } catch {
            throw TransientAudioStoreError.fileOperation
        }
    }

    func makeCaptureFile() async throws -> URL {
        _ = clock.now
        try await sweep()
        try validateRoot()

        for _ in 0..<16 {
            let name = UUID().uuidString.lowercased() + ".caf"
            let url = root.appendingPathComponent(name, isDirectory: false)
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            if descriptor >= 0 {
                defer { _ = close(descriptor) }
                var info = stat()
                guard fstat(descriptor, &info) == 0,
                      Self.isRegular(info),
                      fchmod(descriptor, 0o600) == 0,
                      fstat(descriptor, &info) == 0,
                      (info.st_mode & 0o777) == 0o600 else {
                    _ = unlink(url.path)
                    throw TransientAudioStoreError.fileOperation
                }
                issuedNames.insert(name)
                cleanedNames.remove(name)
                return url
            }
            if errno != EEXIST {
                throw TransientAudioStoreError.fileOperation
            }
        }
        throw TransientAudioStoreError.fileOperation
    }

    func seal(_ url: URL) async throws {
        try validateRoot()
        let name = try ownedName(for: url, allowCleaned: false)
        guard issuedNames.contains(name) else {
            throw TransientAudioStoreError.invalidCapture
        }

        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw TransientAudioStoreError.fileOperation
        }
        defer { _ = close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              Self.isRegular(info),
              fchmod(descriptor, 0o600) == 0,
              fstat(descriptor, &info) == 0,
              Self.isRegular(info),
              (info.st_mode & 0o777) == 0o600 else {
            throw TransientAudioStoreError.fileOperation
        }
    }

    func delete(_ url: URL) async throws {
        try validateRoot()
        let name = try ownedName(for: url, allowCleaned: true)
        if cleanedNames.contains(name) {
            return
        }
        guard issuedNames.contains(name) else {
            throw TransientAudioStoreError.invalidCapture
        }

        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else {
                throw TransientAudioStoreError.fileOperation
            }
            issuedNames.remove(name)
            cleanedNames.insert(name)
            return
        }
        guard Self.isRegular(info) else {
            throw TransientAudioStoreError.invalidCapture
        }
        guard unlink(url.path) == 0 || errno == ENOENT else {
            throw TransientAudioStoreError.fileOperation
        }
        issuedNames.remove(name)
        cleanedNames.insert(name)
    }

    private func validateRoot() throws {
        var info = stat()
        guard lstat(root.path, &info) == 0,
              Self.isDirectory(info),
              RootIdentity(device: info.st_dev, inode: info.st_ino) == identity else {
            throw TransientAudioStoreError.unsafeRoot
        }
        guard chmod(root.path, 0o700) == 0,
              lstat(root.path, &info) == 0,
              Self.isDirectory(info),
              RootIdentity(device: info.st_dev, inode: info.st_ino) == identity,
              (info.st_mode & 0o777) == 0o700 else {
            throw TransientAudioStoreError.unsafeRoot
        }
    }

    private func ownedName(for url: URL, allowCleaned: Bool) throws -> String {
        let normalized = url.standardizedFileURL
        let parent = normalized.deletingLastPathComponent().standardizedFileURL
        let name = normalized.lastPathComponent
        guard parent == root,
              normalized == root.appendingPathComponent(name, isDirectory: false).standardizedFileURL,
              Self.isCanonicalCAFName(name),
              issuedNames.contains(name) || (allowCleaned && cleanedNames.contains(name)) else {
            throw TransientAudioStoreError.invalidCapture
        }
        return name
    }

    private static func prepareRoot(_ root: URL) throws -> RootIdentity {
        var before = stat()
        if lstat(root.path, &before) == 0 {
            guard isDirectory(before) else {
                throw TransientAudioStoreError.unsafeRoot
            }
        } else {
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

        var info = stat()
        guard lstat(root.path, &info) == 0, isDirectory(info) else {
            throw TransientAudioStoreError.unsafeRoot
        }
        guard chmod(root.path, 0o700) == 0,
              lstat(root.path, &info) == 0,
              isDirectory(info),
              (info.st_mode & 0o777) == 0o700 else {
            throw TransientAudioStoreError.rootUnavailable
        }

        do {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableRoot = root
            try mutableRoot.setResourceValues(values)
        } catch let error as TransientAudioStoreError {
            throw error
        } catch {
            throw TransientAudioStoreError.rootUnavailable
        }
        return RootIdentity(device: info.st_dev, inode: info.st_ino)
    }

    private static func sweepFiles(in root: URL, protectedNames: Set<String>) throws {
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            throw TransientAudioStoreError.fileOperation
        }
        for child in children {
            let name = child.lastPathComponent
            guard !protectedNames.contains(name), isCanonicalCAFName(name) else {
                continue
            }
            var info = stat()
            guard lstat(child.path, &info) == 0, isRegular(info) else {
                continue
            }
            guard unlink(child.path) == 0 || errno == ENOENT else {
                throw TransientAudioStoreError.fileOperation
            }
        }
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
