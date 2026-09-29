import Foundation

enum GuaziHomeCategoryOrder {
    private static let categories = [
        ("2", "电视剧"),
        ("1", "电影"),
        ("64", "短剧"),
        ("3", "综艺"),
        ("4", "动漫")
    ]

    static func sort(_ source: [MovieSort.SortData]) -> [MovieSort.SortData] {
        let categoriesByID = Dictionary(
            source.map { ($0.id.trimmingCharacters(in: .whitespacesAndNewlines), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seenPlaylistIDs = Set<String>()
        let playlists = source.filter {
            $0.id.hasPrefix(GuaziPlaylistCatalog.playlistIDPrefix)
                && seenPlaylistIDs.insert($0.id).inserted
        }
        var orderedPlaylists = playlists
        if let hotIndex = playlists.firstIndex(where: {
            let name = $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name == "热门" || name.contains("热门推荐")
        }), hotIndex > 0 {
            orderedPlaylists.insert(orderedPlaylists.remove(at: hotIndex), at: 0)
        }

        let orderedCategories = categories.compactMap { definition in
            let (id, name) = definition
            guard var category = categoriesByID[id] else { return nil }
            category.name = name
            return category
        }
        return orderedPlaylists + orderedCategories
    }
}
