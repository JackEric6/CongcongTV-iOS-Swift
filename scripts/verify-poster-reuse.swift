import Foundation

extension URL {
    static func posterURL(from raw: String) -> URL? {
        URL(string: raw)
    }
}

@main
struct VerifyPosterReuse {
    static func main() async {
        let title = "跨源海报复用校验"
        let poster = "https://images.example.test/poster.jpg"
        let candidates = [
            Movie.Video(id: "provider-1", name: title, pic: poster, sourceKey: "xgzy"),
            Movie.Video(id: "ikanbot-1", name: title, sourceKey: "ikanbot"),
            Movie.Video(id: "zanpian-1", name: title, sourceKey: "zanpian"),
            Movie.Video(id: "zanpian-2", name: "没有同名海报", sourceKey: "zanpian")
        ]

        let results = await PosterCache.shared.enrich(candidates)
        precondition(results.count == 4)
        precondition(results.first(where: { $0.sourceKey == "ikanbot" })?.pic == poster)
        precondition(results.first(where: { $0.id == "zanpian-1" })?.pic == poster)
        precondition(results.first(where: { $0.id == "zanpian-2" })?.pic.isEmpty == true)
        print("CROSS-SOURCE POSTER REUSE CHECKS PASSED")
    }
}
