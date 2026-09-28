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
    private let session: URLSession
    private var metadataCache: [String: Metadata] = [:]
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
            guard let object = item as? [String: Any] else { return nil }
            let id = string(object["vod_id"])
            guard !id.isEmpty else { return nil }
            let metadata = makeMetadata(from: object)
            metadataCache[id] = metadata
            var video = Movie.Video(
                id: id,
                name: metadata.name,
                pic: metadata.pic,
                note: metadata.note,
                sourceKey: "guazi",
                doubanRating: metadata.rating
            )
            video.year = metadata.year
            video.area = metadata.area
            video.type = metadata.type
            video.director = metadata.director
            video.actor = metadata.actor
            video.des = metadata.des
            return video
        }
        return videos
    }

    func detail(vodID: String) async throws -> VodInfo {
        let metadataObject = try await request(
            path: "/App/Resource/Vod/showOne",
            parameters: ["d_id": vodID]
        )
        let metadata = metadataCache[vodID] ?? makeMetadata(from: metadataObject)
        var info = VodInfo(id: vodID)
        info.name = metadata.name.isEmpty ? "瓜子影视 \(vodID)" : metadata.name
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

        let clouds = array(metadataObject["vurl_clouds"])
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
        var token = UserDefaults.standard.string(forKey: Self.tokenKey) ?? ""
        if token.isEmpty {
            token = try await register()
        }

        do {
            return try await performRequest(path: path, parameters: parameters, token: token)
        } catch GuaziServiceError.authFailed {
            let currentToken = UserDefaults.standard.string(forKey: Self.tokenKey) ?? ""
            if currentToken.isEmpty || currentToken == token {
                UserDefaults.standard.removeObject(forKey: Self.tokenKey)
                token = try await register()
            } else {
                token = currentToken
            }
            return try await performRequest(path: path, parameters: parameters, token: token)
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
                let result = try await performRequest(
                    path: "/App/Authentication/Device/signUp",
                    parameters: [
                        "old_key": stable,
                        "new_key": device,
                        "phone_type": "1",
                        "code": ""
                    ],
                    token: ""
                )
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
    ) async throws -> [String: Any] {
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
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw GuaziServiceError.requestFailed("瓜子接口 HTTP 请求失败")
            }
            let raw = String(decoding: data, as: UTF8.self)
            let code = GuaziCrypto.responseCode(raw)
            guard code == 200 else {
                let message = GuaziCrypto.responseMessage(raw)
                if code == 401 || code == 403 || message.localizedCaseInsensitiveContains("token") {
                    throw GuaziServiceError.authFailed
                }
                throw GuaziServiceError.requestFailed(
                    message.isEmpty ? "瓜子接口请求失败" : "瓜子接口错误：\(message)"
                )
            }
            return try GuaziCrypto.decodeResponse(raw)
        } catch let error as GuaziServiceError {
            throw error
        } catch {
            throw GuaziServiceError.requestFailed("瓜子接口请求失败：\(error.localizedDescription)")
        }
    }

    private func makeMetadata(from object: [String: Any]) -> Metadata {
        Metadata(
            name: string(object["vod_name"]),
            pic: string(object["vod_pic"]),
            year: string(object["vod_year"]),
            area: string(object["vod_area"]),
            type: string(object["vod_class"]),
            director: string(object["vod_director"]),
            actor: string(object["vod_actor"]),
            des: string(object["d_class"]).isEmpty ? string(object["vod_content"]) : string(object["d_class"]),
            note: string(object["new_continue"]).isEmpty ? string(object["vod_remarks"]) : string(object["new_continue"]),
            rating: string(object["vod_scroe"]).isEmpty ? string(object["vod_score"]) : string(object["vod_scroe"])
        )
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
        "congcong-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }
}
