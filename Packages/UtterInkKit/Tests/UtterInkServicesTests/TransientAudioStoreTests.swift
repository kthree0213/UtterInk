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
        let linkIdentity = try fileIdentity(link)

        let store = try TransientAudioStore(root: root, clock: AudioTestClock())
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleAtLaunch.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: uppercaseSuffix.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedCAF.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
        let preservedLink = try XCTUnwrap(try directChild(with: linkIdentity, in: root))
        XCTAssertFalse(isCanonicalCAFNameForTest(preservedLink.lastPathComponent))
        XCTAssertEqual(try symlinkDestination(preservedLink), outside.path)
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

    func testSecondLiveStoreFailsClosedWithoutSweepingFirstStoresCapture() async throws {
        let parent = temporaryAudioDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("TransientAudio", isDirectory: true)
        let first = try TransientAudioStore(root: root, clock: AudioTestClock())
        let active = try await first.makeCaptureFile()
        try Data([0xCA, 0xFE]).write(to: active)

        let lockProbe = Process()
        lockProbe.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        lockProbe.arguments = [
            "-c",
            "import fcntl,os,sys; fd=os.open(sys.argv[1],os.O_RDWR); "
                + "\ntry: fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB); sys.exit(0)"
                + "\nexcept BlockingIOError: sys.exit(73)",
            root.appendingPathComponent(".utterink-transient-audio.lock").path
        ]
        try lockProbe.run()
        lockProbe.waitUntilExit()
        XCTAssertEqual(lockProbe.terminationStatus, 73)

        XCTAssertThrowsError(try TransientAudioStore(root: root, clock: AudioTestClock())) {
            assertSanitized($0, canaries: [root.path, active.lastPathComponent])
        }
        XCTAssertEqual(try Data(contentsOf: active), Data([0xCA, 0xFE]))
        withExtendedLifetime(first) {}
    }

    func testRenamedLockFileCannotLetSecondStoreAcquireOwnershipOrSweepActiveCapture() async throws {
        let parent = temporaryAudioDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("TransientAudio", isDirectory: true)
        let first = try TransientAudioStore(root: root, clock: AudioTestClock())
        let active = try await first.makeCaptureFile()
        try Data([0xAA, 0x55]).write(to: active)

        let lock = root.appendingPathComponent(".utterink-transient-audio.lock")
        let renamedLock = root.appendingPathComponent("renamed-lock")
        XCTAssertEqual(rename(lock.path, renamedLock.path), 0)
        try Data().write(to: lock)
        XCTAssertEqual(chmod(lock.path, 0o600), 0)

        XCTAssertThrowsError(try TransientAudioStore(root: root, clock: AudioTestClock()))
        XCTAssertEqual(try Data(contentsOf: active), Data([0xAA, 0x55]))
        withExtendedLifetime(first) {}
    }

    func testVerifyRejectsRegularAndSymlinkSubstitutionWithoutFollowingTargets() async throws {
        let parent = temporaryAudioDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("TransientAudio", isDirectory: true)
        let store = try TransientAudioStore(root: root, clock: AudioTestClock())

        let regular = try await store.makeCaptureFile()
        let issuedIdentity = try fileIdentity(regular)
        let replacement = root.appendingPathComponent("replacement.tmp")
        try Data().write(to: replacement)
        XCTAssertEqual(chmod(replacement.path, 0o600), 0)
        let replacementIdentity = try fileIdentity(replacement)
        XCTAssertNotEqual(issuedIdentity, replacementIdentity)
        XCTAssertEqual(rename(replacement.path, regular.path), 0)
        XCTAssertEqual(try posixMode(regular), 0o600)
        XCTAssertEqual(try Data(contentsOf: regular).count, 0)
        await XCTAssertThrowsAudioStoreError { try await store.verifyForRecording(regular) }
        XCTAssertEqual(try fileIdentity(regular), replacementIdentity)
        try FileManager.default.removeItem(at: regular)
        try await store.delete(regular)

        let link = try await store.makeCaptureFile()
        let outside = parent.appendingPathComponent("outside-target")
        try Data([0x22]).write(to: outside)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        await XCTAssertThrowsAudioStoreError { try await store.verifyForRecording(link) }
        XCTAssertTrue(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        XCTAssertEqual(try Data(contentsOf: outside), Data([0x22]))
        try FileManager.default.removeItem(at: link)
        try await store.delete(link)
    }

    func testIssuedRegularSubstituteIsQuarantinedRetiredAndSurvivesRelaunch() async throws {
        let parent = temporaryAudioDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("TransientAudio", isDirectory: true)
        let hooks = TransientAudioStoreTestHooks()
        var store: TransientAudioStore? = try TransientAudioStore(
            root: root,
            clock: AudioTestClock(),
            testHooks: hooks
        )
        let issued = try await store!.makeCaptureFile()
        let issuedIdentity = try fileIdentity(issued)
        let substitute = root.appendingPathComponent("same-shape-substitute.tmp")
        try Data().write(to: substitute)
        XCTAssertEqual(chmod(substitute.path, 0o600), 0)
        let substituteIdentity = try fileIdentity(substitute)
        XCTAssertNotEqual(substituteIdentity, issuedIdentity)
        let swap = EntrySwapHook(
            expectedName: issued.lastPathComponent,
            prepared: substitute,
            destination: issued
        )
        hooks.beforeQuarantine = { name in swap.run(for: name) }

        await XCTAssertThrowsAudioStoreError { try await store!.delete(issued) }
        XCTAssertEqual(swap.result, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: issued.path))
        let preserved = try XCTUnwrap(
            try directChild(with: substituteIdentity, in: root)
        )
        XCTAssertFalse(isCanonicalCAFNameForTest(preserved.lastPathComponent))
        XCTAssertEqual(try posixMode(preserved), 0o600)
        XCTAssertEqual(try Data(contentsOf: preserved), Data())
        try await store!.delete(issued)

        store = nil
        let reopened = try TransientAudioStore(root: root, clock: AudioTestClock())
        XCTAssertEqual(try fileIdentity(preserved), substituteIdentity)
        try await reopened.sweep()
        XCTAssertEqual(try fileIdentity(preserved), substituteIdentity)
    }

    func testIssuedSymlinkSubstituteIsQuarantinedRetiredAndSurvivesRelaunch() async throws {
        let parent = temporaryAudioDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("TransientAudio", isDirectory: true)
        let hooks = TransientAudioStoreTestHooks()
        var store: TransientAudioStore? = try TransientAudioStore(
            root: root,
            clock: AudioTestClock(),
            testHooks: hooks
        )
        let issued = try await store!.makeCaptureFile()
        let outside = parent.appendingPathComponent("outside-marker")
        let marker = Data([0xA5, 0x5A])
        try marker.write(to: outside)
        let substitute = root.appendingPathComponent("symlink-substitute.tmp")
        try FileManager.default.createSymbolicLink(at: substitute, withDestinationURL: outside)
        let substituteIdentity = try fileIdentity(substitute)
        let swap = EntrySwapHook(
            expectedName: issued.lastPathComponent,
            prepared: substitute,
            destination: issued
        )
        hooks.beforeQuarantine = { name in swap.run(for: name) }

        await XCTAssertThrowsAudioStoreError { try await store!.delete(issued) }
        XCTAssertEqual(swap.result, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: issued.path))
        let preserved = try XCTUnwrap(
            try directChild(with: substituteIdentity, in: root)
        )
        XCTAssertFalse(isCanonicalCAFNameForTest(preserved.lastPathComponent))
        XCTAssertEqual(try symlinkDestination(preserved), outside.path)
        XCTAssertEqual(try Data(contentsOf: outside), marker)
        try await store!.delete(issued)

        store = nil
        let reopened = try TransientAudioStore(root: root, clock: AudioTestClock())
        XCTAssertEqual(try fileIdentity(preserved), substituteIdentity)
        try await reopened.sweep()
        XCTAssertEqual(try fileIdentity(preserved), substituteIdentity)
        XCTAssertEqual(try Data(contentsOf: outside), marker)
    }

    func testManualSweepQuarantinesCompromisedIssuedEntryBeforeRelaunch() async throws {
        let parent = temporaryAudioDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("TransientAudio", isDirectory: true)
        var store: TransientAudioStore? = try TransientAudioStore(
            root: root,
            clock: AudioTestClock()
        )
        let issued = try await store!.makeCaptureFile()
        let originalIdentity = try fileIdentity(issued)
        let substitute = root.appendingPathComponent("sweep-substitute.tmp")
        try Data().write(to: substitute)
        XCTAssertEqual(chmod(substitute.path, 0o600), 0)
        let substituteIdentity = try fileIdentity(substitute)
        XCTAssertNotEqual(originalIdentity, substituteIdentity)
        XCTAssertEqual(rename(substitute.path, issued.path), 0)

        await XCTAssertThrowsAudioStoreError { try await store!.sweep() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: issued.path))
        let preserved = try XCTUnwrap(try directChild(with: substituteIdentity, in: root))
        XCTAssertFalse(isCanonicalCAFNameForTest(preserved.lastPathComponent))
        try await store!.delete(issued)

        store = nil
        let reopened = try TransientAudioStore(root: root, clock: AudioTestClock())
        try await reopened.sweep()
        XCTAssertEqual(try fileIdentity(preserved), substituteIdentity)
    }

    func testPinnedRootBackupExclusionSeedNeverMutatesPublicPathReplacement() throws {
        let parent = temporaryAudioDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("TransientAudio", isDirectory: true)
        let moved = parent.appendingPathComponent("PinnedTransientAudio", isDirectory: true)
        let replacementCanary = Data("replacement-xattr-canary".utf8)
        let hook = PinnedRootReplacementHook(
            root: root,
            moved: moved,
            replacementCanary: replacementCanary
        )
        let hooks = TransientAudioStoreTestHooks()
        hooks.afterRootPinned = { hook.run() }

        XCTAssertThrowsError(
            try TransientAudioStore(
                root: root,
                clock: AudioTestClock(),
                testHooks: hooks
            )
        ) {
            assertSanitized($0, canaries: [root.path, moved.path])
        }

        XCTAssertNil(hook.error)
        XCTAssertEqual(try backupExclusionXattr(root), replacementCanary)
        XCTAssertEqual(try backupExclusionXattr(moved), try expectedBackupExclusionXattr())
    }

    func testEnumerationFailsClosedOnReadAndUnexpectedStatErrorsButAcceptsCleanEOFAndENOENT() async throws {
        let parent = temporaryAudioDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("TransientAudio", isDirectory: true)
        let hooks = TransientAudioStoreTestHooks()
        let store = try TransientAudioStore(
            root: root,
            clock: AudioTestClock(),
            testHooks: hooks
        )

        hooks.forcedDirectoryReadErrno = EIO
        await XCTAssertThrowsAudioStoreError { try await store.sweep() }
        hooks.forcedDirectoryReadErrno = nil
        try await store.sweep()

        let statFailure = root.appendingPathComponent("99999999-9999-4999-8999-999999999999.caf")
        try Data([0x42]).write(to: statFailure)
        let statFailureIdentity = try fileIdentity(statFailure)
        hooks.forcedQuarantinedEntryStatErrno = { name in
            name == statFailure.lastPathComponent ? EIO : nil
        }
        await XCTAssertThrowsAudioStoreError { try await store.sweep() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: statFailure.path))
        let preservedStatFailure = try XCTUnwrap(
            try directChild(with: statFailureIdentity, in: root)
        )
        XCTAssertFalse(isCanonicalCAFNameForTest(preservedStatFailure.lastPathComponent))
        XCTAssertEqual(try Data(contentsOf: preservedStatFailure), Data([0x42]))

        let disappeared = root.appendingPathComponent("88888888-8888-4888-8888-888888888888.caf")
        try Data([0x24]).write(to: disappeared)
        let disappearedIdentity = try fileIdentity(disappeared)
        hooks.forcedQuarantinedEntryStatErrno = { name in
            name == disappeared.lastPathComponent ? ENOENT : nil
        }
        try await store.sweep()
        XCTAssertFalse(FileManager.default.fileExists(atPath: disappeared.path))
        let preservedDisappeared = try XCTUnwrap(
            try directChild(with: disappearedIdentity, in: root)
        )
        XCTAssertFalse(isCanonicalCAFNameForTest(preservedDisappeared.lastPathComponent))
        XCTAssertEqual(try Data(contentsOf: preservedDisappeared), Data([0x24]))

        hooks.forcedQuarantinedEntryStatErrno = nil
        let stale = root.appendingPathComponent("77777777-7777-4777-8777-777777777777.caf")
        try Data([0x66]).write(to: stale)
        try await store.sweep()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    func testRootRenameAndReplacementFailClosedButDescriptorRelativeCleanupStillWorks() async throws {
        let parent = temporaryAudioDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("TransientAudio", isDirectory: true)
        let moved = parent.appendingPathComponent("PinnedTransientAudio", isDirectory: true)
        let store = try TransientAudioStore(root: root, clock: AudioTestClock())
        let issued = try await store.makeCaptureFile()
        let name = issued.lastPathComponent

        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try setBackupExclusionXattr(try backupExclusionXattr(moved), on: root)
        let replacementLock = root.appendingPathComponent(".utterink-transient-audio.lock")
        try Data().write(to: replacementLock)
        XCTAssertEqual(chmod(replacementLock.path, 0o600), 0)
        let replacement = root.appendingPathComponent(name)
        try Data([0x33]).write(to: replacement)

        await XCTAssertThrowsAudioStoreError { try await store.sweep() }
        await XCTAssertThrowsAudioStoreError { _ = try await store.makeCaptureFile() }
        await XCTAssertThrowsAudioStoreError { try await store.seal(issued) }

        try await store.delete(issued)
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.appendingPathComponent(name).path))
        XCTAssertEqual(try Data(contentsOf: replacement), Data([0x33]))
    }

    func testEveryMutationRepairsPinnedRootModeAndExactBackupExclusionXattr() async throws {
        let parent = temporaryAudioDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("TransientAudio", isDirectory: true)
        let store = try TransientAudioStore(root: root, clock: AudioTestClock())
        let expectedXattr = try backupExclusionXattr(root)
        XCTAssertFalse(expectedXattr.isEmpty)

        let first = try await store.makeCaptureFile()

        try driftRoot(root)
        try await store.sweep()
        try assertRepairedRoot(root, expectedXattr: expectedXattr)

        try driftRoot(root)
        let second = try await store.makeCaptureFile()
        try assertRepairedRoot(root, expectedXattr: expectedXattr)

        try driftRoot(root)
        try await store.verifyForRecording(first)
        try assertRepairedRoot(root, expectedXattr: expectedXattr)

        try driftRoot(root)
        try await store.seal(first)
        try assertRepairedRoot(root, expectedXattr: expectedXattr)

        try driftRoot(root)
        try await store.delete(first)
        try assertRepairedRoot(root, expectedXattr: expectedXattr)

        try await store.delete(second)
    }
}

private struct TestFileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
}

private final class EntrySwapHook: @unchecked Sendable {
    private let lock = NSLock()
    private let expectedName: String
    private let prepared: URL
    private let destination: URL
    private var storedResult: Int32?

    init(expectedName: String, prepared: URL, destination: URL) {
        self.expectedName = expectedName
        self.prepared = prepared
        self.destination = destination
    }

    var result: Int32? { lock.withLock { storedResult } }

    func run(for name: String) {
        lock.withLock {
            guard name == expectedName, storedResult == nil else { return }
            let status = rename(prepared.path, destination.path)
            storedResult = status == 0 ? 0 : errno
        }
    }
}

private final class PinnedRootReplacementHook: @unchecked Sendable {
    private let lock = NSLock()
    private let root: URL
    private let moved: URL
    private let replacementCanary: Data
    private var storedError: Error?
    private var ran = false

    init(root: URL, moved: URL, replacementCanary: Data) {
        self.root = root
        self.moved = moved
        self.replacementCanary = replacementCanary
    }

    var error: Error? { lock.withLock { storedError } }

    func run() {
        lock.withLock {
            guard !ran else { return }
            ran = true
            do {
                try FileManager.default.moveItem(at: root, to: moved)
                try FileManager.default.createDirectory(
                    at: root,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: NSNumber(value: 0o700)]
                )
                try setBackupExclusionXattr(replacementCanary, on: root)
            } catch {
                storedError = error
            }
        }
    }
}

private func fileIdentity(_ url: URL) throws -> TestFileIdentity {
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    return TestFileIdentity(device: info.st_dev, inode: info.st_ino)
}

private func directChild(
    with identity: TestFileIdentity,
    in root: URL
) throws -> URL? {
    try FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil,
        options: []
    ).first { try fileIdentity($0) == identity }
}

private func symlinkDestination(_ url: URL) throws -> String {
    try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
}

private func isCanonicalCAFNameForTest(_ name: String) -> Bool {
    guard name.hasSuffix(".caf") else { return false }
    let basename = String(name.dropLast(4))
    guard let uuid = UUID(uuidString: basename) else { return false }
    return basename == uuid.uuidString.lowercased()
}

private func driftRoot(_ root: URL) throws {
    guard chmod(root.path, 0o777) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    try setBackupExclusionXattr(Data("drift-canary".utf8), on: root)
}

private func assertRepairedRoot(_ root: URL, expectedXattr: Data) throws {
    XCTAssertEqual(try posixMode(root), 0o700)
    XCTAssertEqual(try backupExclusionXattr(root), expectedXattr)
}

private func setBackupExclusionXattr(_ data: Data, on url: URL) throws {
    let result = data.withUnsafeBytes { bytes in
        setxattr(
            url.path,
            "com.apple.metadata:com_apple_backup_excludeItem",
            bytes.baseAddress,
            bytes.count,
            0,
            0
        )
    }
    guard result == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
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

private func backupExclusionXattr(_ url: URL) throws -> Data {
    let name = "com.apple.metadata:com_apple_backup_excludeItem"
    let size = getxattr(url.path, name, nil, 0, 0, 0)
    guard size > 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    var bytes = [UInt8](repeating: 0, count: size)
    let read = bytes.withUnsafeMutableBytes { buffer in
        getxattr(url.path, name, buffer.baseAddress, buffer.count, 0, 0)
    }
    guard read == size else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    return Data(bytes)
}

private func expectedBackupExclusionXattr() throws -> Data {
    try PropertyListSerialization.data(
        fromPropertyList: "com.apple.backupd",
        format: .binary,
        options: 0
    )
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
