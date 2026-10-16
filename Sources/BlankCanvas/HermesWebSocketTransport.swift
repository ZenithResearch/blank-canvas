import Foundation

enum HermesTransportError: Error, Equatable, LocalizedError {
    case notConnected
    case readinessTimeout
    case invalidReadiness
    case requestTimeout(HermesRPCMethod)
    case rpc(HermesRPCError)
    case connectionClosed

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Hermes is not connected"
        case .readinessTimeout:
            return "Hermes did not become ready within 15 seconds"
        case .invalidReadiness:
            return "Hermes did not provide the expected gateway readiness event"
        case let .requestTimeout(method):
            return "Hermes request timed out: \(method.rawValue)"
        case let .rpc(error):
            return "Hermes request failed (\(error.code)): \(error.message)"
        case .connectionClosed:
            return "Hermes connection closed"
        }
    }
}

@MainActor
final class HermesWebSocketTransport: HermesGatewayTransporting {
    var eventHandler: ((HermesGatewayEvent) -> Void)?
    var disconnectionHandler: ((Error?) -> Void)?

    private struct PendingRequest {
        let method: HermesRPCMethod
        let continuation: CheckedContinuation<JSONValue, Error>
        let timeoutTask: Task<Void, Never>
    }

    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pending: [String: PendingRequest] = [:]
    private var nextRequestID = 0
    private var explicitlyDisconnecting = false

    func connect(to endpoint: HermesGatewayEndpoint, credential: HermesGatewayCredential) async throws {
        disconnect()
        explicitlyDisconnecting = false
        let authenticatedURL = try endpoint.authenticatedURL(using: credential)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration)
        let socket = session.webSocketTask(with: authenticatedURL)
        self.session = session
        self.socket = socket
        socket.resume()

        let timeout = Task { [weak socket] in
            do {
                try await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                socket?.cancel(with: .goingAway, reason: nil)
            } catch {
                return
            }
        }
        do {
            let firstMessage = try await socket.receive()
            timeout.cancel()
            let frame = try HermesRPCFrame.decode(Self.data(from: firstMessage))
            guard case let .event(event) = frame, event.type == .gatewayReady else {
                throw HermesTransportError.invalidReadiness
            }
            eventHandler?(event)
            startReceiving(from: socket)
        } catch {
            timeout.cancel()
            closeResources()
            if error is HermesProtocolError || error is HermesTransportError {
                throw error
            }
            throw HermesTransportError.readinessTimeout
        }
    }

    func disconnect() {
        explicitlyDisconnecting = true
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        rejectAllPending(with: HermesTransportError.connectionClosed)
        closeResources()
        explicitlyDisconnecting = false
    }

    func request(_ method: HermesRPCMethod, params: [String: JSONValue]) async throws -> JSONValue {
        guard let socket else { throw HermesTransportError.notConnected }
        nextRequestID += 1
        let id = "blank-canvas-\(nextRequestID)"
        let request = HermesRPCRequest(id: id, method: method, params: params)
        let data = try JSONEncoder().encode(request)
        guard let text = String(data: data, encoding: .utf8) else {
            throw HermesProtocolError.invalidFrame("Hermes request could not be encoded as UTF-8")
        }

        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(120))
                    guard !Task.isCancelled else { return }
                    self?.expireRequest(id)
                } catch {
                    return
                }
            }
            pending[id] = PendingRequest(
                method: method,
                continuation: continuation,
                timeoutTask: timeoutTask
            )
            Task { [weak self, weak socket] in
                do {
                    try await socket?.send(.string(text))
                } catch {
                    self?.failRequest(id, with: HermesTransportError.connectionClosed)
                }
            }
        }
    }

    private func startReceiving(from socket: URLSessionWebSocketTask) {
        receiveTask?.cancel()
        receiveTask = Task { [weak self, weak socket] in
            guard let socket else { return }
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    self?.handle(message)
                }
            } catch {
                guard let self, !self.explicitlyDisconnecting else { return }
                self.rejectAllPending(with: HermesTransportError.connectionClosed)
                self.closeResources()
                self.disconnectionHandler?(HermesTransportError.connectionClosed)
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        do {
            switch try HermesRPCFrame.decode(Self.data(from: message)) {
            case let .event(event):
                eventHandler?(event)
            case let .response(response):
                guard let pendingRequest = pending.removeValue(forKey: response.id) else { return }
                pendingRequest.timeoutTask.cancel()
                if let error = response.error {
                    pendingRequest.continuation.resume(throwing: HermesTransportError.rpc(error))
                } else if let result = response.result {
                    pendingRequest.continuation.resume(returning: result)
                } else {
                    pendingRequest.continuation.resume(
                        throwing: HermesProtocolError.invalidFrame("Hermes response is empty")
                    )
                }
            }
        } catch {
            disconnectionHandler?(HermesProtocolError.invalidFrame("Hermes sent an unreadable frame"))
        }
    }

    private func expireRequest(_ id: String) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeoutTask.cancel()
        request.continuation.resume(throwing: HermesTransportError.requestTimeout(request.method))
    }

    private func failRequest(_ id: String, with error: Error) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeoutTask.cancel()
        request.continuation.resume(throwing: error)
    }

    private func rejectAllPending(with error: Error) {
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private func closeResources() {
        receiveTask?.cancel()
        receiveTask = nil
        socket = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private static func data(from message: URLSessionWebSocketTask.Message) throws -> Data {
        switch message {
        case let .data(data):
            return data
        case let .string(string):
            return Data(string.utf8)
        @unknown default:
            throw HermesProtocolError.invalidFrame("Hermes sent an unsupported WebSocket frame")
        }
    }
}
