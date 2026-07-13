import AVFoundation
import Foundation
import UtterInkCore

enum AudioRecordPermission: Sendable {
    case undetermined
    case denied
    case granted
    case unknown
}

protocol RecordingPermissionClient: Sendable {
    var recordPermission: AudioRecordPermission { get }
    func requestRecordPermission() async -> Bool
}

protocol RecordingSession: Sendable {
    func start() throws
    func stop() throws
    func cancel()
}

protocol RecordingSessionFactory: Sendable {
    func makeSession(
        for url: URL,
        levels: @escaping @Sendable (Float) -> Void
    ) async throws -> any RecordingSession
}

public actor AVAudioRecordingService: AudioRecordingService {
    private struct ActiveCapture: Sendable {
        let handle: RecordingHandle
        let url: URL
        let session: any RecordingSession
    }

    private let store: any TransientAudioFileStore
    private let permission: any RecordingPermissionClient
    private let factory: any RecordingSessionFactory
    private var reservation: RecordingHandle?
    private var active: ActiveCapture?
    private var finalizing: ActiveCapture?
    private var cleanupRequested: Set<RecordingHandle> = []
    private var finalized: [RecordingHandle: URL] = [:]
    private var cleanupDebt: [RecordingHandle: URL] = [:]
    private var cleanupInFlight: Set<RecordingHandle> = []
    private var cancelledSessions: Set<RecordingHandle> = []
    private var permissionRequestGeneration: UInt64 = 0
    private var permissionRequest: (generation: UInt64, task: Task<Bool, Never>)?

    public init(store: TransientAudioStore) {
        self.store = store
        permission = SystemRecordingPermissionClient()
        factory = AVFoundationRecordingSessionFactory()
    }

    init(
        store: any TransientAudioFileStore,
        permission: any RecordingPermissionClient,
        factory: any RecordingSessionFactory
    ) {
        self.store = store
        self.permission = permission
        self.factory = factory
    }

    public func requestPermission() async -> PermissionState {
        switch permission.recordPermission {
        case .granted:
            return .granted
        case .denied:
            return .denied
        case .unknown:
            return .denied
        case .undetermined:
            if let request = permissionRequest {
                return await request.task.value ? .granted : .denied
            }
            permissionRequestGeneration &+= 1
            let generation = permissionRequestGeneration
            let permission = self.permission
            let task = Task { await permission.requestRecordPermission() }
            permissionRequest = (generation, task)
            let granted = await task.value
            if permissionRequest?.generation == generation {
                permissionRequest = nil
            }
            return granted ? .granted : .denied
        }
    }

    public func start(
        levels: @escaping @Sendable (Float) -> Void
    ) async throws -> RecordingHandle {
        guard reservation == nil, active == nil, finalizing == nil else {
            throw DiagnosticCode.audioStart
        }

        let handle = RecordingHandle()
        reservation = handle
        var url: URL?
        var session: (any RecordingSession)?

        do {
            guard await drainCleanupDebt() else {
                throw DiagnosticCode.audioStart
            }
            try Task.checkCancellation()
            let captureURL = try await store.makeCaptureFile()
            url = captureURL
            try Task.checkCancellation()
            try await store.verifyForRecording(captureURL)
            try Task.checkCancellation()

            let captureSession = try await factory.makeSession(for: captureURL, levels: levels)
            session = captureSession
            try Task.checkCancellation()
            try await store.verifyForRecording(captureURL)
            try Task.checkCancellation()
            try captureSession.start()
            try Task.checkCancellation()

            guard reservation == handle, active == nil else {
                throw DiagnosticCode.audioStart
            }
            active = ActiveCapture(handle: handle, url: captureURL, session: captureSession)
            reservation = nil
            return handle
        } catch {
            if let session {
                cancelSessionIfNeeded(session, handle: handle)
            }
            if let url {
                cleanupDebt[handle] = url
                _ = await attemptCleanup(handle)
            }
            if reservation == handle {
                reservation = nil
            }
            if error is CancellationError || Task.isCancelled {
                throw DiagnosticCode.cancelled
            }
            throw DiagnosticCode.audioStart
        }
    }

    public func stop(_ handle: RecordingHandle) async throws -> URL {
        if let url = finalized[handle] {
            return url
        }
        guard let capture = active, capture.handle == handle else {
            throw DiagnosticCode.audioFinalize
        }
        active = nil
        finalizing = capture

        do {
            try capture.session.stop()
            try await store.seal(capture.url)
        } catch {
            cancelSessionIfNeeded(capture.session, handle: handle)
            if finalizing?.handle == handle {
                finalizing = nil
            }
            cleanupRequested.remove(handle)
            finalized.removeValue(forKey: handle)
            cleanupDebt[handle] = capture.url
            _ = await attemptCleanup(handle)
            throw DiagnosticCode.audioFinalize
        }

        if cleanupRequested.remove(handle) != nil {
            if finalizing?.handle == handle {
                finalizing = nil
            }
            cleanupDebt[handle] = capture.url
            _ = await attemptCleanup(handle)
            throw DiagnosticCode.audioFinalize
        }
        finalizing = nil
        finalized[handle] = capture.url
        return capture.url
    }

    public func cancel(_ handle: RecordingHandle) async {
        if let capture = active, capture.handle == handle {
            active = nil
            cancelSessionIfNeeded(capture.session, handle: handle)
            cleanupDebt[handle] = capture.url
            _ = await attemptCleanup(handle)
            return
        }
        if let capture = finalizing, capture.handle == handle {
            cleanupRequested.insert(handle)
            cancelSessionIfNeeded(capture.session, handle: handle)
            return
        }
        if let url = finalized[handle] {
            cleanupDebt[handle] = url
            finalized.removeValue(forKey: handle)
            _ = await attemptCleanup(handle)
            return
        }
        if cleanupDebt[handle] != nil {
            _ = await attemptCleanup(handle)
        }
    }

    private func cancelSessionIfNeeded(
        _ session: any RecordingSession,
        handle: RecordingHandle
    ) {
        guard cancelledSessions.insert(handle).inserted else { return }
        session.cancel()
    }

    private func drainCleanupDebt() async -> Bool {
        guard cleanupInFlight.isEmpty else { return false }
        for handle in Array(cleanupDebt.keys) {
            guard await attemptCleanup(handle) else { return false }
        }
        return cleanupDebt.isEmpty
    }

    private func attemptCleanup(_ handle: RecordingHandle) async -> Bool {
        guard let url = cleanupDebt[handle] else { return true }
        guard cleanupInFlight.insert(handle).inserted else { return false }
        do {
            try await store.delete(url)
            cleanupInFlight.remove(handle)
            if cleanupDebt[handle] == url {
                cleanupDebt.removeValue(forKey: handle)
            }
            cancelledSessions.remove(handle)
            return true
        } catch {
            cleanupInFlight.remove(handle)
            return false
        }
    }
}

private struct SystemRecordingPermissionClient: RecordingPermissionClient {
    var recordPermission: AudioRecordPermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return .granted
        case .denied:
            return .denied
        case .undetermined:
            return .undetermined
        @unknown default:
            return .unknown
        }
    }

    func requestRecordPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

private struct AVFoundationRecordingSessionFactory: RecordingSessionFactory {
    func makeSession(
        for url: URL,
        levels: @escaping @Sendable (Float) -> Void
    ) async throws -> any RecordingSession {
        try AVFoundationRecordingSession(url: url, levels: levels)
    }
}

/// Synchronous terminal barrier for level callbacks.
///
/// `close()` prevents new callback reservations and waits for callbacks that
/// already reserved an invocation slot. User code is never called under the
/// condition lock.
final class SynchronousLevelPublisher: @unchecked Sendable {
    final class Invocation: @unchecked Sendable {
        private let lock = NSLock()
        private var body: (@Sendable () -> Void)?

        init(body: @escaping @Sendable () -> Void) {
            self.body = body
        }

        func invoke() {
            let invocation = lock.withLock { () -> (@Sendable () -> Void)? in
                defer { body = nil }
                return body
            }
            invocation?()
        }
    }

    private let condition = NSCondition()
    private var callback: (@Sendable (Float) -> Void)?
    private let beforeReservation: (@Sendable () -> Void)?
    private var inFlight = 0
    private var closed = false

    init(
        _ callback: @escaping @Sendable (Float) -> Void,
        beforeReservation: (@Sendable () -> Void)? = nil
    ) {
        self.callback = callback
        self.beforeReservation = beforeReservation
    }

    func publish(_ level: Float) {
        beforeReservation?()
        reserve(level)?.invoke()
    }

    func reserve(_ level: Float) -> Invocation? {
        condition.lock()
        guard !closed, let callback else {
            condition.unlock()
            return nil
        }
        inFlight += 1
        condition.unlock()

        return Invocation { [self] in
            callback(level)
            finishInvocation()
        }
    }

    private func finishInvocation() {
        condition.lock()
        inFlight -= 1
        if inFlight == 0 {
            condition.broadcast()
        }
        condition.unlock()
    }

    func beginClose() {
        condition.lock()
        closed = true
        callback = nil
        condition.unlock()
    }

    func waitForDrain() {
        condition.lock()
        while inFlight > 0 {
            condition.wait()
        }
        condition.unlock()
    }

    func close() {
        beginClose()
        waitForDrain()
    }
}

/// The no-microphone lifecycle shared by the real AVFoundation session and
/// deterministic tests. Its condition is the single state boundary for open
/// work, callback reservation, close ownership, and close completion.
final class AVFoundationRecordingSessionLifecycle: @unchecked Sendable {
    struct CloseResult {
        let ownsTeardown: Bool
        let error: Error?
    }

    private enum Phase {
        case open
        case closing
        case closed
    }

    private let condition = NSCondition()
    private var callback: (@Sendable (Float) -> Void)?
    private let beforeReservation: (@Sendable () -> Void)?
    private var phase: Phase = .open
    private var inFlightCallbacks = 0
    private var finalError: Error?

    init(
        levels: @escaping @Sendable (Float) -> Void,
        beforeReservation: (@Sendable () -> Void)? = nil
    ) {
        callback = levels
        self.beforeReservation = beforeReservation
    }

    func performOpenWork(_ work: () throws -> Void) rethrows -> Bool {
        condition.lock()
        guard phase == .open else {
            condition.unlock()
            return false
        }
        defer { condition.unlock() }
        try work()
        return true
    }

    func reserveLevel(
        afterOpenWork work: () -> Float?
    ) -> SynchronousLevelPublisher.Invocation? {
        beforeReservation?()
        condition.lock()
        guard phase == .open else {
            condition.unlock()
            return nil
        }
        let level = work()
        guard let level, let callback else {
            condition.unlock()
            return nil
        }
        inFlightCallbacks += 1
        condition.unlock()

        return SynchronousLevelPublisher.Invocation { [self] in
            callback(level)
            finishCallback()
        }
    }

    func beginClose(_ prepare: () -> Error?) -> CloseResult {
        condition.lock()
        while phase == .closing {
            condition.wait()
        }
        guard phase == .open else {
            let error = finalError
            condition.unlock()
            return CloseResult(ownsTeardown: false, error: error)
        }
        phase = .closing
        callback = nil
        finalError = prepare()
        let error = finalError
        condition.unlock()
        return CloseResult(ownsTeardown: true, error: error)
    }

    func waitForCallbackDrain() {
        condition.lock()
        while inFlightCallbacks > 0 {
            condition.wait()
        }
        condition.unlock()
    }

    func completeClose() {
        condition.lock()
        if phase == .closing {
            phase = .closed
            condition.broadcast()
        }
        condition.unlock()
    }

    private func finishCallback() {
        condition.lock()
        inFlightCallbacks -= 1
        if inFlightCallbacks == 0 {
            condition.broadcast()
        }
        condition.unlock()
    }
}

private final class AVFoundationRecordingSession: RecordingSession, @unchecked Sendable {
    private let engine: AVAudioEngine
    private let input: AVAudioInputNode
    private var file: AVAudioFile?
    private let lifecycle: AVFoundationRecordingSessionLifecycle
    private var firstWriteError: Error?
    private var lastLevelEmission: TimeInterval = -.infinity
    private var smoothedLevel: Float = 0
    private var started = false

    init(url: URL, levels: @escaping @Sendable (Float) -> Void) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw AVFoundationRecordingSessionError.invalidFormat
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)

        self.engine = engine
        self.input = input
        self.file = file
        lifecycle = AVFoundationRecordingSessionLifecycle(levels: levels)
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
    }

    func start() throws {
        var attemptedStart = false
        do {
            let open = try lifecycle.performOpenWork {
                guard !started else {
                    throw AVFoundationRecordingSessionError.closed
                }
                started = true
                attemptedStart = true
                engine.prepare()
                try engine.start()
            }
            guard open else {
                throw AVFoundationRecordingSessionError.closed
            }
        } catch {
            if attemptedStart {
                cancel()
            }
            throw error
        }
    }

    func stop() throws {
        let writeError = close()
        if let writeError {
            throw writeError
        }
    }

    func cancel() {
        _ = close()
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        let rawLevel = Self.meterLevel(for: buffer)
        let invocation = lifecycle.reserveLevel(afterOpenWork: {
            if firstWriteError == nil, let file {
                do {
                    try file.write(from: buffer)
                } catch {
                    firstWriteError = error
                }
            }

            smoothedLevel = AudioLevelMeter.smoothed(previous: smoothedLevel, next: rawLevel)
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastLevelEmission >= 0.025 {
                lastLevelEmission = now
                return min(1, max(0, smoothedLevel))
            }
            return nil
        })
        invocation?.invoke()
    }

    private func close() -> Error? {
        let result = lifecycle.beginClose {
            let error = firstWriteError
            file = nil
            return error
        }
        guard result.ownsTeardown else {
            return result.error
        }
        input.removeTap(onBus: 0)
        engine.stop()
        lifecycle.waitForCallbackDrain()
        lifecycle.completeClose()
        return result.error
    }

    private static func meterLevel(for buffer: AVAudioPCMBuffer) -> Float {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }

        let channelCount = Int(buffer.format.channelCount)
        var maxRMS: Float = 0
        if let channels = buffer.floatChannelData {
            for channel in 0..<channelCount {
                let samples = channels[channel]
                var sum: Float = 0
                for index in 0..<frameCount {
                    let value = samples[index]
                    sum += value * value
                }
                maxRMS = max(maxRMS, sqrt(sum / Float(frameCount)))
            }
        } else if let channels = buffer.int16ChannelData {
            for channel in 0..<channelCount {
                let samples = channels[channel]
                var sum: Float = 0
                for index in 0..<frameCount {
                    let value = Float(samples[index]) / 32_768
                    sum += value * value
                }
                maxRMS = max(maxRMS, sqrt(sum / Float(frameCount)))
            }
        } else {
            return 0
        }
        return AudioLevelMeter.mapped(maxRMS: maxRMS)
    }
}

enum AudioLevelMeter {
    static func level(floatChannels channels: [[Float]]) -> Float {
        mapped(maxRMS: maximumRMS(channels) { $0 })
    }

    static func level(int16Channels channels: [[Int16]]) -> Float {
        mapped(maxRMS: maximumRMS(channels) { Float($0) / 32_768 })
    }

    static func mapped(maxRMS: Float) -> Float {
        guard maxRMS.isFinite, maxRMS > 0 else { return 0 }
        return min(1, max(0, sqrt(maxRMS * 14)))
    }

    static func smoothed(previous: Float, next: Float) -> Float {
        let coefficient: Float = next > previous ? 0.45 : 0.12
        return min(1, max(0, previous + coefficient * (next - previous)))
    }

    private static func maximumRMS<Sample>(
        _ channels: [[Sample]],
        normalize: (Sample) -> Float
    ) -> Float {
        var maximum: Float = 0
        for channel in channels where !channel.isEmpty {
            var sum: Float = 0
            for sample in channel {
                let value = normalize(sample)
                sum += value * value
            }
            maximum = max(maximum, sqrt(sum / Float(channel.count)))
        }
        return maximum
    }
}

private enum AVFoundationRecordingSessionError: Error {
    case invalidFormat
    case closed
}
