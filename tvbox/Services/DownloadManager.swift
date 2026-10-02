import Combine
import CryptoKit
import AVFoundation
import Foundation

/// AVAssetDownloadDelegate 的回调必须在返回前接管 .movpkg，避免系统清理临时位置。
private func stableHLSDownloadURL(taskIdentifier: Int) throws -> URL {
    let applicationSupport = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first ?? FileManager.default.temporaryDirectory
    let downloadsDirectory = applicationSupport.appendingPathComponent("Downloads", isDirectory: true)
    try FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
    return downloadsDirectory.appendingPathComponent(
        "congcong-hls-\(taskIdentifier)-\(UUID().uuidString).movpkg",
        isDirectory: true
    )
}

/// 下载请求保留稳定剧集标识；瓜子额外携带 PlayRequest，以便续传时换取新 CDN 地址。
struct DownloadRequest: Identifiable, Hashable, Sendable {
    let identifier: String
    let title: String
    let sourceKey: String
    let videoID: String
    let episodeIndex: Int
    let episodeName: String
    let url: URL
    let playRequestURL: URL?
    let headers: [String: String]

    var id: String { identifier }

    init(
        identifier: String,
        title: String,
        sourceKey: String,
        videoID: String,
        episodeIndex: Int,
        episodeName: String = "",
        url: URL,
        playRequestURL: URL? = nil,
        headers: [String: String] = [:]
    ) {
        self.identifier = identifier
        self.title = title
        self.sourceKey = sourceKey
        self.videoID = videoID
        self.episodeIndex = episodeIndex
        self.episodeName = episodeName
        self.url = url
        self.playRequestURL = playRequestURL
        self.headers = headers
    }

    static func identifier(sourceKey: String, videoID: String, episodeIndex: Int) -> String {
        "\(sourceKey.trimmingCharacters(in: .whitespacesAndNewlines))::\(videoID.trimmingCharacters(in: .whitespacesAndNewlines))::E\(max(0, episodeIndex))"
    }
}

enum DownloadStatus: Equatable, Sendable {
    case queued
    case downloading
    case paused
    case completed
    case failed(String)
    case cancelled
}

enum DownloadMediaKind: String, Codable, Sendable {
    case directFile
    case hls
}

struct DownloadItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let sourceKey: String
    let videoID: String
    let episodeIndex: Int
    let episodeName: String
    let headers: [String: String]
    var url: URL
    let playRequestURL: URL?
    var mediaKind: DownloadMediaKind
    var status: DownloadStatus
    var progress: Double
    var bytesWritten: Int64
    var totalBytes: Int64
    var speedBytesPerSecond: Double
    var localURL: URL?
}

enum DownloadError: LocalizedError, Equatable {
    case invalidURL
    case unsupportedStream
    case alreadyDownloading
    case fileMissing
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "下载地址无效"
        case .unsupportedStream: return "该地址是在线播放清单，暂不支持直接下载"
        case .alreadyDownloading: return "该影片正在下载"
        case .fileMissing: return "本地下载文件不存在"
        case .downloadFailed(let message): return message
        }
    }
}

/// 基于 URLSession 与 AVFoundation 的离线下载服务。
/// 瓜子任务保存稳定的 PlayRequest，开始或续传时再解析临时 CDN 地址。
@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()
    private static let maxConcurrentHLSRequests = 8

    @Published private(set) var items: [String: DownloadItem] = [:]

    private let fileManager = FileManager.default
    private let downloadsDirectory: URL
    private let manifestURL: URL
    private var session: URLSession!
    private var hlsResourceSession: URLSession!
    private var assetSession: AVAssetDownloadURLSession!
    private var taskIDs: [Int: String] = [:]
    private var activeTasks: [Int: URLSessionTask] = [:]
    private var progressSamples: [Int: ProgressSample] = [:]
    private var fallbackTasks: [String: Task<Void, Never>] = [:]
    private var hlsAssetFallbackAttempted = Set<String>()
    private var pausedIdentifiers = Set<String>()
    private var pendingPauseIdentifiers = Set<String>()
    private var pendingResumeIdentifiers = Set<String>()
    private var resumeDataByIdentifier: [String: Data] = [:]

    private struct ProgressSample {
        let timestamp: TimeInterval
        let bytes: Int64
        let speedBytesPerSecond: Double
    }

    // Download tasks re-enter the main-actor manager before mutating this context.
    private final class HLSCacheContext: @unchecked Sendable {
        var localURLs: [String: URL] = [:]
        var activeURLs = Set<String>()
        var resourceCount = 0
        var plannedResourceCount = 0
        var completedCount = 0
        var bytesWritten: Int64 = 0
        var expectedBytes: Int64 = 0
        var mediaSegmentCount = 0
        var mediaDuration: TimeInterval = 0
        var inFlightBytesByResource: [String: Int64] = [:]
        var inFlightExpectedBytesByResource: [String: Int64] = [:]
    }

    private struct HLSResourceResponse {
        let data: Data
        let finalURL: URL
        let mimeType: String?
        let expectedBytes: Int64
    }

    private override init() {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        downloadsDirectory = applicationSupport.appendingPathComponent("Downloads", isDirectory: true)
        manifestURL = downloadsDirectory.appendingPathComponent("manifest.json")
        super.init()

        try? fileManager.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        loadManifest()

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)

        let hlsConfiguration = URLSessionConfiguration.ephemeral
        hlsConfiguration.timeoutIntervalForRequest = 45
        hlsConfiguration.timeoutIntervalForResource = 24 * 60 * 60
        hlsConfiguration.httpMaximumConnectionsPerHost = Self.maxConcurrentHLSRequests
        hlsConfiguration.waitsForConnectivity = true
        hlsConfiguration.networkServiceType = .video
        hlsResourceSession = URLSession(configuration: hlsConfiguration)

        // AVAssetDownloadURLSession requires a background configuration on
        // iOS. Creating it with `.default` raises an Objective-C exception at
        // runtime, which used to make entering the detail/player page crash
        // as soon as `DownloadManager.shared` was initialized.
        let assetConfiguration = URLSessionConfiguration.background(
            withIdentifier: "com.congcong.tv.xgzy.asset-downloads"
        )
        assetConfiguration.timeoutIntervalForRequest = 60
        assetConfiguration.timeoutIntervalForResource = 24 * 60 * 60
        assetConfiguration.isDiscretionary = false
        assetConfiguration.sessionSendsLaunchEvents = true
        assetConfiguration.waitsForConnectivity = true
        assetSession = AVAssetDownloadURLSession(
            configuration: assetConfiguration,
            assetDownloadDelegate: self,
            delegateQueue: nil
        )
    }

    /// 开始下载。重复调用同一 identifier 时会复用已完成文件或抛出正在下载错误。
    @discardableResult
    func start(_ request: DownloadRequest) throws -> DownloadItem {
        guard request.url.scheme?.lowercased() == "http" || request.url.scheme?.lowercased() == "https" else {
            throw DownloadError.invalidURL
        }
        guard taskIDs.values.contains(request.identifier) == false,
              fallbackTasks[request.identifier] == nil else {
            throw DownloadError.alreadyDownloading
        }

        if let existing = items[request.identifier], existing.status == .completed {
            if let localURL = existing.localURL,
               isPlayableLocalURL(
                   localURL,
                   mediaKind: existing.mediaKind,
                   sourceKey: existing.sourceKey
               ) {
                return existing
            }
            if let localURL = existing.localURL,
               fileManager.fileExists(atPath: localURL.path) {
                try? removeDownloadedMedia(at: localURL, mediaKind: existing.mediaKind)
            }
            items.removeValue(forKey: request.identifier)
            saveManifest()
        }

        if let existing = items[request.identifier], existing.status == .paused {
            resume(identifier: request.identifier)
            return items[request.identifier] ?? existing
        }

        hlsAssetFallbackAttempted.remove(request.identifier)
        let mediaKind = Self.mediaKind(for: request.url)
        let item = DownloadItem(
            id: request.identifier,
            title: request.title,
            sourceKey: request.sourceKey,
            videoID: request.videoID,
            episodeIndex: request.episodeIndex,
            episodeName: request.episodeName,
            headers: request.headers,
            url: request.url,
            playRequestURL: request.playRequestURL,
            mediaKind: mediaKind,
            status: .queued,
            progress: 0,
            bytesWritten: 0,
            totalBytes: 0,
            speedBytesPerSecond: 0,
            localURL: nil
        )
        items[request.identifier] = item

        if request.playRequestURL != nil {
            startRefreshingDownload(identifier: request.identifier, item: item, url: request.url)
        } else if mediaKind == .hls {
            startHLSDownload(identifier: request.identifier, item: item, url: request.url)
            updateStatus(for: request.identifier, status: .downloading)
            return items[request.identifier] ?? item
        } else {
            startDirectDownload(identifier: request.identifier, item: item, url: request.url)
        }
        updateStatus(for: request.identifier, status: .downloading)
        return items[request.identifier] ?? item
    }

    /// 暂停当前下载。直链使用 URLSession resume data，普通 HLS 保留已完成分片。
    func pause(identifier: String) {
        guard let item = items[identifier], item.status == .downloading else { return }
        pausedIdentifiers.insert(identifier)

        if let fallbackTask = fallbackTasks[identifier] {
            fallbackTask.cancel()
            updateStatus(for: identifier, status: .paused)
            saveManifest()
            return
        }

        guard let taskID = taskIDs.first(where: { $0.value == identifier })?.key,
              let task = activeTasks[taskID] else {
            updateStatus(for: identifier, status: .paused)
            saveManifest()
            return
        }

        if let assetTask = task as? AVAssetDownloadTask {
            assetTask.suspend()
            updateStatus(for: identifier, status: .paused)
            saveManifest()
            return
        }

        guard let downloadTask = task as? URLSessionDownloadTask else { return }
        pendingPauseIdentifiers.insert(identifier)
        updateStatus(for: identifier, status: .paused)
        downloadTask.cancel(byProducingResumeData: { [weak self] resumeData in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let resumeData {
                    self.resumeDataByIdentifier[identifier] = resumeData
                }
                self.saveManifest()
            }
        })
    }

    /// 继续已暂停的下载。直链优先使用系统 resume data，普通 HLS 从已完成分片继续。
    func resume(identifier: String) {
        guard let item = items[identifier], item.status == .paused else { return }
        if pendingPauseIdentifiers.contains(identifier) { return }
        if fallbackTasks[identifier] != nil {
            pendingResumeIdentifiers.insert(identifier)
            return
        }

        pausedIdentifiers.remove(identifier)
        if let taskID = taskIDs.first(where: { $0.value == identifier })?.key,
           let task = activeTasks[taskID] {
            if let assetTask = task as? AVAssetDownloadTask {
                if item.playRequestURL != nil {
                    taskIDs.removeValue(forKey: taskID)
                    activeTasks.removeValue(forKey: taskID)
                    assetTask.cancel()
                    startRefreshingDownload(
                        identifier: identifier,
                        item: item,
                        url: item.url,
                        resetProgress: false,
                        forceSystemHLS: true
                    )
                } else {
                    assetTask.resume()
                    updateStatus(for: identifier, status: .downloading)
                    saveManifest()
                }
            }
            return
        }

        if item.playRequestURL != nil {
            resumeDataByIdentifier.removeValue(forKey: identifier)
            startRefreshingDownload(
                identifier: identifier,
                item: item,
                url: item.url,
                resetProgress: item.mediaKind != .hls
            )
            return
        }
        if item.mediaKind == .hls {
            startHLSDownload(identifier: identifier, item: item, url: item.url, resetProgress: false)
            updateStatus(for: identifier, status: .downloading)
            return
        }

        guard let resumeData = resumeDataByIdentifier.removeValue(forKey: identifier) else {
            updateStatus(for: identifier, status: .failed("该下载没有可用的断点数据，请重新下载"))
            saveManifest()
            return
        }
        let task = session.downloadTask(withResumeData: resumeData)
        taskIDs[task.taskIdentifier] = identifier
        activeTasks[task.taskIdentifier] = task
        progressSamples[task.taskIdentifier] = ProgressSample(
            timestamp: Date().timeIntervalSinceReferenceDate,
            bytes: item.bytesWritten,
            speedBytesPerSecond: 0
        )
        updateStatus(for: identifier, status: .downloading)
        task.resume()
    }

    func cancel(identifier: String) {
        pausedIdentifiers.remove(identifier)
        pendingPauseIdentifiers.remove(identifier)
        pendingResumeIdentifiers.remove(identifier)
        resumeDataByIdentifier.removeValue(forKey: identifier)
        if let fallbackTask = fallbackTasks.removeValue(forKey: identifier) {
            fallbackTask.cancel()
            hlsAssetFallbackAttempted.remove(identifier)
            removeHLSArtifacts(identifier: identifier)
            updateStatus(for: identifier, status: .cancelled)
            return
        }
        if let taskID = taskIDs.first(where: { $0.value == identifier })?.key,
           let task = activeTasks[taskID] {
            task.cancel()
            taskIDs.removeValue(forKey: taskID)
            activeTasks.removeValue(forKey: taskID)
            progressSamples.removeValue(forKey: taskID)
        }
        hlsAssetFallbackAttempted.remove(identifier)
        removeHLSArtifacts(identifier: identifier)
        updateStatus(for: identifier, status: .cancelled)
    }

    func delete(identifier: String) throws {
        guard let item = items[identifier] else { return }
        cancel(identifier: identifier)
        if let localURL = item.localURL {
            try removeDownloadedMedia(at: localURL, mediaKind: item.mediaKind)
        }
        items.removeValue(forKey: identifier)
        fallbackTasks.removeValue(forKey: identifier)?.cancel()
        hlsAssetFallbackAttempted.remove(identifier)
        pausedIdentifiers.remove(identifier)
        pendingPauseIdentifiers.remove(identifier)
        resumeDataByIdentifier.removeValue(forKey: identifier)
        removeHLSArtifacts(identifier: identifier)
        saveManifest()
    }

    func item(identifier: String) -> DownloadItem? {
        guard let item = items[identifier] else { return nil }
        if item.status == .completed {
            guard let localURL = item.localURL,
                  isPlayableLocalURL(
                      localURL,
                      mediaKind: item.mediaKind,
                      sourceKey: item.sourceKey
                  ) else {
                return nil
            }
        }
        return item
    }

    func localFileURL(identifier: String) -> URL? {
        guard let item = items[identifier],
              item.status == .completed,
              let localURL = item.localURL,
              fileManager.fileExists(atPath: localURL.path),
              isPlayableLocalURL(
                  localURL,
                  mediaKind: item.mediaKind,
                  sourceKey: item.sourceKey
              ) else { return nil }
        return localURL
    }

    func isDownloaded(identifier: String) -> Bool {
        localFileURL(identifier: identifier) != nil
    }

    func allItems() -> [DownloadItem] {
        items.values.map { item in
            guard item.status == .completed,
                  let localURL = item.localURL,
                  !isPlayableLocalURL(
                      localURL,
                      mediaKind: item.mediaKind,
                      sourceKey: item.sourceKey
                  ) else {
                return item
            }
            var invalidItem = item
            invalidItem.status = .failed("缓存文件无法识别为视频，请重新下载")
            return invalidItem
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// AVAssetDownloadURLSession returns a `.movpkg` directory for HLS.
    /// Treat both regular files and downloaded asset packages as playable;
    /// this also prevents stale manifest entries from opening a broken sheet.
    private func isPlayableLocalURL(
        _ url: URL,
        mediaKind: DownloadMediaKind,
        sourceKey: String = ""
    ) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        if mediaKind == .hls {
            if isDirectory.boolValue || url.pathExtension.lowercased() == "movpkg" {
                if sourceKey.caseInsensitiveCompare("guazi") == .orderedSame,
                   url.pathExtension.caseInsensitiveCompare("hlsbundle") == .orderedSame {
                    let metrics = cachedHLSMetrics(at: url)
                    return !DownloadPayloadValidator.isLikelyPreviewHLS(
                        segmentCount: metrics.segmentCount,
                        duration: metrics.duration
                    )
                }
                return true
            }
            guard url.pathExtension.lowercased() == "m3u8",
                  let data = try? Data(contentsOf: url),
                  let playlist = String(data: data.prefix(512), encoding: .utf8) else {
                return false
            }
            return playlist.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveContains("#EXTM3U")
        }
        guard !isDirectory.boolValue,
              let prefix = DownloadPayloadValidator.prefix(at: url) else { return false }
        return DownloadPayloadValidator.isSupportedMediaPayload(
            prefix: prefix,
            fileExtension: url.pathExtension
        )
    }

    private func removeDownloadedMedia(at url: URL, mediaKind: DownloadMediaKind) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        if mediaKind == .hls, url.pathExtension.lowercased() == "m3u8" {
            try fileManager.removeItem(at: url.deletingLastPathComponent())
        } else {
            try fileManager.removeItem(at: url)
        }
    }

    private func updateStatus(for identifier: String, status: DownloadStatus) {
        guard var item = items[identifier] else { return }
        item.status = status
        items[identifier] = item
    }

    @discardableResult
    private func finishPausedFallbackTask(for identifier: String) -> Bool {
        guard pausedIdentifiers.contains(identifier) else { return false }
        fallbackTasks.removeValue(forKey: identifier)
        updateStatus(for: identifier, status: .paused)
        saveManifest()
        if pendingResumeIdentifiers.remove(identifier) != nil {
            resume(identifier: identifier)
        }
        return true
    }

    private func updateProgress(
        for identifier: String,
        bytesWritten: Int64,
        totalBytes: Int64,
        speedBytesPerSecond: Double? = nil
    ) {
        guard var item = items[identifier] else { return }
        guard item.status != .paused else { return }
        let normalizedTotal = max(0, totalBytes)
        item.status = .downloading
        item.bytesWritten = bytesWritten
        item.totalBytes = normalizedTotal
        item.progress = normalizedTotal > 0
            ? min(1, max(0, Double(bytesWritten) / Double(normalizedTotal)))
            : 0
        if let speedBytesPerSecond, speedBytesPerSecond.isFinite {
            item.speedBytesPerSecond = max(0, speedBytesPerSecond)
        }
        items[identifier] = item
    }

    private func updateProgress(for identifier: String, progress: Double) {
        guard var item = items[identifier] else { return }
        guard item.status != .paused else { return }
        item.status = .downloading
        item.progress = min(1, max(0, progress.isFinite ? progress : 0))
        items[identifier] = item
    }

    private func speedSample(taskIdentifier: Int, bytes: Int64) -> Double {
        let now = Date().timeIntervalSinceReferenceDate
        let previous = progressSamples[taskIdentifier]
        let elapsed = now - (previous?.timestamp ?? now)
        let delta = bytes - (previous?.bytes ?? bytes)
        guard elapsed > 0.05, delta >= 0 else {
            return previous?.speedBytesPerSecond ?? 0
        }

        let instantaneous = Double(delta) / elapsed
        let previousSpeed = previous?.speedBytesPerSecond ?? 0
        let smoothed = previousSpeed > 0
            ? previousSpeed * 0.65 + instantaneous * 0.35
            : instantaneous
        progressSamples[taskIdentifier] = ProgressSample(
            timestamp: now,
            bytes: bytes,
            speedBytesPerSecond: smoothed
        )
        return smoothed
    }

    private static func normalizedHeaders(
        _ headers: [String: String],
        sourceKey: String? = nil
    ) -> [String: String] {
        var result = headers
        // 瓜子 CDN 会按 User-Agent 返回不同的 HLS 清单：Safari 风格
        // UA 只能拿到约 20 秒的预览，而播放器使用 KSPlayer UA 才能拿到
        // 完整点播流。下载清单、密钥和每个分片必须使用同一套请求头。
        if sourceKey?.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("guazi") == .orderedSame {
            result = result.filter {
                $0.key.caseInsensitiveCompare("User-Agent") != .orderedSame
            }
            GuaziPlaybackRequest.playbackHeaders.forEach { result[$0.key] = $0.value }
            result["Cache-Control"] = "no-cache"
            result["Pragma"] = "no-cache"
        }
        if result.keys.contains(where: { $0.caseInsensitiveCompare("User-Agent") == .orderedSame }) == false {
            result["User-Agent"] = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148"
        }
        if result.keys.contains(where: { $0.caseInsensitiveCompare("Accept") == .orderedSame }) == false {
            result["Accept"] = "*/*"
        }
        return result
    }

    private func descriptiveError(_ error: Error, task: URLSessionTask) -> String {
        let nsError = error as NSError
        let code = nsError.code
        let message = nsError.localizedFailureReason ?? nsError.localizedDescription
        let endpoint = task.currentRequest?.url?.host.map { "（\($0)）" } ?? ""
        switch code {
        case NSURLErrorCancelled:
            return "下载已取消"
        case NSURLErrorNotConnectedToInternet:
            return "当前没有网络连接，请检查网络后重试"
        case NSURLErrorTimedOut:
            return "下载请求超时，请稍后重试"
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
            return "无法连接资源站\(endpoint)"
        case NSURLErrorNetworkConnectionLost:
            return "网络连接中断，请重试"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            return "资源站 HTTPS 证书校验失败"
        default:
            return "下载失败（错误码 \(code)）：\(message)\(endpoint)"
        }
    }

    private enum HLSDownloadError: LocalizedError {
        case unsupported(String)
        case http(Int)
        case invalid(String)
        case staleAddress(String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let message), .invalid(let message), .staleAddress(let message): return message
            case .http(let status): return "播放列表或分片返回 HTTP \(status)"
            }
        }

        var shouldRefreshDynamicURL: Bool {
            switch self {
            case .http(let status): return [401, 403, 404, 410].contains(status)
            case .staleAddress: return true
            case .unsupported(_), .invalid(_): return false
            }
        }
    }

    private func startHLSDownload(
        identifier: String,
        item: DownloadItem,
        url: URL,
        resetProgress: Bool = true,
        refreshDynamicURL: Bool = true
    ) {
        guard fallbackTasks[identifier] == nil else { return }
        var updated = item
        updated.mediaKind = .hls
        if resetProgress {
            updated.progress = 0
            updated.bytesWritten = 0
            updated.totalBytes = 0
        }
        updated.speedBytesPerSecond = 0
        updated.status = .downloading
        items[identifier] = updated
        progressSamples[identifier.hashValue] = ProgressSample(
            timestamp: Date().timeIntervalSinceReferenceDate,
            bytes: 0,
            speedBytesPerSecond: 0
        )

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var effectiveURL = url
            do {
                if refreshDynamicURL {
                    effectiveURL = try await self.refreshedDownloadURL(for: updated, fallbackURL: url)
                }
                try Task.checkCancellation()
                updated.url = effectiveURL
                self.items[identifier] = updated
                do {
                    try await self.downloadOfflineHLS(identifier: identifier, item: updated, url: effectiveURL)
                } catch let error as HLSDownloadError
                    where updated.playRequestURL != nil && error.shouldRefreshDynamicURL {
                    self.removeHLSArtifacts(identifier: identifier)
                    updated.progress = 0
                    updated.bytesWritten = 0
                    updated.totalBytes = 0
                    effectiveURL = try await self.refreshedDownloadURL(for: updated, fallbackURL: effectiveURL)
                    try Task.checkCancellation()
                    updated.url = effectiveURL
                    self.items[identifier] = updated
                    try await self.downloadOfflineHLS(identifier: identifier, item: updated, url: effectiveURL)
                }
                self.fallbackTasks.removeValue(forKey: identifier)
                self.hlsAssetFallbackAttempted.remove(identifier)
            } catch is CancellationError {
                if !self.finishPausedFallbackTask(for: identifier) {
                    self.fallbackTasks.removeValue(forKey: identifier)
                    self.updateStatus(for: identifier, status: .cancelled)
                }
            } catch HLSDownloadError.unsupported(_) {
                guard !self.finishPausedFallbackTask(for: identifier) else { return }
                self.fallbackTasks.removeValue(forKey: identifier)
                guard !self.hlsAssetFallbackAttempted.contains(identifier) else {
                    self.updateStatus(for: identifier, status: .failed("该 HLS 格式暂不支持离线缓存"))
                    return
                }
                self.hlsAssetFallbackAttempted.insert(identifier)
                self.startHLSAssetDownload(identifier: identifier, item: updated, url: effectiveURL)
            } catch {
                guard !self.finishPausedFallbackTask(for: identifier) else { return }
                self.fallbackTasks.removeValue(forKey: identifier)
                self.progressSamples.removeValue(forKey: identifier.hashValue)
                self.updateStatus(for: identifier, status: .failed(error.localizedDescription))
            }
        }
        fallbackTasks[identifier] = task
    }

    private func downloadOfflineHLS(identifier: String, item: DownloadItem, url: URL) async throws {
        do {
            try await downloadPlainHLS(identifier: identifier, item: item, url: url)
        } catch HLSDownloadError.unsupported(_) {
            try Task.checkCancellation()
            try await downloadPackagedHLS(identifier: identifier, item: item, url: url)
        }
    }

    private func refreshedDownloadURL(for item: DownloadItem, fallbackURL: URL) async throws -> URL {
        guard item.sourceKey.caseInsensitiveCompare("guazi") == .orderedSame else { return fallbackURL }
        guard let playRequestURL = item.playRequestURL else { return fallbackURL }
        guard let playRequest = GuaziService.PlayRequest(url: playRequestURL.absoluteString) else {
            throw DownloadError.invalidURL
        }
        let rawURL = try await GuaziService.shared.play(playRequest)
        guard let url = URL(string: rawURL),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw DownloadError.invalidURL
        }
        return url
    }

    private func startRefreshingDownload(
        identifier: String,
        item: DownloadItem,
        url: URL,
        resetProgress: Bool = true,
        forceSystemHLS: Bool = false
    ) {
        guard fallbackTasks[identifier] == nil else { return }
        var updated = item
        updated.status = .downloading
        if resetProgress {
            updated.progress = 0
            updated.bytesWritten = 0
            updated.totalBytes = 0
        }
        items[identifier] = updated
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let effectiveURL = try await self.refreshedDownloadURL(for: updated, fallbackURL: url)
                try Task.checkCancellation()
                guard self.items[identifier]?.status == .downloading else {
                    self.fallbackTasks.removeValue(forKey: identifier)
                    return
                }
                updated.url = effectiveURL
                updated.mediaKind = Self.mediaKind(for: effectiveURL)
                self.items[identifier] = updated
                self.fallbackTasks.removeValue(forKey: identifier)
                if updated.mediaKind == .hls {
                    if forceSystemHLS {
                        self.startHLSAssetDownload(identifier: identifier, item: updated, url: effectiveURL)
                    } else {
                        self.startHLSDownload(
                            identifier: identifier,
                            item: updated,
                            url: effectiveURL,
                            resetProgress: resetProgress,
                            refreshDynamicURL: false
                        )
                    }
                } else {
                    self.startDirectDownload(identifier: identifier, item: updated, url: effectiveURL)
                }
            } catch is CancellationError {
                if !self.finishPausedFallbackTask(for: identifier) {
                    self.fallbackTasks.removeValue(forKey: identifier)
                    self.updateStatus(for: identifier, status: .cancelled)
                }
            } catch {
                guard !self.finishPausedFallbackTask(for: identifier) else { return }
                self.fallbackTasks.removeValue(forKey: identifier)
                self.updateStatus(for: identifier, status: .failed(error.localizedDescription))
            }
        }
        fallbackTasks[identifier] = task
    }

    private func startDirectDownload(identifier: String, item: DownloadItem, url: URL) {
        var urlRequest = URLRequest(url: url)
        Self.normalizedHeaders(item.headers, sourceKey: item.sourceKey)
            .forEach { urlRequest.setValue($1, forHTTPHeaderField: $0) }
        let task = session.downloadTask(with: urlRequest)
        taskIDs[task.taskIdentifier] = identifier
        activeTasks[task.taskIdentifier] = task
        progressSamples.removeValue(forKey: task.taskIdentifier)
        task.resume()
    }

    private func startHLSAssetDownload(identifier: String, item: DownloadItem, url: URL) {
        let headers = Self.normalizedHeaders(item.headers, sourceKey: item.sourceKey)
        let assetOptions: [String: Any]? = headers.isEmpty
            ? nil
            : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset = AVURLAsset(url: url, options: assetOptions)
        guard let task = assetSession.makeAssetDownloadTask(
            asset: asset,
            assetTitle: item.title,
            assetArtworkData: nil,
            options: nil
        ) else {
            hlsAssetFallbackAttempted.remove(identifier)
            updateStatus(for: identifier, status: .failed("系统无法创建 HLS 离线缓存任务"))
            return
        }
        taskIDs[task.taskIdentifier] = identifier
        activeTasks[task.taskIdentifier] = task
        progressSamples.removeValue(forKey: task.taskIdentifier)
        task.resume()
    }

    /// Cache an HLS presentation as a local playlist plus its referenced media.
    /// Keeping the playlist structure intact supports fMP4, byte ranges,
    /// alternate audio, subtitles, and AES-128 key resources without remuxing.
    private func downloadPackagedHLS(identifier: String, item: DownloadItem, url: URL) async throws {
        let headers = Self.normalizedHeaders(item.headers, sourceKey: item.sourceKey)
        let cacheDirectory = hlsSegmentDirectory(identifier: identifier)
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        defer {
            if !self.pausedIdentifiers.contains(identifier) {
                try? fileManager.removeItem(at: cacheDirectory)
            }
        }

        let context = HLSCacheContext()
        let cachedIndex = try await cacheHLSResource(
            url: url,
            identifier: identifier,
            headers: headers,
            directory: cacheDirectory,
            context: context
        )
        try Task.checkCancellation()
        guard cachedIndex.pathExtension.lowercased() == "m3u8",
              let indexContent = try? String(contentsOf: cachedIndex, encoding: .utf8),
              indexContent.localizedCaseInsensitiveContains("#EXTM3U") else {
            throw HLSDownloadError.invalid("下载内容没有生成有效的本地 HLS 播放清单")
        }
        if item.sourceKey.caseInsensitiveCompare("guazi") == .orderedSame {
            let metrics = cachedHLSMetrics(at: cacheDirectory)
            if DownloadPayloadValidator.isLikelyPreviewHLS(
                segmentCount: max(metrics.segmentCount, context.mediaSegmentCount),
                duration: max(metrics.duration, context.mediaDuration)
            ) {
                throw HLSDownloadError.staleAddress(
                    "瓜子返回的是短预览流，已拒绝保存并准备重新解析完整视频"
                )
            }
        }
        try validateLocalHLSPackage(at: cachedIndex, rootDirectory: cacheDirectory)

        let finalDirectory = hlsPackageDirectory(for: item)
        if fileManager.fileExists(atPath: finalDirectory.path) {
            try fileManager.removeItem(at: finalDirectory)
        }
        try fileManager.moveItem(at: cacheDirectory, to: finalDirectory)
        let localIndex = finalDirectory.appendingPathComponent(cachedIndex.lastPathComponent)

        var completed = item
        completed.mediaKind = .hls
        completed.status = .completed
        completed.progress = 1
        let packageBytes = directorySize(at: finalDirectory)
        completed.bytesWritten = packageBytes
        completed.totalBytes = packageBytes
        completed.speedBytesPerSecond = 0
        completed.localURL = localIndex
        items[identifier] = completed
        saveManifest()
        progressSamples.removeValue(forKey: identifier.hashValue)
    }

    private func validateLocalHLSPackage(at playlistURL: URL, rootDirectory: URL) throws {
        var visited = Set<String>()
        try validateLocalHLSPlaylist(
            at: playlistURL,
            rootDirectory: rootDirectory.standardizedFileURL,
            visited: &visited
        )
    }

    private func validateLocalHLSPlaylist(
        at playlistURL: URL,
        rootDirectory: URL,
        visited: inout Set<String>
    ) throws {
        let rootPath = rootDirectory.path + "/"
        let playlistPath = playlistURL.standardizedFileURL.path
        guard playlistPath.hasPrefix(rootPath),
              let playlist = try? String(contentsOf: playlistURL, encoding: .utf8),
              playlist.localizedCaseInsensitiveContains("#EXTM3U") else {
            throw HLSDownloadError.invalid("离线播放清单结构无效")
        }
        guard visited.insert(playlistPath).inserted else { return }

        let resources = HLSOfflineManifest.referencedResourceURLs(in: playlist, baseURL: playlistURL)
        guard !resources.isEmpty else {
            throw HLSDownloadError.invalid("离线播放清单没有媒体资源")
        }
        for resourceURL in resources {
            let localURL = resourceURL.standardizedFileURL
            guard localURL.isFileURL,
                  localURL.path.hasPrefix(rootPath),
                  fileManager.fileExists(atPath: localURL.path),
                  fileSize(at: localURL) > 0 else {
                throw HLSDownloadError.invalid("离线缓存缺少播放清单引用的媒体资源")
            }
            if localURL.pathExtension.caseInsensitiveCompare("m3u8") == .orderedSame {
                try validateLocalHLSPlaylist(
                    at: localURL,
                    rootDirectory: rootDirectory,
                    visited: &visited
                )
            }
        }
    }

    private func cacheHLSResource(
        url: URL,
        identifier: String,
        headers: [String: String],
        directory: URL,
        context: HLSCacheContext
    ) async throws -> URL {
        try Task.checkCancellation()
        let key = url.absoluteString
        if context.activeURLs.contains(key) {
            throw HLSDownloadError.invalid("HLS 播放清单存在循环引用")
        }
        if let cached = context.localURLs[key] {
            return cached
        }

        context.resourceCount += 1
        let playlistFile = cachedHLSResourceURL(for: url, directory: directory, fileExtension: "m3u8")
        if let savedPlaylist = try? String(contentsOf: playlistFile, encoding: .utf8),
           savedPlaylist.localizedCaseInsensitiveContains("#EXTM3U") {
            context.plannedResourceCount += Self.hlsReferencedResourceCount(savedPlaylist)
            let metrics = DownloadPayloadValidator.hlsPlaylistMetrics(savedPlaylist)
            context.mediaSegmentCount += metrics.segmentCount
            context.mediaDuration += metrics.duration
            context.localURLs[key] = playlistFile
            recordHLSResourceProgress(
                identifier: identifier,
                context: context,
                bytes: fileSize(at: playlistFile)
            )
            return playlistFile
        }

        let resourceFile = cachedHLSResourceURL(for: url, directory: directory, fileExtension: nil)
        if fileManager.fileExists(atPath: resourceFile.path), fileSize(at: resourceFile) > 0 {
            context.localURLs[key] = resourceFile
            recordHLSResourceProgress(
                identifier: identifier,
                context: context,
                bytes: fileSize(at: resourceFile)
            )
            return resourceFile
        }

        context.activeURLs.insert(key)
        defer { context.activeURLs.remove(key) }

        do {
            let response = try await fetchHLSResource(
                url: url,
                identifier: identifier,
                headers: headers,
                context: context
            )

            if Self.looksLikeHLSPlaylist(response.data) {
                guard let playlist = String(data: response.data, encoding: .utf8) else {
                    throw HLSDownloadError.invalid("HLS 播放清单不是有效文本")
                }
                context.plannedResourceCount += Self.hlsReferencedResourceCount(playlist)
                let metrics = DownloadPayloadValidator.hlsPlaylistMetrics(playlist)
                context.mediaSegmentCount += metrics.segmentCount
                context.mediaDuration += metrics.duration
                let rewritten = try await rewriteHLSPlaylist(
                    playlist,
                    baseURL: response.finalURL,
                    identifier: identifier,
                    headers: headers,
                    directory: directory,
                    context: context
                )
                try Data(rewritten.utf8).write(to: playlistFile, options: .atomic)
                context.localURLs[key] = playlistFile
                recordHLSResourceProgress(
                    identifier: identifier,
                    context: context,
                    bytes: Int64(response.data.count)
                )
                return playlistFile
            }

            context.expectedBytes += max(0, response.expectedBytes)
            guard !Self.isRejectedHLSResource(response.data, mimeType: response.mimeType) else {
                throw HLSDownloadError.staleAddress("HLS 分片或密钥返回了错误页，不是媒体内容")
            }
            guard !response.data.isEmpty else {
                throw HLSDownloadError.staleAddress("HLS 分片返回了空响应")
            }
            try response.data.write(to: resourceFile, options: .atomic)
            context.localURLs[key] = resourceFile
            recordHLSResourceProgress(
                identifier: identifier,
                context: context,
                bytes: Int64(response.data.count)
            )
            return resourceFile
        } catch {
            context.inFlightBytesByResource.removeValue(forKey: key)
            context.inFlightExpectedBytesByResource.removeValue(forKey: key)
            context.localURLs.removeValue(forKey: key)
            throw error
        }
    }

    private func directorySize(at url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else {
            return fileSize(at: url)
        }
        var total: Int64 = 0
        while let fileURL = enumerator.nextObject() as? URL {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private func cachedHLSMetrics(at directory: URL) -> DownloadPayloadValidator.HLSPlaylistMetrics {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return .init(segmentCount: 0, duration: 0)
        }

        var segmentCount = 0
        var duration: TimeInterval = 0
        while let fileURL = enumerator.nextObject() as? URL {
            guard fileURL.pathExtension.caseInsensitiveCompare("m3u8") == .orderedSame,
                  let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true,
                  let playlist = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }
            let metrics = DownloadPayloadValidator.hlsPlaylistMetrics(playlist)
            segmentCount += metrics.segmentCount
            duration += metrics.duration
        }
        return .init(segmentCount: segmentCount, duration: duration)
    }

    private func rewriteHLSPlaylist(
        _ playlist: String,
        baseURL: URL,
        identifier: String,
        headers: [String: String],
        directory: URL,
        context: HLSCacheContext
    ) async throws -> String {
        let lines = playlist.components(separatedBy: .newlines)
        if let variant = HLSOfflineManifest.highestVariant(in: playlist, baseURL: baseURL) {
            var output = ["#EXTM3U"]
            for rawLine in lines {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard line.hasPrefix("#"),
                      !line.uppercased().hasPrefix("#EXTM3U"),
                      !line.uppercased().hasPrefix("#EXT-X-STREAM-INF:") else {
                    continue
                }
                if line.uppercased().hasPrefix("#EXT-X-MEDIA:") {
                    guard let group = HLSOfflineManifest.mediaGroup(in: line),
                          variant.mediaGroups.contains(group) else {
                        continue
                    }
                }
                output.append(try await rewriteHLSURIAttribute(
                    in: line,
                    baseURL: baseURL,
                    identifier: identifier,
                    headers: headers,
                    directory: directory,
                    context: context
                ))
            }

            let variantURL = try await cacheHLSResource(
                url: variant.playlistURL,
                identifier: identifier,
                headers: headers,
                directory: directory,
                context: context
            )
            output.append(variant.streamInfo)
            output.append(variantURL.lastPathComponent)
            return output.joined(separator: "\n") + "\n"
        }

        guard playlist.localizedCaseInsensitiveContains("#EXT-X-ENDLIST") else {
            throw HLSDownloadError.unsupported("该 HLS 清单不是已结束的点播流")
        }
        let resources = HLSOfflineManifest.referencedResourceURLs(in: playlist, baseURL: baseURL)
        try await cacheHLSResources(
            resources,
            identifier: identifier,
            headers: headers,
            directory: directory,
            context: context
        )

        var output: [String] = []
        for rawLine in lines {
            try Task.checkCancellation()
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                output.append(try await rewriteHLSURIAttribute(
                    in: line,
                    baseURL: baseURL,
                    identifier: identifier,
                    headers: headers,
                    directory: directory,
                    context: context
                ))
                continue
            }
            guard let resourceURL = URL(string: line, relativeTo: baseURL)?.absoluteURL,
                  ["http", "https"].contains(resourceURL.scheme?.lowercased() ?? "") else {
                throw HLSDownloadError.invalid("HLS 分片地址无效")
            }
            let localURL = try await cacheHLSResource(
                url: resourceURL,
                identifier: identifier,
                headers: headers,
                directory: directory,
                context: context
            )
            output.append(localURL.lastPathComponent)
        }
        return output.joined(separator: "\n") + "\n"
    }

    private func cacheHLSResources(
        _ resources: [URL],
        identifier: String,
        headers: [String: String],
        directory: URL,
        context: HLSCacheContext
    ) async throws {
        guard !resources.isEmpty else { return }

        let concurrencyLimit = min(Self.maxConcurrentHLSRequests, resources.count)
        try await withThrowingTaskGroup(of: Void.self) { group in
            var nextIndex = 0
            while nextIndex < concurrencyLimit {
                let resourceURL = resources[nextIndex]
                nextIndex += 1
                group.addTask {
                    _ = try await self.cacheHLSResource(
                        url: resourceURL,
                        identifier: identifier,
                        headers: headers,
                        directory: directory,
                        context: context
                    )
                }
            }

            while let _ = try await group.next() {
                try Task.checkCancellation()
                guard nextIndex < resources.count else { continue }
                let resourceURL = resources[nextIndex]
                nextIndex += 1
                group.addTask {
                    _ = try await self.cacheHLSResource(
                        url: resourceURL,
                        identifier: identifier,
                        headers: headers,
                        directory: directory,
                        context: context
                    )
                }
            }
        }
    }

    private func rewriteHLSURIAttribute(
        in line: String,
        baseURL: URL,
        identifier: String,
        headers: [String: String],
        directory: URL,
        context: HLSCacheContext
    ) async throws -> String {
        guard let uri = HLSOfflineManifest.uri(in: line) else { return line }
        guard let remoteURL = URL(string: uri, relativeTo: baseURL)?.absoluteURL else {
            throw HLSDownloadError.invalid("HLS URI 资源地址无效")
        }
        guard ["http", "https"].contains(remoteURL.scheme?.lowercased() ?? "") else {
            throw HLSDownloadError.unsupported("该 HLS 使用播放器无法离线重建的密钥协议")
        }
        let localURL = try await cacheHLSResource(
            url: remoteURL,
            identifier: identifier,
            headers: headers,
            directory: directory,
            context: context
        )
        return HLSOfflineManifest.replacingURI(in: line, with: localURL.lastPathComponent)
    }

    private func fetchHLSResource(
        url: URL,
        identifier: String,
        headers: [String: String],
        context: HLSCacheContext
    ) async throws -> HLSResourceResponse {
        var lastError: Error?
        for attempt in 0..<3 {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            request.timeoutInterval = 45
            do {
                let (bytes, response) = try await hlsResourceSession.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw HLSDownloadError.invalid("HLS 媒体资源响应无效")
                }
                guard (200...299).contains(http.statusCode) else {
                    throw HLSDownloadError.http(http.statusCode)
                }

                let expectedBytes = max(0, http.expectedContentLength)
                var data = Data()
                if expectedBytes > 0,
                   expectedBytes <= Int64(Int.max) {
                    data.reserveCapacity(Int(expectedBytes))
                } else {
                    data.reserveCapacity(64 * 1024)
                }

                var chunk = Data()
                chunk.reserveCapacity(64 * 1024)
                var receivedBytes: Int64 = 0
                var resourceIsPlaylist: Bool?
                let resourceKey = url.absoluteString
                context.inFlightBytesByResource[resourceKey] = 0
                context.inFlightExpectedBytesByResource[resourceKey] = expectedBytes
                do {
                    for try await byte in bytes {
                        chunk.append(byte)
                        if chunk.count >= 64 * 1024 {
                            data.append(contentsOf: chunk)
                            receivedBytes += Int64(chunk.count)
                            chunk.removeAll(keepingCapacity: true)
                            if resourceIsPlaylist == nil {
                                resourceIsPlaylist = Self.looksLikeHLSPlaylist(data)
                            }
                            if resourceIsPlaylist == false {
                                updateHLSStreamingProgress(
                                    identifier: identifier,
                                    context: context,
                                    resourceKey: resourceKey,
                                    currentBytes: receivedBytes,
                                    currentExpectedBytes: expectedBytes
                                )
                            }
                        }
                    }

                    if !chunk.isEmpty {
                        data.append(contentsOf: chunk)
                        receivedBytes += Int64(chunk.count)
                    }
                    if resourceIsPlaylist == nil {
                        resourceIsPlaylist = Self.looksLikeHLSPlaylist(data)
                    }
                    if resourceIsPlaylist == false {
                        updateHLSStreamingProgress(
                            identifier: identifier,
                            context: context,
                            resourceKey: resourceKey,
                            currentBytes: receivedBytes,
                            currentExpectedBytes: expectedBytes
                        )
                    }
                } catch {
                    context.inFlightBytesByResource.removeValue(forKey: resourceKey)
                    context.inFlightExpectedBytesByResource.removeValue(forKey: resourceKey)
                    throw error
                }

                context.inFlightBytesByResource.removeValue(forKey: resourceKey)
                context.inFlightExpectedBytesByResource.removeValue(forKey: resourceKey)
                return HLSResourceResponse(
                    data: data,
                    finalURL: http.url ?? url,
                    mimeType: http.mimeType,
                    expectedBytes: expectedBytes
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                lastError = error
                if attempt < 2 {
                    try await Task.sleep(nanoseconds: UInt64((attempt + 1) * 400_000_000))
                }
            }
        }
        throw lastError ?? HLSDownloadError.invalid("HLS 媒体资源下载失败")
    }

    private func updateHLSStreamingProgress(
        identifier: String,
        context: HLSCacheContext,
        resourceKey: String,
        currentBytes: Int64,
        currentExpectedBytes: Int64
    ) {
        context.inFlightBytesByResource[resourceKey] = max(0, currentBytes)
        context.inFlightExpectedBytesByResource[resourceKey] = max(0, currentExpectedBytes)
        guard var item = items[identifier], item.status != .paused else { return }

        let inFlightBytes = context.inFlightBytesByResource.values.reduce(0, +)
        let downloaded = context.bytesWritten + inFlightBytes
        let inFlightExpectedBytes = context.inFlightExpectedBytesByResource.values.reduce(0, +)
        let expected = max(
            context.expectedBytes + inFlightExpectedBytes,
            downloaded
        )
        let denominator = max(
            max(context.resourceCount, context.plannedResourceCount),
            context.completedCount + context.activeURLs.count
        )
        let inFlightFraction = context.inFlightBytesByResource.reduce(0.0) { partial, entry in
            let expectedBytes = context.inFlightExpectedBytesByResource[entry.key] ?? 0
            guard expectedBytes > 0 else { return partial }
            return partial + min(1, max(0, Double(entry.value) / Double(expectedBytes)))
        }
        let resourceFraction = (Double(context.completedCount) + inFlightFraction)
            / Double(max(1, denominator))
        let fraction = resourceFraction
        let speed = speedSample(
            taskIdentifier: identifier.hashValue,
            bytes: downloaded
        )

        item.status = .downloading
        item.progress = max(item.progress, min(0.999, fraction))
        item.bytesWritten = downloaded
        item.totalBytes = expected
        item.speedBytesPerSecond = speed
        items[identifier] = item
    }

    private func recordHLSResourceProgress(
        identifier: String,
        context: HLSCacheContext,
        bytes: Int64
    ) {
        context.completedCount += 1
        context.bytesWritten += max(0, bytes)
        let speed = speedSample(taskIdentifier: identifier.hashValue, bytes: context.bytesWritten)
        let denominator = max(
            max(context.resourceCount, context.plannedResourceCount),
            context.completedCount + context.activeURLs.count
        )
        let resourceFraction = Double(context.completedCount) / Double(max(1, denominator))
        let fraction = resourceFraction
        if var item = items[identifier], item.status != .paused {
            item.status = .downloading
            item.progress = max(item.progress, min(0.999, fraction))
            item.bytesWritten = context.bytesWritten
            item.totalBytes = max(context.expectedBytes, context.bytesWritten)
            item.speedBytesPerSecond = speed
            items[identifier] = item
        }
    }

    private func cachedHLSResourceURL(
        for url: URL,
        directory: URL,
        fileExtension forcedExtension: String?
    ) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
        let ext = forcedExtension
            ?? (url.pathExtension.isEmpty ? "bin" : safeFileComponent(url.pathExtension.lowercased()))
        return directory.appendingPathComponent("\(digest).\(ext)")
    }

    private func hlsPackageDirectory(for item: DownloadItem) -> URL {
        destinationURL(for: item, mimeType: nil, forcedExtension: "hlsbundle")
    }

    private func fileSize(at url: URL) -> Int64 {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func hlsReferencedResourceCount(_ playlist: String) -> Int {
        var count = 0
        var expectsURI = false

        for rawLine in playlist.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let uppercased = line.uppercased()

            if uppercased.hasPrefix("#EXTINF:")
                || uppercased.hasPrefix("#EXT-X-STREAM-INF:") {
                expectsURI = true
                continue
            }

            if uppercased.hasPrefix("#EXT-X-MEDIA:")
                || uppercased.hasPrefix("#EXT-X-KEY:")
                || uppercased.hasPrefix("#EXT-X-MAP:") {
                if HLSOfflineManifest.uri(in: line) != nil {
                    count += 1
                }
                continue
            }

            guard expectsURI, !line.hasPrefix("#") else { continue }
            count += 1
            expectsURI = false
        }
        return count
    }

    private static func looksLikeHLSPlaylist(_ data: Data) -> Bool {
        guard let text = String(data: data.prefix(1024), encoding: .utf8) else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveContains("#EXTM3U")
    }

    private static func isRejectedHLSResource(_ data: Data, mimeType: String?) -> Bool {
        let mime = mimeType?.lowercased() ?? ""
        if mime.contains("text/html")
            || mime.contains("application/json")
            || mime.contains("application/xml")
            || mime.contains("text/xml")
            || mime.contains("javascript") {
            return true
        }
        guard let text = String(data: data.prefix(1024), encoding: .utf8) else { return false }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("#extm3u") || value.hasPrefix("webvtt") { return false }
        if value.hasPrefix("<!doctype html") || value.hasPrefix("<html")
            || value.hasPrefix("{") || value.hasPrefix("[") {
            return true
        }
        return [
            "access denied",
            "request forbidden",
            "forbidden",
            "bad gateway",
            "error 403",
            "error 404",
            "unauthorized",
            "verify you are human",
            "security check",
            "访问受限",
            "请求异常",
            "校验失败"
        ].contains { value.contains($0) }
    }

    private func downloadPlainHLS(identifier: String, item: DownloadItem, url: URL) async throws {
        let headers = Self.normalizedHeaders(item.headers, sourceKey: item.sourceKey)
        let initialPlaylist = try await Self.fetchHLSPlaylist(url: url, headers: headers)
        // URLSession follows redirects; relative URIs must be resolved against
        // the final response URL, not the pre-redirect request URL.
        var playlistURL = initialPlaylist.finalURL
        var playlist = initialPlaylist.playlist
        // Some Guazi CDN responses contain more than one level of variant
        // playlist. Resolve the chain before treating the leaf playlist as a
        // segment list; otherwise a nested #EXTM3U is mistaken for a bad
        // segment response later in the download.
        for _ in 0..<3 {
            guard let variantURL = Self.highestVariantURL(baseURL: playlistURL, playlist: playlist) else {
                break
            }
            let variantPlaylist = try await Self.fetchHLSPlaylist(url: variantURL, headers: headers)
            playlistURL = variantPlaylist.finalURL
            playlist = variantPlaylist.playlist
        }
        let segments = try Self.parsePlainTSPlaylist(baseURL: playlistURL, playlist: playlist)
        guard !segments.isEmpty else { throw HLSDownloadError.invalid("播放列表中没有可下载分片") }
        if item.sourceKey.caseInsensitiveCompare("guazi") == .orderedSame {
            let metrics = DownloadPayloadValidator.hlsPlaylistMetrics(playlist)
            if DownloadPayloadValidator.isLikelyPreviewHLS(
                segmentCount: metrics.segmentCount,
                duration: metrics.duration
            ) {
                throw HLSDownloadError.staleAddress(
                    "瓜子返回的是短预览流，已重新解析完整视频后再下载"
                )
            }
        }

        let segmentDirectory = hlsSegmentDirectory(identifier: identifier)
        let outputPart = hlsOutputPartURL(identifier: identifier)
        try fileManager.createDirectory(at: segmentDirectory, withIntermediateDirectories: true)
        defer {
            if !self.pausedIdentifiers.contains(identifier) {
                try? fileManager.removeItem(at: segmentDirectory)
            }
            try? fileManager.removeItem(at: outputPart)
        }

        var segmentFiles = Array<URL?>(repeating: nil, count: segments.count)
        var pendingIndices: [Int] = []
        var completedCount = 0
        var completedBytes: Int64 = 0
        let progressKey = identifier.hashValue

        for index in segments.indices {
            let segmentFile = segmentDirectory.appendingPathComponent(String(format: "%06d.seg", index))
            let attributes = try? fileManager.attributesOfItem(atPath: segmentFile.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let prefix = DownloadPayloadValidator.prefix(at: segmentFile)
            if size > 0, let prefix, DownloadPayloadValidator.isMPEGTransportStream(prefix) {
                segmentFiles[index] = segmentFile
                completedCount += 1
                completedBytes += size
            } else {
                try? fileManager.removeItem(at: segmentFile)
                pendingIndices.append(index)
            }
        }
        if var progressItem = self.items[identifier] {
            progressItem.status = .downloading
            progressItem.progress = Double(completedCount) / Double(segments.count)
            progressItem.bytesWritten = completedBytes
            progressItem.totalBytes = estimatedTotalBytes(
                completedBytes: completedBytes,
                completedCount: completedCount,
                totalCount: segments.count
            )
            progressItem.speedBytesPerSecond = 0
            self.items[identifier] = progressItem
        }

        try await withThrowingTaskGroup(of: (Int, URL, Int64).self) { group in
            var nextPending = 0
            let initialCount = min(Self.maxConcurrentHLSRequests, pendingIndices.count)
            for _ in 0..<initialCount {
                let index = pendingIndices[nextPending]
                nextPending += 1
                group.addTask {
                    try await self.downloadHLSSegment(
                        index: index,
                        url: segments[index],
                        headers: headers,
                        directory: segmentDirectory
                    )
                }
            }

            while let result = try await group.next() {
                try Task.checkCancellation()
                segmentFiles[result.0] = result.1
                completedCount += 1
                completedBytes += result.2
                let speed = self.speedSample(taskIdentifier: progressKey, bytes: completedBytes)
                if var progressItem = self.items[identifier] {
                    progressItem.status = .downloading
                    progressItem.progress = Double(completedCount) / Double(segments.count)
                    progressItem.bytesWritten = completedBytes
                    progressItem.totalBytes = estimatedTotalBytes(
                        completedBytes: completedBytes,
                        completedCount: completedCount,
                        totalCount: segments.count
                    )
                    progressItem.speedBytesPerSecond = speed
                    self.items[identifier] = progressItem
                }
                if nextPending < pendingIndices.count {
                    let index = pendingIndices[nextPending]
                    nextPending += 1
                    group.addTask {
                        try await self.downloadHLSSegment(
                            index: index,
                            url: segments[index],
                            headers: headers,
                            directory: segmentDirectory
                        )
                    }
                }
            }
        }

        try Task.checkCancellation()
        guard segmentFiles.allSatisfy({ $0 != nil }) else {
            throw HLSDownloadError.invalid("分片下载不完整")
        }
        fileManager.createFile(atPath: outputPart.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputPart)
        defer { try? output.close() }
        for segmentFile in segmentFiles.compactMap({ $0 }) {
            try Task.checkCancellation()
            try output.write(contentsOf: Data(contentsOf: segmentFile))
        }
        try output.close()

        let outputAttributes = try? fileManager.attributesOfItem(atPath: outputPart.path)
        let outputSize = (outputAttributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard fileManager.fileExists(atPath: outputPart.path),
              outputSize > 0,
              let outputPrefix = DownloadPayloadValidator.prefix(at: outputPart),
              DownloadPayloadValidator.isMPEGTransportStream(outputPrefix) else {
            throw HLSDownloadError.staleAddress("合并结果不是有效的视频分片，可能返回了资源站校验内容")
        }
        let destination = destinationURL(for: item, mimeType: "video/mp2t", forcedExtension: "ts")
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: outputPart, to: destination)
        var completed = item
        completed.mediaKind = .directFile
        completed.status = .completed
        completed.progress = 1
        completed.bytesWritten = completedBytes
        completed.totalBytes = completedBytes
        completed.speedBytesPerSecond = 0
        completed.localURL = destination
        items[identifier] = completed
        saveManifest()
        progressSamples.removeValue(forKey: progressKey)
    }

    private func estimatedTotalBytes(
        completedBytes: Int64,
        completedCount: Int,
        totalCount: Int
    ) -> Int64 {
        guard completedBytes > 0, completedCount > 0, totalCount > 0 else { return 0 }
        let estimate = Double(completedBytes) / Double(completedCount) * Double(totalCount)
        guard estimate.isFinite, estimate < Double(Int64.max) else { return completedBytes }
        return max(completedBytes, Int64(estimate))
    }

    private static func fetchHLSPlaylist(
        url: URL,
        headers: [String: String]
    ) async throws -> (playlist: String, finalURL: URL) {
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.timeoutInterval = 30
        let result: (Data, URLResponse)
        do {
            result = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
        let (data, response) = result
        guard let http = response as? HTTPURLResponse else {
            throw HLSDownloadError.invalid("播放列表响应无效")
        }
        guard (200...299).contains(http.statusCode) else {
            throw HLSDownloadError.http(http.statusCode)
        }
        guard let playlist = String(data: data, encoding: .utf8) else {
            throw HLSDownloadError.unsupported("服务器返回的不是文本 HLS 播放列表")
        }
        guard playlist.localizedCaseInsensitiveContains("#EXTM3U") else {
            if looksLikeTextError(data) {
                throw HLSDownloadError.staleAddress("播放列表返回了错误页")
            }
            throw HLSDownloadError.unsupported("服务器返回的不是有效 HLS 播放列表")
        }
        return (playlist, http.url ?? url)
    }

    private static func highestVariantURL(baseURL: URL, playlist: String) -> URL? {
        let lines = playlist.components(separatedBy: .newlines)
        var best: (bandwidth: Int, url: URL)?
        for index in lines.indices where lines[index].uppercased().hasPrefix("#EXT-X-STREAM-INF:") {
            let attributes = String(lines[index].dropFirst("#EXT-X-STREAM-INF:".count))
            let bandwidth = attributes
                .split(separator: ",")
                .first(where: { $0.uppercased().hasPrefix("BANDWIDTH=") })
                .flatMap { Int($0.split(separator: "=", maxSplits: 1).last ?? "") } ?? 0
            var next = index + 1
            while next < lines.count {
                let value = lines[next].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty && !value.hasPrefix("#") {
                    if let url = URL(string: value, relativeTo: baseURL)?.absoluteURL,
                       best == nil || bandwidth > best!.bandwidth {
                        best = (bandwidth, url)
                    }
                    break
                }
                next += 1
            }
        }
        return best?.url
    }

    private static func parsePlainTSPlaylist(baseURL: URL, playlist: String) throws -> [URL] {
        guard playlist.localizedCaseInsensitiveContains("#EXT-X-ENDLIST") else {
            throw HLSDownloadError.unsupported("该地址不是有限点播流")
        }
        let upper = playlist.uppercased()
        if upper.contains("#EXT-X-STREAM-INF:") {
            throw HLSDownloadError.unsupported("播放列表仍包含多层清晰度索引，交由系统转换")
        }
        if upper.contains("#EXT-X-MAP:") || upper.contains("#EXT-X-BYTERANGE:") {
            throw HLSDownloadError.unsupported("该 HLS 使用 fMP4 或 BYTERANGE，交由系统转换")
        }
        for line in playlist.components(separatedBy: .newlines) where line.uppercased().hasPrefix("#EXT-X-KEY:") {
            if !line.uppercased().contains("METHOD=NONE") {
                throw HLSDownloadError.unsupported("该 HLS 使用加密分片，交由系统转换")
            }
        }
        var urls: [URL] = []
        var expectsURL = false
        for rawLine in playlist.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.uppercased().hasPrefix("#EXTINF:") {
                expectsURL = true
                continue
            }
            if line.hasPrefix("#") { continue }
            guard expectsURL else { continue }
            guard let segmentURL = URL(string: line, relativeTo: baseURL)?.absoluteURL else {
                throw HLSDownloadError.invalid("分片地址无效")
            }
            let segmentExtension = segmentURL.pathExtension.lowercased()
            if ["m4s", "mp4", "m4a", "aac", "mp3", "vtt", "webvtt"].contains(segmentExtension) {
                throw HLSDownloadError.unsupported("该 HLS 使用非 MPEG-TS 分片，交由系统转换")
            }
            urls.append(segmentURL)
            expectsURL = false
        }
        guard !urls.isEmpty else { throw HLSDownloadError.invalid("没有找到有效 MPEG-TS 分片") }
        return urls
    }

    private func downloadHLSSegment(
        index: Int,
        url: URL,
        headers: [String: String],
        directory: URL
    ) async throws -> (Int, URL, Int64) {
        let destination = directory.appendingPathComponent(String(format: "%06d.seg", index))
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                try Task.checkCancellation()
                var request = URLRequest(url: url)
                headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
                request.timeoutInterval = 45
                let (data, response) = try await hlsResourceSession.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw HLSDownloadError.invalid("分片响应无效")
                }
                guard (200...299).contains(http.statusCode) else {
                    throw HLSDownloadError.http(http.statusCode)
                }
                guard !data.isEmpty else {
                    throw HLSDownloadError.staleAddress("分片返回了空响应")
                }
                if Self.looksLikeHLSPlaylistLegacy(data) {
                    // A segment URL returning another playlist is not a TS
                    // payload. Hand it to the existing AVAsset fallback.
                    throw HLSDownloadError.unsupported("分片返回了 HLS 播放列表，交由系统转换")
                }
                guard !DownloadPayloadValidator.isRejectedPayload(
                    data,
                    mimeType: http.mimeType
                ) else {
                    throw HLSDownloadError.staleAddress("分片返回了错误页")
                }
                guard DownloadPayloadValidator.isMPEGTransportStream(data) else {
                    throw HLSDownloadError.unsupported("该 HLS 使用非 MPEG-TS 分片")
                }
                try data.write(to: destination, options: .atomic)
                return (index, destination, Int64(data.count))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if attempt < 2 {
                    try await Task.sleep(nanoseconds: UInt64((attempt + 1) * 400_000_000))
                }
            }
        }
        throw lastError ?? HLSDownloadError.invalid("分片下载失败")
    }

    private static func looksLikeTextError(_ data: Data) -> Bool {
        return DownloadPayloadValidator.isRejectedPayload(data)
    }

    private static func looksLikeHLSPlaylistLegacy(_ data: Data) -> Bool {
        guard let text = String(data: data.prefix(512), encoding: .utf8) else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("#extm3u")
    }

    nonisolated private static func looksLikeHLS(response: URLResponse?, location: URL) -> Bool {
        if let mimeType = response?.mimeType?.lowercased(), mimeType.contains("mpegurl") {
            return true
        }
        guard let handle = try? FileHandle(forReadingFrom: location) else { return false }
        let prefix = (try? handle.read(upToCount: 256)) ?? Data()
        try? handle.close()
        guard let text = String(data: prefix, encoding: .utf8) else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U")
    }

    nonisolated private static func looksLikeHTML(response: URLResponse?, location: URL) -> Bool {
        if let mimeType = response?.mimeType?.lowercased(), mimeType.contains("text/html") {
            return true
        }
        guard let handle = try? FileHandle(forReadingFrom: location) else { return false }
        let prefix = (try? handle.read(upToCount: 256)) ?? Data()
        try? handle.close()
        guard let text = String(data: prefix, encoding: .utf8) else { return false }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("<!doctype html") || normalized.hasPrefix("<html")
    }

    private func hlsArtifactToken(for identifier: String) -> String {
        SHA256.hash(data: Data(identifier.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func hlsSegmentDirectory(identifier: String) -> URL {
        downloadsDirectory.appendingPathComponent(
            ".hls-\(hlsArtifactToken(for: identifier))",
            isDirectory: true
        )
    }

    private func hlsOutputPartURL(identifier: String) -> URL {
        downloadsDirectory.appendingPathComponent(
            ".download-\(hlsArtifactToken(for: identifier)).ts.part"
        )
    }

    private func removeHLSArtifacts(identifier: String) {
        try? fileManager.removeItem(at: hlsSegmentDirectory(identifier: identifier))
        try? fileManager.removeItem(at: hlsOutputPartURL(identifier: identifier))
    }

    private func destinationURL(
        for item: DownloadItem,
        mimeType: String?,
        forcedExtension: String? = nil
    ) -> URL {
        let extensionName = forcedExtension.map { safeFileComponent($0) }
            ?? preferredExtension(for: item.url, mimeType: mimeType)
        let title = safeFileComponent(item.title)
        let episode = String(format: "%02d", max(0, item.episodeIndex + 1))
        let digest = SHA256.hash(data: Data(item.id.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        let fileName = "\(title)-E\(episode)-\(digest).\(extensionName)"
        return downloadsDirectory.appendingPathComponent(fileName)
    }

    private func preferredExtension(for url: URL, mimeType: String?) -> String {
        let pathExtension = url.pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if pathExtension.isEmpty == false, pathExtension.count <= 8 {
            return safeFileComponent(pathExtension)
        }
        if let mimeType = mimeType?.lowercased() {
            switch mimeType {
            case "video/mp4": return "mp4"
            case "video/quicktime": return "mov"
            case "video/x-matroska": return "mkv"
            case "video/webm": return "webm"
            default: break
            }
        }
        return "mp4"
    }

    private func safeFileComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalarString = value.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
        let trimmed = scalarString.trimmingCharacters(in: CharacterSet(charactersIn: "._"))
        return String((trimmed.isEmpty ? "video" : trimmed).prefix(80))
    }

    private func loadManifest() {
        guard let data = try? Data(contentsOf: manifestURL),
              let entries = try? JSONDecoder().decode([ManifestEntry].self, from: data) else { return }
        for entry in entries {
            if entry.status == "paused" {
                let item = DownloadItem(
                    id: entry.id,
                    title: entry.title,
                    sourceKey: entry.sourceKey,
                    videoID: entry.videoID,
                    episodeIndex: entry.episodeIndex,
                    episodeName: entry.episodeName ?? "",
                    headers: entry.headers ?? [:],
                    url: entry.url,
                    playRequestURL: entry.playRequestURL,
                    mediaKind: entry.mediaKind ?? .directFile,
                    status: .paused,
                    progress: min(1, max(0, entry.progress ?? 0)),
                    bytesWritten: max(0, entry.bytesWritten ?? 0),
                    totalBytes: max(0, entry.totalBytes),
                    speedBytesPerSecond: 0,
                    localURL: nil
                )
                items[entry.id] = item
                pausedIdentifiers.insert(entry.id)
                if let resumeData = entry.resumeData {
                    resumeDataByIdentifier[entry.id] = resumeData
                }
                continue
            }
            guard let localURL = entry.localURL
                ?? entry.fileName.map({ downloadsDirectory.appendingPathComponent($0) }) else {
                continue
            }
            guard fileManager.fileExists(atPath: localURL.path) else { continue }
            items[entry.id] = DownloadItem(
                id: entry.id,
                title: entry.title,
                sourceKey: entry.sourceKey,
                videoID: entry.videoID,
                episodeIndex: entry.episodeIndex,
                episodeName: entry.episodeName ?? "",
                headers: entry.headers ?? [:],
                url: entry.url,
                playRequestURL: entry.playRequestURL,
                mediaKind: entry.mediaKind ?? .directFile,
                status: .completed,
                progress: 1,
                bytesWritten: entry.totalBytes,
                totalBytes: entry.totalBytes,
                speedBytesPerSecond: 0,
                localURL: localURL
            )
        }
    }

    private func saveManifest() {
        let entries = items.values.compactMap { item -> ManifestEntry? in
            let isCompleted = item.status == .completed
            let isPaused = item.status == .paused
            guard isCompleted || isPaused else { return nil }
            let localURL = item.localURL.flatMap { url in
                fileManager.fileExists(atPath: url.path) ? url : nil
            }
            guard isPaused || localURL != nil else { return nil }
            return ManifestEntry(
                id: item.id,
                title: item.title,
                sourceKey: item.sourceKey,
                videoID: item.videoID,
                episodeIndex: item.episodeIndex,
                episodeName: item.episodeName,
                headers: item.headers,
                url: item.url,
                playRequestURL: item.playRequestURL,
                fileName: localURL?.lastPathComponent,
                localURL: localURL,
                mediaKind: item.mediaKind,
                totalBytes: item.totalBytes,
                status: isPaused ? "paused" : "completed",
                progress: item.progress,
                bytesWritten: item.bytesWritten,
                resumeData: resumeDataByIdentifier[item.id]
            )
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    private struct ManifestEntry: Codable {
        let id: String
        let title: String
        let sourceKey: String
        let videoID: String
        let episodeIndex: Int
        let episodeName: String?
        let headers: [String: String]?
        let url: URL
        let playRequestURL: URL?
        let fileName: String?
        let localURL: URL?
        let mediaKind: DownloadMediaKind?
        let totalBytes: Int64
        let status: String?
        let progress: Double?
        let bytesWritten: Int64?
        let resumeData: Data?
    }

    private static func mediaKind(for url: URL) -> DownloadMediaKind {
        let value = url.absoluteString.lowercased()
        if value.contains(".m3u8") || value.contains("format=m3u8") {
            return .hls
        }
        return .directFile
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let taskIdentifier = downloadTask.taskIdentifier
        Task { @MainActor [weak self] in
            guard let self,
                  let identifier = self.taskIDs[taskIdentifier] else { return }
            self.updateProgress(
                for: identifier,
                bytesWritten: totalBytesWritten,
                totalBytes: totalBytesExpectedToWrite,
                speedBytesPerSecond: self.speedSample(
                    taskIdentifier: taskIdentifier,
                    bytes: totalBytesWritten
                )
            )
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let taskIdentifier = downloadTask.taskIdentifier
        let mimeType = downloadTask.response?.mimeType
        if Self.looksLikeHLS(response: downloadTask.response, location: location) {
            let finalURL = downloadTask.response?.url
            Task { @MainActor [weak self] in
                guard let self,
                      let identifier = self.taskIDs.removeValue(forKey: taskIdentifier),
                      let item = self.items[identifier] else { return }
                self.activeTasks.removeValue(forKey: taskIdentifier)
                self.progressSamples.removeValue(forKey: taskIdentifier)
                self.startHLSDownload(identifier: identifier, item: item, url: finalURL ?? item.url)
            }
            return
        }
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            let message = "服务器返回 HTTP \(response.statusCode)，无法缓存"
            Task { @MainActor [weak self] in
                guard let self,
                      let identifier = self.taskIDs.removeValue(forKey: taskIdentifier) else { return }
                self.activeTasks.removeValue(forKey: taskIdentifier)
                self.progressSamples.removeValue(forKey: taskIdentifier)
                self.updateStatus(for: identifier, status: .failed(message))
            }
            return
        }
        if Self.looksLikeHTML(response: downloadTask.response, location: location) {
            Task { @MainActor [weak self] in
                guard let self,
                      let identifier = self.taskIDs.removeValue(forKey: taskIdentifier) else { return }
                self.activeTasks.removeValue(forKey: taskIdentifier)
                self.progressSamples.removeValue(forKey: taskIdentifier)
                self.updateStatus(for: identifier, status: .failed("服务器返回了网页而不是可播放媒体"))
            }
            return
        }
        let responseURL = downloadTask.response?.url ?? downloadTask.originalRequest?.url
        let fileExtension = responseURL?.pathExtension ?? ""
        guard let prefix = DownloadPayloadValidator.prefix(at: location),
              DownloadPayloadValidator.isSupportedMediaPayload(
                prefix: prefix,
                mimeType: mimeType,
                fileExtension: fileExtension
              ) else {
            Task { @MainActor [weak self] in
                guard let self,
                      let identifier = self.taskIDs.removeValue(forKey: taskIdentifier) else { return }
                self.activeTasks.removeValue(forKey: taskIdentifier)
                self.progressSamples.removeValue(forKey: taskIdentifier)
                self.updateStatus(
                    for: identifier,
                    status: .failed("资源站返回的内容不是可识别的视频文件，可能是访问校验或错误响应")
                )
            }
            return
        }
        let stagedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("congcong-download-\(taskIdentifier)-\(UUID().uuidString)")
        do {
            if FileManager.default.fileExists(atPath: stagedURL.path) {
                try FileManager.default.removeItem(at: stagedURL)
            }
            try FileManager.default.moveItem(at: location, to: stagedURL)
        } catch {
            let errorMessage = error.localizedDescription
            Task { @MainActor [weak self] in
                guard let self,
                      let identifier = self.taskIDs.removeValue(forKey: taskIdentifier) else { return }
                self.activeTasks.removeValue(forKey: taskIdentifier)
                self.updateStatus(for: identifier, status: .failed(errorMessage))
            }
            return
        }
        Task { @MainActor [weak self] in
            guard let self,
                  let identifier = self.taskIDs[taskIdentifier],
                  let item = self.items[identifier] else {
                try? FileManager.default.removeItem(at: stagedURL)
                return
            }
            let destination = self.destinationURL(for: item, mimeType: mimeType)
            do {
                if self.fileManager.fileExists(atPath: destination.path) {
                    try self.fileManager.removeItem(at: destination)
                }
                try self.fileManager.moveItem(at: stagedURL, to: destination)
                var completed = item
                completed.status = .completed
                completed.progress = 1
                completed.bytesWritten = max(item.bytesWritten, item.totalBytes)
                completed.localURL = destination
                self.items[identifier] = completed
                self.taskIDs.removeValue(forKey: taskIdentifier)
                self.activeTasks.removeValue(forKey: taskIdentifier)
                self.progressSamples.removeValue(forKey: taskIdentifier)
                self.saveManifest()
            } catch {
                try? self.fileManager.removeItem(at: stagedURL)
                self.items[identifier]?.status = .failed(error.localizedDescription)
                self.taskIDs.removeValue(forKey: taskIdentifier)
                self.activeTasks.removeValue(forKey: taskIdentifier)
                self.progressSamples.removeValue(forKey: taskIdentifier)
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let taskIdentifier = task.taskIdentifier
        let nsError = error as NSError
        let errorCode = nsError.code
        let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let isAssetDownloadTask = task is AVAssetDownloadTask
        Task { @MainActor [weak self] in
            guard let self,
                  let identifier = self.taskIDs.removeValue(forKey: taskIdentifier) else { return }
            self.activeTasks.removeValue(forKey: taskIdentifier)
            self.progressSamples.removeValue(forKey: taskIdentifier)
            guard self.items[identifier]?.status != .completed else { return }

            if self.pendingPauseIdentifiers.remove(identifier) != nil {
                if let resumeData {
                    self.resumeDataByIdentifier[identifier] = resumeData
                }
                self.pausedIdentifiers.insert(identifier)
                self.updateStatus(for: identifier, status: .paused)
                self.saveManifest()
                return
            }

            // 系统 HLS 离线任务失败时，若此前尚未尝试过系统转换，先退回到
            // 自定义 MPEG-TS 分片下载；第二次失败才将真实错误展示给用户，避免循环重试。
            if isAssetDownloadTask,
               self.items[identifier]?.mediaKind == .hls,
               !self.hlsAssetFallbackAttempted.contains(identifier),
               let item = self.items[identifier] {
                self.hlsAssetFallbackAttempted.insert(identifier)
                self.startHLSDownload(identifier: identifier, item: item, url: item.url)
                return
            }
            if errorCode == NSURLErrorCancelled {
                self.updateStatus(for: identifier, status: .cancelled)
            } else {
                let message = isAssetDownloadTask
                    ? "HLS 离线下载失败：\(error.localizedDescription)"
                    : self.descriptiveError(error, task: task)
                self.hlsAssetFallbackAttempted.remove(identifier)
                self.updateStatus(for: identifier, status: .failed(message))
            }
        }
    }
}

extension DownloadManager: AVAssetDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didLoad timeRange: CMTimeRange,
        totalTimeRangesLoaded loadedTimeRanges: [NSValue],
        timeRangeExpectedToLoad: CMTimeRange
    ) {
        let taskIdentifier = assetDownloadTask.taskIdentifier
        let loadedDuration = loadedTimeRanges.reduce(0.0) { partialResult, value in
            partialResult + value.timeRangeValue.duration.seconds
        }
        let expectedDuration = timeRangeExpectedToLoad.duration.seconds
        Task { @MainActor [weak self] in
            guard let self,
                  let identifier = self.taskIDs[taskIdentifier] else { return }
            let received = max(0, assetDownloadTask.countOfBytesReceived)
            let expected = assetDownloadTask.countOfBytesExpectedToReceive
            let speed = self.speedSample(taskIdentifier: taskIdentifier, bytes: received)
            if expected > 0 {
                self.updateProgress(
                    for: identifier,
                    bytesWritten: received,
                    totalBytes: expected,
                    speedBytesPerSecond: speed
                )
            } else {
                let progress = expectedDuration > 0 ? loadedDuration / expectedDuration : 0
                self.updateProgress(for: identifier, progress: progress)
                if var item = self.items[identifier] {
                    item.speedBytesPerSecond = speed
                    self.items[identifier] = item
                }
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let taskIdentifier = assetDownloadTask.taskIdentifier
        let stableURL: URL
        do {
            stableURL = try stableHLSDownloadURL(taskIdentifier: taskIdentifier)
            if FileManager.default.fileExists(atPath: stableURL.path) {
                try FileManager.default.removeItem(at: stableURL)
            }
            // This move is intentionally synchronous and happens before the
            // delegate callback returns; the temporary .movpkg is not retained.
            try FileManager.default.moveItem(at: location, to: stableURL)
        } catch {
            let errorMessage = error.localizedDescription
            Task { @MainActor [weak self] in
                guard let self,
                      let identifier = self.taskIDs.removeValue(forKey: taskIdentifier) else { return }
                self.activeTasks.removeValue(forKey: taskIdentifier)
                self.hlsAssetFallbackAttempted.remove(identifier)
                self.updateStatus(for: identifier, status: .failed("保存 HLS 离线文件失败：\(errorMessage)"))
            }
            return
        }
        Task { @MainActor [weak self] in
            guard let self,
                  let identifier = self.taskIDs.removeValue(forKey: taskIdentifier),
                  var item = self.items[identifier] else { return }
            item.mediaKind = .hls
            item.status = .completed
            item.progress = 1
            item.speedBytesPerSecond = 0
            item.localURL = stableURL
            self.items[identifier] = item
            self.activeTasks.removeValue(forKey: taskIdentifier)
            self.progressSamples.removeValue(forKey: taskIdentifier)
            self.hlsAssetFallbackAttempted.remove(identifier)
            self.saveManifest()
        }
    }
}
