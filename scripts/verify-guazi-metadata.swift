import Foundation

@main
struct VerifyGuaziMetadata {
    static func main() {
        let shuffledCategories = [
            MovieSort.SortData(id: "4", name: "旧动漫"),
            MovieSort.SortData(id: "64", name: "旧短剧"),
            MovieSort.SortData(id: "3", name: "旧综艺"),
            MovieSort.SortData(id: "1", name: "旧电影"),
            MovieSort.SortData(id: "2", name: "旧电视剧")
        ]
        let orderedCategories = GuaziHomeCategoryOrder.sort(shuffledCategories)
        let expectedCategories = ["电视剧", "电影", "短剧", "综艺", "动漫"]
        guard orderedCategories.map(\.name) == expectedCategories else {
            fatalError("瓜子固定分类顺序不正确：\(orderedCategories.map(\.name))")
        }
        let requiredPageIDs = GuaziHomeCategoryOrder.prioritizedPageIDs(
            in: ["1", "5", "16", "3", "4", "6", "7", "8", "9"]
        )
        guard requiredPageIDs == ["1", "5", "16", "3", "4", "6"] else {
            fatalError("瓜子优先片单栏目预加载列表不正确：\(requiredPageIDs)")
        }
        let overflowPlaylists = (0..<40).map {
            GuaziPlaylistCatalog.Playlist(
                sort: MovieSort.SortData(
                    id: "guazi-playlist:99:\($0)",
                    name: "溢出片单 \($0)"
                ),
                showID: "overflow-\($0)",
                pid: "99",
                embeddedVideos: []
            )
        }
        let allHomeItems = GuaziHomeCategoryOrder.sort(
            overflowPlaylists.map(\.sort) + shuffledCategories
        )
        guard allHomeItems.count == 45,
              allHomeItems.prefix(40).map(\.id) == overflowPlaylists.map { $0.sort.id },
              allHomeItems.suffix(expectedCategories.count).map(\.name) == expectedCategories else {
            fatalError("瓜子首页超过 30 个片单时未完整返回或排序不正确：\(allHomeItems.count) 项")
        }

        let prioritizedIDs = [
            "guazi-playlist:4:74151",
            "guazi-playlist:3:46296",
            "guazi-playlist:3:19260",
            "guazi-playlist:3:17613",
            "guazi-playlist:1:130",
            "guazi-playlist:5:10772",
            "guazi-playlist:4:24058",
            "guazi-playlist:4:24066",
            "guazi-playlist:4:24057",
            "guazi-playlist:4:24067",
            "guazi-playlist:16:38579",
            "guazi-playlist:3:16560",
            "guazi-playlist:3:8",
            "guazi-playlist:6:6663"
        ]
        guard GuaziHomeCategoryOrder.initialSortID == prioritizedIDs.first else {
            fatalError("瓜子首页冷启动首项必须固定为第一优先片单")
        }
        let playlistNames = [
            "精选推荐", "综艺榜单", "TC抢先看（请勿相信视频内广告/网址/二维码）",
            "热播综艺", "电影榜单", "Netflix新片榜", "动漫榜一", "动漫榜二",
            "动漫榜三", "动漫榜四", "精选榜", "综艺精选", "综艺榜", "电影榜"
        ]
        let unprioritizedIDs = ["guazi-playlist:9:extra-a", "guazi-playlist:9:extra-b"]
        let playlistInput = Array(zip(prioritizedIDs, playlistNames).map {
            MovieSort.SortData(id: $0.0, name: $0.1)
        }.reversed())
        let hiddenPlaylist = MovieSort.SortData(
            id: "guazi-playlist:16:embedded-0",
            name: "热门短剧"
        )
        let trailingPlaylists = unprioritizedIDs.map {
            MovieSort.SortData(id: $0, name: $0)
        }
        let duplicatePriority = [
            MovieSort.SortData(id: prioritizedIDs[0], name: "重复优先片单")
        ]
        let orderingInput = trailingPlaylists
            + playlistInput
            + [hiddenPlaylist]
            + duplicatePriority
            + Array(shuffledCategories.reversed())
        let orderedHomeItems = GuaziHomeCategoryOrder.sort(orderingInput)
        let expectedHomeIDs = prioritizedIDs + unprioritizedIDs
        guard Array(orderedHomeItems.prefix(expectedHomeIDs.count)).map(\.id) == expectedHomeIDs,
              orderedHomeItems.first(where: { $0.id == "guazi-playlist:3:19260" })?.name == "TC抢先看",
              !orderedHomeItems.contains(where: { $0.id == hiddenPlaylist.id }),
              Array(orderedHomeItems.dropFirst(prioritizedIDs.count).prefix(unprioritizedIDs.count)).map(\.id) == unprioritizedIDs,
              Array(orderedHomeItems.suffix(expectedCategories.count)).map(\.name) == expectedCategories else {
            fatalError("瓜子首页片单优先级、顺序或固定分类顺序不正确：\(orderedHomeItems)")
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
