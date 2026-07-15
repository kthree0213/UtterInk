import Foundation
import XCTest
import UtterInkCore
@testable import UtterInkServices

final class WhisperModelServiceTests: XCTestCase {
    func testPublicConstructionStartsAtBundledDefaultMissingWithoutNetworkWork() async throws {
        let (root, cleanup) = temporaryModelRoot()
        defer { cleanup() }

        let service = try WhisperModelService(
            catalog: .bundled,
            root: root,
            clock: ModelServiceTestClock()
        )

        let state = await service.state()
        XCTAssertEqual(state, .missing(modelID: "small"))
    }

    func testLocalTokenizerValidatesSpecialTokenRoundTripsAndDerivesWhitespaceFromEncoding() throws {
        let backing = LocalTokenizerBackingFake()
        let tokenizer = try LocalWhisperTokenizer(tokenizer: backing)

        XCTAssertEqual(tokenizer.specialTokens.whitespaceToken, 220)
        let tokenizerWithImplicitNoSpeech = try LocalWhisperTokenizer(
            tokenizer: LocalTokenizerBackingFake(missingToken: "<|nospeech|>")
        )
        XCTAssertEqual(tokenizerWithImplicitNoSpeech.specialTokens.noSpeechToken, 50_362)
        XCTAssertThrowsError(
            try LocalWhisperTokenizer(
                tokenizer: LocalTokenizerBackingFake(missingToken: "<|translate|>")
            )
        )
    }

    func testLocalTokenizerRejectsExplicitNoSpeechTokenThatIsNotAdjacentToNoTimestamps() {
        XCTAssertThrowsError(
            try LocalWhisperTokenizer(
                tokenizer: LocalTokenizerBackingFake(noSpeechTokenID: 50_360)
            )
        )
    }

    func testMissingModelDownloadsWithBoundedProgressThenLoadsReady() async throws {
        let backend = ModelBackendFake(progressValues: [-2, 0.25, 2])
        let service = try makeService(backend: backend)
        let token = effectToken(generation: 7)

        let states = await collect(await service.prepare(modelID: "base", token: token))

        XCTAssertEqual(states.first, .missing(modelID: "base"))
        XCTAssertTrue(states.contains(.loading(modelID: "base")))
        XCTAssertEqual(states.last, .ready(modelID: "base"))
        let progress = states.compactMap { state -> Double? in
            guard case let .downloading(modelID, value) = state, modelID == "base" else { return nil }
            return value
        }
        XCTAssertFalse(progress.isEmpty)
        XCTAssertTrue(progress.allSatisfy { (0 ... 1).contains($0) })
        let downloadCount = await backend.downloadCount(for: "base")
        let loadCount = await backend.loadCount(for: "base")
        XCTAssertEqual(downloadCount, 1)
        XCTAssertEqual(loadCount, 1)
    }

    func testCachedModelSkipsDownloadAndLoadsReady() async throws {
        let backend = ModelBackendFake(cachedIDs: ["small"])
        let service = try makeService(backend: backend)

        let states = await collect(
            await service.prepare(modelID: "small", token: effectToken(generation: 1))
        )

        XCTAssertEqual(states, [.loading(modelID: "small"), .ready(modelID: "small")])
        let downloadCount = await backend.downloadCount(for: "small")
        let loadCount = await backend.loadCount(for: "small")
        XCTAssertEqual(downloadCount, 0)
        XCTAssertEqual(loadCount, 1)
    }

    func testCachedOnlyPreparationLoadsCachedModelWithoutDownload() async throws {
        let backend = ModelBackendFake(cachedIDs: ["base"])
        let service = try makeService(backend: backend)

        let states = await collect(
            await service.prepareCached(modelID: "base", token: effectToken(generation: 1))
        )

        XCTAssertEqual(states, [.loading(modelID: "base"), .ready(modelID: "base")])
        let downloadCount = await backend.downloadCount(for: "base")
        let loadCount = await backend.loadCount(for: "base")
        XCTAssertEqual(downloadCount, 0)
        XCTAssertEqual(loadCount, 1)
    }

    func testCachedOnlyPreparationLeavesMissingModelWithoutDownload() async throws {
        let backend = ModelBackendFake()
        let service = try makeService(backend: backend)

        let cachedOnlyStates = await collect(
            await service.prepareCached(modelID: "base", token: effectToken(generation: 1))
        )

        XCTAssertEqual(cachedOnlyStates, [.missing(modelID: "base")])
        var downloadCount = await backend.downloadCount(for: "base")
        var loadCount = await backend.loadCount(for: "base")
        XCTAssertEqual(downloadCount, 0)
        XCTAssertEqual(loadCount, 0)

        let explicitStates = await collect(
            await service.prepare(modelID: "base", token: effectToken(generation: 2))
        )

        XCTAssertEqual(explicitStates.last, .ready(modelID: "base"))
        downloadCount = await backend.downloadCount(for: "base")
        loadCount = await backend.loadCount(for: "base")
        XCTAssertEqual(downloadCount, 1)
        XCTAssertEqual(loadCount, 1)
    }

    func testCancellationFinishesCurrentGenerationAndLateBackendCannotBecomeReady() async throws {
        let gate = ModelGate()
        let backend = ModelBackendFake(downloadGates: ["base": gate])
        let service = try makeService(backend: backend)
        let stream = await service.prepare(modelID: "base", token: effectToken(generation: 1))
        await waitUntil { await backend.downloadCount(for: "base") == 1 }

        await service.cancelPreparation()
        let states = await collect(stream)

        XCTAssertEqual(states.last, .failed(modelID: "base", code: .cancelled, retryable: true))
        await XCTAssertThrowsAsync { try await service.deleteCachedModel(modelID: "base") }
        await gate.open()
        await waitUntil {
            await service.state() == .failed(modelID: "base", code: .cancelled, retryable: true)
        }
    }

    func testNewGenerationIgnoresStaleCompletion() async throws {
        let firstGate = ModelGate()
        let backend = ModelBackendFake(cachedIDs: ["small"], downloadGates: ["base": firstGate])
        let service = try makeService(backend: backend)
        let first = await service.prepare(modelID: "base", token: effectToken(generation: 1))
        await waitUntil { await backend.downloadCount(for: "base") == 1 }

        let secondStates = await collect(
            await service.prepare(modelID: "small", token: effectToken(generation: 2))
        )
        XCTAssertEqual(secondStates.last, .ready(modelID: "small"))
        await firstGate.open()
        _ = await collect(first)
        await Task.yield()

        let state = await service.state()
        XCTAssertEqual(state, .ready(modelID: "small"))
    }

    func testFailureIsRetryableAndNextGenerationCanSucceed() async throws {
        let backend = ModelBackendFake(loadFailureCounts: ["base": 1])
        let service = try makeService(backend: backend)

        let failed = await collect(
            await service.prepare(modelID: "base", token: effectToken(generation: 1))
        )
        let retried = await collect(
            await service.prepare(modelID: "base", token: effectToken(generation: 2))
        )

        XCTAssertEqual(failed.last, .failed(modelID: "base", code: .transcriptionFailed, retryable: true))
        XCTAssertEqual(retried.last, .ready(modelID: "base"))
        let loadCount = await backend.loadCount(for: "base")
        XCTAssertEqual(loadCount, 2)
    }

    func testReadyLeaseRequiresExactModelAndFullEffectToken() async throws {
        let backend = ModelBackendFake(cachedIDs: ["base"])
        let service = try makeService(backend: backend)
        let preparationToken = effectToken(generation: 1)
        let sessionToken = effectToken(generation: 42)
        _ = await collect(await service.prepare(modelID: "base", token: preparationToken))

        await XCTAssertThrowsAsync {
            _ = try await service.acquireReadyModel(modelID: "small", token: sessionToken)
        }
        let lease = try await service.acquireReadyModel(modelID: "base", token: sessionToken)
        XCTAssertEqual(lease.modelID, "base")
        XCTAssertEqual(lease.generation, sessionToken.generation)

        await XCTAssertThrowsAsync {
            _ = try await service.resolve(
                lease,
                token: EffectToken(
                    sessionID: sessionToken.sessionID,
                    generation: sessionToken.generation + 1
                )
            )
        }
        _ = try await service.resolve(lease, token: sessionToken)
        await service.release(lease)
        await service.release(lease)
        await XCTAssertThrowsAsync { _ = try await service.resolve(lease, token: sessionToken) }
    }

    func testLeaseRetainsOldRuntimeAndDeletionRejectsPreparingCurrentOrLeasedModels() async throws {
        let gate = ModelGate()
        let backend = ModelBackendFake(
            cachedIDs: ["base", "small"],
            downloadGates: ["large-v3": gate]
        )
        let service = try makeService(backend: backend)
        let basePreparationToken = effectToken(generation: 1)
        let baseSessionToken = effectToken(generation: 101)
        _ = await collect(await service.prepare(modelID: "base", token: basePreparationToken))
        let baseLease = try await service.acquireReadyModel(modelID: "base", token: baseSessionToken)

        _ = await collect(
            await service.prepare(modelID: "small", token: effectToken(generation: 2))
        )
        _ = try await service.resolve(baseLease, token: baseSessionToken)
        await XCTAssertThrowsAsync { try await service.deleteCachedModel(modelID: "base") }
        await XCTAssertThrowsAsync { try await service.deleteCachedModel(modelID: "small") }

        await service.release(baseLease)
        try await service.deleteCachedModel(modelID: "base")
        let deletedIDs = await backend.deletedIDs()
        XCTAssertEqual(deletedIDs, ["base"])

        let preparing = await service.prepare(
            modelID: "large-v3",
            token: effectToken(generation: 3)
        )
        await waitUntil { await backend.downloadCount(for: "large-v3") == 1 }
        await XCTAssertThrowsAsync { try await service.deleteCachedModel(modelID: "large-v3") }
        await service.cancelPreparation()
        await gate.open()
        _ = await collect(preparing)
    }
}

private struct ModelServiceTestClock: AppClock {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    func sleep(for duration: Duration) async throws {}
}

private struct LocalTokenizerBackingFake: LocalWhisperTokenizerBacking {
    private static let defaultTokenIDs = [
        "<|endoftext|>": 50_257,
        "<|en|>": 50_259,
        "<|nospeech|>": 50_362,
        "<|notimestamps|>": 50_363,
        "<|startofprev|>": 50_361,
        "<|startoftranscript|>": 50_258,
        "<|0.00|>": 50_364,
        "<|transcribe|>": 50_358,
        "<|translate|>": 50_357
    ]

    let missingToken: String?
    private let tokenIDs: [String: Int]

    init(missingToken: String? = nil, noSpeechTokenID: Int = 50_362) {
        self.missingToken = missingToken
        var tokenIDs = Self.defaultTokenIDs
        tokenIDs["<|nospeech|>"] = noSpeechTokenID
        self.tokenIDs = tokenIDs
    }

    func encode(text: String) -> [Int] {
        text == " " ? [50_257, 220] : []
    }

    func decode(tokens: [Int]) -> String {
        tokens == [220] ? " " : ""
    }

    func convertTokenToId(_ token: String) -> Int? {
        if token == missingToken { return 50_257 }
        if let id = tokenIDs[token] { return id }
        if token.hasPrefix("<|"), token.hasSuffix("|>") { return 50_259 }
        return 50_257
    }

    func convertIdToToken(_ id: Int) -> String? {
        tokenIDs.first(where: { $0.value == id })?.key
    }
}

private enum ModelBackendFakeError: Error { case failed }

private actor ModelGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor ModelBackendFake: WhisperModelBackend {
    private var cachedIDs: Set<String>
    private let progressValues: [Double]
    private let downloadGates: [String: ModelGate]
    private var loadFailureCounts: [String: Int]
    private var downloads: [String: Int] = [:]
    private var loads: [String: Int] = [:]
    private var deletions: [String] = []
    private var runtimes: [String: ModelRuntimeFake] = [:]

    init(
        cachedIDs: Set<String> = [],
        progressValues: [Double] = [0.5, 1],
        downloadGates: [String: ModelGate] = [:],
        loadFailureCounts: [String: Int] = [:]
    ) {
        self.cachedIDs = cachedIDs
        self.progressValues = progressValues
        self.downloadGates = downloadGates
        self.loadFailureCounts = loadFailureCounts
    }

    func isCached(_ entry: WhisperCatalogEntry, root: URL) -> Bool {
        cachedIDs.contains(entry.id)
    }

    func download(
        _ entry: WhisperCatalogEntry,
        root: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        downloads[entry.id, default: 0] += 1
        for value in progressValues { progress(value) }
        if let gate = downloadGates[entry.id] { await gate.wait() }
        cachedIDs.insert(entry.id)
    }

    func load(_ entry: WhisperCatalogEntry, root: URL) async throws -> any WhisperRuntime {
        loads[entry.id, default: 0] += 1
        let failures = loadFailureCounts[entry.id, default: 0]
        if failures > 0 {
            loadFailureCounts[entry.id] = failures - 1
            throw ModelBackendFakeError.failed
        }
        if let runtime = runtimes[entry.id] { return runtime }
        let runtime = ModelRuntimeFake()
        runtimes[entry.id] = runtime
        return runtime
    }

    func deleteCached(_ entry: WhisperCatalogEntry, root: URL) async throws {
        cachedIDs.remove(entry.id)
        deletions.append(entry.id)
    }

    func downloadCount(for id: String) -> Int { downloads[id, default: 0] }
    func loadCount(for id: String) -> Int { loads[id, default: 0] }
    func deletedIDs() -> [String] { deletions }
}

private actor ModelRuntimeFake: WhisperRuntime {
    func transcribe(audioURL: URL, options: WhisperDecodeOptions) async throws -> [String] { [] }
}

private func makeService(backend: ModelBackendFake) throws -> WhisperModelService {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    return try WhisperModelService(
        catalog: .bundled,
        backend: backend,
        root: root,
        clock: ModelServiceTestClock()
    )
}

private func temporaryModelRoot() -> (URL, () -> Void) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    return (root, { try? FileManager.default.removeItem(at: root) })
}

private func effectToken(generation: UInt64) -> EffectToken {
    EffectToken(sessionID: SessionID(), generation: generation)
}

private func collect(_ stream: AsyncStream<SpeechModelState>) async -> [SpeechModelState] {
    var result: [SpeechModelState] = []
    for await value in stream { result.append(value) }
    return result
}

private func waitUntil(
    _ condition: @escaping @Sendable () async -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    for _ in 0 ..< 1_000 {
        if await condition() { return }
        await Task.yield()
    }
    XCTFail("condition not reached", file: file, line: line)
}

private func XCTAssertThrowsAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {}
}
