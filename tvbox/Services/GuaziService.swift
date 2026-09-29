import Foundation

enum GuaziServiceError: LocalizedError {
    case invalidURL
    case invalidResponse
    case authFailed
    case requestFailed(String)
    case playableURLMissing

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "瓜子接口地址无效"
        case .invalidResponse:
            return "瓜子接口返回数据无效"
        case .authFailed:
            return "瓜子设备注册失败"
        case .requestFailed(let message):
            return message
        case .playableURLMissing:
            return "瓜子接口没有返回可播放地址"
        }
    }
}

actor GuaziService {
    static let shared = GuaziService()

    private static let homeCategories: [(id: String, name: String, sub: String)] = [
        ("2", "电视剧", "12"),
        ("1", "电影", "5"),
        ("64", "短剧", ""),
        ("3", "综艺", "22"),
        ("4", "动漫", "30")
    ]

    struct PlayRequest: Hashable {
        let vodID: String
        let cloudID: String
        let vurlID: String
        let domainType: String
        let resolution: String
        let type: String

        init(
            vodID: String,
            cloudID: String,
            vurlID: String,
            domainType: String,
            resolution: String,
            type: String
        ) {
            self.vodID = vodID
            self.cloudID = cloudID
            self.vurlID = vurlID
            self.domainType = domainType
            self.resolution = resolution
            self.type = type
        }

        init?(url: String) {
            guard let components = URLComponents(string: url),
                  components.host?.lowercased() == "guazi.local",
                  let queryItems = components.queryItems else {
                return nil
            }
            func value(_ name: String) -> String {
                queryItems.first(where: { $0.name == name })?.value ?? ""
            }
            let vodID = value("vod_id")
            let cloudID = value("vurl_cloud_id")
            let vurlID = value("vurl_id")
            let domainType = value("domain_type")
            let resolution = value("resolution")
            guard !vodID.isEmpty, !cloudID.isEmpty, !vurlID.isEmpty,
                  !domainType.isEmpty, !resolution.isEmpty else {
                return nil
            }
            self.vodID = vodID
            self.cloudID = cloudID
            self.vurlID = vurlID
            self.domainType = domainType
            self.resolution = resolution
            self.type = value("type").isEmpty ? "play" : value("type")
        }

        var url: String {
            var components = URLComponents()
            components.scheme = "https"
            components.host = "guazi.local"
            components.path = "/play.m3u8"
            components.queryItems = [
                URLQueryItem(name: "vod_id", value: vodID),
                URLQueryItem(name: "vurl_cloud_id", value: cloudID),
                URLQueryItem(name: "vurl_id", value: vurlID),
                URLQueryItem(name: "domain_type", value: domainType),
                URLQueryItem(name: "resolution", value: resolution),
                URLQueryItem(name: "type", value: type)
            ]
            return components.url?.absoluteString ?? ""
        }
    }

    private struct Metadata {
        let name: String
        let pic: String
        let year: String
        let area: String
        let type: String
        let director: String
        let actor: String
        let des: String
        let note: String
        let rating: String
    }

    private static let tokenKey = "congcong.guazi.api.token"
    private static let deviceKey = "congcong.guazi.device.key"
    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    private let session: URLSession
    private var metadataCache: [String: Metadata] = [:]
    private var playlistBySortID: [String: GuaziPlaylistCatalog.Playlist] = [:]
    private var cachedHomeSorts: [MovieSort.SortData]?
    private var registrationTask: Task<String, Error>?

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 35
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func search(keyword: String) async throws -> [Movie.Video] {
        let result = try await request(
            path: "/App/Index/findMoreVod",
            parameters: [
                "keywords": keyword,
                "order_val": "0",
                "search_type": ""
            ]
        )
        guard let list = result["list"] as? [Any] else {
            throw GuaziServiceError.invalidResponse
        }
        let videos = list.compactMap { item -> Movie.Video? in
            guard let object = item as? [String: Any],
                  GuaziSearchMatcher.matches(
                    keyword: keyword,
                    title: string(object["vod_name"])
                  ) else {
                return nil
            }
            return makeVideo(from: object)
        }
        return videos
    }

    /// 片单来自瓜子首页导航及各栏目列表，保留接口返回的榜单顺序。
    func homeSorts() async -> [MovieSort.SortData] {
        if let cachedHomeSorts {
            return cachedHomeSorts
        }

        let categories = Self.homeCategories.map {
            MovieSort.SortData(id: $0.id, name: $0.name)
        }
        do {
            let navigation = try await requestArray(
                path: "/App/Index/indexPid",
                parameters: [:]
            )
            var visitedPIDs = Set<String>()
            let pagePIDs = navigation.compactMap { item -> String? in
                let type = string(item["type"])
                let pid = string(item["pid"])
                guard (type == "video" || type == "recommend"),
                      !pid.isEmpty, pid != "0",
                      visitedPIDs.insert(pid).inserted else {
                    return nil
                }
                return pid
            }
            var pageDataByPID: [String: Data] = [:]
            var nextPageIndex = 0
            await withTaskGroup(of: (String, Data?).self) { group in
                for _ in 0..<min(3, pagePIDs.count) {
                    let pid = pagePIDs[nextPageIndex]
                    nextPageIndex += 1
                    group.addTask {
                        guard let page = try? await self.request(
                            path: "/App/IndexList/index",
                            parameters: ["pid": pid]
                        ),
                        let data = try? JSONSerialization.data(withJSONObject: page) else {
                            return (pid, nil)
                        }
                        return (pid, data)
                    }
                }

                while let (pid, data) = await group.next() {
                    if let data {
                        pageDataByPID[pid] = data
                    }
                    guard nextPageIndex < pagePIDs.count else { continue }
                    let nextPID = pagePIDs[nextPageIndex]
                    nextPageIndex += 1
                    group.addTask {
                        guard let page = try? await self.request(
                            path: "/App/IndexList/index",
                            parameters: ["pid": nextPID]
                        ),
                        let data = try? JSONSerialization.data(withJSONObject: page) else {
                            return (nextPID, nil)
                        }
                        return (nextPID, data)
                    }
                }
            }

            var playlists: [GuaziPlaylistCatalog.Playlist] = []
            for item in navigation {
                let pid = string(item["pid"])
                guard let data = pageDataByPID[pid],
                      let value = try? JSONSerialization.jsonObject(with: data),
                      let page = value as? [String: Any] else {
                    continue
                }
                playlists.append(contentsOf: GuaziPlaylistCatalog.playlists(from: page))
            }
            playlistBySortID = Dictionary(
                playlists.map { ($0.sort.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let sorts = GuaziHomeCategoryOrder.sort(
                playlists.map(\.sort) + categories
            )
            if !playlists.isEmpty {
                cachedHomeSorts = sorts
            }
            return sorts
        } catch {
            // 首页片单暂不可用时仍保留普通分类，后续刷新可重新探测。
            return GuaziHomeCategoryOrder.sort(categories)
        }
    }

    /// 加载瓜子首页指定分类。接口返回结构与搜索接口不同，但同样走瓜子专用加密协议。
    func category(
        sort: MovieSort.SortData,
        page: Int = 1,
        filters: [String: String]? = nil
    ) async throws -> [Movie.Video] {
        if let playlist = playlistBySortID[sort.id] {
            guard page == 1 else { return [] }
            if playlist.showID.isEmpty {
                return playlist.embeddedVideos.compactMap { makeVideo(from: $0) }
            }
            let response = try await request(
                path: "/App/IndexList/hotsList",
                parameters: [
                    "show_id": playlist.showID,
                    "pid": playlist.pid
                ]
            )
            return GuaziPlaylistCatalog.videos(from: response).compactMap {
                makeVideo(from: $0)
            }
        }

        guard let category = Self.homeCategories.first(where: { $0.id == sort.id }) else {
            return []
        }

        let filter = filters ?? [:]
        let result = try await request(
            path: "/App/IndexList/indexList",
            parameters: [
                "area": filter["area"] ?? "0",
                "sub": filter["sub"] ?? category.sub,
                "year": filter["year"] ?? "0",
                "pageSize": "30",
                "sort": filter["sort"] ?? "d_id",
                "page": String(max(1, page)),
                "tid": category.id
            ]
        )
        guard let list = result["list"] as? [Any] else {
            throw GuaziServiceError.invalidResponse
        }
        return list.compactMap { item in
            guard let object = item as? [String: Any] else { return nil }
            return makeVideo(from: object)
        }
    }

    func detail(vodID: String) async throws -> VodInfo {
        let apiToken = try await currentToken()
        async let detailRequest = request(
            path: "/App/Resource/Vod/showOne",
            parameters: ["d_id": vodID]
        )
        async let playInfoRequest: [String: Any]? = try? await request(
            path: "/App/IndexPlay/playInfo",
            parameters: [
                "vod_id": vodID,
                "token": apiToken,
                "token_id": "",
                "mobile_time": String(Int(Date().timeIntervalSince1970))
            ]
        )
        let (detailResponse, playInfoResponse) = try await (detailRequest, playInfoRequest)
        let metadataObject = GuaziMetadataParser.payload(from: detailResponse)
        let detailMetadata = makeMetadata(from: metadataObject)
        var metadata = mergeMetadata(metadataCache[vodID], with: detailMetadata)
        if let playInfoResponse {
            let playInfoObject = GuaziMetadataParser.payload(from: playInfoResponse)
            metadata = mergeMetadata(metadata, with: makeMetadata(from: playInfoObject))
        }

        // playInfo 是瓜子播放器使用的详情接口；若它缺简介，再按精确 ID
        // 从同一瓜子搜索接口补齐，绝不借用其他站点的元数据。
        if metadata.des.isEmpty, !metadata.name.isEmpty,
           let searchResponse = try? await request(
               path: "/App/Index/findMoreVod",
               parameters: [
                   "keywords": metadata.name,
                   "order_val": "0",
                   "search_type": ""
               ]),
           let list = searchResponse["list"] as? [Any],
           let matchingVideo = list.first(where: { item in
               guard let object = item as? [String: Any] else { return false }
               return string(object["vod_id"]) == vodID
           }) as? [String: Any] {
            metadata = mergeMetadata(metadata, with: makeMetadata(from: matchingVideo))
        }

        metadata = mergeMetadata(metadataCache[vodID], with: metadata)
        metadataCache[vodID] = metadata
        var info = VodInfo(id: vodID)
        info.name = metadata.name.isEmpty ? "瓜子 \(vodID)" : metadata.name
        info.pic = metadata.pic
        info.note = metadata.note
        info.year = metadata.year
        info.area = metadata.area
        info.typeName = metadata.type
        info.director = metadata.director
        info.actor = metadata.actor
        info.des = metadata.des
        info.doubanRating = metadata.rating
        info.sourceKey = "guazi"

        let clouds = array(detailResponse["vurl_clouds"] ?? metadataObject["vurl_clouds"])
        for cloudValue in clouds {
            guard let cloud = cloudValue as? [String: Any] else { continue }
            let cloudID = string(cloud["id"])
            guard !cloudID.isEmpty else { continue }
            let episodeResponse = try await request(
                path: "/App/Resource/Vurl/show",
                parameters: [
                    "vurl_cloud_id": cloudID,
                    "vod_d_id": vodID
                ]
            )
            let episodes = buildEpisodes(
                vodID: vodID,
                cloudID: cloudID,
                response: episodeResponse
            )
            guard !episodes.isEmpty else { continue }
            let name = string(cloud["name"]).isEmpty ? "瓜子线路" : string(cloud["name"])
            info.playFlags.append(name)
            info.playUrlMap[name] = episodes
        }
        info.playFlag = info.playFlags.first ?? ""
        return info
    }

    func play(_ playRequest: PlayRequest) async throws -> String {
        let result = try await request(
            path: "/App/Resource/VurlDetail/showOne",
            parameters: [
                "vod_id": playRequest.vodID,
                "domain_type": playRequest.domainType,
                "vurl_id": playRequest.vurlID,
                "resolution": playRequest.resolution,
                "type": playRequest.type
            ]
        )
        guard let url = findPlayableURL(result) else {
            throw GuaziServiceError.playableURLMissing
        }
        return url
    }

    private func buildEpisodes(vodID: String, cloudID: String, response: [String: Any]) -> [VodInfo.Episode] {
        array(response["list"]).compactMap { item -> VodInfo.Episode? in
            guard let episode = item as? [String: Any] else { return nil }
            let vurlID = string(episode["id"])
            guard !vurlID.isEmpty,
                  let play = episode["play"] as? [String: Any],
                  let selected = choosePlay(play) else {
                return nil
            }
            let params = parseQuery(selected)
            let domainType = params["domain_type"] ?? ""
            let resolution = params["resolution"] ?? ""
            guard !domainType.isEmpty, !resolution.isEmpty else { return nil }
            let request = PlayRequest(
                vodID: vodID,
                cloudID: cloudID,
                vurlID: vurlID,
                domainType: domainType,
                resolution: resolution,
                type: params["type"].flatMap { $0.isEmpty ? nil : $0 } ?? "play"
            )
            let title = string(episode["title"]).isEmpty
                ? "第\(vurlID)集"
                : string(episode["title"])
            return VodInfo.Episode(name: title, url: request.url)
        }
    }

    private func choosePlay(_ play: [String: Any]) -> String? {
        for resolution in ["720", "1080", "480"] {
            guard let entry = play[resolution] as? [String: Any] else { continue }
            let value = string(entry["param"])
            if !value.isEmpty { return value }
        }
        return nil
    }

    private func request(path: String, parameters: [String: Any]) async throws -> [String: Any] {
        guard let object = try await requestValue(path: path, parameters: parameters) as? [String: Any] else {
            throw GuaziServiceError.invalidResponse
        }
        return object
    }

    private func requestArray(path: String, parameters: [String: Any]) async throws -> [[String: Any]] {
        guard let array = try await requestValue(path: path, parameters: parameters) as? [[String: Any]] else {
            throw GuaziServiceError.invalidResponse
        }
        return array
    }

    private func currentToken() async throws -> String {
        var token = UserDefaults.standard.string(forKey: Self.tokenKey) ?? ""
        if token.isEmpty {
            token = try await register()
        }
        return token
    }

    private func requestValue(path: String, parameters: [String: Any]) async throws -> Any {
        var token = try await currentToken()
        var requestParameters = parameters

        do {
            return try await performRequest(path: path, parameters: requestParameters, token: token)
        } catch GuaziServiceError.authFailed {
            let currentToken = UserDefaults.standard.string(forKey: Self.tokenKey) ?? ""
            if currentToken.isEmpty || currentToken == token {
                UserDefaults.standard.removeObject(forKey: Self.tokenKey)
                token = try await register()
            } else {
                token = currentToken
            }
            if requestParameters["token"] != nil {
                requestParameters["token"] = token
            }
            return try await performRequest(path: path, parameters: requestParameters, token: token)
        }
    }

    private func register() async throws -> String {
        if let registrationTask {
            return try await registrationTask.value
        }

        let task = Task { try await self.performRegistration() }
        registrationTask = task
        do {
            let token = try await task.value
            registrationTask = nil
            return token
        } catch {
            registrationTask = nil
            throw error
        }
    }

    private func performRegistration() async throws -> String {
        let stable = stableDeviceKey()
        var device = UserDefaults.standard.string(forKey: Self.deviceKey) ?? ""
        if device.isEmpty {
            device = newDeviceKey()
        }

        for _ in 0..<2 {
            do {
                guard let result = try await performRequest(
                    path: "/App/Authentication/Device/signUp",
                    parameters: [
                        "old_key": stable,
                        "new_key": device,
                        "phone_type": "1",
                        "code": ""
                    ],
                    token: ""
                ) as? [String: Any] else {
                    throw GuaziServiceError.invalidResponse
                }
                let token = string(result["token"])
                if !token.isEmpty {
                    UserDefaults.standard.set(device, forKey: Self.deviceKey)
                    UserDefaults.standard.set(token, forKey: Self.tokenKey)
                    return token
                }
            } catch GuaziServiceError.authFailed {
                // 设备号已注册时换一个 new_key 再注册。
            }
            device = newDeviceKey()
        }
        throw GuaziServiceError.authFailed
    }

    private func performRequest(
        path: String,
        parameters: [String: Any],
        token: String
    ) async throws -> Any {
        guard let url = URL(string: GuaziCrypto.baseURL + path) else {
            throw GuaziServiceError.invalidURL
        }
        let timestamp = Int64(Date().timeIntervalSince1970)
        let form = try GuaziCrypto.createForm(parameters: parameters, token: token, time: timestamp)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue(GuaziCrypto.apiVersion, forHTTPHeaderField: "api-ver")
        request.setValue("GZ0007", forHTTPHeaderField: "code")
        request.setValue("zh_cn", forHTTPHeaderField: "lang")
        request.setValue(GuaziCrypto.packageName, forHTTPHeaderField: "PackageName")
        request.setValue(GuaziCrypto.apiVersion, forHTTPHeaderField: "Ver")
        request.setValue(GuaziCrypto.versionCode, forHTTPHeaderField: "Version")
        request.setValue(GuaziCrypto.baseURL, forHTTPHeaderField: "Referer")
        // 与 Android OkHttp FormBody 使用相同的媒体类型；编码由下方的
        // application/x-www-form-urlencoded 编码器负责，不能直接复用 URLQueryItem。
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Self.formEncodedBody(form)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw GuaziServiceError.requestFailed("瓜子接口响应状态无效")
            }
            guard (200..<300).contains(http.statusCode) else {
                if http.statusCode == 401 || http.statusCode == 403 {
                    throw GuaziServiceError.authFailed
                }
                throw GuaziServiceError.requestFailed("瓜子接口 HTTP 请求失败（\(http.statusCode)）")
            }
            let raw = String(decoding: data, as: UTF8.self)
            let code = GuaziCrypto.responseCode(raw)
            guard code == 200 else {
                let message = GuaziCrypto.responseMessage(raw)
                if code == 401 || code == 403
                    || message.localizedCaseInsensitiveContains("token")
                    || message.localizedCaseInsensitiveContains("签名") {
                    throw GuaziServiceError.authFailed
                }
                throw GuaziServiceError.requestFailed(
                    message.isEmpty ? "瓜子接口请求失败" : "瓜子接口错误：\(message)"
                )
            }
            return try GuaziCrypto.decodeResponseValue(raw)
        } catch let error as GuaziServiceError {
            throw error
        } catch {
            throw GuaziServiceError.requestFailed("瓜子接口请求失败：\(error.localizedDescription)")
        }
    }

    private func makeMetadata(from object: [String: Any]) -> Metadata {
        let parsed = GuaziMetadataParser.parse(object)
        return Metadata(
            name: parsed.name,
            pic: parsed.pic,
            year: parsed.year,
            area: parsed.area,
            type: parsed.type,
            director: parsed.director,
            actor: parsed.actor,
            des: parsed.description,
            note: parsed.note,
            rating: parsed.rating
        )
    }

    private func mergeMetadata(_ cached: Metadata?, with detail: Metadata) -> Metadata {
        guard let cached else { return detail }
        return Metadata(
            name: detail.name.isEmpty ? cached.name : detail.name,
            pic: detail.pic.isEmpty ? cached.pic : detail.pic,
            year: detail.year.isEmpty ? cached.year : detail.year,
            area: detail.area.isEmpty ? cached.area : detail.area,
            type: detail.type.isEmpty ? cached.type : detail.type,
            director: detail.director.isEmpty ? cached.director : detail.director,
            actor: detail.actor.isEmpty ? cached.actor : detail.actor,
            des: detail.des.isEmpty ? cached.des : detail.des,
            note: detail.note.isEmpty ? cached.note : detail.note,
            rating: detail.rating.isEmpty ? cached.rating : detail.rating
        )
    }

    /// 生成与 OkHttp FormBody 等价的 UTF-8 表单体。
    /// URLComponents 遵循 RFC 3986 查询编码，可能保留裸 `+`；
    /// application/x-www-form-urlencoded 接收端会把裸 `+` 解码为空格，
    /// 恰好会破坏 RSA Base64 的 keys/token。这里统一编码为 `%2B`。
    private static func formEncodedBody(_ fields: [String: String]) -> Data? {
        // 保持与 Android GuaziCrypto.createForm 的 LinkedHashMap 顺序一致。
        let orderedKeys = [
            "token", "token_id", "phone_type", "time", "phone_model",
            "keys", "request_key", "signature", "app_id", "ad_version"
        ]
        var keys = orderedKeys.filter { fields[$0] != nil }
        keys.append(contentsOf: fields.keys.filter { !orderedKeys.contains($0) }.sorted())

        let body = keys.compactMap { key -> String? in
            guard let value = fields[key] else { return nil }
            return "\(formEncode(key))=\(formEncode(value))"
        }.joined(separator: "&")
        return body.data(using: .utf8)
    }

    private static func formEncode(_ value: String) -> String {
        var encoded = String()
        encoded.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            switch byte {
            case 0x2A, 0x2D, 0x2E, 0x30...0x39,
                 0x41...0x5A, 0x5F, 0x61...0x7A:
                encoded.append(contentsOf: String(UnicodeScalar(byte)))
            case 0x20:
                encoded.append("+")
            default:
                encoded.append(String(format: "%%%02X", byte))
            }
        }
        return encoded
    }

    private func makeVideo(from object: [String: Any]) -> Movie.Video? {
        let id = string(object["vod_id"])
        guard !id.isEmpty else { return nil }

        let metadata = mergeMetadata(metadataCache[id], with: makeMetadata(from: object))
        metadataCache[id] = metadata
        let name = metadata.name.isEmpty ? string(object["c_name"]) : metadata.name
        let pic = metadata.pic.isEmpty ? string(object["c_pic"]) : metadata.pic
        var video = Movie.Video(
            id: id,
            name: name,
            pic: pic,
            note: metadata.note.isEmpty ? string(object["cf_name"]) : metadata.note,
            sourceKey: "guazi",
            doubanRating: metadata.rating
        )
        video.year = metadata.year
        video.area = metadata.area
        video.type = metadata.type
        video.director = metadata.director
        video.actor = metadata.actor
        video.des = metadata.des
        video.tid = string(object["t_id"]).isEmpty ? string(object["d_type"]) : string(object["t_id"])
        return video
    }

    private func parseQuery(_ value: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in value.split(separator: "&") {
            let pieces = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { continue }
            result[pieces[0]] = pieces[1].removingPercentEncoding ?? pieces[1]
        }
        return result
    }

    private func findPlayableURL(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme) else {
                return nil
            }
            let lower = trimmed.lowercased()
            return lower.contains(".m3u8") || lower.contains(".mp4") || lower.contains(".mpd")
                ? trimmed
                : nil
        }
        if let array = value as? [Any] {
            for child in array {
                if let found = findPlayableURL(child) {
                    return found
                }
            }
            return nil
        }
        if let object = value as? [String: Any] {
            for key in ["url", "play_url", "playUrl", "m3u8", "video_url", "videoUrl", "data", "result"] {
                if let found = findPlayableURL(object[key]) { return found }
            }
            for child in object.values {
                if let found = findPlayableURL(child) { return found }
            }
        }
        return nil
    }

    private func array(_ value: Any?) -> [Any] {
        value as? [Any] ?? []
    }

    private func string(_ value: Any?) -> String {
        if let value = value as? String {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let value = value as? NSNumber {
            return value.stringValue
        }
        return ""
    }

    private func stableDeviceKey() -> String {
        let key = "congcong.guazi.stable.device"
        if let stored = UserDefaults.standard.string(forKey: key), !stored.isEmpty {
            return stored
        }
        let value = "ios-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    private func newDeviceKey() -> String {
        "avbox-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }
}
