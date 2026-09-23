import Foundation
import SwiftUI
import Combine

/// 首页 ViewModel
@MainActor
class HomeViewModel: ObservableObject {
    /// 分类列表（包含手动注入的"推荐"分类）。
    @Published var sorts: [MovieSort.SortData] = []
    /// 当前选中的分类。
    @Published var selectedSort: MovieSort.SortData?
    /// 首页推荐内容（对应"推荐"分类）。
    @Published var homeVideos: [Movie.Video] = []
    /// 普通分类的视频列表（分页加载）。
    @Published var categoryVideos: [Movie.Video] = []
    /// 页面加载状态（分类加载与分页共用）。
    @Published var isLoading = false
    /// 当前分类的分页页码。
    @Published var currentPage = 1
    /// 是否还有下一页。
    @Published var hasMore = true
    /// 错误提示文案。
    @Published var errorMessage: String?
    
    /// 源数据访问服务。
    private let sourceService = SourceService.shared
    private let trendingService = DoubanTrendingService.shared
    /// 标记上次加载是否因网络错误失败（用于网络恢复自动重试）。
    private var lastLoadFailedDueToNetwork = false
    private var networkRestoredCancellable: AnyCancellable?
    
    init() {
        setupNetworkRestoredAutoRetry()
    }
    
    /// 加载分类列表
    func loadSorts() async {
        guard let source = ApiConfig.shared.homeSourceBean else { return }
        isLoading = true
        errorMessage = nil
        
        do {
            let result = try await sourceService.getSort(sourceBean: source)
            
            // 插入本地"推荐"分类，保持 UI 与 Android 版本习惯一致。
            var allSorts = [MovieSort.SortData.home()]
            allSorts.append(contentsOf: result.sorts)
            
            self.sorts = allSorts
            self.homeVideos = await loadDoubanRecommendations()
            lastLoadFailedDueToNetwork = false
            
            if selectedSort == nil {
                selectedSort = allSorts.first
            }
        } catch {
            errorMessage = error.localizedDescription
            lastLoadFailedDueToNetwork = error.isNetworkConnectionError
        }
        
        isLoading = false
    }

    /// 从豆瓣热门榜中筛出西瓜源确实存在的条目，避免推荐卡片无法播放。
    private func loadDoubanRecommendations() async -> [Movie.Video] {
        guard let xiguaSource = ApiConfig.shared.sourceBeanList.first(where: isXiguaSource) else { return [] }
        let trending = await trendingService.fetchTrending(limit: 20)
        guard !trending.isEmpty else { return [] }

        let indexedResults = await withTaskGroup(of: (Int, Movie.Video?).self, returning: [(Int, Movie.Video?)].self) { group in
            for (index, item) in trending.enumerated() {
                group.addTask { [sourceService] in
                    guard let coverURL = URL(string: item.cover),
                          let scheme = coverURL.scheme?.lowercased(),
                          scheme == "http" || scheme == "https" else { return (index, nil) }
                    guard let matches = try? await sourceService.search(sourceBean: xiguaSource, keyword: item.title) else {
                        return (index, nil)
                    }
                    let target = Self.normalizedTitle(item.title)
                    guard let match = matches.first(where: { Self.normalizedTitle($0.name) == target }) else {
                        return (index, nil)
                    }
                    var video = match
                    video.pic = item.cover
                    video.sourceKey = xiguaSource.key
                    video.doubanRating = Movie.Video.formatDoubanRating(item.rating)
                    return (index, video)
                }
            }

            var results: [(Int, Movie.Video?)] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        return indexedResults
            .sorted { $0.0 < $1.0 }
            .compactMap(\.1)
    }

    private func isXiguaSource(_ source: SourceBean) -> Bool {
        let identity = "\(source.key) \(source.name) \(source.api)".lowercased()
        return identity.contains("xgzy") || identity.contains("西瓜")
    }

    private nonisolated static func normalizedTitle(_ value: String) -> String {
        value.lowercased().unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) || (scalar.value >= 0x3400 && scalar.value <= 0x9FFF)
        }.map(String.init).joined()
    }
    
    /// 网络恢复时，若上次因网络错误导致首页为空，自动重新加载。
    private func setupNetworkRestoredAutoRetry() {
        networkRestoredCancellable = NetworkMonitor.shared.networkRestoredPublisher
            .sink { [weak self] in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.lastLoadFailedDueToNetwork || (self.sorts.isEmpty && self.homeVideos.isEmpty) else { return }
                    await self.refresh()
                }
            }
    }
    
    /// 选择分类
    func selectSort(_ sort: MovieSort.SortData) {
        // 切分类时先重置分页状态，避免旧分类残留数据闪烁。
        selectedSort = sort
        errorMessage = nil
        categoryVideos = []
        currentPage = 1
        hasMore = true
        
        if sort.id == "home" {
            return
        } else {
            Task {
                await loadCategoryVideos(page: 1, sort: sort)
            }
        }
    }
    
    /// 加载分类视频列表
    private func loadCategoryVideos(page: Int, sort: MovieSort.SortData) async {
        guard sort.id != "home" else { return }
        guard let source = ApiConfig.shared.homeSourceBean else { return }
        // 防重复并发加载，避免分页错序。
        guard !isLoading else { return }
        
        isLoading = true
        defer { isLoading = false }
        
        do {
            let videos = try await sourceService.getList(sourceBean: source, sortData: sort, page: page)
            
            // 分类切换过程中，丢弃旧请求结果
            guard selectedSort?.id == sort.id else { return }
            
            if page == 1 {
                categoryVideos = videos
            } else {
                categoryVideos.append(contentsOf: videos)
            }
            // 以"返回非空"作为是否继续分页的轻量判断。
            currentPage = page
            hasMore = !videos.isEmpty
        } catch {
            guard selectedSort?.id == sort.id else { return }
            errorMessage = error.localizedDescription
        }
    }
    
    /// 加载下一页
    func loadMore() async {
        guard let lastItem = categoryVideos.last else { return }
        await loadMoreIfNeeded(currentItem: lastItem)
    }
    
    /// 当最后一个元素出现时触发加载下一页
    func loadMoreIfNeeded(currentItem: Movie.Video) async {
        guard selectedSort?.id != "home" else { return }
        guard hasMore, !isLoading else { return }
        guard categoryVideos.last?.id == currentItem.id else { return }
        guard let sort = selectedSort else { return }
        
        let nextPage = currentPage + 1
        await loadCategoryVideos(page: nextPage, sort: sort)
    }
    
    /// 刷新
    func refresh() async {
        // 全量刷新时重置分页与错误态，再重新拉分类与当前分类内容。
        currentPage = 1
        hasMore = true
        categoryVideos = []
        errorMessage = nil
        await loadSorts()
        
        guard let sort = selectedSort else { return }
        if sort.id == "home" { return }
        
        if let matchedSort = sorts.first(where: { $0.id == sort.id }) {
            selectedSort = matchedSort
            await loadCategoryVideos(page: 1, sort: matchedSort)
        } else if let firstCategory = sorts.first(where: { $0.id != "home" }) {
            selectedSort = firstCategory
            await loadCategoryVideos(page: 1, sort: firstCategory)
        }
    }
}
