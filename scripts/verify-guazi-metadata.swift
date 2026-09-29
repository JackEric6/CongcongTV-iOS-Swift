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
            MovieSort.SortData(id: "guazi-playlist:4:series", name: "本周国产剧排行榜"),
            MovieSort.SortData(id: "guazi-playlist:1:hot", name: "热门推荐"),
            MovieSort.SortData(id: "guazi-playlist:5:netflix", name: "Netflix新片榜"),
            MovieSort.SortData(id: "guazi-playlist:6:hot-movie", name: "本周热门电影榜"),
            MovieSort.SortData(id: "guazi-playlist:4:series", name: "重复片单")
        ]
        let orderedCategories = GuaziHomeCategoryOrder.sort(shuffledCategories)
        let expectedCategories = [
            "热门推荐", "本周国产剧排行榜", "Netflix新片榜", "本周热门电影榜",
            "电视剧", "电影", "短剧", "综艺", "动漫"
        ]
        guard orderedCategories.map(\.name) == expectedCategories else {
            fatalError("瓜子分类顺序不正确：\(orderedCategories.map(\.name))")
        }

        let navigation: [String: Any] = [
            "list": [
                ["name": "电视剧", "type": "video", "pid": 4],
                ["name": "排行榜", "type": "rank", "pid": 9],
                ["name": "热门", "type": "video", "pid": 2],
                ["name": "热门推荐", "type": "recommend", "pid": 99]
            ]
        ]
        guard GuaziPlaylistCatalog.playlistNavigationPIDs(from: navigation) == ["4", "2", "1"] else {
            fatalError("没有按 Android 首页协议识别瓜子推荐和视频导航")
        }

        let homePage: [String: Any] = [
            "list": [
                ["type": "热门推荐", "p_type": "2", "pid": 1, "show_id": "hot"],
                ["type": "不可展开栏目", "p_type": "1", "pid": 1, "show_id": "skip"],
                ["type": "子级推荐榜", "p_type": "2", "pid": 1, "parent_id": "8", "show_id": "child"],
                ["type": "本周国产剧排行榜", "p_type": "2", "pid": 4, "show_id": "series"],
                ["type": "本周国产剧排行榜", "p_type": "2", "pid": 4, "show_id": "series"]
            ]
        ]
        let playlists = GuaziPlaylistCatalog.playlists(from: homePage)
        guard playlists.map(\.sort.name) == ["热门推荐", "子级推荐榜", "本周国产剧排行榜"],
              playlists.map(\.showID) == ["hot", "child", "series"],
              playlists.map(\.pid) == ["1", "1", "4"] else {
            fatalError("瓜子排行片单解析顺序或去重失败：\(playlists)")
        }
        let hotList: [String: Any] = [
            "list": [
                ["vod_id": "100", "vod_name": "热门影视", "vod_pic": "https://example.test/poster.jpg"]
            ]
        ]
        guard GuaziPlaylistCatalog.videos(from: hotList).first?["vod_id"] as? String == "100" else {
            fatalError("瓜子热门片单视频解析失败")
        }

        let response: [String: Any] = [
            "data": [
                "d_id": "123",
                "d_name": "测试影片",
                "d_class": "谍战，剧情",
                "d_content": "<p>&nbsp;这是瓜子简介</p>"
            ],
            "vurl_clouds": [
                ["content": "播放数据不得作为影片简介"]
            ]
        ]
        let metadata = GuaziMetadataParser.parse(response)
        guard metadata.name == "测试影片",
              metadata.type == "谍战，剧情",
              metadata.description == "这是瓜子简介",
              metadata.description != "谍战，剧情" else {
            fatalError("瓜子嵌套元数据解析失败：\(metadata)")
        }

        print("GUAZI PLAYLIST ORDER AND DESCRIPTION CHECKS PASSED")
    }
}
