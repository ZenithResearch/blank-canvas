import Foundation
import Testing
@testable import BlankCanvas

@MainActor
private final class FakeHermesTransport: HermesGatewayTransporting {
    struct Call: Equatable {
        let method: HermesRPCMethod
        let params: [String: JSONValue]
    }

    var eventHandler: ((HermesGatewayEvent) -> Void)?
    var disconnectionHandler: ((Error?) -> Void)?
    private(set) var connectedEndpoint: HermesGatewayEndpoint?
    private(set) var disconnected = false
    private(set) var calls: [Call] = []
    var responses: [HermesRPCMethod: [JSONValue]] = [:]

    func connect(to endpoint: HermesGatewayEndpoint, credential: HermesGatewayCredential) async throws {
        connectedEndpoint = endpoint
    }

    func disconnect() {
        disconnected = true
    }

    func request(_ method: HermesRPCMethod, params: [String: JSONValue]) async throws -> JSONValue {
        calls.append(Call(method: method, params: params))
        guard var methodResponses = responses[method], !methodResponses.isEmpty else {
            throw HermesProtocolError.invalidResult("No fake response for \(method.rawValue)")
        }
        let response = methodResponses.removeFirst()
        responses[method] = methodResponses
        return response
    }

    func emit(_ event: HermesGatewayEvent) {
        eventHandler?(event)
    }
}

@Suite("Hermes native client model")
@MainActor
struct HermesClientModelTests {
    @Test("Connecting lists only the selected profile's sessions")
    func connectAndList() async throws {
        let transport = FakeHermesTransport()
        transport.responses[.sessionList] = [.object([
            "sessions": .array([
                .object([
                    "id": .string("stored-1"),
                    "title": .string("Trust boundary"),
                    "preview": .string("Inspect the host"),
                    "started_at": .integer(1_797_000_000),
                    "message_count": .integer(4),
                    "source": .string("cli"),
                ]),
            ]),
        ])]
        let model = HermesClientModel(transport: transport)
        let endpoint = try HermesGatewayEndpoint(url: URL(string: "ws://127.0.0.1:8642/api/ws")!, profile: "sophia")

        await model.connect(to: endpoint, credential: .token(HermesSecret("token")))

        #expect(model.connectionState == .connected)
        #expect(model.sessions.map(\.id) == ["stored-1"])
        #expect(transport.connectedEndpoint == endpoint)
        #expect(transport.calls == [FakeHermesTransport.Call(
            method: .sessionList,
            params: ["limit": .integer(200), "profile": .string("sophia")]
        )])
    }

    @Test("Selecting a persisted session resumes it into a runtime-scoped transcript")
    func selectSession() async throws {
        let transport = FakeHermesTransport()
        transport.responses[.sessionResume] = [.object([
            "session_id": .string("runtime-1"),
            "stored_session_id": .string("stored-1"),
            "messages": .array([
                .object(["role": .string("user"), "text": .string("Hello")]),
                .object(["role": .string("assistant"), "text": .string("Hello from Hermes")]),
            ]),
        ])]
        let model = HermesClientModel(transport: transport)
        let summary = HermesSessionSummary(
            id: "stored-1",
            title: "Greeting",
            preview: "Hello",
            startedAt: Date(timeIntervalSince1970: 1),
            messageCount: 2,
            source: "cli"
        )

        await model.select(summary)

        #expect(model.selectedSession == summary)
        #expect(model.runtimeSessionID == "runtime-1")
        #expect(model.transcript.messages.map(\.text) == ["Hello", "Hello from Hermes"])
        #expect(transport.calls.last == FakeHermesTransport.Call(
            method: .sessionResume,
            params: ["session_id": .string("stored-1"), "cols": .integer(100)]
        ))
    }

    @Test("HUD prompts and interruption remain scoped to the active runtime session")
    func submitAndInterrupt() async throws {
        let transport = FakeHermesTransport()
        transport.responses[.sessionResume] = [.object([
            "session_id": .string("runtime-1"),
            "stored_session_id": .string("stored-1"),
            "messages": .array([]),
        ])]
        transport.responses[.promptSubmit] = [.object(["status": .string("streaming")])]
        transport.responses[.sessionInterrupt] = [.object(["status": .string("interrupted")])]
        let model = HermesClientModel(transport: transport)
        let summary = HermesSessionSummary(
            id: "stored-1", title: "", preview: "", startedAt: .distantPast, messageCount: 0, source: "cli"
        )
        await model.select(summary)

        await model.submit("Inspect this safely")
        await model.interrupt()

        #expect(model.transcript.messages.last?.role == .user)
        #expect(model.transcript.messages.last?.text == "Inspect this safely")
        #expect(transport.calls.suffix(2) == [
            FakeHermesTransport.Call(
                method: .promptSubmit,
                params: [
                    "session_id": .string("runtime-1"),
                    "text": .string("Inspect this safely"),
                    "surface": .string("hud"),
                ]
            ),
            FakeHermesTransport.Call(
                method: .sessionInterrupt,
                params: ["session_id": .string("runtime-1")]
            ),
        ])
    }

    @Test("Sudo and secret prompts remain transient and support explicit cancellation")
    func respondToSensitivePrompts() async throws {
        let transport = FakeHermesTransport()
        transport.responses[.sessionResume] = [.object([
            "session_id": .string("runtime-1"),
            "stored_session_id": .string("stored-1"),
            "messages": .array([]),
        ])]
        transport.responses[.sudoRespond] = [.object(["resolved": .bool(true)])]
        transport.responses[.secretRespond] = [.object(["resolved": .bool(true)])]
        let model = HermesClientModel(transport: transport)
        await model.select(HermesSessionSummary(
            id: "stored-1", title: "", preview: "", startedAt: .distantPast, messageCount: 0, source: "cli"
        ))

        transport.emit(HermesGatewayEvent(
            type: .sudoRequest,
            sessionID: "runtime-1",
            profile: nil,
            payload: .object(["request_id": .string("sudo-1")])
        ))
        #expect(model.pendingSensitiveRequest?.kind == .sudo)
        await model.respondToSensitiveRequest("", cancelling: true)

        transport.emit(HermesGatewayEvent(
            type: .secretRequest,
            sessionID: "runtime-1",
            profile: nil,
            payload: .object([
                "request_id": .string("secret-1"),
                "prompt": .string("Enter the service credential"),
                "env_var": .string("SERVICE_TOKEN"),
            ])
        ))
        #expect(model.pendingSensitiveRequest?.kind == .secret)
        #expect(model.pendingSensitiveRequest?.prompt == "Enter the service credential")
        await model.respondToSensitiveRequest("transient-value", cancelling: false)

        #expect(model.pendingSensitiveRequest == nil)
        #expect(transport.calls.suffix(2) == [
            FakeHermesTransport.Call(
                method: .sudoRespond,
                params: ["request_id": .string("sudo-1"), "password": .string("")]
            ),
            FakeHermesTransport.Call(
                method: .secretRespond,
                params: ["request_id": .string("secret-1"), "value": .string("transient-value")]
            ),
        ])
    }

    @Test("Clarifications and tool approvals require explicit native responses")
    func respondToNativePrompts() async throws {
        let transport = FakeHermesTransport()
        transport.responses[.sessionResume] = [.object([
            "session_id": .string("runtime-1"),
            "stored_session_id": .string("stored-1"),
            "messages": .array([]),
        ])]
        transport.responses[.clarifyRespond] = [.object(["resolved": .bool(true)])]
        transport.responses[.approvalRespond] = [.object(["resolved": .bool(true)])]
        let model = HermesClientModel(transport: transport)
        await model.select(HermesSessionSummary(
            id: "stored-1", title: "", preview: "", startedAt: .distantPast, messageCount: 0, source: "cli"
        ))
        transport.emit(HermesGatewayEvent(
            type: .clarifyRequest,
            sessionID: "runtime-1",
            profile: nil,
            payload: .object([
                "request_id": .string("clarify-1"),
                "question": .string("Proceed?"),
                "choices": .array([.string("yes"), .string("no")]),
            ])
        ))
        transport.emit(HermesGatewayEvent(
            type: .approvalRequest,
            sessionID: "runtime-1",
            profile: nil,
            payload: .object([
                "request_id": .string("approval-1"),
                "command": .string("swift test"),
                "choices": .array([.string("once"), .string("deny")]),
            ])
        ))

        #expect(model.pendingClarification?.id == "clarify-1")
        #expect(model.pendingApproval?.id == "approval-1")
        await model.respondToClarification("yes")
        await model.respondToApproval(.once)

        #expect(model.pendingClarification == nil)
        #expect(model.pendingApproval == nil)
        #expect(transport.calls.suffix(2) == [
            FakeHermesTransport.Call(
                method: .clarifyRespond,
                params: [
                    "session_id": .string("runtime-1"),
                    "request_id": .string("clarify-1"),
                    "answer": .string("yes"),
                ]
            ),
            FakeHermesTransport.Call(
                method: .approvalRespond,
                params: [
                    "session_id": .string("runtime-1"),
                    "request_id": .string("approval-1"),
                    "choice": .string("once"),
                    "all": .bool(false),
                ]
            ),
        ])
    }
}
