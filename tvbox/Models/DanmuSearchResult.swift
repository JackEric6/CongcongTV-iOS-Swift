import Foundation

public struct DanmuSearchResult: Identifiable, Hashable, Sendable {
    public let name: String
    public let url: String
    public let isBuiltin: Bool

    public var id: String { url }

    public init(name: String, url: String, isBuiltin: Bool) {
        self.name = name.isEmpty ? url : name
        self.url = url
        self.isBuiltin = isBuiltin
    }
}
