import Foundation

enum JianpianSourceService {
    private static let origin = "https://fan123.hzhnl.com"
    private static let headers = [
        "Accept": "application/json",
        "Referer": origin,
        "User-Agent": "Mozilla/5.0 packageName:com.jp3.xg3"
    ]

    static func search(keyword: String) async throws -> [Movie.Video] {
        let response = try await request(
            path: "/api/v2/search/videoV2",
            query: [
                URLQueryItem(name: "key", value: keyword),
                URLQueryItem(name: "category_id", value: "88"),
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "pageSize", value: "20")
            ]
        )
        let rows = array(in: response, keys: ["data", "items", "list"])
        return rows.compactMap { element in
            guard let item = object(element, wrappers: ["work", "vod"]) else { return nil }
            let video = mapVideo(item)
            return video.id.isEmpty ? nil : video
        }
    }

    static func detail(vodID: String) async throws -> VodInfo {
        let response = try await request(
            path: "/api/video/detailv2",
            query: [URLQueryItem(name: "id", value: vodID)]
        )
        let source = object(response["data"], wrappers: []) ?? response
        let video = mapVideo(source)
        var flags: [String] = []
        var lines: [[VodInfo.Episode]] = []
        appendRoutes(source["source_list_source"], flags: &flags, lines: &lines)
        appendRoutes(source["vip_source_list_source"], flags: &flags, lines: &lines)

        let ftpEpisodes = episodes(from: source["ftp_list"])
        if !ftpEpisodes.isEmpty {
            flags.append("FTP线路")
            lines.append(ftpEpisodes)
        }

        let playFrom = flags.joined(separator: "$$$")
        let playURL = lines.map { line in
            line.map { "\($0.name)$\($0.url)" }.joined(separator: "#")
        }.joined(separator: "$$$")
        return VodInfo.from(video: video, playFrom: playFrom, playUrl: playURL)
    }

    private static func request(path: String, query: [URLQueryItem]) async throws -> [String: Any] {
        var components = URLComponents(string: origin + path)
        components?.queryItems = query
        guard let url = components?.url?.absoluteString else {
            throw SourceError.invalidApiUrl(origin + path)
        }
        let text = try await NetworkManager.shared.getString(from: url, headers: headers, maxRetries: 1)
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SourceError.invalidResponse("荐片接口响应格式无效")
        }
        return value
    }

    private static func mapVideo(_ source: [String: Any]) -> Movie.Video {
        let id = string(source, keys: ["id", "work_id", "video_id"])
        var video = Movie.Video(id: id, name: string(source, keys: ["title", "name", "original_name"]))
        video.pic = image(string(source, keys: ["thumbnail", "tvimg", "poster_url", "cover_url"]))
        video.year = string(source, keys: ["year", "release_year"])
        if video.year.isEmpty, let years = source["years"] as? [[String: Any]], let year = years.first {
            video.year = string(year, keys: ["year", "name"])
        }
        video.area = names(source, keys: ["areas", "area", "region"])
        video.actor = names(source, keys: ["actors", "actor"])
        video.director = names(source, keys: ["directors", "director"])
        video.type = names(source, keys: ["types", "category", "kind"])
        video.doubanRating = string(source, keys: ["score", "rating"])
        video.note = firstNonEmpty(
            string(source, keys: ["mask", "remarks", "badge"]),
            string(source, keys: ["episodes_count"])
        )
        video.des = string(source, keys: ["description", "synopsis", "summary", "content"])
        video.sourceKey = "jianpian"
        return video
    }

    private static func appendRoutes(_ value: Any?, flags: inout [String], lines: inout [[VodInfo.Episode]]) {
        for element in value as? [Any] ?? [] {
            guard let route = object(element, wrappers: ["line", "provider"]) else { continue }
            let name = firstNonEmpty(string(route, keys: ["name", "source_name", "title"]), "荐片线路")
            let routeEpisodes = episodes(from: route["source_list"] ?? route["episodes"])
            guard !routeEpisodes.isEmpty else { continue }
            if let index = flags.firstIndex(of: name) {
                let known = Set(lines[index].map(\.url))
                lines[index].append(contentsOf: routeEpisodes.filter { !known.contains($0.url) })
            } else {
                flags.append(name)
                lines.append(routeEpisodes)
            }
        }
    }

    private static func episodes(from value: Any?) -> [VodInfo.Episode] {
        var result: [VodInfo.Episode] = []
        var seen = Set<String>()
        for element in value as? [Any] ?? [] {
            guard let episode = object(element, wrappers: ["episode", "item"]) else { continue }
            let url = string(episode, keys: ["url", "play_url", "playback_url", "media_url"])
            guard !url.isEmpty, seen.insert(url).inserted else { continue }
            var name = string(episode, keys: ["source_name", "weight", "name", "title", "sort"])
            if name.isEmpty { name = "第\(result.count + 1)集" }
            else if Int(name) != nil { name = "第\(name)集" }
            result.append(VodInfo.Episode(name: name, url: url))
        }
        return result
    }

    private static func array(in object: [String: Any], keys: [String]) -> [Any] {
        for key in keys {
            if let value = object[key] as? [Any] { return value }
        }
        return []
    }

    private static func object(_ value: Any?, wrappers: [String]) -> [String: Any]? {
        guard var object = value as? [String: Any] else { return nil }
        for key in wrappers {
            if let nested = object[key] as? [String: Any] { object = nested; break }
        }
        return object
    }

    private static func names(_ object: [String: Any], keys: [String]) -> String {
        for key in keys {
            guard let value = object[key] else { continue }
            if let text = value as? String, !text.isEmpty, !text.hasPrefix("[") { return text }
            if let values = value as? [Any] {
                let result = values.compactMap { item -> String? in
                    if let item = item as? String { return item }
                    guard let item = item as? [String: Any] else { return nil }
                    return firstNonEmpty(string(item, keys: ["name", "title", "area"]), "")
                }.filter { !$0.isEmpty }
                if !result.isEmpty { return result.joined(separator: ",") }
            }
        }
        return ""
    }

    private static func string(_ object: [String: Any], keys: [String]) -> String {
        for key in keys {
            guard let value = object[key], !(value is NSNull) else { continue }
            if let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let value = value as? NSNumber { return value.stringValue }
        }
        return ""
    }

    private static func image(_ value: String) -> String {
        guard !value.isEmpty else { return "" }
        if value.hasPrefix("http://") || value.hasPrefix("https://") { return value }
        return "https://img.ypfbj.com" + (value.hasPrefix("/") ? value : "/" + value)
    }

    private static func firstNonEmpty(_ values: String...) -> String {
        values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    }
}
