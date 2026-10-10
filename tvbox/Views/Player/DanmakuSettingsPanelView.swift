#if os(iOS)
import UIKit

struct DanmakuDisplaySettings: Codable, Equatable {
    var enabled = true
    var randomColors = false
    var speedLevel = 2
    var sizeLevel = 8
    var rowCount = 3
    var opacity = 90

    static let storageKey = "danmaku_display_settings"

    static func load() -> DanmakuDisplaySettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(Self.self, from: data) else {
            return Self()
        }
        return settings.normalized
    }

    func save() {
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    var normalized: Self {
        var value = self
        value.speedLevel = min(max(speedLevel, 0), 3)
        value.sizeLevel = min(max(sizeLevel, 1), 16)
        value.rowCount = min(max(rowCount, 1), 8)
        value.opacity = min(max(opacity / 10 * 10, 10), 100)
        return value
    }

    var scrollDuration: TimeInterval {
        [16.0, 12.0, 8.0, 5.0][normalized.speedLevel]
    }

    var sizeScale: CGFloat {
        CGFloat(normalized.sizeLevel) / 8
    }
}

final class DanmakuSettingsPanelView: UIView {
    var onSettingsChanged: ((DanmakuDisplaySettings) -> Void)?
    var onSearch: (() -> Void)?
    var onClose: (() -> Void)?

    private var settings: DanmakuDisplaySettings
    private var statusText: String
    private let enabledSwitch = UISwitch()
    private let colorControl = UISegmentedControl(items: ["默认", "随机"])
    private let speedControl = UISegmentedControl(items: ["超慢", "慢", "适中", "快"])
    private let sizeValue = UILabel()
    private let rowValue = UILabel()
    private let opacityValue = UILabel()
    private let statusLabel = UILabel()
    private let card = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterialDark))
    private let contentStack = UIStackView()

    init(settings: DanmakuDisplaySettings, status: String) {
        self.settings = settings.normalized
        statusText = status
        super.init(frame: .zero)
        buildView()
        refresh()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func update(settings: DanmakuDisplaySettings, status: String) {
        self.settings = settings.normalized
        statusText = status
        refresh()
    }

    private func buildView() {
        backgroundColor = UIColor.black.withAlphaComponent(0.38)

        card.translatesAutoresizingMaskIntoConstraints = false
        card.layer.cornerRadius = 12
        card.clipsToBounds = true
        addSubview(card)

        let header = UIView()
        let title = UILabel()
        title.text = "弹幕设置"
        title.textColor = .white
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(title)

        let closeButton = UIButton(type: .system)
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .white
        closeButton.accessibilityLabel = "关闭弹幕设置"
        closeButton.addTarget(self, action: #selector(closePressed), for: .primaryActionTriggered)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(closeButton)

        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.distribution = .fill
        contentStack.spacing = 5
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(contentStack)

        let headerAndBody = UIStackView(arrangedSubviews: [header, scroll])
        headerAndBody.axis = .vertical
        headerAndBody.spacing = 2
        headerAndBody.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(headerAndBody)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(equalTo: widthAnchor, constant: -16),
            card.heightAnchor.constraint(equalToConstant: 360).withPriority(750),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            card.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            card.topAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.topAnchor, constant: 10),
            card.bottomAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.bottomAnchor, constant: -10),
            headerAndBody.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 14),
            headerAndBody.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -14),
            headerAndBody.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 8),
            headerAndBody.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -10),
            header.heightAnchor.constraint(equalToConstant: 38),
            title.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 36),
            closeButton.heightAnchor.constraint(equalToConstant: 36),
            contentStack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])

        enabledSwitch.addTarget(self, action: #selector(enabledChanged), for: .valueChanged)
        colorControl.addTarget(self, action: #selector(colorChanged), for: .valueChanged)
        speedControl.addTarget(self, action: #selector(speedChanged), for: .valueChanged)
        colorControl.selectedSegmentTintColor = .systemOrange
        speedControl.selectedSegmentTintColor = .systemOrange

        let reloadButton = UIButton(type: .system)
        reloadButton.setTitle("搜索弹幕", for: .normal)
        reloadButton.setTitleColor(.white, for: .normal)
        reloadButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        reloadButton.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        reloadButton.layer.cornerRadius = 6
        reloadButton.addTarget(self, action: #selector(reloadPressed), for: .primaryActionTriggered)

        contentStack.addArrangedSubview(makeToggleRow("弹幕显示", control: enabledSwitch))
        contentStack.addArrangedSubview(makeRow("在线弹幕", trailing: reloadButton))
        contentStack.addArrangedSubview(makeRow("弹幕颜色", trailing: colorControl))
        contentStack.addArrangedSubview(makeRow("弹幕速度", trailing: speedControl))
        contentStack.addArrangedSubview(makeStepperRow("弹幕大小", value: sizeValue, minus: #selector(sizeDown), plus: #selector(sizeUp)))
        contentStack.addArrangedSubview(makeStepperRow("弹幕行数", value: rowValue, minus: #selector(rowsDown), plus: #selector(rowsUp)))
        contentStack.addArrangedSubview(makeStepperRow("弹幕透明", value: opacityValue, minus: #selector(opacityDown), plus: #selector(opacityUp)))

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.82)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        contentStack.addArrangedSubview(statusLabel)
        statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
    }

    private func makeToggleRow(_ title: String, control: UIView) -> UIView {
        let row = makeBaseRow(title)
        row.addArrangedSubview(control)
        control.setContentHuggingPriority(.required, for: .horizontal)
        return row
    }

    private func makeRow(_ title: String, trailing: UIView) -> UIView {
        let row = makeBaseRow(title)
        trailing.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(trailing)
        return row
    }

    private func makeBaseRow(_ title: String) -> UIStackView {
        let label = UILabel()
        label.text = title
        label.textColor = UIColor.white.withAlphaComponent(0.9)
        label.font = .systemFont(ofSize: 13)
        label.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let row = UIStackView(arrangedSubviews: [label])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.heightAnchor.constraint(equalToConstant: 40).isActive = true
        return row
    }

    private func makeStepperRow(_ title: String, value: UILabel, minus: Selector, plus: Selector) -> UIView {
        let row = makeBaseRow(title)
        let minusButton = stepButton(symbol: "minus", action: minus)
        let plusButton = stepButton(symbol: "plus", action: plus)
        value.font = .systemFont(ofSize: 13, weight: .medium)
        value.textColor = .white
        value.textAlignment = .center
        row.addArrangedSubview(minusButton)
        row.addArrangedSubview(value)
        row.addArrangedSubview(plusButton)
        return row
    }

    private func stepButton(symbol: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        button.layer.cornerRadius = 18
        button.addTarget(self, action: action, for: .primaryActionTriggered)
        button.widthAnchor.constraint(equalToConstant: 36).isActive = true
        button.heightAnchor.constraint(equalToConstant: 36).isActive = true
        return button
    }

    private func refresh() {
        let value = settings.normalized
        enabledSwitch.isOn = value.enabled
        colorControl.selectedSegmentIndex = value.randomColors ? 1 : 0
        speedControl.selectedSegmentIndex = value.speedLevel
        sizeValue.text = "\(value.sizeLevel) 档"
        rowValue.text = "\(value.rowCount) 行"
        opacityValue.text = "\(value.opacity)%"
        statusLabel.text = statusText
    }

    private func commit() {
        settings = settings.normalized
        settings.save()
        refresh()
        onSettingsChanged?(settings)
    }

    @objc private func enabledChanged() {
        settings.enabled = enabledSwitch.isOn
        commit()
    }

    @objc private func colorChanged() {
        settings.randomColors = colorControl.selectedSegmentIndex == 1
        commit()
    }

    @objc private func speedChanged() {
        settings.speedLevel = speedControl.selectedSegmentIndex
        commit()
    }

    @objc private func sizeDown() { settings.sizeLevel -= 1; commit() }
    @objc private func sizeUp() { settings.sizeLevel += 1; commit() }
    @objc private func rowsDown() { settings.rowCount -= 1; commit() }
    @objc private func rowsUp() { settings.rowCount += 1; commit() }
    @objc private func opacityDown() { settings.opacity -= 10; commit() }
    @objc private func opacityUp() { settings.opacity += 10; commit() }

    @objc private func reloadPressed() {
        onSearch?()
    }

    @objc private func closePressed() {
        onClose?()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit === self {
            onClose?()
            return self
        }
        return hit
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ value: Float) -> NSLayoutConstraint {
        priority = UILayoutPriority(value)
        return self
    }
}
#endif
