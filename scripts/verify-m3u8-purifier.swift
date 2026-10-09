import Foundation

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

        precondition(M3U8PurifierSettings.defaultEnabled)
        print("M3U8 PURIFIER CHECKS PASSED")
    }
}
