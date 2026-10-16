import Foundation

enum WalletProtocolError: Error, Equatable, LocalizedError {
    case invalidFrame(String)
    case invalidResult(String)
    case helperError(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case let .invalidFrame(message), let .invalidResult(message):
            return message
        case let .helperError(code, message):
            return "Wallet helper error \(code): \(message)"
        }
    }
}

enum WalletRPCMethod: String, Codable, CaseIterable, Sendable {
    case initialize = "wallet.initialize"
    case status = "wallet.status"
    case create = "wallet.create"
    case unlock = "wallet.unlock"
    case lock = "wallet.lock"
    case publicIdentity = "wallet.publicIdentity"
    case recover = "wallet.recover"
    case exportRecoveryKit = "wallet.exportRecoveryKit"
    case prepareAction = "wallet.prepareAction"
    case authorizePreparedAction = "wallet.authorizePreparedAction"
    case cancelPreparedAction = "wallet.cancelPreparedAction"
}

struct WalletRPCRequest: Encodable, Equatable, Sendable {
    let version = 1
    let id: String
    let channelNonce: String
    let method: WalletRPCMethod
    let params: [String: JSONValue]

    init(
        id: String,
        channelNonce: String,
        method: WalletRPCMethod,
        params: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.channelNonce = channelNonce
        self.method = method
        self.params = params
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case id
        case channelNonce = "channel_nonce"
        case method
        case params
    }
}

enum WalletFrameCodec {
    static let maximumPayloadBytes = 1_048_576
    private static let headerBytes = 4

    static func encode(_ payload: Data) throws -> Data {
        guard payload.count <= maximumPayloadBytes else {
            throw WalletProtocolError.invalidFrame("Wallet frame exceeds the maximum payload size")
        }

        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: headerBytes)
        frame.append(payload)
        return frame
    }

    static func decodeNext(from buffer: inout Data) throws -> Data? {
        guard buffer.count >= headerBytes else { return nil }

        let payloadLength = buffer.prefix(headerBytes).reduce(0) { partial, byte in
            (partial << 8) | Int(byte)
        }
        guard payloadLength <= maximumPayloadBytes else {
            throw WalletProtocolError.invalidFrame("Wallet frame exceeds the maximum payload size")
        }

        let frameLength = headerBytes + payloadLength
        guard buffer.count >= frameLength else { return nil }

        let payload = Data(buffer[headerBytes..<frameLength])
        buffer.removeFirst(frameLength)
        return payload
    }
}

enum WalletState: String, Equatable, Sendable {
    case setupRequired = "setup_required"
    case locked
    case unlocked
    case error
}

struct WalletPublicIdentity: Equatable, Sendable {
    let keyID: String
    let ed25519PublicKey: String
    let mlDSA65PublicKeyDigest: String
    let algorithm: String
    let version: Int

    static func decode(from value: JSONValue) throws -> WalletPublicIdentity {
        guard let object = value.objectValue,
              let keyID = object["key_id"]?.stringValue,
              let ed25519PublicKey = object["ed25519_public_key"]?.stringValue,
              let mlDSA65PublicKeyDigest = object["ml_dsa_65_public_key_digest"]?.stringValue,
              let algorithm = object["algorithm"]?.stringValue,
              let version = object["version"]?.integerValue else {
            throw WalletProtocolError.invalidResult("Wallet returned an invalid public identity")
        }
        return WalletPublicIdentity(
            keyID: keyID,
            ed25519PublicKey: ed25519PublicKey,
            mlDSA65PublicKeyDigest: mlDSA65PublicKeyDigest,
            algorithm: algorithm,
            version: version
        )
    }
}

struct WalletStatus: Equatable, Sendable {
    let state: WalletState
    let identity: WalletPublicIdentity?
    let backupVerified: Bool

    static func decode(from value: JSONValue) throws -> WalletStatus {
        guard let object = value.objectValue,
              let rawState = object["state"]?.stringValue,
              let state = WalletState(rawValue: rawState),
              let backupVerified = object["backup_verified"]?.boolValue else {
            throw WalletProtocolError.invalidResult("Wallet returned an invalid status")
        }

        let identity: WalletPublicIdentity?
        switch object["identity"] {
        case nil, .some(.null):
            identity = nil
        case let .some(value):
            identity = try WalletPublicIdentity.decode(from: value)
        }

        return WalletStatus(state: state, identity: identity, backupVerified: backupVerified)
    }
}

enum WalletIntentType: String, Equatable, Sendable {
    case registerMemberKey = "register_member_key"
    case createStateGenesis = "create_state_genesis"
    case dreggAction = "dregg_action"
}

struct WalletPreparedAction: Equatable, Sendable {
    let approvalID: String
    let digest: String
    let intentType: WalletIntentType
    let network: String
    let protocolEpoch: Int
    let expiresAt: Date
    let display: [String: JSONValue]

    static func decode(from value: JSONValue) throws -> WalletPreparedAction {
        guard let object = value.objectValue,
              let approvalID = object["approval_id"]?.stringValue,
              !approvalID.isEmpty,
              let digest = object["prepared_action_digest"]?.stringValue,
              !digest.isEmpty,
              let rawIntentType = object["intent_type"]?.stringValue,
              let intentType = WalletIntentType(rawValue: rawIntentType),
              let network = object["network"]?.stringValue,
              !network.isEmpty,
              let protocolEpoch = object["protocol_epoch"]?.integerValue,
              protocolEpoch >= 0,
              let expiresAt = object["expires_at"]?.doubleValue,
              expiresAt.isFinite,
              let display = object["display"]?.objectValue else {
            throw WalletProtocolError.invalidResult("Wallet returned an invalid prepared action")
        }

        return WalletPreparedAction(
            approvalID: approvalID,
            digest: digest,
            intentType: intentType,
            network: network,
            protocolEpoch: protocolEpoch,
            expiresAt: Date(timeIntervalSince1970: expiresAt),
            display: display
        )
    }
}
