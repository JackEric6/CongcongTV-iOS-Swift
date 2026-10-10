#if os(iOS)
import UIKit

final class DanmakuSearchPanelView: UIView, UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate {
    var onSearch: ((String) -> Void)?
    var onSelect: ((Int) -> Void)?
    var onClose: (() -> Void)?

    private(set) var results: [DanmuSearchResult] = []
    private let card = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterialLight))
    private let searchField = UITextField()
    private let searchButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let statusLabel = UILabel()
    private let activity = UIActivityIndicatorView(style: .medium)

    init(query: String) {
        super.init(frame: .zero)
        buildView(query: query)
    }

    required init?(coder: NSCoder) { nil }

    func update(results: [DanmuSearchResult], status: String, loading: Bool) {
        self.results = results
        statusLabel.text = status
        if loading { activity.startAnimating() } else { activity.stopAnimating() }
        tableView.reloadData()
    }

    private func buildView(query: String) {
        backgroundColor = UIColor.black.withAlphaComponent(0.55)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.layer.cornerRadius = 14
        card.clipsToBounds = true
        addSubview(card)

        let title = UILabel()
        title.text = "弹幕搜索"
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .label
        title.textAlignment = .center

        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .secondaryLabel
        closeButton.accessibilityLabel = "关闭弹幕搜索"
        closeButton.addTarget(self, action: #selector(closePressed), for: .primaryActionTriggered)

        let header = UIView()
        [title, closeButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview($0)
        }

        searchField.text = query
        searchField.placeholder = "输入影片名称"
        searchField.borderStyle = .roundedRect
        searchField.clearButtonMode = .whileEditing
        searchField.returnKeyType = .search
        searchField.delegate = self
        searchField.accessibilityLabel = "弹幕搜索名称"
        searchField.translatesAutoresizingMaskIntoConstraints = false

        searchButton.setTitle("搜索", for: .normal)
        searchButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        searchButton.addTarget(self, action: #selector(searchPressed), for: .primaryActionTriggered)
        searchButton.translatesAutoresizingMaskIntoConstraints = false

        let searchRow = UIStackView(arrangedSubviews: [searchField, searchButton])
        searchRow.axis = .horizontal
        searchRow.alignment = .center
        searchRow.spacing = 8
        searchRow.translatesAutoresizingMaskIntoConstraints = false

        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 48
        tableView.keyboardDismissMode = .onDrag
        tableView.backgroundColor = .clear
        tableView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 2
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        activity.hidesWhenStopped = true

        let statusRow = UIStackView(arrangedSubviews: [activity, statusLabel])
        statusRow.axis = .horizontal
        statusRow.alignment = .center
        statusRow.spacing = 8
        statusRow.translatesAutoresizingMaskIntoConstraints = false

        let content = UIStackView(arrangedSubviews: [header, searchRow, statusRow, tableView])
        content.axis = .vertical
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(content)

        let preferredCardWidth = card.widthAnchor.constraint(equalTo: widthAnchor, constant: -32)
        preferredCardWidth.priority = UILayoutPriority(750)
        let preferredCardHeight = card.heightAnchor.constraint(equalTo: heightAnchor, constant: -40)
        preferredCardHeight.priority = UILayoutPriority(750)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            preferredCardWidth,
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 700),
            card.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            preferredCardHeight,
            card.heightAnchor.constraint(lessThanOrEqualToConstant: 480),
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),
            content.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -18),
            content.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -14),
            header.heightAnchor.constraint(equalToConstant: 30),
            title.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),
            searchButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 46),
            statusRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 20)
        ])
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        results.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let reuseID = "danmaku-result"
        let cell = tableView.dequeueReusableCell(withIdentifier: reuseID)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: reuseID)
        let result = results[indexPath.row]
        cell.textLabel?.text = result.name
        cell.textLabel?.font = .systemFont(ofSize: 14)
        cell.textLabel?.numberOfLines = 2
        cell.detailTextLabel?.text = result.isBuiltin ? "内置弹幕源" : result.url
        cell.detailTextLabel?.font = .systemFont(ofSize: 10)
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.backgroundColor = .clear
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onSelect?(indexPath.row)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        searchPressed()
        return true
    }

    @objc private func searchPressed() {
        searchField.resignFirstResponder()
        onSearch?(searchField.text ?? "")
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
#endif
