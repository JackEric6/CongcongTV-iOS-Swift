import Foundation

enum DanmakuTimelinePolicy {
    static func playbackRate(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 1 }
        return min(max(value, 0.25), 4)
    }

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

    static func canFollowScrollingBullet(
        previousRightEdge: Double,
        previousSpeed: Double,
        nextSpeed: Double,
        viewportWidth: Double,
        minimumGap: Double
    ) -> Bool {
        guard previousRightEdge.isFinite,
              previousSpeed.isFinite,
              nextSpeed.isFinite,
              viewportWidth.isFinite,
              minimumGap.isFinite,
              previousSpeed > 0,
              nextSpeed > 0,
              viewportWidth > 0 else { return false }
        guard previousRightEdge <= viewportWidth - max(0, minimumGap) else { return false }
        guard nextSpeed > previousSpeed else { return true }

        let catchUpTime = (viewportWidth - previousRightEdge) / (nextSpeed - previousSpeed)
        let previousExitTime = previousRightEdge / previousSpeed
        return catchUpTime >= previousExitTime
    }
}
