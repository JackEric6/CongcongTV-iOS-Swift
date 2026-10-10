import Foundation

@main
struct VerifyDanmakuTimeline {
    static func main() {
        precondition(!DanmakuTimelinePolicy.didSeekBackward(from: nil, to: 0))
        precondition(!DanmakuTimelinePolicy.didSeekBackward(from: 3, to: 4.5))
        precondition(!DanmakuTimelinePolicy.didSeekBackward(from: 10, to: 9.6))
        precondition(DanmakuTimelinePolicy.didSeekBackward(from: 10, to: 9.4))
        precondition(!DanmakuTimelinePolicy.didSeekBackward(from: 10, to: .infinity))
        print("DANMAKU TIMELINE CHECKS PASSED")
    }
}
