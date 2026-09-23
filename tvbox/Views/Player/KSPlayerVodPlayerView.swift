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
    var canPlayPrevious: Bool = false
    var onPlayPrevious: (() -> Void)? = nil
    var canPlayNext: Bool = false
    var onPlayNext: (() -> Void)? = nil
    var canSelectEpisode: Bool = false
    var onSelectEpisode: (() -> Void)? = nil
    var danmakuTitle: String = ""
    var danmakuEpisode: String = ""
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
                onPlayerAction: onPlayerAction,
                canPlayPrevious: canPlayPrevious,
                onPlayPrevious: onPlayPrevious,
                canPlayNext: canPlayNext,
                onPlayNext: onPlayNext,
                canSelectEpisode: canSelectEpisode,
                onSelectEpisode: onSelectEpisode,
                danmakuTitle: danmakuTitle,
                danmakuEpisode: danmakuEpisode
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
    private weak var interactivePopGestureRecognizer: UIGestureRecognizer?

    override func updateUI(isFullScreen: Bool) {
        // KSPlayer 的原生全屏控制器会在呈现完成后写入同一个全局掩码。
        // 这里提前写入，确保 UIKit 在 present 的那一帧就允许横屏，避免
        // 被应用默认的 portrait 掩码卡住。
        KSOptions.supportedInterfaceOrientations = isFullScreen ? .landscapeRight : .portrait
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
            self.syncInteractivePopGesture()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        syncInteractivePopGesture()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        syncInteractivePopGesture()
    }

    private func syncInteractivePopGesture() {
        guard let navigationController = owningNavigationController,
              let popGesture = navigationController.interactivePopGestureRecognizer else {
            return
        }

        if interactivePopGestureRecognizer !== popGesture {
            interactivePopGestureRecognizer = popGesture
            // KSPlayer 的 pan 手势覆盖在播放器控制层上；让系统边缘返回
            // 优先识别，避免左滑偶发被播放器快进手势吞掉。
            panGesture.require(toFail: popGesture)
            panGesture.cancelsTouchesInView = false
        }

        popGesture.isEnabled = !landscapeButton.isSelected
    }

    private var owningNavigationController: UINavigationController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let viewController = next as? UIViewController {
                return viewController.navigationController
            }
            responder = next
        }
        return nil
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
    let canPlayPrevious: Bool
    let onPlayPrevious: (() -> Void)?
    let canPlayNext: Bool
    let onPlayNext: (() -> Void)?
    let canSelectEpisode: Bool
    let onSelectEpisode: (() -> Void)?
    let danmakuTitle: String
    let danmakuEpisode: String

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onProgressChanged: onProgressChanged,
            onPlaybackEnded: onPlaybackEnded,
            onBack: onBack,
            onPlayerAction: onPlayerAction,
            canPlayPrevious: canPlayPrevious,
            onPlayPrevious: onPlayPrevious,
            canPlayNext: canPlayNext,
            onPlayNext: onPlayNext,
            canSelectEpisode: canSelectEpisode,
            onSelectEpisode: onSelectEpisode,
            danmakuTitle: danmakuTitle,
            danmakuEpisode: danmakuEpisode
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
        context.coordinator.onPlayPrevious = onPlayPrevious
        context.coordinator.onPlayNext = onPlayNext
        context.coordinator.onSelectEpisode = onSelectEpisode
        context.coordinator.updateDanmakuMetadata(title: danmakuTitle, episode: danmakuEpisode)
        context.coordinator.updateActionButtons(
            canPlayPrevious: canPlayPrevious,
            canPlayNext: canPlayNext,
            canSelectEpisode: canSelectEpisode
        )
        guard context.coordinator.url != url else { return }
        configure(view, coordinator: context.coordinator)
    }

    static func dismantleUIView(_ view: CongcongKSVideoPlayerView, coordinator: Coordinator) {
        coordinator.tearDownDanmaku()
        view.pause()
        view.backBlock = nil
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
        view.toolBar.playbackRateButton.setTitle("倍速", for: .normal)
        view.toolBar.playbackRateButton.accessibilityLabel = "倍速"
        coordinator.installActionButtons(
            on: view,
            canPlayPrevious: canPlayPrevious,
            canPlayNext: canPlayNext,
            canSelectEpisode: canSelectEpisode
        )
        coordinator.installDanmaku(on: view)
        view.playTimeDidChange = { [weak coordinator] current, total in
            guard let coordinator else { return }
            coordinator.updateDanmaku(currentTime: current, duration: total > 0 ? total : 0)
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
        var onPlayPrevious: (() -> Void)?
        var onPlayNext: (() -> Void)?
        var onSelectEpisode: (() -> Void)?
        private var danmakuTitle: String
        private var danmakuEpisode: String
        private weak var danmakuView: DanmakuOverlayView?
        private var danmakuTask: Task<Void, Never>?
        private let previousButton = UIButton(type: .system)
        private let nextButton = UIButton(type: .system)
        private let episodeButton = UIButton(type: .system)
        private var actionButtonsInstalled = false

        init(
            onProgressChanged: ((Double, Double?) -> Void)?,
            onPlaybackEnded: (() -> Void)?,
            onBack: (() -> Void)?,
            onPlayerAction: ((PlayerButtonType) -> Void)?,
            canPlayPrevious _: Bool,
            canPlayNext _: Bool,
            canSelectEpisode _: Bool,
            onPlayPrevious: (() -> Void)?,
            onPlayNext: (() -> Void)?,
            onSelectEpisode: (() -> Void)?,
            danmakuTitle: String,
            danmakuEpisode: String
        ) {
            self.onProgressChanged = onProgressChanged
            self.onPlaybackEnded = onPlaybackEnded
            self.onBack = onBack
            self.onPlayerAction = onPlayerAction
            self.onPlayPrevious = onPlayPrevious
            self.onPlayNext = onPlayNext
            self.onSelectEpisode = onSelectEpisode
            self.danmakuTitle = danmakuTitle
            self.danmakuEpisode = danmakuEpisode
        }

        func configure(_ view: IOSVideoPlayerView) {
            view.delegate = self
            view.backBlock = { [weak self] in
                self?.onBack?()
            }
        }

        func updateDanmakuMetadata(title: String, episode: String) {
            let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedEpisode = episode.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedTitle != danmakuTitle || normalizedEpisode != danmakuEpisode else { return }
            danmakuTitle = normalizedTitle
            danmakuEpisode = normalizedEpisode
            guard let danmakuView else { return }
            loadDanmaku(into: danmakuView)
        }

        func installDanmaku(on view: IOSVideoPlayerView) {
            if let existing = danmakuView, existing.superview === view.contentOverlayView {
                loadDanmaku(into: existing)
                return
            }

            let overlay = DanmakuOverlayView()
            overlay.translatesAutoresizingMaskIntoConstraints = false
            view.contentOverlayView.addSubview(overlay)
            NSLayoutConstraint.activate([
                overlay.leadingAnchor.constraint(equalTo: view.contentOverlayView.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: view.contentOverlayView.trailingAnchor),
                overlay.topAnchor.constraint(equalTo: view.contentOverlayView.topAnchor),
                overlay.bottomAnchor.constraint(equalTo: view.contentOverlayView.bottomAnchor)
            ])
            danmakuView = overlay
            loadDanmaku(into: overlay)
        }

        func tearDownDanmaku() {
            danmakuTask?.cancel()
            danmakuTask = nil
            danmakuView?.clear()
            danmakuView?.removeFromSuperview()
            danmakuView = nil
        }

        func updateDanmaku(currentTime: TimeInterval, duration: TimeInterval) {
            danmakuView?.update(currentTime: currentTime, duration: duration)
        }

        private func loadDanmaku(into overlay: DanmakuOverlayView) {
            danmakuTask?.cancel()
            overlay.clear()

            let title = danmakuTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let episode = danmakuEpisode.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return }

            danmakuTask = Task { [weak self, weak overlay] in
                let cues = await DanmuService.shared.loadCues(title: title, episode: episode)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, let overlay, self.danmakuView === overlay else { return }
                    overlay.setCues(cues)
                }
            }
        }

        func installActionButtons(
            on view: IOSVideoPlayerView,
            canPlayPrevious: Bool,
            canPlayNext: Bool,
            canSelectEpisode: Bool
        ) {
            guard !actionButtonsInstalled else { return }
            actionButtonsInstalled = true
            configureButton(previousButton, imageName: "backward.end", label: "上一集", action: #selector(previousPressed))
            configureButton(nextButton, imageName: "forward.end", label: "下一集", action: #selector(nextPressed))
            configureButton(episodeButton, imageName: "list.bullet", label: "选集", action: #selector(selectEpisodePressed))
            view.toolBar.insertArrangedSubview(previousButton, at: 1)
            view.toolBar.insertArrangedSubview(nextButton, at: 2)
            view.toolBar.insertArrangedSubview(episodeButton, at: 3)
            updateActionButtons(
                canPlayPrevious: canPlayPrevious,
                canPlayNext: canPlayNext,
                canSelectEpisode: canSelectEpisode
            )
        }

        func updateActionButtons(canPlayPrevious: Bool, canPlayNext: Bool, canSelectEpisode: Bool) {
            previousButton.isHidden = !canPlayPrevious
            nextButton.isHidden = !canPlayNext
            episodeButton.isHidden = !canSelectEpisode
        }

        private func configureButton(_ button: UIButton, imageName: String, label: String, action: Selector) {
            button.setImage(UIImage(systemName: imageName), for: .normal)
            button.tintColor = .white
            button.accessibilityLabel = label
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 30).isActive = true
            button.addTarget(self, action: action, for: .primaryActionTriggered)
        }

        @objc private func previousPressed() {
            onPlayPrevious?()
        }

        @objc private func nextPressed() {
            onPlayNext?()
        }

        @objc private func selectEpisodePressed() {
            onSelectEpisode?()
        }

        func playerController(state _: KSPlayerState) {}

        func playerController(currentTime _: TimeInterval, totalTime _: TimeInterval) {}

        func playerController(finish error: Error?) {
            danmakuView?.reset()
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

        func playerController(seek _: TimeInterval) {
            danmakuView?.reset()
        }
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
