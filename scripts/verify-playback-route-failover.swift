import Foundation

@main
struct VerifyPlaybackRouteFailover {
    static func main() {
        let flags = ["首选", "失效线路", "备用"]
        let counts = ["首选": 3, "失效线路": 0, "备用": 2]
        precondition(
            PlaybackRouteFailoverPolicy.nextFlag(
                currentFlag: "首选",
                orderedFlags: flags,
                episodeCounts: counts,
                episodeIndex: 1,
                attemptedFlags: ["首选"]
            ) == "备用"
        )
        precondition(
            PlaybackRouteFailoverPolicy.nextFlag(
                currentFlag: "首选",
                orderedFlags: flags,
                episodeCounts: counts,
                episodeIndex: 2,
                attemptedFlags: ["首选", "备用"]
            ) == nil
        )
        precondition(
            PlaybackRouteFailoverPolicy.nextFlag(
                currentFlag: "未知线路",
                orderedFlags: flags,
                episodeCounts: counts,
                episodeIndex: 0,
                attemptedFlags: []
            ) == nil
        )
        print("PLAYBACK ROUTE FAILOVER CHECKS PASSED")
    }
}
