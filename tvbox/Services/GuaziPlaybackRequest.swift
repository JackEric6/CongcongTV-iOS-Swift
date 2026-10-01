import Foundation

struct GuaziPlaybackRequest: Hashable, Sendable {
    static let preferredLocalPort: UInt16 = 9978
    static let localHost = "127.0.0.1"
    static let localPath = "/guazi/play.m3u8"

    // 瓜子 CDN 会把浏览器 UA 路由到短预览；Android 播放器使用自身默认请求头。
    static let playbackHeaders: [String: String] = [:]

    let vodID: String
    let cloudID: String
    let vurlID: String
    let domainType: String
    let resolution: String
    let type: String

    init(
        vodID: String,
        cloudID: String,
        vurlID: String,
        domainType: String,
        resolution: String,
        type: String
    ) {
        self.vodID = vodID
        self.cloudID = cloudID
        self.vurlID = vurlID
        self.domainType = domainType
        self.resolution = resolution
        self.type = type
    }

    init?(url: String) {
        guard let components = URLComponents(string: url),
              components.scheme?.lowercased() == "http",
              components.host == Self.localHost,
              components.port != nil,
              components.path == Self.localPath,
              let queryItems = components.queryItems else {
            return nil
        }
        func value(_ name: String) -> String {
            queryItems.first(where: { $0.name == name })?.value ?? ""
        }
        let vodID = value("vod_id")
        let cloudID = value("vurl_cloud_id")
        let vurlID = value("vurl_id")
        let domainType = value("domain_type")
        let resolution = value("resolution")
        guard !vodID.isEmpty, !cloudID.isEmpty, !vurlID.isEmpty,
              !domainType.isEmpty, !resolution.isEmpty else {
            return nil
        }
        self.vodID = vodID
        self.cloudID = cloudID
        self.vurlID = vurlID
        self.domainType = domainType
        self.resolution = resolution
        self.type = value("type").isEmpty ? "play" : value("type")
    }

    var url: String {
        url(port: Self.preferredLocalPort)
    }

    func url(port: UInt16) -> String {
        var components = URLComponents()
        components.scheme = "http"
        components.host = Self.localHost
        components.port = Int(port)
        components.path = Self.localPath
        components.queryItems = [
            URLQueryItem(name: "vod_id", value: vodID),
            URLQueryItem(name: "vurl_cloud_id", value: cloudID),
            URLQueryItem(name: "vurl_id", value: vurlID),
            URLQueryItem(name: "domain_type", value: domainType),
            URLQueryItem(name: "resolution", value: resolution),
            URLQueryItem(name: "type", value: type)
        ]
        return components.url?.absoluteString ?? ""
    }

    static func parseHTTPRequestHead(
        _ head: String,
        port: UInt16 = Self.preferredLocalPort
    ) -> GuaziPlaybackRequest? {
        guard let requestLine = head.components(separatedBy: "\r\n").first else { return nil }
        let parts = requestLine.split(whereSeparator: \.isWhitespace)
        guard parts.count == 3,
              parts[0].uppercased() == "GET",
              parts[2] == "HTTP/1.0" || parts[2] == "HTTP/1.1",
              parts[1].hasPrefix("/"),
              let url = URL(
                string: "http://\(localHost):\(port)\(parts[1])"
              ) else {
            return nil
        }
        return GuaziPlaybackRequest(url: url.absoluteString)
    }

    static func redirectResponse(to location: String) -> Data? {
        guard let components = URLComponents(string: location),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil,
              !location.contains("\r"),
              !location.contains("\n") else {
            return nil
        }
        let response = [
            "HTTP/1.1 301 Moved Permanently",
            "Content-Type: text/plain",
            "Location: \(location)",
            "Cache-Control: no-store",
            "Content-Length: 0",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        return Data(response.utf8)
    }

    static func errorResponse(status: Int, reason: String, message: String) -> Data {
        let body = Data(message.utf8)
        let header = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Length: \(body.count)",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        return Data(header.utf8) + body
    }

    /// Mirrors GuaziAdapter.parseQuery: split the pairs but do not decode values.
    static func parseEncodedParameters(_ value: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in value.components(separatedBy: "&") {
            guard let separator = pair.firstIndex(of: "="), separator != pair.startIndex else {
                continue
            }
            let key = String(pair[..<separator])
            let encodedValue = String(pair[pair.index(after: separator)...])
            result[key] = encodedValue
        }
        return result
    }
}
