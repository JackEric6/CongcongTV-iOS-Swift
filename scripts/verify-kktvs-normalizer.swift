import Foundation

@main
struct CmsNormalizerSmokeTest {
    static func main() throws {
        let legacyAPI = "http://127.0.0.1:9978/kktvs?source=https%3A%2F%2Fwww.kktvs.com%2Fapi.php%2Fprovide%2Fvod"
        let directAPI = KktvsResponseNormalizer.normalizeSourceAPI(legacyAPI, sourceKey: "kktvs")
        precondition(directAPI == "https://www.kktvs.com/api.php/provide/vod", "legacy localhost API was not rewritten")
        precondition(
            KktvsResponseNormalizer.normalizeSourceAPI(
                "http://127.0.0.1:9978/xgzy?source=https%3A%2F%2Fcaiji.xgzyapi.com%2Fapi.php%2Fprovide%2Fvod%2Ffrom%2Fxiguam3u8%2F",
                sourceKey: "xgzy"
            ) == "https://caiji.xgzyapi.com/api.php/provide/vod/from/xiguam3u8/",
            "xgzy localhost API was not rewritten"
        )

        let input = #"{"list":[{"vod_play_from":"2mplayer$$$hxplayer","vod_play_url":"01$https://www.kktvs.com/vod/?url=https%3A%2F%2Fmedia.test%2Ftwo.mp4$$$01$//media.test/one.m3u8","vod_play_server":"two$$$hls"}]}"#
        guard let data = KktvsResponseNormalizer.normalize(input).data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vod = (root["list"] as? [[String: Any]])?.first else {
            fatalError("normalized KKT response is not valid JSON")
        }
        precondition(vod["vod_play_from"] as? String == "hxplayer$$$2mplayer", "HLS line was not prioritized")
        precondition(
            vod["vod_play_url"] as? String == "01$https://media.test/one.m3u8$$$01$https://media.test/two.mp4",
            "episode URLs were not normalized and kept aligned"
        )
        precondition(vod["vod_play_server"] as? String == "hls$$$two", "line metadata lost alignment")

        let playerPage = #"<script>var player={"url":"https:\/\/media.test\/hls\/index.m3u8?token=1"};</script>"#
        precondition(
            KktvsResponseNormalizer.extractMediaURL(
                from: playerPage,
                baseURL: "https://www.kktvs.com/vod/1.html"
            ) == "https://media.test/hls/index.m3u8?token=1",
            "player page media URL extraction failed"
        )

        print("CMS NORMALIZER SMOKE TESTS PASSED")
    }
}
