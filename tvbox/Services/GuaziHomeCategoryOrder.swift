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

        return categories.compactMap { definition in
            let (id, name) = definition
            guard var category = categoriesByID[id] else { return nil }
            category.name = name
            return category
        }
    }
}
