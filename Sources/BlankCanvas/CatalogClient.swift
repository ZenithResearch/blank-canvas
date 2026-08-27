import Foundation

struct CatalogClient: Sendable {
    private let decoder = JSONDecoder()
    let configuration: RuntimeConfiguration

    func fetchCatalog() async throws -> WallpaperCatalog {
        let data = try await fetchData(from: configuration.catalogURL, label: "catalog")
        let catalog: WallpaperCatalog
        do {
            catalog = try decoder.decode(WallpaperCatalog.self, from: data)
        } catch {
            throw RuntimeError.invalidCatalog(error.localizedDescription)
        }
        guard catalog.schemaVersion == 1 else {
            throw RuntimeError.invalidCatalog("unsupported schema version")
        }
        guard let minimum = SemanticVersion(catalog.minimumRuntimeVersion), minimum <= runtimeVersion else {
            throw RuntimeError.invalidCatalog("blank-canvas must be updated first")
        }
        try PackSecurity.validateRemoteURL(catalog.runtime.downloadURL, label: "runtime download URL", policy: configuration.remotePolicy)
        for pack in catalog.packs {
            guard !pack.id.isEmpty, SemanticVersion(pack.currentVersion) != nil else {
                throw RuntimeError.invalidCatalog("invalid pack identity")
            }
            try PackSecurity.validateRemoteURL(pack.manifestURL, label: "manifest URL", policy: configuration.remotePolicy)
            try PackSecurity.validateRemoteURL(pack.previewURL, label: "preview URL", policy: configuration.remotePolicy)
        }
        return catalog
    }

    func fetchManifest(for pack: CatalogPack) async throws -> (PackManifest, Data) {
        let data = try await fetchData(from: pack.manifestURL, label: "manifest")
        do {
            return (try decoder.decode(PackManifest.self, from: data), data)
        } catch {
            throw RuntimeError.invalidManifest(error.localizedDescription)
        }
    }

    func fetchData(from url: URL, label: String) async throws -> Data {
        try PackSecurity.validateRemoteURL(url, label: label, policy: configuration.remotePolicy)
        var request = URLRequest(url: url)
        if let bypass = configuration.protectionBypass, url.host?.hasSuffix(".vercel.app") == true {
            request.setValue(bypass, forHTTPHeaderField: "x-vercel-protection-bypass")
            request.setValue("true", forHTTPHeaderField: "x-vercel-set-bypass-cookie")
        }
        request.timeoutInterval = 30
        request.cachePolicy = .reloadRevalidatingCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RuntimeError.downloadFailed("\(label) returned a non-200 response")
        }
        return data
    }
}
