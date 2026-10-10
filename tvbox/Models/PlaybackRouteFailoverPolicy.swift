import Foundation

enum PlaybackRouteFailoverPolicy {
    static func nextFlag(
        currentFlag: String,
        orderedFlags: [String],
        episodeCounts: [String: Int],
        episodeIndex: Int,
        attemptedFlags: Set<String>
    ) -> String? {
        guard episodeIndex >= 0,
              let currentIndex = orderedFlags.firstIndex(of: currentFlag),
              !orderedFlags.isEmpty else {
            return nil
        }

        for offset in 1...orderedFlags.count {
            let candidate = orderedFlags[(currentIndex + offset) % orderedFlags.count]
            guard !attemptedFlags.contains(candidate),
                  episodeCounts[candidate, default: 0] > episodeIndex else {
                continue
            }
            return candidate
        }
        return nil
    }
}
