import Foundation

let runtimeVersion = SemanticVersion("2.0.0")!

struct WallpaperCatalog: Decodable, Sendable {
    let schemaVersion: Int
    let generatedAt: String
    let minimumRuntimeVersion: String
    let runtime: RuntimeRelease
    let packs: [CatalogPack]
}

struct RuntimeRelease: Decodable, Sendable {
    let name: String
    let version: String
    let downloadURL: URL
}

struct CatalogPack: Decodable, Identifiable, Sendable {
    let id: String
    let title: String
    let summary: String
    let currentVersion: String
    let manifestURL: URL
    let previewURL: URL
    let featured: Bool
}

struct PackManifest: Codable, Sendable {
    let schemaVersion: Int
    let id: String
    let version: String
    let releasedAt: String
    let entry: String
    let runtime: PackRuntime
    let requirements: PackRequirements
    let archive: PackArchive
    let actions: [PackAction]
    let motion: PackMotion
    var notifications: PackNotifications? = nil
    var signature: PackSignature?
}

struct PackNotifications: Codable, Sendable {
    let feedURL: URL
    let format: NotificationFeedFormat
    let pollIntervalMinutes: Int?
}

enum NotificationFeedFormat: String, Codable, Sendable {
    case zenithJSON = "zenith-json-v1"
    case rss
}

struct PackRuntime: Codable, Sendable {
    let api: String
    let minimumVersion: String
    let maximumExclusiveVersion: String
}

struct PackRequirements: Codable, Sendable {
    let webgl2: Bool
    let wasm: Bool
    let minimumMacOS: String
}

struct PackArchive: Codable, Sendable {
    let url: URL
    let bytes: Int
    let sha256: String
}

struct PackAction: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let symbol: String
}

struct PackMotion: Codable, Sendable {
    let supportsReducedMotion: Bool
}

struct PackSignature: Codable, Sendable {
    let algorithm: String
    let keyID: String
    let value: String
}

struct InstalledPack: Sendable {
    let manifest: PackManifest
    let contentRoot: URL

    var entryURL: URL {
        contentRoot.appendingPathComponent(manifest.entry)
    }
}

struct SemanticVersion: Comparable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ value: String) {
        let core = value.split(separator: "-", maxSplits: 1)[0]
        let components = core.split(separator: ".")
        guard components.count == 3,
              let major = Int(components[0]),
              let minor = Int(components[1]),
              let patch = Int(components[2]) else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (left: SemanticVersion, right: SemanticVersion) -> Bool {
        (left.major, left.minor, left.patch) < (right.major, right.minor, right.patch)
    }
}

enum RuntimeError: LocalizedError {
    case invalidConfiguration(String)
    case invalidCatalog(String)
    case invalidManifest(String)
    case incompatiblePack(String)
    case downloadFailed(String)
    case invalidArchive(String)
    case missingPublicKey
    case noInstalledPack

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let reason): "blank-canvas configuration rejected: \(reason)"
        case .invalidCatalog(let reason): "Catalog rejected: \(reason)"
        case .invalidManifest(let reason): "Wallpaper rejected: \(reason)"
        case .incompatiblePack(let reason): "Wallpaper is incompatible: \(reason)"
        case .downloadFailed(let reason): "Download failed: \(reason)"
        case .invalidArchive(let reason): "Wallpaper archive rejected: \(reason)"
        case .missingPublicKey: "The wallpaper verification key is missing from blank-canvas."
        case .noInstalledPack: "No downloaded wallpaper is selected."
        }
    }
}
