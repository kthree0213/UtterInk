import Darwin
import Foundation
import XCTest
import UtterInkCore
@testable import UtterInkServices

final class TransientAudioStoreTests: XCTestCase {
    func testCreatesPrivateExcludedRootAndPrivateCanonicalCapture() async throws {
        let parent = temporaryAudioDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("TransientAudio", isDirectory: true)

        let store = try TransientAudioStore(root: root, clock: AudioTestClock())
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey])
        XCTAssertEqual(rootValues.isDirectory, true)
        XCTAssertGreaterThan(
            getxattr(root.path, "com.apple.metadata:com_apple_backup_excludeItem", nil, 0, 0, 0),
            0
        )
        XCTAssertEqual(try posixMode(root), 0o700)

        let url = try await store.makeCaptureFile()
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)
        XCTAssertEqual(url.pathExtension, "caf")
        XCTAssertEqual(UUID(uuidString: url.deletingPathExtension().lastPathComponent)?.uuidString.lowercased(),
                       url.deletingPathExtension().lastPathComponent)
        XCTAssertEqual(try posixMode(url), 0o600)
        XCTAssertEqual(try Data(contentsOf: url), Data())
    }

    func testLaunchManualAndPreCaptureSweepDeleteOnlyUnownedCanonicalRegularCAFs() async throws {
        let parent = temporaryAudioDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("TransientAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let staleAtLaunch = root.appendingPathComponent("11111111-1111-4111-8111-111111111111.caf")
        try Data([1]).write(to: staleAtLaunch)
        let unrelated = root.appendingPathComponent("recording.caf")
        try Data([2]).write(to: unrelated)
        let uppercaseSuffix = root.appendingPathComponent("22222222-2222-4222-8222-222222222222.CAF")
        try Data([3]).write(to: uppercaseSuffix)
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let nestedCAF = nested.appendingPathComponent("33333333-3333-4333-8333-333333333333.caf")
        try Data([4]).write(to: nestedCAF)
        let outside = parent.appendingPathComponent("outside.caf")
        try Data([5]).write(to: outside)
        let link = root.appendingPathComponent("44444444-4444-4444-8444-444444444444.caf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let store = try TransientAudioStore(root: root, clock: AudioTestClock())
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleAtLaunch.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: uppercaseSuffix.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedCAF.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
        XCTAssertEqual(try Data(contentsOf: outside), Data([5]))

        let owned = try await store.makeCaptureFile()
        let staleBeforeManual = root.appendingPathComponent("55555555-5555-4555-8555-555555555555.caf")
        try Data([6]).write(to: staleBeforeManual)
        try await store.sweep()
        XCTAssertTrue(FileManager.default.fileExists(atPath: owned.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleBeforeManual.path))

        let staleBeforeCapture = root.appendingPathComponent("66666666-6666-4666-8666-666666666666.caf")
        try Data([7]).write(to: staleBeforeCapture)
        let second = try await store.makeCaptureFile()
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleBeforeCapture.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: owned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testSealRepairsModeAndDeleteIsOwnedAndIdempotent() async throws {
        let parent = temporaryAudioDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("TransientAudio", isDirectory: true)
        let store = try TransientAudioStore(root: root, clock: AudioTestClock())
        let url = try await store.makeCaptureFile()
        XCTAssertEqual(chmod(url.path, 0o644), 0)

        try await store.seal(url)
        XCTAssertEqual(try posixMode(url), 0o600)
        try await store.sweep()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        try await store.delete(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try await store.delete(url)
    }

    func testMutationRepairsRootModeDrift() async throws {
        let parent = temporaryAudioDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("TransientAudio", isDirectory: true)
        let store = try TransientAudioStore(root: root, clock: AudioTestClock())
        XCTAssertEqual(chmod(root.path, 0o777), 0)

        let url = try await store.makeCaptureFile()

        XCTAssertEqual(try posixMode(root), 0o700)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testRejectsUnsafeRootsReplacementAndNonOwnedURLsWithSanitizedErrors() async throws {
        let parent = temporaryAudioDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        XCTAssertThrowsError(
            try TransientAudioStore(
                root: URL(string: "https://invalid.example/path-canary")!,
                clock: AudioTestClock()
            )
        ) {
            assertSanitized($0, canaries: ["invalid.example", "path-canary"])
        }
        XCTAssertThrowsError(
            try TransientAudioStore(root: URL(string: "file:")!, clock: AudioTestClock())
        ) {
            assertSanitized($0, canaries: ["file:"])
        }
        let target = parent.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let rootLink = parent.appendingPathComponent("root-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: target)
        XCTAssertThrowsError(try TransientAudioStore(root: rootLink, clock: AudioTestClock())) {
            assertSanitized($0, canaries: [parent.lastPathComponent, "root-link", "real"])
        }

        let fileRoot = parent.appendingPathComponent("not-a-directory")
        try Data().write(to: fileRoot)
        XCTAssertThrowsError(try TransientAudioStore(root: fileRoot, clock: AudioTestClock())) {
            assertSanitized($0, canaries: [parent.lastPathComponent, "not-a-directory"])
        }

        let root = parent.appendingPathComponent("TransientAudio", isDirectory: true)
        let store = try TransientAudioStore(root: root, clock: AudioTestClock())
        let issued = try await store.makeCaptureFile()
        let outside = parent.appendingPathComponent("77777777-7777-4777-8777-777777777777.caf")
        try Data([9]).write(to: outside)
        await XCTAssertThrowsAudioStoreError {
            try await store.delete(outside)
        }
        let traversal = root.appendingPathComponent("../77777777-7777-4777-8777-777777777777.caf")
        await XCTAssertThrowsAudioStoreError {
            try await store.delete(traversal)
        }
        XCTAssertEqual(try Data(contentsOf: outside), Data([9]))

        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        await XCTAssertThrowsAudioStoreError {
            try await store.sweep()
        }
        await XCTAssertThrowsAudioStoreError {
            try await store.seal(issued)
        }
    }
}

private struct AudioTestClock: AppClock {
    var now: Date { Date(timeIntervalSince1970: 1_700_000_000) }
    func sleep(for duration: Duration) async throws {}
}

private func temporaryAudioDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("UtterInk-audio-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}

private func posixMode(_ url: URL) throws -> mode_t {
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    return info.st_mode & 0o777
}

private func assertSanitized(
    _ error: Error,
    canaries: [String],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let renderings = [
        String(describing: error),
        String(reflecting: error),
        error.localizedDescription
    ]
    for rendering in renderings {
        for canary in canaries where !canary.isEmpty {
            XCTAssertFalse(
                rendering.contains(canary),
                "Leaked canary: \(rendering)",
                file: file,
                line: line
            )
        }
    }
}

private func XCTAssertThrowsAudioStoreError(
    _ operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected a closed store error", file: file, line: line)
    } catch let error as TransientAudioStoreError {
        assertSanitized(
            error,
            canaries: ["UtterInk-audio-tests", ".caf"],
            file: file,
            line: line
        )
    } catch {
        XCTFail("Escaped non-store error: \(error)", file: file, line: line)
    }
}
