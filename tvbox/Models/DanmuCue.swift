import Foundation

/// A single timed danmaku item.
public struct DanmuCue: Codable, Hashable, Identifiable, Sendable {
    public let time: TimeInterval
    public let type: Int
    public let size: Double
    /// RGB color in the 0xRRGGBB form used by the Android parser.
    public let color: Int
    public let text: String

    public var id: String {
        "\(time)-\(type)-\(size)-\(color)-\(text)"
    }

    public var startTime: TimeInterval { time }
    public var timestamp: TimeInterval { time }
    public var timeMs: Int { Int((time * 1000).rounded()) }
    public var mode: Int { type }
    public var fontSize: Double { size }

    public init(
        time: TimeInterval,
        type: Int = 1,
        size: Double = 25,
        color: Int = 0xFFFFFF,
        text: String
    ) {
        self.time = time
        self.type = type
        self.size = size
        self.color = color
        self.text = text
    }

    public init(
        timestamp: TimeInterval,
        mode: Int = 1,
        fontSize: Double = 25,
        color: Int = 0xFFFFFF,
        text: String
    ) {
        self.init(time: timestamp, type: mode, size: fontSize, color: color, text: text)
    }
}
