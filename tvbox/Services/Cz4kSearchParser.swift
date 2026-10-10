import Foundation

enum Cz4kSearchParser {
    private static let anchorPattern = try! NSRegularExpression(
        pattern: #"(?is)<a\b([^>]*?)>(.*?)</a\s*>"#
    )

    static func parse(html: String, baseURL: URL) -> [Movie.Video] {
        var videos: [Movie.Video] = []
        var seen = Set<String>()
        let range = NSRange(html.startIndex..<html.endIndex, in: html)

        for match in anchorPattern.matches(in: html, range: range) {
            guard let attributesRange = Range(match.range(at: 1), in: html),
                  let bodyRange = Range(match.range(at: 2), in: html) else { continue }
            let attributes = String(html[attributesRange])
            let body = String(html[bodyRange])
            let url = [
                attribute("href", in: attributes),
                attribute("data-href", in: attributes),
                attribute("data-url", in: attributes)
            ]
            .compactMap { $0 }
            .compactMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
            .first { isCz4kHost($0.host) && isDetailURL($0) }
            guard let url else { continue }
            let id = url.path + (url.query.map { "?\($0)" } ?? "")
            guard !seen.contains(id) else { continue }

            let imageTag = capture(#"(?is)<img\b([^>]*)>"#, in: body) ?? ""
            let heading = capture(#"(?is)<h[1-6]\b[^>]*>(.*?)</h[1-6]\s*>"#, in: body)
            let name = [
                attribute("title", in: attributes),
                heading.map(text),
                attribute("alt", in: imageTag),
                attribute("title", in: imageTag),
                text(body)
            ].compactMap { $0 }.first {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isActionText($0)
            } ?? ""
            guard !name.isEmpty else { continue }
            seen.insert(id)

            var video = Movie.Video(id: id, name: name)
            video.pic = absoluteImage(
                firstNonEmpty(
                    attribute("data-original", in: imageTag),
                    attribute("data-src", in: imageTag),
                    attribute("data-lazy-src", in: imageTag),
                    attribute("src", in: imageTag)
                ),
                baseURL: baseURL
            )
            video.note = text(body)
            video.year = capture(#"(?:19|20)\d{2}"#, in: name, group: 0) ?? ""
            video.sourceKey = "cz4k"
            videos.append(video)
            if videos.count == 50 { break }
        }
        return videos
    }

    private static func isDetailURL(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        let excluded = ["/nimasile", "/search", "/vodsearch", "/play", "/vodplay", "/vod-play", "/playmov", "/player", "/type", "/topic", "/actor", "/tag"]
        guard !excluded.contains(where: path.contains) else { return false }
        if path.hasSuffix(".html") { return true }
        return ["/v/", "/content/", "/detail/", "/movie/", "/tvseries/", "/animation/", "/arts/", "/voddetail/", "/vod/"]
            .contains(where: path.contains)
    }

    private static func isCz4kHost(_ value: String?) -> Bool {
        guard let host = value?.lowercased() else { return false }
        return host == "cz4k.com" || host.hasSuffix(".cz4k.com")
    }

    private static func isActionText(_ value: String) -> Bool {
        let normalized = value.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        return ["播放", "立即播放", "详情", "查看", "下载", "在线观看", "查看详情"].contains(normalized)
    }

    private static func attribute(_ name: String, in value: String) -> String? {
        let pattern = #"(?is)\b\#(name)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else {
            return nil
        }
        for index in 1..<match.numberOfRanges {
            guard let range = Range(match.range(at: index), in: value) else { continue }
            let result = decodeEntities(String(value[range])).trimmingCharacters(in: .whitespacesAndNewlines)
            if !result.isEmpty { return result }
        }
        return nil
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

    private static func capture(_ pattern: String, in value: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.numberOfRanges > group,
              let range = Range(match.range(at: group), in: value) else { return nil }
        return String(value[range])
    }

    private static func absoluteImage(_ value: String?, baseURL: URL) -> String {
        guard let value, !value.isEmpty else { return "" }
        return URL(string: value, relativeTo: baseURL)?.absoluteURL.absoluteString ?? value
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.compactMap { $0 }.first {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
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
}
