import Foundation

@main
struct VerifyGuaziPlaybackRequest {
    static func main() {
        let parameters = GuaziPlaybackRequest.parseEncodedParameters(
            "domain_type=vod%2Fcloud%2Bprivate&resolution=720&type=play%3Ftoken%3Da%3Db"
        )
        require(parameters["domain_type"] == "vod%2Fcloud%2Bprivate", "domain_type encoding must be preserved")
        require(parameters["resolution"] == "720", "resolution must be parsed")
        require(parameters["type"] == "play%3Ftoken%3Da%3Db", "encoded type and extra equals signs must be preserved")

        let request = GuaziPlaybackRequest(
            vodID: "vod-1",
            cloudID: "cloud-2",
            vurlID: "episode-3",
            domainType: parameters["domain_type"] ?? "",
            resolution: parameters["resolution"] ?? "",
            type: parameters["type"] ?? ""
        )
        guard let roundTripped = GuaziPlaybackRequest(url: request.url) else {
            fatalError("Generated Guazi request URL must parse")
        }
        require(roundTripped.domainType == request.domainType, "domain_type must survive URL construction")
        require(roundTripped.type == request.type, "type must survive URL construction")
        require(roundTripped.vodID == request.vodID, "vod id must survive URL construction")
        require(
            request.url.hasPrefix("http://127.0.0.1:9978/guazi/play.m3u8?"),
            "playback episodes must use Android's loopback HTTP route"
        )
        require(
            GuaziPlaybackRequest(
                url: request.url.replacingOccurrences(of: "127.0.0.1:9978", with: "guazi.local")
            ) == nil,
            "the old synthetic guazi.local URL must not be accepted"
        )
        let actualProxyPort: UInt16 = 54_321
        let actualRequestURL = request.url(port: actualProxyPort)
        let requestComponents = URLComponents(string: actualRequestURL)!
        let requestTarget = requestComponents.path + "?" + requestComponents.percentEncodedQuery!
        let parsedHead = GuaziPlaybackRequest.parseHTTPRequestHead(
            "GET \(requestTarget) HTTP/1.1\r\nHost: 127.0.0.1:\(actualProxyPort)",
            port: actualProxyPort
        )
        require(parsedHead == request, "local HTTP request must preserve Android playback parameters")
        let redirect = String(
            data: GuaziPlaybackRequest.redirectResponse(to: "https://cdn.example/video.m3u8")!,
            encoding: .utf8
        )!
        require(redirect.hasPrefix("HTTP/1.1 301 Moved Permanently\r\n"), "match NanoHTTPD REDIRECT status")
        require(redirect.contains("Location: https://cdn.example/video.m3u8\r\n"), "redirect must carry CDN Location")
        require(redirect.contains("Cache-Control: no-store\r\n"), "redirect must disable caching")
        require(
            GuaziPlaybackRequest.androidCompatibleMediaHeaders["User-Agent"]?.contains("Chrome/138.0.0.0") == true,
            "Guazi media requests must use the Android player user agent"
        )
        require(
            GuaziPlaybackRequest.androidCompatibleMediaHeaders["Accept"]?.contains("application/json") == true,
            "Guazi media requests must use the Android player Accept header"
        )
        require(
            GuaziPlaybackRequest.prefersFFmpegBackend(sourceKey: "guazi"),
            "Guazi must use the FFmpeg backend first"
        )
        require(
            !GuaziPlaybackRequest.prefersFFmpegBackend(sourceKey: "xgzy"),
            "Other sources must keep the AVPlayer-first backend"
        )
        print("GUAZI PLAYBACK REQUEST CHECKS PASSED")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError("FAIL: \(message)")
        }
    }
}
