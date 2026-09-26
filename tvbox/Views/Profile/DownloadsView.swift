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
                                guard item.status == .completed else { return }
                                activeItem = item
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
                if item.status == .downloading {
                    ProgressView(value: item.progress)
                        .tint(.blue)
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
                Text("\(Int(item.progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.white.opacity(0.7))
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
        case .failed: return "exclamationmark.circle.fill"
        case .cancelled: return "pause.circle"
        }
    }

    private func color(for status: DownloadStatus) -> Color {
        switch status {
        case .completed: return .green
        case .downloading, .queued: return .blue
        case .failed: return .red
        case .cancelled: return .gray
        }
    }
}

private struct OfflineDownloadPlayerView: View {
    let item: DownloadItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let localURL = item.localURL {
                    PlayerView(
                        urlString: localURL.absoluteString,
                        onBack: { dismiss() },
                        danmakuTitle: item.title,
                        danmakuEpisode: item.episodeName
                    )
                    .aspectRatio(16 / 9, contentMode: .fit)
                } else {
                    ContentUnavailableView("文件不存在", systemImage: "exclamationmark.triangle")
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
