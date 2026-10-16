import Foundation
import Testing
@testable import BlankCanvas

@Suite("Castalia wallet helper protocol")
struct WalletProtocolContractTests {
    @Test("Only typed wallet operations can be encoded")
    func typedOperations() throws {
        #expect(Set(WalletRPCMethod.allCases) == Set([
            .initialize, .status, .create, .unlock, .lock, .publicIdentity,
            .recover, .exportRecoveryKit, .prepareAction, .authorizePreparedAction,
            .cancelPreparedAction,
        ]))
        let request = WalletRPCRequest(
            id: "wallet-1",
            channelNonce: "launch-nonce",
            method: .status,
            params: [:]
        )
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(object["version"] as? Int == 1)
        #expect(object["channel_nonce"] as? String == "launch-nonce")
        #expect(object["method"] as? String == "wallet.status")
        #expect(object["private_key"] == nil)
        #expect(object["bytes"] == nil)
    }

    @Test("Frames are four-byte big-endian length-prefixed JSON")
    func framingRoundTrip() throws {
        let payload = Data("{\"version\":1}".utf8)
        let frame = try WalletFrameCodec.encode(payload)
        #expect(Array(frame.prefix(4)) == [0, 0, 0, 13])
        var buffer = frame
        #expect(try WalletFrameCodec.decodeNext(from: &buffer) == payload)
        #expect(buffer.isEmpty)
    }

    @Test("Partial and oversized frames fail closed")
    func framingLimits() throws {
        var partial = Data([0, 0, 0, 10, 1, 2])
        #expect(try WalletFrameCodec.decodeNext(from: &partial) == nil)
        #expect(partial == Data([0, 0, 0, 10, 1, 2]))

        var oversized = Data([0x00, 0x10, 0x00, 0x01])
        #expect(throws: WalletProtocolError.self) {
            try WalletFrameCodec.decodeNext(from: &oversized)
        }
        #expect(throws: WalletProtocolError.self) {
            try WalletFrameCodec.encode(Data(repeating: 0, count: WalletFrameCodec.maximumPayloadBytes + 1))
        }
    }

    @Test("Wallet status and identity contain public information only")
    func publicStatus() throws {
        let response: JSONValue = .object([
            "state": .string("locked"),
            "identity": .object([
                "key_id": .string("abc123"),
                "ed25519_public_key": .string("public-ed"),
                "ml_dsa_65_public_key_digest": .string("public-pq-digest"),
                "algorithm": .string("Ed25519+ML-DSA-65"),
                "version": .integer(1),
            ]),
            "backup_verified": .bool(true),
        ])

        let status = try WalletStatus.decode(from: response)

        #expect(status.state == .locked)
        #expect(status.identity?.keyID == "abc123")
        #expect(status.identity?.algorithm == "Ed25519+ML-DSA-65")
        #expect(status.backupVerified)
    }

    @Test("Prepared actions require exact digest, one-time approval, and expiry")
    func preparedAction() throws {
        let value: JSONValue = .object([
            "approval_id": .string("approval-1"),
            "prepared_action_digest": .string("digest-1"),
            "intent_type": .string("create_state_genesis"),
            "network": .string("dregg-devnet"),
            "protocol_epoch": .integer(7),
            "expires_at": .number(1_797_000_100.5),
            "display": .object([
                "title": .string("Create State"),
                "target": .string("garden"),
            ]),
        ])

        let action = try WalletPreparedAction.decode(from: value)

        #expect(action.approvalID == "approval-1")
        #expect(action.digest == "digest-1")
        #expect(action.intentType == .createStateGenesis)
        #expect(action.network == "dregg-devnet")
        #expect(action.protocolEpoch == 7)
        #expect(action.display["title"]?.stringValue == "Create State")
    }
}
