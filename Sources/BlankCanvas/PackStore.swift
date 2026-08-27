import Foundation

final class PackStore: @unchecked Sendable {
    private let fileManager = FileManager.default
    let rootURL: URL
    private let defaultsPrefix: String

    init(rootURL: URL? = nil, namespace: String = "blank-canvas", defaultsPrefix: String = "") throws {
        self.defaultsPrefix = defaultsPrefix
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let base = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            self.rootURL = base.appendingPathComponent(namespace, isDirectory: true)
        }
        try fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: packsRoot, withIntermediateDirectories: true)
    }

    var packsRoot: URL { rootURL.appendingPathComponent("Packs", isDirectory: true) }
    var stagingRoot: URL { rootURL.appendingPathComponent("Staging", isDirectory: true) }

    func versionRoot(id: String, version: String) -> URL {
        packsRoot.appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
    }

    func installedPack(id: String, version: String) throws -> InstalledPack? {
        let root = versionRoot(id: id, version: version)
        let manifestURL = root.appendingPathComponent("manifest.json")
        let contentRoot = root.appendingPathComponent("content", isDirectory: true)
        guard fileManager.fileExists(atPath: manifestURL.path),
              fileManager.fileExists(atPath: contentRoot.path) else { return nil }
        let manifest = try JSONDecoder().decode(PackManifest.self, from: Data(contentsOf: manifestURL))
        let installed = InstalledPack(manifest: manifest, contentRoot: contentRoot)
        guard fileManager.fileExists(atPath: installed.entryURL.path) else { return nil }
        return installed
    }

    func selectedPack() throws -> InstalledPack? {
        let defaults = UserDefaults.standard
        guard let id = defaults.string(forKey: "\(defaultsPrefix)selectedPackID"),
              let version = defaults.string(forKey: "\(defaultsPrefix)selectedPackVersion") else { return nil }
        return try installedPack(id: id, version: version)
    }

    func select(_ pack: InstalledPack) {
        UserDefaults.standard.set(pack.manifest.id, forKey: "\(defaultsPrefix)selectedPackID")
        UserDefaults.standard.set(pack.manifest.version, forKey: "\(defaultsPrefix)selectedPackVersion")
    }
}
