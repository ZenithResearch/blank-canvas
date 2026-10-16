import Foundation
import Testing
@testable import BlankCanvas

@Suite("Hermes protocol contracts")
struct HermesProtocolContractTests {
    @Test("RPC requests are typed JSON-RPC 2.0 envelopes without credentials")
    func requestEnvelope() throws {
        let request = HermesRPCRequest(
            id: "blank-canvas-1",
            method: .sessionList,
            params: [
                "limit": .integer(25),
                "profile": .string("sophia"),
            ]
        )

        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let params = try #require(object["params"] as? [String: Any])

        #expect(object["jsonrpc"] as? String == "2.0")
        #expect(object["id"] as? String == "blank-canvas-1")
        #expect(object["method"] as? String == "session.list")
        #expect(params["limit"] as? Int == 25)
        #expect(params["profile"] as? String == "sophia")
        #expect(object["token"] == nil)
        #expect(params["token"] == nil)
    }

    @Test("Gateway endpoints reject embedded credentials and non-WebSocket schemes")
    func endpointValidation() throws {
        let endpoint = try HermesGatewayEndpoint(
            url: #require(URL(string: "ws://127.0.0.1:8642/api/ws")),
            profile: "sophia"
        )
        let authenticated = try endpoint.authenticatedURL(
            using: .token(HermesSecret("sensitive-local-token"))
        )
        let components = try #require(URLComponents(url: authenticated, resolvingAgainstBaseURL: false))

        #expect(endpoint.description == "ws://127.0.0.1:8642/api/ws [profile: sophia]")
        #expect(components.queryItems == [URLQueryItem(name: "token", value: "sensitive-local-token")])
        #expect(String(describing: HermesSecret("sensitive-local-token")) == "<redacted>")

        #expect(throws: HermesProtocolError.self) {
            try HermesGatewayEndpoint(url: URL(string: "https://127.0.0.1:8642/api/ws")!, profile: nil)
        }
        #expect(throws: HermesProtocolError.self) {
            try HermesGatewayEndpoint(url: URL(string: "ws://127.0.0.1:8642/api/ws?token=leaked")!, profile: nil)
        }
        #expect(throws: HermesProtocolError.self) {
            try HermesGatewayEndpoint(url: URL(string: "ws://user:pass@127.0.0.1:8642/api/ws")!, profile: nil)
        }
    }

    @Test("Remote gateway endpoints require TLS while loopback may use WebSocket")
    func remoteEndpointsRequireTLS() throws {
        #expect(throws: HermesProtocolError.self) {
            try HermesGatewayEndpoint(url: URL(string: "ws://gateway.example/api/ws")!, profile: nil)
        }
        let secureRemote = try HermesGatewayEndpoint(
            url: URL(string: "wss://gateway.example/api/ws")!,
            profile: nil
        )
        #expect(secureRemote.description == "wss://gateway.example/api/ws")
        let local = try HermesGatewayEndpoint(
            url: URL(string: "ws://localhost:8642/api/ws")!,
            profile: nil
        )
        #expect(local.description == "ws://localhost:8642/api/ws")
    }

    @Test("Gateway event frames preserve type, session scope, and structured payload")
    func eventFrame() throws {
        let data = Data(#"""
        {
          "jsonrpc": "2.0",
          "method": "event",
          "params": {
            "type": "message.delta",
            "session_id": "session-123",
            "payload": {"text": "hello", "sequence": 3}
          }
        }
        """#.utf8)

        let frame = try HermesRPCFrame.decode(data)
        guard case let .event(event) = frame else {
            Issue.record("Expected an event frame")
            return
        }

        #expect(event.type == .messageDelta)
        #expect(event.sessionID == "session-123")
        #expect(event.payload?["text"] == .string("hello"))
        #expect(event.payload?["sequence"] == .integer(3))
    }

    @Test("RPC response frames distinguish success from structured failure")
    func responseFrames() throws {
        let success = try HermesRPCFrame.decode(Data(#"""
        {"jsonrpc":"2.0","id":"r1","result":{"count":2}}
        """#.utf8))
        let failure = try HermesRPCFrame.decode(Data(#"""
        {"jsonrpc":"2.0","id":"r2","error":{"code":4007,"message":"session not found"}}
        """#.utf8))

        #expect(success == .response(HermesRPCResponse(
            id: "r1",
            result: .object(["count": .integer(2)]),
            error: nil
        )))
        #expect(failure == .response(HermesRPCResponse(
            id: "r2",
            result: nil,
            error: HermesRPCError(code: 4007, message: "session not found")
        )))
    }

    @Test("RPC responses require exactly one result or error")
    func responseResultErrorExclusivity() {
        let ambiguous = Data(#"""
        {"jsonrpc":"2.0","id":"r3","result":{"count":2},"error":{"code":4007,"message":"session not found"}}
        """#.utf8)

        #expect(throws: HermesProtocolError.self) {
            try HermesRPCFrame.decode(ambiguous)
        }
    }

    @Test("Oversized Hermes frames are rejected before decoding")
    func oversizedFrame() {
        let oversized = Data(repeating: 0x20, count: 1_048_577)

        #expect(throws: HermesProtocolError.invalidFrame("Hermes frame exceeds 1048576 bytes")) {
            try HermesRPCFrame.decode(oversized)
        }
    }

    @Test("Session list results decode without accepting arbitrary history payloads")
    func sessionList() throws {
        let result: JSONValue = .object([
            "sessions": .array([
                .object([
                    "id": .string("stored-session-1"),
                    "title": .string("Architecture review"),
                    "preview": .string("Inspect the trust boundary"),
                    "started_at": .number(1_797_000_000.5),
                    "message_count": .integer(12),
                    "source": .string("cli"),
                ]),
            ]),
        ])

        let sessions = try HermesSessionSummary.decodeList(from: result)

        #expect(sessions == [HermesSessionSummary(
            id: "stored-session-1",
            title: "Architecture review",
            preview: "Inspect the trust boundary",
            startedAt: Date(timeIntervalSince1970: 1_797_000_000.5),
            messageCount: 12,
            source: "cli"
        )])
        #expect(throws: HermesProtocolError.self) {
            try HermesSessionSummary.decodeList(from: .object(["messages": .array([])]))
        }
    }

    @Test("Session resume results decode the runtime id and display projection")
    func sessionResume() throws {
        let result: JSONValue = .object([
            "session_id": .string("runtime-42"),
            "stored_session_id": .string("stored-42"),
            "messages": .array([
                .object(["role": .string("user"), "text": .string("Inspect the boundary"), "row_id": .integer(10)]),
                .object(["role": .string("assistant"), "text": .string("The boundary is native."), "row_id": .integer(11)]),
                .object(["role": .string("tool"), "name": .string("read_file"), "context": .string("HUDView.swift")]),
            ]),
        ])

        let resume = try HermesSessionResume.decode(from: result)

        #expect(resume.runtimeSessionID == "runtime-42")
        #expect(resume.storedSessionID == "stored-42")
        #expect(resume.messages.map(\.role) == [.user, .assistant, .tool])
        #expect(resume.messages[0].rowID == 10)
        #expect(resume.messages[2].toolName == "read_file")
        #expect(resume.messages[2].text == "HUDView.swift")
    }

    @Test("Transcript streaming is scoped to the selected runtime session")
    func transcriptStreaming() throws {
        var transcript = HermesTranscript(messages: [
            HermesMessage(role: .user, text: "Hello", rowID: 1),
        ])
        let ignored = HermesGatewayEvent(
            type: .messageDelta,
            sessionID: "another-session",
            profile: nil,
            payload: .object(["text": .string("leak")])
        )
        let start = HermesGatewayEvent(type: .messageStart, sessionID: "runtime-42", profile: nil, payload: nil)
        let delta = HermesGatewayEvent(
            type: .messageDelta,
            sessionID: "runtime-42",
            profile: nil,
            payload: .object(["text": .string("Native ")])
        )
        let complete = HermesGatewayEvent(
            type: .messageComplete,
            sessionID: "runtime-42",
            profile: nil,
            payload: .object(["text": .string("Native boundary."), "status": .string("complete")])
        )

        let ignoredApplied = transcript.apply(ignored, activeSessionID: "runtime-42")
        #expect(!ignoredApplied)
        #expect(transcript.streamingText == nil)
        let startApplied = transcript.apply(start, activeSessionID: "runtime-42")
        #expect(startApplied)
        let deltaApplied = transcript.apply(delta, activeSessionID: "runtime-42")
        #expect(deltaApplied)
        #expect(transcript.streamingText == "Native ")
        let completeApplied = transcript.apply(complete, activeSessionID: "runtime-42")
        #expect(completeApplied)
        #expect(transcript.streamingText == nil)
        #expect(transcript.messages.last?.role == .assistant)
        #expect(transcript.messages.last?.text == "Native boundary.")
    }

    @Test("Clarification and approval events require request ids and stay typed")
    func nativePrompts() throws {
        let clarification = try HermesClarificationRequest.decode(from: HermesGatewayEvent(
            type: .clarifyRequest,
            sessionID: "runtime-42",
            profile: nil,
            payload: .object([
                "request_id": .string("clarify-1"),
                "question": .string("Which environment?"),
                "choices": .array([.string("development"), .string("staging")]),
                "multi_select": .bool(false),
            ])
        ))
        let approval = try HermesApprovalRequest.decode(from: HermesGatewayEvent(
            type: .approvalRequest,
            sessionID: "runtime-42",
            profile: nil,
            payload: .object([
                "request_id": .string("approval-1"),
                "command": .string("swift test"),
                "description": .string("Run the host test suite"),
                "choices": .array([.string("once"), .string("deny")]),
            ])
        ))

        #expect(clarification.question == "Which environment?")
        #expect(clarification.choices == ["development", "staging"])
        #expect(!clarification.allowsMultiple)
        #expect(approval.command == "swift test")
        #expect(approval.choices == [.once, .deny])
        #expect(throws: HermesProtocolError.self) {
            try HermesApprovalRequest.decode(from: HermesGatewayEvent(
                type: .approvalRequest,
                sessionID: "runtime-42",
                profile: nil,
                payload: .object(["command": .string("missing request id")])
            ))
        }
    }

    @Test("Only recognized prompt-response methods can be constructed")
    func methodAllowlist() {
        #expect(HermesRPCMethod.sessionCreate.rawValue == "session.create")
        #expect(HermesRPCMethod.sessionResume.rawValue == "session.resume")
        #expect(HermesRPCMethod.sessionHistory.rawValue == "session.history")
        #expect(HermesRPCMethod.promptSubmit.rawValue == "prompt.submit")
        #expect(HermesRPCMethod.sessionInterrupt.rawValue == "session.interrupt")
        #expect(HermesRPCMethod.clarifyRespond.rawValue == "clarify.respond")
        #expect(HermesRPCMethod.approvalRespond.rawValue == "approval.respond")
    }
}
