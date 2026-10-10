import Foundation

enum SearchSuggestionService {
    private static let endpoint = "https://suggest.video.iqiyi.com/"

    static func fetch(keyword: String) async -> [String] {
        var components = URLComponents(string: endpoint)
        components?.queryItems = [
            URLQueryItem(name: "if", value: "mobile"),
            URLQueryItem(name: "key", value: keyword)
        ]
        guard let url = components?.url?.absoluteString,
              let response = try? await NetworkManager.shared.getString(
                from: url,
                headers: ["Accept": "application/json"],
                timeout: 6,
                maxRetries: 0
              ) else {
            return []
        }
        return parse(response)
    }

    static func parse(_ response: String) -> [String] {
        guard let data = response.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]] else {
            return []
        }

        var seen = Set<String>()
        return entries.prefix(20).compactMap { item in
            let candidate = [item["name"], item["title"]]
                .compactMap { $0 as? String }
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard let name = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  seen.insert(name.lowercased()).inserted else { return nil }
            return name
        }
    }
}
