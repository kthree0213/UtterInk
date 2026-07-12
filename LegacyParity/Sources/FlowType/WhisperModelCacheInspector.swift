import Foundation

extension Notification.Name {
    /// 语音模型已写入磁盘缓存或加载完成，菜单栏「语音转写模型」列表应刷新。
    static let whisperModelDiskCacheChanged = Notification.Name("whisperModelDiskCacheChanged")
}

/// 语音模型 Hugging Face 缓存：仅使用 `Application Support/FlowType/huggingface`（不访问「文稿」，避免系统隐私弹窗）。
enum WhisperModelCacheInspector {
    private static let huggingFaceFolderName = "huggingface"
    private static let appSupportAppFolderName = "FlowType"

    /// 供界面展示：主缓存根目录（`~/Library/Application Support/FlowType/huggingface` 形式）。
    static func displayCacheRootPath() -> String {
        guard let url = huggingFaceRootURL() else { return "—" }
        let path = url.path
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// Whisper Core ML 仓库在本机缓存的常用子路径（相对 huggingface 根目录）。
    static let whisperKitCoreMLRelativePath = "models/argmaxinc/whisperkit-coreml"

    /// 下载与索引用的根目录（Application Support）。
    static func huggingFaceRootURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport
            .appendingPathComponent(appSupportAppFolderName, isDirectory: true)
            .appendingPathComponent(huggingFaceFolderName, isDirectory: true)
    }

    private static func cacheSearchRoots() -> [URL] {
        guard let u = huggingFaceRootURL() else { return [] }
        return [u]
    }

    /// 传给 `WhisperKit.download(downloadBase:)`；若目录不存在会创建。
    static func ensureDownloadBaseDirectory() throws -> URL {
        guard let url = huggingFaceRootURL() else {
            throw NSError(
                domain: "FlowType",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not resolve Application Support path."]
            )
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 将磁盘上的 `openai_whisper-*` 目录名映射到设置里的变体 id（取长匹配，避免 `large` 误吞 `large-v2`）。
    static func catalogVariantId(forOpenAIWhisperFolderName name: String) -> String? {
        let prefix = "openai_whisper-"
        guard name.hasPrefix(prefix) else { return nil }
        let suffix = String(name.dropFirst(prefix.count))
        let ids = WhisperModelCatalog.allVariantIDs.sorted { $0.count > $1.count }
        for id in ids {
            if suffix == id || suffix.hasPrefix(id + "-") || suffix.hasPrefix(id + ".") {
                return id
            }
        }
        return nil
    }

    /// 是否已在磁盘上存在可识别的 `openai_whisper-*` 目录（含 MelSpectrogram），且归属该变体。
    static func isVariantDownloaded(_ variant: String) -> Bool {
        findDownloadedFolder(for: variant) != nil
    }

    static func findDownloadedFolder(for variant: String) -> URL? {
        for root in cacheSearchRoots() {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            if let url = findDownloadedFolder(for: variant, under: root) { return url }
        }
        return nil
    }

    private static func findDownloadedFolder(for variant: String, under root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return nil }
        for case let url as URL in enumerator {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let name = url.lastPathComponent
            guard name.hasPrefix("openai_whisper-") else { continue }
            guard catalogVariantId(forOpenAIWhisperFolderName: name) == variant else { continue }
            guard folderHasMelSpectrogram(url) else { continue }
            return url
        }
        return nil
    }

    private static func folderHasMelSpectrogram(_ folder: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.contains { name in
            name.hasPrefix("MelSpectrogram")
        } ?? false
    }

    /// 删除该变体在本机 huggingface 缓存下的相关目录（含未完成下载残留；按目录名归属变体）。
    static func deleteCachedVariant(_ variant: String) throws {
        for root in cacheSearchRoots() {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            try deleteCachedVariant(variant, under: root)
        }
    }

    private static func deleteCachedVariant(_ variant: String, under root: URL) throws {
        var urls: [URL] = []
        if let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) {
            for case let url as URL in enumerator {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
                let name = url.lastPathComponent
                guard name.hasPrefix("openai_whisper-") else { continue }
                guard catalogVariantId(forOpenAIWhisperFolderName: name) == variant else { continue }
                urls.append(url)
            }
        }
        for url in urls.sorted(by: { $0.path.count > $1.path.count }) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// 删除 WhisperKit Core ML 仓库整棵缓存（所有变体与下载缓存）。
    static func deleteEntireWhisperKitCoreMLCache() throws {
        for root in cacheSearchRoots() {
            let repo = root.appendingPathComponent(whisperKitCoreMLRelativePath, isDirectory: true)
            if FileManager.default.fileExists(atPath: repo.path) {
                try FileManager.default.removeItem(at: repo)
            }
        }
    }
}
