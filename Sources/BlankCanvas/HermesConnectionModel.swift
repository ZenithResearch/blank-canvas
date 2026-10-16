import Combine
import Foundation
import Security

enum HermesAuthMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case token
    case ticket

    var id: String { rawValue }
    var title: String { self == .token ? "Session token" : "OAuth ticket" }
}

struct HermesSavedConnection: Codable, Equatable, Sendable {
    let endpoint: String
    let profile: String?
    let authMode: HermesAuthMode
}

protocol HermesConnectionSettingsStoring {
    func load() -> HermesSavedConnection?
    func save(_ connection: HermesSavedConnection) throws
}

final class UserDefaultsHermesConnectionSettingsStore: HermesConnectionSettingsStoring {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> HermesSavedConnection? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(HermesSavedConnection.self, from: data)
    }

    func save(_ connection: HermesSavedConnection) throws {
        defaults.set(try JSONEncoder().encode(connection), forKey: key)
    }
}

protocol HermesCredentialStoring {
    func load(for connection: HermesSavedConnection) throws -> HermesSecret?
    func save(_ secret: HermesSecret, for connection: HermesSavedConnection) throws
    func delete(for connection: HermesSavedConnection) throws
}

enum HermesCredentialStoreError: Error, LocalizedError {
    case keychain(OSStatus)
    case invalidEncoding

    var errorDescription: String? {
        switch self {
        case let .keychain(status):
            return "The Hermes credential could not be accessed in Keychain (status \(status))"
        case .invalidEncoding:
            return "The Hermes credential in Keychain is invalid"
        }
    }
}

final class KeychainHermesCredentialStore: HermesCredentialStoring {
    private let service: String

    init(service: String = "ca.zenith-research.blank-canvas.hermes") {
        self.service = service
    }

    func load(for connection: HermesSavedConnection) throws -> HermesSecret? {
        var query = baseQuery(for: connection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw HermesCredentialStoreError.keychain(status) }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw HermesCredentialStoreError.invalidEncoding
        }
        return HermesSecret(value)
    }

    func save(_ secret: HermesSecret, for connection: HermesSavedConnection) throws {
        let data = secret.withValue { Data($0.utf8) }
        var attributes = baseQuery(for: connection)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(baseQuery(for: connection) as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw HermesCredentialStoreError.keychain(updateStatus)
            }
        } else if status != errSecSuccess {
            throw HermesCredentialStoreError.keychain(status)
        }
    }

    func delete(for connection: HermesSavedConnection) throws {
        let status = SecItemDelete(baseQuery(for: connection) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw HermesCredentialStoreError.keychain(status)
        }
    }

    private func baseQuery(for connection: HermesSavedConnection) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: connection),
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    private func account(for connection: HermesSavedConnection) -> String {
        [connection.endpoint, connection.profile ?? "", connection.authMode.rawValue].joined(separator: "|")
    }
}

@MainActor
final class HermesConnectionModel: ObservableObject {
    @Published var endpointText: String
    @Published var profileText: String
    @Published var authMode: HermesAuthMode
    @Published var credentialText = ""
    @Published private(set) var hasStoredCredential = false
    @Published private(set) var errorMessage: String?

    let client: HermesClientModel
    private let settings: HermesConnectionSettingsStoring
    private let credentials: HermesCredentialStoring

    init(
        client: HermesClientModel,
        settings: HermesConnectionSettingsStoring,
        credentials: HermesCredentialStoring
    ) {
        self.client = client
        self.settings = settings
        self.credentials = credentials
        let saved = settings.load()
        endpointText = saved?.endpoint ?? "ws://127.0.0.1:9119/api/ws"
        profileText = saved?.profile ?? ""
        authMode = saved?.authMode ?? .token
        if let saved {
            hasStoredCredential = (try? credentials.load(for: saved)) != nil
        }
    }

    func connect() async {
        errorMessage = nil
        do {
            guard let url = URL(string: endpointText) else {
                throw HermesProtocolError.invalidEndpoint("Enter a valid Hermes WebSocket URL")
            }
            let profile = profileText.trimmingCharacters(in: .whitespacesAndNewlines)
            let connection = HermesSavedConnection(
                endpoint: endpointText,
                profile: profile.isEmpty ? nil : profile,
                authMode: authMode
            )
            let endpoint = try HermesGatewayEndpoint(url: url, profile: connection.profile)
            let enteredCredential = credentialText.trimmingCharacters(in: .whitespacesAndNewlines)
            let secret: HermesSecret
            if !enteredCredential.isEmpty {
                secret = HermesSecret(enteredCredential)
            } else if let stored = try credentials.load(for: connection) {
                secret = stored
            } else {
                throw HermesProtocolError.invalidResult("Enter the Hermes session token or OAuth ticket")
            }
            let credential: HermesGatewayCredential = authMode == .token ? .token(secret) : .ticket(secret)
            await client.connect(to: endpoint, credential: credential)
            guard client.connectionState == .connected else {
                throw HermesProtocolError.invalidResult(client.errorMessage ?? "Hermes connection failed")
            }
            try settings.save(connection)
            if !enteredCredential.isEmpty {
                try credentials.save(secret, for: connection)
            }
            credentialText = ""
            hasStoredCredential = true
        } catch {
            credentialText = ""
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() {
        client.disconnect()
    }

    func forgetCredential() {
        do {
            guard let connection = currentSavedConnection() else { return }
            try credentials.delete(for: connection)
            hasStoredCredential = false
            credentialText = ""
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func currentSavedConnection() -> HermesSavedConnection? {
        let profile = profileText.trimmingCharacters(in: .whitespacesAndNewlines)
        return HermesSavedConnection(
            endpoint: endpointText,
            profile: profile.isEmpty ? nil : profile,
            authMode: authMode
        )
    }
}
