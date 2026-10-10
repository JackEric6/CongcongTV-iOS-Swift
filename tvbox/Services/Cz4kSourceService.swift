import Foundation
#if os(iOS)
import UIKit
import WebKit
#endif

enum Cz4kSourceService {
    private static let origin = "https://www.cz4k.com"
    private static let headers = [
        "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
        "Referer": origin + "/"
    ]
    static func search(keyword: String) async throws -> [Movie.Video] {
        var components = URLComponents(string: origin + "/nimasile")
        components?.queryItems = [URLQueryItem(name: "q", value: keyword)]
        guard let url = components?.url else { throw SourceError.invalidApiUrl(origin + "/nimasile") }
        let html = try await fetch(url.absoluteString)
        return Cz4kSearchParser.parse(html: html, baseURL: url)
    }

    static func detail(vodID: String) async throws -> VodInfo {
        guard let url = resolvedURL(vodID, relativeTo: URL(string: origin)!) else {
            throw SourceError.invalidPlayableURL(vodID)
        }
        let html = try await fetch(url.absoluteString)
        let title = firstNonEmpty(
            firstCapture(#"(?is)<h1\b[^>]*>(.*?)</h1>"#, in: html, group: 1).map(text),
            firstCapture(#"(?is)<meta\s+[^>]*property=[\"']og:title[\"'][^>]*content=[\"']([^\"']*)[\"'][^>]*>"#, in: html, group: 1),
            firstCapture(#"(?is)<title\b[^>]*>(.*?)</title>"#, in: html, group: 1).map(text)
        )
        let image = firstCapture(#"(?is)<meta\s+[^>]*property=[\"']og:image[\"'][^>]*content=[\"']([^\"']*)[\"'][^>]*>"#, in: html, group: 1)
            ?? firstCapture(#"(?is)<img\b([^>]*)>"#, in: html, group: 1).flatMap { attribute("src", in: $0) }
            ?? ""
        let description = firstCapture(#"(?is)<meta\s+[^>]*name=[\"']description[\"'][^>]*content=[\"']([^\"']*)[\"'][^>]*>"#, in: html, group: 1)
            ?? firstCapture(#"(?is)<p\b[^>]*>(.*?)</p>"#, in: html, group: 1).map(text)
            ?? ""

        let video = Movie.Video(id: vodID, name: title)
        var enriched = video
        enriched.pic = absoluteImage(image, baseURL: url)
        enriched.des = description
        enriched.year = firstCapture(#"(?:19|20)\d{2}"#, in: html, group: 0) ?? ""
        enriched.sourceKey = "cz4k"

        var episodes: [VodInfo.Episode] = []
        var seen = Set<String>()
        let anchorPattern = try! NSRegularExpression(pattern: #"(?is)<a\b([^>]*?)>(.*?)</a\s*>"#)
        for match in anchorPattern.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let attrsRange = Range(match.range(at: 1), in: html),
                  let bodyRange = Range(match.range(at: 2), in: html) else { continue }
            let attrs = String(html[attrsRange])
            let body = String(html[bodyRange])
            guard let href = attribute("href", in: attrs),
                  let episodeURL = resolvedURL(href, relativeTo: url),
                  isPlayableURL(episodeURL), seen.insert(episodeURL.absoluteString).inserted else { continue }
            let name = firstNonEmpty(attribute("title", in: attrs), text(body), "第\(episodes.count + 1)集")
            episodes.append(VodInfo.Episode(name: name, url: episodeURL.absoluteString))
            if episodes.count >= 200 { break }
        }
        if episodes.isEmpty,
           let media = firstCapture(#"(?i)(https?:)?//[^\"'<>\s]+\.(?:m3u8|mp4)(?:\?[^\"'<>\s]*)?"#, in: html, group: 0) {
            let resolvedMedia = media.hasPrefix("//") ? "https:" + media : media
            episodes.append(VodInfo.Episode(name: "正片", url: resolvedMedia))
        }
        guard !episodes.isEmpty else { throw SourceError.invalidResponse("厂长详情页没有找到可播放剧集") }
        let playURL = episodes.map { "\($0.name)$\($0.url)" }.joined(separator: "#")
        return VodInfo.from(video: enriched, playFrom: "厂长线路", playUrl: playURL)
    }

    private static func fetch(_ url: String) async throws -> String {
        #if os(iOS)
        guard let target = URL(string: url) else { throw SourceError.invalidApiUrl(url) }
        return try await Cz4kBrowserSession.loadHTML(target)
        #else
        try await NetworkManager.shared.getString(from: url, headers: headers, timeout: 60, maxRetries: 0)
        #endif
    }

    private static func resolvedURL(_ value: String, relativeTo base: URL) -> URL? {
        URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: base)?.absoluteURL
    }

    private static func isPlayableURL(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return path.contains("/play") || path.contains("/vodplay") || path.contains("/vod-play")
            || path.contains("/playmov") || path.contains("/player")
            || path.contains("/v_play/") || path.hasSuffix(".m3u8") || path.hasSuffix(".mp4")
    }

    private static func attribute(_ name: String, in value: String) -> String? {
        let pattern = #"(?is)\b\#(name)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else {
            return nil
        }
        for index in 1..<match.numberOfRanges {
            guard let range = Range(match.range(at: index), in: value) else { continue }
            let result = decodeEntities(String(value[range])).trimmingCharacters(in: .whitespacesAndNewlines)
            if !result.isEmpty { return result }
        }
        return nil
    }

    private static func text(_ html: String) -> String {
        let withoutScripts = html.replacingOccurrences(of: #"(?is)<(script|style)\b[^>]*>.*?</\1>"#, with: " ", options: .regularExpression)
        let withoutTags = withoutScripts.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)
        return decodeEntities(withoutTags)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func absoluteImage(_ value: String, baseURL: URL) -> String {
        guard !value.isEmpty else { return "" }
        return resolvedURL(value, relativeTo: baseURL)?.absoluteString ?? value
    }

    private static func firstCapture(_ pattern: String, in value: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.numberOfRanges > group,
              let range = Range(match.range(at: group), in: value) else { return nil }
        return String(value[range])
    }

    private static func decodeEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    private static func firstNonEmpty(_ values: String?...) -> String {
        values.compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    }
}

#if os(iOS)
@MainActor
private final class Cz4kBrowserSession: NSObject, WKNavigationDelegate {
    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    private static let timeout: TimeInterval = 60

    private let requestURL: URL
    private let webView: WKWebView
    private let hostView: UIView
    private var continuation: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var finished = false

    private init(url: URL, webView: WKWebView, hostView: UIView) {
        requestURL = url
        self.webView = webView
        self.hostView = hostView
    }

    static func loadHTML(_ url: URL) async throws -> String {
        guard let host = url.host?.lowercased(), host == "cz4k.com" || host.hasSuffix(".cz4k.com") else {
            throw SourceError.invalidApiUrl(url.absoluteString)
        }
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })?.windows
            .first(where: \.isKeyWindow) else {
            throw SourceError.invalidResponse("厂长搜索需要可用的应用窗口，请返回应用后重试")
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        webView.customUserAgent = userAgent
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        let hostView = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        hostView.alpha = 0
        hostView.isUserInteractionEnabled = false
        hostView.accessibilityElementsHidden = true
        hostView.addSubview(webView)
        window.addSubview(hostView)

        let session = Cz4kBrowserSession(url: url, webView: webView, hostView: hostView)
        webView.navigationDelegate = session
        return try await session.load()
    }

    private func load() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                timeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(Self.timeout))
                    guard let self, !self.finished else { return }
                    self.finish(.failure(SourceError.invalidResponse(
                        "厂长网页验证尚未完成，请稍后重试"
                    )))
                }
                var request = URLRequest(url: requestURL, timeoutInterval: Self.timeout)
                request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
                request.setValue("https://www.cz4k.com/", forHTTPHeaderField: "Referer")
                webView.load(request)
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.finish(.failure(CancellationError()))
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        scheduleInspection()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    private func scheduleInspection() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1_200))
            guard let self, !self.finished else { return }
            self.inspectPage()
        }
    }

    private func inspectPage() {
        let script = """
        (function() {
          var title = document.title || '';
          var text = (document.body && document.body.innerText) || '';
          var challengeWidget = !!document.querySelector('cap-widget');
          var challengeText = /雷池|safeline|安全检查|访问验证|请稍候|正在验证|验证中|验证失败|checking your browser|verifying you are human|403 forbidden|access denied|人机验证/i.test(title + ' ' + text);
          return JSON.stringify({html: document.documentElement ? document.documentElement.outerHTML : '', challenge: challengeWidget || challengeText, textLength: text.length});
        })();
        """
        webView.evaluateJavaScript(script) { [weak self] value, error in
            guard let self, !self.finished else { return }
            if let error {
                self.finish(.failure(error))
                return
            }
            guard let json = value as? String,
                  let data = json.data(using: .utf8),
                  let page = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.scheduleInspection()
                return
            }
            if page["challenge"] as? Bool == true {
                self.scheduleInspection()
                return
            }
            let html = page["html"] as? String ?? ""
            let textLength = page["textLength"] as? Int ?? 0
            guard !html.isEmpty, textLength > 0 else {
                self.scheduleInspection()
                return
            }
            self.finish(.success(html))
        }
    }

    private func finish(_ result: Result<String, Error>) {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        pollTask?.cancel()
        webView.stopLoading()
        webView.navigationDelegate = nil
        hostView.removeFromSuperview()
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
#endif
