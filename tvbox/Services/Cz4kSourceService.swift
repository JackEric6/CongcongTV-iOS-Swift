import Foundation

enum Cz4kSourceService {
    private static let origin = "https://www.cz4k.com"
    private static let headers = [
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36",
        "Referer": origin + "/"
    ]
    private static let anchorPattern = try! NSRegularExpression(
        pattern: #"(?is)<a\b([^>]*?)>(.*?)</a\s*>"#
    )

    static func search(keyword: String) async throws -> [Movie.Video] {
        var components = URLComponents(string: origin + "/nimasile")
        components?.queryItems = [URLQueryItem(name: "q", value: keyword)]
        guard let url = components?.url else { throw SourceError.invalidApiUrl(origin + "/nimasile") }
        let html = try await fetch(url.absoluteString)
        var videos: [Movie.Video] = []
        var seen = Set<String>()
        for match in anchorPattern.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let attrsRange = Range(match.range(at: 1), in: html),
                  let bodyRange = Range(match.range(at: 2), in: html) else { continue }
            let attrs = String(html[attrsRange])
            let body = String(html[bodyRange])
            guard let href = attribute("href", in: attrs),
                  let detailURL = resolvedURL(href, relativeTo: url),
                  isDetailURL(detailURL) else { continue }
            let imageTag = firstCapture(#"(?is)<img\b([^>]*)>"#, in: body, group: 1) ?? ""
            let name = firstNonEmpty(
                attribute("title", in: attrs),
                attribute("alt", in: imageTag),
                text(body)
            )
            let id = detailURL.path + (detailURL.query.map { "?\($0)" } ?? "")
            guard !name.isEmpty, seen.insert(id).inserted else { continue }
            var video = Movie.Video(id: id, name: name)
            video.pic = absoluteImage(
                attribute("data-original", in: imageTag)
                    ?? attribute("data-src", in: imageTag)
                    ?? attribute("src", in: imageTag) ?? "",
                baseURL: url
            )
            video.note = text(body)
            video.year = firstCapture(#"(?:19|20)\d{2}"#, in: name, group: 0) ?? ""
            video.sourceKey = "cz4k"
            videos.append(video)
            if videos.count >= 20 { break }
        }
        return videos
    }

    static func detail(vodID: String) async throws -> VodInfo {
        guard let url = resolvedURL(vodID, relativeTo: URL(string: origin)!) else {
            throw SourceError.invalidPlayableURL(vodID)
        }
        let html = try await fetch(url.absoluteString)
        let title = firstNonEmpty(
            firstCapture(#"(?is)<h1\b[^>]*>(.*?)</h1>"#, in: html, group: 1).map(text),
            firstCapture(#"(?is)<meta\s+[^>]*property=[\"']og:title[\"'][^>]*content=[\"']([^\"']*)[\"'][^>]*>"#, in: html, group: 1),
            firstCapture(#"(?is)<title\b[^>]*>(.*?)</title>"#, in: html, group: 1).map(text)
        )
        let image = firstCapture(#"(?is)<meta\s+[^>]*property=[\"']og:image[\"'][^>]*content=[\"']([^\"']*)[\"'][^>]*>"#, in: html, group: 1)
            ?? firstCapture(#"(?is)<img\b([^>]*)>"#, in: html, group: 1).flatMap { attribute("src", in: $0) }
            ?? ""
        let description = firstCapture(#"(?is)<meta\s+[^>]*name=[\"']description[\"'][^>]*content=[\"']([^\"']*)[\"'][^>]*>"#, in: html, group: 1)
            ?? firstCapture(#"(?is)<p\b[^>]*>(.*?)</p>"#, in: html, group: 1).map(text)
            ?? ""

        let video = Movie.Video(id: vodID, name: title)
        var enriched = video
        enriched.pic = absoluteImage(image, baseURL: url)
        enriched.des = description
        enriched.year = firstCapture(#"(?:19|20)\d{2}"#, in: html, group: 0) ?? ""
        enriched.sourceKey = "cz4k"

        var episodes: [VodInfo.Episode] = []
        var seen = Set<String>()
        for match in anchorPattern.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let attrsRange = Range(match.range(at: 1), in: html),
                  let bodyRange = Range(match.range(at: 2), in: html) else { continue }
            let attrs = String(html[attrsRange])
            let body = String(html[bodyRange])
            guard let href = attribute("href", in: attrs),
                  let episodeURL = resolvedURL(href, relativeTo: url),
                  isPlayableURL(episodeURL), seen.insert(episodeURL.absoluteString).inserted else { continue }
            let name = firstNonEmpty(attribute("title", in: attrs), text(body), "第\(episodes.count + 1)集")
            episodes.append(VodInfo.Episode(name: name, url: episodeURL.absoluteString))
            if episodes.count >= 200 { break }
        }
        if episodes.isEmpty,
           let media = firstCapture(#"(?i)(https?:)?//[^\"'<>\s]+\.(?:m3u8|mp4)(?:\?[^\"'<>\s]*)?"#, in: html, group: 0) {
            let resolvedMedia = media.hasPrefix("//") ? "https:" + media : media
            episodes.append(VodInfo.Episode(name: "正片", url: resolvedMedia))
        }
        guard !episodes.isEmpty else { throw SourceError.invalidResponse("厂长详情页没有找到可播放剧集") }
        let playURL = episodes.map { "\($0.name)$\($0.url)" }.joined(separator: "#")
        return VodInfo.from(video: enriched, playFrom: "厂长线路", playUrl: playURL)
    }

    private static func fetch(_ url: String) async throws -> String {
        try await NetworkManager.shared.getString(from: url, headers: headers, timeout: 60, maxRetries: 0)
    }

    private static func resolvedURL(_ value: String, relativeTo base: URL) -> URL? {
        URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: base)?.absoluteURL
    }

    private static func isDetailURL(_ url: URL) -> Bool {
        guard url.host?.lowercased() == "www.cz4k.com" || url.host?.lowercased() == "cz4k.com" else { return false }
        let path = url.path.lowercased()
        return path.hasSuffix(".html") && !path.contains("/nimasile") && !isPlayableURL(url)
    }

    private static func isPlayableURL(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return path.contains("/play") || path.contains("/vodplay") || path.contains("/player")
            || path.contains("/v_play/") || path.hasSuffix(".m3u8") || path.hasSuffix(".mp4")
    }

    private static func attribute(_ name: String, in value: String) -> String? {
        let pattern = #"(?is)\b\#(name)\s*=\s*([\"'])(.*?)\2"#
        guard let capture = firstCapture(pattern, in: value, group: 2) else { return nil }
        return decodeEntities(capture.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func text(_ html: String) -> String {
        let withoutScripts = html.replacingOccurrences(of: #"(?is)<(script|style)\b[^>]*>.*?</\1>"#, with: " ", options: .regularExpression)
        let withoutTags = withoutScripts.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)
        return decodeEntities(withoutTags)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func absoluteImage(_ value: String, baseURL: URL) -> String {
        guard !value.isEmpty else { return "" }
        return resolvedURL(value, relativeTo: baseURL)?.absoluteString ?? value
    }

    private static func firstCapture(_ pattern: String, in value: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.numberOfRanges > group,
              let range = Range(match.range(at: group), in: value) else { return nil }
        return String(value[range])
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

    private static func firstNonEmpty(_ values: String?...) -> String {
        values.compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    }
}
