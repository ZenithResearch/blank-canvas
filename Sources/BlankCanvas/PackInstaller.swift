import Foundation

final class PackInstaller: @unchecked Sendable {
    private let client: CatalogClient
    private let store: PackStore
    private let publicKeyData: Data
    private let fileManager = FileManager.default

    init(client: CatalogClient, store: PackStore, publicKeyData: Data) {
        self.client = client
        self.store = store
        self.publicKeyData = publicKeyData
    }

    func install(_ catalogPack: CatalogPack) async throws -> InstalledPack {
        if let installed = try store.installedPack(id: catalogPack.id, version: catalogPack.currentVersion) {
            store.select(installed)
            return installed
        }

        let (manifest, manifestData) = try await client.fetchManifest(for: catalogPack)
        try validate(manifest, catalogPack: catalogPack)
        try PackSecurity.verify(manifest: manifest, publicKeyData: publicKeyData)

        let archiveData = try await client.fetchData(from: manifest.archive.url, label: "wallpaper archive")
        guard archiveData.count == manifest.archive.bytes else {
            throw RuntimeError.invalidArchive("byte length mismatch")
        }
        guard PackSecurity.sha256(archiveData) == manifest.archive.sha256 else {
            throw RuntimeError.invalidArchive("SHA-256 mismatch")
        }

        let staging = store.stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let archiveURL = staging.appendingPathComponent("pack.zip")
        let versionStaging = staging.appendingPathComponent("version", isDirectory: true)
        let contentRoot = versionStaging.appendingPathComponent("content", isDirectory: true)
        try fileManager.createDirectory(at: contentRoot, withIntermediateDirectories: true)
        try archiveData.write(to: archiveURL, options: .atomic)

        do {
            let entries = try archiveEntries(at: archiveURL)
            guard entries.count <= 512 else { throw RuntimeError.invalidArchive("too many files") }
            guard entries.contains(manifest.entry) else { throw RuntimeError.invalidArchive("entry point missing") }
            guard entries.allSatisfy(PackSecurity.validateRelativePath) else {
                throw RuntimeError.invalidArchive("unsafe archive path")
            }
            try run("/usr/bin/ditto", arguments: ["-x", "-k", archiveURL.path, contentRoot.path])
            try rejectLinks(in: contentRoot)
            let entryURL = contentRoot.appendingPathComponent(manifest.entry).standardizedFileURL
            guard entryURL.path.hasPrefix(contentRoot.standardizedFileURL.path + "/"),
                  fileManager.fileExists(atPath: entryURL.path) else {
                throw RuntimeError.invalidArchive("entry point is unavailable")
            }
            try manifestData.write(to: versionStaging.appendingPathComponent("manifest.json"), options: .atomic)
            let finalRoot = store.versionRoot(id: manifest.id, version: manifest.version)
            try fileManager.createDirectory(at: finalRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard !fileManager.fileExists(atPath: finalRoot.path) else {
                throw RuntimeError.invalidArchive("immutable version already exists")
            }
            try fileManager.moveItem(at: versionStaging, to: finalRoot)
            try? fileManager.removeItem(at: staging)
            let installed = InstalledPack(manifest: manifest, contentRoot: finalRoot.appendingPathComponent("content"))
            store.select(installed)
            return installed
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private func validate(_ manifest: PackManifest, catalogPack: CatalogPack) throws {
        guard manifest.id == catalogPack.id, manifest.version == catalogPack.currentVersion else {
            throw RuntimeError.invalidManifest("catalog identity mismatch")
        }
        guard manifest.runtime.api == "zenith-wallpaper-host",
              let minimum = SemanticVersion(manifest.runtime.minimumVersion),
              let maximum = SemanticVersion(manifest.runtime.maximumExclusiveVersion),
              minimum <= runtimeVersion,
              runtimeVersion < maximum else {
            throw RuntimeError.incompatiblePack("runtime version range")
        }
        guard PackSecurity.validateRelativePath(manifest.entry) else {
            throw RuntimeError.invalidManifest("unsafe entry point")
        }
        try PackSecurity.validateRemoteURL(manifest.archive.url, label: "archive URL", policy: client.configuration.remotePolicy)
        guard manifest.archive.bytes > 0, manifest.archive.bytes <= 250 * 1024 * 1024 else {
            throw RuntimeError.invalidManifest("archive size is outside limits")
        }
        guard manifest.archive.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw RuntimeError.invalidManifest("invalid SHA-256")
        }
        if let notifications = manifest.notifications {
            try validateNotificationFeed(notifications)
        }
    }

    private func validateNotificationFeed(_ notifications: PackNotifications) throws {
        guard let scheme = notifications.feedURL.scheme?.lowercased(),
              let host = notifications.feedURL.host?.lowercased(),
              !host.isEmpty else {
            throw RuntimeError.invalidManifest("notification feed URL is invalid")
        }
        let loopback = scheme == "http" && (host == "127.0.0.1" || host == "localhost")
        guard scheme == "https" || (client.configuration.channel == .development && loopback) else {
            throw RuntimeError.invalidManifest("notification feed must use HTTPS")
        }
        if let interval = notifications.pollIntervalMinutes, !(15...1440).contains(interval) {
            throw RuntimeError.invalidManifest("notification poll interval must be between 15 and 1440 minutes")
        }
    }

    private func archiveEntries(at archiveURL: URL) throws -> [String] {
        let output = try run("/usr/bin/unzip", arguments: ["-Z1", archiveURL.path])
        return output.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.hasSuffix("/") }
    }

    @discardableResult
    private func run(_ executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown error"
            throw RuntimeError.invalidArchive(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func rejectLinks(in root: URL) throws {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey],
            options: []
        ) else { throw RuntimeError.invalidArchive("cannot inspect extracted files") }
        var count = 0
        for case let item as URL in enumerator {
            count += 1
            if count > 512 { throw RuntimeError.invalidArchive("too many extracted files") }
            let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw RuntimeError.invalidArchive("symbolic links are not allowed") }
            guard item.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else {
                throw RuntimeError.invalidArchive("extracted path escaped the pack root")
            }
        }
    }
}
