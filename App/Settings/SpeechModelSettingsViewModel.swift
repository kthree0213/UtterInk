import Foundation
import Observation
import UtterInkCore

struct SpeechModelOption: Identifiable, Equatable {
    let descriptor: SpeechModelDescriptor
    let title: String

    var id: String { descriptor.id }
    var diskImpact: String { Self.diskImpact(for: descriptor.approximateBytes) }
    var isRecommended: Bool {
        descriptor.id == "small" && descriptor.preset == "Recommended"
    }

    static func displayTitle(for descriptor: SpeechModelDescriptor) -> String {
        if descriptor.id == "small", descriptor.preset == "Recommended" {
            return "Balanced"
        }
        return descriptor.preset ?? descriptor.displayName
    }

    private static func diskImpact(for bytes: UInt64) -> String {
        if bytes >= 1_000_000_000 {
            let value = Double(bytes) / 1_000_000_000
            return value.rounded() == value
                ? "\(Int(value)) GB"
                : String(format: "%.1f GB", locale: Locale(identifier: "en_US_POSIX"), value)
        }
        if bytes >= 1_000_000 {
            return "\(bytes / 1_000_000) MB"
        }
        if bytes >= 1_000 {
            return "\(bytes / 1_000) KB"
        }
        return "\(bytes) bytes"
    }
}

struct SpeechModelPresentation: Equatable {
    let title: String
    let detail: String
    let progress: Double?
    let canRetry: Bool
    let canCancel: Bool
}

@MainActor
@Observable
final class SpeechModelSettingsViewModel {
    private static let presetIDs = ["base", "small", "large-v3"]
    private static let catalogPresetTitles = [
        "base": "Fast",
        "small": "Recommended",
        "large-v3": "Best Quality",
    ]

    let presets: [SpeechModelOption]
    let advanced: [SpeechModelOption]
    private(set) var selectedModelID = UserSettings.p0Default.speechModelID
    private(set) var isSaving = false
    private(set) var failureMessage: String?
    private(set) var pendingDownload: SpeechModelOption?
    private(set) var pendingDeletion: SpeechModelOption?
    private(set) var preparationRejectedModelID: String?
    private(set) var accessibilityEvent: UtterInkAccessibilityEvent?
    let failureSymbol = "exclamationmark.triangle.fill"

    @ObservationIgnored private let controller: any DictationControlling
    @ObservationIgnored private let settings: any SettingsStore

    init(controller: any DictationControlling, settings: any SettingsStore) {
        self.controller = controller
        self.settings = settings

        let descriptors = controller.speechModelCatalog
        let byID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })
        presets = Self.presetIDs.compactMap { id in
            guard let descriptor = byID[id],
                  descriptor.preset == Self.catalogPresetTitles[id] else { return nil }
            return SpeechModelOption(
                descriptor: descriptor,
                title: SpeechModelOption.displayTitle(for: descriptor)
            )
        }
        let presetIDSet = Set(Self.presetIDs)
        advanced = descriptors
            .filter { !presetIDSet.contains($0.id) }
            .map {
                SpeechModelOption(
                    descriptor: $0,
                    title: $0.displayName
                )
            }
    }

    var presentation: SpeechModelPresentation {
        let state = controller.speechModelState
        let modelID = state.modelID
        let title = option(for: modelID)?.title ?? modelID
        if let preparingID = controller.preparingSpeechModelID {
            switch state {
            case let .downloading(stateID, _) where stateID == preparingID:
                break
            case let .loading(stateID) where stateID == preparingID:
                break
            default:
                let preparingTitle = option(for: preparingID)?.title ?? preparingID
                return SpeechModelPresentation(
                    title: "Preparing",
                    detail: "Starting \(preparingTitle) preparation…",
                    progress: nil,
                    canRetry: false,
                    canCancel: true
                )
            }
        }
        if preparationRejectedModelID == selectedModelID,
           state != .ready(modelID: selectedModelID) {
            let selectedTitle = option(for: selectedModelID)?.title ?? selectedModelID
            return SpeechModelPresentation(
                title: "Preparation Not Started",
                detail: "\(selectedTitle) preparation could not start while dictation is active.",
                progress: nil,
                canRetry: true,
                canCancel: false
            )
        }
        switch state {
        case .missing:
            return SpeechModelPresentation(
                title: "Not Downloaded",
                detail: "\(title) is not downloaded.",
                progress: nil,
                canRetry: false,
                canCancel: controller.preparingSpeechModelID == modelID
            )
        case let .downloading(_, progress):
            let bounded = progress.isFinite ? max(0, min(progress, 1)) : 0
            return SpeechModelPresentation(
                title: "Downloading",
                detail: "Downloading \(title)… \(Int((bounded * 100).rounded()))%",
                progress: bounded,
                canRetry: false,
                canCancel: controller.preparingSpeechModelID == modelID
            )
        case .loading:
            return SpeechModelPresentation(
                title: "Loading",
                detail: "Loading \(title)…",
                progress: nil,
                canRetry: false,
                canCancel: controller.preparingSpeechModelID == modelID
            )
        case .ready:
            return SpeechModelPresentation(
                title: "Ready",
                detail: "\(title) is ready.",
                progress: nil,
                canRetry: false,
                canCancel: false
            )
        case let .failed(_, code, retryable):
            if code == .cancelled {
                return SpeechModelPresentation(
                    title: "Preparation Canceled",
                    detail: "\(title) preparation was canceled.",
                    progress: nil,
                    canRetry: retryable && modelID == selectedModelID,
                    canCancel: false
                )
            }
            return SpeechModelPresentation(
                title: "Preparation Failed",
                detail: "\(title) could not be prepared (\(code.rawValue)).",
                progress: nil,
                canRetry: retryable && modelID == selectedModelID,
                canCancel: false
            )
        }
    }

    func load() async {
        guard !isSaving else { return }
        do {
            selectedModelID = try await settings.current().speechModelID
            await controller.refreshSpeechModelCache()
            failureMessage = nil
        } catch {
            failureMessage = "Speech model settings could not be loaded. Your current choice was kept."
        }
    }

    func select(_ modelID: String) async {
        guard !isSaving,
              !cacheActionIsPending,
              let option = option(for: modelID) else { return }
        if !isDownloaded(modelID) {
            pendingDownload = option
            accessibilityEvent = UtterInkAccessibilityEvent(
                message: "Download confirmation required for \(option.title), approximately \(option.diskImpact)."
            )
            return
        }
        await applySelection(modelID)
    }

    func confirmDownload() async {
        guard let pendingDownload else { return }
        self.pendingDownload = nil
        await applySelection(pendingDownload.id)
    }

    func cancelDownload() {
        guard let pendingDownload else { return }
        self.pendingDownload = nil
        accessibilityEvent = UtterInkAccessibilityEvent(
            message: "Download canceled. \(pendingDownload.title) was not selected."
        )
    }

    func isDownloaded(_ modelID: String) -> Bool {
        if controller.cachedSpeechModelIDs.contains(modelID) { return true }
        if case let .ready(readyID) = controller.speechModelState,
           readyID == modelID { return true }
        return false
    }

    private func applySelection(_ modelID: String) async {
        guard !isSaving,
              !cacheActionIsPending,
              option(for: modelID) != nil else { return }
        if modelID == selectedModelID {
            prepareIfNeeded(modelID)
            return
        }
        isSaving = true
        failureMessage = nil
        do {
            let saved = try await settings.update { $0.speechModelID = modelID }
            selectedModelID = saved.speechModelID
            prepareIfNeeded(modelID)
            let title = option(for: saved.speechModelID)?.title ?? "selected model"
            accessibilityEvent = UtterInkAccessibilityEvent(
                message: "Speech model selected: \(title)."
            )
        } catch {
            let keptTitle = option(for: selectedModelID)?.title ?? selectedModelID
            failureMessage =
                "Speech model selection could not be saved. \(keptTitle) remains selected."
        }
        isSaving = false
    }

    func retry() {
        if preparationRejectedModelID == selectedModelID {
            if controller.speechModelState == .ready(modelID: selectedModelID) {
                clearPreparationRejection(for: selectedModelID)
                return
            }
            startPreparation(selectedModelID)
            return
        }
        guard case let .failed(modelID, _, retryable) = controller.speechModelState,
              retryable,
              modelID == selectedModelID,
              option(for: modelID) != nil else { return }
        startPreparation(modelID)
    }

    func cancel() {
        guard presentation.canCancel else { return }
        controller.cancelSpeechModelPreparation()
        accessibilityEvent = UtterInkAccessibilityEvent(
            message: "Speech model preparation cancellation requested."
        )
    }

    func canDelete(_ modelID: String) -> Bool {
        option(for: modelID) != nil
            && isDownloaded(modelID)
            && !cacheActionIsPending
            && selectedModelID != modelID
            && controller.activeSpeechModelID != modelID
            && controller.preparingSpeechModelID != modelID
    }

    func requestDeletion(_ modelID: String) {
        guard canDelete(modelID), let option = option(for: modelID) else { return }
        pendingDeletion = option
    }

    func cancelDeletion() {
        pendingDeletion = nil
    }

    func confirmDeletion() {
        guard let pendingDeletion else { return }
        self.pendingDeletion = nil
        guard canDelete(pendingDeletion.id) else { return }
        controller.deleteCachedSpeechModel(pendingDeletion.id)
        accessibilityEvent = UtterInkAccessibilityEvent(
            message: "Cached speech model deletion requested."
        )
    }

    var cacheActionIsPending: Bool {
        if case .deleting = controller.speechModelCacheActionStatus { return true }
        return false
    }

    var cacheActionMessage: String? {
        switch controller.speechModelCacheActionStatus {
        case .idle:
            return nil
        case let .deleting(modelID):
            return "Deleting the cached \(option(for: modelID)?.title ?? modelID) model…"
        case let .deleted(modelID):
            return "Deleted the cached \(option(for: modelID)?.title ?? modelID) model."
        case let .deleteFailed(modelID):
            return "The cached \(option(for: modelID)?.title ?? modelID) model could not be deleted."
        }
    }

    var cacheActionFailed: Bool {
        if case .deleteFailed = controller.speechModelCacheActionStatus { return true }
        return false
    }

    private func option(for modelID: String) -> SpeechModelOption? {
        presets.first { $0.id == modelID } ?? advanced.first { $0.id == modelID }
    }

    private func prepareIfNeeded(_ modelID: String) {
        if controller.speechModelState == .ready(modelID: modelID)
            || controller.preparingSpeechModelID == modelID {
            clearPreparationRejection(for: modelID)
            return
        }
        if case let .failed(failedID, _, _) = controller.speechModelState,
           failedID == modelID {
            return
        }
        startPreparation(modelID)
    }

    private func startPreparation(_ modelID: String) {
        controller.prepareSpeechModel(modelID)
        if controller.preparingSpeechModelID == modelID
            || controller.speechModelState == .ready(modelID: modelID) {
            preparationRejectedModelID = nil
            failureMessage = nil
            return
        }
        preparationRejectedModelID = modelID
        let title = option(for: modelID)?.title ?? modelID
        failureMessage =
            "\(title) was selected for future dictation, but preparation could not start. Finish the active dictation, then choose Retry."
    }

    private func clearPreparationRejection(for modelID: String) {
        guard preparationRejectedModelID == modelID else { return }
        preparationRejectedModelID = nil
        failureMessage = nil
    }
}
