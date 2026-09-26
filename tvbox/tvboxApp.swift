import SwiftUI
import SwiftData
import Combine
#if os(iOS)
import UIKit
#endif

enum CongcongBrand {
    static let appName = "丛丛影视"
    static let credit = "Made By 丛丛"
    /// 安卓丛丛影视的 41 源 CMS 清单；首个源仍是西瓜，主页默认使用西瓜。
    static let defaultConfigURL = "https://ghproxy.net/https://raw.githubusercontent.com/JackEric6/movie/refs/heads/xgzy-config-20260922/movie2_xgzy_all"
}

/// 应用入口。
/// 负责初始化 SwiftData 容器，并将全局状态 `AppState` 注入到根视图。
#if os(iOS)
final class CongcongTVAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationLock.supportedInterfaceOrientations
    }
}
#endif

@main
struct CongcongTVApp: App {
#if os(iOS)
    @UIApplicationDelegateAdaptor(CongcongTVAppDelegate.self) private var appDelegate
#endif
    /// 全局运行时状态（配置加载状态、当前源、分栏布局状态等）。
    @StateObject private var appState = AppState()
    /// 网络状态监控。
    @StateObject private var networkMonitor = NetworkMonitor.shared
    
    /// 全局共享的 SwiftData 容器。
    /// 这里显式声明 Schema，确保收藏/历史/缓存三类数据使用同一持久化存储。
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            VodCollect.self,
            VodRecord.self,
            CacheItem.self
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()
    
    /// 应用窗口与根视图。
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(networkMonitor)
        }
        .modelContainer(sharedModelContainer)
        #if os(macOS)
        .defaultSize(width: 1200, height: 800)
        #endif
    }
}

/// 应用级状态容器。
/// 统一管理配置加载与页面共享状态，避免在各页面重复拉取配置。
@MainActor
class AppState: ObservableObject {
    /// 解析后的配置单例，提供给所有页面与 ViewModel 使用。
    @Published var apiConfig = ApiConfig.shared
    /// 配置是否已经成功加载。控制 `ContentView` 显示主界面或首次配置页。
    @Published var isConfigLoaded = false
    /// 当前首页选中的视频源 key（用于跨页面同步）。
    @Published var currentSourceKey: String = ""
    /// 配置加载错误信息，供 UI 展示。
    @Published var configLoadError: String?
    /// 是否正在重试加载配置。
    @Published var isRetryingConfig = false
    /// 配置重新验证成功后递增，供首页刷新当前源内容。
    @Published private(set) var sourceRefreshVersion = 0
    
    #if os(macOS)
    /// macOS 三栏布局可见性（侧栏/内容/详情）。
    @Published var splitViewVisibility: NavigationSplitViewVisibility = .all
    /// 进入播放器全屏前的分栏状态快照，用于退出全屏后恢复。
    private var splitViewVisibilityBeforePlayerFullScreen: NavigationSplitViewVisibility?
    #endif
    
    /// 上次尝试加载的配置地址（用于自动重试）。
    private var lastVodUrl: String = ""
    private var lastLiveUrl: String = ""
    private var networkRestoredCancellable: AnyCancellable?
    private var configLoadGeneration = UUID()
    private var configLoadInFlight = false
    private var foregroundRecoveryTask: Task<Void, Never>?
    private var lastForegroundRecoveryDate: Date?
    private let foregroundRecoveryDebounce: TimeInterval = 1.0
    
    init() {
        setupNetworkRestoredAutoRetry()
    }
    
    /// 仅提供点播地址时的快捷加载入口（直播地址默认与点播一致）。
    func loadConfig(url: String) async {
        await loadConfig(vodUrl: url, liveUrl: nil)
    }
    
    /// 加载点播与直播配置。
    /// - Parameters:
    ///   - vodUrl: 点播配置地址
    ///   - liveUrl: 直播配置地址；为空时自动回退到点播地址
    func loadConfig(vodUrl: String, liveUrl: String?, refreshHomeOnSuccess: Bool = false) async {
        let trimmedVod = vodUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLive = (liveUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVod.isEmpty else { return }
        let resolvedLive = trimmedLive.isEmpty ? trimmedVod : trimmedLive
        
        lastVodUrl = trimmedVod
        lastLiveUrl = resolvedLive
        configLoadError = nil
        let loadGeneration = UUID()
        configLoadGeneration = loadGeneration
        configLoadInFlight = true
        defer {
            if configLoadGeneration == loadGeneration {
                configLoadInFlight = false
            }
        }
        
        do {
            try await ApiConfig.shared.loadConfigs(vodApiUrl: trimmedVod, liveApiUrl: resolvedLive)
            guard configLoadGeneration == loadGeneration, !Task.isCancelled else { return }
            applyLoadedConfigState(refreshHome: refreshHomeOnSuccess)
        } catch {
            guard configLoadGeneration == loadGeneration, !Task.isCancelled else { return }
            if !(error is CancellationError) {
                configLoadError = error.localizedDescription
            }
        }
    }

    /// 应用回到前台时重新验证当前配置，并在成功后通知首页刷新。
    /// 只使用最近一次保存的点播/直播地址，不依赖当前是否已经成功加载过。
    func recoverConfigOnForeground() {
        guard !lastVodUrl.isEmpty else { return }
        guard !configLoadInFlight else { return }

        let now = Date()
        if let lastForegroundRecoveryDate,
           now.timeIntervalSince(lastForegroundRecoveryDate) < foregroundRecoveryDebounce {
            return
        }
        lastForegroundRecoveryDate = now

        foregroundRecoveryTask?.cancel()
        foregroundRecoveryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch {
                return
            }

            guard let self, !Task.isCancelled, !self.configLoadInFlight else { return }
            let vodUrl = self.lastVodUrl
            let liveUrl = self.lastLiveUrl
            self.isRetryingConfig = true
            await self.loadConfig(vodUrl: vodUrl, liveUrl: liveUrl, refreshHomeOnSuccess: true)
            self.isRetryingConfig = false
        }
    }
    
    /// 将"配置已加载"的统一状态写回全局。
    /// 该方法会在设置页和启动自动加载两个入口中复用。
    func applyLoadedConfigState(refreshHome: Bool = false) {
        isConfigLoaded = true
        configLoadError = nil
        currentSourceKey = ApiConfig.shared.homeSourceBean?.key ?? ""
        if refreshHome {
            sourceRefreshVersion &+= 1
        }
    }
    
    /// 网络恢复时复用前台恢复逻辑，避免重复实现导致并发加载。
    private func setupNetworkRestoredAutoRetry() {
        networkRestoredCancellable = NetworkMonitor.shared.networkRestoredPublisher
            .sink { [weak self] in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    self?.recoverConfigOnForeground()
                }
            }
    }
    
    #if os(macOS)
    /// 进入播放器全屏时隐藏侧栏，减少播放器可视区域干扰。
    func enterPlayerFullScreen() {
        if splitViewVisibilityBeforePlayerFullScreen == nil {
            splitViewVisibilityBeforePlayerFullScreen = splitViewVisibility
        }
        splitViewVisibility = .detailOnly
    }
    
    /// 退出播放器全屏时恢复之前的分栏状态。
    func exitPlayerFullScreen() {
        guard let previous = splitViewVisibilityBeforePlayerFullScreen else { return }
        splitViewVisibility = previous
        splitViewVisibilityBeforePlayerFullScreen = nil
    }
    #endif
}
