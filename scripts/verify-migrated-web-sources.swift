import Foundation

extension URL {
    static func posterURL(from raw: String) -> URL? {
        URL(string: raw)
    }
}

struct SourceBean {
    let api: String
    let key: String
    let headers: [String: String]?
}

enum SourceError: Error {
    case invalidApiUrl(String)
    case invalidPlayableURL(String)
    case invalidResponse(String)
}

struct Movie {
    struct Video {
        var id: String
        var name: String
        var pic = ""
        var note = ""
        var year = ""
        var area = ""
        var actor = ""
        var des = ""
        var sourceKey = ""

        init(id: String, name: String, sourceKey: String = "") {
            self.id = id
            self.name = name
            self.sourceKey = sourceKey
        }
    }
}

struct VodInfo {
    struct Episode {
        let name: String
        let url: String
    }

    static func from(video: Movie.Video, playFrom: String, playUrl: String) -> VodInfo { VodInfo() }
}

final class NetworkManager {
    static let shared = NetworkManager()

    func getString(
        from url: String,
        headers: [String: String]?,
        timeout: Int?,
        maxRetries: Int
    ) async throws -> String {
        throw CocoaError(.fileReadUnknown)
    }
}

enum KktvsResponseNormalizer {
    static func extractMediaURL(from body: String, baseURL: String) -> String? { nil }
}

@main
struct VerifyMigratedWebSources {
    static func main() throws {
        precondition(
            MigratedWebSourceService.buildIkanbotToken(
                videoID: "936072",
                eToken: "nd44cd4f0ef214c5ceru378be3bb9h128607b14"
            ) == "d44cd4f0f214c5ce378be3bb28607b14"
        )
        precondition(MigratedWebSourceService.buildIkanbotToken(videoID: "1", eToken: "short").isEmpty)

        let resData = [[
            "flag": "gsm3u8",
            "url": "第1集$https://video.example/one.m3u8#第2集$https://video.example/two.m3u8"
        ]]
        let resDataText = String(data: try JSONSerialization.data(withJSONObject: resData), encoding: .utf8)!
        let response = try JSONSerialization.data(withJSONObject: [
            "state": 1,
            "data": ["list": [["resData": resDataText]]]
        ])
        let parsed = MigratedWebSourceService.parseIkanbotSources(String(data: response, encoding: .utf8)!)
        precondition(parsed.0 == ["gsm3u8"])
        precondition(parsed.1 == [
            "第1集$https://video.example/one.m3u8#第2集$https://video.example/two.m3u8"
        ])

        let zanpianHTML = """
        <li><a class="module_play_img" href="/China/chenmoderongyao/">
        <img src="https://img.example/poster.jpg" alt="沉默的荣耀"/>
        <label>共39集 连载至第39集</label></a>
        <div class="play-txt"><h5><a href="/China/chenmoderongyao/"><font>沉默的荣耀</font></a></h5></div></li>
        """
        let cards = MigratedWebSourceService.parseZanpianCards(
            zanpianHTML,
            sourceKey: "zanpian",
            baseURL: URL(string: "https://www.zanpian.org/")!
        )
        precondition(cards.count == 1)
        precondition(cards[0].id == "/China/chenmoderongyao/")
        precondition(cards[0].name == "沉默的荣耀")
        precondition(cards[0].pic.isEmpty)

        let suggestions = SearchSuggestionService.parse("""
        {"code":"A00000","data":[{"name":"沉默的荣耀"},{"title":"荣耀之后"},{"name":"沉默的荣耀"}]}
        """)
        precondition(suggestions == ["沉默的荣耀", "荣耀之后"])
        print("MIGRATED WEB SOURCE AND SEARCH SUGGESTION CHECKS PASSED")
    }
}
