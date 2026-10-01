import Foundation
import Network

actor GuaziService {
    static let shared = GuaziService()

    func play(_ request: GuaziPlaybackRequest) async throws -> String {
        "https://unused.invalid/video.m3u8"
    }
}

@main
struct VerifyGuaziPlaybackProxy {
    static func main() async throws {
        let expected = GuaziPlaybackRequest(
            vodID: "vod-11",
            cloudID: "cloud-22",
            vurlID: "episode-33",
            domainType: "private%2Fcloud",
            resolution: "720",
            type: "play"
        )
        let resolver = ResolverProbe(expected: expected)
        let proxy = GuaziPlaybackProxy { request in
            try await resolver.resolve(request)
        }
        let port = try await proxy.startIfNeeded()
        guard let url = URL(string: expected.url(port: port)) else {
            fatalError("Could not build the loopback URL")
        }

        let session = URLSession(
            configuration: .ephemeral,
            delegate: RedirectBlocker(),
            delegateQueue: nil
        )
        let firstResponse = try await get(url, using: session)
        require(firstResponse.statusCode == 301, "local playback request must return Android's 301 redirect")
        require(
            firstResponse.value(forHTTPHeaderField: "Location") == "https://cdn.example/video-1.m3u8",
            "first local playback request must forward its freshly resolved media URL"
        )
        require(
            firstResponse.value(forHTTPHeaderField: "Cache-Control") == "no-store",
            "local redirect must not be cached"
        )

        let secondResponse = try await get(url, using: session)
        require(secondResponse.statusCode == 301, "repeated local playback requests must remain valid")
        require(
            secondResponse.value(forHTTPHeaderField: "Location") == "https://cdn.example/video-2.m3u8",
            "each episode request must resolve a fresh media URL instead of reusing a stale redirect"
        )

        let didReceiveExpectedRequest = await resolver.didReceiveExpectedRequests
        require(didReceiveExpectedRequest, "proxy must preserve all episode parameters on every request")
        print("GUAZI LOOPBACK HTTP PLAYBACK CHECKS PASSED")
    }

    private static func get(_ url: URL, using session: URLSession) async throws -> HTTPURLResponse {
        var request = URLRequest(url: url)
        request.setValue("close", forHTTPHeaderField: "Connection")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            fatalError("Loopback server returned a non-HTTP response")
        }
        return http
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError("FAIL: \(message)")
        }
    }
}

private actor ResolverProbe {
    private let expected: GuaziPlaybackRequest
    private var requestCount = 0
    private(set) var didReceiveExpectedRequests = false

    init(expected: GuaziPlaybackRequest) {
        self.expected = expected
    }

    func resolve(_ request: GuaziPlaybackRequest) throws -> String {
        guard request == expected else {
            throw VerificationError.unexpectedRequest
        }
        requestCount += 1
        didReceiveExpectedRequests = requestCount == 2
        return "https://cdn.example/video-\(requestCount).m3u8"
    }
}

private enum VerificationError: Error {
    case unexpectedRequest
}

private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
