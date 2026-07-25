import Foundation
import XCTest
@testable import UtterInkCore

@MainActor
final class DictationSessionControllerTests: XCTestCase {
    func testEndToEndOrderingAndDeliveryPreferenceAreImmutable() async {
        let log = EventLog()
        let harness = Harness(
            settings: polishedSettings(preference: .copyOnly),
            target: .external(DeliveryTargetID()),
            log: log
        )
        await harness.bootstrapWithVolatileProbe()

        harness.controller.send(.start(.focusedExternal))
        await waitUntil { harness.controller.state.stage == .recording }
        XCTAssertEqual(
            harness.controller.sessionPresentation?.destination,
            .external
        )
        await harness.settings.setDeliveryPreference(.automaticPaste)
        harness.controller.send(.stop)
        await waitUntil {
            harness.controller.state.stage == .completed
                && harness.controller.sessionPresentation == nil
        }

        let orderedEvents = await log.values()
        XCTAssertEqual(
            orderedEvents,
            [
                "volatile.raw",
                "history.appendRaw",
                "polish.request",
                "history.updateFinal",
                "delivery.request",
                "history.updateDelivery"
            ]
        )
        let calls = await harness.delivery.deliveryCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].preference, .copyOnly)
        XCTAssertEqual(calls[0].target, harness.initialTarget)
        XCTAssertEqual(harness.controller.state.result?.delivery, .copiedByPreference)
        XCTAssertEqual(harness.controller.state.result?.persistence, .persistent)
        let acquireCount = await harness.models.acquireCount()
        let releaseCount = await harness.models.releaseCount()
        XCTAssertEqual(acquireCount, 1)
        XCTAssertEqual(releaseCount, 1)
    }

    func testActiveSnapshotKeepsLanguageModelOutputProviderAndDeliveryImmutable() async throws {
        let initial = polishedSettingsWithProvider()
        let harness = Harness(settings: initial)
        let profileID = try XCTUnwrap(initial.selectedProviderProfileID)
        try await harness.credentials.write(
            SessionSecret(utf8: "fixture-key"),
            profileID: profileID
        )
        await harness.bootstrapWithVolatileProbe()

        harness.controller.send(.start(.focusedExternal))
        await waitUntil { harness.controller.state.stage == .recording }

        var future = initial
        future.recognition = .automatic
        future.speechModelID = "base"
        future.selectedOutputModeID = OutputMode.rawID
        future.providerProfiles = []
        future.selectedProviderProfileID = nil
        future.deliveryPreference = .copyOnly
        await harness.settings.replace(with: future)

        harness.controller.send(.stop)
        await waitUntil { harness.controller.state.stage == .completed }

        let receivedSnapshots = await harness.polishing.receivedSnapshots()
        let captured = try XCTUnwrap(receivedSnapshots.first)
        let expectedOutput = try XCTUnwrap(
            initial.outputModes.first { $0.id == initial.selectedOutputModeID }
        )
        let expectedProfile = try XCTUnwrap(initial.providerProfiles.first)
        XCTAssertEqual(captured.recognition, initial.recognition)
        XCTAssertEqual(captured.speechModelID, initial.speechModelID)
        XCTAssertEqual(captured.outputMode, expectedOutput)
        XCTAssertEqual(
            captured.provider,
            ProviderSelection(
                profileID: expectedProfile.id,
                baseURL: expectedProfile.baseURL,
                modelID: expectedProfile.modelID,
                policy: expectedProfile.policy
            )
        )
        XCTAssertEqual(captured.deliveryPreference, initial.deliveryPreference)
    }

    func testDuplicateStartDoesNotCreateSecondSession() async {
        let harness = Harness(settings: rawSettings(), target: .external(DeliveryTargetID()))
        await harness.bootstrapWithVolatileProbe()

        harness.controller.send(.start(.focusedExternal))
        harness.controller.send(.start(.focusedExternal))
        await waitUntil { harness.controller.state.stage == .recording }

        let targetCount = await harness.target.snapshotCount()
        let audioStarts = await harness.audio.startCount()
        XCTAssertEqual(targetCount, 1)
        XCTAssertEqual(audioStarts, 1)
    }

    func testModelNotReadyCreatesNoSessionOrTargetCapture() async {
        let models = ModelFake(state: .missing(modelID: "small"))
        let harness = Harness(settings: rawSettings(), models: models)
        await harness.bootstrapWithVolatileProbe()

        harness.controller.send(.start(.focusedExternal))
        await settle()

        XCTAssertEqual(harness.controller.state, .idle)
        let targetCount = await harness.target.snapshotCount()
        let audioStarts = await harness.audio.startCount()
        XCTAssertEqual(targetCount, 0)
        XCTAssertEqual(audioStarts, 0)
    }

    func testMicrophoneDenialFailsWithGuidanceAndNoCapture() async {
        let audio = AudioFake(permission: .denied)
        let harness = Harness(settings: rawSettings(), audio: audio)
        await harness.bootstrapWithVolatileProbe()

        harness.controller.send(.start(.focusedExternal))
        await waitUntil { harness.controller.state.stage == .failed }

        XCTAssertEqual(harness.controller.state.failure?.code, .permissionMicrophone)
        let audioStarts = await audio.startCount()
        let deliveryCount = await harness.delivery.deliveryCalls().count
        XCTAssertEqual(audioStarts, 0)
        XCTAssertEqual(deliveryCount, 0)
    }

    func testHistoryAppendFailureStopsPolishingAndDeliveryButKeepsRawVolatile() async {
        let history = HistoryFake()
        await history.setFailAppend(true)
        let harness = Harness(settings: polishedSettings(), history: history)
        await harness.bootstrapWithVolatileProbe()

        await harness.driveThroughRecordingAndStop()
        await waitUntil { harness.controller.state.stage == .failed }

        XCTAssertEqual(harness.controller.state.failure?.code, .historyWrite)
        XCTAssertEqual(harness.controller.volatileResults.first?.rawText, "raw transcript")
        let polishCount = await harness.polishing.callCount()
        let deliveryCount = await harness.delivery.deliveryCalls().count
        XCTAssertEqual(polishCount, 0)
        XCTAssertEqual(deliveryCount, 0)
    }

    func testPolishFailureDeliversDurableRawWithSanitizedWarning() async {
        let polishing = PolishingFake(failure: .polishTransport)
        let harness = Harness(settings: polishedSettings(), polishing: polishing)
        await harness.bootstrapWithVolatileProbe()

        await harness.driveThroughRecordingAndStop()
        await waitUntil { harness.controller.state.stage == .completed }

        XCTAssertEqual(harness.controller.state.result?.finalText, "raw transcript")
        XCTAssertEqual(harness.controller.state.result?.source, .rawFallback)
        XCTAssertEqual(harness.controller.state.result?.warning, .polishTransport)
        let deliveryCount = await harness.delivery.deliveryCalls().count
        XCTAssertEqual(deliveryCount, 1)
    }

    func testCredentialReadFailureStillRunsLocalPipelineAndDeliversRawFallback() async {
        let credentials = CredentialFake(readFailure: true)
        let polishing = PolishingFake(failure: .credentialMissing)
        let harness = Harness(
            settings: polishedSettingsWithProvider(),
            credentials: credentials,
            polishing: polishing
        )
        await harness.bootstrapWithVolatileProbe()

        await harness.driveThroughRecordingAndStop()
        await waitUntil { harness.controller.state.stage == .completed }

        let deliveryCount = await harness.delivery.deliveryCalls().count
        XCTAssertEqual(harness.controller.state.result?.finalText, "raw transcript")
        XCTAssertEqual(harness.controller.state.result?.source, .rawFallback)
        XCTAssertEqual(harness.controller.state.result?.warning, .polishInvalidResponse)
        XCTAssertEqual(deliveryCount, 1)
    }

    func testDeliveryHistoryFailureDoesNotDispatchTwice() async {
        let history = HistoryFake()
        await history.setFailDeliveryUpdate(true)
        let harness = Harness(settings: rawSettings(), history: history)
        await harness.bootstrapWithVolatileProbe()

        await harness.driveThroughRecordingAndStop()
        await waitUntil { harness.controller.state.stage == .completed }

        let calls = await harness.delivery.deliveryCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(harness.controller.state.result?.warning, .historyWrite)
    }

    func testAutomaticPasteUsesSnapshottedCopyOnlyTargetAndPreference() async {
        let harness = Harness(
            settings: rawSettings(preference: .automaticPaste),
            target: .copyOnly
        )
        await harness.bootstrapWithVolatileProbe()

        harness.controller.send(.start(.focusedExternal))
        await waitUntil { harness.controller.state.stage == .recording }
        XCTAssertEqual(
            harness.controller.sessionPresentation?.destination,
            .copyOnlyFallback
        )
        await harness.settings.setDeliveryPreference(.copyOnly)
        harness.controller.send(.stop)
        await waitUntil { harness.controller.state.stage == .completed }

        let calls = await harness.delivery.deliveryCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].target, .copyOnly)
        XCTAssertEqual(calls[0].preference, .automaticPaste)
        XCTAssertEqual(calls[0].mutationCount, 0)
        XCTAssertEqual(
            harness.controller.state.result?.delivery,
            .manualCopyRequired(.deliveryTargetUnavailable)
        )
        let stored = await harness.history.records()
        XCTAssertEqual(stored.first?.outcome, .delivered)
        XCTAssertEqual(
            stored.first?.delivery,
            .manualCopyRequired(.deliveryTargetUnavailable)
        )
    }

    func testOnboardingSessionBypassesTargetResolverAndExternalDelivery() async {
        let harness = Harness(
            settings: rawSettings(preference: .automaticPaste),
            target: .external(DeliveryTargetID())
        )
        await harness.bootstrapWithVolatileProbe()

        harness.controller.send(.start(.onboardingTest))
        await waitUntil { harness.controller.state.stage == .recording }
        XCTAssertEqual(
            harness.controller.sessionPresentation?.destination,
            .onboardingTest
        )
        harness.controller.send(.stop)
        await waitUntil { harness.controller.state.stage == .completed }

        let targetCount = await harness.target.snapshotCount()
        XCTAssertEqual(targetCount, 0)
        let calls = await harness.delivery.deliveryCalls()
        XCTAssertEqual(calls.map(\.target), [.onboardingTest])
        XCTAssertEqual(harness.controller.state.result?.delivery, .deliveredToOnboardingTest)
    }

    func testOnboardingSessionForcesRawWithoutChangingSavedPolishingChoice() async {
        let configured = polishedSettingsWithProvider()
        let harness = Harness(
            settings: configured,
            target: .external(DeliveryTargetID())
        )
        await harness.bootstrapWithVolatileProbe()

        harness.controller.send(.start(.onboardingTest))
        await waitUntil { harness.controller.state.stage == .recording }
        harness.controller.send(.stop)
        await waitUntil { harness.controller.state.stage == .completed }

        let polishingCallCount = await harness.polishing.callCount()
        let calls = await harness.delivery.deliveryCalls()
        let savedSettings = await harness.settings.value()
        XCTAssertEqual(polishingCallCount, 0)
        XCTAssertEqual(calls.map(\.target), [.onboardingTest])
        XCTAssertEqual(calls.map(\.text), ["raw transcript"])
        XCTAssertEqual(harness.controller.state.result?.source, .raw)
        XCTAssertEqual(harness.controller.state.result?.finalText, "raw transcript")
        XCTAssertEqual(savedSettings.selectedOutputModeID, configured.selectedOutputModeID)
    }

    func testCancelAwaitsInFlightEffectBeforeCleanupAndPersistsCancelledOutcome() async {
        let gate = AsyncGate()
        let polishing = PolishingFake(gate: gate)
        let harness = Harness(settings: polishedSettings(), polishing: polishing)
        await harness.bootstrapWithVolatileProbe()

        await harness.driveThroughRecordingAndStop()
        await gate.waitUntilEntered()
        harness.controller.send(.cancel)
        harness.controller.send(.start(.focusedExternal))
        await settle()
        let targetCountBeforeCleanup = await harness.target.snapshotCount()
        XCTAssertEqual(targetCountBeforeCleanup, 1, "cleanup barrier rejects a new start")

        await gate.open()
        await waitUntil {
            harness.controller.sessionPresentation == nil
                && harness.controller.state.stage == .completed
        }
        let deliveryCount = await harness.delivery.deliveryCalls().count
        let cancelledRecords = await harness.history.records()
        XCTAssertEqual(deliveryCount, 0)
        XCTAssertEqual(cancelledRecords.first?.outcome, .cancelled)
        XCTAssertEqual(cancelledRecords.first?.warning, .cancelled)

        harness.controller.send(.start(.focusedExternal))
        await waitUntil { harness.controller.state.stage == .recording }
        let targetCountAfterCleanup = await harness.target.snapshotCount()
        XCTAssertEqual(targetCountAfterCleanup, 2)
    }

    func testCancelAfterRawAppendCommitsMarksOverlayPersistentAndCancelled() async {
        let returnGate = AsyncGate()
        let history = HistoryFake(appendReturnGate: returnGate)
        let harness = Harness(settings: rawSettings(), history: history)
        await harness.bootstrapWithVolatileProbe()

        await harness.driveThroughRecordingAndStop()
        await returnGate.waitUntilEntered()
        harness.controller.send(.cancel)
        await returnGate.open()
        await waitUntil {
            harness.controller.state.stage == .completed
                && harness.controller.sessionPresentation == nil
        }

        let stored = await history.records()
        XCTAssertEqual(harness.controller.state.result?.persistence, .persistent)
        XCTAssertEqual(harness.controller.volatileResults.first?.persistence, .persistent)
        XCTAssertEqual(stored.first?.outcome, .cancelled)
        XCTAssertEqual(stored.first?.warning, .cancelled)
        let deliveryCount = await harness.delivery.deliveryCalls().count
        XCTAssertEqual(deliveryCount, 0)
    }

    func testCopyAndPasteAgainUseExistingResultAndFreshTargetWithoutRepipeline() async {
        let id = SessionID()
        let record = historyRecord(id: id, final: "saved final")
        let history = HistoryFake(records: [record])
        let target = TargetFake(target: .external(DeliveryTargetID()))
        let harness = Harness(
            settings: rawSettings(preference: .copyOnly),
            targetService: target,
            history: history
        )
        await harness.bootstrapWithVolatileProbe()

        harness.controller.send(.copyResult(id))
        await waitUntil { await harness.delivery.explicitCalls().count == 1 }
        let explicitCalls = await harness.delivery.explicitCalls()
        let copiedRecords = await history.records()
        let polishCountAfterCopy = await harness.polishing.callCount()
        XCTAssertEqual(explicitCalls.first?.text, "saved final")
        XCTAssertEqual(copiedRecords.first?.delivery, .copiedByUser)
        XCTAssertEqual(polishCountAfterCopy, 0)

        await target.setTarget(.copyOnly)
        harness.controller.send(.pasteAgain(id))
        await waitUntil { await harness.delivery.deliveryCalls().count == 1 }
        let recordedPaste = await harness.delivery.deliveryCalls()
        let paste = try? XCTUnwrap(recordedPaste.first)
        XCTAssertEqual(paste?.text, "saved final")
        XCTAssertEqual(paste?.target, .copyOnly)
        XCTAssertEqual(paste?.preference, .automaticPaste)
        XCTAssertEqual(paste?.mutationCount, 0)
        let finalRecords = await history.records()
        let finalPolishCount = await harness.polishing.callCount()
        XCTAssertEqual(finalRecords.count, 1)
        XCTAssertEqual(finalPolishCount, 0)
    }

    func testMissingAndDeletedResultActionsHaveZeroMutationAndCannotResurrect() async {
        let id = SessionID()
        let history = HistoryFake(records: [historyRecord(id: id, final: "kept")])
        let harness = Harness(settings: rawSettings(), history: history)
        await harness.bootstrapWithVolatileProbe()

        harness.controller.send(.deleteResult(id))
        await waitUntil { await history.records().isEmpty }
        harness.controller.send(.copyResult(id))
        harness.controller.send(.pasteAgain(id))
        harness.controller.send(.retryPolishing(id))
        await settle()

        XCTAssertTrue(harness.controller.volatileResults.isEmpty)
        XCTAssertTrue(harness.controller.historyRecords.isEmpty)
        let explicitCount = await harness.delivery.explicitCalls().count
        let automaticCount = await harness.delivery.deliveryCalls().count
        let polishCount = await harness.polishing.callCount()
        XCTAssertEqual(explicitCount, 0)
        XCTAssertEqual(automaticCount, 0)
        XCTAssertEqual(polishCount, 0)
        XCTAssertEqual(harness.controller.state.failure?.code, .historyWrite)
    }

    func testSpeechModelPreparationIgnoresOlderGenerationAndCancelIsExactlyOnce() async {
        let models = ModelFake(state: .ready(modelID: "small"))
        let harness = Harness(settings: rawSettings(), models: models)
        await harness.bootstrapWithVolatileProbe()
        XCTAssertEqual(harness.controller.activeSpeechModelID, "small")

        harness.controller.prepareSpeechModel("base")
        XCTAssertEqual(harness.controller.preparingSpeechModelID, "base")
        XCTAssertEqual(harness.controller.speechModelState, .missing(modelID: "base"))
        await waitUntil { await models.prepareCount() == 1 }
        await models.emit(call: 1, .missing(modelID: "base"))
        await waitUntil { harness.controller.speechModelState == .missing(modelID: "base") }
        await models.emit(call: 1, .downloading(modelID: "base", progress: 0.5))
        await waitUntil {
            harness.controller.speechModelState == .downloading(modelID: "base", progress: 0.5)
        }
        XCTAssertEqual(harness.controller.activeSpeechModelID, "small")

        harness.controller.prepareSpeechModel("large-v3")
        await waitUntil { await models.prepareCount() == 2 }
        await models.emit(call: 2, .loading(modelID: "large-v3"))
        await models.emit(call: 2, .ready(modelID: "large-v3"))
        await waitUntil { harness.controller.speechModelState == .ready(modelID: "large-v3") }
        XCTAssertEqual(harness.controller.activeSpeechModelID, "large-v3")
        await models.emit(call: 1, .failed(modelID: "base", code: .transcriptionFailed, retryable: true))
        await settle()
        XCTAssertEqual(harness.controller.speechModelState, .ready(modelID: "large-v3"))

        harness.controller.prepareSpeechModel("base")
        await waitUntil { await models.prepareCount() == 3 }
        harness.controller.cancelSpeechModelPreparation()
        harness.controller.cancelSpeechModelPreparation()
        await waitUntil { await models.cancelCount() == 1 }
        XCTAssertNil(harness.controller.preparingSpeechModelID)
        XCTAssertEqual(harness.controller.activeSpeechModelID, "large-v3")
        XCTAssertEqual(
            harness.controller.speechModelState,
            .failed(modelID: "base", code: .cancelled, retryable: true)
        )
    }

    func testCancelReplacesDownloadingStateAndSuppressesStalePreparationCallbacks() async {
        let models = ModelFake(state: .ready(modelID: "small"))
        let harness = Harness(settings: rawSettings(), models: models)
        await harness.bootstrapWithVolatileProbe()

        harness.controller.prepareSpeechModel("base")
        await waitUntil { await models.prepareCount() == 1 }
        await models.emit(call: 1, .downloading(modelID: "base", progress: 0.4))
        await waitUntil {
            harness.controller.speechModelState == .downloading(modelID: "base", progress: 0.4)
        }

        harness.controller.cancelSpeechModelPreparation()
        XCTAssertEqual(
            harness.controller.speechModelState,
            .failed(modelID: "base", code: .cancelled, retryable: true)
        )
        XCTAssertNil(harness.controller.preparingSpeechModelID)
        XCTAssertEqual(harness.controller.activeSpeechModelID, "small")

        await models.emit(call: 1, .loading(modelID: "base"))
        await settle()
        XCTAssertEqual(
            harness.controller.speechModelState,
            .failed(modelID: "base", code: .cancelled, retryable: true)
        )
        await waitUntil { await models.cancelCount() == 1 }
    }

    func testModelPreparationIsRejectedDuringSessionAndDeletionChecksFreshSelection() async {
        let models = ModelFake(state: .ready(modelID: "small"))
        let harness = Harness(settings: rawSettings(), models: models)
        await harness.bootstrapWithVolatileProbe()
        harness.controller.send(.start(.focusedExternal))
        await waitUntil { harness.controller.state.stage == .recording }

        harness.controller.prepareSpeechModel("base")
        await settle()
        let prepareCount = await models.prepareCount()
        XCTAssertEqual(prepareCount, 0)

        await harness.settings.setSpeechModelID("base")
        harness.controller.deleteCachedSpeechModel("base")
        await settle()
        let deletedAfterFreshSelection = await models.deletedModelIDs()
        XCTAssertEqual(deletedAfterFreshSelection, [])
        harness.controller.deleteCachedSpeechModel("small")
        await settle()
        let deletedWhileActive = await models.deletedModelIDs()
        XCTAssertEqual(deletedWhileActive, [], "active model cannot be deleted")
    }

    func testSessionStartIsRejectedUntilModelPreparationCancellationFinishes() async {
        let models = ModelFake(state: .ready(modelID: "small"))
        let harness = Harness(settings: rawSettings(), models: models)
        await harness.bootstrapWithVolatileProbe()

        harness.controller.prepareSpeechModel("base")
        await waitUntil { await models.prepareCount() == 1 }
        harness.controller.send(.start(.focusedExternal))
        await settle()
        let capturesDuringPreparation = await harness.target.snapshotCount()
        XCTAssertEqual(capturesDuringPreparation, 0)

        harness.controller.cancelSpeechModelPreparation()
        await waitUntil { await models.cancelCount() == 1 }
        await settle()
        harness.controller.send(.start(.focusedExternal))
        await waitUntil { harness.controller.state.stage == .recording }
        let capturesAfterCancellation = await harness.target.snapshotCount()
        XCTAssertEqual(capturesAfterCancellation, 1)
    }

    func testModelDeletionForwardsOnlyInactiveUnselectedIDsAndKeepsReadinessOnFailure() async {
        let models = ModelFake(state: .ready(modelID: "small"))
        let harness = Harness(settings: rawSettings(), models: models)
        await harness.bootstrapWithVolatileProbe()

        harness.controller.deleteCachedSpeechModel("small")
        await settle()
        let selectedDeletionCalls = await models.deletedModelIDs()
        XCTAssertEqual(selectedDeletionCalls, [])

        harness.controller.deleteCachedSpeechModel("base")
        await waitUntil { await models.deletedModelIDs() == ["base"] }

        await models.setDeleteFailure(.audioStart)
        harness.controller.deleteCachedSpeechModel("large-v3")
        await waitUntil {
            harness.controller.speechModelCacheActionStatus
                == .deleteFailed(modelID: "large-v3")
        }
        XCTAssertEqual(harness.controller.speechModelState, .ready(modelID: "small"))
        XCTAssertEqual(harness.controller.activeSpeechModelID, "small")
    }

    func testCachedModelSnapshotTracksBootstrapDeletionAndSuccessfulPreparation() async {
        let models = ModelFake(
            state: .ready(modelID: "small"),
            cachedModelIDs: ["base", "small"]
        )
        let harness = Harness(settings: rawSettings(), models: models)

        await harness.bootstrapWithVolatileProbe()

        XCTAssertEqual(harness.controller.cachedSpeechModelIDs, ["base", "small"])

        harness.controller.deleteCachedSpeechModel("base")
        await waitUntil { await models.deletedModelIDs() == ["base"] }
        await waitUntil { !harness.controller.cachedSpeechModelIDs.contains("base") }
        XCTAssertEqual(harness.controller.cachedSpeechModelIDs, ["small"])

        harness.controller.prepareSpeechModel("large-v3")
        await waitUntil { await models.prepareCount() == 1 }
        await models.emit(call: 1, .ready(modelID: "large-v3"))
        await waitUntil {
            harness.controller.cachedSpeechModelIDs.contains("large-v3")
        }
        XCTAssertEqual(
            harness.controller.cachedSpeechModelIDs,
            ["large-v3", "small"]
        )
    }

    func testBootstrapRetainsMismatchedReadyModelAsProtectedActiveCache() async {
        var settings = rawSettings()
        settings.speechModelID = "base"
        let models = ModelFake(state: .ready(modelID: "small"))
        let harness = Harness(settings: settings, models: models)
        await harness.bootstrapWithVolatileProbe()
        await waitUntil { await models.cachedPrepareCount() == 1 }
        await waitUntil { harness.controller.preparingSpeechModelID == nil }

        XCTAssertEqual(harness.controller.speechModelState, .missing(modelID: "base"))
        XCTAssertEqual(harness.controller.activeSpeechModelID, "small")
        XCTAssertNil(harness.controller.preparingSpeechModelID)
        let cachedPreparationCount = await models.cachedPrepareCount()
        let explicitPreparationCount = await models.prepareCount()
        let cachedPreparationIDs = await models.cachedPreparedModelIDs()
        XCTAssertEqual(cachedPreparationCount, 1)
        XCTAssertEqual(explicitPreparationCount, 0)
        XCTAssertEqual(cachedPreparationIDs, ["base"])

        harness.controller.deleteCachedSpeechModel("small")
        await settle()
        let deletedModelIDs = await models.deletedModelIDs()
        XCTAssertTrue(deletedModelIDs.isEmpty)
    }

    func testBootstrapLoadsSelectedCachedModelWithoutExplicitPreparation() async {
        var settings = rawSettings()
        settings.speechModelID = "base"
        let models = ModelFake(
            state: .ready(modelID: "small"),
            cachedModelIDs: ["base"]
        )
        let harness = Harness(settings: settings, models: models)

        await harness.bootstrapWithVolatileProbe()
        await waitUntil { await models.cachedPrepareCount() == 1 }

        XCTAssertEqual(harness.controller.speechModelState, .missing(modelID: "base"))
        XCTAssertEqual(harness.controller.preparingSpeechModelID, "base")
        XCTAssertEqual(harness.controller.activeSpeechModelID, "small")
        let explicitPreparationCount = await models.prepareCount()
        let cachedPreparationIDs = await models.cachedPreparedModelIDs()
        XCTAssertEqual(explicitPreparationCount, 0)
        XCTAssertEqual(cachedPreparationIDs, ["base"])

        await models.emit(call: 1, .loading(modelID: "base"))
        await models.emit(call: 1, .ready(modelID: "base"))
        await waitUntil {
            harness.controller.speechModelState == .ready(modelID: "base")
        }

        XCTAssertEqual(harness.controller.speechModelState, .ready(modelID: "base"))
        XCTAssertEqual(harness.controller.activeSpeechModelID, "base")
        XCTAssertNil(harness.controller.preparingSpeechModelID)
    }

    func testPreviouslySelectedModelCanBeDeletedAfterFreshSelectionBecomesReady() async {
        let models = ModelFake(state: .ready(modelID: "small"))
        let harness = Harness(settings: rawSettings(), models: models)
        await harness.bootstrapWithVolatileProbe()

        await harness.settings.setSpeechModelID("base")
        harness.controller.prepareSpeechModel("base")
        await waitUntil { await models.prepareCount() == 1 }
        await models.emit(call: 1, .ready(modelID: "base"))
        await waitUntil { harness.controller.activeSpeechModelID == "base" }

        harness.controller.deleteCachedSpeechModel("small")

        await waitUntil { await models.deletedModelIDs() == ["small"] }
    }

    func testPreparationIsRejectedWhileSameModelCacheDeletionIsInFlight() async {
        let deletionGate = AsyncGate()
        let models = ModelFake(
            state: .ready(modelID: "small"),
            deleteGate: deletionGate
        )
        let harness = Harness(settings: rawSettings(), models: models)
        await harness.bootstrapWithVolatileProbe()

        harness.controller.deleteCachedSpeechModel("base")
        await deletionGate.waitUntilEntered()
        XCTAssertEqual(
            harness.controller.speechModelCacheActionStatus,
            .deleting(modelID: "base")
        )

        harness.controller.prepareSpeechModel("base")
        await settle()

        let prepareCount = await models.prepareCount()
        XCTAssertEqual(prepareCount, 0)
        XCTAssertNil(harness.controller.preparingSpeechModelID)
        XCTAssertEqual(harness.controller.speechModelState, .ready(modelID: "small"))
        await deletionGate.open()
        await waitUntil { await models.deletedModelIDs() == ["base"] }
    }

    func testDisableKeepsExistingHistoryAndClearImmediatelyRemovesAllResults() async {
        let id = SessionID()
        let history = HistoryFake(records: [historyRecord(id: id, final: "saved")])
        let harness = Harness(settings: rawSettings(), history: history)
        await harness.bootstrapWithVolatileProbe()

        harness.controller.send(.setHistoryEnabled(false))
        await waitUntil { await harness.settings.value().historyEnabled == false }
        XCTAssertEqual(harness.controller.historyRecords.map(\.sessionID), [id])

        harness.controller.send(.clearHistory)
        await waitUntil { await history.records().isEmpty }
        XCTAssertTrue(harness.controller.historyRecords.isEmpty)
        XCTAssertTrue(harness.controller.volatileResults.isEmpty)
    }

    func testRapidHistoryDisableThenEnableExecutesInIntentOrder() async {
        let gate = AsyncGate()
        let history = HistoryFake(setEnabledGate: gate)
        let harness = Harness(settings: rawSettings(), history: history)
        await harness.bootstrapWithVolatileProbe()

        harness.controller.send(.setHistoryEnabled(false))
        await gate.waitUntilEntered()
        harness.controller.send(.setHistoryEnabled(true))
        await settle()

        let callsWhileDisabledIsBlocked = await history.setEnabledCalls()
        XCTAssertEqual(callsWhileDisabledIsBlocked, [false])

        await gate.open()
        await waitUntil {
            let calls = await history.setEnabledCalls()
            let settings = await harness.settings.value()
            return calls == [false, true] && settings.historyEnabled
        }

        let finalSettings = await harness.settings.value()
        let finalHistoryEnabled = await history.isEnabled()
        let finalGeneration = await history.generation()
        XCTAssertTrue(finalSettings.historyEnabled)
        XCTAssertTrue(finalHistoryEnabled)
        XCTAssertEqual(finalGeneration, 3)
        XCTAssertEqual(harness.controller.historyControlStatus, .settled(enabled: true))
    }

    func testRapidHistoryEnableThenDisableExecutesInIntentOrder() async {
        let gate = AsyncGate()
        let history = HistoryFake(enabled: false, setEnabledGate: gate)
        let harness = Harness(
            settings: rawSettings(historyEnabled: false),
            history: history
        )
        await harness.bootstrapWithVolatileProbe()

        harness.controller.send(.setHistoryEnabled(true))
        await gate.waitUntilEntered()
        harness.controller.send(.setHistoryEnabled(false))
        await settle()
        let callsWhileEnableIsBlocked = await history.setEnabledCalls()
        XCTAssertEqual(callsWhileEnableIsBlocked, [true])

        await gate.open()
        await waitUntil {
            let calls = await history.setEnabledCalls()
            let settings = await harness.settings.value()
            return calls == [true, false] && !settings.historyEnabled
        }

        let finalSettings = await harness.settings.value()
        let finalHistoryEnabled = await history.isEnabled()
        let finalGeneration = await history.generation()
        XCTAssertFalse(finalSettings.historyEnabled)
        XCTAssertFalse(finalHistoryEnabled)
        XCTAssertEqual(finalGeneration, 3)
        XCTAssertEqual(harness.controller.historyControlStatus, .settled(enabled: false))
    }

    func testStaleEnableCannotReenableRuntimeWhileQueuedDisableIsBlocked() async throws {
        let disableGate = AsyncGate()
        let history = HistoryFake(enabled: false, secondSetEnabledGate: disableGate)
        let initial = polishedSettings()
        var disabledInitial = initial
        disabledInitial.historyEnabled = false
        let harness = Harness(settings: disabledInitial, history: history)
        await harness.bootstrapWithVolatileProbe()

        harness.controller.send(.setHistoryEnabled(true))
        harness.controller.send(.setHistoryEnabled(false))
        await disableGate.waitUntilEntered()

        harness.controller.send(.start(.focusedExternal))
        await waitUntil { harness.controller.state.stage == .recording }
        XCTAssertEqual(harness.controller.historyControlStatus, .applying(enabled: false))

        await disableGate.open()
        await waitUntil {
            let settings = await harness.settings.value()
            return !settings.historyEnabled
                && harness.controller.historyControlStatus == .settled(enabled: false)
        }

        harness.controller.send(.stop)
        await waitUntil { !(await harness.polishing.receivedSnapshots()).isEmpty }

        let snapshots = await harness.polishing.receivedSnapshots()
        let captured = try XCTUnwrap(snapshots.first)
        XCTAssertFalse(captured.historyEnabled)
    }

    func testClearSuppressesStaleQueuedEnableRefresh() async {
        let gate = AsyncGate()
        let record = historyRecord(id: SessionID(), final: "saved")
        let history = HistoryFake(
            records: [record],
            enabled: false,
            setEnabledGate: gate
        )
        let harness = Harness(
            settings: rawSettings(historyEnabled: false),
            history: history
        )
        await harness.bootstrapWithVolatileProbe()

        harness.controller.send(.setHistoryEnabled(true))
        await gate.waitUntilEntered()
        harness.controller.send(.clearHistory)
        XCTAssertTrue(harness.controller.historyRecords.isEmpty)

        await gate.open()
        await waitUntil {
            let generation = await history.generation()
            let records = await history.records()
            return generation == 3 && records.isEmpty
        }

        let loadCalls = await history.loadCallCount()
        XCTAssertEqual(loadCalls, 1, "stale enable must not reload after Clear")
        XCTAssertTrue(harness.controller.historyRecords.isEmpty)
    }

    func testHistoryControlReportsApplyPreferenceAndClearFailuresHonestly() async {
        let applyHistory = HistoryFake()
        await applyHistory.setFailSetEnabled(true)
        let applyHarness = Harness(settings: rawSettings(), history: applyHistory)
        await applyHarness.bootstrapWithVolatileProbe()
        applyHarness.controller.send(.setHistoryEnabled(false))
        await waitUntil {
            applyHarness.controller.historyControlStatus
                == .failed(enabled: true, failure: .applyFailed)
        }

        let preferenceHistory = HistoryFake()
        let preferenceHarness = Harness(settings: rawSettings(), history: preferenceHistory)
        await preferenceHarness.bootstrapWithVolatileProbe()
        await preferenceHarness.settings.setFailUpdate(true)
        preferenceHarness.controller.send(.setHistoryEnabled(false))
        await waitUntil {
            preferenceHarness.controller.historyControlStatus
                == .failed(enabled: false, failure: .preferenceSaveFailed)
        }
        let preferenceRuntimeEnabled = await preferenceHistory.isEnabled()
        XCTAssertFalse(preferenceRuntimeEnabled)

        let clearHistory = HistoryFake(records: [historyRecord(id: SessionID(), final: "saved")])
        await clearHistory.setFailClear(true)
        let clearHarness = Harness(settings: rawSettings(), history: clearHistory)
        await clearHarness.bootstrapWithVolatileProbe()
        clearHarness.controller.send(.clearHistory)
        await waitUntil {
            clearHarness.controller.historyControlStatus
                == .failed(enabled: true, failure: .clearFailed)
        }
        XCTAssertTrue(clearHarness.controller.historyRecords.isEmpty)
    }

    func testHistoryAndOrdinaryAtomicMutationsCannotOverwriteEachOther() async throws {
        let settingsGate = AsyncGate()
        let harness = Harness(
            settings: rawSettings(),
            settingsUpdateGate: settingsGate
        )
        await harness.bootstrapWithVolatileProbe()

        harness.controller.send(.setHistoryEnabled(false))
        await settingsGate.waitUntilEntered()
        let ordinary = Task {
            try await harness.settings.update {
                $0.deliveryPreference = .copyOnly
            }
        }
        await settle()

        let callsWhileHistoryMutationIsBlocked = await harness.settings.updateCallCount()
        XCTAssertEqual(callsWhileHistoryMutationIsBlocked, 1)

        await settingsGate.open()
        _ = try await ordinary.value
        await waitUntil {
            harness.controller.historyControlStatus == .settled(enabled: false)
        }

        let final = await harness.settings.value()
        XCTAssertFalse(final.historyEnabled)
        XCTAssertEqual(final.deliveryPreference, .copyOnly)
    }

    func testDisableImmediatelyInvalidatesInFlightAppendAndStopsAutomation() async {
        let gate = AsyncGate()
        let existing = historyRecord(id: SessionID(), final: "existing")
        let history = HistoryFake(records: [existing], appendGate: gate)
        let harness = Harness(settings: polishedSettings(), history: history)
        await harness.bootstrapWithVolatileProbe()

        await harness.driveThroughRecordingAndStop()
        await gate.waitUntilEntered()
        harness.controller.send(.setHistoryEnabled(false))
        await waitUntil { await harness.settings.value().historyEnabled == false }
        await gate.open()
        await waitUntil { harness.controller.state.stage == .failed }

        let polishCount = await harness.polishing.callCount()
        let deliveryCount = await harness.delivery.deliveryCalls().count
        XCTAssertEqual(harness.controller.state.failure?.code, .historyWrite)
        XCTAssertEqual(polishCount, 0)
        XCTAssertEqual(deliveryCount, 0)
        XCTAssertEqual(harness.controller.historyRecords.map(\.sessionID), [existing.sessionID])
    }

    func testRetryWhileHistoryDisabledPublishesVolatileWithoutChangingDisk() async {
        let id = SessionID()
        let original = historyRecord(id: id, final: "saved final")
        let history = HistoryFake(records: [original])
        let harness = Harness(settings: polishedSettings(), history: history)
        await harness.bootstrapWithVolatileProbe()
        harness.controller.send(.setHistoryEnabled(false))
        await waitUntil { await harness.settings.value().historyEnabled == false }

        harness.controller.send(.retryPolishing(id))
        await waitUntil {
            harness.controller.volatileResults.first?.finalText == "polished transcript"
        }

        let stored = await history.records()
        XCTAssertEqual(harness.controller.volatileResults.first?.persistence, .volatile)
        XCTAssertEqual(stored.first?.finalText, "saved final")
        XCTAssertEqual(stored.first?.source, .polished)
    }
}

@MainActor
private final class Harness {
    let controller: DictationSessionController
    let settings: SettingsFake
    let target: TargetFake
    let history: HistoryFake
    let credentials: CredentialFake
    let audio: AudioFake
    let models: ModelFake
    let transcription: TranscriptionFake
    let polishing: PolishingFake
    let delivery: DeliveryFake
    let diagnostics: DiagnosticsFake
    let initialTarget: DeliveryTarget
    let log: EventLog

    init(
        settings initialSettings: UserSettings,
        settingsUpdateGate: AsyncGate? = nil,
        target initialTarget: DeliveryTarget = .external(DeliveryTargetID()),
        targetService: TargetFake? = nil,
        history: HistoryFake = HistoryFake(),
        credentials: CredentialFake = CredentialFake(),
        audio: AudioFake = AudioFake(),
        models: ModelFake = ModelFake(state: .ready(modelID: "small")),
        transcription: TranscriptionFake = TranscriptionFake(),
        polishing: PolishingFake = PolishingFake(),
        delivery: DeliveryFake? = nil,
        log: EventLog = EventLog()
    ) {
        self.settings = SettingsFake(initialSettings, firstUpdateGate: settingsUpdateGate)
        self.initialTarget = initialTarget
        self.log = log
        self.target = targetService ?? TargetFake(target: initialTarget)
        self.history = history
        self.credentials = credentials
        self.audio = audio
        self.models = models
        self.transcription = transcription
        self.polishing = polishing
        self.delivery = delivery ?? DeliveryFake(log: log)
        diagnostics = DiagnosticsFake()
        controller = DictationSessionController(
            settings: self.settings,
            target: self.target,
            permissions: PermissionFake(),
            history: history,
            credentials: credentials,
            audio: audio,
            models: models,
            transcription: transcription,
            polishing: polishing,
            delivery: self.delivery,
            diagnostics: diagnostics,
            modelCatalog: [
                SpeechModelDescriptor(
                    id: "base",
                    displayName: "Fast",
                    approximateBytes: 150_000_000,
                    preset: "Fast"
                ),
                SpeechModelDescriptor(
                    id: "small",
                    displayName: "Recommended",
                    approximateBytes: 500_000_000,
                    preset: "Recommended"
                ),
                SpeechModelDescriptor(
                    id: "large-v3",
                    displayName: "Best Quality",
                    approximateBytes: 1_600_000_000,
                    preset: "Best Quality"
                )
            ],
            clock: TestClock()
        )
    }

    func bootstrapWithVolatileProbe() async {
        let controller = controller
        await polishing.setLog(log)
        await history.setLog(log)
        await history.setRawProbe {
            await MainActor.run {
                controller.volatileResults.first?.rawText == "raw transcript"
            }
        }
        await controller.bootstrap()
    }

    func driveThroughRecordingAndStop() async {
        controller.send(.start(.focusedExternal))
        await waitUntil { self.controller.state.stage == .recording }
        controller.send(.stop)
    }
}

private actor EventLog {
    private var entries: [String] = []
    func append(_ value: String) { entries.append(value) }
    func values() -> [String] { entries }
}

private actor SettingsFake: SettingsStore {
    enum Failure: Error { case requested }

    private var settings: UserSettings
    private var failUpdate = false
    private let firstUpdateGate: AsyncGate?
    private var updateCalls = 0
    private var updateTail: Task<Void, Never>?

    init(_ settings: UserSettings, firstUpdateGate: AsyncGate? = nil) {
        self.settings = settings
        self.firstUpdateGate = firstUpdateGate
    }
    func current() async throws -> UserSettings { settings }
    func save(_ settings: UserSettings) async throws { self.settings = settings }
    func update(
        _ mutation: @escaping @Sendable (inout UserSettings) -> Void
    ) async throws -> UserSettings {
        let predecessor = updateTail
        let operation = Task<UserSettings, Error> {
            await predecessor?.value
            return try await self.performUpdate(mutation)
        }
        updateTail = Task { _ = try? await operation.value }
        return try await operation.value
    }
    private func performUpdate(
        _ mutation: @escaping @Sendable (inout UserSettings) -> Void
    ) async throws -> UserSettings {
        updateCalls += 1
        if updateCalls == 1, let firstUpdateGate {
            await firstUpdateGate.wait()
        }
        if failUpdate { throw Failure.requested }
        mutation(&settings)
        return settings
    }
    func updateCallCount() -> Int { updateCalls }
    func setFailUpdate(_ value: Bool) { failUpdate = value }
    func setDeliveryPreference(_ preference: DeliveryPreference) {
        settings.deliveryPreference = preference
    }
    func setSpeechModelID(_ id: String) { settings.speechModelID = id }
    func replace(with settings: UserSettings) { self.settings = settings }
    func value() -> UserSettings { settings }
}

private actor HistoryFake: HistoryStore {
    private var stored: [HistoryRecord]
    private var generationValue: UInt64 = 1
    private var enabled: Bool
    private var loads = 0
    private var failAppend = false
    private var failDeliveryUpdate = false
    private var failSetEnabled = false
    private var failClear = false
    private let appendGate: AsyncGate?
    private let appendReturnGate: AsyncGate?
    private let setEnabledGate: AsyncGate?
    private let secondSetEnabledGate: AsyncGate?
    private var enabledCalls: [Bool] = []
    private var log: EventLog?
    private var rawProbe: (@Sendable () async -> Bool)?

    init(
        records: [HistoryRecord] = [],
        enabled: Bool = true,
        appendGate: AsyncGate? = nil,
        appendReturnGate: AsyncGate? = nil,
        setEnabledGate: AsyncGate? = nil,
        secondSetEnabledGate: AsyncGate? = nil
    ) {
        stored = records
        self.enabled = enabled
        self.appendGate = appendGate
        self.appendReturnGate = appendReturnGate
        self.setEnabledGate = setEnabledGate
        self.secondSetEnabledGate = secondSetEnabledGate
    }

    func setLog(_ log: EventLog) { self.log = log }
    func setRawProbe(_ probe: @escaping @Sendable () async -> Bool) { rawProbe = probe }
    func setFailAppend(_ value: Bool) { failAppend = value }
    func setFailDeliveryUpdate(_ value: Bool) { failDeliveryUpdate = value }
    func setFailSetEnabled(_ value: Bool) { failSetEnabled = value }
    func setFailClear(_ value: Bool) { failClear = value }
    func records() -> [HistoryRecord] { stored }
    func setEnabledCalls() -> [Bool] { enabledCalls }
    func isEnabled() -> Bool { enabled }
    func loadCallCount() -> Int { loads }
    func generation() async -> UInt64 { generationValue }

    func appendRaw(_ record: HistoryRecord, expectedGeneration: UInt64) async throws {
        guard enabled, expectedGeneration == generationValue, !failAppend else {
            throw DiagnosticCode.historyWrite
        }
        if await rawProbe?() == true { await log?.append("volatile.raw") }
        if let appendGate { await appendGate.wait() }
        guard enabled, expectedGeneration == generationValue else {
            throw DiagnosticCode.historyWrite
        }
        await log?.append("history.appendRaw")
        stored.insert(record, at: 0)
        if let appendReturnGate { await appendReturnGate.wait() }
    }

    func updateResult(
        sessionID: SessionID,
        finalText: String,
        source: ResultSource,
        warning: DiagnosticCode?,
        delivery: DeliveryOutcome?,
        outcome: HistoryOutcome,
        expectedGeneration: UInt64
    ) async throws {
        guard enabled, expectedGeneration == generationValue,
              let index = stored.firstIndex(where: { $0.sessionID == sessionID }) else {
            throw DiagnosticCode.historyWrite
        }
        if failDeliveryUpdate, delivery != nil {
            throw DiagnosticCode.historyWrite
        }
        switch outcome {
        case .finalized:
            if delivery == nil { await log?.append("history.updateFinal") }
        case .delivered:
            await log?.append("history.updateDelivery")
        case .cancelled, .failed, .rawSaved:
            break
        }
        stored[index].finalText = finalText
        stored[index].source = source
        stored[index].warning = warning
        stored[index].delivery = delivery
        stored[index].outcome = outcome
    }

    func delete(sessionID: SessionID) async throws {
        stored.removeAll { $0.sessionID == sessionID }
    }

    func setEnabled(_ enabled: Bool) async throws -> UInt64 {
        enabledCalls.append(enabled)
        if enabledCalls.count == 1, let setEnabledGate {
            await setEnabledGate.wait()
        }
        if enabledCalls.count == 2, let secondSetEnabledGate {
            await secondSetEnabledGate.wait()
        }
        if failSetEnabled { throw DiagnosticCode.historyWrite }
        generationValue &+= 1
        self.enabled = enabled
        return generationValue
    }

    func clear() async throws -> UInt64 {
        if failClear { throw DiagnosticCode.historyWrite }
        generationValue &+= 1
        stored = []
        return generationValue
    }

    func load() async throws -> [HistoryRecord] {
        loads += 1
        return stored
    }
}

private actor CredentialFake: CredentialStore {
    private var values: [UUID: SessionSecret] = [:]
    private let readFailure: Bool
    init(readFailure: Bool = false) { self.readFailure = readFailure }
    func read(profileID: UUID) async throws -> SessionSecret? {
        if readFailure { throw DiagnosticCode.credentialMissing }
        return values[profileID]?.copy()
    }
    func write(_ secret: SessionSecret, profileID: UUID) async throws {
        values[profileID] = secret.copy()
    }
    func delete(profileID: UUID) async throws { values[profileID] = nil }
}

private actor AudioFake: AudioRecordingService {
    private let permission: PermissionState
    private var starts = 0
    private var cancels = 0
    private let handle = RecordingHandle()

    init(permission: PermissionState = .granted) { self.permission = permission }
    func requestPermission() async -> PermissionState { permission }
    func start(levels: @escaping @Sendable (Float) -> Void) async throws -> RecordingHandle {
        starts += 1
        levels(0.4)
        return handle
    }
    func stop(_ handle: RecordingHandle) async throws -> URL {
        URL(fileURLWithPath: "/private/tmp/utterink-controller-test.caf")
    }
    func cancel(_ handle: RecordingHandle) async { cancels += 1 }
    func startCount() -> Int { starts }
    func cancelCount() -> Int { cancels }
}

private actor ModelFake: SpeechModelService {
    private var current: SpeechModelState
    private var cachedIDs: Set<String>
    private var explicitPreparationIDs: [String] = []
    private var cachedPreparationIDs: [String] = []
    private var streamCalls = 0
    private var cancels = 0
    private var acquires = 0
    private var releases = 0
    private var deleted: [String] = []
    private var deleteFailure: DiagnosticCode?
    private let deleteGate: AsyncGate?
    private var continuations: [Int: AsyncStream<SpeechModelState>.Continuation] = [:]

    init(
        state: SpeechModelState,
        cachedModelIDs: Set<String> = [],
        deleteGate: AsyncGate? = nil
    ) {
        current = state
        cachedIDs = cachedModelIDs
        self.deleteGate = deleteGate
    }
    func state() async -> SpeechModelState { current }
    func cachedModelIDs() async -> Set<String> { cachedIDs }
    func prepare(modelID: String, token: EffectToken) async -> AsyncStream<SpeechModelState> {
        explicitPreparationIDs.append(modelID)
        return makePreparationStream()
    }
    func prepareCached(modelID: String, token: EffectToken) async -> AsyncStream<SpeechModelState> {
        cachedPreparationIDs.append(modelID)
        guard cachedIDs.contains(modelID) else {
            let missing = SpeechModelState.missing(modelID: modelID)
            current = missing
            return AsyncStream { continuation in
                continuation.yield(missing)
                continuation.finish()
            }
        }
        return makePreparationStream()
    }
    private func makePreparationStream() -> AsyncStream<SpeechModelState> {
        streamCalls += 1
        let call = streamCalls
        var captured: AsyncStream<SpeechModelState>.Continuation?
        let stream = AsyncStream<SpeechModelState> { continuation in captured = continuation }
        continuations[call] = captured
        return stream
    }
    func cancelPreparation() async {
        cancels += 1
        continuations.values.forEach { $0.finish() }
        continuations = [:]
    }
    func acquireReadyModel(modelID: String, token: EffectToken) async throws -> SpeechModelLease {
        guard case let .ready(id) = current, id == modelID else {
            throw DiagnosticCode.transcriptionFailed
        }
        acquires += 1
        return SpeechModelLease(modelID: modelID, generation: token.generation)
    }
    func release(_ lease: SpeechModelLease) async { releases += 1 }
    func deleteCachedModel(modelID: String) async throws {
        if let deleteGate { await deleteGate.wait() }
        if let deleteFailure { throw deleteFailure }
        cachedIDs.remove(modelID)
        deleted.append(modelID)
    }
    func emit(call: Int, _ state: SpeechModelState) {
        continuations[call]?.yield(state)
        current = state
        if case let .ready(modelID) = state {
            cachedIDs.insert(modelID)
        }
    }
    func finish(call: Int) { continuations[call]?.finish() }
    func prepareCount() -> Int { explicitPreparationIDs.count }
    func cachedPrepareCount() -> Int { cachedPreparationIDs.count }
    func cachedPreparedModelIDs() -> [String] { cachedPreparationIDs }
    func cancelCount() -> Int { cancels }
    func acquireCount() -> Int { acquires }
    func releaseCount() -> Int { releases }
    func deletedModelIDs() -> [String] { deleted }
    func setDeleteFailure(_ error: DiagnosticCode?) { deleteFailure = error }
}

private actor TranscriptionFake: TranscriptionService {
    private let text: String
    init(text: String = "raw transcript") { self.text = text }
    func transcribe(
        audioURL: URL,
        model: SpeechModelLease,
        configuration: RecognitionConfiguration,
        token: EffectToken
    ) async throws -> String { text }
}

private actor PolishingFake: PolishingService {
    private let failure: DiagnosticCode?
    private let gate: AsyncGate?
    private var log: EventLog?
    private var calls = 0
    private var snapshots: [SessionSnapshot] = []

    init(failure: DiagnosticCode? = nil, gate: AsyncGate? = nil) {
        self.failure = failure
        self.gate = gate
    }
    func setLog(_ log: EventLog) { self.log = log }
    func callCount() -> Int { calls }
    func receivedSnapshots() -> [SessionSnapshot] { snapshots }
    func polish(rawText: String, snapshot: SessionSnapshot, token: EffectToken) async throws -> String {
        calls += 1
        snapshots.append(snapshot)
        await log?.append("polish.request")
        if let gate { await gate.wait() }
        try Task.checkCancellation()
        if let failure { throw failure }
        return "polished transcript"
    }
}

private actor DeliveryFake: DeliveryService {
    struct Call: Equatable, Sendable {
        let text: String
        let target: DeliveryTarget
        let preference: DeliveryPreference
        let mutationCount: Int
    }
    struct ExplicitCall: Equatable, Sendable { let text: String }

    private var delivered: [Call] = []
    private var copied: [ExplicitCall] = []
    private let log: EventLog

    init(log: EventLog = EventLog()) { self.log = log }

    func deliver(
        text: String,
        to target: DeliveryTarget,
        preference: DeliveryPreference,
        token: EffectToken
    ) async -> DeliveryOutcome {
        await log.append("delivery.request")
        let mutations = preference == .automaticPaste && target != .copyOnly ? 1 : 0
        delivered.append(
            Call(text: text, target: target, preference: preference, mutationCount: mutations)
        )
        if target == .onboardingTest { return .deliveredToOnboardingTest }
        if preference == .copyOnly { return .copiedByPreference }
        if target == .copyOnly { return .manualCopyRequired(.deliveryTargetUnavailable) }
        return .pasteEventDispatched
    }

    func copyExplicitly(text: String, token: EffectToken) async -> DeliveryOutcome {
        copied.append(ExplicitCall(text: text))
        return .copiedByUser
    }

    func deliveryCalls() -> [Call] { delivered }
    func explicitCalls() -> [ExplicitCall] { copied }
}

private actor TargetFake: TargetSnapshotService {
    private var target: DeliveryTarget
    private var count = 0
    init(target: DeliveryTarget) { self.target = target }
    func snapshotTarget() async -> DeliveryTarget {
        count += 1
        return target
    }
    func setTarget(_ target: DeliveryTarget) { self.target = target }
    func snapshotCount() -> Int { count }
}

private struct PermissionFake: PermissionService {
    func microphoneState() async -> PermissionState { .granted }
    func accessibilityState() async -> PermissionState { .granted }
}

private actor DiagnosticsFake: DiagnosticsSink {
    private var values: [(PipelineStage, DiagnosticCode?)] = []
    func record(stage: PipelineStage, code: DiagnosticCode?) async {
        values.append((stage, code))
    }
}

private struct TestClock: AppClock {
    let now = Date(timeIntervalSince1970: 1_721_000_000)
    func sleep(for duration: Duration) async throws {}
}

private actor AsyncGate {
    private var entered = false
    private var openState = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        if openState { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        openState = true
        continuation?.resume()
        continuation = nil
    }

    func waitUntilEntered() async {
        for _ in 0..<2_000 {
            if entered { return }
            await Task.yield()
        }
    }
}

private func rawSettings(
    preference: DeliveryPreference = .automaticPaste,
    historyEnabled: Bool = true
) -> UserSettings {
    UserSettings(
        launchAtLogin: false,
        showFloatingRecorder: true,
        recognition: .fixed(languageCode: "en"),
        speechModelID: "small",
        outputModes: [.raw],
        selectedOutputModeID: OutputMode.rawID,
        providerProfiles: [],
        selectedProviderProfileID: nil,
        shortcutMode: .toggle,
        historyEnabled: historyEnabled,
        deliveryPreference: preference,
        onboardingCompletedV2: true,
        onboardingStep: 4
    )
}

private func polishedSettings(
    preference: DeliveryPreference = .automaticPaste
) -> UserSettings {
    let mode = OutputMode(
        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        title: "Clean",
        skipsPolishing: false,
        instructions: "Clean the transcript"
    )
    var value = rawSettings(preference: preference)
    value.outputModes = [.raw, mode]
    value.selectedOutputModeID = mode.id
    return value
}

private func polishedSettingsWithProvider() -> UserSettings {
    var value = polishedSettings()
    let id = UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!
    value.providerProfiles = [
        ProviderProfile(
            id: id,
            title: "Provider",
            baseURL: URL(string: "https://example.test/v1")!,
            modelID: "model",
            policy: .remoteHTTPS
        )
    ]
    value.selectedProviderProfileID = id
    return value
}

private func historyRecord(
    id: SessionID,
    final: String
) -> HistoryRecord {
    HistoryRecord(
        sessionID: id,
        startedAt: Date(timeIntervalSince1970: 1_721_000_000),
        rawText: "saved raw",
        finalText: final,
        source: .polished,
        warning: nil,
        delivery: nil,
        outcome: .finalized
    )
}

@MainActor
private func waitUntil(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ predicate: @escaping @MainActor () async -> Bool
) async {
    for _ in 0..<3_000 {
        if await predicate() { return }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("timed out waiting for controller state", file: file, line: line)
}

private func settle() async {
    for _ in 0..<20 { await Task.yield() }
    try? await Task.sleep(nanoseconds: 5_000_000)
}
