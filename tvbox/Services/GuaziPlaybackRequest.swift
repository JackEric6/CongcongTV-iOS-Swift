import Foundation

struct GuaziPlaybackRequest: Hashable, Sendable {
    static let androidCompatibleMediaHeaders = [
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/json;q=0.9"
    ]

    static func prefersFFmpegBackend(sourceKey: String) -> Bool {
        sourceKey.caseInsensitiveCompare("guazi") == .orderedSame
    }

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
              components.host?.lowercased() == "guazi.local",
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
        var components = URLComponents()
        components.scheme = "https"
        components.host = "guazi.local"
        components.path = "/play.m3u8"
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
