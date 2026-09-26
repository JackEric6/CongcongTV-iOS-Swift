import SwiftUI

/// 根视图 - 对应 Android 版 HomeActivity 的 TabView 导航
struct ContentView: View {
    /// 全局状态（配置加载、分栏状态等）。
    @EnvironmentObject var appState: AppState
    /// 网络连接状态。
    @EnvironmentObject var networkMonitor: NetworkMonitor
    /// 当前主标签索引。
    @State private var selectedTab = 0
    
    var body: some View {
        Group {
            mainTabView
        }
        .overlay(alignment: .top) {
            networkStatusBanner
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // 自动加载已保存的配置
            let defaults = UserDefaults.standard
            let savedVodUrl = defaults.string(forKey: HawkConfig.API_URL)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .flatMap { $0.isEmpty ? nil : $0 } ?? CongcongBrand.defaultConfigURL
            let savedLiveUrl = defaults.string(forKey: HawkConfig.LIVE_API_URL)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .flatMap { $0.isEmpty ? nil : $0 } ?? savedVodUrl
            if !savedVodUrl.isEmpty {
                // 启动自动恢复配置，避免每次重启都回到首次配置页。
                Task {
                    await appState.loadConfig(vodUrl: savedVodUrl, liveUrl: savedLiveUrl)
                }
            }
        }
    }
    
    // MARK: - 主界面
    
    /// 主体导航容器：iOS 使用 TabView，macOS 使用 NavigationSplitView。
    private var mainTabView: some View {
        #if os(iOS)
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem {
                    Label("首页", systemImage: "house.fill")
                }
                .tag(0)
            
            NavigationStack {
                HistoryView()
            }
                .tabItem {
                    Label("历史", systemImage: "clock.fill")
                }
                .tag(1)
            
            NavigationStack {
                FavoritesView()
            }
                .tabItem {
                    Label("收藏", systemImage: "heart.fill")
                }
                .tag(2)
            
            ProfileView()
                .tabItem {
                    Label("个人中心", systemImage: "person.fill")
                }
                .tag(3)
        }
        .tint(.orange)
        .onChange(of: selectedTab) { _, _ in
            HapticManager.shared.selection()
        }
        #else
        NavigationSplitView(columnVisibility: $appState.splitViewVisibility) {
            List(selection: $selectedTab) {
                Label("首页", systemImage: "house.fill")
                    .tag(0)
                Label("直播", systemImage: "tv.fill")
                    .tag(1)
                Label("搜索", systemImage: "magnifyingglass")
                    .tag(2)
                Label("收藏", systemImage: "heart.fill")
                    .tag(3)
                Label("历史", systemImage: "clock.fill")
                    .tag(5)
                Label("设置", systemImage: "gearshape.fill")
                    .tag(4)
            }
            .navigationTitle(CongcongBrand.appName)
            .listStyle(.sidebar)
        } detail: {
            switch selectedTab {
            case 0: HomeView()
            case 1: LiveView()
            case 2: SearchView()
            case 3:
                NavigationStack {
                    FavoritesView()
                }
            case 4: SettingsView()
            case 5:
                NavigationStack {
                    HistoryView()
                }
            default: HomeView()
            }
        }
        #endif
    }
    
    /// 网络断开时在顶部显示提示条。
    @ViewBuilder
    private var networkStatusBanner: some View {
        if !networkMonitor.isConnected {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 13, weight: .semibold))
                Text("网络连接已断开")
                    .font(.system(size: 13, weight: .medium))
                if appState.isRetryingConfig {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(.white)
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color.red.opacity(0.85))
            )
            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.3), value: networkMonitor.isConnected)
        }
    }
    
    private func readPasteboardText() -> String? {
        #if os(iOS)
        UIPasteboard.general.string
        #else
        // macOS 下通过 NSPasteboard 读取纯文本。
        NSPasteboard.general.string(forType: .string)
        #endif
    }
}
