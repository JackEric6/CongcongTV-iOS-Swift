import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// 详情页 - 对应 Android 版 DetailActivity
struct DetailView: View {
    let video: Movie.Video
    @StateObject private var viewModel = DetailViewModel()
    @StateObject private var sharedSystemController = SystemPlayerSessionController()
    @StateObject private var sharedVLCController = VLCPlayerController()
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var showFullScreen = false
    #if os(macOS)
    @State private var pendingMacWindowFullScreen = false
    #endif
    @State private var lastPersistedProgress: Double = 0
    @State private var playbackSessionToken = UUID()
    @State private var isCollected = false
    @State private var showEpisodePicker = false
    #if os(iOS)
    @State private var isDescriptionExpanded = false
    #endif
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // 播放器区域
                if shouldShowInlinePlayer, viewModel.isPlaying, let url = viewModel.playUrl {
                    // 播放器会话由共享控制器持有；AVKit 全屏时复用同一个控制器。
                    ZStack {
                        Color.black
                        PlayerView(
                            urlString: url,
                            startPosition: viewModel.currentPlaybackSeconds(),
                            onProgressChanged: { [playbackSessionToken] seconds, _ in
                                handlePlaybackProgress(seconds, sessionToken: playbackSessionToken)
                            },
                            onPlaybackEnded: playNextEpisodeIfNeeded,
                            onToggleFullScreen: inlineFullScreenHandler,
                            onBack: { dismiss() },
                            canPlayPrevious: viewModel.selectedEpisodeIndex > 0,
                            onPlayPrevious: playPreviousEpisode,
                            canPlayNext: canPlayNextEpisode,
                            onPlayNext: playNextEpisodeIfNeeded,
                            canSelectEpisode: viewModel.currentEpisodes.count > 1,
                            onSelectEpisode: handlePlayerEpisodeSelection,
                            danmakuTitle: viewModel.vodInfo?.name ?? video.name,
                            danmakuEpisode: currentDanmakuEpisode,
                            onFullScreenChanged: { showFullScreen = $0 },
                            systemController: sharedSystemController,
                            vlcController: sharedVLCController
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipped()
                }
                
                // 视频信息
                videoInfoSection
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                
                // 线路选择
                if viewModel.flags.count > 1 {
                    flagSelector
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                }
                
                // 清晰度选择
                if viewModel.hasQualityChoices {
                    qualitySelector
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                }
                
                // 剧集列表
                if !viewModel.currentEpisodes.isEmpty {
                    episodeSection
                        .padding(.top, 10)
                }
            }
            .padding(.bottom, 40)
        }
        .background(AppTheme.primaryGradient)
        #if os(iOS)
        // 标题只在 16:9 播放器下方显示，避免从导航栏向内容区跳动的中间态。
        .navigationTitle("")
        #else
        .navigationTitle(video.name)
        #endif
        #if os(macOS)
        .toolbar((showFullScreen || pendingMacWindowFullScreen) ? .hidden : .visible, for: .windowToolbar)
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showEpisodePicker) {
            EpisodePickerSheet(
                episodes: viewModel.currentEpisodes,
                selectedIndex: viewModel.selectedEpisodeIndex,
                onSelect: { index in
                    showEpisodePicker = false
                    beginPlaybackSession()
                    withAnimation {
                        viewModel.selectEpisode(index: index)
                    }
                    saveHistoryForCurrentEpisode()
                }
            )
        }
        .task(id: "\(video.sourceKey)-\(video.id)") {
            await viewModel.loadDetail(video: video)
            restorePlaybackFromHistory()
            // 海报点击后默认直接进入播放：先按历史续播，无历史则自动选中第一集播放，
            // 用户无需再额外点击“立即播放”。
            if !viewModel.isPlaying {
                beginPlaybackSession()
                viewModel.selectEpisode(index: 0)
                saveHistoryForCurrentEpisode()
            }
            refreshCollectState()
        }
        .onDisappear {
            viewModel.commitPlaybackProgressSnapshot()
            persistHistoryIfNeeded(force: true)
            #if os(macOS)
            showFullScreen = false
            #endif
            if !showFullScreen {
                sharedSystemController.stop()
                sharedVLCController.stop()
            }
            #if os(macOS)
            pendingMacWindowFullScreen = false
            appState.exitPlayerFullScreen()
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            viewModel.commitPlaybackProgressSnapshot()
            persistHistoryIfNeeded(force: true)
        }
        #if os(macOS)
        .overlay {
            if showFullScreen, let url = viewModel.playUrl {
                FullScreenPlayerView(
                    urlString: url,
                    startPosition: viewModel.currentPlaybackSeconds(),
                    onProgressChanged: { [playbackSessionToken] seconds, _ in
                        handlePlaybackProgress(seconds, sessionToken: playbackSessionToken)
                    },
                    onPlaybackEnded: playNextEpisodeIfNeeded,
                    canPlayNext: canPlayNextEpisode,
                    onPlayNext: playNextEpisodeIfNeeded,
                    danmakuTitle: viewModel.vodInfo?.name ?? video.name,
                    danmakuEpisode: currentDanmakuEpisode,
                    systemController: sharedSystemController,
                    vlcController: sharedVLCController,
                    onCloseRequested: closeMacFullScreenOverlay
                )
                .ignoresSafeArea()
                .transition(.opacity)
                .zIndex(2)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            guard pendingMacWindowFullScreen else { return }
            pendingMacWindowFullScreen = false
            showFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            pendingMacWindowFullScreen = false
            if showFullScreen {
                showFullScreen = false
            }
            appState.exitPlayerFullScreen()
        }
        #endif
    }

    private var shouldShowInlinePlayer: Bool {
        #if os(macOS)
        return !showFullScreen
        #else
        // iOS 的 KSPlayer 原生全屏控制器自己负责进入/退出全屏；
        // 详情页始终保留唯一的播放器实例，避免重建第二个控制器。
        return true
        #endif
    }

    private var inlineFullScreenHandler: (() -> Void)? {
        #if os(macOS)
        return { openFullScreenPlayer() }
        #else
        // iOS 使用 KSPlayer 原生全屏按钮和退出手势。
        return nil
        #endif
    }

    private func handlePlayerEpisodeSelection() {
        #if os(iOS)
        // KSPlayer 全屏时播放器 UIView 会被移到它自己的全屏控制器；
        // 从顶层控制器呈现选集，避免底层 SwiftUI sheet 抢占当前转场。
        if let top = topViewController(), top.presentingViewController != nil {
            presentFullscreenEpisodePicker(from: top)
        } else {
            showEpisodePicker = true
        }
        #else
        showEpisodePicker = true
        #endif
    }

    #if os(iOS)
    private func topViewController(from root: UIViewController? = nil) -> UIViewController? {
        let root = root ?? UIApplication.shared.connectedScenes
            .compactMap { scene in
                (scene as? UIWindowScene)?.windows.first(where: { $0.isKeyWindow })
            }
            .first?.rootViewController
        if let presented = root?.presentedViewController {
            return topViewController(from: presented)
        }
        if let navigation = root as? UINavigationController {
            return topViewController(from: navigation.visibleViewController)
        }
        if let tab = root as? UITabBarController {
            return topViewController(from: tab.selectedViewController)
        }
        return root
    }

    private func presentFullscreenEpisodePicker(from presenter: UIViewController) {
        guard viewModel.currentEpisodes.count > 1 else { return }
        let picker = FullscreenEpisodePickerView(
            episodes: viewModel.currentEpisodes,
            selectedIndex: viewModel.selectedEpisodeIndex,
            onDismiss: { [weak presenter] in
                presenter?.dismiss(animated: true)
            },
            onSelect: { [weak presenter] index in
                presenter?.dismiss(animated: true) {
                    beginPlaybackSession()
                    withAnimation {
                        viewModel.selectEpisode(index: index)
                    }
                    saveHistoryForCurrentEpisode()
                }
            }
        )
        let hostingController = UIHostingController(rootView: picker)
        hostingController.modalPresentationStyle = .overFullScreen
        hostingController.modalTransitionStyle = .crossDissolve
        hostingController.view.backgroundColor = .clear
        presenter.present(hostingController, animated: true)
    }
    #endif
    
    // MARK: - 视频信息
    
    #if os(iOS)
    @ViewBuilder
    private var videoInfoSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                videoDetails
                Spacer(minLength: 0)
                if !viewModel.isPlaying {
                    playButton
                }
                collectButton
            }

            if let info = viewModel.vodInfo, !info.des.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                descriptionSection(info.des)
            }
        }
        .padding(12)
        .glassCard(cornerRadius: AppTheme.glassRadius)
    }
    #else
    @ViewBuilder
    private var videoInfoSection: some View {
        HStack(alignment: .top, spacing: 20) {
            videoPoster
            
            videoDetails
            
            Spacer()
        }
        .padding(15)
        .glassCard(cornerRadius: AppTheme.glassRadius)
    }
    #endif

    @ViewBuilder
    private var videoPoster: some View {
        CachedAsyncImage(url: URL.posterURL(from: video.pic)) { image in
            image.resizable().aspectRatio(2/3, contentMode: .fill)
        } placeholder: {
            ZStack {
                Color.white.opacity(0.05)
                Image(systemName: "film.fill").foregroundColor(.white.opacity(0.2))
            }
            .aspectRatio(2/3, contentMode: .fill)
        }
        .frame(width: 130)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardRadius))
        .shadow(color: .black.opacity(0.5), radius: 10, x: 0, y: 5)
    }

    @ViewBuilder
    private var videoDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(video.name)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(2)

            if !video.formattedDoubanRating.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "star.fill")
                        .foregroundColor(.yellow)
                    Text(video.formattedDoubanRating)
                        .foregroundColor(.yellow)
                }
                .font(.system(size: 14, weight: .semibold))
            }
            
            if let info = viewModel.vodInfo {
                VStack(alignment: .leading, spacing: 3) {
                    infoRow("年份", info.year)
                    infoRow("地区", info.area)
                    infoRow("类型", info.typeName)
                    infoRow("导演", info.director)
                    infoRow("演员", info.actor)
                }
            }
            
            #if os(macOS)
            Spacer(minLength: 10)
            
            HStack(spacing: 10) {
                playButton
                collectButton
            }
            #endif
        }
    }

    @ViewBuilder
    private var playButton: some View {
        if !viewModel.isPlaying && viewModel.vodInfo != nil {
            Button {
                beginPlaybackSession()
                viewModel.selectEpisode(index: 0)
                saveHistoryForCurrentEpisode()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                    Text("立即播放")
                }
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(AppTheme.accentGradient)
                .clipShape(Capsule())
                .shadow(color: .red.opacity(0.4), radius: 10, x: 0, y: 5)
            }
            .buttonStyle(.plain)
        }
    }
    
    private var collectButton: some View {
        Button {
            toggleCollect()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isCollected ? "heart.fill" : "heart")
                Text(isCollected ? "已收藏" : "收藏")
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                Group {
                    if isCollected {
                        AppTheme.accentGradient
                    } else {
                        Color.white.opacity(0.08)
                    }
                }
            )
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(isCollected ? 0 : 0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
    
    @ViewBuilder
    private func infoRow(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            HStack(alignment: .top, spacing: 4) {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.gray)
                    .frame(width: 36, alignment: .leading)
                Text(value)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(2)
            }
        }
    }
    
    // MARK: - 线路选择
    
    @ViewBuilder
    private var flagSelector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("播放线路")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
            
            flagScrollView
        }
        .padding(15)
        .glassCard(cornerRadius: AppTheme.glassRadius)
    }

    @ViewBuilder
    private var flagScrollView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(viewModel.flags, id: \.self) { flag in
                    flagButton(flag)
                }
            }
        }
    }

    @ViewBuilder
    private func flagButton(_ flag: String) -> some View {
        Button {
            beginPlaybackSession()
            withAnimation {
                viewModel.selectFlag(flag)
            }
            if viewModel.isPlaying {
                saveHistoryForCurrentEpisode()
            }
        } label: {
            Text(flag)
                .font(.system(size: 14, weight: viewModel.selectedFlag == flag ? .bold : .medium))
                .foregroundColor(viewModel.selectedFlag == flag ? .white : .white.opacity(0.6))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    ZStack {
                        if viewModel.selectedFlag == flag {
                            AppTheme.accentGradient
                        } else {
                            Color.white.opacity(0.05)
                        }
                    }
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - 清晰度选择
    
    @ViewBuilder
    private var qualitySelector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("视频清晰度")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(viewModel.qualityOptions) { option in
                        qualityButton(option)
                    }
                }
            }
        }
        .padding(15)
        .glassCard(cornerRadius: AppTheme.glassRadius)
    }
    
    @ViewBuilder
    private func qualityButton(_ option: PlaybackQualityOption) -> some View {
        Button {
            beginPlaybackSession()
            withAnimation {
                viewModel.selectQuality(option)
            }
            if viewModel.isPlaying {
                saveHistoryForCurrentEpisode()
            }
        } label: {
            Text(option.name)
                .font(.system(size: 14, weight: viewModel.selectedQualityId == option.id ? .bold : .medium))
                .foregroundColor(viewModel.selectedQualityId == option.id ? .white : .white.opacity(0.6))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    ZStack {
                        if viewModel.selectedQualityId == option.id {
                            AppTheme.accentGradient
                        } else {
                            Color.white.opacity(0.05)
                        }
                    }
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - 剧集列表
    
    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选集播放")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
            
            EpisodeListView(
                episodes: viewModel.currentEpisodes,
                selectedIndex: viewModel.selectedEpisodeIndex,
                onSelect: { index in
                    beginPlaybackSession()
                    withAnimation {
                        viewModel.selectEpisode(index: index)
                    }
                    saveHistoryForCurrentEpisode()
                }
            )
        }
    }
    
    // MARK: - 简介
    
    private func descriptionSection(_ des: String) -> some View {
        let cleanedDescription = normalizedDescription(des)

        return VStack(alignment: .leading, spacing: 12) {
            Button {
                #if os(iOS)
                withAnimation(.easeInOut(duration: 0.2)) {
                    isDescriptionExpanded.toggle()
                }
                #endif
            } label: {
                HStack {
                    Text("影片简介")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    #if os(iOS)
                    Image(systemName: isDescriptionExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white.opacity(0.65))
                    #endif
                }
            }
            .buttonStyle(.plain)

            Text(cleanedDescription)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.68))
                .lineSpacing(3)
                #if os(iOS)
                .lineLimit(isDescriptionExpanded ? nil : 2)
                #else
                .lineLimit(nil)
                #endif
        }
        .padding(.top, 2)
    }

    /// 清理资源站简介中的 HTML 空白实体和不可见空白，避免界面出现 "nbsp" 前缀。
    private func normalizedDescription(_ value: String) -> String {
        let decoded = value
            .replacingOccurrences(of: "&nbsp;", with: " ", options: .caseInsensitive)
            .replacingOccurrences(of: "&#160;", with: " ", options: .caseInsensitive)
            .replacingOccurrences(of: "\\u00a0", with: " ", options: .caseInsensitive)
            .replacingOccurrences(of: "nbsp", with: " ", options: .caseInsensitive)

        return decoded
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private var canPlayNextEpisode: Bool {
        viewModel.selectedEpisodeIndex + 1 < viewModel.currentEpisodes.count
    }

    private var currentDanmakuEpisode: String {
        guard viewModel.selectedEpisodeIndex >= 0,
              viewModel.selectedEpisodeIndex < viewModel.currentEpisodes.count else {
            return "第\(viewModel.selectedEpisodeIndex + 1)集"
        }
        let name = viewModel.currentEpisodes[viewModel.selectedEpisodeIndex].name
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "第\(viewModel.selectedEpisodeIndex + 1)集" : name
    }
    
    private func saveHistoryForCurrentEpisode(progressOverride: Double? = nil) {
        let episodeName = viewModel.vodInfo?.currentEpisode?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let episodeLabel = episodeName.isEmpty ? "第\(viewModel.selectedEpisodeIndex + 1)集" : episodeName
        let progress = max(progressOverride ?? viewModel.currentPlaybackSeconds(), 0)
        let timeLabel = progress > 0 ? Int(progress).durationString : ""
        let playNote = timeLabel.isEmpty ? episodeLabel : "\(episodeLabel) \(timeLabel)"
        
        let playbackState = VodPlaybackState(
            flag: viewModel.selectedFlag,
            episodeIndex: viewModel.selectedEpisodeIndex,
            progressSeconds: progress
        )
        
        // CacheStore 的写入方法本身运行在 MainActor，同步写入可避免异步任务乱序覆盖最新进度。
        CacheStore.shared.addRecord(
            video,
            playNote: playNote,
            playbackState: playbackState,
            context: modelContext
        )
    }
    
    private func handlePlaybackProgress(_ seconds: Double, sessionToken: UUID? = nil) {
        if let sessionToken, sessionToken != playbackSessionToken {
            return
        }
        viewModel.updatePlaybackProgress(seconds: seconds)
        persistHistoryIfNeeded(force: false, currentProgress: seconds)
    }
    
    private func persistHistoryIfNeeded(force: Bool, currentProgress: Double? = nil) {
        guard viewModel.isPlaying else { return }
        let progress = max(currentProgress ?? viewModel.currentPlaybackSeconds(), 0)
        guard progress.isFinite else { return }
        
        if !force && abs(progress - lastPersistedProgress) < 20 {
            return
        }
        
        lastPersistedProgress = progress
        saveHistoryForCurrentEpisode(progressOverride: progress)
    }

    /// 开始新的线路/剧集播放会话，令旧播放器回调失效，并重新计算本集的持久化阈值。
    private func beginPlaybackSession() {
        playbackSessionToken = UUID()
        lastPersistedProgress = 0
    }
    
    private func restorePlaybackFromHistory() {
        guard let playbackState = CacheStore.shared.getPlaybackState(
            vodId: video.id,
            sourceKey: video.sourceKey,
            context: modelContext
        ) else { return }
        
        viewModel.applyPlaybackState(playbackState)
        lastPersistedProgress = max(playbackState.progressSeconds, 0)
    }
    
    private func refreshCollectState() {
        isCollected = CacheStore.shared.isCollected(
            vodId: video.id,
            sourceKey: video.sourceKey,
            context: modelContext
        )
    }
    
    private func toggleCollect() {
        if isCollected {
            CacheStore.shared.removeCollect(
                vodId: video.id,
                sourceKey: video.sourceKey,
                context: modelContext
            )
        } else {
            CacheStore.shared.addCollect(video, context: modelContext)
        }
        refreshCollectState()
    }
    
    private func playNextEpisodeIfNeeded() {
        var moved = false
        withAnimation {
            moved = viewModel.playNext()
        }
        
        if moved {
            beginPlaybackSession()
            saveHistoryForCurrentEpisode()
        }
    }

    private func playPreviousEpisode() {
        var moved = false
        withAnimation {
            moved = viewModel.playPrevious()
        }
        if moved {
            beginPlaybackSession()
            saveHistoryForCurrentEpisode()
        }
    }
    
    #if os(macOS)
    private func openFullScreenPlayer() {
        guard viewModel.playUrl != nil else { return }
        appState.enterPlayerFullScreen()
        
        if let window = NSApp.keyWindow ?? NSApp.mainWindow,
           window.styleMask.contains(.fullScreen) {
            showFullScreen = true
            return
        }
        
        pendingMacWindowFullScreen = requestMacWindowFullScreen(enter: true)
        if !pendingMacWindowFullScreen {
            showFullScreen = true
        }
    }

    @discardableResult
    private func requestMacWindowFullScreen(enter: Bool) -> Bool {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return false }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        guard enter != isFullScreen else { return false }
        window.toggleFullScreen(nil)
        return true
    }
    
    private func closeMacFullScreenOverlay() {
        pendingMacWindowFullScreen = false
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        if window?.styleMask.contains(.fullScreen) == true {
            requestMacWindowFullScreen(enter: false)
            return
        }
        showFullScreen = false
        appState.exitPlayerFullScreen()
    }
    #endif
}

private struct EpisodePickerSheet: View {
    let episodes: [VodInfo.Episode]
    let selectedIndex: Int
    let onSelect: (Int) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                EpisodeListView(
                    episodes: episodes,
                    selectedIndex: selectedIndex,
                    onSelect: onSelect
                )
                .padding(.top, 12)
            }
            .navigationTitle("选集")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .presentationDetents([.medium, .large])
            #endif
        }
    }
}

/// 全屏播放器
struct FullScreenPlayerView: View {
    let urlString: String
    var danmakuTitle: String = ""
    var danmakuEpisode: String = ""
    var startPosition: Double = 0
    var onProgressChanged: ((Double, Double?) -> Void)? = nil
    var onPlaybackEnded: (() -> Void)? = nil
    var canPlayNext: Bool = false
    var onPlayNext: (() -> Void)? = nil
    var systemController: SystemPlayerSessionController? = nil
    var vlcController: VLCPlayerController? = nil
    var onCloseRequested: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            PlayerView(
                urlString: urlString,
                startPosition: startPosition,
                onProgressChanged: onProgressChanged,
                onPlaybackEnded: onPlaybackEnded,
                onToggleFullScreen: {
                    if let onCloseRequested {
                        onCloseRequested()
                    } else {
                        dismiss()
                    }
                },
                onBack: onCloseRequested,
                canPlayNext: canPlayNext,
                onPlayNext: onPlayNext,
                danmakuTitle: danmakuTitle,
                danmakuEpisode: danmakuEpisode,
                systemController: systemController,
                vlcController: vlcController
            )
                .ignoresSafeArea()
            
            VStack {
                HStack {
                    Button {
                        if let onCloseRequested {
                            onCloseRequested()
                        } else {
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.white.opacity(0.8))
                    }
                    Spacer()
                }
                .padding()
                Spacer()
            }
        }
        #if os(iOS)
        // 保留系统状态栏与 Home 指示条；KSPlayer 原生全屏控制器负责
        // 根据 maskShow 更新状态栏可见性，避免时间/电量被 SwiftUI 包装层吞掉。
        .statusBarHidden(false)
        .persistentSystemOverlays(.visible)
        #endif
    }
}
