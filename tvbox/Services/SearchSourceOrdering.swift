import Foundation

enum SearchSourceGroup: Int, CaseIterable, Hashable, Identifiable {
    case guazi
    case jianpian
    case xigua
    case feifan
    case baofeng
    case tiantang
    case liangzi
    case source360
    case xintong
    case changzhang
    case moli
    case other

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
        case .source360: return "360"
        case .xintong: return "鑫同"
        case .changzhang: return "厂长"
        case .moli: return "茉莉"
        case .other: return "其他影视源"
        }
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
        case "360zy", "360": return .source360
        case "fhw88", "xintong": return .xintong
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
        if name.contains("360") { return .source360 }
        if name.contains("鑫同") { return .xintong }
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
