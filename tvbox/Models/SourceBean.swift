import Foundation

/// 视频源站点配置 - 对应 Android 版 SourceBean.java
struct SourceBean: Codable, Identifiable, Hashable {
    /// 以源 key 作为稳定标识。
    var id: String { key }

    /// 源唯一键。
    let key: String
    /// 源显示名。
    let name: String
    /// 源接口地址。
    let api: String
    /// 搜索开关：0 关闭，1 开启。
    let searchable: Int
    /// 是否允许出现在首页分类：0 不可选，1 可选。
    let filterable: Int
    /// 快速搜索开关：0 关闭，1 开启（主要用于 remote 源 quick 参数）。
    let quickSearch: Int
    /// 源声明的播放器类型（历史字段，Swift 端目前主要走统一播放器策略）。
    let playerType: Int
    /// 源协议类型：0 XML，1 JSON，3 JAR，4 Remote。
    let type: Int
    /// 扩展参数（remote 源常用）。
    let ext: String?
    /// 源请求超时（秒），缺省时由网络层使用全局超时。
    let timeout: Int?
    /// 源请求头。
    let headers: [String: String]?
    /// 源图标。
    let icon: String?
    /// 是否允许切换。
    let changeable: Int
    /// 是否隐藏。
    let hidden: Bool
    /// 是否停用。
    let disabled: Bool
    /// 备用 CMS 接口。
    let backupApi: [String]
    /// 备用站点域名。
    let backupDomain: [String]

    init(key: String = "", name: String = "", api: String = "",
         searchable: Int = 1, filterable: Int = 1, quickSearch: Int = 0,
         playerType: Int = 0, type: Int = 1, ext: String? = nil,
         timeout: Int? = nil, headers: [String: String]? = nil,
         icon: String? = nil, changeable: Int = 1, hidden: Bool = false,
         disabled: Bool = false, backupApi: [String] = [], backupDomain: [String] = []) {
        self.key = key
        self.name = name
        self.api = api
        self.searchable = searchable
        self.filterable = filterable
        self.quickSearch = quickSearch
        self.playerType = playerType
        self.type = type
        self.ext = ext
        self.timeout = timeout
        self.headers = headers
        self.icon = icon
        self.changeable = changeable
        self.hidden = hidden
        self.disabled = disabled
        self.backupApi = backupApi
        self.backupDomain = backupDomain
    }

    private enum CodingKeys: String, CodingKey {
        case key, name, api, searchable, filterable, quickSearch
        case playerType, type, ext, timeout, headers, icon, changeable
        case hidden, disabled, backupApi, backupDomain
    }

    /// 安卓配置中的扩展字段并非每个源都会提供，缺失时必须回退到兼容默认值。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            key: try container.decodeIfPresent(String.self, forKey: .key) ?? "",
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "",
            api: try container.decodeIfPresent(String.self, forKey: .api) ?? "",
            searchable: try container.decodeIfPresent(Int.self, forKey: .searchable) ?? 1,
            filterable: try container.decodeIfPresent(Int.self, forKey: .filterable) ?? 1,
            quickSearch: try container.decodeIfPresent(Int.self, forKey: .quickSearch) ?? 0,
            playerType: try container.decodeIfPresent(Int.self, forKey: .playerType) ?? 0,
            type: try container.decodeIfPresent(Int.self, forKey: .type) ?? 1,
            ext: try container.decodeIfPresent(String.self, forKey: .ext),
            timeout: try container.decodeIfPresent(Int.self, forKey: .timeout),
            headers: try container.decodeIfPresent([String: String].self, forKey: .headers),
            icon: try container.decodeIfPresent(String.self, forKey: .icon),
            changeable: try container.decodeIfPresent(Int.self, forKey: .changeable) ?? 1,
            hidden: try container.decodeIfPresent(Bool.self, forKey: .hidden) ?? false,
            disabled: try container.decodeIfPresent(Bool.self, forKey: .disabled) ?? false,
            backupApi: try container.decodeIfPresent([String].self, forKey: .backupApi) ?? [],
            backupDomain: try container.decodeIfPresent([String].self, forKey: .backupDomain) ?? []
        )
    }

    var isSearchable: Bool { searchable == 1 }
    var isFilterable: Bool { filterable == 1 }
    var isQuickSearchEnabled: Bool { quickSearch == 1 }
    var isChangeable: Bool { changeable == 1 }
    var isEnabled: Bool { !disabled }
    var isSelectable: Bool { isSupportedInSwift && isEnabled && !hidden }

    /// 是否在 Swift 版中受支持（type=3 为 JAR/Spider，需要 Java 运行时，暂不支持）
    var isSupportedInSwift: Bool {
        return type == 0 || type == 1 || type == 4
    }

    /// 类型描述
    var typeDescription: String {
        switch type {
        case 0: return "XML"
        case 1: return "JSON"
        case 3: return "JAR"
        case 4: return "Remote"
        default: return "未知"
        }
    }

    /// api 字段是否为有效 HTTP URL
    var isHttpApi: Bool {
        let trimmed = api.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = components.host,
              !host.isEmpty else {
            return false
        }
        return true
    }
}
