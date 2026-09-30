import Foundation

/// 单部剧的续播状态，按线路和剧集分别保留进度。
struct VodPlaybackState: Codable {
    /// 当前播放线路标识。
    var flag: String
    /// 当前剧集索引。
    var episodeIndex: Int
    /// 当前剧集播放进度（秒）。
    var progressSeconds: Double
    /// 已观看剧集的进度，键为线路和剧集索引。
    var episodeProgress: [String: Double]

    init(
        flag: String,
        episodeIndex: Int,
        progressSeconds: Double,
        episodeProgress: [String: Double] = [:]
    ) {
        self.flag = flag
        self.episodeIndex = episodeIndex
        self.progressSeconds = progressSeconds
        self.episodeProgress = episodeProgress
        setProgress(progressSeconds, flag: flag, episodeIndex: episodeIndex)
    }

    private enum CodingKeys: String, CodingKey {
        case flag
        case episodeIndex
        case progressSeconds
        case episodeProgress
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        flag = try container.decodeIfPresent(String.self, forKey: .flag) ?? ""
        episodeIndex = max(0, try container.decodeIfPresent(Int.self, forKey: .episodeIndex) ?? 0)
        progressSeconds = max(0, try container.decodeIfPresent(Double.self, forKey: .progressSeconds) ?? 0)
        episodeProgress = try container.decodeIfPresent([String: Double].self, forKey: .episodeProgress) ?? [:]
        setProgress(progressSeconds, flag: flag, episodeIndex: episodeIndex)
    }

    func progress(for flag: String, episodeIndex: Int) -> Double {
        guard episodeIndex >= 0 else { return 0 }
        let value = episodeProgress[Self.progressKey(flag: flag, episodeIndex: episodeIndex)]
            ?? (self.flag == flag && self.episodeIndex == episodeIndex ? progressSeconds : 0)
        return value.isFinite ? max(0, value) : 0
    }

    mutating func setProgress(_ progress: Double, flag: String, episodeIndex: Int) {
        guard episodeIndex >= 0, progress.isFinite else { return }
        episodeProgress[Self.progressKey(flag: flag, episodeIndex: episodeIndex)] = max(0, progress)
    }

    static func progressKey(flag: String, episodeIndex: Int) -> String {
        "\(flag)::\(max(0, episodeIndex))"
    }
}
