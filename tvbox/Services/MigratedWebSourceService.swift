import Foundation

enum MigratedWebSourceService {
    private static let ikanbotAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/128.0.0.0 Safari/537.36"
    private static let anchorPattern = try! NSRegularExpression(
        pattern: #"(?is)<a\b([^>]*)>(.*?)</a\s*>"#
    )

    static func searchIkanbot(source: SourceBean, keyword: String) async throws -> [Movie.Video] {
        guard let origin = URL(string: source.api),
              var components = URLComponents(url: origin.appendingPathComponent("search"), resolvingAgainstBaseURL: false) else {
            throw SourceError.invalidApiUrl(source.api)
        }
        components.queryItems = [URLQueryItem(name: "q", value: keyword)]
        guard let url = components.url else { throw SourceError.invalidApiUrl(source.api) }
        let html = try await fetch(url, headers: browserHeaders(for: source, referer: origin.absoluteString))
        let titleAnchors = anchorMatches(in: html).filter {
            attribute("class", in: $0.attributes)?.contains("title-text") == true
        }
        var seen = Set<String>()
        var videos: [Movie.Video] = []
        for anchor in titleAnchors {
            guard let path = attribute("href", in: anchor.attributes),
                  let id = ikanbotID(path), seen.insert(id).inserted else { continue }
            let imagePattern = #"(?is)<img\b[^>]*\bid=["']\#(NSRegularExpression.escapedPattern(for: id))["'][^>]*>"#
            let image = capture(imagePattern, in: html, group: 0) ?? ""
            let title = text(anchor.body)
            guard !title.isEmpty else { continue }
            var video = Movie.Video(id: id, name: title)
            video.pic = absoluteURL(
                attribute("data-src", in: image) ?? attribute("src", in: image) ?? "",
                relativeTo: url
            )
            video.year = firstMatch(#"(?:19|20)\d{2}"#, in: title) ?? ""
            video.sourceKey = source.key
            videos.append(video)
            if videos.count >= 20 { break }
        }
        return videos
    }

    static func detailIkanbot(source: SourceBean, vodID: String) async throws -> VodInfo {
        let id = vodID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty,
              let origin = URL(string: source.api),
              let detailURL = URL(string: "/play/\(id)", relativeTo: origin)?.absoluteURL else {
            throw SourceError.invalidPlayableURL(vodID)
        }
        let headers = browserHeaders(for: source, referer: origin.absoluteString)
        let html = try await fetch(detailURL, headers: headers)
        let title = firstNonEmpty(
            capture(#"(?is)<[^>]+\bid=["']video_title["'][^>]*>(.*?)</[^>]+>"#, in: html).map(text),
            attribute("content", in: capture(#"(?is)<meta\b[^>]*property=["']og:title["'][^>]*>"#, in: html, group: 0) ?? ""),
            "爱看影片 \(id)"
        )
        let cover = capture(#"(?is)<img\b[^>]*class=["'][^"']*\bcover\b[^"']*["'][^>]*>"#, in: html, group: 0) ?? ""
        let descriptionTag = capture(#"(?is)<meta\b[^>]*name=["']description["'][^>]*>"#, in: html, group: 0) ?? ""
        let metadata = captures(#"(?is)<[^>]+class=["'][^"']*\bmeta\b[^"']*["'][^>]*>(.*?)</[^>]+>"#, in: html)
            .map(text)
            .filter { !$0.isEmpty }

        var video = Movie.Video(id: id, name: title)
        video.pic = absoluteURL(attribute("data-src", in: cover) ?? attribute("src", in: cover) ?? "", relativeTo: detailURL)
        video.note = "爱看线路"
        if metadata.count > 2 { video.year = firstMatch(#"(?:19|20)\d{2}"#, in: metadata[2]) ?? "" }
        if metadata.count > 3 { video.area = metadata[3] }
        if metadata.count > 4 { video.actor = metadata[4] }
        video.des = attribute("content", in: descriptionTag) ?? ""
        video.sourceKey = source.key

        let eToken = attribute("value", in: capture(#"(?is)<input\b[^>]*\bid=["']e_token["'][^>]*>"#, in: html, group: 0) ?? "") ?? ""
        let mtype = attribute("value", in: capture(#"(?is)<input\b[^>]*\bid=["']mtype["'][^>]*>"#, in: html, group: 0) ?? "") ?? ""
        let token = buildIkanbotToken(videoID: id, eToken: eToken)
        guard !token.isEmpty else { throw SourceError.invalidResponse("爱看播放令牌无效") }

        var apiComponents = URLComponents(url: URL(string: "/api/getResN", relativeTo: origin)!.absoluteURL, resolvingAgainstBaseURL: false)
        apiComponents?.queryItems = [
            URLQueryItem(name: "videoId", value: id),
            URLQueryItem(name: "mtype", value: mtype),
            URLQueryItem(name: "token", value: token)
        ]
        guard let apiURL = apiComponents?.url else { throw SourceError.invalidApiUrl(source.api) }
        var apiHeaders = browserHeaders(for: source, referer: detailURL.absoluteString)
        apiHeaders["Accept"] = "application/json, text/plain, */*"
        apiHeaders["Origin"] = origin.originString
        apiHeaders["X-Requested-With"] = "XMLHttpRequest"
        let response = try await fetch(apiURL, headers: apiHeaders)
        let (flags, playURLs) = parseIkanbotSources(response)
        guard !flags.isEmpty else { throw SourceError.invalidResponse("爱看没有返回 HLS 播放线路") }
        return VodInfo.from(video: video, playFrom: flags.joined(separator: "$$$"), playUrl: playURLs.joined(separator: "$$$"))
    }

    static func searchZanpian(source: SourceBean, keyword: String) async throws -> [Movie.Video] {
        guard let origin = URL(string: source.api),
              let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw SourceError.invalidApiUrl(source.api)
        }
        let escapedKeyword = keyword.addingPercentEncoding(
            withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        ) ?? encoded
        guard let url = URL(string: "/index.php?s=vod-search-wd-\(escapedKeyword)-ajax", relativeTo: origin)?.absoluteURL else {
            throw SourceError.invalidApiUrl(source.api)
        }
        var headers = browserHeaders(for: source, referer: origin.absoluteString)
        headers["Accept"] = "application/json, text/plain, */*"
        headers["X-Requested-With"] = "XMLHttpRequest"
        let response = try await fetch(url, headers: headers)
        let html = htmlPayload(response)
        guard !html.isEmpty else { throw SourceError.invalidResponse("赞片搜索响应缺少 HTML 结果") }
        return parseZanpianCards(html, sourceKey: source.key, baseURL: origin)
    }

    static func detailZanpian(source: SourceBean, vodID: String) async throws -> VodInfo {
        guard let origin = URL(string: source.api),
              let detailURL = URL(string: vodID, relativeTo: origin)?.absoluteURL else {
            throw SourceError.invalidPlayableURL(vodID)
        }
        let html = try await fetch(detailURL, headers: browserHeaders(for: source, referer: origin.absoluteString))
        let pageTitle = capture(#"(?is)<title\b[^>]*>(.*?)</title>"#, in: html).map(text) ?? ""
        let title = firstNonEmpty(
            capture(#"(?is)<h1\b[^>]*>(.*?)</h1>"#, in: html).map(text),
            attribute("content", in: capture(#"(?is)<meta\b[^>]*property=["']og:title["'][^>]*>"#, in: html, group: 0) ?? ""),
            pageTitle
        )
        let imageTag = capture(#"(?is)<meta\b[^>]*property=["']og:image["'][^>]*>"#, in: html, group: 0) ?? ""
        let descriptionTag = capture(#"(?is)<meta\b[^>]*name=["']description["'][^>]*>"#, in: html, group: 0) ?? ""
        var video = Movie.Video(id: vodID, name: title.replacingOccurrences(of: #"\s*[-|｜]\s*(赞片网|ZanPian).*$"#, with: "", options: .regularExpression))
        video.pic = absoluteURL(attribute("content", in: imageTag) ?? "", relativeTo: detailURL)
        video.des = attribute("content", in: descriptionTag) ?? ""
        video.year = firstMatch(#"(?:19|20)\d{2}"#, in: title) ?? ""
        video.sourceKey = source.key

        var episodes: [VodInfo.Episode] = []
        var seen = Set<String>()
        for anchor in anchorMatches(in: html) {
            guard let href = attribute("href", in: anchor.attributes),
                  let episodeURL = URL(string: href, relativeTo: detailURL)?.absoluteURL,
                  episodeURL.host?.caseInsensitiveCompare(detailURL.host ?? "") == .orderedSame,
                  isZanpianEpisode(episodeURL.path, under: detailURL.path),
                  seen.insert(episodeURL.absoluteString).inserted else { continue }
            let name = firstNonEmpty(attribute("title", in: anchor.attributes), text(anchor.body), "第\(episodes.count + 1)集")
            episodes.append(VodInfo.Episode(name: name, url: episodeURL.absoluteString))
            if episodes.count >= 300 { break }
        }
        if episodes.isEmpty,
           let direct = KktvsResponseNormalizer.extractMediaURL(from: html, baseURL: detailURL.absoluteString) {
            episodes.append(VodInfo.Episode(name: "正片", url: direct))
        }
        guard !episodes.isEmpty else { throw SourceError.invalidResponse("赞片详情页没有可播放剧集") }
        let playURL = episodes.map { "\($0.name)$\($0.url)" }.joined(separator: "#")
        return VodInfo.from(video: video, playFrom: "赞片线路", playUrl: playURL)
    }

    static func buildIkanbotToken(videoID: String, eToken: String) -> String {
        guard videoID.count >= 4, eToken.count >= 8 else { return "" }
        var remainder = eToken
        var token = ""
        for digit in videoID.suffix(4) {
            guard let value = digit.wholeNumberValue else { return "" }
            let offset = value % 3 + 1
            guard remainder.count >= offset + 8 else { return "" }
            let start = remainder.index(remainder.startIndex, offsetBy: offset)
            let end = remainder.index(start, offsetBy: 8)
            token += remainder[start..<end]
            remainder = String(remainder[remainder.index(remainder.startIndex, offsetBy: offset + 8)...])
        }
        return token
    }

    static func parseIkanbotSources(_ response: String) -> ([String], [String]) {
        guard let data = response.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["state"] as? Int) == 1,
              let dataObject = root["data"] as? [String: Any],
              let rows = dataObject["list"] as? [[String: Any]] else {
            return ([], [])
        }
        var flags: [String] = []
        var lines: [String] = []
        for (index, row) in rows.enumerated() {
            guard let raw = row["resData"] as? String,
                  let innerData = raw.data(using: .utf8),
                  let resources = try? JSONSerialization.jsonObject(with: innerData) as? [[String: Any]] else { continue }
            for resource in resources {
                guard let urls = resource["url"] as? String else { continue }
                let episodes = urls.split(separator: "#").compactMap { entry -> String? in
                    guard let delimiter = entry.firstIndex(of: "$"), delimiter != entry.startIndex else { return nil }
                    let name = String(entry[..<delimiter]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let url = String(entry[entry.index(after: delimiter)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard url.lowercased().hasPrefix("http"), url.lowercased().contains(".m3u8") else { return nil }
                    return "\(name)$\(url)"
                }
                guard !episodes.isEmpty else { continue }
                let flag = (resource["flag"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                flags.append(flag?.isEmpty == false ? flag! : "线路\(index + 1)")
                lines.append(episodes.joined(separator: "#"))
            }
        }
        return (flags, lines)
    }

    static func parseZanpianCards(_ html: String, sourceKey: String, baseURL: URL) -> [Movie.Video] {
        let anchors = anchorMatches(in: html)
        var seenPaths = Set<String>()
        let detailPaths = anchors.compactMap { anchor -> String? in
            guard let href = attribute("href", in: anchor.attributes),
                  let url = URL(string: href, relativeTo: baseURL)?.absoluteURL,
                  isZanpianDetail(url.path), seenPaths.insert(url.path).inserted else { return nil }
            return url.path
        }
        var videos: [Movie.Video] = []
        for path in detailPaths {
            let samePath = anchors.filter {
                guard let href = attribute("href", in: $0.attributes),
                      let url = URL(string: href, relativeTo: baseURL)?.absoluteURL else { return false }
                return url.path == path
            }
            let titleAnchor = samePath.first { !$0.body.localizedCaseInsensitiveContains("<img") && !text($0.body).isEmpty }
            let imageAnchor = samePath.first { $0.body.localizedCaseInsensitiveContains("<img") }
            let imageTag = imageAnchor.flatMap { capture(#"(?is)<img\b([^>]*)>"#, in: $0.body) } ?? ""
            let title = firstNonEmpty(
                titleAnchor.map { text($0.body) },
                attribute("alt", in: imageTag)
            )
            guard !title.isEmpty else { continue }
            var video = Movie.Video(id: path, name: title)
            video.pic = absoluteURL(
                attribute("data-original", in: imageTag)
                    ?? attribute("data-lazyload-src", in: imageTag)
                    ?? attribute("data-src", in: imageTag)
                    ?? attribute("src", in: imageTag) ?? "",
                relativeTo: baseURL
            )
            video.note = samePath.map { text($0.body) }.first { $0.contains("集") } ?? ""
            video.year = firstMatch(#"(?:19|20)\d{2}"#, in: title) ?? ""
            video.sourceKey = sourceKey
            videos.append(video)
            if videos.count >= 20 { break }
        }
        return videos
    }

    private static func isZanpianDetail(_ path: String) -> Bool {
        path.range(
            of: #"^/[a-z0-9_-]+/[a-z0-9_-]+/$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func isZanpianEpisode(_ path: String, under detailPath: String) -> Bool {
        let normalizedDetail = detailPath.hasSuffix("/") ? detailPath : detailPath + "/"
        guard path.hasPrefix(normalizedDetail) else { return false }
        let suffix = String(path.dropFirst(normalizedDetail.count))
        return suffix.range(of: #"^\d+-\d+\.html$"#, options: .regularExpression) != nil
    }

    private static func ikanbotID(_ path: String) -> String? {
        guard let range = path.range(of: #"^/play/([a-zA-Z0-9_-]+)(?:/|$)"#, options: .regularExpression) else { return nil }
        let match = String(path[range])
        return capture(#"^/play/([a-zA-Z0-9_-]+)"#, in: match)
    }

    private static func browserHeaders(for source: SourceBean, referer: String) -> [String: String] {
        var headers = source.headers ?? [:]
        if !headers.keys.contains(where: { $0.caseInsensitiveCompare("User-Agent") == .orderedSame }) {
            headers["User-Agent"] = ikanbotAgent
        }
        headers["Referer"] = referer
        return headers
    }

    private static func fetch(_ url: URL, headers: [String: String]) async throws -> String {
        try await NetworkManager.shared.getString(
            from: url.absoluteString,
            headers: headers,
            timeout: 15,
            maxRetries: 1
        )
    }

    private static func htmlPayload(_ response: String) -> String {
        guard let data = response.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return response.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") ? response : ""
        }
        return findHTML(in: object)
    }

    private static func findHTML(in value: Any) -> String {
        if let string = value as? String {
            return string.contains("<") && string.contains(">") ? string : ""
        }
        if let array = value as? [Any] {
            return array.map(findHTML).max(by: { $0.count < $1.count }) ?? ""
        }
        if let object = value as? [String: Any] {
            for key in ["ajaxtxt", "html", "content", "body", "data", "result", "list"] {
                if let candidate = object[key].map(findHTML), !candidate.isEmpty { return candidate }
            }
            return object.values.map(findHTML).max(by: { $0.count < $1.count }) ?? ""
        }
        return ""
    }

    private struct Anchor {
        let attributes: String
        let body: String
    }

    private static func anchorMatches(in html: String) -> [Anchor] {
        anchorPattern.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let attributesRange = Range(match.range(at: 1), in: html),
                  let bodyRange = Range(match.range(at: 2), in: html) else { return nil }
            return Anchor(attributes: String(html[attributesRange]), body: String(html[bodyRange]))
        }
    }

    private static func attribute(_ name: String, in value: String) -> String? {
        let pattern = #"(?is)\b\#(name)\s*=\s*(["'])(.*?)\1"#
        return capture(pattern, in: value, group: 2).map(decodeEntities)
    }

    private static func text(_ html: String) -> String {
        let withoutScripts = html.replacingOccurrences(
            of: #"(?is)<(script|style)\b[^>]*>.*?</\1>"#,
            with: " ",
            options: .regularExpression
        )
        let withoutTags = withoutScripts.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)
        return decodeEntities(withoutTags)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    private static func capture(_ pattern: String, in value: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.numberOfRanges > group,
              let range = Range(match.range(at: group), in: value) else { return nil }
        return String(value[range])
    }

    private static func captures(_ pattern: String, in value: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap {
            guard let range = Range($0.range(at: 1), in: value) else { return nil }
            return String(value[range])
        }
    }

    private static func firstMatch(_ pattern: String, in value: String) -> String? {
        capture(pattern, in: value, group: 0)
    }

    private static func absoluteURL(_ value: String, relativeTo baseURL: URL) -> String {
        guard !value.isEmpty else { return "" }
        return URL(string: value, relativeTo: baseURL)?.absoluteURL.absoluteString ?? value
    }

    private static func firstNonEmpty(_ values: String?...) -> String {
        values.compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    }
}

private extension URL {
    var originString: String {
        guard let scheme = scheme, let host = host else { return absoluteString }
        return "\(scheme)://\(host)"
    }
}
