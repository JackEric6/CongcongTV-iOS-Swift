import Foundation

/// 视频详情模型 - 对应 Android 版 VodInfo.java
struct VodInfo: Codable, Identifiable, Sendable {
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
    /// 豆瓣评分；跨源详情补全时仅填充当前详情缺失的评分。
    var doubanRating: String = ""
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
    struct Episode: Codable, Identifiable, Hashable, Sendable {
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
        info.doubanRating = video.doubanRating
        info.sourceKey = video.sourceKey
        
        // 解析播放列表：
        // playFrom 格式: "线路1$$$线路2$$$线路3"
        // playUrl  格式: "第1集$url1#第2集$url2$$$第1集$url3#第2集$url4"
        let flags = playFrom.components(separatedBy: "$$$")
        let urls = playUrl.components(separatedBy: "$$$")

        for (index, rawFlag) in flags.enumerated() where urls.indices.contains(index) {
            let flag = rawFlag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !flag.isEmpty else { continue }
            let episodes = urls[index].components(separatedBy: "#").compactMap { item -> Episode? in
                guard let separator = item.firstIndex(of: "$"), separator != item.startIndex else { return nil }
                let name = String(item[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                let url = String(item[item.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !url.isEmpty else { return nil }
                return Episode(name: name, url: url)
            }
            guard !episodes.isEmpty else { continue }
            info.playFlags.append(flag)
            info.playUrlMap[flag] = episodes
        }
        
        if let first = info.playFlags.first {
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
