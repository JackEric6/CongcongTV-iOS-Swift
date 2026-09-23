import SwiftUI

#if os(iOS)
import KSPlayer
import UIKit

/// SwiftUI adapter for KSPlayer's native iOS player view.
struct KSPlayerVodPlayerView: View {
    let urlString: String
    var startPosition: Double = 0
    var onProgressChanged: ((Double, Double?) -> Void)? = nil
    var onPlaybackEnded: (() -> Void)? = nil

    var body: some View {
        if let url = Self.makeURL(from: urlString) {
            KSPlayerUIView(
                url: url,
                startPosition: max(0, startPosition),
                onProgressChanged: onProgressChanged,
                onPlaybackEnded: onPlaybackEnded
            )
            .background(Color.black)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                Text("播放地址无效")
                    .foregroundColor(.white)
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
        }
    }

    private static func makeURL(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        return URL(string: encoded)
    }
}

private struct KSPlayerUIView: UIViewRepresentable {
    let url: URL
    let startPosition: Double
    let onProgressChanged: ((Double, Double?) -> Void)?
    let onPlaybackEnded: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onProgressChanged: onProgressChanged,
            onPlaybackEnded: onPlaybackEnded
        )
    }

    func makeUIView(context: Context) -> IOSVideoPlayerView {
        let view = IOSVideoPlayerView()
        context.coordinator.configure(view)
        configure(view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ view: IOSVideoPlayerView, context: Context) {
        context.coordinator.onProgressChanged = onProgressChanged
        context.coordinator.onPlaybackEnded = onPlaybackEnded
        guard context.coordinator.url != url else { return }
        configure(view, coordinator: context.coordinator)
    }

    static func dismantleUIView(_ view: IOSVideoPlayerView, coordinator: Coordinator) {
        view.pause()
        view.playerLayer = nil
        view.delegate = nil
        view.playTimeDidChange = nil
    }

    private func configure(_ view: IOSVideoPlayerView, coordinator: Coordinator) {
        coordinator.url = url
        let options = KSOptions()
        options.isAutoPlay = true
        options.startPlayTime = startPosition
        view.set(url: url, options: options)
        view.playTimeDidChange = { [weak coordinator] current, total in
            guard let coordinator else { return }
            coordinator.onProgressChanged?(current, total > 0 ? total : nil)
        }
        view.play()
    }

    final class Coordinator: NSObject, PlayerControllerDelegate {
        var url: URL?
        var onProgressChanged: ((Double, Double?) -> Void)?
        var onPlaybackEnded: (() -> Void)?

        init(
            onProgressChanged: ((Double, Double?) -> Void)?,
            onPlaybackEnded: (() -> Void)?
        ) {
            self.onProgressChanged = onProgressChanged
            self.onPlaybackEnded = onPlaybackEnded
        }

        func configure(_ view: IOSVideoPlayerView) {
            view.delegate = self
        }

        func playerController(state _: KSPlayerState) {}

        func playerController(currentTime _: TimeInterval, totalTime _: TimeInterval) {}

        func playerController(finish error: Error?) {
            guard error == nil else { return }
            DispatchQueue.main.async { [weak self] in
                self?.onPlaybackEnded?()
            }
        }

        func playerController(maskShow _: Bool) {}

        func playerController(action _: PlayerButtonType) {}

        func playerController(bufferedCount _: Int, consumeTime _: TimeInterval) {}

        func playerController(seek _: TimeInterval) {}
    }
}
#else
struct KSPlayerVodPlayerView: View {
    let urlString: String
    var startPosition: Double = 0
    var onProgressChanged: ((Double, Double?) -> Void)? = nil
    var onPlaybackEnded: (() -> Void)? = nil

    var body: some View {
        Text("KSPlayer 仅支持 iOS 播放")
    }
}
#endif
