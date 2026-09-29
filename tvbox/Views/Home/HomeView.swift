import SwiftUI

/// 首页 - 对应 Android 版 HomeActivity + UserFragment
struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @EnvironmentObject var appState: AppState
    @State private var categoryScrollAnchorId: String?
    @State private var contentScrollAnchorId: String?
    
    // 网格布局
    #if os(iOS)
    private let columns = [
        GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 10)
    ]
    #else
    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 16)
    ]
    #endif
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 顶部栏
                headerBar
                
                // 分类标签栏
                // 冷启动时先保持加载态，等瓜子片单完整排序后再展示标签栏，
                // 避免临时返回顺序造成随机选中和横向跳动。
                if !viewModel.sorts.isEmpty && viewModel.selectedSort != nil {
                    categoryTabBar
                }
                
                // 内容区
                contentArea
            }
            .background(AppTheme.primaryGradient)
        }
        .task {
            await viewModel.loadSorts()
            guard viewModel.categoryVideos.isEmpty,
                  let selected = viewModel.selectedSort else { return }
            // 只重试模型已经决定的分类，不在页面生命周期回调中重新选择标签。
            viewModel.selectSort(selected, userInitiated: false)
        }
        .onAppear {
            viewModel.handleHomeAppearance()
        }
        // 去掉了首启配置页后，主页可能先于配置加载完成出现；
        // 配置就绪后自动拉取分类与首页数据。
        .onChange(of: appState.isConfigLoaded) { _, loaded in
            if loaded && viewModel.sorts.isEmpty && viewModel.homeVideos.isEmpty {
                Task {
                    await viewModel.loadSorts()
                    guard viewModel.categoryVideos.isEmpty,
                          let selected = viewModel.selectedSort else { return }
                    viewModel.selectSort(selected, userInitiated: false)
                }
            }
        }
        .onChange(of: appState.sourceRefreshVersion) { _, _ in
            guard appState.isConfigLoaded else { return }
            Task {
                await viewModel.refresh()
            }
        }
    }
    
    // MARK: - 顶部栏
    
    private var headerBar: some View {
        HStack(spacing: 12) {
            Text(CongcongBrand.appName)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)

            Spacer()

            NavigationLink {
                SearchView()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("搜索")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
    
    // MARK: - 分类标签栏
    
    private var categoryTabBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(viewModel.sorts) { sort in
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                viewModel.selectSort(sort)
                            }
                            categoryScrollAnchorId = sort.id
                            scrollCategoryBar(to: sort.id, proxy: proxy)
                        } label: {
                            VStack(spacing: 6) {
                                Text(sort.name)
                                    .font(.system(size: 14, weight: viewModel.selectedSort?.id == sort.id ? .bold : .regular))
                                    .foregroundColor(viewModel.selectedSort?.id == sort.id ? .white : .white.opacity(0.6))
                                
                                // 底部指示条
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(Color.orange)
                                    .frame(width: 20, height: 3)
                                    .opacity(viewModel.selectedSort?.id == sort.id ? 1 : 0)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .id(sort.id)
                    }
                }
                .padding(.horizontal, 12)
            }
            .onAppear {
                syncCategoryScrollAnchorIfNeeded()
                scrollCategoryBar(to: categoryScrollAnchorId, proxy: proxy, animated: false)
            }
            .onChange(of: viewModel.sorts.map(\.id)) { oldValue, newValue in
                syncCategoryScrollAnchorIfNeeded()
                scrollCategoryBar(to: categoryScrollAnchorId, proxy: proxy, animated: false)
            }
            .onChange(of: viewModel.selectedSort?.id) { oldId, newId in
                guard let newId else { return }
                categoryScrollAnchorId = newId
                scrollCategoryBar(to: newId, proxy: proxy)
            }
        }
        .padding(.bottom, 4)
    }
    
    private func categoryIndex(for id: String?) -> Int? {
        guard let id else { return nil }
        return viewModel.sorts.firstIndex(where: { $0.id == id })
    }
    
    private func syncCategoryScrollAnchorIfNeeded() {
        guard !viewModel.sorts.isEmpty else {
            categoryScrollAnchorId = nil
            return
        }
        
        if let selectedId = viewModel.selectedSort?.id,
           viewModel.sorts.contains(where: { $0.id == selectedId }) {
            categoryScrollAnchorId = selectedId
            return
        }
        
        if let anchorId = categoryScrollAnchorId,
           viewModel.sorts.contains(where: { $0.id == anchorId }) {
            return
        }
        
        categoryScrollAnchorId = viewModel.sorts.first?.id
    }
    
    private func scrollCategoryBar(to id: String?, proxy: ScrollViewProxy, animated: Bool = true) {
        guard let id else { return }
        
        if animated {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(id, anchor: .center)
            }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }
    
    // MARK: - 内容区
    
    private var contentArea: some View {
        let isHome = viewModel.selectedSort?.id == "home"
        let videos = isHome ? viewModel.homeVideos : viewModel.categoryVideos

        return Group {
            if (viewModel.selectedSort == nil && viewModel.errorMessage == nil)
                || (viewModel.isLoading && videos.isEmpty) {
                VStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.orange)
                    Text("加载中...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.top, 12)
                    Spacer()
                }
            } else if let error = viewModel.errorMessage, videos.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    
                    Button("重试") {
                        Task { await viewModel.refresh() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(videos) { video in
                            NavigationLink(value: video) {
                                VodCardView(video: video)
                            }
                            .id(video.id)
                            #if os(iOS)
                            .buttonStyle(VodCardPressStyle())
                            #else
                            .buttonStyle(.plain)
                            #endif
                            .onAppear {
                                Task { await viewModel.loadMoreIfNeeded(currentItem: video) }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    
                    // 加载更多
                    if viewModel.selectedSort?.id != "home" && viewModel.hasMore {
                        ProgressView()
                            .padding()
                    }
                }
                .scrollPosition(id: $contentScrollAnchorId)
                .onAppear {
                    restoreContentScrollPosition(sortID: viewModel.selectedSort?.id, videos: videos)
                }
                .onChange(of: contentScrollAnchorId) { _, newID in
                    viewModel.rememberScrollPosition(
                        videoID: newID,
                        sortID: viewModel.selectedSort?.id
                    )
                }
                .onChange(of: viewModel.selectedSort?.id) { _, newSortID in
                    restoreContentScrollPosition(sortID: newSortID, videos: videos)
                }
                .onChange(of: videos.map(\.id)) { _, _ in
                    restoreContentScrollPosition(sortID: viewModel.selectedSort?.id, videos: videos)
                }
                .refreshable {
                    await viewModel.refresh()
                }
            }
        }
        .navigationDestination(for: Movie.Video.self) { video in
            DetailView(video: video)
        }
    }

    private func restoreContentScrollPosition(sortID: String?, videos: [Movie.Video]) {
        let savedID = viewModel.savedScrollPosition(sortID: sortID)
        let targetID = savedID.flatMap { saved in
            videos.contains(where: { $0.id == saved }) ? saved : nil
        }
        guard contentScrollAnchorId != targetID else { return }
        Task { @MainActor in
            await Task.yield()
            contentScrollAnchorId = targetID
        }
    }
}
