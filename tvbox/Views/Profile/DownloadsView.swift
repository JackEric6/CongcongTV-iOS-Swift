#if os(iOS)
import SwiftUI

/// 已下载影片列表。播放时直接使用本地文件，不依赖资源站或网络连接。
struct DownloadsView: View {
    @StateObject private var downloadManager = DownloadManager.shared
    @State private var activeItem: DownloadItem?

    var body: some View {
        Group {
            if downloadManager.allItems().isEmpty {
                EmptyStateView(
                    icon: "arrow.down.circle",
                    title: "暂无离线影片",
                    message: "在影片详情页点击下载按钮后，可在这里离线观看。"
                )
            } else {
                List {
                    ForEach(downloadManager.allItems()) { item in
                        downloadRow(item)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard item.status == .completed,
                                      let localURL = downloadManager.localFileURL(identifier: item.id) else {
                                    return
                                }
                                var playableItem = item
                                playableItem.localURL = localURL
                                activeItem = playableItem
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    try? downloadManager.delete(identifier: item.id)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(AppTheme.primaryGradient)
        .navigationTitle("离线下载")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $activeItem) { item in
            OfflineDownloadPlayerView(item: item)
        }
    }

    private func downloadRow(_ item: DownloadItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(for: item.status))
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(color(for: item.status))
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(episodeLabel(item))
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.65))
                if item.status == .downloading || item.status == .paused {
                    ProgressView(value: item.progress)
                        .tint(.blue)
                    HStack(spacing: 6) {
                        Text(downloadProgressLabel(item))
                        Spacer(minLength: 0)
                        Text(downloadSpeedLabel(item))
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.white.opacity(0.62))
                } else if case .failed(let message) = item.status {
                    Text(message)
                        .font(.caption2)
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            if item.status == .completed {
                Image(systemName: "play.fill")
                    .foregroundColor(.white.opacity(0.7))
            } else if item.status == .downloading {
                HStack(spacing: 10) {
                    Text("\(Int(item.progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.white.opacity(0.7))
                    Button {
                        downloadManager.pause(identifier: item.id)
                    } label: {
                        Image(systemName: "pause.fill")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.borderless)
                    .tint(.white)
                    .accessibilityLabel("暂停下载")
                }
            } else if item.status == .paused {
                Button {
                    downloadManager.resume(identifier: item.id)
                } label: {
                    Image(systemName: "play.fill")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.borderless)
                .tint(.white)
                .accessibilityLabel("继续下载")
            }
        }
        .padding(.vertical, 8)
        .listRowBackground(Color.white.opacity(0.06))
    }

    private func episodeLabel(_ item: DownloadItem) -> String {
        let episode = item.episodeName.trimmingCharacters(in: .whitespacesAndNewlines)
        return episode.isEmpty ? "第\(item.episodeIndex + 1)集 · \(item.sourceKey)" : "\(episode) · \(item.sourceKey)"
    }

    private func icon(for status: DownloadStatus) -> String {
        switch status {
        case .completed: return "checkmark.circle.fill"
        case .downloading, .queued: return "arrow.down.circle"
        case .paused: return "pause.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .cancelled: return "pause.circle"
        }
    }

    private func color(for status: DownloadStatus) -> Color {
        switch status {
        case .completed: return .green
        case .downloading, .queued: return .blue
        case .paused: return .orange
        case .failed: return .red
        case .cancelled: return .gray
        }
    }

    private func downloadProgressLabel(_ item: DownloadItem) -> String {
        let percent = "\(Int((item.progress * 100).rounded()))%"
        if item.totalBytes > 0 {
            return "\(percent) · \(formatBytes(item.bytesWritten))/\(formatBytes(item.totalBytes))"
        }
        if item.bytesWritten > 0 {
            return "\(percent) · 已下载 \(formatBytes(item.bytesWritten))"
        }
        return percent
    }

    private func downloadSpeedLabel(_ item: DownloadItem) -> String {
        if item.status == .paused { return "已暂停" }
        guard item.speedBytesPerSecond > 0 else { return "准备中" }
        return "\(formatBytes(Int64(item.speedBytesPerSecond)))/秒"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let value = Double(max(0, bytes))
        if value >= 1024 * 1024 * 1024 {
            return String(format: "%.1f GB", value / (1024 * 1024 * 1024))
        }
        if value >= 1024 * 1024 {
            return String(format: "%.1f MB", value / (1024 * 1024))
        }
        if value >= 1024 {
            return String(format: "%.0f KB", value / 1024)
        }
        return "\(Int(value)) B"
    }
}

private struct OfflineDownloadPlayerView: View {
    let item: DownloadItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let localURL = item.localURL,
                   FileManager.default.fileExists(atPath: localURL.path) {
                    PlayerView(
                        urlString: localURL.absoluteString,
                        onBack: { dismiss() },
                        danmakuTitle: item.title,
                        danmakuEpisode: item.episodeName
                    )
                    .aspectRatio(16 / 9, contentMode: .fit)
                } else {
                    ContentUnavailableView(
                        "离线文件不可用",
                        systemImage: "exclamationmark.triangle",
                        description: Text("请删除该条目后重新下载")
                    )
                }
                Spacer(minLength: 0)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
#endif
