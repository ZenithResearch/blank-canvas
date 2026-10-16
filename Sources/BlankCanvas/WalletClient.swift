import Foundation

protocol WalletHelperTransporting: Sendable {
    func exchange(_ request: Data) async throws -> Data
}

struct WalletRPCError: Equatable, Sendable {
    let code: String
    let message: String
}

struct WalletRPCResponse: Equatable, Sendable {
    let version: Int
    let id: String
    let channelNonce: String
    let result: JSONValue?
    let error: WalletRPCError?

    static func decode(_ data: Data) throws -> WalletRPCResponse {
        guard data.count <= WalletFrameCodec.maximumPayloadBytes else {
            throw WalletProtocolError.invalidFrame(
                "Wallet response exceeds the maximum payload size"
            )
        }

        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw WalletProtocolError.invalidResult("Wallet returned malformed JSON")
        }

        guard let object = value.objectValue,
              object["version"]?.integerValue == 1,
              let id = object["id"]?.stringValue,
              !id.isEmpty,
              let channelNonce = object["channel_nonce"]?.stringValue,
              !channelNonce.isEmpty else {
            throw WalletProtocolError.invalidResult("Wallet returned an invalid response")
        }

        let result: JSONValue?
        let responseError: WalletRPCError?
        switch (object["result"], object["error"]) {
        case let (.some(value), nil):
            result = value
            responseError = nil
        case let (nil, .some(value)):
            guard let errorObject = value.objectValue,
                  let code = errorObject["code"]?.stringValue,
                  !code.isEmpty,
                  let message = errorObject["message"]?.stringValue else {
                throw WalletProtocolError.invalidResult("Wallet returned an invalid error")
            }
            result = nil
            responseError = WalletRPCError(code: code, message: message)
        default:
            throw WalletProtocolError.invalidResult(
                "Wallet response must contain exactly one result or error"
            )
        }

        return WalletRPCResponse(
            version: 1,
            id: id,
            channelNonce: channelNonce,
            result: result,
            error: responseError
        )
    }
}

actor WalletClient {
    private let transport: any WalletHelperTransporting
    private let channelNonce: String
    private let makeRequestID: @Sendable () -> String

    init(
        transport: any WalletHelperTransporting,
        channelNonce: String,
        makeRequestID: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.transport = transport
        self.channelNonce = channelNonce
        self.makeRequestID = makeRequestID
    }

    func status() async throws -> WalletStatus {
        let result = try await request(.status)
        return try WalletStatus.decode(from: result)
    }

    private func request(
        _ method: WalletRPCMethod,
        params: [String: JSONValue] = [:]
    ) async throws -> JSONValue {
        let id = makeRequestID()
        guard !id.isEmpty, !channelNonce.isEmpty else {
            throw WalletProtocolError.invalidResult("Wallet request identity is invalid")
        }

        let request = WalletRPCRequest(
            id: id,
            channelNonce: channelNonce,
            method: method,
            params: params
        )
        let requestData: Data
        do {
            requestData = try JSONEncoder().encode(request)
        } catch {
            throw WalletProtocolError.invalidResult("Wallet request could not be encoded")
        }

        let response = try WalletRPCResponse.decode(
            await transport.exchange(requestData)
        )
        guard response.id == id, response.channelNonce == channelNonce else {
            throw WalletProtocolError.invalidResult("Wallet response does not match its request")
        }
        if let error = response.error {
            throw WalletProtocolError.helperError(code: error.code, message: error.message)
        }
        guard let result = response.result else {
            throw WalletProtocolError.invalidResult("Wallet response is missing its result")
        }
        return result
    }
}
