import Foundation

@main
struct VerifyGuaziMetadata {
    static func main() {
        let shuffledCategories = [
            MovieSort.SortData(id: "4", name: "旧动漫"),
            MovieSort.SortData(id: "64", name: "旧短剧"),
            MovieSort.SortData(id: "3", name: "旧综艺"),
            MovieSort.SortData(id: "1", name: "旧电影"),
            MovieSort.SortData(id: "2", name: "旧电视剧"),
            MovieSort.SortData(id: "hot", name: "热门")
        ]
        let orderedCategories = GuaziHomeCategoryOrder.sort(shuffledCategories)
        let expectedCategories = ["电视剧", "电影", "短剧", "综艺", "动漫"]
        guard orderedCategories.map(\.name) == expectedCategories else {
            fatalError("瓜子分类顺序不正确：\(orderedCategories.map(\.name))")
        }

        let response: [String: Any] = [
            "data": [
                "d_id": "123",
                "d_name": "测试影片",
                "d_class": "<p>&nbsp;这是瓜子简介</p>"
            ],
            "vurl_clouds": [
                ["content": "播放数据不得作为影片简介"]
            ]
        ]
        let metadata = GuaziMetadataParser.parse(response)
        guard metadata.name == "测试影片",
              metadata.description == "这是瓜子简介" else {
            fatalError("瓜子嵌套元数据解析失败：\(metadata)")
        }

        print("GUAZI CATEGORY ORDER AND DESCRIPTION CHECKS PASSED")
    }
}
