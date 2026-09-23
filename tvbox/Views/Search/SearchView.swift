import SwiftUI

/// 搜索页 - 对应 Android 版 SearchActivity
struct SearchView: View {
    /// 搜索状态与结果管理。
    @StateObject private var viewModel = SearchViewModel()
    /// 豆瓣当前热门条目，作为搜索页空态热搜榜。
    @State private var trendingItems: [DoubanTrendingItem] = []
    @State private var isLoadingTrending = false
    @State private var trendingError: String?
    
    #if os(iOS)
    /// iOS 卡片网格参数。
    private let columns = [
        GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 12)
    ]
    #else
    /// macOS 卡片网格参数。
    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 16)
    ]
    #endif
    
    var body: some View {
        VStack(spacing: 0) {
            // 搜索栏
            searchBar

            // 内容
            if viewModel.isSearching {
                Spacer()
                ProgressView("搜索中...")
                    .tint(.orange)
                Spacer()
            } else if !viewModel.results.isEmpty {
                searchResults
            } else if viewModel.keyword.isEmpty {
                // 输入为空时显示历史；输入非空但无结果时显示提示文案。
                searchHistorySection
            } else if let error = viewModel.errorMessage {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.largeTitle)
                        .foregroundColor(.gray)
                    Text(error)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.1))
        .navigationTitle("搜索")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await loadTrending()
        }
    }

    /// 加载热搜榜；失败时保留历史搜索，不阻断正常搜索功能。
    @MainActor
    private func loadTrending() async {
        guard trendingItems.isEmpty, !isLoadingTrending else { return }
        isLoadingTrending = true
        trendingError = nil
        let items = await DoubanTrendingService.shared.fetchTrending(limit: 20)
        trendingItems = items
        if items.isEmpty {
            trendingError = "暂时无法获取热搜榜"
        }
        isLoadingTrending = false
    }
    
    // MARK: - 搜索栏
    
    /// 顶部搜索输入区。
    private var searchBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                
                TextField("搜索影片...", text: $viewModel.keyword)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .submitLabel(.search)
                    .onSubmit {
                        Task { await viewModel.search() }
                    }
                    #if os(iOS)
                    .autocapitalization(.none)
                    #endif
                
                if !viewModel.keyword.isEmpty {
                    Button {
                        withAnimation {
                            viewModel.keyword = ""
                            viewModel.results = []
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.05))
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(LinearGradient(colors: [.orange.opacity(0.5), .clear], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            )
            
            Button {
                Task { await viewModel.search() }
            } label: {
                Text("搜索")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(LinearGradient(colors: [.orange, .red], startPoint: .leading, endPoint: .trailing))
                    .cornerRadius(14)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 10)
    }
    
    // MARK: - 搜索结果
    
    /// 搜索结果网格。
    private var searchResults: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(viewModel.results) { video in
                    NavigationLink(destination: DetailView(video: video)) {
                        VodCardView(video: video)
                    }
                    #if os(iOS)
                    .buttonStyle(VodCardPressStyle())
                    #else
                    .buttonStyle(.plain)
                    #endif
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }
    
    // MARK: - 搜索历史
    
    /// 搜索历史区域，支持复用历史关键词与一键清空。
    private var searchHistorySection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !viewModel.searchHistory.isEmpty {
                    HStack {
                        Text("搜索历史")
                            .font(.headline)
                            .foregroundColor(.white)
                        Spacer()
                        Button {
                            viewModel.clearHistory()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "trash")
                                Text("清空")
                            }
                            .font(.caption)
                            .foregroundColor(.gray)
                        }
                    }
                    .padding(.horizontal, 20)

                    FlowLayout(spacing: 8) {
                        ForEach(viewModel.searchHistory, id: \.self) { keyword in
                            HStack(spacing: 4) {
                                Button {
                                    viewModel.keyword = keyword
                                    Task { await viewModel.search() }
                                } label: {
                                    Text(keyword)
                                        .font(.subheadline)
                                        .foregroundColor(.white.opacity(0.8))
                                        .padding(.leading, 14)
                                        .padding(.vertical, 7)
                                }
                                .buttonStyle(.plain)

                                Button {
                                    viewModel.removeFromHistory(keyword)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.caption2.weight(.bold))
                                        .foregroundColor(.white.opacity(0.55))
                                        .frame(width: 26, height: 28)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.trailing, 3)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal, 20)
                }

                trendingSection

                if trendingItems.isEmpty, !isLoadingTrending, let trendingError {
                    Text(trendingError)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 12)
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
    }

    /// 当前热搜榜。条目使用豆瓣封面，点击后直接复用原搜索逻辑。
    private var trendingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("当前热搜榜")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                if isLoadingTrending {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.orange)
                }
            }
            .padding(.horizontal, 20)

            if !trendingItems.isEmpty {
                LazyVStack(spacing: 0) {
                    ForEach(Array(trendingItems.enumerated()), id: \.element.id) { index, item in
                        Button {
                            viewModel.keyword = item.title
                            Task { await viewModel.search() }
                        } label: {
                            HStack(spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(index < 3 ? .orange : .secondary)
                                    .frame(width: 24)

                                CachedAsyncImage(url: URL.posterURL(from: item.cover)) { image in
                                    image
                                        .resizable()
                                        .scaledToFill()
                                } placeholder: {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.white.opacity(0.08))
                                        .overlay(
                                            Image(systemName: "film")
                                                .font(.caption)
                                                .foregroundColor(.white.opacity(0.3))
                                        )
                                }
                                .frame(width: 38, height: 52)
                                .clipShape(RoundedRectangle(cornerRadius: 4))

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                    HStack(spacing: 6) {
                                        if !item.rating.isEmpty {
                                            Text("评分 \(item.rating)")
                                        }
                                        if !item.year.isEmpty {
                                            Text(item.year)
                                        }
                                    }
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "magnifyingglass")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// 流式布局
struct FlowLayout: Layout {
    /// 子项间距。
    var spacing: CGFloat = 8
    
    /// 计算整体尺寸。
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangement(proposal: proposal, subviews: subviews)
        return result.size
    }
    
    /// 按计算结果放置子视图。
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }
    
    /// 核心排版算法：按最大宽度逐个放置，超宽后自动换行。
    private func arrangement(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0
        
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            maxX = max(maxX, currentX)
        }
        
        return (CGSize(width: maxX, height: currentY + lineHeight), positions)
    }
}
