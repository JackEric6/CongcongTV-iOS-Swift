import Foundation

struct GuaziPlaylistCatalog {
    static let playlistIDPrefix = "guazi-playlist:"

    struct Playlist {
        let sort: MovieSort.SortData
        let showID: String
        let pid: String
        let embeddedVideos: [[String: Any]]
    }

    static func playlists(from response: [String: Any]) -> [Playlist] {
        var seen = Set<String>()
        return list(in: response).enumerated().compactMap { index, item in
            let title = string(item["type"])
            let showID = string(item["show_id"])
            let pid = string(item["pid"])
            let embeddedVideos = list(in: item["list"])
            guard string(item["p_type"]) == "2", !title.isEmpty, !pid.isEmpty,
                  !showID.isEmpty || !embeddedVideos.isEmpty else {
                return nil
            }

            let suffix = showID.isEmpty ? "embedded-\(index)" : showID
            let id = "\(playlistIDPrefix)\(pid):\(suffix)"
            guard seen.insert(id).inserted else { return nil }
            return Playlist(
                sort: MovieSort.SortData(id: id, name: title),
                showID: showID,
                pid: pid,
                embeddedVideos: embeddedVideos
            )
        }
    }

    static func videos(from response: [String: Any]) -> [[String: Any]] {
        list(in: response)
    }

    private static func list(in response: [String: Any]) -> [[String: Any]] {
        let direct = list(in: response["list"])
        if !direct.isEmpty {
            return direct
        }
        for key in ["data", "result", "payload"] {
            let nested = list(in: response[key])
            if !nested.isEmpty {
                return nested
            }
        }
        return []
    }

    private static func list(in value: Any?) -> [[String: Any]] {
        if let list = value as? [Any] {
            return list.compactMap { $0 as? [String: Any] }
        }
        guard let object = value as? [String: Any] else { return [] }
        for key in ["list", "data", "result", "payload"] {
            let nested = list(in: object[key])
            if !nested.isEmpty {
                return nested
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
