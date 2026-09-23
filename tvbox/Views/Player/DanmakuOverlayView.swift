#if os(iOS)
import UIKit

/// UIKit-only danmaku layer intended to live inside the native player content layer.
/// It deliberately does not own media time; the player supplies it through `update`.
final class DanmakuOverlayView: UIView {
    private enum Placement {
        case scrolling
        case top
        case bottom
    }

    private struct ActiveBullet {
        let label: UILabel
        let placement: Placement
        let lane: Int
        let startTime: TimeInterval
        let duration: TimeInterval
        let width: CGFloat
    }

    private var cues: [DanmuCue] = []
    private var nextCueIndex = 0
    private var activeBullets: [ActiveBullet] = []
    private var displayLink: CADisplayLink?
    private var mediaTime: TimeInterval = 0
    private var mediaDuration: TimeInterval = 0
    private var wallClockAnchor: CFTimeInterval = 0
    private var hasTimeAnchor = false
    private var lastRenderedTime: TimeInterval = 0

    private let horizontalInset: CGFloat = 8
    private let rowHeight: CGFloat = 28
    private let scrollDuration: TimeInterval = 8
    private let fixedDuration: TimeInterval = 3.5
    private let maxActiveBullets = 80

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isUserInteractionEnabled = false
        backgroundColor = .clear
        clipsToBounds = true
        accessibilityElementsHidden = true
    }

    deinit {
        stopDisplayLink()
    }

    /// Replaces all cues and starts from the beginning of the supplied timeline.
    func setCues(_ cues: [DanmuCue]) {
        self.cues = cues.sorted { $0.timeMs < $1.timeMs }
        reset()
    }

    /// Supplies the current player time. The display link only interpolates between
    /// these callbacks to keep scrolling smooth while the player is playing.
    func update(currentTime: TimeInterval, duration: TimeInterval = 0) {
        let boundedTime = max(0, currentTime)
        let jumped = !hasTimeAnchor || abs(boundedTime - mediaTime) > 1.25
        mediaDuration = max(0, duration)
        mediaTime = boundedTime
        wallClockAnchor = CACurrentMediaTime()
        hasTimeAnchor = true

        if jumped || boundedTime + 0.1 < lastRenderedTime {
            clearActiveBullets()
            nextCueIndex = lowerBound(for: boundedTime)
        }

        lastRenderedTime = boundedTime
        if window != nil, !cues.isEmpty {
            startDisplayLinkIfNeeded()
        }
        render(at: boundedTime)
    }

    /// Clears active labels but keeps the loaded cue list.
    func reset() {
        clearActiveBullets()
        nextCueIndex = 0
        mediaTime = 0
        mediaDuration = 0
        lastRenderedTime = 0
        wallClockAnchor = CACurrentMediaTime()
        hasTimeAnchor = false
    }

    /// Clears both active labels and loaded cues.
    func clear() {
        reset()
        cues.removeAll(keepingCapacity: false)
        stopDisplayLink()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopDisplayLink()
        } else if !cues.isEmpty {
            startDisplayLinkIfNeeded()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A rotation/full-screen transition changes lane geometry; preserving labels
        // would make them jump across rows, so restart the short-lived overlay state.
        if !activeBullets.isEmpty {
            clearActiveBullets()
        }
    }

    private func startDisplayLinkIfNeeded() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(displayLinkTick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayLinkTick(_ link: CADisplayLink) {
        guard hasTimeAnchor else { return }
        let elapsed = max(0, CACurrentMediaTime() - wallClockAnchor)
        let interpolatedTime = mediaTime + elapsed
        if mediaDuration > 0, interpolatedTime > mediaDuration + 0.5 {
            render(at: mediaDuration)
        } else {
            render(at: interpolatedTime)
        }
    }

    private func render(at time: TimeInterval) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        while nextCueIndex < cues.count {
            let cue = cues[nextCueIndex]
            let cueTime = TimeInterval(cue.timeMs) / 1000
            guard cueTime <= time + 0.08 else { break }
            nextCueIndex += 1
            if time - cueTime <= 1.0, activeBullets.count < maxActiveBullets {
                enqueue(cue, at: cueTime)
            }
        }

        var remaining: [ActiveBullet] = []
        for bullet in activeBullets {
            let age = time - bullet.startTime
            guard age >= 0, age <= bullet.duration else {
                bullet.label.removeFromSuperview()
                continue
            }
            position(bullet, age: age)
            remaining.append(bullet)
        }
        activeBullets = remaining
    }

    private func enqueue(_ cue: DanmuCue, at cueTime: TimeInterval) {
        let placement: Placement
        switch cue.type {
        // The endpoint follows Bilibili's XML convention: 1/2/3/6 are
        // scrolling, 4 is bottom and 5 is top. Unsupported special effects
        // are rendered as scrolling text instead of being dropped.
        case 4: placement = .bottom
        case 5: placement = .top
        default: placement = .scrolling
        }

        let label = UILabel()
        label.text = cue.text
        label.textColor = UIColor(rgba: UInt32(truncatingIfNeeded: cue.color))
        label.font = .systemFont(ofSize: max(12, min(28, CGFloat(cue.size))))
        label.textAlignment = .center
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.85
        label.layer.shadowRadius = 1.5
        label.layer.shadowOffset = .zero
        label.sizeToFit()
        let width = min(max(label.bounds.width, 24), max(24, bounds.width - horizontalInset * 2))
        label.bounds.size = CGSize(width: width, height: rowHeight)

        let lane = availableLane(for: placement)
        addSubview(label)
        let bullet = ActiveBullet(label: label, placement: placement, lane: lane,
                                  startTime: cueTime, duration: placement == .scrolling ? scrollDuration : fixedDuration,
                                  width: width)
        activeBullets.append(bullet)
        position(bullet, age: max(0, lastRenderedTime - cueTime))
    }

    private func position(_ bullet: ActiveBullet, age: TimeInterval) {
        let laneCount = max(1, Int(bounds.height / rowHeight))
        let laneY = CGFloat(min(max(bullet.lane, 0), laneCount - 1)) * rowHeight
        switch bullet.placement {
        case .scrolling:
            let startX = bounds.width + bullet.width
            let endX = -bullet.width
            let progress = CGFloat(min(1, max(0, age / bullet.duration)))
            bullet.label.frame = CGRect(x: startX + (endX - startX) * progress,
                                        y: laneY, width: bullet.width, height: rowHeight)
        case .top:
            bullet.label.frame = CGRect(x: (bounds.width - bullet.width) / 2,
                                        y: laneY, width: bullet.width, height: rowHeight)
        case .bottom:
            let y = bounds.height - rowHeight * CGFloat(min(max(bullet.lane + 1, 1), laneCount))
            bullet.label.frame = CGRect(x: (bounds.width - bullet.width) / 2,
                                        y: max(0, y), width: bullet.width, height: rowHeight)
        }
    }

    private func availableLane(for placement: Placement) -> Int {
        let laneCount = max(1, Int(bounds.height / rowHeight))
        let occupied = Set(activeBullets.filter { $0.placement == placement }.map(\.lane))
        return (0..<laneCount).first { !occupied.contains($0) } ?? (activeBullets.count % laneCount)
    }

    private func clearActiveBullets() {
        activeBullets.forEach { $0.label.removeFromSuperview() }
        activeBullets.removeAll(keepingCapacity: true)
    }

    private func lowerBound(for time: TimeInterval) -> Int {
        let target = Int(max(0, time) * 1000)
        var low = 0
        var high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].timeMs < target { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

private extension UIColor {
    convenience init(rgba: UInt32) {
        self.init(red: CGFloat((rgba >> 16) & 0xff) / 255,
                  green: CGFloat((rgba >> 8) & 0xff) / 255,
                  blue: CGFloat(rgba & 0xff) / 255,
                  alpha: 1)
    }
}
#endif
