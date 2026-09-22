import Foundation

/// 对 TVBox CMS 响应和旧本机代理地址做轻量整理。
///
/// KKT影视部分历史数据会把播放器页、真实媒体地址和多集地址混在同一组
/// `vod_play_url` 中。这里保持 TVBox 的字段格式，只调整线路优先级并解开
/// 能安全识别的 `url`/`play` 参数，不依赖 Java、JAR 或本地桥接服务。
enum KktvsResponseNormalizer {
    private static let mediaExtensions = [
        ".m3u8", ".mp4", ".flv", ".mkv", ".webm", ".mov"
    ]

    static func normalize(_ response: String) -> String {
        guard let data = response.data(using: .utf8),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var list = root["list"] as? [[String: Any]] else {
            return response
        }

        for index in list.indices {
            normalizeVod(&list[index])
        }
        root["list"] = list

        guard JSONSerialization.isValidJSONObject(root),
              let normalizedData = try? JSONSerialization.data(withJSONObject: root),
              let normalized = String(data: normalizedData, encoding: .utf8) else {
            return response
        }
        return normalized
    }

    /// 部分 Android 配置仍包含旧本机代理地址；iOS 端直接访问其 source 参数中的 CMS API。
    static func normalizeSourceAPI(_ value: String, sourceKey: String) -> String {
        guard let components = URLComponents(string: value),
              let host = components.host?.lowercased(),
              ["127.0.0.1", "localhost", "::1"].contains(host),
              let source = components.queryItems?.first(where: {
                  $0.name.caseInsensitiveCompare("source") == .orderedSame
              })?.value,
              let sourceComponents = URLComponents(string: source),
              ["http", "https"].contains(sourceComponents.scheme?.lowercased() ?? ""),
              sourceComponents.host != nil else {
            return value
        }
        return source
    }

    /// 供播放前使用：先处理协议相对地址和播放器页查询参数。
    static func normalizeMediaURL(_ value: String) -> String {
        var url = unescape(value.trimmingCharacters(in: .whitespacesAndNewlines))
        if url.hasPrefix("//") {
            url = "https:" + url
        }

        if let components = URLComponents(string: url),
           let nested = components.queryItems?.first(where: {
               let name = $0.name.lowercased()
               return name == "url" || name == "play" || name == "playurl"
           })?.value {
            let candidate = unescape(nested.trimmingCharacters(in: .whitespacesAndNewlines))
            if isHTTPURL(candidate), isDirectMedia(candidate) {
                return candidate
            }
        }
        return url
    }

    /// 从 hxplayer/2mplayer 等播放器页脚本中提取直接媒体地址。
    static func extractMediaURL(from body: String, baseURL: String) -> String? {
        let content = unescape(body)
        let patterns = [
            #"(?i)[\"'](?:url|playurl|play_url|file|src|video)[\"']\s*:\s*[\"']([^\"']+)[\"']"#,
            #"(?i)(?:https?:)?//[^\s\"'<>\\]+(?:\.m3u8|\.mp4|\.flv|\.mkv|\.webm|\.mov|\.ts)(?:\?[^\s\"'<>\\]*)?"#
        ]

        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(content.startIndex..<content.endIndex, in: content)
            for match in regex.matches(in: content, range: range) {
                let valueRange = match.numberOfRanges > 1 && index == 0
                    ? match.range(at: 1)
                    : match.range(at: 0)
                guard let swiftRange = Range(valueRange, in: content) else { continue }
                var candidate = String(content[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if candidate.hasPrefix("//") {
                    candidate = "https:" + candidate
                } else if candidate.hasPrefix("/"),
                          let base = URL(string: baseURL),
                          let resolved = URL(string: candidate, relativeTo: base)?.absoluteURL {
                    candidate = resolved.absoluteString
                }
                candidate = normalizeMediaURL(candidate)
                if isDirectMedia(candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    static func directMediaURL(_ value: String) -> String? {
        let normalized = normalizeMediaURL(value)
        return isDirectMedia(normalized) ? normalized : nil
    }

    private static func normalizeVod(_ vod: inout [String: Any]) {
        guard let from = stringValue(vod["vod_play_from"]),
              let urls = stringValue(vod["vod_play_url"]),
              !from.isEmpty,
              !urls.isEmpty else {
            return
        }

        let flags = from.components(separatedBy: "$$$")
        let playURLs = urls.components(separatedBy: "$$$")
        let servers = stringValue(vod["vod_play_server"])?.components(separatedBy: "$$$") ?? []
        let notes = stringValue(vod["vod_play_note"])?.components(separatedBy: "$$$") ?? []

        struct PlayGroup {
            let flag: String
            let url: String
            let server: String
            let note: String
            let priority: Int
            let originalIndex: Int
        }

        var groups: [PlayGroup] = []
        for index in 0..<min(flags.count, playURLs.count) {
            let flag = flags[index].trimmingCharacters(in: .whitespacesAndNewlines)
            let playURL = normalizePlayURL(playURLs[index])
            guard !flag.isEmpty, !playURL.isEmpty else { continue }
            groups.append(PlayGroup(
                flag: flag,
                url: playURL,
                server: index < servers.count ? servers[index].trimmingCharacters(in: .whitespacesAndNewlines) : "",
                note: index < notes.count ? notes[index].trimmingCharacters(in: .whitespacesAndNewlines) : "",
                priority: priority(flag: flag, url: playURL),
                originalIndex: index
            ))
        }

        guard !groups.isEmpty else {
            vod["vod_play_from"] = ""
            vod["vod_play_url"] = ""
            if vod["vod_play_server"] != nil { vod["vod_play_server"] = "" }
            if vod["vod_play_note"] != nil { vod["vod_play_note"] = "" }
            return
        }

        let ordered = groups.sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.originalIndex < $1.originalIndex
        }
        vod["vod_play_from"] = ordered.map(\.flag).joined(separator: "$$$")
        vod["vod_play_url"] = ordered.map(\.url).joined(separator: "$$$")
        if vod["vod_play_server"] != nil {
            vod["vod_play_server"] = ordered.map(\.server).joined(separator: "$$$")
        }
        if vod["vod_play_note"] != nil {
            vod["vod_play_note"] = ordered.map(\.note).joined(separator: "$$$")
        }
    }

    private static func normalizePlayURL(_ value: String) -> String {
        let episodes = value.components(separatedBy: "#")
        return episodes.map { episode in
            guard let separator = episode.firstIndex(of: "$"), separator != episode.startIndex else {
                return normalizeMediaURL(episode)
            }
            let name = String(episode[..<separator])
            let addressStart = episode.index(after: separator)
            guard addressStart < episode.endIndex else { return episode }
            return name + "$" + normalizeMediaURL(String(episode[addressStart...]))
        }.joined(separator: "#")
    }

    private static func priority(flag: String, url: String) -> Int {
        if url.lowercased().contains(".m3u8") { return 0 }
        if isDirectMedia(url) { return 1 }
        let normalizedFlag = flag.lowercased().replacingOccurrences(of: " ", with: "")
        if normalizedFlag.contains("hxplayer") || normalizedFlag.contains("2mplayer") || normalizedFlag.contains("1mplayer") {
            return 2
        }
        return 3
    }

    private static func isDirectMedia(_ value: String) -> Bool {
        guard isHTTPURL(value) else { return false }
        let lowercased = value.lowercased()
        if mediaExtensions.contains(where: { lowercased.contains($0) }) { return true }
        return lowercased.hasSuffix(".ts") || lowercased.contains(".ts?")
    }

    private static func isHTTPURL(_ value: String) -> Bool {
        let lowercased = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://")
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let value = value as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    private static func unescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\u002F", with: "/")
            .replacingOccurrences(of: "\\u002f", with: "/")
            .replacingOccurrences(of: "\\u0026", with: "&")
            .replacingOccurrences(of: "\\u003F", with: "?")
            .replacingOccurrences(of: "\\u003f", with: "?")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
