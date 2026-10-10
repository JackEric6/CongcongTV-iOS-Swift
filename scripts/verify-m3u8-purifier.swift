import Foundation

final class NetworkManager {
    static let shared = NetworkManager()
    private(set) var requestCount = 0

    func getString(
        from url: String,
        headers: [String: String]? = nil,
        maxRetries: Int = 3
    ) async throws -> String {
        requestCount += 1
        throw CocoaError(.fileReadUnknown)
    }
}

@main
struct VerifyM3U8Purifier {
    static func main() async {
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
        precondition(result.removedSegmentCount == 2)
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

        var frameRateLines = ["#EXTM3U", "#EXT-X-TARGETDURATION:5", "#EXT-X-DISCONTINUITY"]
        for index in 1...20 {
            frameRateLines.append("#EXTINF:4.080,")
            frameRateLines.append("https://cdn.example/video/main-\(index).ts")
        }
        frameRateLines.append("#EXT-X-DISCONTINUITY")
        for index in 1...3 {
            frameRateLines.append("#EXTINF:4.125,")
            frameRateLines.append("https://cdn.example/video/block-\(index).ts")
        }
        frameRateLines.append("#EXT-X-DISCONTINUITY")
        for index in 21...30 {
            frameRateLines.append("#EXTINF:4.080,")
            frameRateLines.append("https://cdn.example/video/main-\(index).ts")
        }
        frameRateLines.append("#EXT-X-ENDLIST")
        let frameRateResult = M3U8ManifestPurifier.purify(
            baseURL: URL(string: "https://cdn.example/video/index.m3u8")!,
            content: frameRateLines.joined(separator: "\n")
        )
        precondition(
            frameRateResult.removedSegmentCount == 3,
            "frame-rate removal count=\(frameRateResult.removedSegmentCount), adBlockPresent=\(frameRateResult.content.contains("block-1.ts"))"
        )
        precondition(!frameRateResult.content.contains("block-1.ts"))
        precondition((1...30).allSatisfy {
            frameRateResult.content.contains("main-\($0).ts")
        })

        var finalPrecisionLines = ["#EXTM3U", "#EXT-X-TARGETDURATION:5", "#EXT-X-DISCONTINUITY"]
        for index in 1...20 {
            finalPrecisionLines.append("#EXTINF:4.080,")
            finalPrecisionLines.append("https://cdn.example/video/main-\(index).ts")
        }
        finalPrecisionLines.append("#EXT-X-DISCONTINUITY")
        for index in 1...3 {
            finalPrecisionLines.append("#EXTINF:4.08,")
            finalPrecisionLines.append("https://cdn.example/video/tail-\(index).ts")
        }
        finalPrecisionLines.append("#EXT-X-ENDLIST")
        let finalPrecisionResult = M3U8ManifestPurifier.purify(
            baseURL: URL(string: "https://cdn.example/video/index.m3u8")!,
            content: finalPrecisionLines.joined(separator: "\n")
        )
        precondition(finalPrecisionResult.removedSegmentCount == 0)
        precondition((1...3).allSatisfy { finalPrecisionResult.content.contains("tail-\($0).ts") })

        var finalFrameRateLines = ["#EXTM3U", "#EXT-X-TARGETDURATION:5", "#EXT-X-DISCONTINUITY"]
        for index in 1...20 {
            finalFrameRateLines.append("#EXTINF:4.080,")
            finalFrameRateLines.append("https://cdn.example/video/main-\(index).ts")
        }
        finalFrameRateLines.append("#EXT-X-DISCONTINUITY")
        for index in 1...3 {
            finalFrameRateLines.append("#EXTINF:4.125,")
            finalFrameRateLines.append("https://cdn.example/video/tail-\(index).ts")
        }
        finalFrameRateLines.append("#EXT-X-ENDLIST")
        let finalFrameRateResult = M3U8ManifestPurifier.purify(
            baseURL: URL(string: "https://cdn.example/video/index.m3u8")!,
            content: finalFrameRateLines.joined(separator: "\n")
        )
        precondition(finalFrameRateResult.removedSegmentCount == 0)
        precondition((1...3).allSatisfy { finalFrameRateResult.content.contains("tail-\($0).ts") })

        let ambiguousFrameRateLines = frameRateLines.map { line in
            line.replacingOccurrences(of: "4.080", with: "4.040")
                .replacingOccurrences(of: "4.125", with: "4.042")
        }
        let ambiguousFrameRateResult = M3U8ManifestPurifier.purify(
            baseURL: URL(string: "https://cdn.example/video/index.m3u8")!,
            content: ambiguousFrameRateLines.joined(separator: "\n")
        )
        precondition(ambiguousFrameRateResult.removedSegmentCount == 0)
        precondition(ambiguousFrameRateResult.content.contains("block-1.ts"))

        let originalGuaziURL = "https://guazi.example/video/index.m3u8?token=original"
        let guaziResult = await M3U8Purifier.shared.prepare(
            urlString: originalGuaziURL,
            headers: ["User-Agent": "Guazi"],
            sourceKey: "GuAzI"
        )
        precondition(guaziResult.url == originalGuaziURL)
        precondition(!guaziResult.didPurify && guaziResult.removedSegmentCount == 0)
        precondition(NetworkManager.shared.requestCount == 0)
        print("M3U8 PURIFIER AND PLAYBACK SAFETY CHECKS PASSED")
    }
}
