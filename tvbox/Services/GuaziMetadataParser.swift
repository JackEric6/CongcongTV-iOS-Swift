import Foundation

struct GuaziMetadataParser {
    struct Values {
        let name: String
        let pic: String
        let year: String
        let area: String
        let type: String
        let director: String
        let actor: String
        let description: String
        let note: String
        let rating: String
    }

    private static let descriptionKeys = [
        "vod_use_content", "d_content", "d_blurb", "d_desc", "d_description",
        "d_intro", "d_synopsis", "d_summary", "vod_content", "vod_blurb",
        "vod_desc", "vod_description", "vod_intro", "vod_summary",
        "synopsis", "summary", "intro", "introduction", "description",
        "desc", "content"
    ]

    private static let containerKeys = [
        "detail", "data", "result", "vod", "info", "item", "vod_info",
        "video", "videos", "list", "rows", "record"
    ]

    private static let ignoredKeys: Set<String> = [
        "vurl_clouds", "play", "play_url", "playurl", "url",
        "streams", "episodes"
    ]

    static func parse(_ value: Any) -> Values {
        let object = payload(from: value)
        let director = string(object["vod_director"])

        return Values(
            name: string(object["vod_name"]).isEmpty
                ? string(object["d_name"])
                : string(object["vod_name"]),
            pic: string(object["vod_pic"]).isEmpty
                ? string(object["d_pic"])
                : string(object["vod_pic"]),
            year: string(object["vod_year"]).isEmpty
                ? string(object["d_year"])
                : string(object["vod_year"]),
            area: string(object["vod_area"]).isEmpty
                ? string(object["d_area"])
                : string(object["vod_area"]),
            type: string(object["vod_class"]).isEmpty
                ? (string(object["d_type"]).isEmpty
                    ? string(object["d_class"])
                    : string(object["d_type"]))
                : string(object["vod_class"]),
            director: director.isEmpty ? string(object["vod_directed"]) : director,
            actor: string(object["vod_actor"]).isEmpty
                ? string(object["d_actor"])
                : string(object["vod_actor"]),
            description: description(in: object),
            note: string(object["new_continue"]).isEmpty
                ? (string(object["vod_remarks"]).isEmpty
                    ? string(object["vod_title"])
                    : string(object["vod_remarks"]))
                : string(object["new_continue"]),
            rating: string(object["vod_scroe"]).isEmpty
                ? string(object["vod_score"])
                : string(object["vod_scroe"])
        )
    }

    static func payload(from value: Any) -> [String: Any] {
        guard let object = bestMetadataObject(in: value)?.object else {
            return value as? [String: Any] ?? [:]
        }
        return object
    }

    private static func description(in object: [String: Any]) -> String {
        for key in descriptionKeys {
            guard let candidate = object[key] else { continue }
            let text = cleanDescription(string(candidate))
            if !text.isEmpty { return text }

            if candidate is [String: Any] || candidate is [Any],
               let nested = bestMetadataObject(in: candidate)?.object {
                let nestedDescription = description(in: nested)
                if !nestedDescription.isEmpty { return nestedDescription }
            }
        }

        for key in containerKeys {
            guard let nested = object[key],
                  let nestedObject = bestMetadataObject(in: nested)?.object else { continue }
            let nestedDescription = description(in: nestedObject)
            if !nestedDescription.isEmpty { return nestedDescription }
        }
        return ""
    }

    private static func bestMetadataObject(in value: Any) -> (object: [String: Any], score: Int)? {
        if let values = value as? [Any] {
            return values
                .compactMap { bestMetadataObject(in: $0) }
                .max { $0.score < $1.score }
        }

        guard let object = value as? [String: Any] else { return nil }
        var best = (object: object, score: metadataScore(object))

        for key in containerKeys {
            guard let nested = object[key],
                  let candidate = bestMetadataObject(in: nested),
                  candidate.score > best.score else { continue }
            best = candidate
        }

        for key in object.keys.sorted()
        where !containerKeys.contains(key) && !ignoredKeys.contains(key) {
            guard let nested = object[key],
                  let candidate = bestMetadataObject(in: nested),
                  candidate.score > best.score else { continue }
            best = candidate
        }

        return best.score > 0 ? best : nil
    }

    private static func metadataScore(_ object: [String: Any]) -> Int {
        let hasDescription = descriptionKeys.contains { key in
            !cleanDescription(string(object[key])).isEmpty
        }
        let metadataKeys = [
            "vod_name", "d_name", "vod_pic", "d_pic", "vod_year", "d_year",
            "vod_area", "d_area", "vod_class", "d_type", "vod_director",
            "vod_directed", "d_id", "vod_id"
        ]
        let fieldCount = metadataKeys.reduce(into: 0) { count, key in
            if !string(object[key]).isEmpty { count += 1 }
        }
        return (hasDescription ? 100 : 0) + fieldCount
    }

    private static func string(_ value: Any?) -> String {
        if let value = value as? String {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let value = value as? NSNumber {
            return value.stringValue
        }
        return ""
    }

    private static func cleanDescription(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }

        var value = raw
            .replacingOccurrences(of: "<br />", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<br/>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "&nbsp;", with: " ", options: .caseInsensitive)
            .replacingOccurrences(of: "&#160;", with: " ", options: .caseInsensitive)
            .replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
            .replacingOccurrences(of: "&lt;", with: "<", options: .caseInsensitive)
            .replacingOccurrences(of: "&gt;", with: ">", options: .caseInsensitive)
            .replacingOccurrences(of: "&quot;", with: "\"", options: .caseInsensitive)
            .replacingOccurrences(of: "&#39;", with: "'", options: .caseInsensitive)
            .replacingOccurrences(of: "&#x27;", with: "'", options: .caseInsensitive)

        value = value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
