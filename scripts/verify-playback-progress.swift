import Foundation

@main
struct VerifyPlaybackProgress {
    static func main() throws {
        let legacyJSON = Data(
            #"{"flag":"line-a","episodeIndex":0,"progressSeconds":525}"#.utf8
        )
        var state = try JSONDecoder().decode(VodPlaybackState.self, from: legacyJSON)
        guard state.progress(for: "line-a", episodeIndex: 0) == 525,
              state.progress(for: "line-a", episodeIndex: 1) == 0 else {
            fatalError("Legacy playback state did not decode with its current episode progress")
        }

        state.setProgress(82, flag: "line-a", episodeIndex: 1)
        state.flag = "line-a"
        state.episodeIndex = 1
        state.progressSeconds = 82
        let roundTrip = try JSONDecoder().decode(
            VodPlaybackState.self,
            from: JSONEncoder().encode(state)
        )
        guard roundTrip.progress(for: "line-a", episodeIndex: 0) == 525,
              roundTrip.progress(for: "line-a", episodeIndex: 1) == 82 else {
            fatalError("Switching episodes did not preserve both episode positions")
        }

        let differentLine = try JSONDecoder().decode(
            VodPlaybackState.self,
            from: JSONEncoder().encode(
                VodPlaybackState(
                    flag: "line-b",
                    episodeIndex: 1,
                    progressSeconds: 36,
                    episodeProgress: roundTrip.episodeProgress
                )
            )
        )
        guard differentLine.progress(for: "line-b", episodeIndex: 1) == 36,
              differentLine.progress(for: "line-a", episodeIndex: 1) == 82 else {
            fatalError("Playback progress was not isolated by line and episode")
        }

        let corruptProgress = try JSONDecoder().decode(
            VodPlaybackState.self,
            from: Data(
                #"{"flag":"line-a","episodeIndex":0,"progressSeconds":1e300,"episodeProgress":{"line-a::0":1e300}}"#.utf8
            )
        )
        guard corruptProgress.progressSeconds == 0,
              corruptProgress.progress(for: "line-a", episodeIndex: 0) == 0,
              VodPlaybackState.normalizedProgress(.infinity) == 0,
              VodPlaybackState.normalizedProgress(-1) == 0 else {
            fatalError("Corrupt playback positions were not rejected")
        }
        print("PLAYBACK PROGRESS LEDGER CHECKS PASSED")
    }
}
