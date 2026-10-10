import Foundation

@main
struct VerifySearchSourceOrdering {
    private struct Source {
        let key: String
        let name: String
        let marker: String
    }

    static func main() {
        let sources = [
            Source(key: "fan_moli", name: "茉莉多线", marker: "moli"),
            Source(key: "custom_a", name: "自定义甲", marker: "other-a"),
            Source(key: "xgzy", name: "西瓜", marker: "xigua"),
            Source(key: "guazi", name: "瓜子", marker: "guazi"),
            Source(key: "fan_jianpian", name: "荐片原生", marker: "jianpian"),
            Source(key: "jianpian", name: "荐片", marker: "jianpian-api"),
            Source(key: "fhw88", name: "鑫同", marker: "xintong"),
            Source(key: "cz4k", name: "厂长", marker: "changzhang"),
            Source(key: "custom_b", name: "自定义乙", marker: "other-b"),
            Source(key: "360zy", name: "360", marker: "360"),
            Source(key: "dyttzy", name: "电影天堂", marker: "tiantang"),
            Source(key: "lzi", name: "量子", marker: "liangzi"),
            Source(key: "bfzy", name: "暴风", marker: "baofeng"),
            Source(key: "ffzy", name: "非凡", marker: "feifan")
        ]

        let sorted = SearchSourceGroup.sorted(
            sources,
            sourceKey: \.key,
            sourceName: \.name
        )
        precondition(sorted.map(\.marker) == [
            "guazi", "jianpian", "jianpian-api", "xigua", "feifan", "baofeng", "tiantang",
            "liangzi", "360", "xintong", "changzhang", "moli", "other-a", "other-b"
        ])
        precondition(SearchSourceGroup.allCases.map(\.title) == [
            "瓜子", "荐片", "西瓜", "非凡", "暴风", "天堂", "量子", "360", "鑫同", "厂长", "茉莉", "其他"
        ])
        precondition(SearchSourceGroup.displayName(sourceKey: "iqiyi", sourceName: "爱奇艺") == "奇艺")
        precondition(SearchSourceGroup.displayName(sourceKey: "xinlang", sourceName: "新浪资源") == "新浪")
        precondition(SearchSourceGroup.displayName(sourceKey: "unknown", sourceName: "奇异资源站") == "奇异")
        precondition(SearchSourceGroup.displayName(sourceKey: "dyttzy", sourceName: "电影天堂") == "天堂")
        precondition(!SearchSourceGroup.allCases.map(\.title).contains("其他影视源"))
        precondition(SearchSourceGroup.classify(sourceKey: "legacy", sourceName: "鑫同采集") == .xintong)
        precondition(SearchSourceGroup.classify(sourceKey: "cms_baofeng", sourceName: "暴风┃本地") == .baofeng)
        print("SEARCH SOURCE ORDERING CHECKS PASSED")
    }
}
