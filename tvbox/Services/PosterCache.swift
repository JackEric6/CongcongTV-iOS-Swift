import Foundation

/// 跨源共享海报缓存。
///
/// CMS 源经常只返回片名而不返回 vod_pic。缓存按规范化片名索引，
/// 这样另一个源先返回海报时，之前缺图的同名结果也可以被补齐。
actor PosterCache {
    static let shared = PosterCache()

    private var posters: [String: String] = [:]

    private static let persistedKey = "congcong.poster-cache.v2"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.persistedKey),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            posters = saved
        }
    }

    /// 用于同名影视合并海报，不包含标点、空白和大小写差异。
    nonisolated static func key(for title: String) -> String {
        let folded = title.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        let scalars = folded.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
                && !CharacterSet.punctuationCharacters.contains($0)
                && !CharacterSet.symbols.contains($0)
        }
        return String(String.UnicodeScalarView(scalars)).lowercased()
    }

    /// 返回标准化且可加载的 HTTP(S) 海报地址。
    nonisolated static func normalizedURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate = trimmed.hasPrefix("//") ? "https:\(trimmed)" : trimmed
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else { return nil }

        // 使用项目已有的图片 URL 规范化逻辑处理防盗链域名。
        return URL.posterURL(from: candidate)?.absoluteString ?? candidate
    }

    /// 这些地址经常能通过 URL 校验，但实际请求会长期超时或返回防盗链页面。
    /// 若同名影视存在其他来源的图片，应优先使用其他来源，避免暴风源坏图卡住整个卡片。
    nonisolated static func isLikelyBroken(_ raw: String, sourceKey: String = "") -> Bool {
        let value = raw.lowercased()
        let source = sourceKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return source == "bfzy"
            || source.contains("baofeng")
            || value.contains("img.picbf.com")
            || value.contains("picbf.com")
    }

    /// 供历史/收藏等同步视图读取最近一次成功复用的海报。
    /// 该方法只读 UserDefaults，不会改变视频的 sourceKey、id 或播放配置。
    nonisolated static func cachedPoster(for title: String) -> String? {
        guard let data = UserDefaults.standard.data(forKey: Self.persistedKey),
              let saved = try? JSONDecoder().decode([String: String].self, from: data),
              let value = saved[key(for: title)],
              normalizedURL(value) != nil,
              !isLikelyBroken(value) else { return nil }
        return value
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(posters) else { return }
        UserDefaults.standard.set(data, forKey: Self.persistedKey)
    }

    /// 记录一个源返回的海报。已有有效海报不会被空值或新值覆盖。
    func remember(title: String, poster: String, sourceKey: String = "") -> String? {
        let titleKey = Self.key(for: title)
        guard !titleKey.isEmpty, let normalized = Self.normalizedURL(poster) else {
            return posters[titleKey]
        }
        if let existing = posters[titleKey], Self.normalizedURL(existing) != nil {
            // 坏的暴风图不能锁死同名影片；后续返回的正常海报应覆盖它。
            if Self.isLikelyBroken(existing), !Self.isLikelyBroken(poster, sourceKey: sourceKey) {
                posters[titleKey] = normalized
                persist()
                return normalized
            }
            return existing
        }
        posters[titleKey] = normalized
        persist()
        return normalized
    }

    /// 取同名影视已经缓存的海报。
    func poster(for title: String) -> String? {
        let value = posters[Self.key(for: title)]
        guard let value,
              Self.normalizedURL(value) != nil,
              !Self.isLikelyBroken(value) else { return nil }
        return value
    }

    /// 记录当前批次已有的合法海报，并为同名缺图条目补齐缓存海报。
    /// 与 `enrich` 不同，此方法不会隐藏仍然没有海报的条目，适用于首页。
    func fill(_ videos: [Movie.Video]) -> [Movie.Video] {
        for video in videos {
            if Self.normalizedURL(video.pic) != nil {
                _ = remember(title: video.name, poster: video.pic, sourceKey: video.sourceKey)
            }
        }

        return videos.map { video in
            var filled = video
            if Self.normalizedURL(filled.pic) == nil,
               let poster = posters[Self.key(for: filled.name)],
               Self.normalizedURL(poster) != nil {
                filled.pic = poster
            }
            return filled
        }
    }

    /// 为搜索结果补齐同名海报，并隐藏仍然没有可用海报的结果。
    func enrich(_ videos: [Movie.Video]) -> [Movie.Video] {
        for video in videos {
            if Self.normalizedURL(video.pic) != nil {
                _ = remember(title: video.name, poster: video.pic, sourceKey: video.sourceKey)
            }
        }

        return videos.compactMap { video in
            var enriched = video
            let ownPoster = Self.normalizedURL(video.pic)
            let cached = posters[Self.key(for: video.name)]
            let canUseCached = cached != nil
                && Self.normalizedURL(cached ?? "") != nil
                && !Self.isLikelyBroken(cached ?? "")
                && (ownPoster == nil || Self.isLikelyBroken(video.pic, sourceKey: video.sourceKey))
            let poster = canUseCached ? cached : (ownPoster ?? cached)
            guard let poster, Self.normalizedURL(poster) != nil else { return nil }
            // 没有可复用的正常海报时，隐藏已知会卡住的暴风图片。
            let selectedPosterIsBroken = canUseCached
                ? Self.isLikelyBroken(poster)
                : Self.isLikelyBroken(video.pic, sourceKey: video.sourceKey)
            guard !selectedPosterIsBroken else { return nil }
            enriched.pic = poster
            return enriched
        }
    }
}
