import SwiftUI

/// 「设置 → 语音模型」：列出全部 Whisper 变体、说明、本地缓存状态与下载/使用（转写在本机完成，不上传录音；仅模型文件可经网络下载）。
struct SpeechModelsSettingsPane: View {
    @ObservedObject var appState: AppState
    @AppStorage(WhisperModelCatalog.storageKey) private var selectedVariant = WhisperModelCatalog.default
    @AppStorage(AppUILanguage.storageKey) private var uiLanguage = "en"

    @State private var diskRefreshTrigger = 0
    @State private var prefetchingVariant: String?
    @State private var prefetchProgress: Double = 0
    @State private var prefetchThroughput: Double?
    @State private var prefetchError: String?
    @State private var prefetchTask: Task<Void, Never>?
    @State private var variantPendingDelete: String?

    private var sL10n: SettingsLocalization { SettingsLocalization(useChinese: AppUILanguage.isChinese(uiLanguage)) }
    private var mL10n: MenuLocalization { MenuLocalization(useChinese: AppUILanguage.isChinese(uiLanguage)) }

    var body: some View {
        Form {
            Section {
                Text(sL10n.speechModelsIntro(cacheRootPath: WhisperModelCacheInspector.displayCacheRootPath()))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)

                if let err = prefetchError, !err.isEmpty {
                    Text(err)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } header: {
                Text(sL10n.speechModelsAboutSectionTitle)
            }

            Section {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(WhisperModelCatalog.allVariantIDs, id: \.self) { vid in
                            modelRow(variant: vid)
                            if vid != WhisperModelCatalog.allVariantIDs.last {
                                Divider()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 300, maxHeight: 520)
                .scrollIndicators(.visible)
            } header: {
                Text(sL10n.speechModelsVariantsSectionTitle)
            }
        }
        .formStyle(.grouped)
        .onAppear { diskRefreshTrigger += 1 }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            diskRefreshTrigger += 1
        }
        .alert(sL10n.speechModelDeleteConfirmTitle, isPresented: Binding(
            get: { variantPendingDelete != nil },
            set: { if !$0 { variantPendingDelete = nil } }
        )) {
            Button(sL10n.speechModelCancelDownload, role: .cancel) {
                variantPendingDelete = nil
            }
            Button(sL10n.speechModelDelete, role: .destructive) {
                if let v = variantPendingDelete {
                    performDelete(v)
                }
                variantPendingDelete = nil
            }
        } message: {
            if let v = variantPendingDelete {
                Text(sL10n.speechModelDeleteConfirmBody(variant: v))
            }
        }
    }

    @ViewBuilder
    private func modelRow(variant: String) -> some View {
        let zh = AppUILanguage.isChinese(uiLanguage)
        let downloaded = cachedOnDisk(variant)
        let mb = WhisperModelCatalog.approximateDownloadMB(for: variant)
        let coord = appState.coordinator
        let loaded = coord?.activeLoadedWhisperVariantId == variant && coord?.whisperKit != nil
        let isPrefs = selectedVariant == variant
        let inUse = isPrefs && loaded
        let loadingThis =
            appState.whisperTargetLoadVariantId == variant && appState.whisperModelLoadPhase != nil
        let prefetchThis = prefetchingVariant == variant

        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(variant)
                        .font(.system(.headline, design: .monospaced))
                    if WhisperModelCatalog.showsQualityRecommendationBadge(for: variant) {
                        Text(sL10n.speechModelRecommendedBadge)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    }
                    statusBadge(
                        downloaded: downloaded,
                        inUse: inUse,
                        loadingThis: loadingThis,
                        prefetchThis: prefetchThis
                    )
                }
                Text(WhisperModelCatalog.shortDescription(for: variant, useChinese: zh))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 8) {
                Text(sL10n.speechModelApproxMB(mb))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if !downloaded {
                        Button(sL10n.speechModelDownload) {
                            startPrefetch(variant)
                        }
                        .disabled(
                            prefetchingVariant != nil || loadingThis
                                || (appState.whisperTargetLoadVariantId != nil && !loadingThis)
                        )
                    }
                    if downloaded, !inUse {
                        Button(sL10n.speechModelUse) {
                            selectedVariant = variant
                            appState.coordinator?.scheduleWhisperModelLoad(modelId: variant)
                            diskRefreshTrigger += 1
                        }
                        .disabled(loadingThis || prefetchingVariant != nil)
                    }
                    if downloaded {
                        Button(sL10n.speechModelDelete, role: .destructive) {
                            variantPendingDelete = variant
                        }
                        .disabled(loadingThis || prefetchThis)
                    }
                }
                if loadingThis {
                    VStack(alignment: .trailing, spacing: 4) {
                        if let p = appState.whisperModelLoadProgress {
                            ProgressView(value: p, total: 1)
                                .frame(width: 160)
                            Text(sL10n.speechModelDownloadPercent(p))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(sL10n.speechModelDownloadSpeedLabel(bytesPerSecond: appState.whisperModelLoadThroughputBytesPerSecond))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(appState.whisperModelLoadPhase == .downloading ? mL10n.downloadingModel : mL10n.loadingModel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if appState.whisperModelLoadPhase == .downloading {
                            Button(sL10n.speechModelCancelDownload) {
                                appState.coordinator?.cancelWhisperModelLoad()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Text(sL10n.speechModelDownloadNoPauseFootnote)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: 200, alignment: .trailing)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else if prefetchThis {
                    VStack(alignment: .trailing, spacing: 4) {
                        ProgressView(value: prefetchProgress, total: 1)
                            .frame(width: 160)
                        Text(sL10n.speechModelDownloadPercent(prefetchProgress))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(sL10n.speechModelDownloadSpeedLabel(bytesPerSecond: prefetchThroughput))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(sL10n.speechModelPrefetching)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button(sL10n.speechModelCancelDownload) {
                            cancelPrefetch()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Text(sL10n.speechModelDownloadNoPauseFootnote)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: 200, alignment: .trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func statusBadge(downloaded: Bool, inUse: Bool, loadingThis: Bool, prefetchThis: Bool) -> some View {
        if inUse {
            Label(sL10n.speechModelStatusInUse, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else if loadingThis {
            Text(sL10n.speechModelStatusLoading)
                .font(.caption)
                .foregroundStyle(.orange)
        } else if prefetchThis {
            Text(sL10n.speechModelPrefetching)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if downloaded {
            Text(sL10n.speechModelStatusDownloaded)
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(.secondary.opacity(0.15)))
        } else {
            Text(sL10n.speechModelStatusNotDownloaded)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func cachedOnDisk(_ variant: String) -> Bool {
        _ = diskRefreshTrigger
        return WhisperModelCacheInspector.isVariantDownloaded(variant)
    }

    private func cancelPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchingVariant = nil
        prefetchProgress = 0
        prefetchThroughput = nil
    }

    private func startPrefetch(_ variant: String) {
        cancelPrefetch()
        prefetchError = nil
        prefetchingVariant = variant
        prefetchProgress = 0
        prefetchThroughput = nil
        guard let coord = appState.coordinator else {
            cancelPrefetch()
            return
        }
        prefetchTask = Task {
            do {
                try await coord.prefetchWhisperVariant(variant) { p, tp in
                    Task { @MainActor in
                        prefetchProgress = p
                        prefetchThroughput = tp
                    }
                }
                try Task.checkCancellation()
                await MainActor.run {
                    prefetchingVariant = nil
                    prefetchProgress = 0
                    prefetchThroughput = nil
                    prefetchTask = nil
                    diskRefreshTrigger += 1
                    NotificationCenter.default.post(name: .whisperModelDiskCacheChanged, object: nil)
                }
            } catch is CancellationError {
                await MainActor.run { cancelPrefetch() }
            } catch {
                await MainActor.run {
                    prefetchingVariant = nil
                    prefetchProgress = 0
                    prefetchThroughput = nil
                    prefetchTask = nil
                    prefetchError =
                        (AppUILanguage.isChinese(uiLanguage) ? "下载失败：" : "Download failed: ") + error.localizedDescription
                }
            }
        }
    }

    private func performDelete(_ variant: String) {
        prefetchError = nil
        guard let coord = appState.coordinator else { return }
        do {
            try coord.removeWhisperVariantFromDisk(variant)
            if selectedVariant == variant {
                selectedVariant = WhisperModelCatalog.default
                if WhisperModelCacheInspector.isVariantDownloaded(WhisperModelCatalog.default) {
                    coord.scheduleWhisperModelLoad(modelId: WhisperModelCatalog.default)
                }
            }
            diskRefreshTrigger += 1
            NotificationCenter.default.post(name: .whisperModelDiskCacheChanged, object: nil)
        } catch {
            let zh = AppUILanguage.isChinese(uiLanguage)
            prefetchError = (zh ? "删除失败：" : "Delete failed: ") + error.localizedDescription
        }
    }
}
