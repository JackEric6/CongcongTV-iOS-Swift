import Foundation

@main
struct VerifyPlaybackVolume {
    static func main() {
        var volume = PlaybackVolumeState()
        precondition(volume.toggle(currentVolume: 0) == 0.05)
        precondition(volume.toggle(currentVolume: 0.05) == 0)
        precondition(volume.toggle(currentVolume: 0) == 0.05)

        var externallyMuted = PlaybackVolumeState()
        precondition(externallyMuted.toggle(currentVolume: 0.8) == 0)
        precondition(externallyMuted.toggle(currentVolume: 0) == 0.8)

        print("PLAYBACK VOLUME BUTTON CHECKS PASSED")
    }
}
