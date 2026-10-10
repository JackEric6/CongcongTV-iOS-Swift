import Foundation

@main
struct VerifyDanmakuTimeline {
    static func main() {
        precondition(!DanmakuTimelinePolicy.didSeekBackward(from: nil, to: 0))
        precondition(!DanmakuTimelinePolicy.didSeekBackward(from: 3, to: 4.5))
        precondition(!DanmakuTimelinePolicy.didSeekBackward(from: 10, to: 9.6))
        precondition(DanmakuTimelinePolicy.didSeekBackward(from: 10, to: 9.4))
        precondition(!DanmakuTimelinePolicy.didSeekBackward(from: 10, to: .infinity))
        precondition(DanmakuTimelinePolicy.playbackRate(2) == 2)
        precondition(DanmakuTimelinePolicy.playbackRate(0) == 1)
        precondition(DanmakuTimelinePolicy.playbackRate(8) == 4)
        precondition(DanmakuTimelinePolicy.canFollowScrollingBullet(
            previousRightEdge: 700,
            previousSpeed: 100,
            nextSpeed: 125,
            viewportWidth: 1000,
            minimumGap: 0
        ))
        precondition(!DanmakuTimelinePolicy.canFollowScrollingBullet(
            previousRightEdge: 900,
            previousSpeed: 100,
            nextSpeed: 125,
            viewportWidth: 1000,
            minimumGap: 0
        ))
        print("DANMAKU TIMELINE CHECKS PASSED")
    }
}
