import Foundation

enum DanmakuTimelinePolicy {
    static func didSeekBackward(
        from previousTime: TimeInterval?,
        to currentTime: TimeInterval,
        tolerance: TimeInterval = 0.5
    ) -> Bool {
        guard let previousTime,
              previousTime.isFinite,
              currentTime.isFinite,
              previousTime >= 0,
              currentTime >= 0 else { return false }
        return currentTime < previousTime - max(0, tolerance)
    }
}
