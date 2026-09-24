import SwiftUI
import AVKit
import AVFoundation

#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if os(iOS)
/// AirPlay 投屏入口按钮（仅系统 AVPlayer 播放器，配合 allowsExternalPlayback 使用）。
struct AirPlayRoutePickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let pickerView = AVRoutePickerView()
        pickerView.tintColor = .white
        pickerView.activeTintColor = UIColor.systemOrange
        return pickerView
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif

/// 跨平台播放器：macOS 使用 AVPlayerView，避免 SwiftUI.VideoPlayer 在 macOS 的崩溃问题
struct PlatformVideoPlayer: View {
    let player: AVPlayer
    var sessionController: SystemPlayerSessionController? = nil
    #if os(iOS)
    var onWillBeginFullScreen: (() -> Void)? = nil
    var onDidEndFullScreen: (() -> Void)? = nil
    #endif
    
    var body: some View {
        #if os(macOS)
        MacOSPlayerView(player: player)
        #else
        AVKitPlayerView(
            player: player,
            sessionController: sessionController,
            onWillBeginFullScreen: onWillBeginFullScreen,
            onDidEndFullScreen: onDidEndFullScreen
        )
        #endif
    }
}

#if os(macOS)
private struct MacOSPlayerView: NSViewRepresentable {
    let player: AVPlayer
    
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.showsFullScreenToggleButton = false
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
    
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
    
    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player = nil
    }
}
#endif

/// 系统播放器会话控制器：用于在页面内联与全屏视图间复用同一 AVPlayer，避免重复拉流
@MainActor
final class SystemPlayerSessionController: ObservableObject {
    fileprivate var player: AVPlayer?
    fileprivate var mediaURLString: String?

    #if os(iOS)
    @Published fileprivate private(set) var isFullScreen = false

    func setFullScreenState(_ value: Bool) {
        isFullScreen = value
    }
    #endif
    
    func setPlayer(_ newPlayer: AVPlayer, urlString: String) {
        if player !== newPlayer {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
        }
        player = newPlayer
        mediaURLString = urlString
    }
    
    func stop() {
        #if os(iOS)
        isFullScreen = false
        #endif
        let stoppingPlayer = player
        player?.pause()
        player = nil
        mediaURLString = nil
        // AVPlayer.replaceCurrentItem(with: nil) 在播放网络流时会同步阻塞主线程数秒。
        // 将其移到后台执行，闭包持有 AVPlayer 强引用防止提前 dealloc。
        if let stoppingPlayer {
            DispatchQueue.global(qos: .utility).async {
                stoppingPlayer.replaceCurrentItem(with: nil)
            }
        }
    }
}

/// 视频播放器组件 - 对应 Android 版 PlayFragment
struct PlayerView: View {
    let urlString: String
    var startPosition: Double = 0
    var onProgressChanged: ((Double, Double?) -> Void)? = nil
    var onPlaybackEnded: (() -> Void)? = nil
    var onToggleFullScreen: (() -> Void)? = nil
    var onBack: (() -> Void)? = nil
    var canPlayPrevious: Bool = false
    var onPlayPrevious: (() -> Void)? = nil
    var canPlayNext: Bool = false
    var onPlayNext: (() -> Void)? = nil
    var canSelectEpisode: Bool = false
    var onSelectEpisode: (() -> Void)? = nil
    var danmakuTitle: String = ""
    var danmakuEpisode: String = ""
    #if os(iOS)
    var onDrawableReady: ((UIView) -> Void)? = nil
    var onFullScreenChanged: ((Bool) -> Void)? = nil
    #endif
    var systemController: SystemPlayerSessionController? = nil
    var vlcController: VLCPlayerController? = nil
    @AppStorage(HawkConfig.PLAY_TYPE_VOD) private var vodPlayTypeRaw = -1
    @AppStorage(HawkConfig.PLAY_TYPE) private var legacyPlayTypeRaw = PlayerEngine.system.rawValue
    
    private var selectedEngine: PlayerEngine {
        let defaults = UserDefaults.standard
        let rawValue: Int
        if defaults.object(forKey: HawkConfig.PLAY_TYPE_VOD) != nil {
            rawValue = vodPlayTypeRaw
        } else if defaults.object(forKey: HawkConfig.PLAY_TYPE) != nil {
            rawValue = legacyPlayTypeRaw
        } else {
            rawValue = PlayerEngine.system.rawValue
        }
        return PlayerEngine.fromStoredValue(rawValue)
    }

    private var activeEngine: PlayerEngine {
        #if os(iOS)
        return .system
        #else
        return selectedEngine
        #endif
    }
    
    var body: some View {
        Group {
            #if os(iOS)
            AVPlayerContentView(
                urlString: urlString,
                startPosition: startPosition,
                onProgressChanged: onProgressChanged,
                onPlaybackEnded: onPlaybackEnded,
                onToggleFullScreen: onToggleFullScreen,
                onBack: onBack,
                canPlayPrevious: canPlayPrevious,
                onPlayPrevious: onPlayPrevious,
                canPlayNext: canPlayNext,
                onPlayNext: onPlayNext,
                canSelectEpisode: canSelectEpisode,
                onSelectEpisode: onSelectEpisode,
                title: danmakuTitle,
                episode: danmakuEpisode,
                sharedController: systemController,
                onFullScreenChanged: onFullScreenChanged
            )
            #else
            switch selectedEngine {
            case .system:
                AVPlayerContentView(
                    urlString: urlString,
                    startPosition: startPosition,
                    onProgressChanged: onProgressChanged,
                    onPlaybackEnded: onPlaybackEnded,
                    onToggleFullScreen: onToggleFullScreen,
                    canPlayNext: canPlayNext,
                    onPlayNext: onPlayNext,
                    sharedController: systemController
                )
            case .vlc:
                VLCVodPlayerView(
                    urlString: urlString,
                    startPosition: startPosition,
                    onProgressChanged: onProgressChanged,
                    onPlaybackEnded: onPlaybackEnded,
                    onToggleFullScreen: onToggleFullScreen,
                    canPlayNext: canPlayNext,
                    onPlayNext: onPlayNext,
                    sharedController: vlcController
                )
            }
            #endif
        }
        .id(activeEngine.rawValue)
        .onAppear {
            if activeEngine != .system {
                systemController?.stop()
            }
            if activeEngine != .vlc {
                vlcController?.stop()
            }
        }
        .onChange(of: activeEngine) { _, newValue in
            if newValue != .system {
                systemController?.stop()
            }
            if newValue != .vlc {
                vlcController?.stop()
            }
        }
    }
}

/// 基于系统 AVPlayer 的点播播放器实现
struct AVPlayerContentView: View {
    private static let supportedPlaybackRates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0]
    let urlString: String
    var startPosition: Double = 0
    var onProgressChanged: ((Double, Double?) -> Void)? = nil
    var onPlaybackEnded: (() -> Void)? = nil
    var onToggleFullScreen: (() -> Void)? = nil
    var onBack: (() -> Void)? = nil
    var canPlayPrevious: Bool = false
    var onPlayPrevious: (() -> Void)? = nil
    var canPlayNext: Bool = false
    var onPlayNext: (() -> Void)? = nil
    var canSelectEpisode: Bool = false
    var onSelectEpisode: (() -> Void)? = nil
    var title: String = ""
    var episode: String = ""
    var sharedController: SystemPlayerSessionController? = nil
    #if os(iOS)
    var onFullScreenChanged: ((Bool) -> Void)? = nil
    @State private var isFullScreen = false
    #endif
    @AppStorage(HawkConfig.PLAY_SPEED) private var savedPlaybackRate = 1.0
    @State private var player: AVPlayer?
    @State private var playbackEndObserver: NSObjectProtocol?
    @State private var timeObserverToken: Any?
    
    // UI 状态
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var volume: Double = 1.0
    @State private var rate: Float = 1.0
    @State private var isPreparing = true
    @State private var playbackError: String?
    @State private var showControls = true
    @State private var controlsTimer: Timer?
    @State private var osdIcon: String?
    @State private var osdOpacity: Double = 0
    @State private var osdTimer: Timer?
    @State private var isDraggingProgress = false
    @State private var draggingSeconds: Double = 0
    @State private var playerObservers: [NSKeyValueObservation] = []
    
    @State private var videoZoomScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            Group {
                if let player = player {
                    #if os(iOS)
                    PlatformVideoPlayer(
                        player: player,
                        sessionController: sharedController,
                        onWillBeginFullScreen: {
                            isFullScreen = true
                            onFullScreenChanged?(true)
                            OrientationLock.landscape()
                        },
                        onDidEndFullScreen: {
                            isFullScreen = false
                            onFullScreenChanged?(false)
                            OrientationLock.portrait()
                        }
                    )
                        .scaleEffect(videoZoomScale)
                    #else
                    PlatformVideoPlayer(
                        player: player,
                        sessionController: sharedController
                    )
                    #endif
                } else {
                    ZStack {
                        Color.black
                        ProgressView()
                            .tint(.white)
                    }
                }
            }
            #if !os(iOS)
            .onTapGesture(count: 2) {
                onToggleFullScreen?()
            }
            .onTapGesture(count: 1) {
                togglePlayPauseWithOSD()
            }
            #endif

            if isPreparing {
                ProgressView()
                    .tint(.white)
            }
            
            if let error = playbackError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.yellow)
                    Text("播放失败")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
                .padding()
            }

            if let osdIcon = osdIcon {
                Image(systemName: osdIcon)
                    .font(.system(size: 60, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(30)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
                    .opacity(osdOpacity)
                    .allowsHitTesting(false)
            }
        }
        #if os(iOS)
        .overlay {
            if player != nil {
                AVPlayerDanmakuOverlayView(
                    title: title,
                    episode: episode,
                    resourceKey: urlString,
                    currentTime: currentTime,
                    duration: duration
                )
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            if !isFullScreen, showControls {
                HStack(spacing: 10) {
                    if let onBack {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.plain)
                    }
                    if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title)
                                .font(.system(size: 15, weight: .semibold))
                                .lineLimit(1)
                            if !episode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(episode)
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.72))
                                    .lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .background(
                    LinearGradient(
                        colors: [.black.opacity(0.72), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
        }
        #endif
        #if os(macOS)
        .overlay(alignment: .bottom) {
            GeometryReader { proxy in
                if player != nil {
                    playbackControls(containerWidth: proxy.size.width)
                        .opacity(showControls ? 1.0 : 0.0)
                        .animation(.easeInOut(duration: 0.3), value: showControls)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        #endif
        .overlay {
            SystemPlayerKeyboardCaptureView(
                onLeft: { seek(by: -seekStep) },
                onRight: { seek(by: seekStep) },
                onTogglePlayPause: { togglePlayPause() },
                onToggleFullScreen: { onToggleFullScreen?() },
                onVolumeDown: { wakeUpControls(); adjustVolume(by: -volumeStep) },
                onVolumeUp: { wakeUpControls(); adjustVolume(by: volumeStep) }
            )
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .allowsHitTesting(false)
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(_): wakeUpControls()
            case .ended: break
            }
        }
        .onAppear {
            syncRateFromSettings()
            setupPlayer()
            wakeUpControls()
        }
        .onChange(of: urlString) { _, _ in
            syncRateFromSettings()
            setupPlayer()
            wakeUpControls()
        }
        .onDisappear {
            cleanupPlayer(keepSharedPlayer: sharedController != nil)
            controlsTimer?.invalidate()
            osdTimer?.invalidate()
        }
    }
    
    /// 配置音频会话为后台播放模式，确保播放器出声并支持 AirPlay 投屏。
    private func configureAudioSessionIfNeeded() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
        #endif
    }

    private func setupPlayer() {
        configureAudioSessionIfNeeded()
        guard let url = Self.sanitizedURL(from: urlString) else {
            print("[AVPlayer] URL sanitization failed for: \(urlString)")
            return
        }
        let targetURLString = url.absoluteString
        let preferredRate = normalizedSavedPlaybackRate
        rate = preferredRate
        playbackError = nil
        
        if let sharedController,
           sharedController.mediaURLString == targetURLString,
           let sharedPlayer = sharedController.player {
            cleanupPlayer(keepSharedPlayer: true)
            sharedPlayer.allowsExternalPlayback = true
            sharedPlayer.usesExternalPlaybackWhileExternalScreenIsActive = true
            player = sharedPlayer
            applyPreferredPlaybackRate(to: sharedPlayer)
            bindPlayerObservers(for: sharedPlayer)
            reportProgress(for: sharedPlayer)
            return
        }
        
        // 清理旧播放器
        cleanupPlayer()
        
        // 使用 AVURLAsset 并设置自定义 HTTP 头，解决部分 CDN 拒绝无 User-Agent 请求的问题
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(nil, queue: nil)
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 0
        let newPlayer = AVPlayer(playerItem: playerItem)
        newPlayer.defaultRate = preferredRate
        newPlayer.allowsExternalPlayback = true
        newPlayer.usesExternalPlaybackWhileExternalScreenIsActive = true
        if let sharedController {
            sharedController.setPlayer(newPlayer, urlString: targetURLString)
        }
        
        player = newPlayer
        bindPlayerObservers(for: newPlayer)
        startPlayback(for: newPlayer)
    }
    
    /// 将原始 URL 字符串转换为合法的 URL，处理未编码的特殊字符。
    private static func sanitizedURL(from urlString: String) -> URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed) {
            return url
        }
        // 尝试对整个字符串进行百分号编码（保留已编码部分）
        if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: encoded) {
            return url
        }
        return nil
    }
    
    private func bindPlayerObservers(for player: AVPlayer) {
        playerObservers = [
            player.observe(\.timeControlStatus, options: [.new]) { p, _ in
                let status = p.timeControlStatus
                DispatchQueue.main.async { isPlaying = status == .playing }
            },
            player.observe(\.reasonForWaitingToPlay, options: [.new]) { p, _ in
                let reason = p.reasonForWaitingToPlay
                DispatchQueue.main.async { isPreparing = reason != nil }
            },
            player.observe(\.volume, options: [.new]) { p, _ in
                let vol = Double(p.volume)
                DispatchQueue.main.async { volume = vol }
            },
            player.observe(\.rate, options: [.new]) { p, _ in
                let currentRate = p.rate
                guard currentRate > 0 else { return }
                let normalized = Self.normalizedPlaybackRate(from: currentRate)
                DispatchQueue.main.async {
                    rate = normalized
                    if abs(savedPlaybackRate - Double(normalized)) > 0.001 {
                        savedPlaybackRate = Double(normalized)
                    }
                }
            }
        ]
        // 监听 AVPlayerItem 状态，捕获加载失败的具体原因
        if let item = player.currentItem {
            let itemObserver = item.observe(\.status, options: [.new]) { observedItem, _ in
                if observedItem.status == .failed {
                    let errorDesc = observedItem.error?.localizedDescription ?? "未知错误"
                    DispatchQueue.main.async {
                        isPreparing = false
                        playbackError = errorDesc
                    }
                } else if observedItem.status == .readyToPlay {
                    DispatchQueue.main.async {
                        playbackError = nil
                    }
                }
            }
            playerObservers.append(itemObserver)
        }
        observePlaybackProgress(for: player)
        observePlaybackEnd(for: player)
        isPlaying = player.timeControlStatus == .playing
        isPreparing = player.reasonForWaitingToPlay != nil
        volume = Double(player.volume)
        rate = normalizedSavedPlaybackRate
    }
    
    private func detachPlayerObservers() {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        if let observer = playbackEndObserver {
            NotificationCenter.default.removeObserver(observer)
            playbackEndObserver = nil
        }
        playerObservers.forEach { $0.invalidate() }
        playerObservers.removeAll()
    }
    
    private func cleanupPlayer(keepSharedPlayer: Bool = false) {
        let currentPlayer = player
        detachPlayerObservers()
        
        guard let currentPlayer else { return }
        if keepSharedPlayer, sharedController?.player === currentPlayer {
            player = nil
            return
        }
        
        currentPlayer.pause()
        if sharedController?.player === currentPlayer {
            sharedController?.player = nil
            sharedController?.mediaURLString = nil
        }
        player = nil
        // replaceCurrentItem(with: nil) 在播放网络流时会阻塞主线程，移到后台
        DispatchQueue.global(qos: .utility).async {
            currentPlayer.replaceCurrentItem(with: nil)
        }
    }
    
    private func startPlayback(for player: AVPlayer) {
        let target = max(startPosition, 0)
        
        if target > 0 {
            let seekTime = CMTime(seconds: target, preferredTimescale: 600)
            player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                reportProgress(for: player)
                playAtPreferredRate(player)
            }
        } else {
            playAtPreferredRate(player)
        }
    }
    
    private func togglePlayPause() {
        guard let player = player else { return }
        if player.rate == 0 {
            playAtPreferredRate(player)
        } else {
            player.pause()
        }
    }
    
    private func togglePlayPauseWithOSD() {
        togglePlayPause()
        showOSD(icon: isPlaying ? "pause.fill" : "play.fill")
    }
    
    private func wakeUpControls() {
        withAnimation { showControls = true }
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            withAnimation(.easeOut(duration: 0.5)) {
                showControls = false
            }
        }
    }
    
    private func showOSD(icon: String) {
        osdIcon = icon
        osdOpacity = 1.0
        osdTimer?.invalidate()
        osdTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
            withAnimation(.easeOut(duration: 0.5)) {
                osdOpacity = 0.0
            }
        }
    }
    
    private func observePlaybackEnd(for player: AVPlayer) {
        guard let item = player.currentItem else { return }
        
        playbackEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            onPlaybackEnded?()
        }
    }
    
    private func observePlaybackProgress(for player: AVPlayer) {
        let interval = CMTime(seconds: 1, preferredTimescale: 2)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { _ in
            reportProgress(for: player)
        }
    }
    
    private func reportProgress(for player: AVPlayer?) {
        guard let player else { return }
        let current = player.currentTime().seconds
        guard current.isFinite, current >= 0 else { return }
        
        if !isDraggingProgress {
            self.currentTime = current
            self.draggingSeconds = current
        }
        
        let rawDuration = player.currentItem?.duration.seconds
        if let rawDuration, rawDuration.isFinite, rawDuration >= 0 {
            self.duration = rawDuration
        }
        onProgressChanged?(current, duration > 0 ? duration : nil)
    }
    
    private var seekStep: Double {
        let saved = UserDefaults.standard.integer(forKey: HawkConfig.PLAY_TIME_STEP)
        return Double(saved > 0 ? saved : 10)
    }

    private var volumeStep: Double { 0.1 }
    
    private var progressUpperBound: Double {
        max(duration, max(currentTime, 1))
    }

    private func playbackControls(containerWidth: CGFloat) -> some View {
        #if os(iOS)
        let controlWidth = containerWidth * 1.0
        #else
        let controlWidth = containerWidth * 0.7
        #endif

        return VStack(spacing: 0) {
            #if os(iOS)
            // iOS: 紧凑单行布局 — 进度条在上，按钮在下紧贴
            // 进度条行
            HStack(spacing: 8) {
                Text(currentTime.durationString)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
                
                Slider(
                    value: Binding(
                        get: { isDraggingProgress ? draggingSeconds : currentTime },
                        set: { 
                            draggingSeconds = $0
                            wakeUpControls()
                        }
                    ),
                    in: 0...progressUpperBound,
                    onEditingChanged: { editing in
                        isDraggingProgress = editing
                        wakeUpControls()
                        if !editing {
                            seek(to: draggingSeconds)
                        }
                    }
                )
                .accentColor(.white)
                .disabled(duration <= 0)
                
                Text(duration.durationString)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
            
            // 控制按钮行 — 紧凑排列
            HStack(spacing: 0) {
                // 左：倍速
                playbackRateMenu
                    .frame(minWidth: 36, alignment: .leading)
                
                Spacer()
                
                // 中间：主控按钮
                HStack(spacing: 20) {
                    Button {
                        wakeUpControls()
                        seek(by: -seekStep)
                        showOSD(icon: "gobackward.\(Int(seekStep))")
                    } label: {
                        Image(systemName: "gobackward.\(Int(seekStep))")
                            .font(.system(size: 16, weight: .medium))
                            .frame(minWidth: 36, minHeight: 36)
                    }
                    .buttonStyle(.plain)
                    
                    Button {
                        wakeUpControls()
                        togglePlayPauseWithOSD()
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 20, weight: .bold))
                            .frame(minWidth: 36, minHeight: 36)
                    }
                    .buttonStyle(.plain)
                    
                    Button {
                        wakeUpControls()
                        seek(by: seekStep)
                        showOSD(icon: "goforward.\(Int(seekStep))")
                    } label: {
                        Image(systemName: "goforward.\(Int(seekStep))")
                            .font(.system(size: 16, weight: .medium))
                            .frame(minWidth: 36, minHeight: 36)
                    }
                    .buttonStyle(.plain)

                    if let onPlayPrevious {
                        Button {
                            guard canPlayPrevious else { return }
                            wakeUpControls()
                            onPlayPrevious()
                            showOSD(icon: "backward.end.fill")
                        } label: {
                            Image(systemName: "backward.end.fill")
                                .font(.system(size: 16, weight: .medium))
                                .frame(minWidth: 36, minHeight: 36)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canPlayPrevious)
                        .opacity(canPlayPrevious ? 1 : 0.4)
                    }

                    if let onPlayNext {
                        Button {
                            guard canPlayNext else { return }
                            wakeUpControls()
                            onPlayNext()
                            showOSD(icon: "forward.end.fill")
                        } label: {
                            Image(systemName: "forward.end.fill")
                                .font(.system(size: 16, weight: .medium))
                                .frame(minWidth: 36, minHeight: 36)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canPlayNext)
                        .opacity(canPlayNext ? 1 : 0.4)
                    }
                }
                
                Spacer()
                
                // 右：投屏 + 全屏
                #if os(iOS)
                if let onSelectEpisode {
                    Button {
                        guard canSelectEpisode else { return }
                        wakeUpControls()
                        onSelectEpisode()
                    } label: {
                        Image(systemName: "list.number")
                            .font(.system(size: 14, weight: .bold))
                            .frame(minWidth: 36, minHeight: 36)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSelectEpisode)
                    .opacity(canSelectEpisode ? 1 : 0.4)
                }
                AirPlayRoutePickerView()
                    .frame(width: 36, height: 36)
                #endif
                if let onToggleFullScreen {
                    Button {
                        wakeUpControls()
                        onToggleFullScreen()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 14, weight: .bold))
                            .frame(minWidth: 36, minHeight: 36)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            #else
            // macOS: 保持两行布局
            HStack(spacing: 12) {
                Text(currentTime.durationString)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)
                    .frame(width: 62, alignment: .leading)
                
                Slider(
                    value: Binding(
                        get: { isDraggingProgress ? draggingSeconds : currentTime },
                        set: { 
                            draggingSeconds = $0
                            wakeUpControls()
                        }
                    ),
                    in: 0...progressUpperBound,
                    onEditingChanged: { editing in
                        isDraggingProgress = editing
                        wakeUpControls()
                        if !editing {
                            seek(to: draggingSeconds)
                        }
                    }
                )
                .accentColor(.white)
                .disabled(duration <= 0)
                
                Text(duration.durationString)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
                    .frame(width: 62, alignment: .trailing)
            }
            .padding(.horizontal, 4)
            
            HStack(spacing: 0) {
                HStack(spacing: 16) {
                    playbackRateMenu
                }
                .frame(width: 150, alignment: .leading)
                
                Spacer()
                
                HStack(spacing: 24) {
                    Button {
                        wakeUpControls()
                        seek(by: -seekStep)
                        showOSD(icon: "gobackward.\(Int(seekStep))")
                    } label: {
                        Image(systemName: "gobackward.\(Int(seekStep))")
                            .font(.system(size: 18, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    
                    Button {
                        wakeUpControls()
                        togglePlayPauseWithOSD()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.15))
                                .frame(width: 38, height: 38)
                            
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 18, weight: .bold))
                        }
                    }
                    .buttonStyle(.plain)
                    
                    Button {
                        wakeUpControls()
                        seek(by: seekStep)
                        showOSD(icon: "goforward.\(Int(seekStep))")
                    } label: {
                        Image(systemName: "goforward.\(Int(seekStep))")
                            .font(.system(size: 18, weight: .medium))
                    }
                    .buttonStyle(.plain)

                    if let onPlayNext {
                        Button {
                            guard canPlayNext else { return }
                            wakeUpControls()
                            onPlayNext()
                            showOSD(icon: "forward.end.fill")
                        } label: {
                            Image(systemName: "forward.end.fill")
                                .font(.system(size: 18, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canPlayNext)
                        .opacity(canPlayNext ? 1 : 0.4)
                    }
                }
                
                Spacer()
                
                HStack(spacing: 14) {
                    HStack(spacing: 6) {
                        Button {
                            wakeUpControls()
                            let newVolume = volume > 0 ? 0.0 : 1.0
                            player?.volume = Float(newVolume)
                            showOSD(icon: newVolume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        } label: {
                            Image(systemName: volumeIconName)
                                .font(.system(size: 14, weight: .bold))
                                .frame(width: 20)
                        }
                        .buttonStyle(.plain)

                        Slider(
                            value: Binding(
                                get: { volume },
                                set: {
                                    player?.volume = Float($0)
                                    wakeUpControls()
                                }
                            ),
                            in: 0...1.0
                        )
                        .accentColor(.white.opacity(0.8))
                        .frame(width: 80)
                    }
                    
                    if let onToggleFullScreen {
                        Button {
                            wakeUpControls()
                            onToggleFullScreen()
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 15, weight: .bold))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 150, alignment: .trailing)
            }
            .padding(.top, 8)
            #endif
        }
        #if os(iOS)
        .padding(.vertical, 2)
        .foregroundColor(.white)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .padding(.bottom, 0)
        .frame(width: controlWidth)
        #else
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .foregroundColor(.white)
        .glassCard(cornerRadius: 18)
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
        .frame(width: controlWidth)
        #endif
        .environment(\.colorScheme, .dark)
    }

    private var playbackRateMenu: some View {
        Menu {
            ForEach(Self.supportedPlaybackRates, id: \.self) { r in
                Button {
                    wakeUpControls()
                    setPlaybackRate(r)
                    showOSD(icon: "speedometer")
                } label: {
                    HStack {
                        Text("\(String(format: "%.1f", r))x")
                        if r == rate {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("\(String(format: "%.1f", rate))x")
                Image(systemName: "chevron.up")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.12))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var volumeIconName: String {
        if volume <= 0 { return "speaker.slash.fill" }
        if volume < 0.5 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }

    private var normalizedSavedPlaybackRate: Float {
        Self.normalizedPlaybackRate(from: Float(savedPlaybackRate))
    }

    private static func normalizedPlaybackRate(from raw: Float) -> Float {
        guard !supportedPlaybackRates.isEmpty else { return 1.0 }
        return supportedPlaybackRates.min(by: { abs($0 - raw) < abs($1 - raw) }) ?? 1.0
    }

    private func syncRateFromSettings() {
        rate = normalizedSavedPlaybackRate
    }

    private func setPlaybackRate(_ value: Float) {
        let normalized = Self.normalizedPlaybackRate(from: value)
        rate = normalized
        savedPlaybackRate = Double(normalized)
        guard let player else { return }
        player.defaultRate = normalized
        if player.rate > 0 {
            player.rate = normalized
        }
    }

    private func applyPreferredPlaybackRate(to player: AVPlayer) {
        let normalized = normalizedSavedPlaybackRate
        rate = normalized
        player.defaultRate = normalized
        if player.rate > 0 {
            player.rate = normalized
        }
    }

    private func playAtPreferredRate(_ player: AVPlayer) {
        let normalized = normalizedSavedPlaybackRate
        rate = normalized
        player.defaultRate = normalized
        player.playImmediately(atRate: normalized)
    }

    private func seek(to seconds: Double) {
        guard let player = player else { return }
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    
    private func seek(by offset: Double) {
        guard let player else { return }
        
        let current = player.currentTime().seconds
        guard current.isFinite else { return }
        let wasPlaying = player.rate != 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        
        var target = max(current + offset, 0)
        if let duration = player.currentItem?.duration.seconds, duration.isFinite {
            target = min(target, duration)
        }
        
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { _ in
            reportProgress(for: player)
            if wasPlaying {
                playAtPreferredRate(player)
            }
        }
    }

    private func adjustVolume(by delta: Double) {
        guard let player else { return }
        let current = Double(player.volume)
        let target = min(max(current + delta, 0), 1)
        player.volume = Float(target)
        showOSD(icon: target <= 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
    }
}

#if os(iOS)
/// Bridges AVPlayer's clock to the shared UIKit danmaku renderer.
///
/// The representable owns only the overlay and its loading task. Media playback
/// remains owned by AVPlayerContentView, so a danmaku request can never block or
/// replace the player when a feed is unavailable.
private struct AVPlayerDanmakuOverlayView: UIViewRepresentable {
    let title: String
    let episode: String
    let resourceKey: String
    let currentTime: Double
    let duration: Double

    final class Coordinator {
        weak var overlay: DanmakuOverlayView?
        var loadedKey = ""
        var loadTask: Task<Void, Never>?

        deinit {
            loadTask?.cancel()
        }

        func update(
            title: String,
            episode: String,
            resourceKey: String,
            currentTime: Double,
            duration: Double
        ) {
            let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedEpisode = episode.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = "\(resourceKey)|\(normalizedTitle)|\(normalizedEpisode)"

            if key != loadedKey {
                loadedKey = key
                load(title: normalizedTitle, episode: normalizedEpisode, resourceKey: key)
            }

            overlay?.update(
                currentTime: max(0, currentTime.isFinite ? currentTime : 0),
                duration: max(0, duration.isFinite ? duration : 0)
            )
        }

        private func load(title: String, episode: String, resourceKey: String) {
            loadTask?.cancel()
            overlay?.clear()

            guard !title.isEmpty else { return }
            let targetOverlay = overlay
            loadTask = Task { [weak self, weak targetOverlay] in
                let cues = await DanmuService.shared.loadCues(title: title, episode: episode)
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard let self,
                          self.loadedKey == resourceKey,
                          let targetOverlay,
                          self.overlay === targetOverlay else { return }
                    targetOverlay.setCues(cues)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let host = UIView(frame: .zero)
        host.backgroundColor = .clear
        host.isUserInteractionEnabled = false

        let overlay = DanmakuOverlayView(frame: .zero)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: host.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])

        context.coordinator.overlay = overlay
        context.coordinator.update(
            title: title,
            episode: episode,
            resourceKey: resourceKey,
            currentTime: currentTime,
            duration: duration
        )
        return host
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.update(
            title: title,
            episode: episode,
            resourceKey: resourceKey,
            currentTime: currentTime,
            duration: duration
        )
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.loadTask?.cancel()
        coordinator.loadTask = nil
        coordinator.overlay?.clear()
        coordinator.overlay = nil
    }
}
#endif

#if os(macOS)
private struct SystemPlayerKeyboardCaptureView: NSViewRepresentable {
    let onLeft: () -> Void
    let onRight: () -> Void
    let onTogglePlayPause: () -> Void
    let onToggleFullScreen: () -> Void
    let onVolumeDown: () -> Void
    let onVolumeUp: () -> Void
    
    func makeNSView(context: Context) -> SystemPlayerKeyCaptureNSView {
        let view = SystemPlayerKeyCaptureNSView(frame: .zero)
        applyCallbacks(to: view)
        DispatchQueue.main.async {
            view.activate()
        }
        return view
    }
    
    func updateNSView(_ nsView: SystemPlayerKeyCaptureNSView, context: Context) {
        applyCallbacks(to: nsView)
        DispatchQueue.main.async {
            nsView.activate()
        }
    }
    
    private func applyCallbacks(to view: SystemPlayerKeyCaptureNSView) {
        view.onLeft = onLeft
        view.onRight = onRight
        view.onTogglePlayPause = onTogglePlayPause
        view.onToggleFullScreen = onToggleFullScreen
        view.onVolumeDown = onVolumeDown
        view.onVolumeUp = onVolumeUp
    }
}

private final class SystemPlayerKeyCaptureNSView: NSView {
    var onLeft: (() -> Void)?
    var onRight: (() -> Void)?
    var onTogglePlayPause: (() -> Void)?
    var onToggleFullScreen: (() -> Void)?
    var onVolumeDown: (() -> Void)?
    var onVolumeUp: (() -> Void)?
    
    override var acceptsFirstResponder: Bool { true }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        activate()
    }
    
    func activate() {
        window?.makeFirstResponder(self)
    }
    
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty == false {
            super.keyDown(with: event)
            return
        }
        
        switch event.keyCode {
        case 123: // left
            onLeft?()
            return
        case 124: // right
            onRight?()
            return
        case 125: // down
            onVolumeDown?()
            return
        case 126: // up
            onVolumeUp?()
            return
        case 49: // space
            onTogglePlayPause?()
            return
        default: break
        }
        
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch key {
        case "k": onTogglePlayPause?()
        case "f": onToggleFullScreen?()
        default: super.keyDown(with: event)
        }
    }
}
#else
private struct SystemPlayerKeyboardCaptureView: UIViewRepresentable {
    let onLeft: () -> Void
    let onRight: () -> Void
    let onTogglePlayPause: () -> Void
    let onToggleFullScreen: () -> Void
    let onVolumeDown: () -> Void
    let onVolumeUp: () -> Void
    
    func makeUIView(context: Context) -> SystemPlayerKeyCaptureUIView {
        let view = SystemPlayerKeyCaptureUIView(frame: .zero)
        applyCallbacks(to: view)
        DispatchQueue.main.async {
            view.activate()
        }
        return view
    }
    
    func updateUIView(_ uiView: SystemPlayerKeyCaptureUIView, context: Context) {
        applyCallbacks(to: uiView)
        DispatchQueue.main.async {
            uiView.activate()
        }
    }
    
    private func applyCallbacks(to view: SystemPlayerKeyCaptureUIView) {
        view.onLeft = onLeft
        view.onRight = onRight
        view.onTogglePlayPause = onTogglePlayPause
        view.onToggleFullScreen = onToggleFullScreen
        view.onVolumeDown = onVolumeDown
        view.onVolumeUp = onVolumeUp
    }
}

private final class SystemPlayerKeyCaptureUIView: UIView {
    var onLeft: (() -> Void)?
    var onRight: (() -> Void)?
    var onTogglePlayPause: (() -> Void)?
    var onToggleFullScreen: (() -> Void)?
    var onVolumeDown: (() -> Void)?
    var onVolumeUp: (() -> Void)?
    
    override var canBecomeFirstResponder: Bool { true }
    
    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(handleLeft)),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(handleRight)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(handleVolumeDown)),
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(handleVolumeUp)),
            UIKeyCommand(input: " ", modifierFlags: [], action: #selector(handleTogglePlayPause)),
            UIKeyCommand(input: "k", modifierFlags: [], action: #selector(handleTogglePlayPause)),
            UIKeyCommand(input: "f", modifierFlags: [], action: #selector(handleToggleFullScreen))
        ]
    }
    
    override func didMoveToWindow() {
        super.didMoveToWindow()
        activate()
    }
    
    func activate() {
        becomeFirstResponder()
    }
    
    @objc private func handleLeft() { onLeft?() }
    @objc private func handleRight() { onRight?() }
    @objc private func handleVolumeDown() { onVolumeDown?() }
    @objc private func handleVolumeUp() { onVolumeUp?() }
    @objc private func handleTogglePlayPause() { onTogglePlayPause?() }
    @objc private func handleToggleFullScreen() { onToggleFullScreen?() }
}
#endif
