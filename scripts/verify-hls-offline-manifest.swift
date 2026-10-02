import Foundation

@main
struct VerifyHLSOfflineManifest {
    static func main() {
        let baseURL = URL(string: "https://media.example.test/path/master.m3u8")!
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio-main",NAME="中文, 原声",URI="audio/index.m3u8"
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs-main",NAME="简体中文",URI="subs/index.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,AUDIO="audio-main"
        low/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720,AUDIO="audio-main",SUBTITLES="subs-main"
        high/index.m3u8
        """

        guard let variant = HLSOfflineManifest.highestVariant(in: playlist, baseURL: baseURL),
              variant.bandwidth == 2_400_000,
              variant.playlistURL.absoluteString == "https://media.example.test/path/high/index.m3u8",
              variant.mediaGroups == ["audio-main", "subs-main"] else {
            fatalError("Highest HLS variant or linked media groups were not parsed")
        }

        let mediaLine = """
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio-main",NAME="中文, 原声",URI="audio/index.m3u8"
        """
        guard HLSOfflineManifest.mediaGroup(in: mediaLine) == "audio-main",
              HLSOfflineManifest.uri(in: mediaLine) == "audio/index.m3u8",
              HLSOfflineManifest.replacingURI(in: mediaLine, with: "resource.m3u8")
                .contains(#"URI="resource.m3u8""#) else {
            fatalError("HLS URI attribute with a quoted comma was not preserved")
        }

        let keyLine = #"#EXT-X-KEY:METHOD=AES-128,URI="../keys/key.bin",IV=0x01"#
        guard HLSOfflineManifest.uri(in: keyLine) == "../keys/key.bin" else {
            fatalError("HLS key URI was not parsed")
        }

        let mediaPlaylist = """
        #EXTM3U
        #EXT-X-KEY:METHOD=AES-128,URI="../keys/key.bin"
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:6.0,
        segments/0001.ts
        #EXTINF:6.0,
        segments/0002.ts
        #EXT-X-KEY:METHOD=NONE
        """
        let resources = HLSOfflineManifest.referencedResourceURLs(
            in: mediaPlaylist,
            baseURL: URL(string: "https://media.example.test/vod/720p/index.m3u8")!
        )
        let resourcePaths = Set(resources.map(\.absoluteString))
        guard resourcePaths == [
            "https://media.example.test/vod/keys/key.bin",
            "https://media.example.test/vod/720p/init.mp4",
            "https://media.example.test/vod/720p/segments/0001.ts",
            "https://media.example.test/vod/720p/segments/0002.ts"
        ] else {
            fatalError("HLS resource enumeration lost a segment, map, or encryption key")
        }
        print("HLS OFFLINE MANIFEST CHECKS PASSED")
    }
}
