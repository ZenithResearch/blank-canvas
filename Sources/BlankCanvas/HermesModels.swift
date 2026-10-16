import Foundation

enum HermesMessageRole: String, Equatable, Sendable {
    case user
    case assistant
    case system
    case tool
}

struct HermesMessage: Identifiable, Equatable, Sendable {
    let id: String
    let role: HermesMessageRole
    let text: String
    let rowID: Int?
    let displayKind: String?
    let toolName: String?

    init(
        id: String? = nil,
        role: HermesMessageRole,
        text: String,
        rowID: Int? = nil,
        displayKind: String? = nil,
        toolName: String? = nil
    ) {
        self.id = id ?? rowID.map { "row:\($0)" } ?? UUID().uuidString
        self.role = role
        self.text = text
        self.rowID = rowID
        self.displayKind = displayKind
        self.toolName = toolName
    }

    static func decodeList(from value: JSONValue) throws -> [HermesMessage] {
        guard let values = value.arrayValue else {
            throw HermesProtocolError.invalidResult("Hermes messages are not an array")
        }
        return try values.enumerated().map { index, value in
            guard let object = value.objectValue,
                  let rawRole = object["role"]?.stringValue,
                  let role = HermesMessageRole(rawValue: rawRole) else {
                throw HermesProtocolError.invalidResult("Hermes returned an invalid message")
            }
            let rowID = object["row_id"]?.integerValue
            let toolName = object["name"]?.stringValue
            let text: String
            if role == .tool {
                text = object["context"]?.stringValue ?? toolName ?? "Tool activity"
            } else {
                guard let decodedText = object["text"]?.stringValue else {
                    throw HermesProtocolError.invalidResult("Hermes message is missing display text")
                }
                text = decodedText
            }
            return HermesMessage(
                id: rowID.map { "row:\($0)" } ?? "history:\(index):\(rawRole)",
                role: role,
                text: text,
                rowID: rowID,
                displayKind: object["display_kind"]?.stringValue,
                toolName: toolName
            )
        }
    }
}

struct HermesSessionResume: Equatable, Sendable {
    let runtimeSessionID: String
    let storedSessionID: String
    let messages: [HermesMessage]

    static func decode(from result: JSONValue) throws -> HermesSessionResume {
        guard let runtimeSessionID = result["session_id"]?.stringValue,
              let storedSessionID = result["stored_session_id"]?.stringValue,
              let messageValue = result["messages"] else {
            throw HermesProtocolError.invalidResult("Hermes session.resume result is incomplete")
        }
        return HermesSessionResume(
            runtimeSessionID: runtimeSessionID,
            storedSessionID: storedSessionID,
            messages: try HermesMessage.decodeList(from: messageValue)
        )
    }
}

struct HermesTranscript: Equatable, Sendable {
    var messages: [HermesMessage]
    private(set) var streamingText: String?
    private(set) var lastError: String?

    init(messages: [HermesMessage] = [], streamingText: String? = nil, lastError: String? = nil) {
        self.messages = messages
        self.streamingText = streamingText
        self.lastError = lastError
    }

    @discardableResult
    mutating func apply(_ event: HermesGatewayEvent, activeSessionID: String) -> Bool {
        guard event.sessionID == activeSessionID else { return false }
        switch event.type {
        case .messageStart:
            streamingText = ""
            lastError = nil
        case .messageDelta:
            guard let text = event.payload?["text"]?.stringValue else { return false }
            streamingText = (streamingText ?? "") + text
        case .messageInterim:
            guard let text = event.payload?["text"]?.stringValue, !text.isEmpty else { return false }
            messages.append(HermesMessage(role: .assistant, text: text))
            streamingText = ""
        case .messageComplete:
            guard let text = event.payload?["text"]?.stringValue else { return false }
            if !text.isEmpty {
                messages.append(HermesMessage(role: .assistant, text: text))
            }
            lastError = event.payload?["error"]?.stringValue
            streamingText = nil
        case .error:
            lastError = event.payload?["message"]?.stringValue ?? event.payload?["text"]?.stringValue
            streamingText = nil
        default:
            return false
        }
        return true
    }
}

struct HermesClarificationRequest: Identifiable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let question: String
    let choices: [String]
    let allowsMultiple: Bool

    static func decode(from event: HermesGatewayEvent) throws -> HermesClarificationRequest {
        guard event.type == .clarifyRequest,
              let sessionID = event.sessionID,
              let requestID = event.payload?["request_id"]?.stringValue,
              let question = event.payload?["question"]?.stringValue else {
            throw HermesProtocolError.invalidResult("Hermes clarification request is incomplete")
        }
        let rawChoices = event.payload?["choices"]?.arrayValue ?? []
        let choices = try rawChoices.map { value -> String in
            guard let choice = value.stringValue else {
                throw HermesProtocolError.invalidResult("Hermes clarification choice is invalid")
            }
            return choice
        }
        return HermesClarificationRequest(
            id: requestID,
            sessionID: sessionID,
            question: question,
            choices: choices,
            allowsMultiple: event.payload?["multi_select"]?.boolValue ?? false
        )
    }
}

enum HermesApprovalChoice: String, Equatable, Sendable {
    case once
    case session
    case always
    case deny
}

struct HermesApprovalRequest: Identifiable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let command: String
    let detail: String
    let choices: [HermesApprovalChoice]

    static func decode(from event: HermesGatewayEvent) throws -> HermesApprovalRequest {
        guard event.type == .approvalRequest,
              let sessionID = event.sessionID,
              let requestID = event.payload?["request_id"]?.stringValue else {
            throw HermesProtocolError.invalidResult("Hermes approval request is incomplete")
        }
        let rawChoices = event.payload?["choices"]?.arrayValue ?? [
            .string(HermesApprovalChoice.once.rawValue),
            .string(HermesApprovalChoice.deny.rawValue),
        ]
        let choices = try rawChoices.map { value -> HermesApprovalChoice in
            guard let rawChoice = value.stringValue,
                  let choice = HermesApprovalChoice(rawValue: rawChoice) else {
                throw HermesProtocolError.invalidResult("Hermes approval choice is invalid")
            }
            return choice
        }
        return HermesApprovalRequest(
            id: requestID,
            sessionID: sessionID,
            command: event.payload?["command"]?.stringValue ?? "",
            detail: event.payload?["description"]?.stringValue ?? "",
            choices: choices
        )
    }
}

enum HermesSensitiveRequestKind: Equatable, Sendable {
    case sudo
    case secret
}

struct HermesSensitiveRequest: Identifiable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let kind: HermesSensitiveRequestKind
    let prompt: String
    let environmentVariable: String?

    static func decode(from event: HermesGatewayEvent) throws -> HermesSensitiveRequest {
        guard let sessionID = event.sessionID,
              let requestID = event.payload?["request_id"]?.stringValue else {
            throw HermesProtocolError.invalidResult("Hermes sensitive request is incomplete")
        }
        switch event.type {
        case .sudoRequest:
            return HermesSensitiveRequest(
                id: requestID,
                sessionID: sessionID,
                kind: .sudo,
                prompt: "Administrator password",
                environmentVariable: nil
            )
        case .secretRequest:
            return HermesSensitiveRequest(
                id: requestID,
                sessionID: sessionID,
                kind: .secret,
                prompt: event.payload?["prompt"]?.stringValue ?? "Credential required",
                environmentVariable: event.payload?["env_var"]?.stringValue
            )
        default:
            throw HermesProtocolError.invalidResult("Hermes event is not a sensitive request")
        }
    }
}
