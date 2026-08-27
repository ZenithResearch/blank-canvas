import CryptoKit
import Foundation

enum PackSecurity {
    static func validateRemoteURL(_ url: URL, label: String, policy: RemoteURLPolicy) throws {
        try policy.validate(url, label: label)
    }

    static func validateRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\"), !value.contains("\0") else {
            return false
        }
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    static func canonicalPayload(for manifest: PackManifest) throws -> Data {
        var unsigned = manifest
        unsigned.signature = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(unsigned)
    }

    static func verify(manifest: PackManifest, publicKeyData: Data) throws {
        guard manifest.schemaVersion == 1 else {
            throw RuntimeError.invalidManifest("unsupported schema version")
        }
        guard manifest.signature?.algorithm == "ed25519",
              manifest.signature?.keyID == "zenith-wallpapers-2026-01",
              let signatureValue = manifest.signature?.value,
              let signature = Data(base64Encoded: signatureValue) else {
            throw RuntimeError.invalidManifest("missing signature")
        }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        guard key.isValidSignature(signature, for: try canonicalPayload(for: manifest)) else {
            throw RuntimeError.invalidManifest("signature verification failed")
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
