import Foundation

/// 豆瓣热门影视条目，供首页推荐和搜索热榜使用。
struct DoubanTrendingItem: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let cover: String
    let rating: String
    let type: String
    let year: String
}

/// 豆瓣移动端热门影视服务。
/// 请求失败时返回空数组，不影响 TVBox 的片源、详情和播放链路。
final class DoubanTrendingService: @unchecked Sendable {
    static let shared = DoubanTrendingService()

    private let network = NetworkManager.shared
    private let baseURL = "https://m.douban.com/rexxar/api/v2/subject/recent_hot"
    private let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private init() {}

    /// 获取豆瓣当前热门电影和剧集，按接口返回顺序去重。
    func fetchTrending(limit: Int = 20) async -> [DoubanTrendingItem] {
        let count = min(max(limit, 1), 50)
        async let movies = fetch(kind: "movie", type: "电影", limit: count)
        async let tv = fetch(kind: "tv", type: "电视剧", limit: count)
        let combined = await (movies, tv)

        var seen = Set<String>()
        return (combined.0 + combined.1).filter { item in
            let key = item.id.isEmpty ? item.title : item.id
            guard !key.isEmpty, seen.insert(key).inserted else { return false }
            return !item.title.isEmpty
        }
    }

    private func fetch(kind: String, type: String, limit: Int) async -> [DoubanTrendingItem] {
        guard var components = URLComponents(string: "\(baseURL)/\(kind)") else { return [] }
        components.queryItems = [
            URLQueryItem(name: "start", value: "0"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "category", value: "热门"),
            URLQueryItem(name: "type", value: kind == "movie" ? "全部" : "show")
        ]
        guard let url = components.url else { return [] }

        do {
            let text = try await network.getString(
                from: url.absoluteString,
                headers: [
                    "User-Agent": userAgent,
                    "Referer": kind == "movie" ? "https://movie.douban.com/explore" : "https://movie.douban.com/tv/",
                    "Accept": "application/json, text/plain, */*"
                ],
                maxRetries: 1
            )
            guard let data = text.data(using: .utf8) else { return [] }
            return parse(data: data, fallbackType: type)
        } catch {
            return []
        }
    }

    private func parse(data: Data, fallbackType: String) -> [DoubanTrendingItem] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let dictionaries: [[String: Any]]
        if let root = object as? [String: Any], let items = root["items"] as? [[String: Any]] {
            dictionaries = items
        } else if let items = object as? [[String: Any]] {
            dictionaries = items
        } else {
            return []
        }

        return dictionaries.compactMap { item in
            let id = string(item["id"])
            let title = string(item["title"])
            guard !title.isEmpty else { return nil }
            let pic = item["pic"] as? [String: Any]
            let candidates = [string(pic?["normal"]), string(pic?["large"]), string(item["cover_url"])]
            guard let cover = candidates.first(where: { !$0.isEmpty }),
                  URL(string: normalizeImageURL(cover)) != nil else { return nil }
            let rating = item["rating"] as? [String: Any]
            let ratingValue = rating.map { string($0["value"]) } ?? string(item["rating"])
            let itemType = string(item["type"])
            return DoubanTrendingItem(
                id: id,
                title: title,
                cover: normalizeImageURL(cover),
                rating: Movie.Video.formatDoubanRating(ratingValue),
                type: itemType.isEmpty ? fallbackType : itemType,
                year: string(item["year"])
            )
        }
    }

    private func string(_ value: Any?) -> String {
        if let value = value as? String { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }

    private func normalizeImageURL(_ value: String) -> String {
        value.hasPrefix("//") ? "https:\(value)" : value
    }
}
