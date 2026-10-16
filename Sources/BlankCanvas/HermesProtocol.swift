import Foundation

enum HermesProtocolError: Error, Equatable, LocalizedError {
    case invalidEndpoint(String)
    case invalidFrame(String)
    case invalidResult(String)

    var errorDescription: String? {
        switch self {
        case let .invalidEndpoint(message), let .invalidFrame(message), let .invalidResult(message):
            return message
        }
    }
}

enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }

    subscript(key: String) -> JSONValue? {
        guard case let .object(values) = self else { return nil }
        return values[key]
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var integerValue: Int? {
        switch self {
        case let .integer(value): return value
        case let .number(value) where value.rounded() == value: return Int(exactly: value)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case let .integer(value): return Double(value)
        case let .number(value): return value
        default: return nil
        }
    }

    var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }
}

enum HermesRPCMethod: String, Codable, CaseIterable, Sendable {
    case sessionCreate = "session.create"
    case sessionList = "session.list"
    case sessionResume = "session.resume"
    case sessionHistory = "session.history"
    case promptSubmit = "prompt.submit"
    case sessionInterrupt = "session.interrupt"
    case clarifyRespond = "clarify.respond"
    case approvalRespond = "approval.respond"
    case sudoRespond = "sudo.respond"
    case secretRespond = "secret.respond"
}

struct HermesRPCRequest: Encodable, Equatable, Sendable {
    let jsonrpc = "2.0"
    let id: String
    let method: HermesRPCMethod
    let params: [String: JSONValue]

    init(id: String, method: HermesRPCMethod, params: [String: JSONValue] = [:]) {
        self.id = id
        self.method = method
        self.params = params
    }
}

struct HermesRPCError: Codable, Equatable, Sendable {
    let code: Int
    let message: String
}

struct HermesRPCResponse: Equatable, Sendable {
    let id: String
    let result: JSONValue?
    let error: HermesRPCError?
}

struct HermesEventType: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static let gatewayReady = Self(rawValue: "gateway.ready")
    static let sessionInfo = Self(rawValue: "session.info")
    static let messageStart = Self(rawValue: "message.start")
    static let messageDelta = Self(rawValue: "message.delta")
    static let messageInterim = Self(rawValue: "message.interim")
    static let messageComplete = Self(rawValue: "message.complete")
    static let thinkingDelta = Self(rawValue: "thinking.delta")
    static let reasoningDelta = Self(rawValue: "reasoning.delta")
    static let reasoningAvailable = Self(rawValue: "reasoning.available")
    static let statusUpdate = Self(rawValue: "status.update")
    static let toolStart = Self(rawValue: "tool.start")
    static let toolProgress = Self(rawValue: "tool.progress")
    static let toolComplete = Self(rawValue: "tool.complete")
    static let clarifyRequest = Self(rawValue: "clarify.request")
    static let approvalRequest = Self(rawValue: "approval.request")
    static let sudoRequest = Self(rawValue: "sudo.request")
    static let secretRequest = Self(rawValue: "secret.request")
    static let error = Self(rawValue: "error")
}

struct HermesGatewayEvent: Equatable, Sendable {
    let type: HermesEventType
    let sessionID: String?
    let profile: String?
    let payload: JSONValue?
}

enum HermesRPCFrame: Equatable, Sendable {
    static let maximumFrameBytes = 1_048_576

    case response(HermesRPCResponse)
    case event(HermesGatewayEvent)

    static func decode(_ data: Data) throws -> HermesRPCFrame {
        guard data.count <= maximumFrameBytes else {
            throw HermesProtocolError.invalidFrame("Hermes frame exceeds \(maximumFrameBytes) bytes")
        }
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw HermesProtocolError.invalidFrame("Hermes sent malformed JSON")
        }
        guard let object = value.objectValue,
              object["jsonrpc"]?.stringValue == "2.0" else {
            throw HermesProtocolError.invalidFrame("Hermes frame is not JSON-RPC 2.0")
        }

        if object["method"]?.stringValue == "event" {
            guard let params = object["params"]?.objectValue,
                  let type = params["type"]?.stringValue else {
                throw HermesProtocolError.invalidFrame("Hermes event is missing its type")
            }
            return .event(HermesGatewayEvent(
                type: HermesEventType(rawValue: type),
                sessionID: params["session_id"]?.stringValue,
                profile: params["profile"]?.stringValue,
                payload: params["payload"]
            ))
        }

        guard let id = object["id"]?.stringValue else {
            throw HermesProtocolError.invalidFrame("Hermes response is missing its request id")
        }
        let result = object["result"]
        let rpcError: HermesRPCError?
        if let errorValue = object["error"] {
            guard let error = errorValue.objectValue,
                  let code = error["code"]?.integerValue,
                  let message = error["message"]?.stringValue else {
                throw HermesProtocolError.invalidFrame("Hermes response contains an invalid error")
            }
            rpcError = HermesRPCError(code: code, message: message)
        } else {
            rpcError = nil
        }
        guard (result != nil) != (rpcError != nil) else {
            throw HermesProtocolError.invalidFrame("Hermes response must contain exactly one result or error")
        }
        return .response(HermesRPCResponse(id: id, result: result, error: rpcError))
    }
}

struct HermesSecret: CustomStringConvertible, Sendable {
    private let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    func withValue<Result>(_ body: (String) throws -> Result) rethrows -> Result {
        try body(rawValue)
    }

    var description: String { "<redacted>" }
}

enum HermesGatewayCredential: Sendable {
    case token(HermesSecret)
    case ticket(HermesSecret)
}

struct HermesGatewayEndpoint: CustomStringConvertible, Equatable, Sendable {
    let url: URL
    let profile: String?

    init(url: URL, profile: String?) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme,
              let host = components.host,
              scheme == "ws" || scheme == "wss",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.hasSuffix("/api/ws") else {
            throw HermesProtocolError.invalidEndpoint(
                "Hermes endpoint must be an uncredentialed ws:// or wss:// /api/ws URL"
            )
        }
        let normalizedHost = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        let loopbackHosts = ["localhost", "127.0.0.1", "::1"]
        guard scheme == "wss" || loopbackHosts.contains(normalizedHost) else {
            throw HermesProtocolError.invalidEndpoint(
                "Remote Hermes endpoints must use wss://; ws:// is limited to loopback"
            )
        }
        self.url = url
        let normalizedProfile = profile?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.profile = normalizedProfile?.isEmpty == false ? normalizedProfile : nil
    }

    func authenticatedURL(using credential: HermesGatewayCredential) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw HermesProtocolError.invalidEndpoint("Hermes endpoint cannot be represented as URL components")
        }
        switch credential {
        case let .token(secret):
            components.queryItems = [URLQueryItem(name: "token", value: secret.withValue { $0 })]
        case let .ticket(secret):
            components.queryItems = [URLQueryItem(name: "ticket", value: secret.withValue { $0 })]
        }
        guard let authenticated = components.url else {
            throw HermesProtocolError.invalidEndpoint("Hermes endpoint could not accept a credential")
        }
        return authenticated
    }

    var description: String {
        let profileDescription = profile.map { " [profile: \($0)]" } ?? ""
        return url.absoluteString + profileDescription
    }
}

struct HermesSessionSummary: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let preview: String
    let startedAt: Date
    let messageCount: Int
    let source: String

    static func decodeList(from result: JSONValue) throws -> [HermesSessionSummary] {
        guard let sessions = result["sessions"]?.arrayValue else {
            throw HermesProtocolError.invalidResult("Hermes session.list result is missing sessions")
        }
        return try sessions.map { value in
            guard let object = value.objectValue,
                  let id = object["id"]?.stringValue,
                  let startedAt = object["started_at"]?.doubleValue,
                  let messageCount = object["message_count"]?.integerValue else {
                throw HermesProtocolError.invalidResult("Hermes returned an invalid session summary")
            }
            return HermesSessionSummary(
                id: id,
                title: object["title"]?.stringValue ?? "",
                preview: object["preview"]?.stringValue ?? "",
                startedAt: Date(timeIntervalSince1970: startedAt),
                messageCount: messageCount,
                source: object["source"]?.stringValue ?? ""
            )
        }
    }
}
