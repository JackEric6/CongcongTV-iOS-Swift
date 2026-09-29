import Foundation

struct GuaziPlaylistCatalog {
    static let playlistIDPrefix = "guazi-playlist:"

    struct Playlist: Hashable {
        let sort: MovieSort.SortData
        let showID: String
        let pid: String
    }

    /// Matches Android's home navigation: video tabs use their own pid, while
    /// the recommendation tab is backed by the fixed homepage pid 1.
    static func playlistNavigationPIDs(from response: [String: Any]) -> [String] {
        var seen = Set<String>()
        return list(in: response).compactMap { item in
            let type = string(item["type"])
            let pid: String
            switch type {
            case "video":
                pid = string(item["pid"])
            case "recommend":
                pid = "1"
            default:
                return nil
            }
            guard !pid.isEmpty, seen.insert(pid).inserted else { return nil }
            return pid
        }
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
        (response["list"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
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
