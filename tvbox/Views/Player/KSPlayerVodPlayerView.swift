import SwiftUI

#if os(iOS)
import KSPlayer
import AVKit
import UIKit

/// SwiftUI adapter for KSPlayer's native iOS player view.
struct KSPlayerVodPlayerView: View {
    let urlString: String
    var startPosition: Double = 0
    var onProgressChanged: ((Double, Double?) -> Void)? = nil
    var onPlaybackEnded: (() -> Void)? = nil
    /// Called when KSPlayer's native back button is pressed.
    var onBack: (() -> Void)? = nil
    /// Forwards native toolbar actions to the host without replacing KSPlayer's handling.
    var onPlayerAction: ((PlayerButtonType) -> Void)? = nil

    var body: some View {
        if let url = Self.makeURL(from: urlString) {
            KSPlayerUIView(
                url: url,
                startPosition: max(0, startPosition),
                onProgressChanged: onProgressChanged,
                onPlaybackEnded: onPlaybackEnded,
                onBack: onBack,
                onPlayerAction: onPlayerAction
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

private final class CongcongKSVideoPlayerView: IOSVideoPlayerView {
    override func updateUI(isFullScreen: Bool) {
        super.updateUI(isFullScreen: isFullScreen)

        // KSPlayer owns the presentation controller. Keep the app orientation
        // in sync with that controller instead of layering another full-screen
        // SwiftUI presentation on top of it.
        DispatchQueue.main.async {
            if isFullScreen {
                OrientationLock.landscape()
            } else {
                OrientationLock.portrait()
            }
        }
    }
}

private struct KSPlayerUIView: UIViewRepresentable {
    private static let supportedPlaybackRates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    let url: URL
    let startPosition: Double
    let onProgressChanged: ((Double, Double?) -> Void)?
    let onPlaybackEnded: (() -> Void)?
    let onBack: (() -> Void)?
    let onPlayerAction: ((PlayerButtonType) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onProgressChanged: onProgressChanged,
            onPlaybackEnded: onPlaybackEnded,
            onBack: onBack,
            onPlayerAction: onPlayerAction
        )
    }

    func makeUIView(context: Context) -> CongcongKSVideoPlayerView {
        let view = CongcongKSVideoPlayerView()
        context.coordinator.configure(view)
        configure(view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ view: CongcongKSVideoPlayerView, context: Context) {
        context.coordinator.onProgressChanged = onProgressChanged
        context.coordinator.onPlaybackEnded = onPlaybackEnded
        context.coordinator.onBack = onBack
        context.coordinator.onPlayerAction = onPlayerAction
        guard context.coordinator.url != url else { return }
        configure(view, coordinator: context.coordinator)
    }

    static func dismantleUIView(_ view: CongcongKSVideoPlayerView, coordinator: Coordinator) {
        view.pause()
        view.backBlock = nil
        view.playerLayer = nil
        view.delegate = nil
        view.playTimeDidChange = nil
    }

    private func configure(_ view: IOSVideoPlayerView, coordinator: Coordinator) {
        coordinator.url = url
        // KSPlayer's AV player configures the audio session too, but doing it here
        // keeps background audio available across view reattachment and PiP.
        KSOptions.setAudioSession()
        KSOptions.canBackgroundPlay = true
        KSOptions.isAutoPlay = true
        let options = KSOptions()
        options.startPlayTime = startPosition
        let savedRate = UserDefaults.standard.object(forKey: HawkConfig.PLAY_SPEED) as? Double ?? 1.0
        options.startPlayRate = Self.normalizedPlaybackRate(
            from: savedRate
        )
        options.registerRemoteControll = true
        options.canStartPictureInPictureAutomaticallyFromInline = true
        view.set(url: url, options: options)
        // IOSVideoPlayerView owns the native rate/PiP/AirPlay controls. The
        // package hides PiP and route controls during base toolbar setup, so
        // explicitly expose them here when the platform supports them.
        if AVPictureInPictureController.isPictureInPictureSupported() {
            view.toolBar.pipButton.isHidden = false
        }
        view.routeButton.isHidden = false
        view.routeButton.tintColor = .white
        view.routeButton.activeTintColor = .systemOrange
        view.playTimeDidChange = { [weak coordinator] current, total in
            guard let coordinator else { return }
            coordinator.onProgressChanged?(current, total > 0 ? total : nil)
        }
        view.play()
    }

    private static func normalizedPlaybackRate(from raw: Double) -> Float {
        let value = raw.isFinite && raw > 0 ? Float(raw) : 1.0
        return supportedPlaybackRates.min(by: { abs($0 - value) < abs($1 - value) }) ?? 1.0
    }

    final class Coordinator: NSObject, PlayerControllerDelegate {
        var url: URL?
        var onProgressChanged: ((Double, Double?) -> Void)?
        var onPlaybackEnded: (() -> Void)?
        var onBack: (() -> Void)?
        var onPlayerAction: ((PlayerButtonType) -> Void)?

        init(
            onProgressChanged: ((Double, Double?) -> Void)?,
            onPlaybackEnded: (() -> Void)?,
            onBack: (() -> Void)?,
            onPlayerAction: ((PlayerButtonType) -> Void)?
        ) {
            self.onProgressChanged = onProgressChanged
            self.onPlaybackEnded = onPlaybackEnded
            self.onBack = onBack
            self.onPlayerAction = onPlayerAction
        }

        func configure(_ view: IOSVideoPlayerView) {
            view.delegate = self
            view.backBlock = { [weak self] in
                self?.onBack?()
            }
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

        func playerController(action: PlayerButtonType) {
            // KSPlayer already performs the native action. Forward it after
            // that handling so the host can observe back/rate/PiP actions.
            onPlayerAction?(action)
        }

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
