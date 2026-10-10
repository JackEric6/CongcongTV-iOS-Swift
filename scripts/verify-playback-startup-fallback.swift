import Foundation

@main
struct VerifyPlaybackStartupFallback {
    static func main() {
        precondition(!PlaybackStartupFallbackPolicy.shouldFallback(
            didPurify: true,
            elapsed: PlaybackStartupFallbackPolicy.timeout - 0.1,
            startingProgress: 0,
            currentProgress: 0
        ))
        precondition(PlaybackStartupFallbackPolicy.shouldFallback(
            didPurify: true,
            elapsed: PlaybackStartupFallbackPolicy.timeout,
            startingProgress: 120,
            currentProgress: 120.5
        ))
        precondition(!PlaybackStartupFallbackPolicy.shouldFallback(
            didPurify: false,
            elapsed: 60,
            startingProgress: 0,
            currentProgress: 0
        ))
        precondition(!PlaybackStartupFallbackPolicy.shouldFallback(
            didPurify: true,
            elapsed: 60,
            startingProgress: 120,
            currentProgress: 121
        ))
        print("PLAYBACK STARTUP FALLBACK CHECKS PASSED")
    }
}
