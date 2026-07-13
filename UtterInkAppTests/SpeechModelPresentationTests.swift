import XCTest
import UtterInkCore
@testable import UtterInk

@MainActor
final class SpeechModelPresentationTests: XCTestCase {
    func testLockedCatalogMapsExactPresetsAndLeavesOnlyOtherEntriesInAdvanced() async {
        let controller = RecordingIntentControllerSpy()
        controller.speechModelCatalog = Self.catalog
        let model = SpeechModelSettingsViewModel(
            controller: controller,
            settings: AppSettingsFake()
        )

        await model.load()

        XCTAssertEqual(model.presets.map(\.id), ["base", "small", "large-v3"])
        XCTAssertEqual(model.presets.map(\.title), ["Fast", "Recommended", "Best Quality"])
        XCTAssertEqual(model.presets.map(\.diskImpact), ["150 MB", "500 MB", "1.6 GB"])
        XCTAssertEqual(model.advanced.map(\.id), ["distil-small.en"])
        XCTAssertEqual(model.advanced.map(\.title), ["Distilled Small English"])
        XCTAssertEqual(model.selectedModelID, "small")
    }

    func testAuthoritativeStateCopyAndProgressAreSanitized() async {
        let controller = RecordingIntentControllerSpy()
        controller.speechModelCatalog = Self.catalog
        var settingsValue = UserSettings.p0Default
        settingsValue.speechModelID = "large-v3"
        let model = SpeechModelSettingsViewModel(
            controller: controller,
            settings: AppSettingsFake(value: settingsValue)
        )
        await model.load()

        controller.speechModelState = .missing(modelID: "base")
        XCTAssertEqual(model.presentation.title, "Not Downloaded")
        XCTAssertEqual(model.presentation.detail, "Fast is not downloaded.")
        XCTAssertNil(model.presentation.progress)

        controller.preparingSpeechModelID = "base"
        controller.speechModelState = .downloading(modelID: "base", progress: 1.8)
        XCTAssertEqual(model.presentation.title, "Downloading")
        XCTAssertEqual(model.presentation.detail, "Downloading Fast… 100%")
        XCTAssertEqual(model.presentation.progress, 1)
        XCTAssertTrue(model.presentation.canCancel)

        controller.speechModelState = .downloading(modelID: "large-v3", progress: 0.2)
        XCTAssertEqual(model.presentation.title, "Preparing")
        XCTAssertEqual(model.presentation.detail, "Starting Fast preparation…")
        controller.speechModelState = .downloading(modelID: "base", progress: 1.8)

        controller.speechModelState = .downloading(modelID: "base", progress: -.infinity)
        XCTAssertEqual(model.presentation.progress, 0)
        controller.speechModelState = .downloading(modelID: "base", progress: .nan)
        XCTAssertEqual(model.presentation.progress, 0)

        controller.preparingSpeechModelID = "small"
        controller.speechModelState = .loading(modelID: "small")
        XCTAssertEqual(model.presentation.title, "Loading")
        XCTAssertEqual(model.presentation.detail, "Loading Recommended…")
        XCTAssertTrue(model.presentation.canCancel)

        controller.preparingSpeechModelID = nil
        controller.speechModelState = .ready(modelID: "small")
        XCTAssertEqual(model.presentation.title, "Ready")
        XCTAssertEqual(model.presentation.detail, "Recommended is ready.")

        controller.speechModelState = .failed(
            modelID: "large-v3",
            code: .transcriptionFailed,
            retryable: true
        )
        XCTAssertEqual(model.presentation.title, "Preparation Failed")
        XCTAssertEqual(
            model.presentation.detail,
            "Best Quality could not be prepared (transcription.failed)."
        )
        XCTAssertTrue(model.presentation.canRetry)

        controller.speechModelState = .failed(
            modelID: "large-v3",
            code: .audioStart,
            retryable: false
        )
        XCTAssertFalse(model.presentation.canRetry)

        controller.speechModelState = .failed(
            modelID: "large-v3",
            code: .cancelled,
            retryable: true
        )
        XCTAssertEqual(model.presentation.title, "Preparation Canceled")
        XCTAssertEqual(model.presentation.detail, "Best Quality preparation was canceled.")
        XCTAssertTrue(model.presentation.canRetry)
    }

    func testSelectionPersistsAtomicallyThenPreparesOnlyWhenNotReady() async throws {
        let controller = RecordingIntentControllerSpy()
        controller.speechModelCatalog = Self.catalog
        controller.speechModelState = .ready(modelID: "small")
        controller.activeSpeechModelID = "small"
        let store = AppSettingsFake()
        let model = SpeechModelSettingsViewModel(controller: controller, settings: store)
        await model.load()

        await model.select("base")

        let savedModelID = try await store.current().speechModelID
        XCTAssertEqual(model.selectedModelID, "base")
        XCTAssertEqual(savedModelID, "base")
        XCTAssertEqual(controller.preparedSpeechModelIDs, ["base"])

        controller.speechModelState = .ready(modelID: "large-v3")
        await model.select("large-v3")
        XCTAssertEqual(controller.preparedSpeechModelIDs, ["base"])
    }

    func testClickingInitiallySelectedMissingModelStartsPreparation() async {
        let controller = RecordingIntentControllerSpy()
        controller.speechModelCatalog = Self.catalog
        controller.speechModelState = .missing(modelID: "small")
        let model = SpeechModelSettingsViewModel(
            controller: controller,
            settings: AppSettingsFake()
        )
        await model.load()

        await model.select("small")

        XCTAssertEqual(controller.preparedSpeechModelIDs, ["small"])
        XCTAssertEqual(model.presentation.title, "Preparing")
        XCTAssertEqual(model.presentation.detail, "Starting Recommended preparation…")
        XCTAssertTrue(model.presentation.canCancel)
        XCTAssertFalse(model.presentation.canRetry)
    }

    func testRejectedPreparationKeepsFutureSelectionAndExposesRetry() async throws {
        let controller = RecordingIntentControllerSpy()
        controller.speechModelCatalog = Self.catalog
        controller.speechModelState = .ready(modelID: "small")
        controller.activeSpeechModelID = "small"
        controller.rejectPreparation = true
        let store = AppSettingsFake()
        let model = SpeechModelSettingsViewModel(controller: controller, settings: store)
        await model.load()

        await model.select("base")

        let savedModelID = try await store.current().speechModelID
        XCTAssertEqual(model.selectedModelID, "base")
        XCTAssertEqual(savedModelID, "base")
        XCTAssertEqual(model.presentation.title, "Preparation Not Started")
        XCTAssertTrue(model.presentation.canRetry)
        XCTAssertEqual(
            model.failureMessage,
            "Fast was selected for future dictation, but preparation could not start. Finish the active dictation, then choose Retry."
        )

        controller.rejectPreparation = false
        model.retry()
        XCTAssertEqual(controller.preparedSpeechModelIDs, ["base"])
        XCTAssertNil(model.preparationRejectedModelID)
    }

    func testReadySelectedModelClearsStalePreparationRejectionWithoutRestarting() async {
        let controller = RecordingIntentControllerSpy()
        controller.speechModelCatalog = Self.catalog
        controller.rejectPreparation = true
        let model = SpeechModelSettingsViewModel(
            controller: controller,
            settings: AppSettingsFake()
        )
        await model.load()
        controller.speechModelState = .missing(modelID: "small")
        await model.select("small")
        XCTAssertEqual(model.preparationRejectedModelID, "small")

        controller.speechModelState = .ready(modelID: "small")
        XCTAssertEqual(model.presentation.title, "Ready")
        model.retry()

        XCTAssertNil(model.preparationRejectedModelID)
        XCTAssertTrue(controller.preparedSpeechModelIDs.isEmpty)
        XCTAssertNil(model.failureMessage)
    }

    func testCacheDeletionPendingBlocksSelectionAndPreparation() async throws {
        let controller = RecordingIntentControllerSpy()
        controller.speechModelCatalog = Self.catalog
        controller.speechModelCacheActionStatus = .deleting(modelID: "base")
        let store = AppSettingsFake()
        let model = SpeechModelSettingsViewModel(controller: controller, settings: store)
        await model.load()

        await model.select("base")

        let savedModelID = try await store.current().speechModelID
        XCTAssertEqual(savedModelID, "small")
        XCTAssertEqual(model.selectedModelID, "small")
        XCTAssertTrue(controller.preparedSpeechModelIDs.isEmpty)
    }

    func testSwitchingBackToLastActiveButNoLongerReadyModelPreparesAgain() async {
        let controller = RecordingIntentControllerSpy()
        controller.speechModelCatalog = Self.catalog
        controller.activeSpeechModelID = "small"
        controller.speechModelState = .ready(modelID: "base")
        var settings = UserSettings.p0Default
        settings.speechModelID = "base"
        let model = SpeechModelSettingsViewModel(
            controller: controller,
            settings: AppSettingsFake(value: settings)
        )
        await model.load()

        await model.select("small")

        XCTAssertEqual(controller.preparedSpeechModelIDs, ["small"])
    }

    func testSelectionFailureKeepsPublishedSelectionAndDoesNotPrepare() async {
        let controller = RecordingIntentControllerSpy()
        controller.speechModelCatalog = Self.catalog
        let store = AppSettingsFake()
        let model = SpeechModelSettingsViewModel(controller: controller, settings: store)
        await model.load()
        await store.setSaveFailureEnabled(true)

        await model.select("base")

        XCTAssertEqual(model.selectedModelID, "small")
        XCTAssertTrue(controller.preparedSpeechModelIDs.isEmpty)
        XCTAssertEqual(
            model.failureMessage,
            "Speech model selection could not be saved. Recommended remains selected."
        )
    }

    func testRetryCancelAndConfirmedInactiveDeletionForwardExactly() async {
        let controller = RecordingIntentControllerSpy()
        controller.speechModelCatalog = Self.catalog
        controller.speechModelState = .failed(
            modelID: "base",
            code: .transcriptionFailed,
            retryable: true
        )
        controller.activeSpeechModelID = "small"
        var selected = UserSettings.p0Default
        selected.speechModelID = "base"
        let model = SpeechModelSettingsViewModel(
            controller: controller,
            settings: AppSettingsFake(value: selected)
        )
        await model.load()

        model.retry()
        controller.speechModelState = .downloading(modelID: "base", progress: 0.3)
        controller.preparingSpeechModelID = "base"
        model.cancel()
        model.requestDeletion("large-v3")
        XCTAssertEqual(model.pendingDeletion?.id, "large-v3")
        model.confirmDeletion()

        XCTAssertEqual(controller.preparedSpeechModelIDs, ["base"])
        XCTAssertEqual(controller.cancelPreparationCount, 1)
        XCTAssertEqual(controller.deletedSpeechModelIDs, ["large-v3"])
        XCTAssertEqual(model.cacheActionMessage, "Deleted the cached Best Quality model.")
    }

    func testDeletionIsDisabledForSelectedSessionPreparingAndActiveModels() async {
        let controller = RecordingIntentControllerSpy()
        controller.speechModelCatalog = Self.catalog
        controller.activeSpeechModelID = "small"
        controller.preparingSpeechModelID = "large-v3"
        var settings = UserSettings.p0Default
        settings.speechModelID = "base"
        let model = SpeechModelSettingsViewModel(
            controller: controller,
            settings: AppSettingsFake(value: settings)
        )
        await model.load()

        XCTAssertFalse(model.canDelete("base"), "selected/current-session model is locked")
        XCTAssertFalse(model.canDelete("small"), "last successfully active model is locked")
        XCTAssertFalse(model.canDelete("large-v3"), "preparing model is locked")

        model.requestDeletion("base")
        model.requestDeletion("small")
        model.requestDeletion("large-v3")
        model.confirmDeletion()
        XCTAssertNil(model.pendingDeletion)
        XCTAssertTrue(controller.deletedSpeechModelIDs.isEmpty)
    }

    func testDeletionConfirmationRechecksActivityThatChangedWhileDialogWasOpen() async {
        let controller = RecordingIntentControllerSpy()
        controller.speechModelCatalog = Self.catalog
        let model = SpeechModelSettingsViewModel(
            controller: controller,
            settings: AppSettingsFake()
        )
        await model.load()

        model.requestDeletion("base")
        XCTAssertEqual(model.pendingDeletion?.id, "base")
        controller.preparingSpeechModelID = "base"
        model.confirmDeletion()

        XCTAssertTrue(controller.deletedSpeechModelIDs.isEmpty)
        XCTAssertNil(model.pendingDeletion)
    }

    private static let catalog = [
        SpeechModelDescriptor(
            id: "base", displayName: "Fast", approximateBytes: 150_000_000, preset: "Fast"
        ),
        SpeechModelDescriptor(
            id: "small", displayName: "Recommended", approximateBytes: 500_000_000,
            preset: "Recommended"
        ),
        SpeechModelDescriptor(
            id: "large-v3", displayName: "Best Quality", approximateBytes: 1_600_000_000,
            preset: "Best Quality"
        ),
        SpeechModelDescriptor(
            id: "distil-small.en", displayName: "Distilled Small English",
            approximateBytes: 300_000_000, preset: nil
        ),
    ]
}
