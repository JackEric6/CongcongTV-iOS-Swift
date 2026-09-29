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

        let homePage: [String: Any] = [
            "data": [
                "list": [
                    ["type": "热门推荐", "p_type": "2", "pid": 1, "show_id": "hot"],
                    ["type": "不可展开栏目", "p_type": "1", "pid": 1, "show_id": "skip"],
                    ["type": "子级推荐榜", "p_type": "2", "pid": 1, "parent_id": "8", "show_id": "child"],
                    ["type": "本周国产剧排行榜", "p_type": "2", "pid": 4, "show_id": "series"],
                    ["type": "本周国产剧排行榜", "p_type": "2", "pid": 4, "show_id": "series"]
                ]
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
        let embeddedPlaylist = GuaziPlaylistCatalog.playlists(from: [
            "list": [
                [
                    "type": "热门推荐",
                    "pid": "1",
                    "p_type": "2",
                    "list": [
                        [
                            "vod_id": "101",
                            "c_name": "热门作品",
                            "c_pic": "https://example.test/embedded.jpg",
                            "vod_douban_score": "8.2"
                        ]
                    ]
                ]
            ]
        ])
        guard embeddedPlaylist.count == 1,
              embeddedPlaylist[0].showID.isEmpty,
              embeddedPlaylist[0].embeddedVideos.first?["vod_id"] as? String == "101" else {
            fatalError("瓜子内嵌热门片单解析失败：\(embeddedPlaylist)")
        }

        let response: [String: Any] = [
            "vodInfo": [
                "vod_id": "123",
                "vod_name": "测试影片",
                "vod_year": "2025",
                "vod_area": "大陆",
                "vod_use_content": "<p>&nbsp;这是瓜子 playInfo 接口返回的真实简介字段</p>"
            ],
            "vurl_clouds": [
                ["content": "播放数据不得作为影片简介"]
            ]
        ]
        let metadata = GuaziMetadataParser.parse(response)
        guard metadata.name == "测试影片",
              metadata.year == "2025",
              metadata.area == "大陆",
              metadata.description == "这是瓜子 playInfo 接口返回的真实简介字段" else {
            fatalError("瓜子嵌套元数据解析失败：\(metadata)")
        }
        let embeddedMetadata = GuaziMetadataParser.parse(
            embeddedPlaylist[0].embeddedVideos[0]
        )
        guard embeddedMetadata.name == "热门作品",
              embeddedMetadata.pic == "https://example.test/embedded.jpg",
              embeddedMetadata.rating == "8.2" else {
            fatalError("瓜子内嵌推荐视频字段解析失败：\(embeddedMetadata)")
        }

        print("GUAZI PLAYLIST ORDER AND PLAYINFO DESCRIPTION CHECKS PASSED")
    }
}
