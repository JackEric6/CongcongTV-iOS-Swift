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
    private let deviceStatusView = UIView()
    private let deviceTimeLabel = UILabel()
    private let deviceBatteryIconView = UIImageView()
    private let deviceBatteryLabel = UILabel()
    private var deviceStatusTimer: Timer?
    var customControlsLayout: ((Bool) -> Void)?
    private var isSliderDragging = false
    private var sliderSeekCommitted = false
    private var panStartPoint: CGPoint?
    private var nativePanDirection: KSPanDirection?
    private var pendingSeekTarget: TimeInterval?
    private var seekRequestID = 0

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

    override func didMoveToWindow() {
        super.didMoveToWindow()
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
        super.player(layer: layer, state: state)
        guard state == .readyToPlay else { return }

        if !didApplyStartPosition,
           pendingStartPosition > 0,
           pendingStartPosition.isFinite {
            didApplyStartPosition = true
            let target = pendingStartPosition
            playerLayer?.seek(time: target, autoPlay: true) { [weak self] success in
                if !success {
                    // 某些流在第一次 ready 回调时仍不可 seek，允许下一次 ready 重试。
                    self?.didApplyStartPosition = false
                }
            }
        }

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
    func stopCurrentPlayback() {
        // SwiftUI dismantleUIView 可能先于 DetailView.onDisappear 触发；
        // 先把播放器最后的有效位置回传，避免页面退出时丢掉尾部进度。
        if let player = playerLayer?.player {
            let current = player.currentPlaybackTime
            let duration = player.duration
            if current.isFinite, current > 0 {
                playTimeDidChange?(current, duration.isFinite && duration > 0 ? duration : 0)
            }
        }
        playerLayer?.delegate = nil
        playerLayer?.stop()
        playerLayer = nil
        playTimeDidChange = nil
        pendingStartPosition = 0
        didApplyStartPosition = false
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
        guard gestureRecognizer === panGesture else { return true }
        panStartPoint = touch.location(in: self)
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
        // KSPlayer's native full-screen controller temporarily reparents this
        // view. SwiftUI may ask the representable for its view again while
        // that transition is still in flight; reuse the retained instance so
        // the AVPlayer session is not torn down and recreated.
        if let retainedView = context.coordinator.retainedPlayerView {
            context.coordinator.configure(retainedView)
            return retainedView
        }

        let view = CongcongKSVideoPlayerView()
        context.coordinator.retainedPlayerView = view
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
        if let previousURL = coordinator.url, previousURL != url {
            view.stopCurrentPlayback()
        }
        coordinator.url = url
        view.pendingStartPosition = max(0, startPosition)
        view.didApplyStartPosition = false
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
        /// Strongly retain the native view across SwiftUI's transient
        /// dismantle/re-make cycle during KSPlayer full-screen transitions.
        /// The view's delegate and callbacks are weak, so this does not form
        /// a retain cycle with the coordinator.
        private var retainedPlayerView: CongcongKSVideoPlayerView?
        private var playerView: IOSVideoPlayerView?
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
                verticalSeekStack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -14),
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
                rewindButton,
                toolbar.playButton,
                forwardButton,
                toolbar.timeLabel,
                previousButton,
                nextButton,
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
            // 剧集导航只在横屏显示；横屏固定占位，避免集数变化时控制栏横向跳动。
            previousButton.isHidden = !isLandscape
            nextButton.isHidden = !isLandscape
            previousButton.isEnabled = isLandscape && canPlayPrevious
            nextButton.isEnabled = isLandscape && canPlayNext
            previousButton.alpha = canPlayPrevious ? 1 : 0.45
            nextButton.alpha = canPlayNext ? 1 : 0.45
            episodeButton.isHidden = !isLandscape || !canSelectEpisode
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

        private func applyControlVisibility() {
            let alpha: CGFloat = controlsVisible ? 1 : 0
            UIView.animate(withDuration: 0.2) {
                self.verticalSeekStack.alpha = self.controlsVisible && !self.isLandscape ? 1 : 0
                self.playerView?.routeButton.alpha = alpha
                self.playerView?.routeButton.isHidden = !self.controlsVisible
                self.playerView?.toolBar.playbackRateButton.alpha = alpha
                self.playerView?.toolBar.playbackRateButton.isHidden = !self.controlsVisible
            }
        }

        private func configureButton(_ button: UIButton, imageName: String, label: String, action: Selector) {
            button.setImage(UIImage(systemName: imageName), for: .normal)
            button.tintColor = .white
            button.accessibilityLabel = label
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 30).isActive = true
            button.backgroundColor = .clear
            button.layer.backgroundColor = UIColor.clear.cgColor
            button.layer.shadowColor = UIColor.clear.cgColor
            button.layer.shadowOpacity = 0
            button.layer.shadowRadius = 0
            button.layer.shadowOffset = .zero
            button.layer.cornerRadius = 0
            button.clipsToBounds = false
            button.addTarget(self, action: action, for: .primaryActionTriggered)
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
