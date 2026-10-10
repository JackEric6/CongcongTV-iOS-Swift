import Foundation

@main
struct VerifyDanmakuEpisodeMatcher {
    static func main() {
        precondition(DanmakuEpisodeMatcher.matches(requestedEpisode: "第1集", title: "第1集 无悔追踪 01"))
        precondition(DanmakuEpisodeMatcher.matches(requestedEpisode: "第1集", title: "美人余(2026)【电视剧】 from tencent [qq] 美人余_01"))
        precondition(DanmakuEpisodeMatcher.matches(requestedEpisode: "EP01", title: "EP01 正片"))
        precondition(DanmakuEpisodeMatcher.matches(requestedEpisode: "第1集", title: "任意标题", explicitNumber: 1))
        precondition(!DanmakuEpisodeMatcher.matches(requestedEpisode: "第1集", title: "【bilibili】PV1 预告"))
        precondition(!DanmakuEpisodeMatcher.matches(requestedEpisode: "第1集", title: "第10集"))
        precondition(!DanmakuEpisodeMatcher.matches(requestedEpisode: "第1集", title: "美人余_02"))
        print("DANMAKU EPISODE MATCHER CHECKS PASSED")
    }
}
