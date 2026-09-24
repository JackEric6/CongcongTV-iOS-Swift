import Foundation
import SwiftUI

/// 设置 ViewModel
@MainActor
class SettingsViewModel: ObservableObject {
    /// 当输入地址是“多仓库入口”时，先弹出候选仓库供用户确认。
    struct PendingMultiRepoSelection: Identifiable {
        /// 当前待选择的是点播仓库还是直播仓库。
        enum Target {
            case vod
            case live
            
            var title: String {
                switch self {
                case .vod: return "点播"
                case .live: return "直播"
                }
            }
        }
        
        let id = UUID()
        /// 目标类型。
        let target: Target
        /// 用户原始输入地址（用于后续“是否联动 live 地址”判断）。
        let sourceUrl: String
        /// 可选仓库列表。
        let options: [ApiConfig.MultiRepoOption]
    }
    
    /// 点播配置地址。
    @Published var vodApiUrl: String = ""
    /// 直播配置地址。
    @Published var liveApiUrl: String = ""
    /// 配置加载中状态。
    @Published var isLoadingConfig = false
    /// 配置错误提示。
    @Published var configError: String?
    /// 配置是否加载成功（供 UI 执行后续跳转/收起流程）。
    @Published var configSuccess = false
    /// 多仓库待选状态，为 nil 表示无需弹窗。
    @Published var pendingMultiRepoSelection: PendingMultiRepoSelection?
    /// 最近输入过的 API 历史。
    @Published var apiHistory: [String] = []
    /// 点播播放器内核选择。
    @Published var vodPlayerEngine: PlayerEngine = .system
    /// 直播播放器内核选择。
    @Published var livePlayerEngine: PlayerEngine = .system
    /// 解码模式选择。
    @Published var decodeMode: VideoDecodeMode = .auto
    /// VLC 缓冲策略。
    @Published var vlcBufferMode: VLCBufferMode = .defaultMode
    /// 快进/快退步长（秒）。
    @Published var playTimeStep: Int = 10
    /// 缓存占用展示文本。
    @Published var cacheSizeString: String = "0 KB"
    
    /// 快进步长候选项。
    let playTimeStepOptions: [Int] = [5, 10, 15, 30, 60]
    /// 当前构建可用播放器列表。
    let playerEngineOptions: [PlayerEngine] = PlayerEngine.availableEngines
    /// 解码模式候选。
    let decodeModeOptions: [VideoDecodeMode] = VideoDecodeMode.allCases
    /// VLC 缓冲模式候选。
    let vlcBufferModeOptions: [VLCBufferMode] = VLCBufferMode.allCases
    
    /// 初始化时完成三件事：
    /// 1) 回填已保存的配置地址
    /// 2) 兼容老版本单一播放器字段到新字段
    /// 3) 回填播放/缓存相关设置
    init() {
        let defaults = UserDefaults.standard
        let savedVod = defaults.string(forKey: HawkConfig.API_URL) ?? CongcongBrand.defaultConfigURL
        vodApiUrl = savedVod
        if let savedLive = defaults.string(forKey: HawkConfig.LIVE_API_URL) {
            liveApiUrl = savedLive
        } else {
            liveApiUrl = savedVod
        }
        loadApiHistory()
        let hasLegacyPlayer = defaults.object(forKey: HawkConfig.PLAY_TYPE) != nil
        let legacyPlayerRaw = defaults.integer(forKey: HawkConfig.PLAY_TYPE)
        let defaultVodRaw = PlayerEngine.system.rawValue
        let defaultLiveRaw = PlayerEngine.isVLCAvailable
            ? PlayerEngine.vlc.rawValue
            : PlayerEngine.system.rawValue
        #if os(iOS)
        // iOS 点播已固定使用系统 AVPlayer；旧版本保存的播放器值仅作兼容占位。
        defaults.set(PlayerEngine.system.rawValue, forKey: HawkConfig.PLAY_TYPE_VOD)
        #else
        if defaults.object(forKey: HawkConfig.PLAY_TYPE_VOD) == nil {
            defaults.set(hasLegacyPlayer ? legacyPlayerRaw : defaultVodRaw, forKey: HawkConfig.PLAY_TYPE_VOD)
        }
        #endif
        if defaults.object(forKey: HawkConfig.PLAY_TYPE_LIVE) == nil {
            defaults.set(hasLegacyPlayer ? legacyPlayerRaw : defaultLiveRaw, forKey: HawkConfig.PLAY_TYPE_LIVE)
        }
        vodPlayerEngine = PlayerEngine.fromStoredValue(
            defaults.integer(forKey: HawkConfig.PLAY_TYPE_VOD)
        )
        livePlayerEngine = PlayerEngine.fromStoredValue(
            defaults.integer(forKey: HawkConfig.PLAY_TYPE_LIVE)
        )
        decodeMode = VideoDecodeMode.fromStoredValue(
            defaults.integer(forKey: HawkConfig.PLAY_DECODE_MODE)
        )
        vlcBufferMode = VLCBufferMode.fromStoredValue(
            defaults.integer(forKey: HawkConfig.PLAY_VLC_BUFFER_MODE)
        )
        
        let savedStep = defaults.integer(forKey: HawkConfig.PLAY_TIME_STEP)
        playTimeStep = savedStep > 0 ? savedStep : 10
        refreshCacheSize()
    }
    
    /// 加载配置
    func loadConfig() async {
        let trimmedVod = vodApiUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLive = liveApiUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVod.isEmpty else {
            configError = "请输入点播接口地址"
            return
        }
        
        isLoadingConfig = true
        configError = nil
        configSuccess = false
        pendingMultiRepoSelection = nil
        
        do {
            let resolvedLive = trimmedLive.isEmpty ? trimmedVod : trimmedLive
            
            // 若探测到多仓库入口，先中断加载并弹出候选，让用户显式选定目标仓库。
            if let pending = try await detectPendingMultiRepoSelection(
                vodUrl: trimmedVod,
                liveUrl: resolvedLive
            ) {
                pendingMultiRepoSelection = pending
                isLoadingConfig = false
                return
            }
            
            try await ApiConfig.shared.loadConfigs(vodApiUrl: trimmedVod, liveApiUrl: resolvedLive)
            // 保存用户输入（live 允许空值，表示跟随点播地址）。
            UserDefaults.standard.set(trimmedVod, forKey: HawkConfig.API_URL)
            UserDefaults.standard.set(trimmedLive, forKey: HawkConfig.LIVE_API_URL)
            vodApiUrl = trimmedVod
            liveApiUrl = trimmedLive
            addToApiHistory(trimmedVod)
            addToApiHistory(resolvedLive)
            configSuccess = true
        } catch {
            configError = error.localizedDescription
        }
        
        isLoadingConfig = false
    }
    
    /// 处理多仓库弹窗选择结果，并继续走统一加载流程。
    func selectPendingMultiRepoOption(_ option: ApiConfig.MultiRepoOption) async {
        guard let pending = pendingMultiRepoSelection else { return }
        let normalizedSource = ApiConfig.normalizeConfigUrl(pending.sourceUrl)
        
        switch pending.target {
        case .vod:
            let normalizedLive = ApiConfig.normalizeConfigUrl(liveApiUrl)
            // 若 live 输入与原始 vod 相同，说明用户希望两者共用，选择后同步更新。
            let shouldSyncLive = !liveApiUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && normalizedLive == normalizedSource
            vodApiUrl = option.url
            if shouldSyncLive {
                liveApiUrl = option.url
            }
        case .live:
            liveApiUrl = option.url
        }
        
        pendingMultiRepoSelection = nil
        await loadConfig()
    }
    
    /// 取消多仓库选择，恢复到普通待输入状态。
    func cancelPendingMultiRepoSelection() {
        pendingMultiRepoSelection = nil
        isLoadingConfig = false
    }
    
    /// 尝试识别输入地址是否为多仓库入口。
    /// - Returns: 需要弹窗选择时返回待选对象，否则返回 `nil`。
    private func detectPendingMultiRepoSelection(
        vodUrl: String,
        liveUrl: String
    ) async throws -> PendingMultiRepoSelection? {
        if let vodOptions = try await ApiConfig.shared.fetchMultiRepoOptions(from: vodUrl) {
            guard !vodOptions.isEmpty else {
                throw ConfigError.parseError("点播多仓库配置中没有可用地址")
            }
            return PendingMultiRepoSelection(
                target: .vod,
                sourceUrl: vodUrl,
                options: vodOptions
            )
        }
        
        let normalizedVod = ApiConfig.normalizeConfigUrl(vodUrl)
        let normalizedLive = ApiConfig.normalizeConfigUrl(liveUrl)
        guard normalizedLive != normalizedVod else {
            return nil
        }
        
        if let liveOptions = try await ApiConfig.shared.fetchMultiRepoOptions(from: liveUrl) {
            guard !liveOptions.isEmpty else {
                throw ConfigError.parseError("直播多仓库配置中没有可用地址")
            }
            return PendingMultiRepoSelection(
                target: .live,
                sourceUrl: liveUrl,
                options: liveOptions
            )
        }
        
        return nil
    }
    
    // MARK: - API 历史
    
    /// 读取 API 历史。
    private func loadApiHistory() {
        apiHistory = UserDefaults.standard.stringArray(forKey: "api_history") ?? []
    }
    
    /// 新增历史并去重，最多保留 10 条。
    private func addToApiHistory(_ url: String) {
        apiHistory.removeAll { $0 == url }
        apiHistory.insert(url, at: 0)
        if apiHistory.count > 10 {
            apiHistory = Array(apiHistory.prefix(10))
        }
        UserDefaults.standard.set(apiHistory, forKey: "api_history")
    }
    
    /// 删除单条 API 历史。
    func removeApiHistory(_ url: String) {
        apiHistory.removeAll { $0 == url }
        UserDefaults.standard.set(apiHistory, forKey: "api_history")
    }
    
    /// 清除所有缓存
    func clearCache() {
        URLCache.shared.removeAllCachedResponses()
        ImageLoader.shared.clearCache()
        ImageCache.shared.clear()
        refreshCacheSize()
    }
    
    /// 设置快进步长
    func setPlayTimeStep(_ step: Int) {
        guard step > 0 else { return }
        playTimeStep = step
        UserDefaults.standard.set(step, forKey: HawkConfig.PLAY_TIME_STEP)
    }
    
    /// 设置点播播放器内核
    func setVodPlayerEngine(_ engine: PlayerEngine) {
        #if os(iOS)
        return
        #else
        guard playerEngineOptions.contains(engine) else { return }
        vodPlayerEngine = engine
        UserDefaults.standard.set(engine.rawValue, forKey: HawkConfig.PLAY_TYPE_VOD)
        #endif
    }
    
    /// 设置直播播放器内核
    func setLivePlayerEngine(_ engine: PlayerEngine) {
        guard playerEngineOptions.contains(engine) else { return }
        livePlayerEngine = engine
        UserDefaults.standard.set(engine.rawValue, forKey: HawkConfig.PLAY_TYPE_LIVE)
    }
    
    /// 设置视频解码模式
    func setDecodeMode(_ mode: VideoDecodeMode) {
        guard decodeModeOptions.contains(mode) else { return }
        decodeMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: HawkConfig.PLAY_DECODE_MODE)
    }

    /// 设置 VLC 缓冲策略
    func setVLCBufferMode(_ mode: VLCBufferMode) {
        guard vlcBufferModeOptions.contains(mode) else { return }
        vlcBufferMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: HawkConfig.PLAY_VLC_BUFFER_MODE)
    }
    
    /// 统计并刷新缓存占用展示（网络缓存 + 图片缓存磁盘占用）。
    private func refreshCacheSize() {
        let sharedDisk = URLCache.shared.currentDiskUsage
        let imageDisk = ImageLoader.shared.cacheUsage.disk
        cacheSizeString = Self.formatSize(bytes: sharedDisk + imageDisk)
    }
    
    /// 格式化字节大小。
    private static func formatSize(bytes: Int) -> String {
        let size = max(0, bytes)
        if size < 1024 * 1024 {
            return String(format: "%.1f KB", Double(size) / 1024.0)
        }
        return String(format: "%.1f MB", Double(size) / 1024.0 / 1024.0)
    }
}
