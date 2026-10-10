import Foundation

@main
struct VerifyVodInfoPlaylist {
    static func main() {
        let video = Movie.Video(id: "movie-1", name: "播放列表校验", sourceKey: "xgzy")
        let playFrom = "主线路$$$$$$备用线路"
        let playUrl = [
            "第1集$https://cdn.example/one.m3u8?token=alpha$beta",
            "", // 空线路必须继续占住原索引，不能让后续 flag 与 URL 错配。
            "第3集$https://cdn.example/three.m3u8?token=gamma"
        ].joined(separator: "$$$")

        let info = VodInfo.from(video: video, playFrom: playFrom, playUrl: playUrl)
        precondition(info.playFlags == ["主线路", "备用线路"])
        precondition(info.playUrlMap["主线路"]?.first?.url == "https://cdn.example/one.m3u8?token=alpha$beta")
        precondition(info.playUrlMap["备用线路"]?.first?.url == "https://cdn.example/three.m3u8?token=gamma")

        let emptyFirstLine = VodInfo.from(
            video: video,
            playFrom: "$$$备用线路",
            playUrl: "$$$第3集$https://cdn.example/three.m3u8"
        )
        precondition(emptyFirstLine.playFlag == "备用线路")
        precondition(emptyFirstLine.currentEpisode?.url == "https://cdn.example/three.m3u8")
        print("VOD PLAYLIST PARSING CHECKS PASSED")
    }
}
