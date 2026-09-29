import Foundation

struct GuaziPlaylistCatalog {
    static let playlistIDPrefix = "guazi-playlist:"

    struct Playlist: Hashable {
        let sort: MovieSort.SortData
        let showID: String
        let pid: String
    }

    static func playlists(from response: [String: Any]) -> [Playlist] {
        var seen = Set<String>()
        return list(in: response).compactMap { item in
            let title = string(item["type"])
            let showID = string(item["show_id"])
            let pid = string(item["pid"])
            guard string(item["p_type"]) == "2",
                  !title.isEmpty,
                  !showID.isEmpty,
                  !pid.isEmpty else {
                return nil
            }

            let id = "\(playlistIDPrefix)\(pid):\(showID)"
            guard seen.insert(id).inserted else { return nil }
            return Playlist(
                sort: MovieSort.SortData(id: id, name: title),
                showID: showID,
                pid: pid
            )
        }
    }

    static func videos(from response: [String: Any]) -> [[String: Any]] {
        list(in: response)
    }

    private static func list(in response: [String: Any]) -> [[String: Any]] {
        if let list = response["list"] as? [Any] {
            return list.compactMap { $0 as? [String: Any] }
        }

        for key in ["data", "result", "payload"] {
            guard let nested = response[key] as? [String: Any] else { continue }
            let nestedList = list(in: nested)
            if !nestedList.isEmpty {
                return nestedList
            }
        }
        return []
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
}
