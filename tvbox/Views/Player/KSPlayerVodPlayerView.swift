import SwiftUI

#if os(iOS)
import KSPlayer
import AVKit
import UIKit

extension Notification.Name {
    static let congcongPlaybackSessionWillChange = Notification.Name(
        "CongcongPlaybackSessionWillChange"
    )
}

/// SwiftUI adapter for KSPlayer's native iOS player view.
struct KSPlayerVodPlayerView: View {
    let urlString: String
    var playbackHeaders: [String: String] = [:]
    var preferFFmpegBackend = false
    var startPosition: Double = 0
    var playbackSessionToken: UUID? = nil
    var isResolvingPlayback = false
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
    var onMarkIntro: (() -> Void)? = nil
    var onMarkOutro: (() -> Void)? = nil
    var onResetIntro: (() -> Void)? = nil
    var onResetOutro: (() -> Void)? = nil
    var introLabel: String = "片头"
    var outroLabel: String = "片尾"
    var danmakuTitle: String = ""
    var danmakuEpisode: String = ""
    /// Forwards native toolbar actions to the host without replacing KSPlayer's handling.
    var onPlayerAction: ((PlayerButtonType) -> Void)? = nil

    var body: some View {
        if let url = Self.makeURL(from: urlString) {
            KSPlayerUIView(
                url: url,
                playbackHeaders: playbackHeaders,
                preferFFmpegBackend: preferFFmpegBackend,
                startPosition: max(0, startPosition),
                playbackSessionToken: playbackSessionToken,
                isResolvingPlayback: isResolvingPlayback,
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
                onMarkIntro: onMarkIntro,
                onMarkOutro: onMarkOutro,
                onResetIntro: onResetIntro,
                onResetOutro: onResetOutro,
                introLabel: introLabel,
                outroLabel: outroLabel,
                danmakuTitle: danmakuTitle,
                danmakuEpisode: danmakuEpisode
            )
            .background(Color.clear)
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

private final class CongcongKSVideoPlayerView: IOSVideoPlayerView, UIGestureRecognizerDelegate {
    private static let supportedPlaybackRates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    private weak var interactivePopGestureRecognizer: UIGestureRecognizer?
    private weak var inlineSuperview: UIView?
    private var inlineFrameConstraints: [NSLayoutConstraint] = []
    private var inlineFrame = CGRect.zero
    private var inlineTranslatesAutoresizingMaskIntoConstraints = false
    private var restoreTask: DispatchWorkItem?
    // KSPlayer moves this exact view into its native full-screen controller.
    // Keep the playback layer alive until the view has been reattached inline.
    private var preservingFullscreenPlayer = false
    private var routeButtonLayoutInstalled = false
    /// KSPlayer 的 AVPlayer 后端不会消费 KSOptions.startPlayTime，
    /// 因此在 readyToPlay 后由宿主显式 seek 一次。
    fileprivate var pendingStartPosition: TimeInterval = 0
    fileprivate var didApplyStartPosition = false
    private var didStartInitialPlayback = false
    private var startPositionRetryCount = 0
    private let startPositionCoverView = UIView()
    private var startPositionCoverInstalled = false
    fileprivate var canShowPlaybackControl = false
    fileprivate var hasDisplayedCurrentVideoFrame = false
    fileprivate var canShowPlayerControls: Bool {
        canShowPlaybackControl
            && ((hasDisplayedCurrentVideoFrame && hasPlaybackAdvanced) || playbackFailed)
    }
    private var playbackFailed = false
    private var hasPlaybackAdvanced = false
    private weak var observedVideoLayer: AVPlayerLayer?
    private var firstFrameObservation: NSKeyValueObservation?
    private var firstFrameStartPosition: TimeInterval = 0
    private var startPositionGeneration = 0
    private var startPositionRetryWorkItem: DispatchWorkItem?
    /// SwiftUI 可能在 KSPlayer 全屏转场期间重新配置同一个 UIView。
    /// 将媒体身份保存在原生视图上，避免把重挂载误判为新会话并重复 set(url:)。
    fileprivate var configuredPlaybackURL: URL?
    fileprivate var configuredPlaybackHeaders: [String: String] = [:]
    fileprivate var configuredPreferFFmpegBackend: Bool?
    fileprivate var configuredPlaybackSessionToken: UUID?
    // Keep the selected rate independent from KSPlayer's transient menu/player
    // rebuilds. Applying a rate must never recreate the current media item.
    fileprivate var desiredPlaybackRate: Float = 1.0
    private let deviceStatusView = UIView()
    private let deviceTimeLabel = UILabel()
    private let deviceBatteryIconView = UIImageView()
    private let deviceBatteryLabel = UILabel()
    private var deviceStatusTimer: Timer?
    private var playbackSessionObserver: NSObjectProtocol?
    var customControlsLayout: ((Bool) -> Void)?
    var customControlsRefresh: (() -> Void)?
    private var isSliderDragging = false
    private var sliderSeekCommitted = false
    private var panStartPoint: CGPoint?
    private var nativePanDirection: KSPanDirection?
    private var pendingSeekTarget: TimeInterval?
    private var seekRequestID = 0
    private var autoplayRetryWorkItem: DispatchWorkItem?

    override var isMaskShow: Bool {
        didSet {
            updateDeviceStatus(isLandscape: landscapeButton.isSelected)
            owningViewController?.setNeedsStatusBarAppearanceUpdate()
        }
    }

    override func updateUI(isFullScreen: Bool) {
        if isFullScreen {
            restoreTask?.cancel()
            restoreTask = nil
            preservingFullscreenPlayer = true
            captureInlineLayout()
        } else {
            // Keep this flag set while KSPlayer dismisses its controller. The
            // native completion reattaches the same view; only then can it be
            // treated as an ordinary inline SwiftUI view again.
            preservingFullscreenPlayer = true
        }

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

        if !isFullScreen {
            scheduleInlineRestoration()
        }
    }

    override func updateUI(isLandscape: Bool) {
        super.updateUI(isLandscape: isLandscape)
        // KSPlayer 在 landscape 分支会将按钮隐藏；这里覆盖该默认行为。
        landscapeButton.isHidden = false
        landscapeButton.isEnabled = true
        styleControlLayers(isLandscape: isLandscape)
        updateDeviceStatus(isLandscape: isLandscape)
        customControlsLayout?(isLandscape)
        owningViewController?.setNeedsStatusBarAppearanceUpdate()
    }

    override func slider(value: Double, event: ControlEvents) {
        switch event {
        case .touchDown:
            isSliderDragging = true
            sliderSeekCommitted = false
            pendingSeekTarget = nil
            // The base implementation only updates the preview value here;
            // it does not seek until the release event.
            super.slider(value: value, event: event)
        case .valueChanged:
            // KSPlayer's independent pan recognizer can emit valueChanged
            // without a preceding UIControl touchDown.
            if !isSliderDragging {
                isSliderDragging = true
                sliderSeekCommitted = false
            }
            pendingSeekTarget = nil
            super.slider(value: value, event: event)
        case .touchUpInside, .touchCancel:
            guard !sliderSeekCommitted else { return }
            sliderSeekCommitted = true
            isSliderDragging = false
            // KSSlider's base path only seeks for touchUpInside. Treat a
            // cancelled touch as the final position too, and let the base
            // implementation perform the single seek.
            super.slider(value: value, event: .touchUpInside)
        default:
            super.slider(value: value, event: event)
        }
    }

    override func seek(
        time: TimeInterval,
        completion: @escaping ((Bool) -> Void)
    ) {
        guard time.isFinite else {
            completion(false)
            return
        }

        seekRequestID &+= 1
        let requestID = seekRequestID
        pendingSeekTarget = max(0, min(time, toolBar.totalTime > 0 ? toolBar.totalTime : time))
        let target = pendingSeekTarget ?? max(0, time)

        // Keep the target visible until KSPlayer confirms this particular seek.
        // A stale playback tick must not move the thumb back to the pre-seek time.
        super.seek(time: target) { [weak self] success in
            DispatchQueue.main.async {
                guard let self, self.seekRequestID == requestID else { return }
                if success {
                    self.toolBar.currentTime = target
                }
                self.pendingSeekTarget = nil
                completion(success)
            }
        }
    }

    override func player(
        layer: KSPlayerLayer,
        currentTime: TimeInterval,
        totalTime: TimeInterval
    ) {
        guard playerLayer === layer else { return }
        updatePlaybackControlIfPlaying(layer: layer)
        // IOSVideoPlayerView normally guards this internally, but its private
        // drag flag does not cover every KSSlider tracking path. Keep the
        // user's preview thumb from being overwritten by playback callbacks.
        if let pendingSeekTarget {
            if abs(toolBar.totalTime - totalTime) > 0.1 {
                toolBar.totalTime = totalTime
            }
            toolBar.currentTime = pendingSeekTarget
            return
        }
        if isSliderDragging || toolBar.timeSlider.isTracking {
            if abs(toolBar.totalTime - totalTime) > 0.1 {
                toolBar.totalTime = totalTime
            }
            return
        }
        super.player(layer: layer, currentTime: currentTime, totalTime: totalTime)
    }

    override func resetPlayer() {
        super.resetPlayer()
        // resetPlayer() restores KSPlayer's default replay button visibility;
        // this app uses the toolbar button as the sole play/pause affordance.
        replayButton.isHidden = true
        if !canShowPlaybackControl {
            showPlaybackLoadingIndicator()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        installPlaybackSessionObserverIfNeeded()
        if window == nil {
            deviceStatusTimer?.invalidate()
            deviceStatusTimer = nil
        }
        applyTransparentSurfaces()
        syncInteractivePopGesture()
    }

    deinit {
        deviceStatusTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        if let playbackSessionObserver {
            NotificationCenter.default.removeObserver(playbackSessionObserver)
        }
    }

    private func installPlaybackSessionObserverIfNeeded() {
        guard playbackSessionObserver == nil else { return }
        playbackSessionObserver = NotificationCenter.default.addObserver(
            forName: .congcongPlaybackSessionWillChange,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self,
                  let token = notification.userInfo?["sessionToken"] as? UUID,
                  self.configuredPlaybackSessionToken == token else {
                return
            }
            self.pauseCurrentPlaybackForSessionChange()
        }
    }

    private func pauseCurrentPlaybackForSessionChange() {
        // Keep the current fullscreen frame mounted while the next URL resolves.
        // replacePlayback stops and releases this layer before the new one starts.
        playerLayer?.pause()
    }

    private func installDeviceStatusViewIfNeeded() {
        guard deviceStatusView.superview == nil else { return }
        deviceStatusView.translatesAutoresizingMaskIntoConstraints = false
        deviceStatusView.backgroundColor = .clear
        deviceStatusView.isOpaque = false
        deviceStatusView.layer.zPosition = 150
        deviceTimeLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        deviceBatteryIconView.image = UIImage(systemName: "battery.100")
        deviceBatteryIconView.tintColor = .white
        deviceBatteryIconView.contentMode = .scaleAspectFit
        deviceBatteryIconView.setContentHuggingPriority(.required, for: .horizontal)
        deviceBatteryIconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        deviceBatteryLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        [deviceTimeLabel, deviceBatteryLabel].forEach {
            $0.textColor = .white
            $0.shadowColor = UIColor.black.withAlphaComponent(0.85)
            $0.shadowOffset = CGSize(width: 0, height: 1)
        }
        let batteryStack = UIStackView(arrangedSubviews: [deviceBatteryIconView, deviceBatteryLabel])
        batteryStack.axis = .horizontal
        batteryStack.spacing = 3
        batteryStack.alignment = .center
        let stack = UIStackView(arrangedSubviews: [deviceTimeLabel, batteryStack])
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        deviceStatusView.addSubview(stack)
        controllerView.addSubview(deviceStatusView)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: deviceStatusView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: deviceStatusView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: deviceStatusView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: deviceStatusView.bottomAnchor),
            deviceBatteryIconView.widthAnchor.constraint(equalToConstant: 22),
            deviceBatteryIconView.heightAnchor.constraint(equalToConstant: 14),
            deviceStatusView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -14),
            deviceStatusView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
            deviceStatusView.heightAnchor.constraint(equalToConstant: 22)
        ])
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceBatteryLevelDidChange),
            name: UIDevice.batteryLevelDidChangeNotification,
            object: UIDevice.current
        )
        deviceStatusTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refreshDeviceStatus()
        }
        refreshDeviceStatus()
    }

    @objc private func deviceBatteryLevelDidChange() {
        refreshDeviceStatus()
    }

    private func refreshDeviceStatus() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        deviceTimeLabel.text = formatter.string(from: Date())
        let level = UIDevice.current.batteryLevel
        if level >= 0 {
            // UIDevice reports the system value as a 0...1 fraction. Do not
            // quantize it to the old five-percent steps.
            deviceBatteryLabel.text = "\(Int((level * 100).rounded()))%"
        } else {
            deviceBatteryLabel.text = ""
        }
    }

    private func updateDeviceStatus(isLandscape: Bool) {
        installDeviceStatusViewIfNeeded()
        deviceStatusView.isHidden = !isLandscape || !isMaskShow
        if isLandscape { refreshDeviceStatus() }
    }

    fileprivate func installRouteButtonLayout() {
        guard !routeButtonLayoutInstalled else { return }
        routeButtonLayoutInstalled = true

        // KSPlayer 默认把 routeButton 放进顶部 navigationBar；移到控制层右侧中部，
        // 避免横屏时和标题/返回按钮挤在一起，也避免重复显示。
        navigationBar.removeArrangedSubview(routeButton)
        routeButton.removeFromSuperview()
        controllerView.addSubview(routeButton)
        routeButton.translatesAutoresizingMaskIntoConstraints = false
        routeButton.layer.zPosition = 120
        NSLayoutConstraint.activate([
            routeButton.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -12),
            routeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            routeButton.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    private func styleControlLayers(isLandscape: Bool) {
        // 横屏时播放器可能在视频上下出现留边；控制层本身不能把留边固化成黑色。
        // 控制层和按钮都不应固化为黑色背景。
        let colors: [CGColor]
        if isLandscape {
            colors = [UIColor.clear.cgColor, UIColor.clear.cgColor]
        } else {
            let color = UIColor.black.withAlphaComponent(0.5).cgColor
            colors = [color, UIColor.clear.cgColor]
        }
        topMaskView.gradientLayer.colors = colors
        bottomMaskView.gradientLayer.colors = colors
        topMaskView.backgroundColor = .clear
        bottomMaskView.backgroundColor = .clear
        topMaskView.isOpaque = false
        bottomMaskView.isOpaque = false
    }

    override func player(layer: KSPlayerLayer, state: KSPlayerState) {
        guard playerLayer === layer else { return }
        super.player(layer: layer, state: state)
        installFirstFrameObservation(for: layer)
        // KSPlayer's centered replay button is redundant with the toolbar
        // play button in this app. It is especially distracting while a new
        // episode is preparing because the native paused callback briefly
        // makes it visible before autoplay resumes.
        replayButton.isHidden = true
        switch state {
        case .initialized, .preparing, .readyToPlay:
            showPlaybackLoadingIndicator()
        case .buffering:
            if !hidePlaybackLoadingIndicatorIfVideoIsPlaying(layer: layer) {
                showPlaybackLoadingIndicator()
            }
        case .bufferFinished:
            if layer.player.isPlaying {
                updatePlaybackControlIfPlaying(layer: layer)
            } else {
                showPlaybackLoadingIndicator()
                if !hasDisplayedCurrentVideoFrame, didStartInitialPlayback {
                    requestInitialPlayback(layer: layer)
                }
            }
        case .paused:
            if hidePlaybackLoadingIndicatorIfVideoIsPlaying(layer: layer)
                || (hasDisplayedCurrentVideoFrame && hasPlaybackAdvanced) {
                hidePlaybackLoadingIndicator()
            } else {
                showPlaybackLoadingIndicator()
                if didStartInitialPlayback {
                    // KSPlayer emits a transient paused callback while its
                    // backend is transitioning into playback. Keep loading
                    // visible and retry until the first frame is ready.
                    requestInitialPlayback(layer: layer)
                }
            }
        case .playedToTheEnd:
            hidePlaybackLoadingIndicator()
        case .error:
            autoplayRetryWorkItem?.cancel()
            autoplayRetryWorkItem = nil
            playbackFailed = true
            hidePlaybackLoadingIndicator()
            canShowPlaybackControl = true
            customControlsRefresh?()
            toolBar.playButton.isEnabled = true
            startPositionCoverView.isHidden = true
        }
        guard state == .readyToPlay else { return }

        // KSPlayer can replace its backend during preparation. Re-apply only
        // the rate to the current backend; do not call set(url:) or seek.
        applyPlaybackRate(desiredPlaybackRate, persist: false, rebuildMenu: false)

        startInitialPlaybackIfNeeded(layer: layer)

        // KSPlayer 2.3.4 每次 readyToPlay 都会重建一次默认倍速菜单，默认只到 2x。
        // 在它完成初始化后覆盖菜单，避免切集或重连时选项又被恢复。
        rebuildPlaybackRateMenu()
        DispatchQueue.main.async { [weak self, weak layer] in
            guard let self, let layer, self.playerLayer === layer else { return }
            self.isMaskShow = true
            self.customControlsLayout?(self.landscapeButton.isSelected)
            self.customControlsRefresh?()
        }
    }

    private func installStartPositionCoverIfNeeded() {
        guard !startPositionCoverInstalled else { return }
        startPositionCoverInstalled = true
        startPositionCoverView.translatesAutoresizingMaskIntoConstraints = false
        startPositionCoverView.backgroundColor = .black
        startPositionCoverView.isOpaque = true
        startPositionCoverView.layer.zPosition = 400
        contentOverlayView.addSubview(startPositionCoverView)
        NSLayoutConstraint.activate([
            startPositionCoverView.leadingAnchor.constraint(equalTo: contentOverlayView.leadingAnchor),
            startPositionCoverView.trailingAnchor.constraint(equalTo: contentOverlayView.trailingAnchor),
            startPositionCoverView.topAnchor.constraint(equalTo: contentOverlayView.topAnchor),
            startPositionCoverView.bottomAnchor.constraint(equalTo: contentOverlayView.bottomAnchor)
        ])
    }

    fileprivate func prepareInitialPlayback(startPosition: TimeInterval) {
        startPositionGeneration &+= 1
        startPositionRetryWorkItem?.cancel()
        startPositionRetryWorkItem = nil
        pendingStartPosition = VodPlaybackState.normalizedProgress(startPosition)
        didApplyStartPosition = false
        didStartInitialPlayback = false
        canShowPlaybackControl = false
        hasDisplayedCurrentVideoFrame = false
        playbackFailed = false
        hasPlaybackAdvanced = false
        firstFrameObservation?.invalidate()
        firstFrameObservation = nil
        observedVideoLayer = nil
        firstFrameStartPosition = pendingStartPosition
        startPositionRetryCount = 0
        installStartPositionCoverIfNeeded()
        startPositionCoverView.isHidden = pendingStartPosition <= 0.5
        toolBar.playButton.isEnabled = pendingStartPosition <= 0.5
        toolBar.playButton.alpha = 0
        replayButton.isHidden = true
        autoplayRetryWorkItem?.cancel()
        autoplayRetryWorkItem = nil
        showPlaybackLoadingIndicator()
        customControlsRefresh?()
    }

    private func startInitialPlaybackIfNeeded(layer: KSPlayerLayer) {
        guard !didStartInitialPlayback else { return }
        guard pendingStartPosition > 0.5, pendingStartPosition.isFinite else {
            didStartInitialPlayback = true
            startPositionCoverView.isHidden = true
            toolBar.playButton.isEnabled = true
            requestInitialPlayback(layer: layer)
            return
        }
        guard !didApplyStartPosition else { return }

        // KSPlayer queues seek requests internally when the backend is not yet
        // seekable. Wait without issuing a seek so the app retry loop cannot
        // race that internal deferred seek.
        guard layer.player.isReadyToPlay, layer.player.seekable else {
            retryStartPositionWhenSeekable(layer: layer)
            return
        }

        toolBar.playButton.isEnabled = false
        didApplyStartPosition = true
        let requestedPosition = pendingStartPosition
        let duration = layer.player.duration
        let validDuration = duration.isFinite && duration > 0 ? duration : 0
        let target: TimeInterval
        if validDuration > 0 {
            // A completed/invalid resume point should replay from the start,
            // not seek to EOF and immediately trigger end-of-item behavior.
            guard requestedPosition < validDuration - 1 else {
                startInitialPlaybackFromBeginning(layer: layer)
                return
            }
            target = min(requestedPosition, validDuration)
        } else {
            target = requestedPosition
        }
        firstFrameStartPosition = target
        let generation = startPositionGeneration
        layer.player.seek(time: target) { [weak self, weak layer] success in
            DispatchQueue.main.async {
                guard let self,
                      let layer,
                      self.playerLayer === layer,
                      self.startPositionGeneration == generation else { return }
                self.startPositionRetryWorkItem?.cancel()
                self.startPositionRetryWorkItem = nil
                if success {
                    self.didStartInitialPlayback = true
                    self.pendingStartPosition = 0
                    self.startPositionCoverView.isHidden = true
                    self.toolBar.playButton.isEnabled = true
                    self.requestInitialPlayback(layer: layer)
                    return
                }

                // Do not retry a failed seek: KSPlayer may already have
                // accepted it into its own deferred-seek path.
                self.startInitialPlaybackFromBeginning(layer: layer)
            }
        }
    }

    private func retryStartPositionWhenSeekable(layer: KSPlayerLayer) {
        guard startPositionRetryWorkItem == nil else { return }
        guard startPositionRetryCount < 8 else {
            startInitialPlaybackFromBeginning(layer: layer)
            return
        }

        startPositionRetryCount += 1
        let generation = startPositionGeneration
        let workItem = DispatchWorkItem { [weak self, weak layer] in
            guard let self,
                  let layer,
                  self.playerLayer === layer,
                  self.startPositionGeneration == generation else { return }
            self.startPositionRetryWorkItem = nil
            self.startInitialPlaybackIfNeeded(layer: layer)
        }
        startPositionRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    private func startInitialPlaybackFromBeginning(layer: KSPlayerLayer) {
        guard playerLayer === layer else { return }
        startPositionRetryWorkItem?.cancel()
        startPositionRetryWorkItem = nil
        pendingStartPosition = 0
        firstFrameStartPosition = 0
        didApplyStartPosition = false
        didStartInitialPlayback = true
        startPositionCoverView.isHidden = true
        toolBar.playButton.isEnabled = true
        requestInitialPlayback(layer: layer)
    }

    private func requestInitialPlayback(layer: KSPlayerLayer) {
        guard playerLayer === layer,
              didStartInitialPlayback,
              !(hasDisplayedCurrentVideoFrame && hasPlaybackAdvanced && layer.player.isPlaying),
              autoplayRetryWorkItem == nil else { return }
        if layer.player.isReadyToPlay, !layer.player.isPlaying {
            showPlaybackLoadingIndicator()
            play()
        }
        if layer.player.isPlaying, hasDisplayedCurrentVideoFrame {
            updatePlaybackControlIfPlaying(layer: layer)
            if hasPlaybackAdvanced {
                return
            }
        }
        let workItem = DispatchWorkItem { [weak self, weak layer] in
            guard let self,
                  let layer,
                  self.playerLayer === layer,
                  self.didStartInitialPlayback,
                  !(self.hasDisplayedCurrentVideoFrame
                    && self.hasPlaybackAdvanced
                    && layer.player.isPlaying) else { return }
            self.autoplayRetryWorkItem = nil
            guard layer.state != .error else {
                self.hidePlaybackLoadingIndicator()
                return
            }
            if layer.player.isPlaying {
                self.updatePlaybackControlIfPlaying(layer: layer)
                if self.hasDisplayedCurrentVideoFrame, self.hasPlaybackAdvanced {
                    return
                }
            } else {
                self.showPlaybackLoadingIndicator()
                if layer.player.isReadyToPlay {
                    self.play()
                }
            }
            self.requestInitialPlayback(layer: layer)
        }
        autoplayRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    private func updatePlaybackControlIfPlaying(layer: KSPlayerLayer) {
        guard playerLayer === layer, layer.player.isPlaying else { return }
        if !canShowPlaybackControl {
            autoplayRetryWorkItem?.cancel()
            autoplayRetryWorkItem = nil
            canShowPlaybackControl = true
            toolBar.playButton.isSelected = true
            customControlsRefresh?()
        }

        if layer.player.tracks(mediaType: .video).isEmpty {
            hasDisplayedCurrentVideoFrame = true
            hasPlaybackAdvanced = true
        } else {
            installFirstFrameObservation(for: layer)
            if !hasPlaybackAdvanced {
                let currentTime = layer.player.currentPlaybackTime
                if currentTime.isFinite, currentTime - firstFrameStartPosition >= 0.08 {
                    hasPlaybackAdvanced = true
                }
            }
            // Non-AVPlayer KSPlayer backends do not expose AVPlayerLayer's
            // first-frame signal. Only infer readiness after playback time
            // has actually advanced from this session's start point.
            if observedVideoLayer == nil {
                let currentTime = layer.player.currentPlaybackTime
                if currentTime.isFinite, currentTime - firstFrameStartPosition >= 0.25 {
                    hasDisplayedCurrentVideoFrame = true
                    hasPlaybackAdvanced = true
                }
            }
        }
        if hasDisplayedCurrentVideoFrame {
            autoplayRetryWorkItem?.cancel()
            autoplayRetryWorkItem = nil
            hidePlaybackLoadingIndicator()
        } else {
            showPlaybackLoadingIndicator()
        }
    }

    private func installFirstFrameObservation(for layer: KSPlayerLayer) {
        guard playerLayer === layer,
              let renderLayer = layer.player.view?.layer as? AVPlayerLayer else { return }
        // The initial KVO delivery below also reports a layer that was ready
        // before observation began. Re-entering the frame callback synchronously
        // here can recurse through autoplay -> controls -> observation until the
        // main-thread stack overflows.
        guard observedVideoLayer !== renderLayer else { return }

        firstFrameObservation?.invalidate()
        observedVideoLayer = renderLayer
        firstFrameObservation = renderLayer.observe(
            \.isReadyForDisplay,
            options: [.initial, .new]
        ) { [weak self, weak layer] renderLayer, _ in
            guard renderLayer.isReadyForDisplay else { return }
            DispatchQueue.main.async {
                guard let self, let layer,
                      self.playerLayer === layer,
                      self.observedVideoLayer === renderLayer,
                      layer.player.view?.layer === renderLayer else { return }
                self.markFirstVideoFrameDisplayed(for: layer, renderedBy: renderLayer)
            }
        }
    }

    private func markFirstVideoFrameDisplayed(for layer: KSPlayerLayer, renderedBy renderLayer: AVPlayerLayer) {
        guard playerLayer === layer,
              observedVideoLayer === renderLayer,
              layer.player.view?.layer === renderLayer else { return }
        hasDisplayedCurrentVideoFrame = true
        if !hasPlaybackAdvanced {
            let currentTime = layer.player.currentPlaybackTime
            if currentTime.isFinite, currentTime - firstFrameStartPosition >= 0.08 {
                hasPlaybackAdvanced = true
            }
        }
        if layer.player.isPlaying {
            hidePlaybackLoadingIndicator()
            if hasPlaybackAdvanced {
                autoplayRetryWorkItem?.cancel()
                autoplayRetryWorkItem = nil
                if !canShowPlaybackControl {
                    canShowPlaybackControl = true
                    toolBar.playButton.isSelected = true
                }
                customControlsRefresh?()
            } else {
                // Playback may have started at a resume timestamp that is
                // rounded by the backend. The rendered frame is enough to hide
                // the loader; keep retrying only for control-state readiness.
                requestInitialPlayback(layer: layer)
            }
        } else {
            // AVPlayerLayer may expose a paused frame before the playback
            // clock advances. Keep the loader over that still frame and start
            // playback immediately; hide the loader on the first time tick.
            autoplayRetryWorkItem?.cancel()
            autoplayRetryWorkItem = nil
            showPlaybackLoadingIndicator()
            requestInitialPlayback(layer: layer)
        }
    }

    private func showPlaybackLoadingIndicator() {
        loadingIndector.isHidden = false
        loadingIndector.startAnimating()
    }

    @discardableResult
    private func hidePlaybackLoadingIndicatorIfVideoIsPlaying(layer: KSPlayerLayer) -> Bool {
        guard playerLayer === layer,
              layer.player.isPlaying,
              hasDisplayedCurrentVideoFrame else { return false }
        hidePlaybackLoadingIndicator()
        return true
    }

    private func hidePlaybackLoadingIndicator() {
        loadingIndector.stopAnimating()
        loadingIndector.isHidden = true
    }

    override func player(layer: KSPlayerLayer, finish error: Error?) {
        // An old layer can finish asynchronously while a new episode is being
        // installed. Ignore it so it cannot advance the new episode again.
        guard playerLayer === layer else { return }
        super.player(layer: layer, finish: error)
    }

    private func normalizedPlaybackRate(_ raw: Float) -> Float {
        guard raw.isFinite, raw > 0 else { return 1.0 }
        return Self.supportedPlaybackRates.min {
            abs($0 - raw) < abs($1 - raw)
        } ?? 1.0
    }

    private func applyPlaybackRate(
        _ rawRate: Float,
        persist: Bool,
        rebuildMenu: Bool
    ) {
        let rate = normalizedPlaybackRate(rawRate)
        let apply = { [weak self] in
            guard let self else { return }
            self.desiredPlaybackRate = rate
            if persist {
                UserDefaults.standard.set(Double(rate), forKey: HawkConfig.PLAY_SPEED)
            }
            guard let player = self.playerLayer?.player else {
                if rebuildMenu { self.rebuildPlaybackRateMenu() }
                return
            }

            // The rate setter changes the existing AVPlayer backend in place.
            // Keep a defensive position checkpoint so a backend implementation
            // that momentarily resets its time cannot restart the episode.
            let position = player.currentPlaybackTime
            let wasPlaying = player.isPlaying
            player.playbackRate = rate
            if position.isFinite, position > 0,
               abs(player.currentPlaybackTime - position) > 0.25 {
                player.seek(time: position) { [weak self] success in
                    guard success, wasPlaying else { return }
                    DispatchQueue.main.async {
                        self?.playerLayer?.player.play()
                    }
                }
            }
            if rebuildMenu {
                self.rebuildPlaybackRateMenu()
            }
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    fileprivate func rebuildPlaybackRateMenu() {
        guard #available(iOS 14.0, *) else { return }
        let current = normalizedPlaybackRate(
            playerLayer?.player.playbackRate ?? desiredPlaybackRate
        )
        let actions = Self.supportedPlaybackRates.map { rate in
            UIAction(
                title: String(format: "%.2gx", rate),
                state: abs(rate - current) < 0.01 ? .on : .off
            ) { [weak self] _ in
                self?.applyPlaybackRate(rate, persist: true, rebuildMenu: true)
            }
        }
        toolBar.playbackRateButton.menu = UIMenu(title: "倍速", children: actions)
        toolBar.playbackRateButton.showsMenuAsPrimaryAction = true
        toolBar.playbackRateButton.setTitle(nil, for: .normal)
        toolBar.playbackRateButton.setImage(UIImage(systemName: "speedometer"), for: .normal)
        toolBar.playbackRateButton.accessibilityLabel = "倍速"
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        applyTransparentSurfaces()
        // KSPlayer performs the actual reparenting in its dismissal
        // completion. Restore constraints only after that callback, never by
        // racing it with an early addSubview from our side.
        if !landscapeButton.isSelected, superview === inlineSuperview {
            restoreInlineLayout()
        }
        syncInteractivePopGesture()
    }

    private func captureInlineLayout() {
        guard let container = superview else { return }
        if inlineSuperview === container, !inlineFrameConstraints.isEmpty {
            return
        }
        inlineSuperview = container
        inlineFrameConstraints = inlineLayoutConstraints(in: container)
        inlineFrame = frame
        inlineTranslatesAutoresizingMaskIntoConstraints = translatesAutoresizingMaskIntoConstraints
    }

    private func inlineLayoutConstraints(in container: UIView) -> [NSLayoutConstraint] {
        var result = container.constraints.filter { constraint in
            constraint.firstItem === self || constraint.secondItem === self
        }
        result.append(contentsOf: constraints.filter { constraint in
            guard constraint.firstItem === self || constraint.secondItem === self else {
                return false
            }
            return constraint.firstAttribute == .width
                || constraint.firstAttribute == .height
                || constraint.secondAttribute == .width
                || constraint.secondAttribute == .height
        })
        return result
    }

    private func scheduleInlineRestoration() {
        restoreTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.restoreInlineLayout()
        }
        restoreTask = task

        // Wait for KSPlayer's PlayerTransitionAnimator to finish before
        // restoring the inline constraints. Reattaching during the animation
        // is what causes the view to briefly jump to the window's top-left.
        if let coordinator = owningViewController?.transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                self?.restoreInlineLayout()
            }
        }
        // Covers rotation and dismissals without a transition coordinator.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: task)
    }

    private func restoreInlineLayout() {
        guard !landscapeButton.isSelected, let container = inlineSuperview else { return }
        restoreTask?.cancel()
        restoreTask = nil

        // The native KSPlayer transition owns reparenting. If it has not
        // completed yet, leave the view where KSPlayer put it and let
        // didMoveToSuperview call us again after the dismissal callback.
        guard superview === container else { return }
        translatesAutoresizingMaskIntoConstraints = inlineTranslatesAutoresizingMaskIntoConstraints
        if inlineFrameConstraints.isEmpty {
            translatesAutoresizingMaskIntoConstraints = true
            frame = inlineFrame
        } else {
            NSLayoutConstraint.activate(inlineFrameConstraints)
        }
        applyTransparentSurfaces()
        container.setNeedsLayout()
        container.layoutIfNeeded()
        updateUI(isLandscape: false)
        preservingFullscreenPlayer = false
    }

    fileprivate var isPreservingFullscreenPlayer: Bool {
        preservingFullscreenPlayer || landscapeButton.isSelected
    }

    /// Stop and release the current media item before installing another URL.
    /// Pausing alone leaves the old AVPlayerItem and audio pipeline alive.
    func stopCurrentPlayback(reportFinalProgress: Bool = true) {
        startPositionGeneration &+= 1
        startPositionRetryWorkItem?.cancel()
        startPositionRetryWorkItem = nil
        let layer = playerLayer
        let progressHandler = playTimeDidChange
        playTimeDidChange = nil
        autoplayRetryWorkItem?.cancel()
        autoplayRetryWorkItem = nil
        firstFrameObservation?.invalidate()
        firstFrameObservation = nil
        observedVideoLayer = nil
        layer?.delegate = nil

        // SwiftUI dismantleUIView 可能先于 DetailView.onDisappear 触发；
        // 先把播放器最后的有效位置回传，避免页面退出时丢掉尾部进度。
        if reportFinalProgress, let player = layer?.player {
            let current = player.currentPlaybackTime
            let duration = player.duration
            if current.isFinite, current > 0 {
                progressHandler?(current, duration.isFinite && duration > 0 ? duration : 0)
            }
        }
        layer?.pause()
        layer?.stop()
        playerLayer = nil
        pendingStartPosition = 0
        didApplyStartPosition = false
        didStartInitialPlayback = false
        canShowPlaybackControl = false
        hasDisplayedCurrentVideoFrame = false
        playbackFailed = false
        hasPlaybackAdvanced = false
        startPositionRetryCount = 0
        startPositionCoverView.isHidden = true
        toolBar.playButton.isEnabled = true
        toolBar.playButton.alpha = 0
        replayButton.isHidden = true
        hidePlaybackLoadingIndicator()
        configuredPlaybackURL = nil
        configuredPlaybackHeaders = [:]
        configuredPreferFFmpegBackend = nil
        configuredPlaybackSessionToken = nil
    }

    func replacePlayback(url: URL, options: KSOptions, preferFFmpegBackend: Bool) {
        let oldLayer = playerLayer
        oldLayer?.delegate = nil
        // The detail flow checkpoints history before rotating the session token.
        // Never send the retired layer's final callback through the new session.
        playTimeDidChange = nil

        // Stop the old audio pipeline before KSPlayer constructs the replacement layer.
        // Keep its view attached until set(url:) swaps it.
        oldLayer?.pause()
        oldLayer?.stop()
        // KSPlayer selects its backend when the layer is created. This app has
        // one active VOD session, so keep the preference aligned for native
        // quality/URL changes as well as the initial request.
        KSOptions.firstPlayerType = preferFFmpegBackend ? KSMEPlayer.self : KSAVPlayer.self
        KSOptions.secondPlayerType = preferFFmpegBackend ? KSAVPlayer.self : KSMEPlayer.self
        super.set(url: url, options: options)
        if let playerLayer {
            installFirstFrameObservation(for: playerLayer)
        }
    }

    private func applyTransparentSurfaces() {
        backgroundColor = .clear
        isOpaque = false
        contentOverlayView.backgroundColor = .clear
        contentOverlayView.isOpaque = false
        controllerView.backgroundColor = .clear
        controllerView.isOpaque = false
        topMaskView.backgroundColor = .clear
        bottomMaskView.backgroundColor = .clear
        playerLayer?.player.view?.backgroundColor = .clear
        playerLayer?.player.view?.isOpaque = false

        if landscapeButton.isSelected, let fullScreenViewController = owningViewController {
            fullScreenViewController.view.backgroundColor = .clear
            fullScreenViewController.view.isOpaque = false
        }
    }

    private func syncInteractivePopGesture() {
        // Full-screen controller may not have a navigation controller. The
        // slider exclusion must remain active there as well.
        // KSPlayer currently leaves this delegate unset. Only claim it when
        // it is available (or already ours), so a future KSPlayer delegate is
        // never overwritten on every view lifecycle callback.
        if panGesture.delegate == nil || panGesture.delegate === self {
            panGesture.delegate = self
        }
        // KSPlayer's 2x long-press recognizer has its own delegate. The
        // control-area exclusion in gestureRecognizer(_:shouldReceive:) only
        // works for recognizers whose delegate is this view; previously only
        // panGesture was wired, so long presses below the progress bar still
        // reached KSPlayer and enabled 2x playback.
        if longPressGesture.delegate == nil || longPressGesture.delegate === self {
            longPressGesture.delegate = self
        }
        panGesture.cancelsTouchesInView = false
        guard let navigationController = owningNavigationController,
              let popGesture = navigationController.interactivePopGestureRecognizer else {
            return
        }

        if interactivePopGestureRecognizer !== popGesture {
            interactivePopGestureRecognizer = popGesture
            // 让系统边缘返回优先识别，避免播放器原生横滑手势吞掉左边缘返回。
            panGesture.require(toFail: popGesture)
        }

        popGesture.isEnabled = !landscapeButton.isSelected
    }

    private var owningNavigationController: UINavigationController? {
        owningViewController?.navigationController
    }

    private var owningViewController: UIViewController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let viewController = next as? UIViewController {
                return viewController
            }
            responder = next
        }
        return nil
    }

    // KSPlayer 的原生 pan 手势同时处理横向进度、左侧亮度和右侧音量。
    // 这里只在进度条区域拒绝 pan，让 KSSlider 独占这块触摸区域，避免
    // 拖动滑块时原生 pan 又写回播放时间导致小圆点乱跳。
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        let touchPoint = touch.location(in: self)
        // 控制栏（进度条及其下方区域）只交给原生按钮和滑块处理，
        // 禁止左右调速/调进度以及 KSPlayer 长按 2x 手势抢占触摸。
        if (gestureRecognizer === panGesture || gestureRecognizer === longPressGesture),
           isControlBarTouchArea(touchPoint) {
            return false
        }
        guard gestureRecognizer === panGesture else { return true }
        panStartPoint = touchPoint
        return true
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === panGesture,
              let pan = gestureRecognizer as? UIPanGestureRecognizer else {
            return true
        }

        let velocity = pan.velocity(in: self)
        guard abs(velocity.x) > abs(velocity.y), abs(velocity.x) > 1 else {
            return true
        }

        let touchPoint = panStartPoint ?? pan.location(in: self)
        panStartPoint = nil
        // Keep the portrait left-edge swipe available for UINavigationController.
        if !landscapeButton.isSelected && touchPoint.x <= 32 {
            return false
        }
        return !isProgressSliderTouchArea(touchPoint)
    }

    private func isProgressSliderTouchArea(_ point: CGPoint) -> Bool {
        guard !toolBar.timeSlider.isHidden,
              toolBar.timeSlider.bounds.width > 0,
              toolBar.timeSlider.bounds.height > 0 else {
            return false
        }

        var sliderFrame = toolBar.timeSlider.convert(toolBar.timeSlider.bounds, to: self)
        // Include a generous but local hit-protection band around the visual
        // track. This prevents a horizontal seek gesture from stealing a
        // thumb drag while leaving the rest of the video surface available.
        sliderFrame = sliderFrame.insetBy(dx: -20, dy: -28)
        if sliderFrame.contains(point) {
            return true
        }

        // Some KSPlayer layouts make the slider's bounds very short while
        // the surrounding toolbar row is taller. Protect that row as well,
        // but only across the slider's horizontal span.
        let rowFrame = CGRect(
            x: sliderFrame.minX,
            y: sliderFrame.midY - 28,
            width: sliderFrame.width,
            height: 56
        )
        return rowFrame.contains(point)
    }

    private func isControlBarTouchArea(_ point: CGPoint) -> Bool {
        guard !toolBar.isHidden else { return false }
        var toolbarFrame = toolBar.convert(toolBar.bounds, to: self)
        toolbarFrame = toolbarFrame.insetBy(dx: -18, dy: -24)
        guard !toolBar.timeSlider.isHidden,
              toolBar.timeSlider.bounds.width > 0,
              toolBar.timeSlider.bounds.height > 0 else {
            return toolbarFrame.contains(point)
        }

        let sliderFrame = toolBar.timeSlider.convert(toolBar.timeSlider.bounds, to: self)
        let controlsBounds = controllerView.convert(controllerView.bounds, to: self)
        let areaBelowProgress = CGRect(
            x: controlsBounds.minX,
            y: sliderFrame.maxY,
            width: controlsBounds.width,
            height: max(0, controlsBounds.maxY - sliderFrame.maxY)
        )
        return toolbarFrame.contains(point)
            || isProgressSliderTouchArea(point)
            || areaBelowProgress.contains(point)
    }

    override func panGestureBegan(location point: CGPoint, direction: KSPanDirection) {
        nativePanDirection = direction
        if direction == .horizontal {
            // KSPlayer owns the seek math and target preview. Do not replace
            // its default velocity-to-time mapping with a second calculation.
            pendingSeekTarget = nil
            sliderSeekCommitted = false
        }
        super.panGestureBegan(location: point, direction: direction)
    }

    override func panGestureChanged(velocity point: CGPoint, direction: KSPanDirection) {
        super.panGestureChanged(velocity: point, direction: direction)
        if direction == .horizontal, toolBar.currentTime.isFinite {
            pendingSeekTarget = toolBar.currentTime
        }
    }

    override func panGestureEnded() {
        if nativePanDirection == .horizontal {
            // panGestureEnded in KSPlayer commits exactly this preview value
            // through slider(.touchUpInside). Keep it protected from the last
            // stale playback callback while that seek is in flight.
            pendingSeekTarget = toolBar.currentTime
        }
        super.panGestureEnded()
        nativePanDirection = nil
    }
}

private struct KSPlayerUIView: UIViewRepresentable {
    private static let supportedPlaybackRates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    let url: URL
    let playbackHeaders: [String: String]
    let preferFFmpegBackend: Bool
    let startPosition: Double
    let playbackSessionToken: UUID?
    let isResolvingPlayback: Bool
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
    let onMarkIntro: (() -> Void)?
    let onMarkOutro: (() -> Void)?
    let onResetIntro: (() -> Void)?
    let onResetOutro: (() -> Void)?
    let introLabel: String
    let outroLabel: String
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
            onMarkIntro: onMarkIntro,
            onMarkOutro: onMarkOutro,
            onResetIntro: onResetIntro,
            onResetOutro: onResetOutro,
            introLabel: introLabel,
            outroLabel: outroLabel,
            danmakuTitle: danmakuTitle,
            danmakuEpisode: danmakuEpisode
        )
    }

    func makeUIView(context: Context) -> CongcongKSVideoPlayerView {
        // KSPlayer's native full-screen controller temporarily reparents this
        // view. SwiftUI may ask the representable for its view again while
        // that transition is still in flight; reuse the retained instance so
        // the playback session is not torn down and recreated.
        if let retainedView = context.coordinator.retainedPlayerView {
            context.coordinator.configure(retainedView)
            retainedView.customControlsLayout = { [weak coordinator = context.coordinator] isLandscape in
                coordinator?.updateActionButtonsLayout(isLandscape: isLandscape)
            }
            let shouldConfigure = synchronizeCoordinator(context.coordinator, with: retainedView)
            if shouldConfigure {
                configure(retainedView, coordinator: context.coordinator)
            }
            return retainedView
        }

        let view = CongcongKSVideoPlayerView()
        context.coordinator.retainedPlayerView = view
        context.coordinator.configure(view)
        view.customControlsLayout = { [weak coordinator = context.coordinator] isLandscape in
            coordinator?.updateActionButtonsLayout(isLandscape: isLandscape)
        }
        _ = synchronizeCoordinator(context.coordinator, with: view)
        configure(view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ view: CongcongKSVideoPlayerView, context: Context) {
        let shouldConfigure = synchronizeCoordinator(context.coordinator, with: view)
        guard shouldConfigure else { return }
        configure(view, coordinator: context.coordinator)
    }

    private func synchronizeCoordinator(
        _ coordinator: Coordinator,
        with view: CongcongKSVideoPlayerView
    ) -> Bool {
        let tokenChanged = coordinator.playbackSessionToken != playbackSessionToken
        let mediaChanged = coordinator.url != url
        let headersChanged = coordinator.playbackHeaders != playbackHeaders
        let backendChanged = coordinator.preferFFmpegBackend != preferFFmpegBackend
        if tokenChanged {
            coordinator.playbackSessionToken = playbackSessionToken
        }
        if headersChanged {
            coordinator.playbackHeaders = playbackHeaders
        }
        if backendChanged {
            coordinator.preferFFmpegBackend = preferFFmpegBackend
        }
        if isResolvingPlayback && (tokenChanged || mediaChanged || headersChanged || backendChanged) {
            coordinator.pendingPlaybackReload = true
        }
        coordinator.onProgressChanged = isResolvingPlayback ? nil : onProgressChanged
        coordinator.onPlaybackEnded = isResolvingPlayback ? nil : onPlaybackEnded
        coordinator.onBack = onBack
        coordinator.onPlayerAction = onPlayerAction
        coordinator.onPlayPrevious = onPlayPrevious
        coordinator.onPlayNext = onPlayNext
        coordinator.onSelectEpisode = onSelectEpisode
        coordinator.onMarkIntro = onMarkIntro
        coordinator.onMarkOutro = onMarkOutro
        coordinator.onResetIntro = onResetIntro
        coordinator.onResetOutro = onResetOutro
        coordinator.updateMarkerLabels(intro: introLabel, outro: outroLabel)
        coordinator.updateDanmakuMetadata(title: danmakuTitle, episode: danmakuEpisode)
        coordinator.installActionButtons(
            on: view,
            canPlayPrevious: canPlayPrevious,
            canPlayNext: canPlayNext,
            canSelectEpisode: canSelectEpisode
        )
        coordinator.setPlaybackResolving(isResolvingPlayback)
        let canPlayPrevious = self.canPlayPrevious
        let canPlayNext = self.canPlayNext
        let canSelectEpisode = self.canSelectEpisode
        view.customControlsRefresh = { [weak coordinator, weak view] in
            guard let coordinator, let view else { return }
            coordinator.installActionButtons(
                on: view,
                canPlayPrevious: canPlayPrevious,
                canPlayNext: canPlayNext,
                canSelectEpisode: canSelectEpisode
            )
        }
        coordinator.updateActionButtonsLayout(isLandscape: view.landscapeButton.isSelected)
        view.customControlsLayout = { [weak coordinator] isLandscape in
            coordinator?.updateActionButtonsLayout(isLandscape: isLandscape)
        }
        let shouldConfigure = !isResolvingPlayback
            && (tokenChanged || mediaChanged || headersChanged || backendChanged || coordinator.pendingPlaybackReload)
        if shouldConfigure {
            coordinator.pendingPlaybackReload = false
        }
        return shouldConfigure
    }

    static func dismantleUIView(_ view: CongcongKSVideoPlayerView, coordinator: Coordinator) {
        // A native full-screen transition can temporarily make SwiftUI think
        // the representable disappeared. Do not tear down its layer or
        // coordinator callbacks; the same view is still owned by KSPlayer and
        // will be reattached when dismissal completes.
        guard !view.isPreservingFullscreenPlayer else { return }
        coordinator.tearDownDanmaku()
        view.stopCurrentPlayback()
        view.backBlock = nil
        view.delegate = nil
    }

    private func configure(_ view: CongcongKSVideoPlayerView, coordinator: Coordinator) {
        coordinator.url = url
        coordinator.playbackSessionToken = playbackSessionToken
        let needsPlaybackReplacement = view.playerLayer == nil
            || view.configuredPlaybackURL != url
            || view.configuredPlaybackHeaders != playbackHeaders
            || view.configuredPreferFFmpegBackend != preferFFmpegBackend
            || view.configuredPlaybackSessionToken != playbackSessionToken

        // 全屏进出只是同一个播放器 UIView 的重挂载，不能重置进度或重新
        // 安装媒体。否则 KSPlayer 会先从 0 开始，再执行一次恢复 seek。
        if needsPlaybackReplacement {
            view.prepareInitialPlayback(startPosition: startPosition)
            view.configuredPlaybackURL = url
            view.configuredPlaybackHeaders = playbackHeaders
            view.configuredPreferFFmpegBackend = preferFFmpegBackend
            view.configuredPlaybackSessionToken = playbackSessionToken
        }
        // KSPlayer configures the audio session too, but doing it here
        // keeps background audio available across view reattachment.
        KSOptions.setAudioSession()
        KSOptions.canBackgroundPlay = true
        // KSPlayer couples this flag to both prepareToPlay() and playback.
        // Keep its native initialization/autoplay path enabled.
        KSOptions.isAutoPlay = true
        // KSPlayer 原生 pan 手势：横向调进度，左侧纵向调亮度，右侧纵向调音量。
        // 显式开启，避免外部全局配置或旧版本默认值把这些交互关闭。
        KSOptions.enableBrightnessGestures = true
        KSOptions.enableVolumeGestures = true
        let options = KSOptions()
        playbackHeaders.forEach { options.appendHeader([$0.key: $0.value]) }
        // Start position is restored by the guarded seek path above. Leaving a
        // second native start-time request enabled can race that single seek.
        options.startPlayTime = 0
        let savedRate = UserDefaults.standard.object(forKey: HawkConfig.PLAY_SPEED) as? Double ?? 1.0
        let initialRate = Self.normalizedPlaybackRate(
            from: savedRate
        )
        view.desiredPlaybackRate = initialRate
        options.startPlayRate = initialRate
        options.registerRemoteControll = true
        // 本应用只提供点播，不启用画中画；尤其不能让播放器在内联状态下
        // 因切后台或系统事件自动进入 PiP。
        options.canStartPictureInPictureAutomaticallyFromInline = false
        if needsPlaybackReplacement {
            view.replacePlayback(
                url: url,
                options: options,
                preferFFmpegBackend: preferFFmpegBackend
            )
        }
        view.backgroundColor = .clear
        view.isOpaque = false
        view.contentOverlayView.backgroundColor = .clear
        view.controllerView.backgroundColor = .clear
        view.playerLayer?.player.view?.backgroundColor = .clear
        view.playerLayer?.player.view?.isOpaque = false
        // 完全移除 PiP 入口；投屏仍保留为独立的 AirPlay route 按钮。
        view.toolBar.pipButton.isHidden = true
        view.toolBar.pipButton.isEnabled = false
        view.routeButton.isHidden = false
        view.routeButton.tintColor = .white
        view.routeButton.activeTintColor = .systemOrange
        view.installRouteButtonLayout()
        view.toolBar.playbackRateButton.setTitle(nil, for: .normal)
        view.toolBar.playbackRateButton.setImage(UIImage(systemName: "speedometer"), for: .normal)
        view.toolBar.playbackRateButton.tintColor = .white
        view.toolBar.playbackRateButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
        view.toolBar.playbackRateButton.accessibilityLabel = "倍速"
        // Keep the persisted selection visible even before the first ready
        // callback rebuilds KSPlayer's native controls.
        view.rebuildPlaybackRateMenu()
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
    }

    private static func normalizedPlaybackRate(from raw: Double) -> Float {
        let value = raw.isFinite && raw > 0 ? Float(raw) : 1.0
        return supportedPlaybackRates.min(by: { abs($0 - value) < abs($1 - value) }) ?? 1.0
    }

    final class Coordinator: NSObject, PlayerControllerDelegate {
        var url: URL?
        var playbackHeaders: [String: String] = [:]
        var preferFFmpegBackend = false
        var playbackSessionToken: UUID?
        var pendingPlaybackReload = false
        var onProgressChanged: ((Double, Double?) -> Void)?
        var onPlaybackEnded: (() -> Void)?
        var onBack: (() -> Void)?
        var onPlayerAction: ((PlayerButtonType) -> Void)?
        var onPlayPrevious: (() -> Void)?
        var onPlayNext: (() -> Void)?
        var onSelectEpisode: (() -> Void)?
        var onMarkIntro: (() -> Void)?
        var onMarkOutro: (() -> Void)?
        var onResetIntro: (() -> Void)?
        var onResetOutro: (() -> Void)?
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
        private let introButton = UIButton(type: .system)
        private let outroButton = UIButton(type: .system)
        private var introLabel = "片头"
        private var outroLabel = "片尾"
        /// Strongly retain the native view across SwiftUI's transient
        /// dismantle/re-make cycle during KSPlayer full-screen transitions.
        /// The view's delegate and callbacks are weak, so this does not form
        /// a retain cycle with the coordinator.
        fileprivate var retainedPlayerView: CongcongKSVideoPlayerView?
        private var playerView: IOSVideoPlayerView?
        private var canPlayPrevious = false
        private var canPlayNext = false
        private var canSelectEpisode = false
        private var isLandscape = false
        private var lastVolume: Float = 0.5
        private var verticalSeekConstraints: [NSLayoutConstraint] = []

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
            onMarkIntro: (() -> Void)?,
            onMarkOutro: (() -> Void)?,
            onResetIntro: (() -> Void)?,
            onResetOutro: (() -> Void)?,
            introLabel: String,
            outroLabel: String,
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
            self.onMarkIntro = onMarkIntro
            self.onMarkOutro = onMarkOutro
            self.onResetIntro = onResetIntro
            self.onResetOutro = onResetOutro
            self.introLabel = introLabel
            self.outroLabel = outroLabel
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
            configureMarkerButton(introButton, title: introLabel, label: "标记片头", action: #selector(markIntroPressed), resetAction: #selector(resetIntroPressed))
            configureMarkerButton(outroButton, title: outroLabel, label: "标记片尾", action: #selector(markOutroPressed), resetAction: #selector(resetOutroPressed))

            verticalSeekStack.axis = .vertical
            verticalSeekStack.alignment = .center
            verticalSeekStack.distribution = .fillEqually
            verticalSeekStack.spacing = 12
            verticalSeekStack.translatesAutoresizingMaskIntoConstraints = false
            verticalSeekStack.addArrangedSubview(verticalRewindButton)
            verticalSeekStack.addArrangedSubview(verticalForwardButton)
            if verticalSeekStack.superview !== view.controllerView {
                NSLayoutConstraint.deactivate(verticalSeekConstraints)
                view.controllerView.addSubview(verticalSeekStack)
                verticalSeekConstraints = [
                    verticalSeekStack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -14),
                    verticalSeekStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                    verticalSeekStack.widthAnchor.constraint(equalToConstant: 46),
                    verticalRewindButton.heightAnchor.constraint(equalToConstant: 42),
                    verticalForwardButton.heightAnchor.constraint(equalToConstant: 42)
                ]
                NSLayoutConstraint.activate(verticalSeekConstraints)
            }

            self.canPlayPrevious = canPlayPrevious
            self.canPlayNext = canPlayNext
            self.canSelectEpisode = canSelectEpisode
            let toolbar = view.toolBar
            let orderedViews: [UIView] = [
                rewindButton,
                toolbar.playButton,
                forwardButton,
                toolbar.timeLabel,
                previousButton,
                nextButton,
                volumeButton,
                toolbar.playbackRateButton,
                episodeButton,
                introButton,
                outroButton,
                view.landscapeButton
            ]
            let currentToolbarViews = toolbar.arrangedSubviews
            let needsToolbarSync = currentToolbarViews.count != orderedViews.count
                || !zip(currentToolbarViews, orderedViews).allSatisfy { pair in
                    pair.0 === pair.1
                }
            if needsToolbarSync {
                for arranged in toolbar.arrangedSubviews {
                    toolbar.removeArrangedSubview(arranged)
                    if !orderedViews.contains(where: { $0 === arranged }) {
                        arranged.removeFromSuperview()
                    }
                }
                for arranged in orderedViews {
                    toolbar.addArrangedSubview(arranged)
                }
            }
            toolbar.spacing = 6
            toolbar.playButton.isEnabled = !isResolvingPlayback
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

        func updateMarkerLabels(intro: String, outro: String) {
            introLabel = intro
            outroLabel = outro
            introButton.setTitle(intro, for: .normal)
            outroButton.setTitle(outro, for: .normal)
        }

        func updateActionButtonsLayout(isLandscape: Bool) {
            self.isLandscape = isLandscape
            // 剧集导航只在横屏显示；横屏固定占位，避免集数变化时控制栏横向跳动。
            previousButton.isHidden = !isLandscape
            nextButton.isHidden = !isLandscape
            previousButton.isEnabled = isLandscape && canPlayPrevious
            nextButton.isEnabled = isLandscape && canPlayNext
            previousButton.alpha = canPlayPrevious ? 1 : 0.45
            nextButton.alpha = canPlayNext ? 1 : 0.45
            episodeButton.isHidden = !isLandscape || !canSelectEpisode
            introButton.isHidden = false
            outroButton.isHidden = false
            rewindButton.isHidden = !isLandscape
            forwardButton.isHidden = !isLandscape
            verticalSeekStack.isHidden = isLandscape
            volumeButton.isHidden = false
            applyControlVisibility()
        }

        func updateControlVisibility(isVisible: Bool) {
            controlsVisible = isVisible
            applyControlVisibility()
        }

        private var controlsVisible = true
        private var isResolvingPlayback = false

        func setPlaybackResolving(_ isResolving: Bool) {
            isResolvingPlayback = isResolving
            playerView?.toolBar.playButton.isEnabled = !isResolving
            // A URL replacement can report paused before autoplay begins.
            // Hide the transient play triangle until this item starts or errors.
            applyControlVisibility()
        }

        private func applyControlVisibility() {
            let alpha: CGFloat = controlsVisible ? 1 : 0
            UIView.animate(withDuration: 0.2) {
                self.verticalSeekStack.alpha = self.controlsVisible && !self.isLandscape ? 1 : 0
                self.playerView?.routeButton.alpha = alpha
                self.playerView?.routeButton.isHidden = !self.controlsVisible
                let canShowPlaybackControl = (self.playerView as? CongcongKSVideoPlayerView)?
                    .canShowPlayerControls == true
                self.playerView?.toolBar.playButton.alpha = self.controlsVisible
                    && !self.isResolvingPlayback
                    && canShowPlaybackControl ? 1 : 0
                self.playerView?.toolBar.playbackRateButton.alpha = alpha
                self.playerView?.toolBar.playbackRateButton.isHidden = !self.controlsVisible
                self.introButton.alpha = alpha
                self.outroButton.alpha = alpha
                self.introButton.isHidden = !self.controlsVisible
                self.outroButton.isHidden = !self.controlsVisible
            }
        }

        private func configureButton(_ button: UIButton, imageName: String, label: String, action: Selector) {
            button.setImage(UIImage(systemName: imageName), for: .normal)
            button.tintColor = .white
            button.accessibilityLabel = label
            button.translatesAutoresizingMaskIntoConstraints = false
            ensureWidthConstraint(button, constant: 30, relation: .equal)
            button.backgroundColor = .clear
            button.layer.backgroundColor = UIColor.clear.cgColor
            button.layer.shadowColor = UIColor.clear.cgColor
            button.layer.shadowOpacity = 0
            button.layer.shadowRadius = 0
            button.layer.shadowOffset = .zero
            button.layer.cornerRadius = 0
            button.clipsToBounds = false
            button.removeTarget(self, action: action, for: .primaryActionTriggered)
            button.addTarget(self, action: action, for: .primaryActionTriggered)
        }

        private func configureMarkerButton(_ button: UIButton, title: String, label: String, action: Selector, resetAction: Selector) {
            button.setTitle(title, for: .normal)
            button.setTitleColor(.white, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
            button.accessibilityLabel = label
            button.accessibilityHint = "轻点设置当前时间，长按清除标记"
            button.translatesAutoresizingMaskIntoConstraints = false
            ensureWidthConstraint(button, constant: 54, relation: .greaterThanOrEqual)
            button.backgroundColor = .clear
            button.layer.backgroundColor = UIColor.clear.cgColor
            button.layer.shadowColor = UIColor.clear.cgColor
            button.layer.shadowOpacity = 0
            button.layer.shadowRadius = 0
            button.layer.shadowOffset = .zero
            button.layer.cornerRadius = 0
            button.clipsToBounds = false
            button.removeTarget(self, action: action, for: .primaryActionTriggered)
            button.addTarget(self, action: action, for: .primaryActionTriggered)
            for gesture in button.gestureRecognizers ?? [] where gesture is UILongPressGestureRecognizer {
                button.removeGestureRecognizer(gesture)
            }
            let longPress = UILongPressGestureRecognizer(target: self, action: resetAction)
            longPress.minimumPressDuration = 0.65
            button.addGestureRecognizer(longPress)
        }

        private func ensureWidthConstraint(
            _ button: UIButton,
            constant: CGFloat,
            relation: NSLayoutConstraint.Relation
        ) {
            let exists = button.constraints.contains {
                ($0.firstItem as? UIView) === button
                    && $0.firstAttribute == .width
                    && $0.relation == relation
                    && abs($0.constant - constant) < 0.01
            }
            guard !exists else { return }
            let constraint = relation == .equal
                ? button.widthAnchor.constraint(equalToConstant: constant)
                : button.widthAnchor.constraint(greaterThanOrEqualToConstant: constant)
            constraint.isActive = true
        }

        @objc private func previousPressed() {
            guard canPlayPrevious else { return }
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
            guard canPlayNext else { return }
            onPlayNext?()
        }

        @objc private func selectEpisodePressed() {
            onSelectEpisode?()
        }

        @objc private func markIntroPressed() {
            onMarkIntro?()
        }

        @objc private func markOutroPressed() {
            onMarkOutro?()
        }

        @objc private func resetIntroPressed(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began else { return }
            onResetIntro?()
        }

        @objc private func resetOutroPressed(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began else { return }
            onResetOutro?()
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
