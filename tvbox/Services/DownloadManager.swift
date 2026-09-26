import Combine
import CryptoKit
import Foundation

/// 可下载的实际播放地址。`identifier` 应由调用方使用 sourceKey、影片 ID 和集数组成，
/// 不能使用搜索结果的临时索引，以便同一集在重启后仍能查询到。
struct DownloadRequest: Identifiable, Hashable, Sendable {
    let identifier: String
    let title: String
    let sourceKey: String
    let videoID: String
    let episodeIndex: Int
    let episodeName: String
    let url: URL
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
        headers: [String: String] = [:]
    ) {
        self.identifier = identifier
        self.title = title
        self.sourceKey = sourceKey
        self.videoID = videoID
        self.episodeIndex = episodeIndex
        self.episodeName = episodeName
        self.url = url
        self.headers = headers
    }

    static func identifier(sourceKey: String, videoID: String, episodeIndex: Int) -> String {
        "\(sourceKey.trimmingCharacters(in: .whitespacesAndNewlines))::\(videoID.trimmingCharacters(in: .whitespacesAndNewlines))::E\(max(0, episodeIndex))"
    }
}

enum DownloadStatus: Equatable, Sendable {
    case queued
    case downloading
    case completed
    case failed(String)
    case cancelled
}

struct DownloadItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let sourceKey: String
    let videoID: String
    let episodeIndex: Int
    let episodeName: String
    let url: URL
    var status: DownloadStatus
    var progress: Double
    var bytesWritten: Int64
    var totalBytes: Int64
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

/// 基于系统 URLSession 的直接视频文件下载服务。
///
/// 服务只接收实际播放 URL，不参与 CMS 解析，也不修改 sourceKey、播放线路或集数配置。
@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var items: [String: DownloadItem] = [:]

    private let fileManager = FileManager.default
    private let downloadsDirectory: URL
    private let manifestURL: URL
    private var session: URLSession!
    private var taskIDs: [Int: String] = [:]
    private var activeTasks: [Int: URLSessionDownloadTask] = [:]

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
    }

    /// 开始下载。重复调用同一 identifier 时会复用已完成文件或抛出正在下载错误。
    @discardableResult
    func start(_ request: DownloadRequest) throws -> DownloadItem {
        guard request.url.scheme?.lowercased() == "http" || request.url.scheme?.lowercased() == "https" else {
            throw DownloadError.invalidURL
        }
        let normalizedURL = request.url.absoluteString.lowercased()
        guard request.url.pathExtension.lowercased() != "m3u8",
              !normalizedURL.contains(".m3u8"),
              !normalizedURL.contains("format=m3u8") else {
            throw DownloadError.unsupportedStream
        }
        guard taskIDs.values.contains(request.identifier) == false else {
            throw DownloadError.alreadyDownloading
        }

        if let existing = items[request.identifier],
           existing.status == .completed,
           let localURL = existing.localURL,
           fileManager.fileExists(atPath: localURL.path) {
            return existing
        }

        let item = DownloadItem(
            id: request.identifier,
            title: request.title,
            sourceKey: request.sourceKey,
            videoID: request.videoID,
            episodeIndex: request.episodeIndex,
            episodeName: request.episodeName,
            url: request.url,
            status: .queued,
            progress: 0,
            bytesWritten: 0,
            totalBytes: 0,
            localURL: nil
        )
        items[request.identifier] = item

        var urlRequest = URLRequest(url: request.url)
        request.headers.forEach { urlRequest.setValue($1, forHTTPHeaderField: $0) }
        let task = session.downloadTask(with: urlRequest)
        taskIDs[task.taskIdentifier] = request.identifier
        activeTasks[task.taskIdentifier] = task
        task.resume()
        updateStatus(for: request.identifier, status: .downloading)
        return items[request.identifier] ?? item
    }

    func cancel(identifier: String) {
        guard let taskID = taskIDs.first(where: { $0.value == identifier })?.key,
              let task = activeTasks[taskID] else { return }
        task.cancel()
        taskIDs.removeValue(forKey: taskID)
        activeTasks.removeValue(forKey: taskID)
        updateStatus(for: identifier, status: .cancelled)
    }

    func delete(identifier: String) throws {
        guard let item = items[identifier] else { return }
        cancel(identifier: identifier)
        if let localURL = item.localURL, fileManager.fileExists(atPath: localURL.path) {
            try fileManager.removeItem(at: localURL)
        }
        items.removeValue(forKey: identifier)
        saveManifest()
    }

    func item(identifier: String) -> DownloadItem? {
        guard let item = items[identifier] else { return nil }
        if item.status == .completed,
           let localURL = item.localURL,
           fileManager.fileExists(atPath: localURL.path) {
            return item
        }
        return item.status == .completed ? nil : item
    }

    func localFileURL(identifier: String) -> URL? {
        guard let item = items[identifier],
              item.status == .completed,
              let localURL = item.localURL,
              fileManager.fileExists(atPath: localURL.path) else { return nil }
        return localURL
    }

    func isDownloaded(identifier: String) -> Bool {
        localFileURL(identifier: identifier) != nil
    }

    func allItems() -> [DownloadItem] {
        items.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func updateStatus(for identifier: String, status: DownloadStatus) {
        guard var item = items[identifier] else { return }
        item.status = status
        items[identifier] = item
    }

    private func updateProgress(
        for identifier: String,
        bytesWritten: Int64,
        totalBytes: Int64
    ) {
        guard var item = items[identifier] else { return }
        item.status = .downloading
        item.bytesWritten = bytesWritten
        item.totalBytes = totalBytes
        item.progress = totalBytes > 0 ? min(1, max(0, Double(bytesWritten) / Double(totalBytes))) : 0
        items[identifier] = item
    }

    private func destinationURL(for item: DownloadItem, mimeType: String?) -> URL {
        let extensionName = preferredExtension(for: item.url, mimeType: mimeType)
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
            let localURL = downloadsDirectory.appendingPathComponent(entry.fileName)
            guard fileManager.fileExists(atPath: localURL.path) else { continue }
            items[entry.id] = DownloadItem(
                id: entry.id,
                title: entry.title,
                sourceKey: entry.sourceKey,
                videoID: entry.videoID,
                episodeIndex: entry.episodeIndex,
                episodeName: entry.episodeName ?? "",
                url: entry.url,
                status: .completed,
                progress: 1,
                bytesWritten: entry.totalBytes,
                totalBytes: entry.totalBytes,
                localURL: localURL
            )
        }
    }

    private func saveManifest() {
        let entries = items.values.compactMap { item -> ManifestEntry? in
            guard item.status == .completed,
                  let localURL = item.localURL,
                  fileManager.fileExists(atPath: localURL.path) else { return nil }
            return ManifestEntry(
                id: item.id,
                title: item.title,
                sourceKey: item.sourceKey,
                videoID: item.videoID,
                episodeIndex: item.episodeIndex,
                episodeName: item.episodeName,
                url: item.url,
                fileName: localURL.lastPathComponent,
                totalBytes: item.totalBytes
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
        let url: URL
        let fileName: String
        let totalBytes: Int64
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
                totalBytes: totalBytesExpectedToWrite
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
        if let mimeType,
           mimeType.lowercased().contains("mpegurl") || mimeType.lowercased().contains("text/html") {
            Task { @MainActor [weak self] in
                guard let self,
                      let identifier = self.taskIDs.removeValue(forKey: taskIdentifier) else { return }
                self.activeTasks.removeValue(forKey: taskIdentifier)
                self.updateStatus(
                    for: identifier,
                    status: .failed("服务器返回的不是可下载视频文件")
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
                self.saveManifest()
            } catch {
                try? self.fileManager.removeItem(at: stagedURL)
                self.items[identifier]?.status = .failed(error.localizedDescription)
                self.taskIDs.removeValue(forKey: taskIdentifier)
                self.activeTasks.removeValue(forKey: taskIdentifier)
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
        let errorCode = (error as NSError).code
        let errorMessage = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self,
                  let identifier = self.taskIDs.removeValue(forKey: taskIdentifier) else { return }
            self.activeTasks.removeValue(forKey: taskIdentifier)
            if errorCode == NSURLErrorCancelled {
                self.updateStatus(for: identifier, status: .cancelled)
            } else {
                self.updateStatus(for: identifier, status: .failed(errorMessage))
            }
        }
    }
}
