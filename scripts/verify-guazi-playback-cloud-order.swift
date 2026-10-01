import Foundation

@main
struct VerifyGuaziPlaybackCloudOrder {
    static func main() {
        let clouds = [
            GuaziPlaybackCloud(index: 2, id: "cloud-c", name: "线路C"),
            GuaziPlaybackCloud(index: 0, id: "cloud-a", name: "线路A"),
            GuaziPlaybackCloud(index: 1, id: "cloud-b", name: "线路B")
        ]

        let defaultOrder = GuaziPlaybackCloudOrder.ordered(clouds, preferredName: "")
        require(defaultOrder.map(\.id) == ["cloud-a", "cloud-b", "cloud-c"],
                "new playback must follow Android's API cloud order")

        let resumeOrder = GuaziPlaybackCloudOrder.ordered(clouds, preferredName: "线路B")
        require(resumeOrder.map(\.id) == ["cloud-b", "cloud-a", "cloud-c"],
                "resume must try the saved line first and then preserve API order")
        print("GUAZI PLAYBACK CLOUD ORDER CHECKS PASSED")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError("FAIL: \(message)")
        }
    }
}
