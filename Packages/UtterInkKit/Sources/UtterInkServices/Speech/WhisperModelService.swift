import Foundation
import Hub
import Tokenizers
import UtterInkCore
import WhisperKit

struct WhisperDecodeOptions: Equatable, Sendable {
    let language: String?
    let detectLanguage: Bool
}

protocol WhisperRuntime: Sendable {
    func transcribe(audioURL: URL, options: WhisperDecodeOptions) async throws -> [String]
}

protocol WhisperModelBackend: Sendable {
    func isCached(_ entry: WhisperCatalogEntry, root: URL) async -> Bool
    func download(
        _ entry: WhisperCatalogEntry,
        root: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws
    func load(_ entry: WhisperCatalogEntry, root: URL) async throws -> any WhisperRuntime
    func deleteCached(_ entry: WhisperCatalogEntry, root: URL) async throws
}

public actor WhisperModelService: SpeechModelService {
    private enum PreparationPhase { case checking, downloading, loading }

    private struct Preparation {
        let modelID: String
        let token: EffectToken
        let generation: UInt64
        let continuation: AsyncStream<SpeechModelState>.Continuation
        var phase: PreparationPhase
    }

    private struct ReadyRecord {
        let modelID: String
        let runtime: any WhisperRuntime
    }

    private struct LeaseRecord {
        let lease: SpeechModelLease
        let token: EffectToken
        let runtime: any WhisperRuntime
    }

    private let catalogByID: [String: WhisperCatalogEntry]
    private let backend: any WhisperModelBackend
    private let root: URL
    private let clock: any AppClock
    private var currentState: SpeechModelState
    private var nextPreparationGeneration: UInt64 = 0
    private var preparation: Preparation?
    private var preparationTask: Task<Void, Never>?
    private var activeOperations: [UInt64: String] = [:]
    private var ready: ReadyRecord?
    private var leases: [UUID: LeaseRecord] = [:]

    public init(catalog: WhisperModelCatalog, root: URL, clock: any AppClock) throws {
        try self.init(
            catalog: catalog,
            backend: RealWhisperModelBackend(),
            root: root,
            clock: clock
        )
    }

    init(
        catalog: WhisperModelCatalog,
        backend: any WhisperModelBackend,
        root: URL,
        clock: any AppClock
    ) throws {
        guard root.isFileURL, root.path.hasPrefix("/") else {
            throw WhisperModelServiceError.invalidRoot
        }
        let normalizedRoot = root.standardizedFileURL
        do {
            try FileManager.default.createDirectory(
                at: normalizedRoot,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let values = try normalizedRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw WhisperModelServiceError.invalidRoot
            }
        } catch let error as WhisperModelServiceError {
            throw error
        } catch {
            throw WhisperModelServiceError.invalidRoot
        }

        catalogByID = Dictionary(uniqueKeysWithValues: catalog.entries.map { ($0.id, $0) })
        self.backend = backend
        self.root = normalizedRoot
        self.clock = clock
        currentState = .missing(modelID: catalog.defaultModelID)
    }

    public func state() async -> SpeechModelState {
        currentState
    }

    public func prepare(modelID: String, token: EffectToken) async -> AsyncStream<SpeechModelState> {
        preparationTask?.cancel()
        preparation?.continuation.finish()
        preparation = nil
        ready = nil

        let pair = AsyncStream<SpeechModelState>.makeStream()
        nextPreparationGeneration &+= 1
        let generation = nextPreparationGeneration

        guard let entry = catalogByID[modelID] else {
            let failed = SpeechModelState.failed(
                modelID: modelID,
                code: .transcriptionFailed,
                retryable: false
            )
            currentState = failed
            pair.continuation.yield(failed)
            pair.continuation.finish()
            return pair.stream
        }

        currentState = .missing(modelID: modelID)
        preparation = Preparation(
            modelID: modelID,
            token: token,
            generation: generation,
            continuation: pair.continuation,
            phase: .checking
        )
        activeOperations[generation] = modelID
        preparationTask = Task { [weak self] in
            await self?.runPreparation(entry: entry, token: token, generation: generation)
        }
        return pair.stream
    }

    public func cancelPreparation() async {
        guard let current = preparation else { return }
        nextPreparationGeneration &+= 1
        preparationTask?.cancel()
        preparationTask = nil
        let failed = SpeechModelState.failed(
            modelID: current.modelID,
            code: .cancelled,
            retryable: true
        )
        currentState = failed
        current.continuation.yield(failed)
        current.continuation.finish()
        preparation = nil
    }

    public func acquireReadyModel(
        modelID: String,
        token: EffectToken
    ) async throws -> SpeechModelLease {
        guard let ready, ready.modelID == modelID else {
            throw WhisperModelServiceError.modelNotReady
        }
        let lease = SpeechModelLease(modelID: modelID, generation: token.generation)
        leases[lease.id] = LeaseRecord(lease: lease, token: token, runtime: ready.runtime)
        return lease
    }

    public func release(_ lease: SpeechModelLease) async {
        leases.removeValue(forKey: lease.id)
    }

    public func deleteCachedModel(modelID: String) async throws {
        guard let entry = catalogByID[modelID] else {
            throw WhisperModelServiceError.unknownModel
        }
        guard preparation?.modelID != modelID,
              !activeOperations.values.contains(modelID),
              ready?.modelID != modelID,
              !leases.values.contains(where: { $0.lease.modelID == modelID }) else {
            throw WhisperModelServiceError.modelInUse
        }
        do {
            try await backend.deleteCached(entry, root: root)
        } catch {
            throw WhisperModelServiceError.cacheOperationFailed
        }
    }

    func resolve(
        _ lease: SpeechModelLease,
        token: EffectToken
    ) async throws -> any WhisperRuntime {
        guard let record = leases[lease.id],
              record.lease == lease,
              record.lease.modelID == lease.modelID,
              record.lease.generation == token.generation,
              record.token == token else {
            throw WhisperModelServiceError.invalidLease
        }
        return record.runtime
    }

    private func runPreparation(
        entry: WhisperCatalogEntry,
        token: EffectToken,
        generation: UInt64
    ) async {
        defer { activeOperations.removeValue(forKey: generation) }
        let cached = await backend.isCached(entry, root: root)
        guard isCurrent(generation: generation, token: token), !Task.isCancelled else { return }

        do {
            if !cached {
                emit(.missing(modelID: entry.id), generation: generation)
                setPhase(.downloading, generation: generation)
                try await backend.download(entry, root: root) { [weak self] value in
                    Task { await self?.emitProgress(value, modelID: entry.id, generation: generation) }
                }
                guard isCurrent(generation: generation, token: token), !Task.isCancelled else { return }
            }

            setPhase(.loading, generation: generation)
            emit(.loading(modelID: entry.id), generation: generation)
            let runtime = try await backend.load(entry, root: root)
            guard isCurrent(generation: generation, token: token), !Task.isCancelled else { return }
            finishReady(entry: entry, token: token, runtime: runtime, generation: generation)
        } catch {
            guard isCurrent(generation: generation, token: token) else { return }
            if Task.isCancelled || error is CancellationError {
                finishFailed(
                    modelID: entry.id,
                    code: .cancelled,
                    retryable: true,
                    generation: generation
                )
            } else {
                finishFailed(
                    modelID: entry.id,
                    code: .transcriptionFailed,
                    retryable: true,
                    generation: generation
                )
            }
        }
    }

    private func isCurrent(generation: UInt64, token: EffectToken) -> Bool {
        preparation?.generation == generation && preparation?.token == token
    }

    private func setPhase(_ phase: PreparationPhase, generation: UInt64) {
        guard preparation?.generation == generation else { return }
        preparation?.phase = phase
    }

    private func emit(_ state: SpeechModelState, generation: UInt64) {
        guard let current = preparation, current.generation == generation else { return }
        currentState = state
        current.continuation.yield(state)
    }

    private func emitProgress(_ value: Double, modelID: String, generation: UInt64) {
        guard preparation?.generation == generation,
              preparation?.phase == .downloading else { return }
        let bounded = value.isFinite ? min(1, max(0, value)) : 0
        emit(.downloading(modelID: modelID, progress: bounded), generation: generation)
    }

    private func finishReady(
        entry: WhisperCatalogEntry,
        token: EffectToken,
        runtime: any WhisperRuntime,
        generation: UInt64
    ) {
        guard let current = preparation, current.generation == generation else { return }
        ready = ReadyRecord(modelID: entry.id, runtime: runtime)
        let state = SpeechModelState.ready(modelID: entry.id)
        currentState = state
        current.continuation.yield(state)
        current.continuation.finish()
        preparation = nil
        preparationTask = nil
    }

    private func finishFailed(
        modelID: String,
        code: DiagnosticCode,
        retryable: Bool,
        generation: UInt64
    ) {
        guard let current = preparation, current.generation == generation else { return }
        let state = SpeechModelState.failed(modelID: modelID, code: code, retryable: retryable)
        currentState = state
        current.continuation.yield(state)
        current.continuation.finish()
        preparation = nil
        preparationTask = nil
    }
}

enum WhisperModelServiceError: Error {
    case invalidRoot
    case unknownModel
    case modelNotReady
    case invalidLease
    case modelInUse
    case cacheOperationFailed
}

private struct RealWhisperModelBackend: WhisperModelBackend {
    private static let endpoint = "https://huggingface.co"
    private static let tokenizerFiles = [
        "config.json",
        "special_tokens_map.json",
        "tokenizer.json",
        "tokenizer_config.json"
    ]

    func isCached(_ entry: WhisperCatalogEntry, root: URL) async -> Bool {
        validModelFolder(Self.modelFolder(for: entry, root: root))
            && validTokenizerFolder(Self.tokenizerFolder(for: entry, root: root))
    }

    func download(
        _ entry: WhisperCatalogEntry,
        root: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let modelBase = Self.modelDownloadBase(for: entry, root: root)
        let tokenizerBase = Self.tokenizerDownloadBase(for: entry, root: root)
        try FileManager.default.createDirectory(at: modelBase, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tokenizerBase, withIntermediateDirectories: true)

        let downloader = Self.modelDownloader(for: entry)
        _ = try await downloader.resolveRepo(
            patterns: Self.modelPatterns(for: entry),
            downloadBase: modelBase,
            download: true
        ) { modelProgress in
            progress(0.8 * Self.bounded(modelProgress.fractionCompleted))
        }
        try Task.checkCancellation()

        let hub = HubApi(
            downloadBase: tokenizerBase,
            endpoint: Self.endpoint,
            useOfflineMode: false
        )
        let repo = Hub.Repo(id: entry.tokenizerRepository, type: .models)
        _ = try await hub.snapshot(
            from: repo,
            revision: entry.tokenizerRevision,
            matching: Self.tokenizerFiles
        ) { tokenizerProgress in
            progress(0.8 + 0.2 * Self.bounded(tokenizerProgress.fractionCompleted))
        }
        try Task.checkCancellation()

        guard validModelFolder(Self.modelFolder(for: entry, root: root)),
              validTokenizerFolder(Self.tokenizerFolder(for: entry, root: root)) else {
            throw RealBackendError.incompleteDownload
        }
        progress(1)
    }

    func load(_ entry: WhisperCatalogEntry, root: URL) async throws -> any WhisperRuntime {
        let modelFolder = Self.modelFolder(for: entry, root: root)
        let tokenizerFolder = Self.tokenizerFolder(for: entry, root: root)
        guard validModelFolder(modelFolder), validTokenizerFolder(tokenizerFolder) else {
            throw RealBackendError.incompleteDownload
        }

        let offlineHub = HubApi(
            downloadBase: Self.tokenizerDownloadBase(for: entry, root: root),
            endpoint: Self.endpoint,
            useOfflineMode: true
        )
        let configuration = LanguageModelConfigurationFromHub(
            modelFolder: tokenizerFolder,
            hubApi: offlineHub
        )
        guard let tokenizerConfig = try await configuration.tokenizerConfig else {
            throw RealBackendError.invalidTokenizer
        }
        let tokenizerData = try await configuration.tokenizerData
        let tokenizer = try PreTrainedTokenizer(
            tokenizerConfig: tokenizerConfig,
            tokenizerData: tokenizerData,
            strict: true
        )
        let wrappedTokenizer = try LocalWhisperTokenizer(tokenizer: tokenizer)

        let config = WhisperKitConfig(
            model: entry.id,
            modelFolder: modelFolder.path,
            tokenizerFolder: tokenizerFolder,
            verbose: false,
            load: false,
            download: false
        )
        let kit = try await WhisperKit(config)
        kit.tokenizer = wrappedTokenizer
        kit.textDecoder.isModelMultilingual = true
        try await kit.loadModels()
        return RealWhisperRuntime(kit: kit)
    }

    func deleteCached(_ entry: WhisperCatalogEntry, root: URL) async throws {
        for directory in [
            Self.modelDownloadBase(for: entry, root: root),
            Self.tokenizerDownloadBase(for: entry, root: root)
        ] where FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func validModelFolder(_ folder: URL) -> Bool {
        ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]
            .allSatisfy { Self.isNonemptyDirectory(folder.appendingPathComponent($0, isDirectory: true)) }
            && Self.isRegularFile(folder.appendingPathComponent("config.json"))
            && Self.isRegularFile(folder.appendingPathComponent("generation_config.json"))
    }

    private func validTokenizerFolder(_ folder: URL) -> Bool {
        Self.tokenizerFiles.allSatisfy {
            Self.isRegularFile(folder.appendingPathComponent($0, isDirectory: false))
        }
    }

    private static func modelDownloader(for entry: WhisperCatalogEntry) -> ModelDownloader {
        ModelDownloader(
            config: ModelDownloadConfig(
                modelRepo: entry.repository,
                endpoint: endpoint,
                revision: entry.revision
            )
        )
    }

    private static func modelPatterns(for entry: WhisperCatalogEntry) -> [String] {
        [
            "\(entry.folder)/MelSpectrogram.mlmodelc/**",
            "\(entry.folder)/AudioEncoder.mlmodelc/**",
            "\(entry.folder)/TextDecoder.mlmodelc/**",
            "\(entry.folder)/config.json",
            "\(entry.folder)/generation_config.json"
        ]
    }

    private static func modelDownloadBase(for entry: WhisperCatalogEntry, root: URL) -> URL {
        root.appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(entry.revision, isDirectory: true)
            .appendingPathComponent(entry.id, isDirectory: true)
    }

    private static func tokenizerDownloadBase(for entry: WhisperCatalogEntry, root: URL) -> URL {
        root.appendingPathComponent("tokenizers", isDirectory: true)
            .appendingPathComponent(entry.tokenizerRevision, isDirectory: true)
            .appendingPathComponent(entry.id, isDirectory: true)
    }

    private static func modelFolder(for entry: WhisperCatalogEntry, root: URL) -> URL {
        modelDownloader(for: entry)
            .localRepoLocation(downloadBase: modelDownloadBase(for: entry, root: root))
            .appendingPathComponent(entry.folder, isDirectory: true)
    }

    private static func tokenizerFolder(for entry: WhisperCatalogEntry, root: URL) -> URL {
        HubApi(
            downloadBase: tokenizerDownloadBase(for: entry, root: root),
            endpoint: endpoint,
            useOfflineMode: true
        ).localRepoLocation(Hub.Repo(id: entry.tokenizerRepository, type: .models))
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    private static func isNonemptyDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
            return false
        }
        return !contents.isEmpty
    }

    private static func bounded(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }
}

private enum RealBackendError: Error {
    case incompleteDownload
    case invalidTokenizer
}

private actor RealWhisperRuntime: WhisperRuntime {
    private let kit: SendableWhisperKit
    private var isAvailable = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(kit: WhisperKit) {
        self.kit = SendableWhisperKit(value: kit)
    }

    func transcribe(audioURL: URL, options: WhisperDecodeOptions) async throws -> [String] {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        let decodingOptions = DecodingOptions(
            language: options.language,
            detectLanguage: options.detectLanguage
        )
        let results: [TranscriptionResult] = try await kit.value.transcribe(
            audioPath: audioURL.path,
            decodeOptions: decodingOptions
        )
        return results.map(\.text)
    }

    private func acquire() async {
        if isAvailable {
            isAvailable = false
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            isAvailable = true
            return
        }
        waiters.removeFirst().resume()
    }
}

private final class SendableWhisperKit: @unchecked Sendable {
    let value: WhisperKit

    init(value: WhisperKit) {
        self.value = value
    }
}

protocol LocalWhisperTokenizerBacking {
    func encode(text: String) -> [Int]
    func decode(tokens: [Int]) -> String
    func convertTokenToId(_ token: String) -> Int?
    func convertIdToToken(_ id: Int) -> String?
}

extension PreTrainedTokenizer: LocalWhisperTokenizerBacking {}

final class LocalWhisperTokenizer: WhisperTokenizer {
    private let tokenizer: any LocalWhisperTokenizerBacking
    let specialTokens: SpecialTokens
    let allLanguageTokens: Set<Int>

    init(tokenizer: any LocalWhisperTokenizerBacking) throws {
        func required(_ token: String) throws -> Int {
            guard let value = tokenizer.convertTokenToId(token),
                  tokenizer.convertIdToToken(value) == token else {
                throw RealBackendError.invalidTokenizer
            }
            return value
        }

        let end = try required("<|endoftext|>")
        let whitespaceCandidates = tokenizer.encode(text: " ").filter { $0 < end }
        guard whitespaceCandidates.count == 1,
              let whitespace = whitespaceCandidates.first,
              tokenizer.decode(tokens: [whitespace]) == " " else {
            throw RealBackendError.invalidTokenizer
        }
        specialTokens = try SpecialTokens(
            endToken: end,
            englishToken: required("<|en|>"),
            noSpeechToken: required("<|nospeech|>"),
            noTimestampsToken: required("<|notimestamps|>"),
            specialTokenBegin: end,
            startOfPreviousToken: required("<|startofprev|>"),
            startOfTranscriptToken: required("<|startoftranscript|>"),
            timeTokenBegin: required("<|0.00|>"),
            transcribeToken: required("<|transcribe|>"),
            translateToken: required("<|translate|>"),
            whitespaceToken: whitespace
        )
        self.tokenizer = tokenizer
        allLanguageTokens = Set(
            Constants.languages.values.compactMap { code in
                tokenizer.convertTokenToId("<|\(code)|>")
            }.filter { $0 > end }
        )
        guard !allLanguageTokens.isEmpty else {
            throw RealBackendError.invalidTokenizer
        }
    }

    func encode(text: String) -> [Int] { tokenizer.encode(text: text) }
    func decode(tokens: [Int]) -> String { tokenizer.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { tokenizer.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { tokenizer.convertIdToToken(id) }

    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        var words: [String] = []
        var wordTokens: [[Int]] = []
        for tokenID in tokenIds where tokenID < specialTokens.specialTokenBegin {
            let fragment = tokenizer.decode(tokens: [tokenID])
            if words.isEmpty || fragment.first?.isWhitespace == true {
                words.append(fragment)
                wordTokens.append([tokenID])
            } else {
                words[words.count - 1].append(fragment)
                wordTokens[wordTokens.count - 1].append(tokenID)
            }
        }
        return (words, wordTokens)
    }
}
