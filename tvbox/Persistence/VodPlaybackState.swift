import Foundation

/// 单部剧的续播状态，按线路和剧集分别保留进度。
struct VodPlaybackState: Codable {
    /// Reject corrupt seek positions before they reach the player or time-label conversions.
    static let maximumPlaybackPosition: Double = 7 * 24 * 60 * 60

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
        self.progressSeconds = Self.normalizedProgress(progressSeconds)
        self.episodeProgress = episodeProgress.reduce(into: [:]) { result, entry in
            let progress = Self.normalizedProgress(entry.value)
            if progress > 0 {
                result[entry.key] = progress
            }
        }
        setProgress(self.progressSeconds, flag: flag, episodeIndex: episodeIndex)
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
        progressSeconds = Self.normalizedProgress(
            try container.decodeIfPresent(Double.self, forKey: .progressSeconds) ?? 0
        )
        let decodedProgress = try container.decodeIfPresent([String: Double].self, forKey: .episodeProgress) ?? [:]
        episodeProgress = decodedProgress.reduce(into: [:]) { result, entry in
            let progress = Self.normalizedProgress(entry.value)
            if progress > 0 {
                result[entry.key] = progress
            }
        }
        setProgress(progressSeconds, flag: flag, episodeIndex: episodeIndex)
    }

    func progress(for flag: String, episodeIndex: Int) -> Double {
        guard episodeIndex >= 0 else { return 0 }
        let value = episodeProgress[Self.progressKey(flag: flag, episodeIndex: episodeIndex)]
            ?? (self.flag == flag && self.episodeIndex == episodeIndex ? progressSeconds : 0)
        return Self.normalizedProgress(value)
    }

    mutating func setProgress(_ progress: Double, flag: String, episodeIndex: Int) {
        guard episodeIndex >= 0 else { return }
        episodeProgress[Self.progressKey(flag: flag, episodeIndex: episodeIndex)] = Self.normalizedProgress(progress)
    }

    static func normalizedProgress(_ progress: Double) -> Double {
        guard progress.isFinite,
              progress >= 0,
              progress <= maximumPlaybackPosition else {
            return 0
        }
        return progress
    }

    static func progressKey(flag: String, episodeIndex: Int) -> String {
        "\(flag)::\(max(0, episodeIndex))"
    }
}
