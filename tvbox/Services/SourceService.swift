import Foundation

/// 视频源数据服务 - 对应 Android 版 SourceViewModel.java
/// 负责从各视频源获取分类、列表、详情和搜索数据
class SourceService {
    static let shared = SourceService()

    private let network = NetworkManager.shared

    private init() {}

    // MARK: - 获取分类列表

    /// 获取指定源的分类列表和首页推荐
    func getSort(sourceBean: SourceBean) async throws -> (sorts: [MovieSort.SortData], homeVideos: [Movie.Video]) {
        if sourceBean.key.caseInsensitiveCompare("guazi") == .orderedSame {
            // 瓜子没有标准 CMS 分类接口，首页分类走专用加密接口。
            return (sorts: await GuaziService.shared.homeSorts(), homeVideos: [])
        }
        let api = sourceBean.api
        guard !api.isEmpty else {
            throw SourceError.emptyApi
        }

        // type=3 (JAR/Spider) 暂不支持
        guard sourceBean.isSupportedInSwift else {
            throw SourceError.unsupportedType(sourceBean.typeDescription)
        }

        // 确保 api 是有效的 HTTP URL
        guard sourceBean.isHttpApi else {
            throw SourceError.invalidApiUrl(api)
        }

        let rawJSON: String
        if sourceBean.type == 0 {
            // XML 接口
            rawJSON = try await getString(from: api, sourceBean: sourceBean, expectation: .catalog)
        } else if sourceBean.type == 4 {
            // Type 4: 远程接口，需要 extend 和 filter 参数
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "filter", value: "true")
            ]
            // 加载 extend
            if let ext = sourceBean.ext, !ext.isEmpty {
                let extend = await resolveExtend(ext)
                if !extend.isEmpty {
                    queryItems.append(URLQueryItem(name: "extend", value: extend))
                }
            }
            let url = try buildURL(base: api, queryItems: queryItems)
            rawJSON = try await getString(from: url, sourceBean: sourceBean, expectation: .catalog)
        } else {
            // JSON 接口 (type=1)
            let url = try buildURL(
                base: api,
                queryItems: [URLQueryItem(name: "ac", value: "class")]
            )
            rawJSON = try await getString(from: url, sourceBean: sourceBean, expectation: .catalog)
        }

        let jsonStr = normalizedResponse(rawJSON, sourceBean: sourceBean)
        var (sorts, homeVideos) = try parseSort(jsonStr, sourceBean: sourceBean)

        // 当大多数推荐视频的 vod_pic 为空时（ac=class 接口常见情况），
        // 额外请求列表接口获取带完整海报的推荐视频
        let picMissingCount = homeVideos.filter { $0.pic.trimmingCharacters(in: .whitespaces).isEmpty }.count
        let needsFallback = homeVideos.isEmpty || picMissingCount > homeVideos.count / 2

        if needsFallback && (sourceBean.type == 1 || sourceBean.type == 4) {
            let listUrl: String
            if sourceBean.type == 4 {
                // type=4 用 ac=detail 格式，与 getList 保持一致
                let ext = Data("{}".utf8).base64EncodedString()
                listUrl = try buildURL(
                    base: api,
                    queryItems: [
                        URLQueryItem(name: "ac", value: "detail"),
                        URLQueryItem(name: "filter", value: "true"),
                        URLQueryItem(name: "pg", value: "1"),
                        URLQueryItem(name: "ext", value: ext)
                    ]
                )
            } else {
                // type=1 用 ac=videolist 格式
                listUrl = try buildURL(
                    base: api,
                    queryItems: [
                        URLQueryItem(name: "ac", value: "videolist"),
                        URLQueryItem(name: "pg", value: "1")
                    ]
                )
            }
            if let listStr = try? await getString(from: listUrl, sourceBean: sourceBean, expectation: .catalog) {
                let normalizedList = normalizedResponse(listStr, sourceBean: sourceBean)
                let fallback = (try? parseVideoList(normalizedList, sourceKey: sourceBean.key, type: sourceBean.type)) ?? []
                if !fallback.isEmpty {
                    homeVideos = fallback
                }
            }
        }

        return (sorts, homeVideos)
    }

    /// 获取分类列表的渐进版本。瓜子会在每个栏目页返回后回调当前排序，
    /// 其他资源站保持一次性返回，避免改变既有加载行为。
    func getSortProgressively(
        sourceBean: SourceBean,
        onSorts: @escaping @Sendable ([MovieSort.SortData]) async -> Void
    ) async throws -> (sorts: [MovieSort.SortData], homeVideos: [Movie.Video]) {
        if sourceBean.key.caseInsensitiveCompare("guazi") == .orderedSame {
            let sorts = try await GuaziService.shared.homeSortsProgressively(onUpdate: onSorts)
            return (sorts: sorts, homeVideos: [])
        }

        let result = try await getSort(sourceBean: sourceBean)
        await onSorts(result.sorts)
        return result
    }

    private func parseSort(_ jsonStr: String, sourceBean: SourceBean) throws -> (sorts: [MovieSort.SortData], homeVideos: [Movie.Video]) {
        guard let data = jsonStr.data(using: .utf8) else {
            throw SourceError.parseError("无法解析数据")
        }

        var sorts: [MovieSort.SortData] = []
        var homeVideos: [Movie.Video] = []

        if sourceBean.type == 0 {
            // XML 格式
            let lowercased = jsonStr.lowercased()
            guard lowercased.contains("<rss") || lowercased.contains("<root") ||
                    lowercased.contains("<class") || lowercased.contains("<ty") ||
                    lowercased.contains("<video") else {
                throw SourceError.invalidResponse("XML 响应缺少分类或视频结构")
            }
            sorts = parseXMLCategories(from: jsonStr)
        } else {
            // JSON 格式 (type=1, type=4)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SourceError.invalidResponse("JSON 响应格式无效")
            }
            guard json["class"] != nil || json["list"] != nil else {
                throw SourceError.invalidResponse("JSON 响应缺少 class/list 结构")
            }

            // 解析分类
            if let classValue = json["class"] {
                guard let classList = classValue as? [[String: Any]] else {
                    throw SourceError.invalidResponse("JSON 的 class 结构无效")
                }
                for cls in classList {
                    let id: String
                    if let intId = cls["type_id"] as? Int {
                        id = String(intId)
                    } else {
                        id = cls["type_id"] as? String ?? ""
                    }
                    let parentID: String
                    if let intParentID = cls["type_pid"] as? Int {
                        parentID = String(intParentID)
                    } else {
                        parentID = cls["type_pid"] as? String ?? ""
                    }
                    let name = cls["type_name"] as? String ?? ""
                    sorts.append(MovieSort.SortData(id: id, name: name, parentID: parentID))
                }
            }

            // 解析首页推荐视频
            if let listValue = json["list"] {
                guard let list = listValue as? [[String: Any]] else {
                    throw SourceError.invalidResponse("JSON 的 list 结构无效")
                }
                for item in list {
                    let decoder = JSONDecoder()
                    if let itemData = try? JSONSerialization.data(withJSONObject: item),
                       var video = try? decoder.decode(Movie.Video.self, from: itemData) {
                        video.sourceKey = sourceBean.key
                        homeVideos.append(video)
                    }
                }
            }
        }

        return (sorts, homeVideos)
    }

    private func parseXMLCategories(from xml: String) -> [MovieSort.SortData] {
        // 简化的 XML 分类解析
        var sorts: [MovieSort.SortData] = []
        let pattern = "<ty id=\"(\\d+)\"[^>]*>([^<]+)</ty>"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
            for match in matches {
                if let idRange = Range(match.range(at: 1), in: xml),
                   let nameRange = Range(match.range(at: 2), in: xml) {
                    let id = String(xml[idRange])
                    let name = String(xml[nameRange])
                    sorts.append(MovieSort.SortData(id: id, name: name))
                }
            }
        }
        return sorts
    }

    // MARK: - 获取分类视频列表

    /// 获取分类下的视频列表
    func getList(sourceBean: SourceBean, sortData: MovieSort.SortData, page: Int = 1, filters: [String: String]? = nil) async throws -> [Movie.Video] {
        if sourceBean.key.caseInsensitiveCompare("guazi") == .orderedSame {
            return try await GuaziService.shared.category(
                sort: sortData,
                page: page,
                filters: filters
            )
        }
        let api = sourceBean.api
        guard !api.isEmpty else { throw SourceError.emptyApi }
        guard sourceBean.isSupportedInSwift else { throw SourceError.unsupportedType(sourceBean.typeDescription) }
        guard sourceBean.isHttpApi else { throw SourceError.invalidApiUrl(api) }

        let url: String
        if sourceBean.type == 0 {
            // XML 接口
            url = try buildURL(
                base: api,
                queryItems: [
                    URLQueryItem(name: "ac", value: "videolist"),
                    URLQueryItem(name: "t", value: sortData.id),
                    URLQueryItem(name: "pg", value: String(page))
                ]
            )
        } else if sourceBean.type == 4 {
            // Type 4: 远程接口
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "ac", value: "detail"),
                URLQueryItem(name: "filter", value: "true"),
                URLQueryItem(name: "t", value: sortData.id),
                URLQueryItem(name: "pg", value: String(page))
            ]

            // 附加筛选参数（base64 编码）
            if let filters = filters, !filters.isEmpty {
                if let filterData = try? JSONSerialization.data(withJSONObject: filters),
                   let filterStr = String(data: filterData, encoding: .utf8) {
                    let ext = Data(filterStr.utf8).base64EncodedString()
                    queryItems.append(URLQueryItem(name: "ext", value: ext))
                }
            } else {
                let ext = Data("{}".utf8).base64EncodedString()
                queryItems.append(URLQueryItem(name: "ext", value: ext))
            }

            // 加载 extend
            if let ext = sourceBean.ext, !ext.isEmpty {
                let extend = await resolveExtend(ext)
                if !extend.isEmpty {
                    queryItems.append(URLQueryItem(name: "extend", value: extend))
                }
            }
            url = try buildURL(base: api, queryItems: queryItems)
        } else {
            // JSON 接口 (type=1)
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "ac", value: "videolist"),
                URLQueryItem(name: "t", value: sortData.id),
                URLQueryItem(name: "pg", value: String(page))
            ]

            // 附加筛选参数
            if let filters = filters {
                for (key, value) in filters {
                    queryItems.append(URLQueryItem(name: key, value: value))
                }
            }
            url = try buildURL(base: api, queryItems: queryItems)
        }

        let jsonStr = try await getString(from: url, sourceBean: sourceBean, expectation: .catalog)
        return try parseVideoList(
            normalizedResponse(jsonStr, sourceBean: sourceBean),
            sourceKey: sourceBean.key,
            type: sourceBean.type
        )
    }

    private func parseVideoList(_ jsonStr: String, sourceKey: String, type: Int) throws -> [Movie.Video] {
        guard let data = jsonStr.data(using: .utf8) else {
            throw SourceError.parseError("无法解析数据")
        }

        var videos: [Movie.Video] = []

        if type == 0 {
            videos = parseXMLVideoList(from: jsonStr, sourceKey: sourceKey)
        } else {
            // JSON 格式 (type=1, type=4)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SourceError.invalidResponse("JSON 响应格式无效")
            }
            guard let list = json["list"] as? [[String: Any]] else {
                throw SourceError.invalidResponse("JSON 响应缺少有效 list 结构")
            }
            let decoder = JSONDecoder()
            for item in list {
                if let itemData = try? JSONSerialization.data(withJSONObject: item),
                   var video = try? decoder.decode(Movie.Video.self, from: itemData) {
                    video.sourceKey = sourceKey
                    videos.append(video)
                }
            }
        }

        return videos
    }

    private func parseXMLVideoList(from xml: String, sourceKey: String) -> [Movie.Video] {
        // 简化 XML 视频列表解析
        var videos: [Movie.Video] = []
        let pattern = "<video>.*?<id>(\\d+)</id>.*?<name><!\\[CDATA\\[(.+?)\\]\\]></name>.*?<pic>(.*?)</pic>.*?<note><!\\[CDATA\\[(.*?)\\]\\]></note>.*?</video>"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) {
            let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
            for match in matches {
                var video = Movie.Video()
                if let r = Range(match.range(at: 1), in: xml) { video.id = String(xml[r]) }
                if let r = Range(match.range(at: 2), in: xml) { video.name = String(xml[r]) }
                if let r = Range(match.range(at: 3), in: xml) { video.pic = String(xml[r]) }
                if let r = Range(match.range(at: 4), in: xml) { video.note = String(xml[r]) }
                video.sourceKey = sourceKey
                videos.append(video)
            }
        }
        return videos
    }

    // MARK: - 获取详情

    /// 获取视频详情
    func getDetail(
        sourceBean: SourceBean,
        vodId: String,
        preferredPlaybackFlag: String? = nil,
        onGuaziDetailProgress: (@MainActor @Sendable (VodInfo) -> Void)? = nil
    ) async throws -> VodInfo? {
        if sourceBean.key.caseInsensitiveCompare("guazi") == .orderedSame {
            return try await GuaziService.shared.detail(
                vodID: vodId,
                preferredFlag: preferredPlaybackFlag,
                onProgress: onGuaziDetailProgress
            )
        }
        if SearchSourceGroup.classify(sourceKey: sourceBean.key, sourceName: sourceBean.name) == .jianpian {
            return try await JianpianSourceService.detail(vodID: vodId)
        }
        if SearchSourceGroup.classify(sourceKey: sourceBean.key, sourceName: sourceBean.name) == .changzhang {
            return try await Cz4kSourceService.detail(vodID: vodId)
        }
        if sourceBean.key.caseInsensitiveCompare("ikanbot") == .orderedSame {
            return try await MigratedWebSourceService.detailIkanbot(source: sourceBean, vodID: vodId)
        }
        if sourceBean.key.caseInsensitiveCompare("zanpian") == .orderedSame {
            return try await MigratedWebSourceService.detailZanpian(source: sourceBean, vodID: vodId)
        }
        let api = sourceBean.api
        guard !api.isEmpty else { throw SourceError.emptyApi }
        guard !vodId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SourceError.invalidResponse("详情 ID 为空")
        }
        guard sourceBean.isSupportedInSwift else { throw SourceError.unsupportedType(sourceBean.typeDescription) }
        guard sourceBean.isHttpApi else { throw SourceError.invalidApiUrl(api) }

        let url: String
        if sourceBean.type == 0 {
            url = try buildURL(
                base: api,
                queryItems: [
                    URLQueryItem(name: "ac", value: "videolist"),
                    URLQueryItem(name: "ids", value: vodId)
                ]
            )
        } else if sourceBean.type == 4 {
            // Type 4: 远程接口
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "ac", value: "detail"),
                URLQueryItem(name: "ids", value: vodId)
            ]

            // 加载 extend
            if let ext = sourceBean.ext, !ext.isEmpty {
                let extend = await resolveExtend(ext)
                if !extend.isEmpty {
                    queryItems.append(URLQueryItem(name: "extend", value: extend))
                }
            }
            url = try buildURL(base: api, queryItems: queryItems)
        } else {
            // JSON 接口 (type=1)
            url = try buildURL(
                base: api,
                queryItems: [
                    URLQueryItem(name: "ac", value: "detail"),
                    URLQueryItem(name: "ids", value: vodId)
                ]
            )
        }

        let jsonStr = try await getString(from: url, sourceBean: sourceBean, expectation: .catalog)
        guard let detail = try parseDetail(
            normalizedResponse(jsonStr, sourceBean: sourceBean),
            sourceBean: sourceBean
        ) else {
            throw SourceError.invalidResponse("详情响应没有匹配的视频")
        }
        return detail
    }

    private func parseDetail(_ jsonStr: String, sourceBean: SourceBean) throws -> VodInfo? {
        if sourceBean.type == 0 {
            guard let detail = parseXMLDetail(jsonStr, sourceKey: sourceBean.key) else {
                throw SourceError.invalidResponse("XML 详情缺少有效视频结构")
            }
            return detail
        }

        guard let data = jsonStr.data(using: .utf8) else {
            throw SourceError.parseError("无法解析数据")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SourceError.invalidResponse("JSON 响应格式无效")
        }
        guard let list = json["list"] as? [[String: Any]] else {
            throw SourceError.invalidResponse("JSON 响应缺少有效 list 结构")
        }
        guard let first = list.first else {
            throw SourceError.invalidResponse("详情响应 list 为空")
        }

        let decoder = JSONDecoder()
        guard let itemData = try? JSONSerialization.data(withJSONObject: first),
              var video = try? decoder.decode(Movie.Video.self, from: itemData) else {
            throw SourceError.invalidResponse("详情视频结构无效")
        }
        video.sourceKey = sourceBean.key

        let playFrom = first["vod_play_from"] as? String ?? ""
        let playUrl = first["vod_play_url"] as? String ?? ""
        let playback = filteredPlaybackLines(
            playFrom: playFrom,
            playUrl: playUrl,
            sourceBean: sourceBean
        )
        return VodInfo.from(video: video, playFrom: playback.playFrom, playUrl: playback.playUrl)
    }

    // MARK: - 搜索

    /// 在指定源中搜索
    func search(sourceBean: SourceBean, keyword: String) async throws -> [Movie.Video] {
        if sourceBean.key.caseInsensitiveCompare("guazi") == .orderedSame {
            return try await GuaziService.shared.search(keyword: keyword)
        }
        let searchGroup = SearchSourceGroup.classify(sourceKey: sourceBean.key, sourceName: sourceBean.name)
        if searchGroup == .jianpian {
            return filterSearchResults(try await JianpianSourceService.search(keyword: keyword), keyword: keyword)
        }
        if searchGroup == .changzhang {
            return filterSearchResults(try await Cz4kSourceService.search(keyword: keyword), keyword: keyword)
        }
        if sourceBean.key.caseInsensitiveCompare("ikanbot") == .orderedSame {
            return filterSearchResults(
                try await MigratedWebSourceService.searchIkanbot(source: sourceBean, keyword: keyword),
                keyword: keyword
            )
        }
        if sourceBean.key.caseInsensitiveCompare("zanpian") == .orderedSame {
            return filterSearchResults(
                try await MigratedWebSourceService.searchZanpian(source: sourceBean, keyword: keyword),
                keyword: keyword
            )
        }
        let api = sourceBean.api
        guard !api.isEmpty else { throw SourceError.emptyApi }
        guard sourceBean.isSupportedInSwift else { throw SourceError.unsupportedType(sourceBean.typeDescription) }
        guard sourceBean.isHttpApi else { throw SourceError.invalidApiUrl(api) }

        let url: String
        if sourceBean.type == 0 {
            url = try buildSearchURL(
                base: api,
                queryItems: [URLQueryItem(name: "wd", value: keyword)]
            )
        } else if sourceBean.type == 4 {
            // Type 4: 远程接口
            let quickValue = sourceBean.isQuickSearchEnabled ? "true" : "false"
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "wd", value: keyword),
                URLQueryItem(name: "ac", value: "detail"),
                URLQueryItem(name: "quick", value: quickValue)
            ]

            // 加载 extend
            if let ext = sourceBean.ext, !ext.isEmpty {
                let extend = await resolveExtend(ext, timeout: 3, maxRetries: 0)
                if !extend.isEmpty {
                    queryItems.append(URLQueryItem(name: "extend", value: extend))
                }
            }
            url = try buildSearchURL(base: api, queryItems: queryItems)
        } else {
            // AVBox 对标准 JSON CMS 搜索统一使用 ac=detail&wd=，并保留
            // 配置 URL 中已有的 source/token 等参数。
            url = try buildSearchURL(
                base: api,
                queryItems: [
                    URLQueryItem(name: "ac", value: "detail"),
                    URLQueryItem(name: "wd", value: keyword)
                ]
            )
        }

        // 搜索是聚合请求的一部分，不能沿用首页请求的长超时和重试策略。
        // 单个站点失败应尽快让位给其他站点，避免搜索页长期停留在“搜索中”。
        let jsonStr = try await getSearchString(from: url, sourceBean: sourceBean)
        let videos = try parseVideoList(
            normalizedResponse(jsonStr, sourceBean: sourceBean),
            sourceKey: sourceBean.key,
            type: sourceBean.type
        )
        return filterSearchResults(videos, keyword: keyword)
    }

    /// 将 KKT影视的播放器页地址尽量解析为 AVPlayer/VLC 可以直接打开的媒体地址。
    /// 普通 CMS 源也可能返回播放器页（例如 `/play/...`），统一尝试提取
    /// 页面中的真实媒体地址；已经是 m3u8/mp4 等直链时保持原值。
    func resolvePlayableURL(sourceBean: SourceBean, url: String) async throws -> String {
        if sourceBean.key.caseInsensitiveCompare("guazi") == .orderedSame {
            guard let request = GuaziService.PlayRequest(url: url) else {
                throw SourceError.invalidPlayableURL(url)
            }
            // Resolve the dynamic address before handing media to AVPlayer.
            // Do not depend on AVPlayer forwarding custom headers across a
            // cross-origin redirect; Guazi serves only a short preview to
            // default browser-like user agents.
            let mediaURL = try await GuaziService.shared.play(request)
            guard let playableURL = Self.validPlayableURL(mediaURL) else {
                throw SourceError.invalidPlayableURL(mediaURL)
            }
            return playableURL
        }

        return try await resolvePlaybackPage(
            sourceBean: sourceBean,
            url: url,
            visited: [],
            remainingPageHops: 3
        )
    }

    private func resolvePlaybackPage(
        sourceBean: SourceBean,
        url: String,
        visited: Set<String>,
        remainingPageHops: Int
    ) async throws -> String {
        let normalized = KktvsResponseNormalizer.normalizeMediaURL(url)
        guard let validURL = Self.validPlayableURL(normalized) else {
            throw SourceError.invalidPlayableURL(url)
        }
        let scheme = URLComponents(string: validURL)?.scheme?.lowercased()
        if KktvsResponseNormalizer.directMediaURL(normalized) != nil
            || !["http", "https"].contains(scheme ?? "") {
            return validURL
        }
        guard remainingPageHops > 0 else {
            throw SourceError.invalidPlayableURL(validURL)
        }
        var visited = visited
        guard visited.insert(validURL).inserted else {
            throw SourceError.invalidPlayableURL(validURL)
        }

        // 播放页通常是 HTML；有些资源站则用无扩展名 URL 直接返回 HLS 清单。
        // 先识别清单内容，再尝试播放器页提取，并限制跳转层数以防循环页面。
        let body = try await getPlaybackPage(from: validURL, sourceBean: sourceBean)
        if KktvsResponseNormalizer.isHLSPlaylist(body) {
            return validURL
        }
        guard let extracted = KktvsResponseNormalizer.extractMediaURL(from: body, baseURL: validURL),
              let resolvedURL = Self.validPlayableURL(extracted),
              resolvedURL != validURL else {
            throw SourceError.invalidPlayableURL(validURL)
        }
        return try await resolvePlaybackPage(
            sourceBean: sourceBean,
            url: resolvedURL,
            visited: visited,
            remainingPageHops: remainingPageHops - 1
        )
    }

    /// 只允许播放器可以处理的非空绝对地址进入播放状态。
    static func validPlayableURL(_ value: String) -> String? {
        let normalized = KktvsResponseNormalizer.normalizeMediaURL(value)
        guard !normalized.isEmpty,
              !normalized.contains(where: { $0.isWhitespace }),
              let components = URLComponents(string: normalized),
              let scheme = components.scheme?.lowercased(),
              !scheme.isEmpty else {
            return nil
        }

        let networkSchemes = ["http", "https", "rtsp", "rtmp", "mms"]
        if networkSchemes.contains(scheme) {
            guard let host = components.host, !host.isEmpty else { return nil }
        }
        return normalized
    }

    /// 多源并发搜索。
    ///
    /// 站点数量较多时采用有限并发：同时请求过多会触发系统连接排队，
    /// 而完全串行又会被失效站点拖慢。每个站点都有独立的短超时，
    /// 一个站点失败不会影响其他站点，也不会阻塞最终收敛。
    @MainActor
    func searchAll(keyword: String) async -> [Movie.Video] {
        var allResults: [Movie.Video] = []
        await searchAllStreaming(keyword: keyword) { videos in
            allResults.append(contentsOf: videos)
        }
        return allResults
    }

    /// 多源并发搜索，并在每个源完成后立即返回该源的结果。
    ///
    /// 结果按源完成顺序回调，而不是按配置顺序等待汇总；这样搜索页可以
    /// 像 Android 端一样逐源显示。每个源只在自己的结果集合内去重，失败
    /// 或取消的源不会阻塞其他源。
    func searchAllStreaming(
        keyword: String,
        onResults: @escaping @MainActor ([Movie.Video]) async -> Void,
        onSourceError: @escaping @MainActor (String, String) async -> Void = { _, _ in }
    ) async {
        let sources = await ApiConfig.shared.getSearchableSources()

        var searchableSources: [SourceBean] = []
        for source in sources where source.isSearchable
            && source.isSelectable
            && source.isSupportedInSwift {
            let isGuazi = source.key.caseInsensitiveCompare("guazi") == .orderedSame
            // 瓜子由 GuaziService 直接请求加密接口，不依赖 SourceBean.api；
            // 不能因为远程配置里的旧条目缺少 CMS api 就把它从聚合搜索中过滤掉。
            guard isGuazi || source.isHttpApi else { continue }
            searchableSources.append(source)
        }
        searchableSources = prioritizedSearchSources(searchableSources)
        guard !searchableSources.isEmpty else { return }

        // 多数站点使用不同域名，适当提高并发可以显著降低首屏等待；
        // URLSession 仍会按 host 自己限流，不会把同一站点打爆。
        let concurrency = min(12, searchableSources.count)
        await withTaskGroup(of: (Int, [Movie.Video], String?).self) { group in
            var nextIndex = 0
            for _ in 0..<concurrency {
                let index = nextIndex
                nextIndex += 1
                group.addTask { [self] in
                    do {
                        let videos = try await self.search(sourceBean: searchableSources[index], keyword: keyword)
                        return (index, videos, nil)
                    } catch is CancellationError {
                        return (index, [], nil)
                    } catch {
                        let isGuazi = searchableSources[index].key.caseInsensitiveCompare("guazi") == .orderedSame
                        return (index, [], isGuazi ? error.localizedDescription : nil)
                    }
                }
            }

            var seen = Set<String>()
            while let result = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }

                let (sourceIndex, videos, errorMessage) = result
                if let errorMessage {
                    await onSourceError(searchableSources[sourceIndex].key, errorMessage)
                }
                var batch: [Movie.Video] = []
                for video in videos {
                    let identity: String
                    if !video.id.isEmpty {
                        identity = "\(video.sourceKey)|id:\(video.id)"
                    } else {
                        identity = "\(video.sourceKey)|name:\(normalizeSearchText(video.name))"
                    }
                    guard seen.insert(identity).inserted else { continue }
                    batch.append(video)
                }
                if !batch.isEmpty {
                    await onResults(batch)
                }

                guard !Task.isCancelled, nextIndex < searchableSources.count else {
                    if Task.isCancelled { group.cancelAll() }
                    continue
                }
                let index = nextIndex
                nextIndex += 1
                group.addTask { [self] in
                    do {
                        let videos = try await self.search(sourceBean: searchableSources[index], keyword: keyword)
                        return (index, videos, nil)
                    } catch is CancellationError {
                        return (index, [], nil)
                    } catch {
                        let isGuazi = searchableSources[index].key.caseInsensitiveCompare("guazi") == .orderedSame
                        return (index, [], isGuazi ? error.localizedDescription : nil)
                    }
                }
            }

            group.cancelAll()
        }
    }

    /// 让瓜子和首选资源站在首批并发中启动，避免配置列表末尾的源被多轮请求拖延。
    private func prioritizedSearchSources(_ sources: [SourceBean]) -> [SourceBean] {
        SearchSourceGroup.sorted(sources, sourceKey: \.key, sourceName: \.name)
    }

    /// 对源返回结果做本地关键词过滤，规避部分接口返回推荐/无关内容。
    private func filterSearchResults(_ videos: [Movie.Video], keyword: String) -> [Movie.Video] {
        let tokens = keyword
            .split(whereSeparator: \.isWhitespace)
            .map { normalizeSearchText(String($0)) }
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { return videos }

        return videos.filter { video in
            guard !video.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
            let searchableText = normalizeSearchText([
                video.name,
                video.note,
                video.actor,
                video.director,
                video.type,
                video.area,
                video.year
            ].joined(separator: " "))
            guard !searchableText.isEmpty else { return false }
            return tokens.allSatisfy { searchableText.contains($0) }
        }
    }

    private func normalizeSearchText(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        let scalars = folded.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
            !CharacterSet.punctuationCharacters.contains(scalar) &&
            !CharacterSet.symbols.contains(scalar)
        }
        return String(String.UnicodeScalarView(scalars)).lowercased()
    }

    // MARK: - Extend 解析

    /// 解析 extend 参数（对应 Android 端 getFixUrl）
    /// 如果 extend 是 HTTP URL，则下载其内容作为 extend 值
    /// 如果 extend 是普通字符串，则直接返回
    private func resolveExtend(
        _ extend: String,
        timeout: Int? = nil,
        maxRetries: Int = NetworkManager.defaultMaxRetries
    ) async -> String {
        guard !extend.isEmpty else { return "" }

        // 非 HTTP URL 直接返回
        guard extend.hasPrefix("http://") || extend.hasPrefix("https://") else {
            return extend
        }

        // 从 HTTP URL 加载 extend 内容
        do {
            let content = try await network.getString(from: extend, timeout: timeout, maxRetries: maxRetries)
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            // 如果内容过长（>2500），回退到使用原始 URL
            if trimmed.count > 2500 { return extend }
            return trimmed
        } catch {
            return extend
        }
    }

    private enum ResponseExpectation {
        case any
        case catalog
    }

    private func normalizedResponse(_ response: String, sourceBean: SourceBean) -> String {
        guard isKktvsSource(sourceBean) else { return response }
        return KktvsResponseNormalizer.normalize(response)
    }

    private func getString(
        from url: String,
        sourceBean: SourceBean,
        expectation: ResponseExpectation = .any
    ) async throws -> String {
        let response = try await network.getString(
            from: url,
            headers: sourceBean.headers,
            timeout: min(max(sourceBean.timeout ?? 8, 3), 12),
            maxRetries: 1
        )
        try validateResponse(response, sourceBean: sourceBean, expectation: expectation)
        return response
    }

    /// 搜索专用请求策略：比列表请求略宽容，容纳响应较慢的资源站。
    private func getSearchString(from url: String, sourceBean: SourceBean) async throws -> String {
        let configuredTimeout = sourceBean.timeout ?? 12
        let timeout = min(max(configuredTimeout, 6), 12)
        let response = try await network.getString(
            from: url,
            headers: sourceBean.headers,
            timeout: timeout,
            maxRetries: 1
        )
        try validateResponse(response, sourceBean: sourceBean, expectation: .catalog)
        return response
    }

    private func getPlaybackPage(from url: String, sourceBean: SourceBean) async throws -> String {
        let headers = playbackHeaders(for: sourceBean, mediaURL: url)
        return try await network.getString(
            from: url,
            headers: headers,
            timeout: min(max(sourceBean.timeout ?? 8, 5), 15),
            maxRetries: 1
        )
    }

    func playbackHeaders(for sourceBean: SourceBean, mediaURL: String) -> [String: String] {
        var headers = defaultPlaybackHeaders(for: mediaURL)
        if SearchSourceGroup.classify(sourceKey: sourceBean.key, sourceName: sourceBean.name) == .jianpian {
            headers["User-Agent"] = "Mozilla/5.0 packageName:com.jp3.xg3"
            headers["Referer"] = "https://fan123.hzhnl.com/"
            headers["Accept"] = "*/*"
        }
        // URLRequest 的请求头不区分大小写，但 Swift Dictionary 区分；
        // 先移除同名的默认项，确保配置中的自定义值稳定覆盖默认值。
        sourceBean.headers?.forEach { key, value in
            headers.keys
                .filter { $0.caseInsensitiveCompare(key) == .orderedSame }
                .forEach { headers.removeValue(forKey: $0) }
            headers[key] = value
        }
        return headers
    }

    private func defaultPlaybackHeaders(for url: String) -> [String: String] {
        var headers = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        ]

        guard let components = URLComponents(string: url),
              let scheme = components.scheme,
              let host = components.host,
              !scheme.isEmpty,
              !host.isEmpty else {
            return headers
        }

        var origin = "\(scheme)://\(host)"
        if let port = components.port {
            origin += ":\(port)"
        }
        headers["Referer"] = origin + "/"
        return headers
    }

    private func validateResponse(
        _ response: String,
        sourceBean: SourceBean,
        expectation: ResponseExpectation
    ) throws {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SourceError.invalidResponse("站点返回空响应")
        }

        let lowercased = trimmed.lowercased()
        let htmlMarkers = [
            "<!doctype html", "<html", "<head", "<body", "cloudflare",
            "access denied", "just a moment", "502 bad gateway", "404 not found"
        ]
        if htmlMarkers.contains(where: { lowercased.contains($0) }) {
            throw SourceError.invalidResponse("站点返回了 HTML 或错误页面")
        }

        guard expectation == .catalog else { return }
        if sourceBean.type == 0 {
            guard lowercased.contains("<rss") || lowercased.contains("<root") ||
                    lowercased.contains("<class") || lowercased.contains("<ty") ||
                    lowercased.contains("<video") else {
                throw SourceError.invalidResponse("XML 响应缺少影视数据结构")
            }
        } else {
            guard let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  object is [String: Any] else {
                throw SourceError.invalidResponse("站点返回的不是有效 JSON")
            }
        }
    }

    private func isKktvsSource(_ sourceBean: SourceBean) -> Bool {
        sourceBean.key.caseInsensitiveCompare("kktvs") == .orderedSame
            || sourceBean.api.range(of: "kktvs.com", options: [.caseInsensitive]) != nil
    }

    private func isDyttSource(_ sourceBean: SourceBean) -> Bool {
        let identity = "\(sourceBean.key) \(sourceBean.name) \(sourceBean.api)".lowercased()
        return identity.contains("dytt") || identity.contains("电影天堂")
    }

    /// 电影天堂存在可解析页和 m3u8 两条线路，点播端只保留稳定的 dyttm3u8。
    private func filteredPlaybackLines(
        playFrom: String,
        playUrl: String,
        sourceBean: SourceBean
    ) -> (playFrom: String, playUrl: String) {
        let flags = playFrom.components(separatedBy: "$$$")
        let urls = playUrl.components(separatedBy: "$$$")

        // 某些 CMS 将解析页线路放在第一条、直链 m3u8 放在后面。
        // 先稳定地把可直接播放或可提取媒体的线路排前，避免详情页默认
        // 选择一个只能在网页中播放的地址。相同优先级保持源站顺序。
        var paired = flags.indices.compactMap { index -> (flag: String, url: String, index: Int)? in
            guard urls.indices.contains(index) else { return nil }
            let flag = flags[index].trimmingCharacters(in: .whitespacesAndNewlines)
            let url = urls[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !flag.isEmpty, !url.isEmpty else { return nil }
            return (flag, url, index)
        }

        // 这些源同时返回网页解析线路和 m3u8 线路。点播端按安卓配置只保留
        // 指定的稳定线路，并始终从同一条记录取 flag 与 URL，避免串线。
        if let requiredFlag = requiredPlaybackFlag(for: sourceBean) {
            paired = paired.filter {
                $0.flag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == requiredFlag
            }
            guard !paired.isEmpty else { return ("", "") }
        }
        let ordered = paired.sorted { lhs, rhs in
            let leftPriority = playbackLinePriority(lhs.url)
            let rightPriority = playbackLinePriority(rhs.url)
            if leftPriority != rightPriority { return leftPriority < rightPriority }
            return lhs.index < rhs.index
        }

        let orderedFlags = ordered.map(\.flag)
        let orderedURLs = ordered.map(\.url)
        let normalizedPlayFrom = orderedFlags.isEmpty ? playFrom : orderedFlags.joined(separator: "$$$")
        let normalizedPlayUrl = orderedURLs.isEmpty ? playUrl : orderedURLs.joined(separator: "$$$")

        guard isDyttSource(sourceBean) else {
            return (normalizedPlayFrom, normalizedPlayUrl)
        }

        let filteredFlags = normalizedPlayFrom.components(separatedBy: "$$$")
        let filteredURLs = normalizedPlayUrl.components(separatedBy: "$$$")
        guard let index = filteredFlags.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "dyttm3u8"
        }), filteredURLs.indices.contains(index) else {
            return ("", "")
        }
        return ("dyttm3u8", filteredURLs[index])
    }

    private func playbackLinePriority(_ rawURL: String) -> Int {
        let normalized = KktvsResponseNormalizer.normalizeMediaURL(rawURL)
        if KktvsResponseNormalizer.directMediaURL(normalized) != nil { return 0 }
        let lowercased = normalized.lowercased()
        if lowercased.contains("/play/") || lowercased.contains("player") || lowercased.contains("parse") {
            return 1
        }
        return 2
    }

    private func requiredPlaybackFlag(for sourceBean: SourceBean) -> String? {
        let identity = "\(sourceBean.key) \(sourceBean.name) \(sourceBean.api)".lowercased()
        if identity.contains("subo") || identity.contains("速播") { return "subm3u8" }
        if identity.contains("juliang") || identity.contains("巨量") { return "jlm3u8" }
        if identity.contains("uku") || identity.contains("u酷") { return "ukm3u8" }
        return nil
    }

    private func parseXMLDetail(_ xml: String, sourceKey: String) -> VodInfo? {
        guard let videoBlock = firstMatch(
            pattern: #"<video[\s\S]*?</video>"#,
            in: xml
        ) else {
            return nil
        }

        let vodId = extractXMLTag("id", in: videoBlock)
        guard !vodId.isEmpty else { return nil }

        var video = Movie.Video(id: vodId)
        video.name = extractXMLTag("name", in: videoBlock)
        video.pic = extractXMLTag("pic", in: videoBlock)
        video.note = extractXMLTag("note", in: videoBlock)
        video.year = extractXMLTag("year", in: videoBlock)
        video.area = extractXMLTag("area", in: videoBlock)
        video.type = extractXMLTag("type", in: videoBlock)
        video.director = extractXMLTag("director", in: videoBlock)
        video.actor = extractXMLTag("actor", in: videoBlock)
        video.des = extractXMLTag("des", in: videoBlock)
        video.sourceKey = sourceKey

        let ddNodes = extractXMLDDNodes(from: videoBlock)
        let playFrom: String
        let playUrl: String

        if ddNodes.isEmpty {
            playFrom = "默认"
            playUrl = ""
        } else {
            playFrom = ddNodes.map { $0.flag }.joined(separator: "$$$")
            playUrl = ddNodes.map { $0.url }.joined(separator: "$$$")
        }

        return VodInfo.from(video: video, playFrom: playFrom, playUrl: playUrl)
    }

    private func extractXMLDDNodes(from block: String) -> [(flag: String, url: String)] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<dd([^>]*)>([\s\S]*?)</dd>"#,
            options: [.caseInsensitive]
        ) else {
            return []
        }

        let nsRange = NSRange(block.startIndex..<block.endIndex, in: block)
        let matches = regex.matches(in: block, range: nsRange)
        var result: [(flag: String, url: String)] = []

        for (index, match) in matches.enumerated() {
            guard match.numberOfRanges >= 3 else { continue }
            guard let attrRange = Range(match.range(at: 1), in: block),
                  let valueRange = Range(match.range(at: 2), in: block) else {
                continue
            }

            let attrs = String(block[attrRange])
            let rawUrl = decodeXMLText(String(block[valueRange]))
            guard !rawUrl.isEmpty else { continue }

            let flag = firstMatch(
                pattern: #"flag\s*=\s*["']([^"']+)["']"#,
                in: attrs,
                captureGroup: 1
            ) ?? "线路\(index + 1)"
            result.append((flag: decodeXMLText(flag), url: rawUrl))
        }

        return result
    }

    private func extractXMLTag(_ tag: String, in content: String) -> String {
        let escapedTag = NSRegularExpression.escapedPattern(for: tag)
        let pattern = "<\(escapedTag)>\\s*([\\s\\S]*?)\\s*</\(escapedTag)>"
        let value = firstMatch(pattern: pattern, in: content, captureGroup: 1) ?? ""
        return decodeXMLText(value)
    }

    private func firstMatch(pattern: String, in content: String, captureGroup: Int = 0) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        guard let match = regex.firstMatch(in: content, options: [], range: range),
              match.numberOfRanges > captureGroup,
              let subRange = Range(match.range(at: captureGroup), in: content) else {
            return nil
        }
        return String(content[subRange])
    }

    private func decodeXMLText(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("<![CDATA["), value.hasSuffix("]]>"), value.count >= 12 {
            value.removeFirst(9)
            value.removeLast(3)
        }
        value = value.replacingOccurrences(of: "&amp;", with: "&")
        value = value.replacingOccurrences(of: "&lt;", with: "<")
        value = value.replacingOccurrences(of: "&gt;", with: ">")
        value = value.replacingOccurrences(of: "&quot;", with: "\"")
        value = value.replacingOccurrences(of: "&#39;", with: "'")
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func buildURL(base: String, queryItems: [URLQueryItem]) throws -> String {
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmedBase) else {
            throw SourceError.invalidApiUrl(base)
        }

        var mergedQueryItems = components.queryItems ?? []
        mergedQueryItems.append(contentsOf: queryItems)
        components.queryItems = mergedQueryItems

        guard let url = components.url else {
            throw SourceError.invalidApiUrl(base)
        }
        return url.absoluteString
    }

    private func buildSearchURL(base: String, queryItems: [URLQueryItem]) throws -> String {
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmedBase) else {
            throw SourceError.invalidApiUrl(base)
        }
        let replacedNames = Set(queryItems.map { $0.name.lowercased() }).union(["wd", "ac"])
        let preserved = (components.queryItems ?? []).filter {
            !replacedNames.contains($0.name.lowercased())
        }
        components.queryItems = preserved + queryItems
        guard let url = components.url else { throw SourceError.invalidApiUrl(base) }
        return url.absoluteString
    }
}

enum SourceError: LocalizedError {
    case emptyApi
    case parseError(String)
    case invalidResponse(String)
    case invalidPlayableURL(String)
    case unsupportedType(String)
    case invalidApiUrl(String)

    var errorDescription: String? {
        switch self {
        case .emptyApi: return "接口地址为空"
        case .parseError(let msg): return "数据解析错误: \(msg)"
        case .invalidResponse(let msg): return "站点响应无效: \(msg)"
        case .invalidPlayableURL(let url): return "播放地址无效: \(url)"
        case .unsupportedType(let type): return "暂不支持 \(type) 类型的数据源，请切换其他源"
        case .invalidApiUrl(let url): return "无效的接口地址: \(url)"
        }
    }
}
