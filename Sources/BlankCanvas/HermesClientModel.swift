import Combine
import Foundation

@MainActor
protocol HermesGatewayTransporting: AnyObject {
    var eventHandler: ((HermesGatewayEvent) -> Void)? { get set }
    var disconnectionHandler: ((Error?) -> Void)? { get set }

    func connect(to endpoint: HermesGatewayEndpoint, credential: HermesGatewayCredential) async throws
    func disconnect()
    func request(_ method: HermesRPCMethod, params: [String: JSONValue]) async throws -> JSONValue
}

enum HermesConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
}

@MainActor
final class HermesClientModel: ObservableObject {
    @Published private(set) var connectionState: HermesConnectionState = .disconnected
    @Published private(set) var sessions: [HermesSessionSummary] = []
    @Published private(set) var selectedSession: HermesSessionSummary?
    @Published private(set) var runtimeSessionID: String?
    @Published private(set) var transcript = HermesTranscript()
    @Published private(set) var pendingClarification: HermesClarificationRequest?
    @Published private(set) var pendingApproval: HermesApprovalRequest?
    @Published private(set) var pendingSensitiveRequest: HermesSensitiveRequest?
    @Published private(set) var status = "Hermes is not connected"
    @Published private(set) var errorMessage: String?
    @Published private(set) var isBusy = false

    private let transport: HermesGatewayTransporting
    private var endpoint: HermesGatewayEndpoint?

    init(transport: HermesGatewayTransporting) {
        self.transport = transport
        transport.eventHandler = { [weak self] event in
            self?.receive(event)
        }
        transport.disconnectionHandler = { [weak self] error in
            guard let self else { return }
            self.connectionState = .disconnected
            self.status = "Hermes disconnected"
            if let error {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func connect(to endpoint: HermesGatewayEndpoint, credential: HermesGatewayCredential) async {
        guard connectionState != .connecting else { return }
        connectionState = .connecting
        isBusy = true
        errorMessage = nil
        status = "Connecting to Hermes…"
        self.endpoint = endpoint
        do {
            try await transport.connect(to: endpoint, credential: credential)
            connectionState = .connected
            status = "Connected to Hermes"
            await refreshSessions()
        } catch {
            connectionState = .disconnected
            status = "Hermes unavailable"
            errorMessage = error.localizedDescription
        }
        isBusy = false
    }

    func disconnect() {
        transport.disconnect()
        connectionState = .disconnected
        sessions = []
        selectedSession = nil
        runtimeSessionID = nil
        transcript = HermesTranscript()
        pendingClarification = nil
        pendingApproval = nil
        pendingSensitiveRequest = nil
        status = "Hermes is not connected"
        errorMessage = nil
    }

    func clearSelection() {
        selectedSession = nil
        runtimeSessionID = nil
        transcript = HermesTranscript()
        pendingClarification = nil
        pendingApproval = nil
        pendingSensitiveRequest = nil
        status = sessions.isEmpty ? "Connected · no Hermes sessions" : "Connected · \(sessions.count) session(s)"
        errorMessage = nil
    }

    func refreshSessions() async {
        guard connectionState == .connected || endpoint == nil else { return }
        var params: [String: JSONValue] = ["limit": .integer(200)]
        if let profile = endpoint?.profile {
            params["profile"] = .string(profile)
        }
        do {
            let result = try await transport.request(.sessionList, params: params)
            sessions = try HermesSessionSummary.decodeList(from: result)
            status = sessions.isEmpty ? "Connected · no Hermes sessions" : "Connected · \(sessions.count) session(s)"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func select(_ session: HermesSessionSummary) async {
        isBusy = true
        errorMessage = nil
        do {
            let result = try await transport.request(.sessionResume, params: [
                "session_id": .string(session.id),
                "cols": .integer(100),
            ])
            let resume = try HermesSessionResume.decode(from: result)
            selectedSession = session
            runtimeSessionID = resume.runtimeSessionID
            transcript = HermesTranscript(messages: resume.messages)
            pendingClarification = nil
            pendingApproval = nil
            pendingSensitiveRequest = nil
            status = session.title.isEmpty ? "Hermes session ready" : session.title
        } catch {
            errorMessage = error.localizedDescription
        }
        isBusy = false
    }

    func submit(_ rawText: String) async {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let runtimeSessionID else { return }
        transcript.messages.append(HermesMessage(role: .user, text: text))
        errorMessage = nil
        do {
            _ = try await transport.request(.promptSubmit, params: [
                "session_id": .string(runtimeSessionID),
                "text": .string(text),
                "surface": .string("hud"),
            ])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func interrupt() async {
        guard let runtimeSessionID else { return }
        do {
            _ = try await transport.request(.sessionInterrupt, params: [
                "session_id": .string(runtimeSessionID),
            ])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func respondToClarification(_ answer: String) async {
        guard let request = pendingClarification else { return }
        do {
            _ = try await transport.request(.clarifyRespond, params: [
                "session_id": .string(request.sessionID),
                "request_id": .string(request.id),
                "answer": .string(answer),
            ])
            pendingClarification = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func respondToSensitiveRequest(_ value: String, cancelling: Bool) async {
        guard let request = pendingSensitiveRequest else { return }
        let method: HermesRPCMethod
        let valueKey: String
        switch request.kind {
        case .sudo:
            method = .sudoRespond
            valueKey = "password"
        case .secret:
            method = .secretRespond
            valueKey = "value"
        }
        do {
            _ = try await transport.request(method, params: [
                "request_id": .string(request.id),
                valueKey: .string(cancelling ? "" : value),
            ])
            pendingSensitiveRequest = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func respondToApproval(_ choice: HermesApprovalChoice, all: Bool = false) async {
        guard let request = pendingApproval,
              request.choices.contains(choice) else { return }
        do {
            _ = try await transport.request(.approvalRespond, params: [
                "session_id": .string(request.sessionID),
                "request_id": .string(request.id),
                "choice": .string(choice.rawValue),
                "all": .bool(all),
            ])
            pendingApproval = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func receive(_ event: HermesGatewayEvent) {
        if let runtimeSessionID {
            var updatedTranscript = transcript
            if updatedTranscript.apply(event, activeSessionID: runtimeSessionID) {
                transcript = updatedTranscript
                return
            }
        }
        guard event.sessionID == runtimeSessionID else { return }
        do {
            switch event.type {
            case .clarifyRequest:
                pendingClarification = try HermesClarificationRequest.decode(from: event)
            case .approvalRequest:
                pendingApproval = try HermesApprovalRequest.decode(from: event)
            case .sudoRequest, .secretRequest:
                pendingSensitiveRequest = try HermesSensitiveRequest.decode(from: event)
            case .statusUpdate:
                if let text = event.payload?["text"]?.stringValue {
                    status = text
                }
            case .error:
                errorMessage = event.payload?["message"]?.stringValue ?? "Hermes reported an error"
            default:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
