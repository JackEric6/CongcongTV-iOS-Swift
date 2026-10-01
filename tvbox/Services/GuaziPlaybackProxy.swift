import Foundation
import Network

/// iOS 等价于 Android RemoteServer + GuaziPlayRequestProcess 的回环媒体路由。
actor GuaziPlaybackProxy {
    static let shared = GuaziPlaybackProxy()

    private let queue = DispatchQueue(label: "com.congcong.tv.guazi-playback-proxy")
    private var listener: NWListener?
    private var isReady = false
    private var readyPort: UInt16?
    private var readyWaiters: [CheckedContinuation<UInt16, Error>] = []

    private init() {}

    func startIfNeeded() async throws -> UInt16 {
        if isReady, let readyPort { return readyPort }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            readyWaiters.append(continuation)
            guard listener == nil else { return }

            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(
                    host: NWEndpoint.Host(GuaziPlaybackRequest.localHost),
                    port: .any
                )
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
                isReady = false
                resumeReadyWaiters(with: CocoaError(.fileReadUnknown))
                return
            }
            isReady = true
            readyPort = port
            resumeReadyWaiters(with: nil)
        case .failed(let error):
            listener?.cancel()
            listener = nil
            isReady = false
            readyPort = nil
            resumeReadyWaiters(with: error)
        case .cancelled:
            listener = nil
            isReady = false
            readyPort = nil
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
            } else if let readyPort {
                waiter.resume(returning: readyPort)
            } else {
                waiter.resume(throwing: CocoaError(.fileReadUnknown))
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, accumulated: Data())
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
            [weak self] data, _, isComplete, error in
            Task {
                await self?.handleReceived(
                    data,
                    isComplete: isComplete,
                    error: error,
                    on: connection,
                    accumulated: accumulated
                )
            }
        }
    }

    private func handleReceived(
        _ data: Data?,
        isComplete: Bool,
        error: NWError?,
        on connection: NWConnection,
        accumulated: Data
    ) async {
        if error != nil {
            connection.cancel()
            return
        }

        let requestData = accumulated + (data ?? Data())
        let terminator = Data([13, 10, 13, 10])
        if let range = requestData.range(of: terminator) {
            let headerData = requestData[..<range.lowerBound]
            guard let header = String(data: headerData, encoding: .utf8),
                  let request = GuaziPlaybackRequest.parseHTTPRequestHead(
                    header,
                    port: readyPort ?? GuaziPlaybackRequest.preferredLocalPort
                  ) else {
                send(
                    GuaziPlaybackRequest.errorResponse(
                        status: 404,
                        reason: "Not Found",
                        message: "Not Found"
                    ),
                    on: connection
                )
                return
            }

            do {
                let mediaURL = try await GuaziService.shared.play(request)
                guard let response = GuaziPlaybackRequest.redirectResponse(to: mediaURL) else {
                    throw GuaziServiceError.playableURLMissing
                }
                send(response, on: connection)
            } catch {
                send(
                    GuaziPlaybackRequest.errorResponse(
                        status: 500,
                        reason: "Internal Server Error",
                        message: "瓜子播放地址获取失败: \(error.localizedDescription)"
                    ),
                    on: connection
                )
            }
            return
        }

        guard !isComplete, requestData.count < 65_536 else {
            send(
                GuaziPlaybackRequest.errorResponse(
                    status: 400,
                    reason: "Bad Request",
                    message: "Bad Request"
                ),
                on: connection
            )
            return
        }
        receiveRequest(on: connection, accumulated: requestData)
    }

    private func send(_ data: Data, on connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
