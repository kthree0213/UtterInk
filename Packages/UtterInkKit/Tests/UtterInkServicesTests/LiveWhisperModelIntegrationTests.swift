import Darwin
import Foundation
import XCTest
import UtterInkCore
@testable import UtterInkServices

final class LiveWhisperModelIntegrationTests: XCTestCase {
    private static let isolatedWorkerEnvironmentKey = "UTTERINK_LIVE_ISOLATED_WORKER"
    private static let smokeWorkerEnvironmentKey = "UTTERINK_LIVE_SUPERVISOR_SMOKE_WORKER"
    private static let selectedTest = "UtterInkServicesTests.LiveWhisperModelIntegrationTests/"
        + "testPinnedModelDownloadsLoadsAndTranscribesWhenExplicitlyEnabled"
    private static let smokeSelectedTest = "UtterInkServicesTests.LiveWhisperModelIntegrationTests/"
        + "testLiveModelSupervisorSmokePathDoesNotAccessNetwork"
    private static let workerDeadline: Duration = .seconds(1_800)
    private static let preparationDeadline: Duration = .seconds(1_770)
    private static let transcriptionDeadline: Duration = .seconds(300)

    func testLiveModelSupervisorSmokePathDoesNotAccessNetwork() async throws {
        executionTimeAllowance = 40
        let environment = ProcessInfo.processInfo.environment
        if let expectedParentPID = environment[Self.smokeWorkerEnvironmentKey].flatMap(Int32.init) {
            XCTAssertEqual(
                expectedParentPID,
                getppid(),
                "xcrun must exec xctest without interposing a different worker parent."
            )
            return
        }

        let process = try makeXCTestSubprocess(
            selectedTest: Self.smokeSelectedTest,
            environment: environment,
            workerEnvironmentKey: Self.smokeWorkerEnvironmentKey,
            inheritsOutput: false
        )
        try process.run()
        let outcome = await waitForProcessExit(process, timeout: .seconds(20))
        guard outcome == .exited else {
            let workerExited = terminateAndReap(process)
            XCTAssertTrue(workerExited, "The offline supervisor smoke worker could not be reaped.")
            XCTFail("The offline supervisor smoke worker exceeded its deadline.")
            return
        }
        process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testPinnedModelDownloadsLoadsAndTranscribesWhenExplicitlyEnabled() async throws {
        executionTimeAllowance = 1_860
        let environment = ProcessInfo.processInfo.environment
        guard let modelID = environment["UTTERINK_LIVE_MODEL_ID"], !modelID.isEmpty else {
            throw XCTSkip("Set UTTERINK_LIVE_MODEL_ID to run the network-backed model check.")
        }

        let expectedWorkerParentPID = environment[Self.isolatedWorkerEnvironmentKey]
            .flatMap(Int32.init)
        if let expectedWorkerParentPID {
            guard expectedWorkerParentPID == getppid() else {
                throw LiveTestConfigurationError("Invalid isolated live-model worker context.")
            }
            try await runIsolatedWorker(environment: environment, modelID: modelID)
            return
        }

        let configuration = try validatedConfiguration(
            environment: environment,
            modelID: modelID
        )
        try await runWorkerSubprocess(
            environment: environment,
            configuration: configuration
        )
    }

    private func runWorkerSubprocess(
        environment: [String: String],
        configuration: LiveTestConfiguration
    ) async throws {
        let process = try makeXCTestSubprocess(
            selectedTest: Self.selectedTest,
            environment: environment,
            workerEnvironmentKey: Self.isolatedWorkerEnvironmentKey,
            inheritsOutput: true
        )

        var workerExited = false
        defer {
            if workerExited {
                removeTemporaryRoot(configuration.root)
            }
        }

        try process.run()
        let outcome = await waitForProcessExit(process, timeout: Self.workerDeadline)
        switch outcome {
        case .exited:
            process.waitUntilExit()
            workerExited = true
            XCTAssertEqual(
                process.terminationReason,
                .exit,
                "The isolated live-model worker terminated from a signal."
            )
            XCTAssertEqual(
                process.terminationStatus,
                0,
                "The isolated live-model worker reported a failure."
            )

        case .deadlineReached, .parentCancelled:
            workerExited = terminateAndReap(process)
            guard workerExited else {
                XCTFail(
                    "Could not confirm isolated worker termination; its temporary root was retained "
                        + "to avoid racing a live process."
                )
                return
            }
            XCTFail(
                outcome == .deadlineReached
                    ? "Live download, load, and transcription exceeded the 30-minute hard deadline."
                    : "The live-model test was cancelled; its isolated worker was terminated."
            )
        }
    }

    private func runIsolatedWorker(
        environment: [String: String],
        modelID: String
    ) async throws {
        let configuration = try validatedConfiguration(
            environment: environment,
            modelID: modelID
        )
        // The supervisor is the sole cleanup owner. In particular, a preparation cancellation
        // may finish its AsyncStream before the backend task has unwound; this worker must not
        // remove the root while any of its own model work could still be running.

        let service = try WhisperModelService(
            catalog: .bundled,
            root: configuration.root,
            clock: SystemAppClock()
        )
        let token = EffectToken(sessionID: SessionID(), generation: 1)
        let states = await service.prepare(modelID: modelID, token: token)
        let preparationTimeoutTask = Task { () -> Bool in
            do {
                try await Task.sleep(for: Self.preparationDeadline)
            } catch {
                return false
            }
            await service.cancelPreparation()
            return true
        }
        defer { preparationTimeoutTask.cancel() }

        var finalState: SpeechModelState?
        for await state in states {
            finalState = state
            print("UTTERINK_LIVE_MODEL_STATE \(state)")
        }
        preparationTimeoutTask.cancel()
        let preparationTimedOut = await preparationTimeoutTask.value
        guard !preparationTimedOut else {
            XCTFail("Pinned model preparation exceeded its controlled timeout and was cancelled.")
            return
        }
        guard case let .ready(readyID) = finalState, readyID == modelID else {
            XCTFail("Pinned model did not become ready: \(String(describing: finalState))")
            return
        }

        let lease = try await service.acquireReadyModel(modelID: modelID, token: token)
        let transcriber = WhisperTranscriber(models: service)
        let outcomeGate = TranscriptionOutcomeGate()
        let transcriptionTask = Task {
            do {
                let text = try await transcriber.transcribe(
                    audioURL: configuration.audioURL,
                    model: lease,
                    configuration: .fixed(languageCode: "en"),
                    token: token
                )
                await outcomeGate.resolve(.success(text))
            } catch {
                await outcomeGate.resolve(.failure(String(describing: error)))
            }
        }
        let transcriptionTimeoutTask = Task {
            do {
                try await Task.sleep(for: Self.transcriptionDeadline)
            } catch {
                return
            }
            transcriptionTask.cancel()
            await outcomeGate.resolve(.deadlineReached)
        }
        defer { transcriptionTimeoutTask.cancel() }

        let text: String
        switch await outcomeGate.wait() {
        case let .success(value):
            transcriptionTimeoutTask.cancel()
            await transcriptionTask.value
            await service.release(lease)
            text = value

        case let .failure(description):
            transcriptionTimeoutTask.cancel()
            await transcriptionTask.value
            await service.release(lease)
            XCTFail("Pinned model transcription failed: \(description)")
            return

        case .deadlineReached:
            // Task cancellation is cooperative and WhisperKit/Core ML does not guarantee that
            // its await will return. This code runs only in the isolated worker, so a hard exit
            // prevents an unbounded wait without racing lease or cache cleanup in this process.
            transcriptionTask.cancel()
            Darwin._exit(124)
        }

        let transcriptWords = Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
        let matchedKeywords = configuration.expectedKeywords.intersection(transcriptWords)
        print("UTTERINK_LIVE_TRANSCRIPT_VALIDATED")
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertGreaterThanOrEqual(
            matchedKeywords.count,
            2,
            "Transcript did not preserve at least two expected fixture keywords as whole words."
        )
    }

    private func validatedConfiguration(
        environment: [String: String],
        modelID: String
    ) throws -> LiveTestConfiguration {
        let temporaryRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .standardizedFileURL
        guard let rootPath = environment["UTTERINK_LIVE_MODEL_ROOT"] else {
            throw LiveTestConfigurationError(
                "UTTERINK_LIVE_MODEL_ROOT must name a fresh isolated temporary directory."
            )
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        guard root.deletingLastPathComponent() == temporaryRoot,
              root.lastPathComponent.hasPrefix("utterink-live-model-"),
              root.lastPathComponent.count > "utterink-live-model-".count,
              !FileManager.default.fileExists(atPath: root.path) else {
            throw LiveTestConfigurationError(
                "UTTERINK_LIVE_MODEL_ROOT must be a fresh direct child of /private/tmp."
            )
        }

        guard let audioPath = environment["UTTERINK_LIVE_AUDIO_PATH"] else {
            throw LiveTestConfigurationError(
                "UTTERINK_LIVE_AUDIO_PATH must point to an isolated audio fixture."
            )
        }
        let audioURL = URL(fileURLWithPath: audioPath, isDirectory: false).standardizedFileURL
        let audioValues = try audioURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard audioURL.deletingLastPathComponent() == temporaryRoot,
              audioURL.lastPathComponent.hasPrefix("utterink-live-model-"),
              audioValues.isRegularFile == true,
              audioValues.isSymbolicLink != true,
              FileManager.default.isReadableFile(atPath: audioURL.path) else {
            throw LiveTestConfigurationError(
                "UTTERINK_LIVE_AUDIO_PATH must be a regular fixture directly under /private/tmp."
            )
        }

        let expectedKeywords = Set(
            environment["UTTERINK_LIVE_EXPECTED_KEYWORDS", default: "americans,country,ask"]
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        guard expectedKeywords.count >= 2,
              expectedKeywords.allSatisfy({
                  $0.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) == nil
              }) else {
            throw LiveTestConfigurationError(
                "UTTERINK_LIVE_EXPECTED_KEYWORDS must contain at least two distinct single words."
            )
        }

        guard WhisperModelCatalog.bundled.descriptors.contains(where: { $0.id == modelID }) else {
            throw LiveTestConfigurationError("Unknown live model ID: \(modelID)")
        }
        return LiveTestConfiguration(
            root: root,
            audioURL: audioURL,
            expectedKeywords: expectedKeywords
        )
    }

    private func makeXCTestSubprocess(
        selectedTest: String,
        environment: [String: String],
        workerEnvironmentKey: String,
        inheritsOutput: Bool
    ) throws -> Process {
        let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun", isDirectory: false)
            .standardizedFileURL
        let xcrunValues = try xcrun.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard xcrunValues.isRegularFile == true,
              xcrunValues.isSymbolicLink != true,
              FileManager.default.isExecutableFile(atPath: xcrun.path) else {
            throw LiveTestConfigurationError("Could not locate the macOS xcrun executable.")
        }

        let process = Process()
        process.executableURL = xcrun
        process.arguments = [
            "xctest",
            "-XCTest",
            selectedTest,
            try currentTestBundle().path
        ]
        var workerEnvironment = environment
        workerEnvironment[workerEnvironmentKey] = String(getpid())
        process.environment = workerEnvironment
        process.currentDirectoryURL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        if inheritsOutput {
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        return process
    }

    private func currentTestBundle() throws -> URL {
        let bundle = Bundle(for: Self.self).bundleURL.standardizedFileURL
        let values = try bundle.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard bundle.pathExtension == "xctest",
              values.isDirectory == true,
              values.isSymbolicLink != true else {
            throw LiveTestConfigurationError("Could not identify the current XCTest bundle.")
        }
        return bundle
    }

    private func waitForProcessExit(
        _ process: Process,
        timeout: Duration
    ) async -> WorkerWaitOutcome {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while process.isRunning {
            guard !Task.isCancelled else { return .parentCancelled }
            guard clock.now < deadline else { return .deadlineReached }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return .parentCancelled
            }
        }
        return .exited
    }

    private func terminateAndReap(_ process: Process) -> Bool {
        guard process.isRunning else {
            process.waitUntilExit()
            return true
        }

        process.terminate()
        if waitSynchronouslyForExit(process, timeout: 2) {
            process.waitUntilExit()
            return true
        }

        let signalResult = Darwin.kill(process.processIdentifier, SIGKILL)
        guard signalResult == 0 || errno == ESRCH,
              waitSynchronouslyForExit(process, timeout: 10) else {
            return false
        }
        process.waitUntilExit()
        return true
    }

    private func waitSynchronouslyForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !process.isRunning
    }

    private func removeTemporaryRoot(_ root: URL) {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            XCTFail("Live model test could not remove its isolated temporary directory.")
        }
    }
}

private struct LiveTestConfiguration {
    let root: URL
    let audioURL: URL
    let expectedKeywords: Set<String>
}

private struct LiveTestConfigurationError: LocalizedError {
    let errorDescription: String?

    init(_ description: String) {
        errorDescription = description
    }
}

private enum WorkerWaitOutcome: Equatable {
    case exited
    case deadlineReached
    case parentCancelled
}

private enum IsolatedTranscriptionOutcome {
    case success(String)
    case failure(String)
    case deadlineReached
}

private actor TranscriptionOutcomeGate {
    private var outcome: IsolatedTranscriptionOutcome?
    private var waiter: CheckedContinuation<IsolatedTranscriptionOutcome, Never>?

    func wait() async -> IsolatedTranscriptionOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation in
            if let outcome {
                continuation.resume(returning: outcome)
            } else {
                waiter = continuation
            }
        }
    }

    func resolve(_ newOutcome: IsolatedTranscriptionOutcome) {
        guard outcome == nil else { return }
        outcome = newOutcome
        let pendingWaiter = waiter
        waiter = nil
        pendingWaiter?.resume(returning: newOutcome)
    }
}
