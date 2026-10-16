import Foundation
import Testing
@testable import BlankCanvas

@Suite("Live Hermes gateway", .serialized)
@MainActor
struct LiveHermesGatewayTests {
    @Test("Ephemeral WebSocket transport reaches readiness and lists sessions")
    func liveSessionList() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpointValue = environment["BLANK_CANVAS_HERMES_LIVE_URL"],
              let endpointURL = URL(string: endpointValue),
              let tokenFile = environment["BLANK_CANVAS_HERMES_LIVE_TOKEN_FILE"] else {
            return
        }
        let token = try String(contentsOfFile: tokenFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!token.isEmpty)

        let transport = HermesWebSocketTransport()
        let endpoint = try HermesGatewayEndpoint(url: endpointURL, profile: nil)
        try await transport.connect(to: endpoint, credential: .token(HermesSecret(token)))
        let result = try await transport.request(.sessionList, params: ["limit": .integer(20)])
        let sessions = try HermesSessionSummary.decodeList(from: result)
        #expect(sessions.isEmpty)
        transport.disconnect()
    }
}
