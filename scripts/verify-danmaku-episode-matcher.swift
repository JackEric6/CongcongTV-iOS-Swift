import Foundation

@main
struct VerifyDanmakuEpisodeMatcher {
    static func main() {
        precondition(DanmakuEpisodeMatcher.matches(requestedEpisode: "第1集", title: "第1集 无悔追踪 01"))
        precondition(DanmakuEpisodeMatcher.matches(requestedEpisode: "EP01", title: "EP01 正片"))
        precondition(DanmakuEpisodeMatcher.matches(requestedEpisode: "第1集", title: "任意标题", explicitNumber: 1))
        precondition(!DanmakuEpisodeMatcher.matches(requestedEpisode: "第1集", title: "【bilibili】PV1 预告"))
        precondition(!DanmakuEpisodeMatcher.matches(requestedEpisode: "第1集", title: "第10集"))
        print("DANMAKU EPISODE MATCHER CHECKS PASSED")
    }
}
