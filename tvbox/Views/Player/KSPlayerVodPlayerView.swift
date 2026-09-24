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
    var customControlsLayout: ((Bool) -> Void)?

    override func updateUI(isFullScreen: Bool) {
        // KSPlayer 的原生全屏控制器会在呈现完成后写入同一个全局掩码。
        // 这里提前写入，确保 UIKit 在 present 的那一帧就允许横屏，避免
        // 被应用默认的 portrait 掩码卡住。
        KSOptions.supportedInterfaceOrientations = isFullScreen ? .landscapeRight : .portrait
        // 先更新应用方向掩码，再让 KSPlayer 执行 present/dismiss。否则
        // full-screen controller 可能在同一帧拿到 portrait 掩码，表现为黑屏
        // 或播放器被挪到错误的布局位置。
        if isFullScreen {
            OrientationLock.landscape()
        } else {
            OrientationLock.portrait()
        }
        super.updateUI(isFullScreen: isFullScreen)

        // KSPlayer 默认在横屏时隐藏方向按钮，导致用户只能依赖系统手势退出。
        // 保留同一个原生按钮，确保横屏右下角始终有明确的退出全屏入口。
        landscapeButton.isHidden = false
        landscapeButton.isEnabled = true

        // KSPlayer owns the presentation controller. Keep the app orientation
        // in sync with that controller instead of layering another full-screen
        // SwiftUI presentation on top of it.
        DispatchQueue.main.async {
            self.syncInteractivePopGesture()
            self.landscapeButton.isHidden = false
        }
    }

    override func updateUI(isLandscape: Bool) {
        super.updateUI(isLandscape: isLandscape)
        // KSPlayer 在 landscape 分支会将按钮隐藏；这里覆盖该默认行为。
        landscapeButton.isHidden = false
        landscapeButton.isEnabled = true
        styleControlLayers(isLandscape: isLandscape)
        customControlsLayout?(isLandscape)
    }

    private func styleControlLayers(isLandscape: Bool) {
        // ExoPlayer/Media3 风格的纯黑控制层，保证白色图标和时间文本清晰可见。
        let alpha: CGFloat = isLandscape ? 0.94 : 0.88
        let color = UIColor.black.withAlphaComponent(alpha).cgColor
        topMaskView.gradientLayer.colors = [color, color]
        bottomMaskView.gradientLayer.colors = [color, color]
        topMaskView.backgroundColor = .black
        bottomMaskView.backgroundColor = .black
    }

    override func player(layer: KSPlayerLayer, state: KSPlayerState) {
        super.player(layer: layer, state: state)
        guard state == .readyToPlay else { return }

        // KSPlayer 2.3.4 每次 readyToPlay 都会重建一次默认倍速菜单，默认只到 2x。
        // 在它完成初始化后覆盖菜单，避免切集或重连时选项又被恢复。
        if #available(iOS 14.0, *) {
            let rates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0]
            let current = playerLayer?.player.playbackRate ?? 1.0
            let actions = rates.map { rate in
                UIAction(
                    title: String(format: "%.2gx", rate),
                    state: abs(rate - current) < 0.01 ? .on : .off
                ) { [weak self] _ in
                    self?.playerLayer?.player.playbackRate = rate
                    self?.toolBar.playbackRateButton.setTitle(nil, for: .normal)
                    self?.toolBar.playbackRateButton.setImage(UIImage(systemName: "speedometer"), for: .normal)
                }
            }
            toolBar.playbackRateButton.menu = UIMenu(title: "倍速", children: actions)
            toolBar.playbackRateButton.showsMenuAsPrimaryAction = true
            toolBar.playbackRateButton.setTitle(nil, for: .normal)
            toolBar.playbackRateButton.setImage(UIImage(systemName: "speedometer"), for: .normal)
            toolBar.playbackRateButton.accessibilityLabel = "倍速"
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
    private static let supportedPlaybackRates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0]

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
            canPlayNext: canPlayNext,
            canSelectEpisode: canSelectEpisode,
            onPlayPrevious: onPlayPrevious,
            onPlayNext: onPlayNext,
            onSelectEpisode: onSelectEpisode,
            danmakuTitle: danmakuTitle,
            danmakuEpisode: danmakuEpisode
        )
    }

    func makeUIView(context: Context) -> CongcongKSVideoPlayerView {
        let view = CongcongKSVideoPlayerView()
        context.coordinator.configure(view)
        view.customControlsLayout = { [weak coordinator = context.coordinator] isLandscape in
            coordinator?.updateActionButtonsLayout(isLandscape: isLandscape)
        }
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
        // keeps background audio available across view reattachment.
        KSOptions.setAudioSession()
        KSOptions.canBackgroundPlay = true
        KSOptions.isAutoPlay = true
        // KSPlayer 原生 pan 手势：横向调进度，左侧纵向调亮度，右侧纵向调音量。
        // 显式开启，避免外部全局配置或旧版本默认值把这些交互关闭。
        KSOptions.enableBrightnessGestures = true
        KSOptions.enableVolumeGestures = true
        let options = KSOptions()
        options.startPlayTime = startPosition
        let savedRate = UserDefaults.standard.object(forKey: HawkConfig.PLAY_SPEED) as? Double ?? 1.0
        options.startPlayRate = Self.normalizedPlaybackRate(
            from: savedRate
        )
        options.registerRemoteControll = true
        // 本应用只提供点播，不启用画中画；尤其不能让播放器在内联状态下
        // 因切后台或系统事件自动进入 PiP。
        options.canStartPictureInPictureAutomaticallyFromInline = false
        view.set(url: url, options: options)
        // 完全移除 PiP 入口；投屏仍保留为独立的 AirPlay route 按钮。
        view.toolBar.pipButton.isHidden = true
        view.toolBar.pipButton.isEnabled = false
        view.routeButton.isHidden = false
        view.routeButton.tintColor = .white
        view.routeButton.activeTintColor = .systemOrange
        view.toolBar.playbackRateButton.setTitle(nil, for: .normal)
        view.toolBar.playbackRateButton.setImage(UIImage(systemName: "speedometer"), for: .normal)
        view.toolBar.playbackRateButton.tintColor = .white
        view.toolBar.playbackRateButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
        view.toolBar.playbackRateButton.accessibilityLabel = "倍速"
        view.landscapeButton.isHidden = false
        view.landscapeButton.isEnabled = true
        coordinator.installActionButtons(
            on: view,
            canPlayPrevious: canPlayPrevious,
            canPlayNext: canPlayNext,
            canSelectEpisode: canSelectEpisode
        )
        coordinator.updateActionButtonsLayout(isLandscape: view.landscapeButton.isSelected)
        coordinator.installDanmaku(on: view)
        view.playTimeDidChange = { [weak coordinator] current, total in
            guard let coordinator else { return }
            coordinator.updateDanmakuTime(currentTime: current, duration: total > 0 ? total : 0)
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
        private var lastPlayerTime: TimeInterval = 0
        private var lastPlayerDuration: TimeInterval = 0
        private let previousButton = UIButton(type: .system)
        private let rewindButton = UIButton(type: .system)
        private let forwardButton = UIButton(type: .system)
        private let nextButton = UIButton(type: .system)
        private let verticalRewindButton = UIButton(type: .system)
        private let verticalForwardButton = UIButton(type: .system)
        private let verticalSeekStack = UIStackView()
        private let volumeButton = UIButton(type: .system)
        private let episodeButton = UIButton(type: .system)
        private weak var playerView: IOSVideoPlayerView?
        private var canPlayPrevious = false
        private var canPlayNext = false
        private var canSelectEpisode = false
        private var isLandscape = false
        private var lastVolume: Float = 0.5
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
            playerView?.titleLabel.text = normalizedTitle
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
            overlay.layer.zPosition = 100
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
                    // A cue request can finish between two KSPlayer time
                    // callbacks. Seed the overlay with the latest known time
                    // so the first comments are rendered immediately.
                    overlay.update(currentTime: self.lastPlayerTime, duration: self.lastPlayerDuration)
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
            playerView = view
            view.titleLabel.text = danmakuTitle
            view.titleLabel.textColor = .white
            configureButton(previousButton, imageName: "backward.end.fill", label: "上一集", action: #selector(previousPressed))
            configureButton(rewindButton, imageName: "gobackward.15", label: "后退15秒", action: #selector(rewindPressed))
            configureButton(forwardButton, imageName: "goforward.15", label: "前进15秒", action: #selector(forwardPressed))
            configureButton(nextButton, imageName: "forward.end.fill", label: "下一集", action: #selector(nextPressed))
            configureButton(verticalRewindButton, imageName: "gobackward.15", label: "后退15秒", action: #selector(rewindPressed))
            configureButton(verticalForwardButton, imageName: "goforward.15", label: "前进15秒", action: #selector(forwardPressed))
            configureButton(volumeButton, imageName: "speaker.wave.2.fill", label: "音量", action: #selector(volumePressed))
            configureButton(episodeButton, imageName: "list.bullet", label: "选集", action: #selector(selectEpisodePressed))

            verticalSeekStack.axis = .vertical
            verticalSeekStack.alignment = .center
            verticalSeekStack.distribution = .fillEqually
            verticalSeekStack.spacing = 12
            verticalSeekStack.translatesAutoresizingMaskIntoConstraints = false
            verticalSeekStack.addArrangedSubview(verticalRewindButton)
            verticalSeekStack.addArrangedSubview(verticalForwardButton)
            view.controllerView.addSubview(verticalSeekStack)
            NSLayoutConstraint.activate([
                verticalSeekStack.trailingAnchor.constraint(equalTo: view.safeTrailingAnchor, constant: -14),
                verticalSeekStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                verticalSeekStack.widthAnchor.constraint(equalToConstant: 46),
                verticalRewindButton.heightAnchor.constraint(equalToConstant: 42),
                verticalForwardButton.heightAnchor.constraint(equalToConstant: 42)
            ])

            self.canPlayPrevious = canPlayPrevious
            self.canPlayNext = canPlayNext
            self.canSelectEpisode = canSelectEpisode
            let toolbar = view.toolBar
            let orderedViews: [UIView] = [
                previousButton,
                rewindButton,
                toolbar.playButton,
                forwardButton,
                nextButton,
                toolbar.timeLabel,
                volumeButton,
                toolbar.playbackRateButton,
                episodeButton,
                view.landscapeButton
            ]
            for arranged in toolbar.arrangedSubviews {
                toolbar.removeArrangedSubview(arranged)
                if !orderedViews.contains(where: { $0 === arranged }) {
                    arranged.removeFromSuperview()
                }
            }
            for arranged in orderedViews {
                toolbar.addArrangedSubview(arranged)
            }
            toolbar.spacing = 6
            updateActionButtons(
                canPlayPrevious: canPlayPrevious,
                canPlayNext: canPlayNext,
                canSelectEpisode: canSelectEpisode
            )
            updateControlVisibility(isVisible: view.isMaskShow)
        }

        func updateActionButtons(canPlayPrevious: Bool, canPlayNext: Bool, canSelectEpisode: Bool) {
            self.canPlayPrevious = canPlayPrevious
            self.canPlayNext = canPlayNext
            self.canSelectEpisode = canSelectEpisode
            updateActionButtonsLayout(isLandscape: isLandscape)
        }

        func updateActionButtonsLayout(isLandscape: Bool) {
            self.isLandscape = isLandscape
            previousButton.isHidden = !canPlayPrevious
            nextButton.isHidden = !canPlayNext
            // 剧集导航只在横屏显示，竖屏保留播放、时间、15秒、音量和全屏。
            previousButton.isHidden = !isLandscape || !canPlayPrevious
            nextButton.isHidden = !isLandscape || !canPlayNext
            episodeButton.isHidden = !isLandscape || !canSelectEpisode
            rewindButton.isHidden = !isLandscape
            forwardButton.isHidden = !isLandscape
            verticalSeekStack.isHidden = isLandscape
            volumeButton.isHidden = false
        }

        func updateControlVisibility(isVisible: Bool) {
            let alpha: CGFloat = isVisible ? 1 : 0
            UIView.animate(withDuration: 0.2) {
                self.verticalSeekStack.alpha = alpha
            }
        }

        private func configureButton(_ button: UIButton, imageName: String, label: String, action: Selector) {
            button.setImage(UIImage(systemName: imageName), for: .normal)
            button.tintColor = .white
            button.accessibilityLabel = label
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 30).isActive = true
            button.backgroundColor = UIColor.black.withAlphaComponent(0.58)
            button.layer.cornerRadius = 21
            button.clipsToBounds = true
            button.addTarget(self, action: action, for: .primaryActionTriggered)
        }

        @objc private func previousPressed() {
            onPlayPrevious?()
        }

        @objc private func rewindPressed() {
            guard let playerView, playerView.toolBar.isSeekable else { return }
            let target = max(0, playerView.toolBar.currentTime - 15)
            playerView.seek(time: target) { _ in }
        }

        @objc private func forwardPressed() {
            guard let playerView, playerView.toolBar.isSeekable else { return }
            let target = min(
                playerView.toolBar.totalTime,
                playerView.toolBar.currentTime + 15
            )
            playerView.seek(time: target) { _ in }
        }

        @objc private func nextPressed() {
            onPlayNext?()
        }

        @objc private func selectEpisodePressed() {
            onSelectEpisode?()
        }

        @objc private func volumePressed() {
            guard let playerView else { return }
            let slider = playerView.volumeViewSlider
            if slider.value > 0.02 {
                lastVolume = slider.value
                slider.setValue(0, animated: false)
                volumeButton.setImage(UIImage(systemName: "speaker.slash.fill"), for: .normal)
            } else {
                slider.setValue(max(lastVolume, 0.5), animated: false)
                volumeButton.setImage(UIImage(systemName: "speaker.wave.2.fill"), for: .normal)
            }
            slider.sendActions(for: .valueChanged)
        }

        func playerController(state _: KSPlayerState) {}

        func playerController(currentTime: TimeInterval, totalTime: TimeInterval) {
            updateDanmakuTime(currentTime: currentTime, duration: totalTime)
            onProgressChanged?(currentTime, totalTime > 0 ? totalTime : nil)
        }

        func playerController(finish error: Error?) {
            danmakuView?.reset()
            guard error == nil else { return }
            DispatchQueue.main.async { [weak self] in
                self?.onPlaybackEnded?()
            }
        }

        func playerController(maskShow: Bool) {
            updateControlVisibility(isVisible: maskShow)
        }

        func playerController(action: PlayerButtonType) {
            // KSPlayer already performs the native action. Forward it after
            // that handling so the host can observe back/rate/PiP actions.
            onPlayerAction?(action)
        }

        func playerController(bufferedCount _: Int, consumeTime _: TimeInterval) {}

        func playerController(seek time: TimeInterval) {
            danmakuView?.reset()
            updateDanmakuTime(currentTime: time, duration: lastPlayerDuration)
        }

        func updateDanmakuTime(currentTime: TimeInterval, duration: TimeInterval) {
            lastPlayerTime = max(0, currentTime.isFinite ? currentTime : 0)
            lastPlayerDuration = max(0, duration.isFinite ? duration : 0)
            danmakuView?.update(currentTime: lastPlayerTime, duration: lastPlayerDuration)
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
