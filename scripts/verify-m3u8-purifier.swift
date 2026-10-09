import Foundation

final class NetworkManager {
    static let shared = NetworkManager()

    func getString(
        from url: String,
        headers: [String: String]? = nil,
        maxRetries: Int = 3
    ) async throws -> String {
        throw CocoaError(.fileReadUnknown)
    }
}

@main
struct VerifyM3U8Purifier {
    static func main() {
        let manifest = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:8
        #EXTINF:6.0,
        https://cdn.example/video/0001.ts
        #EXTINF:6.0,
        https://cdn.example/video/0002.ts
        #EXT-X-CUE-OUT:DURATION=12
        #EXTINF:6.0,
        https://ads.example/ad/001.ts
        #EXTINF:6.0,
        https://ads.example/ad/002.ts
        #EXT-X-CUE-IN
        #EXTINF:6.0,
        https://cdn.example/video/0003.ts
        #EXT-X-ENDLIST
        """
        .replacingOccurrences(of: "        ", with: "")

        let result = M3U8ManifestPurifier.purify(
            baseURL: URL(string: "https://cdn.example/video/index.m3u8")!,
            content: manifest
        )
        precondition(result.removedSegmentCount >= 2)
        precondition(result.content.contains("https://cdn.example/video/0001.ts"))
        precondition(result.content.contains("https://cdn.example/video/0003.ts"))
        precondition(!result.content.contains("ads.example"))
        precondition(result.content.contains("#EXT-X-ENDLIST"))

        let normalManifest = [
            "#EXTM3U",
            "#EXT-X-TARGETDURATION:6",
            "#EXTINF:6.0,",
            "https://cdn.example/video/0001.ts",
            "#EXTINF:6.0,",
            "https://cdn.example/video/0002.ts",
            "#EXT-X-ENDLIST"
        ].joined(separator: "\n")
        let normalResult = M3U8ManifestPurifier.purify(
            baseURL: URL(string: "https://cdn.example/video/index.m3u8")!,
            content: normalManifest
        )
        precondition(normalResult.removedSegmentCount == 0)
        precondition(normalResult.content == normalManifest)

        var minorityLines = ["#EXTM3U", "#EXT-X-TARGETDURATION:6"]
        for index in 1...8 {
            minorityLines.append("#EXTINF:6.0,")
            minorityLines.append(String(format: "https://cdn.example/video/segment%04d.ts", index))
        }
        for index in 1...2 {
            minorityLines.append("#EXTINF:6.0,")
            minorityLines.append(String(format: "https://ads.example/ad/ad%04d.ts", index))
        }
        minorityLines.append("#EXT-X-ENDLIST")
        let minorityResult = M3U8ManifestPurifier.purify(
            baseURL: URL(string: "https://cdn.example/video/index.m3u8")!,
            content: minorityLines.joined(separator: "\n")
        )
        precondition(minorityResult.removedSegmentCount == 2)
        precondition((1...8).allSatisfy {
            minorityResult.content.contains(String(format: "segment%04d.ts", $0))
        })
        precondition(!minorityResult.content.contains("ads.example"))

        var rollbackLines = ["#EXTM3U", "#EXT-X-TARGETDURATION:6"]
        for index in 1...2 {
            rollbackLines.append("#EXTINF:6.0,")
            rollbackLines.append(String(format: "https://cdn.example/video/normal%04d.ts", index))
        }
        rollbackLines.append("#EXT-X-CUE-OUT:DURATION=36")
        for index in 1...6 {
            rollbackLines.append("#EXTINF:6.0,")
            rollbackLines.append(String(format: "https://cdn.example/video/ad%04d.ts", index))
        }
        rollbackLines.append("#EXT-X-CUE-IN")
        for index in 3...4 {
            rollbackLines.append("#EXTINF:6.0,")
            rollbackLines.append(String(format: "https://cdn.example/video/normal%04d.ts", index))
        }
        rollbackLines.append("#EXT-X-ENDLIST")
        let rollbackManifest = rollbackLines.joined(separator: "\n")
        let rollbackResult = M3U8ManifestPurifier.purify(
            baseURL: URL(string: "https://cdn.example/video/index.m3u8")!,
            content: rollbackManifest
        )
        precondition(rollbackResult.removedSegmentCount == 0)
        precondition(rollbackResult.content == rollbackManifest)
        precondition((1...4).allSatisfy {
            rollbackResult.content.contains(String(format: "normal%04d.ts", $0))
        })
        precondition((1...6).allSatisfy {
            rollbackResult.content.contains(String(format: "ad%04d.ts", $0))
        })

        precondition(M3U8PurifierSettings.defaultEnabled)
        print("M3U8 PURIFIER AND PLAYBACK SAFETY CHECKS PASSED")
    }
}
