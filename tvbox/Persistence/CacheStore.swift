import Foundation
import SwiftData

/// SwiftData 持久化模型 - 对应 Android 版 Room 数据库

/// 收藏/历史的业务唯一键（source + vodId）。
private func makeVodBusinessKey(vodId: String, sourceKey: String) -> String {
    let normalizedVodId = vodId.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedSourceKey = sourceKey.trimmingCharacters(in: .whitespacesAndNewlines)
    return "\(normalizedSourceKey)::\(normalizedVodId)"
}

/// 历史去重使用的影视标题键：忽略大小写、空白和标点。
private func makeHistoryTitleKey(_ value: String) -> String {
    value.lowercased().unicodeScalars.filter { scalar in
        CharacterSet.alphanumerics.contains(scalar)
            || (scalar.value >= 0x3400 && scalar.value <= 0x9FFF)
    }.map(String.init).joined()
}

/// 视频收藏
@Model
final class VodCollect {
    /// 业务唯一键（sourceKey + vodId）。
    var bizKey: String = ""
    /// 视频 ID（与 sourceKey 组成唯一语义键）。
    var vodId: String = ""
    /// 片名。
    var vodName: String = ""
    /// 海报地址。
    var vodPic: String = ""
    /// 来源站点 key。
    var sourceKey: String = ""
    /// 最近更新时间（收藏创建/刷新时间）。
    var updateTime: Date = Date()
    
    init(vodId: String, vodName: String, vodPic: String, sourceKey: String) {
        self.bizKey = makeVodBusinessKey(vodId: vodId, sourceKey: sourceKey)
        self.vodId = vodId
        self.vodName = vodName
        self.vodPic = vodPic
        self.sourceKey = sourceKey
        self.updateTime = Date()
    }
}

/// 播放历史记录
@Model
final class VodRecord {
    /// 业务唯一键（sourceKey + vodId）。
    var bizKey: String = ""
    /// 视频 ID。
    var vodId: String = ""
    /// 片名。
    var vodName: String = ""
    /// 海报地址。
    var vodPic: String = ""
    /// 来源站点 key。
    var sourceKey: String = ""
    /// 播放标记，如“第5集 03:45”。
    var playNote: String = ""
    /// 续播状态 JSON（`VodPlaybackState` 编码结果）。
    var dataJson: String = ""
    /// 最近播放时间。
    var updateTime: Date = Date()
    
    init(vodId: String, vodName: String, vodPic: String, sourceKey: String, playNote: String = "") {
        self.bizKey = makeVodBusinessKey(vodId: vodId, sourceKey: sourceKey)
        self.vodId = vodId
        self.vodName = vodName
        self.vodPic = vodPic
        self.sourceKey = sourceKey
        self.playNote = playNote
        self.updateTime = Date()
    }
}

/// 通用缓存
@Model
final class CacheItem {
    /// 唯一缓存键。
    @Attribute(.unique) var key: String = ""
    /// 缓存值（字符串形式）。
    var value: String = ""
    /// 更新时间。
    var updateTime: Date = Date()
    
    init(key: String, value: String) {
        self.key = key
        self.value = value
        self.updateTime = Date()
    }
}

/// 缓存管理器
actor CacheStore {
    static let shared = CacheStore()
    
    private init() {}
    
    @MainActor
    func addCollect(_ video: Movie.Video, context: ModelContext) {
        let vodId = video.id
        let sourceKey = video.sourceKey
        let bizKey = makeVodBusinessKey(vodId: vodId, sourceKey: sourceKey)
        
        do {
            let matched = try fetchCollects(vodId: vodId, sourceKey: sourceKey, context: context)
            if let first = matched.first {
                first.bizKey = bizKey
                first.vodName = video.name
                first.vodPic = video.pic
                first.updateTime = Date()
                for duplicate in matched.dropFirst() {
                    context.delete(duplicate)
                }
            } else {
                let collect = VodCollect(
                    vodId: vodId,
                    vodName: video.name,
                    vodPic: video.pic,
                    sourceKey: sourceKey
                )
                context.insert(collect)
            }
            try context.save()
        } catch {
            print("写入收藏失败: \(error)")
        }
    }
    
    @MainActor
    func removeCollect(vodId: String, sourceKey: String, context: ModelContext) {
        do {
            let items = try fetchCollects(vodId: vodId, sourceKey: sourceKey, context: context)
            guard !items.isEmpty else { return }
            for item in items {
                context.delete(item)
            }
            try context.save()
        } catch {
            print("删除收藏失败: \(error)")
        }
    }
    
    @MainActor
    func isCollected(vodId: String, sourceKey: String, context: ModelContext) -> Bool {
        let bizKey = makeVodBusinessKey(vodId: vodId, sourceKey: sourceKey)
        let predicate = #Predicate<VodCollect> { item in
            item.bizKey == bizKey || (item.bizKey == "" && item.vodId == vodId && item.sourceKey == sourceKey)
        }
        let descriptor = FetchDescriptor<VodCollect>(predicate: predicate)
        
        do {
            let count = try context.fetchCount(descriptor)
            return count > 0
        } catch {
            print("查询收藏状态失败: \(error)")
            return false
        }
    }
    
    @MainActor
    func addRecord(
        _ video: Movie.Video,
        playNote: String,
        playbackState: VodPlaybackState? = nil,
        context: ModelContext
    ) {
        let vodId = video.id
        let sourceKey = video.sourceKey
        let encodedState = Self.encodePlaybackState(playbackState)
        let bizKey = makeVodBusinessKey(vodId: vodId, sourceKey: sourceKey)
        
        do {
            let exactMatches = try fetchRecords(vodId: vodId, sourceKey: sourceKey, context: context)
            let titleKey = makeHistoryTitleKey(video.name)
            let titleMatches: [VodRecord]
            if titleKey.isEmpty {
                titleMatches = []
            } else {
                let allRecords = try context.fetch(FetchDescriptor<VodRecord>())
                titleMatches = allRecords.filter {
                    makeHistoryTitleKey($0.vodName) == titleKey
                }.sorted { $0.updateTime > $1.updateTime }
            }
            var matched = exactMatches
            for candidate in titleMatches where !matched.contains(where: { $0 === candidate }) {
                matched.append(candidate)
            }
            matched.sort { $0.updateTime > $1.updateTime }
            
            // 更新或插入
            if let record = matched.first {
                record.bizKey = bizKey
                record.vodId = vodId
                record.vodName = video.name
                record.vodPic = video.pic
                record.sourceKey = sourceKey
                record.playNote = playNote
                if let encodedState {
                    record.dataJson = encodedState
                }
                record.updateTime = Date()
                for duplicate in matched.dropFirst() {
                    context.delete(duplicate)
                }
            } else {
                let record = VodRecord(
                    vodId: vodId,
                    vodName: video.name,
                    vodPic: video.pic,
                    sourceKey: sourceKey,
                    playNote: playNote
                )
                if let encodedState {
                    record.dataJson = encodedState
                }
                context.insert(record)
            }
            
            try context.save()
        } catch {
            print("写入播放记录失败: \(error)")
        }
    }
    
    /// 读取续播状态（若无记录或 JSON 无法解码则返回 `nil`）。
    @MainActor
    func getPlaybackState(vodId: String, sourceKey: String, context: ModelContext) -> VodPlaybackState? {
        do {
            guard let record = try fetchRecords(vodId: vodId, sourceKey: sourceKey, context: context).first else {
                return nil
            }
            // 兼容早期只保存 playNote、尚未写入 dataJson 的历史记录。
            return Self.decodePlaybackState(record.dataJson)
                ?? Self.decodeLegacyPlaybackState(record.playNote)
        } catch {
            print("读取续播状态失败: \(error)")
            return nil
        }
    }
    
    @MainActor
    func clearHistory(context: ModelContext) {
        do {
            try context.delete(model: VodRecord.self)
            try context.save()
        } catch {
            print("清空历史记录失败: \(error)")
        }
    }
    
    @MainActor
    private func fetchRecords(vodId: String, sourceKey: String, context: ModelContext) throws -> [VodRecord] {
        let bizKey = makeVodBusinessKey(vodId: vodId, sourceKey: sourceKey)
        let predicate = #Predicate<VodRecord> { item in
            item.bizKey == bizKey || (item.bizKey == "" && item.vodId == vodId && item.sourceKey == sourceKey)
        }
        let descriptor = FetchDescriptor<VodRecord>(predicate: predicate)
        let records = try context.fetch(descriptor)
        
        // 兼容旧数据：命中 legacy 记录时补写业务键。
        var needsSave = false
        for record in records where record.bizKey.isEmpty {
            record.bizKey = bizKey
            needsSave = true
        }
        if needsSave {
            try context.save()
        }
        
        return records.sorted(by: { $0.updateTime > $1.updateTime })
    }
    
    @MainActor
    private func fetchCollects(vodId: String, sourceKey: String, context: ModelContext) throws -> [VodCollect] {
        let bizKey = makeVodBusinessKey(vodId: vodId, sourceKey: sourceKey)
        let predicate = #Predicate<VodCollect> { item in
            item.bizKey == bizKey || (item.bizKey == "" && item.vodId == vodId && item.sourceKey == sourceKey)
        }
        let descriptor = FetchDescriptor<VodCollect>(predicate: predicate)
        let collects = try context.fetch(descriptor)
        
        // 兼容旧数据：命中 legacy 记录时补写业务键。
        var needsSave = false
        for collect in collects where collect.bizKey.isEmpty {
            collect.bizKey = bizKey
            needsSave = true
        }
        if needsSave {
            try context.save()
        }
        
        return collects.sorted(by: { $0.updateTime > $1.updateTime })
    }
    
    private nonisolated static func encodePlaybackState(_ state: VodPlaybackState?) -> String? {
        guard let state else { return nil }
        guard let data = try? JSONEncoder().encode(state) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    
    /// 从 JSON 字符串反序列化续播状态。
    private nonisolated static func decodePlaybackState(_ json: String) -> VodPlaybackState? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(VodPlaybackState.self, from: data)
    }

    /// 清理已有的同名重复历史，只保留最近播放的一条。
    @MainActor
    func deduplicateHistory(context: ModelContext) {
        do {
            let records = try context.fetch(FetchDescriptor<VodRecord>())
            var newestByTitle: [String: VodRecord] = [:]
            var duplicates: [VodRecord] = []

            for record in records {
                let titleKey = makeHistoryTitleKey(record.vodName)
                let identity = titleKey.isEmpty ? record.bizKey : titleKey
                guard !identity.isEmpty else { continue }
                if let existing = newestByTitle[identity] {
                    if record.updateTime > existing.updateTime {
                        duplicates.append(existing)
                        newestByTitle[identity] = record
                    } else {
                        duplicates.append(record)
                    }
                } else {
                    newestByTitle[identity] = record
                }
            }

            guard !duplicates.isEmpty else { return }
            for duplicate in duplicates {
                context.delete(duplicate)
            }
            try context.save()
        } catch {
            print("清理重复历史失败: \(error)")
        }
    }

    /// 从旧版本的“第 N 集 08:45”文本记录恢复基础续播状态。
    /// 旧记录没有线路字段，使用空 flag 让详情页回退到当前源的默认线路。
    private nonisolated static func decodeLegacyPlaybackState(_ note: String) -> VodPlaybackState? {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let episodeIndex: Int = {
            let pattern = #"第\s*(\d+)\s*集"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                      in: text,
                      range: NSRange(text.startIndex..., in: text)
                  ),
                  let range = Range(match.range(at: 1), in: text),
                  let number = Int(text[range]), number > 0 else {
                return 0
            }
            return number - 1
        }()

        let timePattern = #"(?:(\d+):)?(\d{1,2}):(\d{2})\s*$"#
        guard let regex = try? NSRegularExpression(pattern: timePattern),
              let match = regex.firstMatch(
                  in: text,
                  range: NSRange(text.startIndex..., in: text)
              ) else {
            return VodPlaybackState(flag: "", episodeIndex: episodeIndex, progressSeconds: 0)
        }

        func capture(_ index: Int) -> Int {
            guard let range = Range(match.range(at: index), in: text) else { return 0 }
            return Int(text[range]) ?? 0
        }

        let hours = capture(1)
        let minutes = capture(2)
        let seconds = capture(3)
        let progress = Double(hours * 3600 + minutes * 60 + seconds)
        return VodPlaybackState(
            flag: "",
            episodeIndex: episodeIndex,
            progressSeconds: progress
        )
    }
}
