import Foundation

enum SearchSourceGroup: Int, CaseIterable, Hashable, Identifiable {
    case guazi
    case jianpian
    case xigua
    case feifan
    case baofeng
    case tiantang
    case liangzi
    case xintong
    case other
    case changzhang
    case moli
    case cheese
    case nuomi

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .guazi: return "瓜子"
        case .jianpian: return "荐片"
        case .xigua: return "西瓜"
        case .feifan: return "非凡"
        case .baofeng: return "暴风"
        case .tiantang: return "天堂"
        case .liangzi: return "量子"
        case .xintong: return "鑫同"
        case .cheese: return "奶酪"
        case .nuomi: return "糯米"
        case .changzhang: return "厂长"
        case .moli: return "茉莉"
        case .other: return "其他"
        }
    }

    static func displayName(sourceKey: String, sourceName: String?) -> String {
        let group = classify(sourceKey: sourceKey, sourceName: sourceName)
        if group != .other { return group.title }

        if sourceKey.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("360zy") == .orderedSame {
            return "360"
        }
        if sourceKey.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("ikunzy") == .orderedSame {
            return "爱坤"
        }

        let configuredName = sourceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if configuredName.contains("爱奇艺") { return "奇艺" }
        if configuredName.contains("电影天堂") { return "天堂" }

        let rawName = configuredName.isEmpty || configuredName.contains("其他影视源")
            ? sourceKey.trimmingCharacters(in: .whitespacesAndNewlines)
            : configuredName
        var shortName = rawName
        let suffixes = ["资源站", "采集站", "采集网", "采集", "资源"]
        var previous: String
        repeat {
            previous = shortName
            for suffix in suffixes where shortName.hasSuffix(suffix) {
                shortName.removeLast(suffix.count)
                shortName = shortName.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        } while shortName != previous

        if let first = shortName.first,
           first.unicodeScalars.contains(where: { $0.value > 0xFFFF }) {
            shortName.removeFirst()
            shortName = shortName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(shortName.prefix(2))
    }

    static func classify(sourceKey: String, sourceName: String? = nil) -> SearchSourceGroup {
        let key = sourceKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let name = (sourceName ?? "")
            .replacingOccurrences(of: "资源", with: "")
            .replacingOccurrences(of: "采集", with: "")
            .lowercased()

        switch key {
        case "guazi", "guazizy": return .guazi
        case "jianpian", "fan_jianpian", "fan_jp": return .jianpian
        case "xgzy", "xigua", "xiguazy": return .xigua
        case "ffzy", "feifan", "feifazy": return .feifan
        case "bfzy", "cms_baofeng", "baofeng": return .baofeng
        case "dyttzy", "dytt", "tiantang": return .tiantang
        case "lzi", "liangzi", "liangzizy": return .liangzi
        case "fhw88", "xintong": return .xintong
        case "fan_cheese", "cheese": return .cheese
        case "fan_nomi", "nuomi": return .nuomi
        case "cz4k", "changzhang": return .changzhang
        case "fan_moli", "moli": return .moli
        default: break
        }

        if name.contains("瓜子") { return .guazi }
        if name.contains("荐片") { return .jianpian }
        if name.contains("西瓜") { return .xigua }
        if name.contains("非凡") { return .feifan }
        if name.contains("暴风") { return .baofeng }
        if name.contains("天堂") { return .tiantang }
        if name.contains("量子") { return .liangzi }
        if name.contains("鑫同") { return .xintong }
        if name.contains("奶酪") { return .cheese }
        if name.contains("糯米") { return .nuomi }
        if name.contains("厂长") { return .changzhang }
        if name.contains("茉莉") { return .moli }
        return .other
    }

    static func sorted<T>(
        _ values: [T],
        sourceKey: (T) -> String,
        sourceName: (T) -> String? = { _ in nil }
    ) -> [T] {
        values.enumerated().sorted { lhs, rhs in
            let left = classify(sourceKey: sourceKey(lhs.element), sourceName: sourceName(lhs.element))
            let right = classify(sourceKey: sourceKey(rhs.element), sourceName: sourceName(rhs.element))
            if left.rawValue != right.rawValue { return left.rawValue < right.rawValue }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}
