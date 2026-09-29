import Foundation

@main
struct VerifyGuaziSearch {
    static func main() {
        let cases: [(String, String, Bool)] = [
            ("沉默的荣耀", "沉默的荣耀", true),
            ("沉默的荣耀", "《沉默 的 荣耀》（2025）", true),
            ("沉默的荣耀", "沉默的荣耀之外", true),
            ("沉默的荣耀", "荣耀之外", false),
            ("沉默的荣耀", "本周热门推荐", false),
            ("！！！", "任意影片", false),
            ("沉默的荣耀", "", false)
        ]

        for (keyword, title, expected) in cases {
            guard GuaziSearchMatcher.matches(keyword: keyword, title: title) == expected else {
                fatalError("瓜子搜索标题过滤失败：\(keyword) / \(title)")
            }
        }
        print("GUAZI SEARCH TITLE FILTER CHECKS PASSED")
    }
}
