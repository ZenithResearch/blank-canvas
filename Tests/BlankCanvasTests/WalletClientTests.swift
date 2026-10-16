import Foundation
import Testing
@testable import BlankCanvas

private actor FakeWalletHelperTransport: WalletHelperTransporting {
    private(set) var requests: [Data] = []
    var responses: [Data]

    init(responses: [Data]) {
        self.responses = responses
    }

    func exchange(_ request: Data) async throws -> Data {
        requests.append(request)
        guard !responses.isEmpty else {
            throw WalletProtocolError.invalidResult("No fake wallet response")
        }
        return responses.removeFirst()
    }

    func recordedRequests() -> [Data] {
        requests
    }
}

@Suite("Castalia wallet helper client")
struct WalletClientTests {
    @Test("Status requests are nonce-bound and decode only public wallet state")
    func statusRequest() async throws {
        let response = Data(#"{"version":1,"id":"wallet-1","channel_nonce":"launch-nonce","result":{"state":"locked","identity":{"key_id":"member-1","ed25519_public_key":"public-ed","ml_dsa_65_public_key_digest":"public-pq-digest","algorithm":"Ed25519+ML-DSA-65","version":1},"backup_verified":true}}"#.utf8)
        let transport = FakeWalletHelperTransport(responses: [response])
        let client = WalletClient(
            transport: transport,
            channelNonce: "launch-nonce",
            makeRequestID: { "wallet-1" }
        )

        let status = try await client.status()

        #expect(status.state == .locked)
        #expect(status.identity?.keyID == "member-1")
        #expect(status.backupVerified)

        let requests = await transport.recordedRequests()
        let request = try #require(requests.first)
        let object = try #require(
            JSONSerialization.jsonObject(with: request) as? [String: Any]
        )
        #expect(object["version"] as? Int == 1)
        #expect(object["id"] as? String == "wallet-1")
        #expect(object["channel_nonce"] as? String == "launch-nonce")
        #expect(object["method"] as? String == "wallet.status")
        #expect((object["params"] as? [String: Any])?.isEmpty == true)
    }

    @Test("Structured helper errors are preserved as typed failures")
    func helperError() async throws {
        let response = Data(#"{"version":1,"id":"wallet-1","channel_nonce":"launch-nonce","error":{"code":"wallet_locked","message":"Wallet is locked"}}"#.utf8)
        let transport = FakeWalletHelperTransport(responses: [response])
        let client = WalletClient(
            transport: transport,
            channelNonce: "launch-nonce",
            makeRequestID: { "wallet-1" }
        )

        await #expect(throws: WalletProtocolError.helperError(
            code: "wallet_locked",
            message: "Wallet is locked"
        )) {
            try await client.status()
        }
    }

    @Test("Responses from another helper channel are rejected")
    func rejectsChannelSubstitution() async throws {
        let response = Data(#"{"version":1,"id":"wallet-1","channel_nonce":"other-launch","result":{"state":"locked","identity":null,"backup_verified":false}}"#.utf8)
        let transport = FakeWalletHelperTransport(responses: [response])
        let client = WalletClient(
            transport: transport,
            channelNonce: "launch-nonce",
            makeRequestID: { "wallet-1" }
        )

        await #expect(throws: WalletProtocolError.invalidResult(
            "Wallet response does not match its request"
        )) {
            try await client.status()
        }
    }

    @Test("Responses for another request are rejected")
    func rejectsRequestSubstitution() async throws {
        let response = Data(#"{"version":1,"id":"wallet-2","channel_nonce":"launch-nonce","result":{"state":"locked","identity":null,"backup_verified":false}}"#.utf8)
        let transport = FakeWalletHelperTransport(responses: [response])
        let client = WalletClient(
            transport: transport,
            channelNonce: "launch-nonce",
            makeRequestID: { "wallet-1" }
        )

        await #expect(throws: WalletProtocolError.invalidResult(
            "Wallet response does not match its request"
        )) {
            try await client.status()
        }
    }

    @Test("Oversized helper responses fail before JSON decoding")
    func rejectsOversizedResponse() async throws {
        let response = Data(
            repeating: 0,
            count: WalletFrameCodec.maximumPayloadBytes + 1
        )
        let transport = FakeWalletHelperTransport(responses: [response])
        let client = WalletClient(
            transport: transport,
            channelNonce: "launch-nonce",
            makeRequestID: { "wallet-1" }
        )

        await #expect(throws: WalletProtocolError.invalidFrame(
            "Wallet response exceeds the maximum payload size"
        )) {
            try await client.status()
        }
    }
}
