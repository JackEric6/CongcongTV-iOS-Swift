import Foundation

/// 跨源共享海报缓存。
///
/// CMS 源经常只返回片名而不返回 vod_pic。缓存按规范化片名索引，
/// 这样另一个源先返回海报时，之前缺图的同名结果也可以被补齐。
actor PosterCache {
    static let shared = PosterCache()

    private var posters: [String: String] = [:]

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

    /// 记录一个源返回的海报。已有有效海报不会被空值或新值覆盖。
    func remember(title: String, poster: String) -> String? {
        let titleKey = Self.key(for: title)
        guard !titleKey.isEmpty, let normalized = Self.normalizedURL(poster) else {
            return posters[titleKey]
        }
        if let existing = posters[titleKey], Self.normalizedURL(existing) != nil {
            return existing
        }
        posters[titleKey] = normalized
        return normalized
    }

    /// 取同名影视已经缓存的海报。
    func poster(for title: String) -> String? {
        let value = posters[Self.key(for: title)]
        guard let value, Self.normalizedURL(value) != nil else { return nil }
        return value
    }

    /// 记录当前批次已有的合法海报，并为同名缺图条目补齐缓存海报。
    /// 与 `enrich` 不同，此方法不会隐藏仍然没有海报的条目，适用于首页。
    func fill(_ videos: [Movie.Video]) -> [Movie.Video] {
        for video in videos {
            if Self.normalizedURL(video.pic) != nil {
                _ = remember(title: video.name, poster: video.pic)
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
                _ = remember(title: video.name, poster: video.pic)
            }
        }

        return videos.compactMap { video in
            var enriched = video
            let poster = Self.normalizedURL(video.pic) ?? posters[Self.key(for: video.name)]
            guard let poster, Self.normalizedURL(poster) != nil else { return nil }
            enriched.pic = poster
            return enriched
        }
    }
}
