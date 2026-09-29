import Foundation

enum GuaziSearchMatcher {
    static func matches(keyword: String, title: String) -> Bool {
        let normalizedKeyword = normalize(keyword)
        return !normalizedKeyword.isEmpty && normalize(title).contains(normalizedKeyword)
    }

    private static func normalize(_ value: String) -> String {
        let normalized = value.precomposedStringWithCompatibilityMapping
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        return String(normalized.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        })
    }
}
