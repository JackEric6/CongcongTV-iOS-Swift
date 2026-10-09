import Foundation
import Network

/// Android 版 M3u8.purify 的 iOS 实现。
///
/// 净化结果只在进程内保存，并通过回环 HTTP 地址交给 KSPlayer。播放清单中的
/// 分片、密钥和子资源会被改写成绝对地址，因此播放器不需要额外的代理能力。
actor M3U8Purifier {
    static let shared = M3U8Purifier()

    struct PreparedURL: Sendable {
        let url: String
        let didPurify: Bool
        let removedSegmentCount: Int
    }

    private let network = NetworkManager.shared
    private let proxy = M3U8LoopbackProxy.shared

    func prepare(urlString: String, headers: [String: String]) async -> PreparedURL {
        guard M3U8PurifierSettings.isEnabled,
              let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              Self.isHTTPURL(url),
              Self.looksLikeM3U8(url),
              !Self.isLoopbackURL(url) else {
            return PreparedURL(url: urlString, didPurify: false, removedSegmentCount: 0)
        }

        do {
            let firstContent = try await network.getString(
                from: url.absoluteString,
                headers: headers.isEmpty ? nil : headers,
                maxRetries: 1
            )
            guard firstContent.trimmingCharacters(in: .whitespacesAndNewlines)
                .hasPrefix("#EXTM3U") else {
                return PreparedURL(url: urlString, didPurify: false, removedSegmentCount: 0)
            }

            let targetURL: URL
            let content: String
            if let variant = Self.firstVariantURL(in: firstContent, baseURL: url) {
                targetURL = variant
                content = try await network.getString(
                    from: variant.absoluteString,
                    headers: headers.isEmpty ? nil : headers,
                    maxRetries: 1
                )
            } else {
                targetURL = url
                content = firstContent
            }

            let result = M3U8ManifestPurifier.purify(baseURL: targetURL, content: content)
            guard result.removedSegmentCount > 0,
                  let proxyURL = try? await proxy.publish(content: result.content) else {
                // Android 版在没有命中广告时回退到实际媒体清单；主清单解析出的
                // 第一条变体同样直接播放，避免把无法净化的 master 交给本地代理。
                return PreparedURL(
                    url: targetURL.absoluteString,
                    didPurify: false,
                    removedSegmentCount: 0
                )
            }
            return PreparedURL(
                url: proxyURL,
                didPurify: true,
                removedSegmentCount: result.removedSegmentCount
            )
        } catch {
            // 净化是增强能力，网络失败不能阻断原始播放链路。
            return PreparedURL(url: urlString, didPurify: false, removedSegmentCount: 0)
        }
    }

    private static func isHTTPURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    private static func isLoopbackURL(_ url: URL) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(url.host?.lowercased() ?? "")
    }

    private static func looksLikeM3U8(_ url: URL) -> Bool {
        let value = url.absoluteString.lowercased()
        return value.contains(".m3u8") || url.pathExtension.lowercased() == "m3u"
    }

    private static func firstVariantURL(in content: String, baseURL: URL) -> URL? {
        let lines = normalizedLines(content)
        for index in lines.indices where lines[index].hasPrefix("#EXT-X-STREAM-INF") {
            var next = index + 1
            while next < lines.count {
                let candidate = lines[next].trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty && !candidate.hasPrefix("#") {
                    guard candidate.lowercased().contains(".m3u8") else { break }
                    return URL(string: candidate, relativeTo: baseURL)?.absoluteURL
                }
                next += 1
            }
        }
        return nil
    }

    private static func normalizedLines(_ content: String) -> [String] {
        content
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }
}

struct M3U8PurifierSettings {
    static let key = "m3u8_purify"
    static let defaultEnabled = true

    static var isEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: key) == nil {
            defaults.set(defaultEnabled, forKey: key)
            return defaultEnabled
        }
        return defaults.bool(forKey: key)
    }
}

/// 只服务净化后的 m3u8 文本，不代理分片数据。
actor M3U8LoopbackProxy {
    static let shared = M3U8LoopbackProxy()

    private struct Slot {
        let content: String
        var lastAccess: UInt64
    }

    private let queue = DispatchQueue(label: "com.congcong.tv.m3u8-proxy")
    private var listener: NWListener?
    private var port: UInt16?
    private var sequence: UInt64 = 0
    private var slots: [String: Slot] = [:]
    private var readyWaiters: [CheckedContinuation<UInt16, Error>] = []
    private let slotLimit = 8

    func publish(content: String) async throws -> String {
        let port = try await startIfNeeded()
        sequence &+= 1
        let key = "\(UInt64(Date().timeIntervalSince1970 * 1000))-\(sequence)"
        slots[key] = Slot(content: content, lastAccess: sequence)
        trimSlots()
        return "http://127.0.0.1:\(port)/m3u8/\(key).m3u8"
    }

    private func startIfNeeded() async throws -> UInt16 {
        if let port { return port }
        return try await withCheckedThrowingContinuation { continuation in
            readyWaiters.append(continuation)
            guard listener == nil else { return }
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
                let newListener = try NWListener(using: parameters)
                listener = newListener
                newListener.stateUpdateHandler = { [weak self] state in
                    Task { await self?.handleListenerState(state) }
                }
                newListener.newConnectionHandler = { [weak self] connection in
                    Task { await self?.accept(connection) }
                }
                newListener.start(queue: queue)
            } catch {
                listener = nil
                resumeReadyWaiters(with: error)
            }
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port?.rawValue else {
                listener?.cancel()
                listener = nil
                resumeReadyWaiters(with: CocoaError(.fileReadUnknown))
                return
            }
            self.port = port
            resumeReadyWaiters(with: nil)
        case .failed(let error):
            listener?.cancel()
            listener = nil
            port = nil
            resumeReadyWaiters(with: error)
        case .cancelled:
            listener = nil
            port = nil
        default:
            break
        }
    }

    private func resumeReadyWaiters(with error: Error?) {
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for waiter in waiters {
            if let error {
                waiter.resume(throwing: error)
            } else if let port {
                waiter.resume(returning: port)
            } else {
                waiter.resume(throwing: CocoaError(.fileReadUnknown))
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, data: Data())
    }

    private func receive(on connection: NWConnection, data accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            Task {
                await self?.handleRequest(
                    data: data,
                    complete: complete,
                    error: error,
                    connection: connection,
                    accumulated: accumulated
                )
            }
        }
    }

    private func handleRequest(
        data: Data?,
        complete: Bool,
        error: NWError?,
        connection: NWConnection,
        accumulated: Data
    ) {
        guard error == nil else {
            connection.cancel()
            return
        }
        let request = accumulated + (data ?? Data())
        let delimiter = Data([13, 10, 13, 10])
        guard let range = request.range(of: delimiter) else {
            guard !complete, request.count < 65_536 else {
                send(Self.response(status: 400, reason: "Bad Request", body: "Bad Request"), on: connection)
                return
            }
            receive(on: connection, data: request)
            return
        }

        let headerData = request[..<range.lowerBound]
        guard let header = String(data: headerData, encoding: .utf8),
              let line = header.components(separatedBy: "\r\n").first,
              let path = line.split(separator: " ").dropFirst().first,
              line.hasPrefix("GET ") else {
            send(Self.response(status: 400, reason: "Bad Request", body: "Bad Request"), on: connection)
            return
        }

        let pathString = String(path)
        let key = pathString
            .replacingOccurrences(of: "/m3u8/", with: "")
            .replacingOccurrences(of: ".m3u8", with: "")
        guard pathString.hasPrefix("/m3u8/"), let slot = slots[key] else {
            send(Self.response(status: 404, reason: "Not Found", body: "m3u8 slot not found"), on: connection)
            return
        }
        sequence &+= 1
        slots[key] = Slot(content: slot.content, lastAccess: sequence)
        send(Self.response(status: 200, reason: "OK", body: slot.content, contentType: "application/vnd.apple.mpegurl"), on: connection)
    }

    private func trimSlots() {
        guard slots.count > slotLimit else { return }
        let removeCount = slots.count - slotLimit
        for key in slots.sorted(by: { $0.value.lastAccess < $1.value.lastAccess }).prefix(removeCount).map(\.key) {
            slots.removeValue(forKey: key)
        }
    }

    private func send(_ data: Data, on connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func response(
        status: Int,
        reason: String,
        body: String,
        contentType: String = "text/plain; charset=utf-8"
    ) -> Data {
        let bodyData = Data(body.utf8)
        let header = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: \(contentType)",
            "Cache-Control: no-store",
            "Content-Length: \(bodyData.count)",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        return Data(header.utf8) + bodyData
    }
}

struct M3U8ManifestPurifier {
    struct Result {
        let content: String
        let removedSegmentCount: Int
    }

    private static let adURLPattern = try! NSRegularExpression(
        pattern: #"(?i)(^|[/?&=_.-])(ads?|adv|advert(ise(ment)?)?|commercial|preroll|pre-roll|midroll|mid-roll|postroll|post-roll|sponsor|scte|vast|vmap|interstitial|bumper)([/?&=_.-]|$)"#
    )
    private static let adDomains = [
        "adservice", "adserver", "adsystem", "doubleclick", "googlesyndication",
        "advertising", "2mdn.net", "moatads", "scorecardresearch", "quantserve"
    ]

    static func purify(baseURL: URL, content: String) -> Result {
        let original = normalize(content)
        guard original.hasPrefix("#EXTM3U") else { return Result(content: content, removedSegmentCount: 0) }
        let originalSegments = mediaCount(original)
        var removed = 0
        // AVBox 的 get() 会先把所有可播放 URI 解析成绝对地址。
        // 代理清单运行在 127.0.0.1 上，若保留相对地址，播放器会错误地向回环地址请求分片。
        var transformed = resolveMediaURIs(resolveURIAttributes(original, baseURL: baseURL), baseURL: baseURL)
        transformed = removeURLMinority(transformed, baseURL: baseURL, removed: &removed)
        transformed = removeCommonAdMarkers(transformed, removed: &removed)
        transformed = removeSuspiciousDiscontinuityGroups(transformed, removed: &removed)
        if hasEndList(transformed) && transformed.contains("#EXT-X-DISCONTINUITY") {
            transformed = removeDiscontinuityFormatAds(transformed, removed: &removed)
        }
        transformed = normalizeDiscontinuities(transformed)

        if originalSegments > 0 && removed > originalSegments / 2 {
            return Result(content: original, removedSegmentCount: 0)
        }
        guard removed > 0, isPlayable(transformed) else {
            return Result(content: original, removedSegmentCount: 0)
        }
        if hasEndList(original) && !hasEndList(transformed) {
            transformed += "#EXT-X-ENDLIST\n"
        }
        return Result(content: transformed, removedSegmentCount: removed)
    }

    private static func normalize(_ content: String) -> String {
        content
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func resolveURIAttributes(_ content: String, baseURL: URL) -> String {
        let pattern = try! NSRegularExpression(pattern: #"URI="([^"]+)""#)
        return content.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let line = String(raw)
            guard line.hasPrefix("#"), let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let valueRange = Range(match.range(at: 1), in: line),
                  let resolved = URL(string: String(line[valueRange]), relativeTo: baseURL)?.absoluteString else {
                return line
            }
            return line.replacingCharacters(in: valueRange, with: resolved)
        }.joined(separator: "\n")
    }

    private static func resolveMediaURIs(_ content: String, baseURL: URL) -> String {
        content.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return line }
            return absoluteURL(trimmed, baseURL: baseURL)
        }.joined(separator: "\n")
    }

    private static func removeURLMinority(_ content: String, baseURL: URL, removed: inout Int) -> String {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let urls = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#") && !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard urls.count >= 6 else { return content }
        var prefixes: [String: Int] = [:]
        var hosts: [String: Int] = [:]
        for raw in urls {
            let absolute = absoluteURL(raw, baseURL: baseURL)
            let path = URL(string: absolute)?.deletingPathExtension().absoluteString ?? absolute
            let prefix = path.count > 4 ? String(path.dropLast(4)) : path
            prefixes[prefix, default: 0] += 1
            if let host = URL(string: absolute)?.host { hosts[host, default: 0] += 1 }
        }
        let dominantPrefix = prefixes.max(by: { $0.value < $1.value })
        let usePrefix = dominantPrefix.map { prefixes.count > 1 && Double($0.value) / Double(urls.count) >= 0.8 } ?? false
        let dominantHost = hosts.max(by: { $0.value < $1.value })
        let useHost = !usePrefix && dominantHost.map { hosts.count > 1 && Double($0.value) / Double(urls.count) >= 0.8 } ?? false
        guard usePrefix || useHost else { return content }

        var pending: [String] = []
        var output: [String] = []
        for raw in lines {
            let item = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if item.isEmpty { pending.append(raw); continue }
            if item.hasPrefix("#") {
                if isSegmentTag(item) { pending.append(raw) } else { output.append(contentsOf: pending); pending.removeAll(); output.append(raw) }
                continue
            }
            let absolute = absoluteURL(raw, baseURL: baseURL)
            let path = URL(string: absolute)?.deletingPathExtension().absoluteString ?? absolute
            let prefix = path.count > 4 ? String(path.dropLast(4)) : path
            let host = URL(string: absolute)?.host ?? ""
            let keep = usePrefix
                ? prefix == dominantPrefix?.key
                : (host == dominantHost?.key || (hosts[host] ?? 0) > 15)
            if keep {
                output.append(contentsOf: pending); pending.removeAll(); output.append(absolute)
            } else {
                pending.removeAll(); removed += 1
            }
        }
        output.append(contentsOf: pending)
        return output.joined(separator: "\n")
    }

    private static func removeCommonAdMarkers(_ content: String, removed: inout Int) -> String {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var output: [String] = []
        var pending: [String] = []
        var inAdBreak = false
        for raw in lines {
            let item = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if item.isEmpty { pending.append(raw); continue }
            if item.hasPrefix("#") {
                if item.hasPrefix("#EXT-X-CUE-OUT") || isAdSignal(item) {
                    output.append(contentsOf: pending); pending.removeAll()
                    inAdBreak = true
                    pending.append(raw)
                    continue
                }
                if item.hasPrefix("#EXT-X-CUE-IN") {
                    inAdBreak = false
                    pending.removeAll()
                    continue
                }
                if isStandaloneAdTag(item) {
                    output.append(contentsOf: pending); pending.removeAll()
                    removed += 1
                    continue
                }
                if isSegmentTag(item) || inAdBreak { pending.append(raw) }
                else { output.append(contentsOf: pending); pending.removeAll(); output.append(raw) }
                continue
            }
            if inAdBreak || pending.contains(where: { isAdSignal($0) }) || isAdURL(item) {
                pending.removeAll()
                removed += 1
                continue
            }
            output.append(contentsOf: pending); pending.removeAll(); output.append(raw)
        }
        if !inAdBreak { output.append(contentsOf: pending) }
        return output.joined(separator: "\n")
    }

    private static func removeSuspiciousDiscontinuityGroups(_ content: String, removed: inout Int) -> String {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var groups: [[String]] = [[]]
        for line in lines {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXT-X-DISCONTINUITY"),
               groups.last?.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#") }) == true {
                groups.append([])
            }
            groups[groups.count - 1].append(line)
        }
        guard groups.count >= 3 else { return content }
        let stats = groups.map(groupStats)
        guard let mainIndex = stats.indices.max(by: { stats[$0].duration < stats[$1].duration }) else { return content }
        let main = stats[mainIndex]
        guard main.segments >= 3 else { return content }
        var output: [String] = []
        for index in groups.indices {
            let current = stats[index]
            let short = current.segments > 0 && (current.segments <= 2 || current.duration < main.duration * 0.18)
            let different = !main.host.isEmpty && !current.host.isEmpty && main.host != current.host
            let differentPath = !main.path.isEmpty && !current.path.isEmpty && main.path != current.path
            let adLike = current.adLike || different || (current.segments <= 2 && differentPath)
            if index != mainIndex && short && adLike {
                removed += current.segments
            } else {
                output.append(contentsOf: groups[index])
            }
        }
        return output.joined(separator: "\n")
    }

    /// 安卓端还会利用 EXTINF 小数精度和帧率特征识别短广告块，这里保持相同的保守策略。
    private static func removeDiscontinuityFormatAds(_ content: String, removed: inout Int) -> String {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let groups = buildGroups(lines)
        guard groups.count >= 2 else { return content }
        let durations = groups.flatMap { $0.compactMap(extinfDuration) }
        guard durations.count >= 8 else { return content }

        let precisions = durations.map(decimalPrecision)
        let precisionCounts = Dictionary(grouping: precisions, by: { $0 }).mapValues(\.count)
        let dominantPrecision = precisionCounts.max(by: { $0.value < $1.value })
        let precisionReliable = dominantPrecision.map { Double($0.value) / Double(durations.count) >= 0.7 } ?? false
        let dominantRate = dominantFrameRate(durations)
        var drop = Set<Int>()
        var removable = 0
        for index in groups.indices.dropLast() {
            let groupDurations = groups[index].compactMap(extinfDuration)
            guard !groupDurations.isEmpty, groupDurations.count <= 12 else { continue }
            let short = groupDurations.count <= 2 || groupDurations.reduce(0, +) < durations.reduce(0, +) * 0.18
            let precisionMismatch = precisionReliable && groupDurations.allSatisfy { decimalPrecision($0) != dominantPrecision!.key }
            let rateMismatch = dominantRate != nil && groupDurations.filter { frameRate($0) == dominantRate }.count < groupDurations.count / 2
            if short && (precisionMismatch || rateMismatch) {
                drop.insert(index)
                removable += groupDurations.count
            }
        }
        guard !drop.isEmpty, removable <= max(1, durations.count * 3 / 10) else { return content }
        var output: [String] = []
        for index in groups.indices {
            if drop.contains(index) { removed += groups[index].compactMap(extinfDuration).count }
            else { output.append(contentsOf: groups[index]) }
        }
        return output.joined(separator: "\n")
    }

    private static func buildGroups(_ lines: [String]) -> [[String]] {
        var result: [[String]] = [[]]
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("#EXT-X-DISCONTINUITY"),
               result.last?.contains(where: { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }) == true {
                result.append([])
            }
            result[result.count - 1].append(line)
        }
        return result
    }

    private static func extinfDuration(_ line: String) -> Double? {
        guard line.hasPrefix("#EXTINF:"), let value = line.dropFirst(8).split(separator: ",").first else { return nil }
        return Double(value)
    }

    private static func decimalPrecision(_ value: Double) -> Int {
        let text = String(format: "%.6f", value).replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
        return text.split(separator: ".").last?.count ?? 0
    }

    private static func dominantFrameRate(_ values: [Double]) -> Int? {
        let rates = values.map(frameRate).filter { $0 > 0 }
        let counts = Dictionary(grouping: rates, by: { $0 }).mapValues(\.count)
        guard let item = counts.max(by: { $0.value < $1.value }), item.value >= 2 else { return nil }
        return item.key
    }

    private static func frameRate(_ value: Double) -> Int {
        let fraction = value - floor(value)
        let candidates: [(Int, Double)] = [(30, 1.0 / 30.0), (25, 1.0 / 25.0), (24, 1.0 / 24.0)]
        for (rate, step) in candidates {
            let nearest = (fraction / step).rounded() * step
            if abs(fraction - nearest) < 0.012 { return rate }
        }
        return 0
    }

    private struct GroupStats {
        var segments = 0
        var duration = 0.0
        var host = ""
        var path = ""
        var adLike = false
    }

    private static func groupStats(_ lines: [String]) -> GroupStats {
        var stats = GroupStats()
        for raw in lines {
            let item = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if item.hasPrefix("#EXTINF:"), let value = item.dropFirst(8).split(separator: ",").first, let duration = Double(value) { stats.duration += duration }
            guard !item.isEmpty, !item.hasPrefix("#") else {
                if isAdSignal(item) || isStandaloneAdTag(item) { stats.adLike = true }
                continue
            }
            stats.segments += 1
            if isAdURL(item) { stats.adLike = true }
            if let url = URL(string: item) {
                if stats.host.isEmpty { stats.host = url.host ?? "" }
                if stats.path.isEmpty { stats.path = url.deletingLastPathComponent().absoluteString }
            }
        }
        return stats
    }

    private static func normalizeDiscontinuities(_ content: String) -> String {
        var output: [String] = []
        var seenMedia = false
        var pending = false
        for raw in normalize(content).split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let item = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if item.hasPrefix("#EXT-X-DISCONTINUITY") && !item.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE") {
                if seenMedia { pending = true }
                continue
            }
            if pending {
                if !item.isEmpty && !item.hasPrefix("#EXT-X-ENDLIST") { output.append("#EXT-X-DISCONTINUITY") }
                pending = false
            }
            output.append(raw)
            if !item.isEmpty && !item.hasPrefix("#") { seenMedia = true }
        }
        return output.joined(separator: "\n")
    }

    private static func absoluteURL(_ raw: String, baseURL: URL) -> String {
        URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: baseURL)?.absoluteURL.absoluteString ?? raw
    }

    private static func isSegmentTag(_ line: String) -> Bool {
        ["#EXTINF", "#EXT-X-BYTERANGE", "#EXT-X-PROGRAM-DATE-TIME", "#EXT-X-DISCONTINUITY", "#EXT-X-PART", "#EXT-X-PRELOAD-HINT"].contains { line.hasPrefix($0) }
    }

    private static func isAdSignal(_ line: String) -> Bool {
        let value = line.lowercased()
        return value.hasPrefix("#ext-oatcls-scte35") || value.hasPrefix("#ext-x-scte35") ||
            value.hasPrefix("#ext-x-splicepoint-scte35") || value.hasPrefix("#ext-x-cue") ||
            value.hasPrefix("#ext-x-asset") || value.hasPrefix("#ext-x-vmap-ad-break") || value.hasPrefix("#ext-x-ad")
    }

    private static func isStandaloneAdTag(_ line: String) -> Bool {
        guard line.hasPrefix("#EXT-X-DATERANGE") else { return false }
        return isAdLikeText(line) || line.contains("X-ASSET-URI") || line.contains("X-ASSET-LIST")
    }

    private static func isAdLikeText(_ line: String) -> Bool {
        let value = line.lowercased()
        return ["scte", "cue", "interstitial", "vmap", "vast", "advert", "commercial", "ad-", "ad_", "ad.", "preroll", "midroll", "postroll", "bumper"].contains { value.contains($0) }
    }

    private static func isAdURL(_ line: String) -> Bool {
        let lower = line.lowercased()
        if adDomains.contains(where: lower.contains) { return true }
        let range = NSRange(lower.startIndex..., in: lower)
        return adURLPattern.firstMatch(in: lower, range: range) != nil
    }

    private static func mediaCount(_ content: String) -> Int {
        content.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#") }.count
    }

    private static func hasEndList(_ content: String) -> Bool { content.contains("#EXT-X-ENDLIST") }

    private static func isPlayable(_ content: String) -> Bool {
        guard content.hasPrefix("#EXTM3U") else { return false }
        var pendingExtInf = false
        var count = 0
        for raw in content.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXTINF") { pendingExtInf = true }
            else if !line.hasPrefix("#") { count += 1; pendingExtInf = false }
        }
        return count > 0 && !pendingExtInf
    }
}
