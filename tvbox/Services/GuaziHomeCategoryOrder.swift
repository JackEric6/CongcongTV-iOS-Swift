import Foundation

enum GuaziHomeCategoryOrder {
    private static let categories = [
        ("2", "电视剧"),
        ("1", "电影"),
        ("64", "短剧"),
        ("3", "综艺"),
        ("4", "动漫")
    ]

    private static let prioritizedPlaylistIDs = [
        "guazi-playlist:4:74151",
        "guazi-playlist:3:46296",
        "guazi-playlist:3:19260",
        "guazi-playlist:3:17613",
        "guazi-playlist:1:130",
        "guazi-playlist:5:10772",
        "guazi-playlist:4:24058",
        "guazi-playlist:4:24066",
        "guazi-playlist:4:24057",
        "guazi-playlist:4:24067",
        "guazi-playlist:16:38579",
        "guazi-playlist:3:16560",
        "guazi-playlist:3:8",
        "guazi-playlist:6:6663"
    ]

    private static let hiddenPlaylistIDs: Set<String> = [
        "guazi-playlist:16:embedded-0"
    ]

    static func prioritizedPageIDs(in pageIDs: [String]) -> [String] {
        let requiredPageIDs = Set(prioritizedPlaylistIDs.compactMap { id -> String? in
            let components = id.split(separator: ":")
            guard components.count >= 3 else { return nil }
            return String(components[1])
        })
        return pageIDs.filter { requiredPageIDs.contains($0) }
    }

    static func sort(_ source: [MovieSort.SortData]) -> [MovieSort.SortData] {
        let categoriesByID = Dictionary(
            source.map { ($0.id.trimmingCharacters(in: .whitespacesAndNewlines), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seenPlaylistIDs = Set<String>()
        let playlists = source.filter {
            $0.id.hasPrefix(GuaziPlaylistCatalog.playlistIDPrefix)
                && !hiddenPlaylistIDs.contains($0.id)
                && seenPlaylistIDs.insert($0.id).inserted
        }
        var playlistsByID = Dictionary(
            playlists.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var orderedPlaylists = prioritizedPlaylistIDs.compactMap { id -> MovieSort.SortData? in
            guard var playlist = playlistsByID.removeValue(forKey: id) else { return nil }
            if id == "guazi-playlist:3:19260" {
                playlist.name = "TC抢先看"
            }
            return playlist
        }
        orderedPlaylists.append(contentsOf: playlists.compactMap { playlist in
            guard playlistsByID.removeValue(forKey: playlist.id) != nil else { return nil }
            return playlist
        })

        let orderedCategories = categories.compactMap { definition -> MovieSort.SortData? in
            let (id, name) = definition
            guard var category = categoriesByID[id] else { return nil }
            category.name = name
            return category
        }
        // 保留瓜子接口返回的全部有效片单；请求层负责受控并发和渐进发布，
        // 不再因为标签数量截断首页栏目。
        return orderedPlaylists + orderedCategories
    }
}
