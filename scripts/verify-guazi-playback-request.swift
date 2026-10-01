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
