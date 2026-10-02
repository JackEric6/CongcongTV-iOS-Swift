import Foundation

enum DownloadPayloadValidator {
    private static let transportPacketSize = 188

    struct HLSPlaylistMetrics: Equatable, Sendable {
        let segmentCount: Int
        let duration: TimeInterval
    }

    /// 统计媒体清单中的实际媒体分片，而不是把主清晰度索引或密钥
    /// URI 误算进去。瓜子浏览器 UA 返回的短预览通常只有 2 个分片，
    /// 用这个指标可以在落盘前拒绝短预览。
    static func hlsPlaylistMetrics(_ playlist: String) -> HLSPlaylistMetrics {
        var segmentCount = 0
        var duration: TimeInterval = 0
        var expectsSegment = false

        for rawLine in playlist.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let uppercased = line.uppercased()
            if uppercased.hasPrefix("#EXTINF:") {
                expectsSegment = true
                let payload = line.dropFirst("#EXTINF:".count)
                    .split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                    .first
                    .map(String.init) ?? ""
                if let value = Double(payload.trimmingCharacters(in: .whitespacesAndNewlines)),
                   value.isFinite, value > 0 {
                    duration += value
                }
                continue
            }
            guard expectsSegment, !line.hasPrefix("#") else { continue }
            segmentCount += 1
            expectsSegment = false
        }

        return HLSPlaylistMetrics(segmentCount: segmentCount, duration: duration)
    }

    static func isLikelyPreviewHLS(
        segmentCount: Int,
        duration: TimeInterval,
        minimumSegments: Int = 3,
        minimumDuration: TimeInterval = 30
    ) -> Bool {
        segmentCount < minimumSegments
            || !duration.isFinite
            || duration < minimumDuration
    }

    static func isRejectedPayload(_ data: Data, mimeType: String? = nil) -> Bool {
        let mime = mimeType?.components(separatedBy: ";").first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if mime.hasPrefix("text/")
            || mime.contains("json")
            || mime.contains("xml")
            || mime.contains("javascript")
            || mime.contains("mpegurl") {
            return true
        }

        guard let text = String(data: data.prefix(1024), encoding: .utf8) else { return false }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return false }
        if value.hasPrefix("#extm3u") { return false }
        if value.hasPrefix("<") || value.hasPrefix("{") || value.hasPrefix("[") {
            return true
        }

        let printableCount = value.unicodeScalars.filter {
            CharacterSet.controlCharacters.contains($0) == false
        }.count
        guard printableCount * 100 / max(1, value.unicodeScalars.count) >= 90 else {
            return false
        }
        return [
            "access denied",
            "request forbidden",
            "forbidden",
            "bad gateway",
            "error 403",
            "error 404",
            "error 502",
            "unauthorized",
            "verify you are human",
            "security check",
            "访问受限",
            "请求异常",
            "校验失败"
        ].contains { value.contains($0) }
    }

    static func isMPEGTransportStream(_ data: Data) -> Bool {
        let packetCount = min(3, data.count / transportPacketSize)
        guard packetCount > 0 else { return false }
        let lastOffset = min(
            transportPacketSize - 1,
            data.count - transportPacketSize * packetCount
        )
        guard lastOffset >= 0 else { return false }
        for offset in 0...lastOffset {
            let hasExpectedSyncBytes = (0..<packetCount).allSatisfy { packet in
                data[offset + packet * transportPacketSize] == 0x47
            }
            if hasExpectedSyncBytes {
                return true
            }
        }
        return false
    }

    static func isSupportedMediaPayload(
        prefix: Data,
        mimeType: String? = nil,
        fileExtension: String
    ) -> Bool {
        guard !prefix.isEmpty, !isRejectedPayload(prefix, mimeType: mimeType) else {
            return false
        }

        let ext = fileExtension.lowercased()
        let bytes = [UInt8](prefix.prefix(64))
        let isoBrand = bytes.count >= 8
            ? String(bytes: bytes[4..<8], encoding: .ascii)
            : nil
        let isISOBaseMedia = ["ftyp", "styp", "moov"].contains(isoBrand ?? "")
        let isEBML = bytes.starts(with: [0x1A, 0x45, 0xDF, 0xA3])
        let isFLV = bytes.starts(with: Array("FLV".utf8))
        let isAVI = bytes.count >= 12
            && bytes[0..<4].elementsEqual(Array("RIFF".utf8))
            && bytes[8..<12].elementsEqual(Array("AVI ".utf8))
        let isMPEGProgramStream = bytes.starts(with: [0x00, 0x00, 0x01, 0xBA])
            || bytes.starts(with: [0x00, 0x00, 0x01, 0xB3])
        let isID3Audio = bytes.starts(with: Array("ID3".utf8))
        let isADTS = bytes.count >= 2 && bytes[0] == 0xFF && (bytes[1] & 0xF6) == 0xF0

        switch ext {
        case "mp4", "m4v", "mov", "3gp":
            return isISOBaseMedia
        case "ts", "m2ts", "mts":
            return isMPEGTransportStream(prefix)
        case "mkv", "webm":
            return isEBML
        case "flv":
            return isFLV
        case "avi":
            return isAVI
        case "mpg", "mpeg":
            return isMPEGProgramStream
        case "mp3":
            return isID3Audio || (bytes.count >= 2 && bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0)
        case "aac":
            return isADTS
        default:
            return isISOBaseMedia
                || isMPEGTransportStream(prefix)
                || isEBML
                || isFLV
                || isAVI
                || isMPEGProgramStream
                || isID3Audio
                || isADTS
        }
    }

    static func prefix(at url: URL, maxLength: Int = 4096) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: maxLength)
    }
}
