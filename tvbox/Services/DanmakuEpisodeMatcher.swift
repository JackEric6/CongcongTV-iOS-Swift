import Foundation

enum DanmakuEpisodeMatcher {
    private static let markedNumberPatterns = [
        #"第\s*0*(\d+)\s*(?:集|话|期|回)"#,
        #"(?i)(?:^|[\s【\[(])EP?\s*0*(\d+)(?:$|[\s】\])])"#,
        #"(?i)S\s*\d+\s*E\s*0*(\d+)"#
    ]

    static func matches(
        requestedEpisode: String,
        title: String,
        explicitNumber: Int = -1
    ) -> Bool {
        let requested = normalize(requestedEpisode)
        let candidate = normalize(title)
        guard !requested.isEmpty else { return true }
        let requestedNumber = firstNumber(in: requestedEpisode)
        if requestedNumber <= 0 { return candidate.contains(requested) }
        if explicitNumber == requestedNumber { return true }
        return markedNumberPatterns.contains { pattern in
            captureNumber(pattern, in: title) == requestedNumber
        }
    }

    private static func firstNumber(in value: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: #"\d+"#),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range, in: value) else { return -1 }
        return Int(value[range]) ?? -1
    }

    private static func captureNumber(_ pattern: String, in value: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        let matchRange = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
        guard let range = Range(matchRange, in: value) else { return nil }
        return Int(value[range])
    }

    private static func normalize(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            .lowercased()
    }
}
