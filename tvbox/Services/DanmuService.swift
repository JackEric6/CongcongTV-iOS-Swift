import Foundation

/// Loads and parses danmaku using the protocol shared with the Android client.
@MainActor
public final class DanmuService {
    public static let shared = DanmuService()
    public static let builtinAPI = "https://logvardanmu.konfan.cn/87654321"

    public struct Configuration: Sendable, Equatable {
        public var apiURL: String?
        public var useDefault: Bool?

        public init(apiURL: String? = nil, useDefault: Bool? = nil) {
            self.apiURL = apiURL
            self.useDefault = useDefault
        }
    }

    private let network = NetworkManager.shared
    private let customSession: URLSession
    private var requestSequence = 0

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = true
        customSession = URLSession(configuration: configuration)
    }

    /// Loads a timeline. Network, parsing, cancellation, and malformed data all
    /// degrade to an empty result so playback is never blocked by danmaku.
    public func load(
        title: String,
        episode: String,
        configuration: Configuration = Configuration()
    ) async -> [DanmuCue] {
        requestSequence += 1
        let sequence = requestSequence
        let apiURL = resolveAPIURL(configuration)
        guard !apiURL.isEmpty else { return [] }

        do {
            let cues: [DanmuCue]
            if Self.isBuiltinAPI(apiURL) {
                cues = try await loadBuiltin(
                    baseURL: Self.normalizeBaseURL(apiURL),
                    title: title,
                    episode: episode
                )
            } else {
                let body = try await loadCustom(
                    apiURL: apiURL,
                    title: title,
                    episode: episode
                )
                cues = try await Self.parseOffMain(body)
            }
            try Task.checkCancellation()
            guard sequence == requestSequence else { return [] }
            return cues
        } catch is CancellationError {
            return []
        } catch {
            return []
        }
    }

    /// Alias kept short for callers that prefer a fetch-style API.
    public func fetch(
        title: String,
        episode: String,
        configuration: Configuration = Configuration()
    ) async -> [DanmuCue] {
        await load(title: title, episode: episode, configuration: configuration)
    }

    /// Compatibility alias used by the native player integration.
    public func loadCues(
        title: String,
        episode: String,
        configuration: Configuration = Configuration()
    ) async -> [DanmuCue] {
        await load(title: title, episode: episode, configuration: configuration)
    }

    public func load(
        title: String,
        episode: String,
        apiURL: String?
    ) async -> [DanmuCue] {
        await load(
            title: title,
            episode: episode,
            configuration: Configuration(apiURL: apiURL)
        )
    }

    public func cancel() {
        requestSequence += 1
    }

    /// Parses an already downloaded XML or comments/data JSON payload.
    public nonisolated static func parse(_ body: String) -> [DanmuCue] {
        DanmuCueParser.parse(body)
    }

    private func resolveAPIURL(_ configuration: Configuration) -> String {
        if let explicit = configuration.apiURL?.trimmedNonEmpty {
            return explicit
        }

        let defaults = UserDefaults.standard
        let useDefault = configuration.useDefault
            ?? (defaults.object(forKey: Self.useDefaultKey) as? Bool)
            ?? false
        if useDefault {
            return Self.builtinAPI
        }

        if let saved = Self.firstDefaultValue(
            keys: [Self.customAPIKey, "danmaku_api", "danmaku"]
        ) {
            return saved
        }

        // Android configurations expose this as a top-level `danmaku` value.
        if let configured = ApiConfig.shared.danmaku.trimmedNonEmpty {
            return configured
        }
        return Self.builtinAPI
    }

    private func loadBuiltin(
        baseURL: String,
        title: String,
        episode: String
    ) async throws -> [DanmuCue] {
        let number = Self.extractNumber(from: episode)
        let queries = number > 0 ? [String(number), ""] : [""]

        for query in queries {
            try Task.checkCancellation()
            let searchURL = try Self.makeURL(
                baseURL: baseURL,
                path: "/api/v2/search/episodes",
                queryItems: [
                    URLQueryItem(name: "anime", value: Self.transliterateToSimplified(title)),
                    query.isEmpty ? nil : URLQueryItem(name: "episode", value: query)
                ].compactMap { $0 }
            )
            guard let body = try? await network.getString(from: searchURL.absoluteString) else {
                continue
            }
            for match in Self.findEpisodes(in: body, requestedEpisode: episode) {
                if let cues = try? await loadComments(baseURL: baseURL, match: match),
                   !cues.isEmpty {
                    return cues
                }
            }
        }

        // Some servers return only anime search results from the episodes route.
        let animeURL = try Self.makeURL(
            baseURL: baseURL,
            path: "/api/v2/search/anime",
            queryItems: [URLQueryItem(name: "keyword", value: Self.transliterateToSimplified(title))]
        )
        guard let animeBody = try? await network.getString(from: animeURL.absoluteString) else {
            return []
        }

        for animeID in Self.findAnimeIDs(in: animeBody) {
            try Task.checkCancellation()
            let bangumiURL = try Self.makeURL(
                baseURL: baseURL,
                path: "/api/v2/bangumi/\(Self.urlPathEscape(animeID))",
                queryItems: []
            )
            guard let bangumiBody = try? await network.getString(from: bangumiURL.absoluteString) else {
                continue
            }
            for match in Self.findEpisodes(in: bangumiBody, requestedEpisode: episode) {
                if let cues = try? await loadComments(baseURL: baseURL, match: match),
                   !cues.isEmpty {
                    return cues
                }
            }
        }
        return []
    }

    private func loadComments(baseURL: String, match: EpisodeMatch) async throws -> [DanmuCue] {
        let commentURL = try Self.makeURL(
            baseURL: baseURL,
            path: "/api/v2/comment/\(Self.urlPathEscape(match.id))",
            queryItems: [URLQueryItem(name: "format", value: "json")]
        )
        let comments = try await network.getString(from: commentURL.absoluteString)
        return try await Self.parseOffMain(comments)
    }

    private func loadCustom(apiURL: String, title: String, episode: String) async throws -> String {
        let name = Self.transliterateToSimplified(title)
        let episodeValue = Self.transliterateToSimplified(episode)
        if apiURL.contains("{name}") || apiURL.contains("{episode}") {
            let replaced = apiURL
                .replacingOccurrences(of: "{name}", with: Self.urlQueryEscape(name))
                .replacingOccurrences(of: "{episode}", with: Self.urlQueryEscape(episodeValue))
            return try await network.getString(from: replaced)
        }

        guard let url = URL(string: apiURL) else { throw NetworkError.invalidURL(apiURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let formBody = "name=\(Self.urlQueryEscape(name))&episode=\(Self.urlQueryEscape(episodeValue))"
        request.httpBody = formBody.data(using: .utf8)

        let (data, response) = try await customSession.data(for: request)
        try Task.checkCancellation()
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.invalidResponse
        }
        let body = String(decoding: data, as: UTF8.self)
        if let nestedURL = Self.extractURL(from: body), nestedURL != apiURL {
            return try await network.getString(from: nestedURL)
        }
        return body
    }

    private static func parseOffMain(_ body: String) async throws -> [DanmuCue] {
        try Task.checkCancellation()
        return await Task.detached(priority: .utility) {
            DanmuCueParser.parse(body)
        }.value
    }

    private static let useDefaultKey = "danmu_api_use_default"
    private static let customAPIKey = "danmu_api"

    private static func firstDefaultValue(keys: [String]) -> String? {
        for key in keys {
            if let value = UserDefaults.standard.string(forKey: key)?.trimmedNonEmpty {
                return value
            }
        }
        return nil
    }

    private static func isBuiltinAPI(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == builtinAPI.lowercased()
            || normalized.hasSuffix("/87654321")
    }

    private static func normalizeBaseURL(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix("/") { result.removeLast() }
        if result.hasSuffix("/87654321") {
            result.removeLast("/87654321".count)
        }
        return result
    }

    private static func makeURL(
        baseURL: String,
        path: String,
        queryItems: [URLQueryItem]
    ) throws -> URL {
        guard let base = URL(string: baseURL), var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw NetworkError.invalidURL(baseURL)
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let pathPart = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + ([basePath, pathPart].filter { !$0.isEmpty }.joined(separator: "/"))
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else { throw NetworkError.invalidURL(baseURL) }
        return url
    }

    private static func urlPathEscape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private static func urlQueryEscape(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func transliterateToSimplified(_ value: String) -> String {
        // The Android client normalizes through Trans.t2s. Foundation has no
        // built-in Traditional-to-Simplified converter, so preserve the input.
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct EpisodeMatch {
        let id: String
        let title: String
        let number: Int
    }

    private static func findAnimeIDs(in body: String) -> [String] {
        guard let object = jsonObject(body) else { return [] }
        let arrays = ["animes", "anime", "data"]
        var ids: [String] = []
        for key in arrays {
            if let items = object[key] as? [[String: Any]] {
                ids.append(contentsOf: items.map { firstString($0, keys: ["animeId", "id"]) })
            }
        }
        if ids.isEmpty {
            let id = firstString(object, keys: ["animeId", "id"])
            if !id.isEmpty { ids.append(id) }
        }
        var seen = Set<String>()
        return ids.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func findEpisodes(in body: String, requestedEpisode: String) -> [EpisodeMatch] {
        guard let object = jsonObject(body) else { return [] }
        let episodeArrays = episodeArrays(in: object)
        let requestedNumber = extractNumber(from: requestedEpisode)
        var matches: [EpisodeMatch] = []

        for item in episodeArrays {
            let id = firstString(item, keys: ["episodeId", "id"])
            guard !id.isEmpty else { continue }
            let title = firstString(item, keys: ["episodeTitle", "title", "name"])
            let rawNumber = firstString(item, keys: ["episodeNumber", "number", "sort"])
            let number = parseEpisodeNumber(rawNumber)
            let match = EpisodeMatch(id: id, title: title, number: number)
            let exactTitle = !requestedEpisode.isEmpty && !title.isEmpty
                && title.localizedCaseInsensitiveContains(requestedEpisode)
            let exactNumber = requestedNumber > 0 && (number == requestedNumber
                || extractNumber(from: title) == requestedNumber)
            if requestedEpisode.isEmpty || exactTitle || exactNumber {
                matches.append(match)
            }
        }

        if matches.isEmpty, requestedEpisode.isEmpty {
            return episodeArrays.compactMap { item in
                let id = firstString(item, keys: ["episodeId", "id"])
                guard !id.isEmpty else { return nil }
                return EpisodeMatch(
                    id: id,
                    title: firstString(item, keys: ["episodeTitle", "title", "name"]),
                    number: parseEpisodeNumber(firstString(item, keys: ["episodeNumber", "number", "sort"]))
                )
            }
        }
        return matches
    }

    private static func episodeArrays(in object: [String: Any]) -> [[String: Any]] {
        if let episodes = object["episodes"] as? [[String: Any]] { return episodes }
        if let bangumi = object["bangumi"] as? [String: Any],
           let episodes = bangumi["episodes"] as? [[String: Any]] {
            return episodes
        }

        var nestedEpisodes: [[String: Any]] = []
        for key in ["animes", "anime", "data"] {
            guard let items = object[key] as? [[String: Any]] else { continue }
            for item in items {
                if let episodes = item["episodes"] as? [[String: Any]] {
                    nestedEpisodes.append(contentsOf: episodes)
                }
            }
        }
        return nestedEpisodes
    }

    private static func parseEpisodeNumber(_ value: String) -> Int {
        if let number = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return Int(number)
        }
        return extractNumber(from: value)
    }

    private static func extractNumber(from value: String) -> Int {
        let digits = value.compactMap { $0.isNumber ? String($0) : nil }.joined()
        return Int(digits) ?? -1
    }

    private static func jsonObject(_ body: String) -> [String: Any]? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func firstString(_ object: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty { return value }
            if let value = object[key] as? NSNumber { return value.stringValue }
        }
        return ""
    }

    private static func extractURL(from body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("file://") {
            return trimmed
        }
        guard let data = trimmed.data(using: .utf8) else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let url = object["url"] as? String,
           !url.isEmpty {
            return url
        }
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           let url = array.lazy.compactMap({ $0["url"] as? String }).first(where: { !$0.isEmpty }) {
            return url
        }
        return nil
    }
}

private enum DanmuCueParser {
    static func parse(_ body: String) -> [DanmuCue] {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.first == "<" {
            let xmlCues = parseXML(trimmed)
            if !xmlCues.isEmpty { return xmlCues }
        }
        if let jsonCues = parseJSON(trimmed), !jsonCues.isEmpty {
            return jsonCues
        }
        return parseXMLWithRegex(trimmed)
    }

    private static func parseXML(_ body: String) -> [DanmuCue] {
        guard let data = body.data(using: .utf8) else { return [] }
        let delegate = XMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return [] }
        return normalized(delegate.cues)
    }

    private static func parseJSON(_ body: String) -> [DanmuCue]? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        let items: [[String: Any]]
        if let array = object as? [[String: Any]] {
            items = array
        } else if let dictionary = object as? [String: Any] {
            items = ["comments", "data", "danmaku"].compactMap { dictionary[$0] as? [[String: Any]] }.flatMap { $0 }
        } else {
            return []
        }

        let cues = items.compactMap { item -> DanmuCue? in
            let param = scalarString(item["p"])
            var text = scalarString(item["m"])
            if text.isEmpty { text = scalarString(item["text"]) }
            guard !param.isEmpty, !text.isEmpty else { return nil }
            return makeCue(param: param, text: text)
        }
        return normalized(cues)
    }

    private static func parseXMLWithRegex(_ body: String) -> [DanmuCue] {
        let pattern = #"(?is)<d\b[^>]*\bp\s*=\s*([\"'])(.*?)\1[^>]*>(.*?)</d\s*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        let cues = regex.matches(in: body, range: range).compactMap { match -> DanmuCue? in
            guard let paramRange = Range(match.range(at: 2), in: body),
                  let textRange = Range(match.range(at: 3), in: body) else { return nil }
            return makeCue(
                param: String(body[paramRange]),
                text: decodeXML(String(body[textRange]))
            )
        }
        return normalized(cues)
    }

    private static func makeCue(param: String, text: String) -> DanmuCue? {
        let values = param.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard let time = Double(values.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""),
              time.isFinite else { return nil }
        let type = Int(values[safe: 1] ?? "1") ?? 1
        var size = Double(values[safe: 2] ?? "25") ?? 25
        var color = parseColor(values[safe: 3]) ?? 0xFFFFFF

        // The Android compatibility path accepts feeds that put the color in
        // the third slot and omit a valid fourth-slot color.
        if let third = parseColor(values[safe: 2]), parseColor(values[safe: 3]) == nil {
            color = third
            size = 25
        }
        guard !text.isEmpty else { return nil }
        return DanmuCue(
            time: max(0, time),
            type: type,
            size: size > 0 && size.isFinite ? size : 25,
            color: color,
            text: decodeXML(text)
        )
    }

    private static func parseColor(_ value: String?) -> Int? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("#") {
            return Int(text.dropFirst(), radix: 16).map { $0 & 0xFFFFFF }
        }
        if text.lowercased().hasPrefix("0x") {
            return Int(text.dropFirst(2), radix: 16).map { $0 & 0xFFFFFF }
        }
        guard let value = Int(text), (0...0xFFFFFF).contains(value) else { return nil }
        return value
    }

    private static func scalarString(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    private static func normalized(_ cues: [DanmuCue]) -> [DanmuCue] {
        cues.sorted {
            if $0.time == $1.time { return $0.id < $1.id }
            return $0.time < $1.time
        }
    }

    private static func decodeXML(_ value: String) -> String {
        var result = value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
        let pattern = #"&#(x[0-9a-fA-F]+|[0-9]+);"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..<result.endIndex, in: result))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result),
                  let valueRange = Range(match.range(at: 1), in: result) else { continue }
            let token = String(result[valueRange])
            let scalar: UInt32?
            if token.lowercased().hasPrefix("x") {
                scalar = UInt32(token.dropFirst(), radix: 16)
            } else {
                scalar = UInt32(token)
            }
            if let scalar, let unicode = UnicodeScalar(scalar) {
                result.replaceSubrange(range, with: String(unicode))
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private final class XMLDelegate: NSObject, XMLParserDelegate {
        var cues: [DanmuCue] = []
        private var currentParam: String?
        private var currentText = ""

        func parser(
            _: XMLParser,
            didStartElement elementName: String,
            namespaceURI _: String?,
            qualifiedName _: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            guard elementName.caseInsensitiveCompare("d") == .orderedSame else { return }
            currentParam = attributeDict["p"] ?? attributeDict["P"]
            currentText = ""
        }

        func parser(_: XMLParser, foundCharacters string: String) {
            guard currentParam != nil else { return }
            currentText += string
        }

        func parser(_: XMLParser, foundCDATA CDATABlock: Data) {
            guard currentParam != nil else { return }
            currentText += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(
            _: XMLParser,
            didEndElement elementName: String,
            namespaceURI _: String?,
            qualifiedName _: String?
        ) {
            guard elementName.caseInsensitiveCompare("d") == .orderedSame,
                  let currentParam,
                  let cue = makeCue(param: currentParam, text: currentText) else { return }
            cues.append(cue)
            self.currentParam = nil
            currentText = ""
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
