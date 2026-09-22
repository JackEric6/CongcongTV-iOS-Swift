import Foundation

/// 视频详情模型 - 对应 Android 版 VodInfo.java
struct VodInfo: Codable, Identifiable {
    /// 视频唯一 ID。
    var id: String
    /// 标题。
    var name: String = ""
    /// 海报地址。
    var pic: String = ""
    /// 备注（更新状态等）。
    var note: String = ""
    /// 年份。
    var year: String = ""
    /// 地区。
    var area: String = ""
    /// 类型名。
    var typeName: String = ""
    /// 导演。
    var director: String = ""
    /// 演员。
    var actor: String = ""
    /// 简介。
    var des: String = ""
    /// 来源站点 key。
    var sourceKey: String = ""
    
    /// 播放来源（线路）列表
    var playFlags: [String] = []
    /// key: flag名称, value: 剧集列表
    var playUrlMap: [String: [Episode]] = [:]
    
    /// 当前选中线路。
    var playFlag: String = ""
    /// 当前播放剧集索引。
    var playIndex: Int = 0
    
    /// 单集信息
    struct Episode: Codable, Identifiable, Hashable {
        var id: String { name }
        /// 集标题。
        let name: String
        /// 集播放地址。
        let url: String
        
        init(name: String, url: String) {
            self.name = name
            self.url = url
        }
    }
    
    /// 从 Movie.Video 和详情数据构建
    static func from(video: Movie.Video, playFrom: String, playUrl: String) -> VodInfo {
        var info = VodInfo(id: video.id)
        info.name = video.name
        info.pic = video.pic
        info.note = video.note
        info.year = video.year
        info.area = video.area
        info.typeName = video.type
        info.director = video.director
        info.actor = video.actor
        info.des = video.des.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        info.sourceKey = video.sourceKey
        
        // 解析播放列表：
        // playFrom 格式: "线路1$$$线路2$$$线路3"
        // playUrl  格式: "第1集$url1#第2集$url2$$$第1集$url3#第2集$url4"
        let flags = playFrom.components(separatedBy: "$$$").filter { !$0.isEmpty }
        let urls = playUrl.components(separatedBy: "$$$")
        
        info.playFlags = flags
        for (i, flag) in flags.enumerated() {
            if i < urls.count {
                let episodes = urls[i].components(separatedBy: "#").compactMap { item -> Episode? in
                    let parts = item.components(separatedBy: "$")
                    guard parts.count >= 2 else { return nil }
                    return Episode(name: parts[0], url: parts[1])
                }
                info.playUrlMap[flag] = episodes
            }
        }
        
        if let first = flags.first {
            info.playFlag = first
        }
        
        return info
    }
    
    /// 当前线路下的剧集。
    var currentEpisodes: [Episode] {
        playUrlMap[playFlag] ?? []
    }
    
    /// 当前线路 + 当前索引对应的剧集对象。
    var currentEpisode: Episode? {
        let eps = currentEpisodes
        guard playIndex >= 0, playIndex < eps.count else { return nil }
        return eps[playIndex]
    }
}
