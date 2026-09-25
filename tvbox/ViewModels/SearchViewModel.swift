import Foundation
import SwiftUI

/// 搜索 ViewModel
@MainActor
class SearchViewModel: ObservableObject {
    /// 搜索关键词输入。
    @Published var keyword: String = ""
    /// 当前结果列表。
    @Published var results: [Movie.Video] = []
    /// 搜索加载状态，用于控制进度指示器。
    @Published var isSearching = false
    /// 本地搜索历史（最近在前）。
    @Published var searchHistory: [String] = []
    /// 搜索失败或空结果提示。
    @Published var errorMessage: String?
    
    /// 源数据服务（负责多源并发搜索）。
    private let sourceService = SourceService.shared
    /// 搜索请求序号（用于丢弃过期异步结果）。
    private var latestSearchRequestId: UUID = UUID()
    /// 当前搜索任务；重新搜索时取消，避免旧请求继续占用网络和回写结果。
    private var activeSearchTask: Task<Void, Never>?
    
    /// 初始化时同步加载本地历史记录，确保搜索页首次渲染即可展示。
    init() {
        loadSearchHistory()
    }
    
    /// 执行搜索
    func search() async {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        activeSearchTask?.cancel()
        let requestId = UUID()
        latestSearchRequestId = requestId
        
        isSearching = true
        errorMessage = nil
        results = []

        // 无论搜索正常完成、被新搜索淘汰还是任务取消，都要回收加载状态。
        defer {
            if requestId == latestSearchRequestId {
                isSearching = false
            }
        }
        
        // 搜索一旦触发就先落历史，保持行为与移动端常见搜索体验一致。
        addToHistory(trimmed)
        
        // 每个源完成后立即追加一批结果；旧关键词的回调会被请求序号丢弃。
        let task = Task { [weak self] in
            guard let self else { return }
            await self.sourceService.searchAllStreaming(keyword: trimmed) { [weak self] videos in
                guard let self, requestId == self.latestSearchRequestId else { return }
                self.results.append(contentsOf: videos)
            }
        }
        activeSearchTask = task
        await task.value

        guard requestId == latestSearchRequestId else { return }
        if results.isEmpty {
            errorMessage = "未找到相关内容"
        }
        activeSearchTask = nil
        
    }
    
    /// 在指定源搜索
    func searchInSource(_ source: SourceBean) async {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        activeSearchTask?.cancel()
        activeSearchTask = nil
        let requestId = UUID()
        latestSearchRequestId = requestId
        addToHistory(trimmed)
        
        isSearching = true
        errorMessage = nil

        defer {
            if requestId == latestSearchRequestId {
                isSearching = false
            }
        }
        
        do {
            let videos = try await sourceService.search(sourceBean: source, keyword: trimmed)
            guard requestId == latestSearchRequestId else { return }
            self.results = videos
        } catch {
            guard requestId == latestSearchRequestId else { return }
            errorMessage = error.localizedDescription
        }
        
    }

    /// 取消当前搜索并结束加载状态。
    func cancelSearch() {
        activeSearchTask?.cancel()
        activeSearchTask = nil
        latestSearchRequestId = UUID()
        isSearching = false
    }
    
    // MARK: - 搜索历史
    
    /// 从本地读取历史。
    private func loadSearchHistory() {
        searchHistory = UserDefaults.standard.stringArray(forKey: HawkConfig.SEARCH_HISTORY) ?? []
    }
    
    /// 新增历史项并去重，最多保留 20 条。
    private func addToHistory(_ keyword: String) {
        searchHistory.removeAll { $0 == keyword }
        searchHistory.insert(keyword, at: 0)
        if searchHistory.count > 20 {
            searchHistory = Array(searchHistory.prefix(20))
        }
        UserDefaults.standard.set(searchHistory, forKey: HawkConfig.SEARCH_HISTORY)
    }
    
    /// 清空历史。
    func clearHistory() {
        searchHistory = []
        UserDefaults.standard.removeObject(forKey: HawkConfig.SEARCH_HISTORY)
    }
    
    /// 删除单条历史。
    func removeFromHistory(_ keyword: String) {
        searchHistory.removeAll { $0 == keyword }
        UserDefaults.standard.set(searchHistory, forKey: HawkConfig.SEARCH_HISTORY)
    }
}
