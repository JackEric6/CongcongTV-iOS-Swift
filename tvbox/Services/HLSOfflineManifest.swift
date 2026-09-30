import Foundation

enum HLSOfflineManifest {
    struct Variant {
        let streamInfo: String
        let playlistURL: URL
        let uriLineIndex: Int
        let bandwidth: Int
        let mediaGroups: Set<String>
    }

    private static let attributePattern = try! NSRegularExpression(
        pattern: #"(?i)(?:^|,)\s*([A-Z0-9-]+)\s*=\s*("[^"]*"|'[^']*'|[^,]*)"#
    )
    private static let uriPattern = try! NSRegularExpression(
        pattern: #"(?i)\bURI\s*=\s*("[^"]*"|'[^']*'|[^,\s]*)"#
    )

    static func highestVariant(in playlist: String, baseURL: URL) -> Variant? {
        let lines = playlist.components(separatedBy: .newlines)
        var best: Variant?

        for index in lines.indices
        where lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased().hasPrefix("#EXT-X-STREAM-INF:") {
            let streamInfo = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            var uriIndex = index + 1
            while uriIndex < lines.count {
                let value = lines[uriIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty, !value.hasPrefix("#") {
                    guard let url = URL(string: value, relativeTo: baseURL)?.absoluteURL else { break }
                    let bandwidth = Int(
                        attribute("AVERAGE-BANDWIDTH", in: streamInfo)
                            ?? attribute("BANDWIDTH", in: streamInfo)
                            ?? ""
                    ) ?? 0
                    let candidate = Variant(
                        streamInfo: streamInfo,
                        playlistURL: url,
                        uriLineIndex: uriIndex,
                        bandwidth: bandwidth,
                        mediaGroups: mediaGroups(in: streamInfo)
                    )
                    if best == nil || candidate.bandwidth > best!.bandwidth {
                        best = candidate
                    }
                    break
                }
                uriIndex += 1
            }
        }
        return best
    }

    static func attribute(_ name: String, in line: String) -> String? {
        let searchRange = NSRange(line.startIndex..<line.endIndex, in: line)
        for match in attributePattern.matches(in: line, range: searchRange) {
            guard let nameRange = Range(match.range(at: 1), in: line),
                  line[nameRange].caseInsensitiveCompare(name) == .orderedSame,
                  let valueRange = Range(match.range(at: 2), in: line) else {
                continue
            }
            var value = String(line[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2,
               (value.first == "\"" && value.last == "\"")
                || (value.first == "'" && value.last == "'") {
                value.removeFirst()
                value.removeLast()
            }
            return value
        }
        return nil
    }

    static func mediaGroups(in streamInfo: String) -> Set<String> {
        ["AUDIO", "VIDEO", "SUBTITLES", "CLOSED-CAPTIONS"].reduce(into: Set<String>()) { groups, name in
            if let value = attribute(name, in: streamInfo), !value.isEmpty, value.uppercased() != "NONE" {
                groups.insert(value)
            }
        }
    }

    static func mediaGroup(in line: String) -> String? {
        guard line.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased().hasPrefix("#EXT-X-MEDIA:") else {
            return nil
        }
        return attribute("GROUP-ID", in: line)
    }

    static func uri(in line: String) -> String? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = uriPattern.firstMatch(in: line, range: range),
              let valueRange = Range(match.range(at: 1), in: line) else {
            return nil
        }
        var value = String(line[valueRange])
        if value.count >= 2,
           (value.first == "\"" && value.last == "\"")
            || (value.first == "'" && value.last == "'") {
            value.removeFirst()
            value.removeLast()
        }
        return value
    }

    static func replacingURI(in line: String, with localName: String) -> String {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = uriPattern.firstMatch(in: line, range: range),
              let swiftRange = Range(match.range, in: line) else {
            return line
        }
        return line.replacingCharacters(in: swiftRange, with: "URI=\"\(localName)\"")
    }
}
