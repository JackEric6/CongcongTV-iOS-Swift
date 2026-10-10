import Foundation

struct PlaybackVolumeState {
    private(set) var lastUnmutedVolume: Float?
    private(set) var isMutedByButton = false

    mutating func toggle(currentVolume: Float) -> Float {
        if currentVolume > 0.02 {
            lastUnmutedVolume = currentVolume
            isMutedByButton = true
            return 0
        }

        guard isMutedByButton else {
            return min(max(currentVolume + 0.05, 0.05), 1)
        }

        isMutedByButton = false
        return min(max(lastUnmutedVolume ?? 0.05, 0.05), 1)
    }
}
