import Foundation

enum RuntimeChannel: String, Sendable {
    case production
    case staging
}

struct RemoteOrigin: Hashable, Sendable {
    let scheme: String
    let host: String
    let port: Int?

    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        self.scheme = scheme
        self.host = host
        port = url.port
    }
}

struct RemoteURLPolicy: Sendable {
    let allowedOrigins: Set<RemoteOrigin>
    let allowsInsecureLoopback: Bool

    func validate(_ url: URL, label: String) throws {
        guard let origin = RemoteOrigin(url: url), allowedOrigins.contains(origin) else {
            throw RuntimeError.invalidManifest("\(label) uses an unapproved origin")
        }
        if origin.scheme == "https" { return }
        let isLoopback = origin.scheme == "http" && (origin.host == "127.0.0.1" || origin.host == "localhost")
        guard allowsInsecureLoopback && isLoopback else {
            throw RuntimeError.invalidManifest("\(label) must use HTTPS")
        }
    }
}

struct RuntimeConfiguration: Sendable {
    static let productionCatalogURL = URL(string: "https://zenith-research.ca/wallpapers/v1/catalog.json")!
    static let productionGalleryURL = URL(string: "https://zenith-research.ca/wallpapers/")!
    static let stagingCatalogURL = URL(string: "https://zenith-research.ca/wallpapers/v1/staging/catalog.json")!
    static let stagingGalleryURL = URL(string: "https://zenith-research.ca/wallpapers/staging")!
    static let localCatalogURL = URL(string: "http://127.0.0.1:3001/wallpapers/v1/catalog.json")!
    static let localGalleryURL = URL(string: "http://127.0.0.1:3001/wallpapers")!

    let channel: RuntimeChannel
    let catalogURL: URL
    let galleryURL: URL
    let remotePolicy: RemoteURLPolicy
    let protectionBypass: String?

    var cacheNamespace: String { channel == .production ? "blank-canvas" : "blank-canvas-staging" }
    var defaultsPrefix: String { channel == .production ? "" : "staging." }
    var displayChannel: String { channel == .production ? "Production" : "Staging" }

    func browserAssetURL(_ url: URL) -> URL {
        guard let protectionBypass, url.host?.hasSuffix(".vercel.app") == true,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "x-vercel-protection-bypass", value: protectionBypass))
        items.append(URLQueryItem(name: "x-vercel-set-bypass-cookie", value: "true"))
        components.queryItems = items
        return components.url ?? url
    }

    static func load(
        bundleValues: [String: Any] = Bundle.main.infoDictionary ?? [:],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) throws -> RuntimeConfiguration {
        let argumentSet = Set(arguments)
        let bundleChannel = (bundleValues["BlankCanvasChannel"] as? String)?.lowercased()
        let testMode = argumentSet.contains("--test-mode")
            || environment["BLANK_CANVAS_TEST_MODE"] == "1"
            || bundleChannel == RuntimeChannel.staging.rawValue
        let channel: RuntimeChannel = testMode ? .staging : .production

        let explicitCatalog = value(after: "--catalog-url", in: arguments)
            ?? environment["BLANK_CANVAS_CATALOG_URL"]
        let configuredCatalog = explicitCatalog
            ?? bundleValues["BlankCanvasCatalogURL"] as? String
        if channel == .production, configuredCatalog != nil {
            throw RuntimeError.invalidConfiguration("catalog overrides require --test-mode")
        }
        let catalogURL = try parseURL(
            configuredCatalog,
            fallback: channel == .production ? productionCatalogURL : stagingCatalogURL,
            label: "catalog URL"
        )
        let explicitGallery = value(after: "--gallery-url", in: arguments)
            ?? environment["BLANK_CANVAS_GALLERY_URL"]
        let configuredGallery = explicitGallery
            ?? (explicitCatalog == nil ? bundleValues["BlankCanvasGalleryURL"] as? String : nil)
        let galleryFallback = channel == .production
            ? productionGalleryURL
            : configuredCatalog == nil ? stagingGalleryURL : derivedGalleryURL(from: catalogURL)
        let galleryURL = try parseURL(
            configuredGallery,
            fallback: galleryFallback,
            label: "gallery URL"
        )
        guard let productionOrigin = RemoteOrigin(url: productionCatalogURL),
              let catalogOrigin = RemoteOrigin(url: catalogURL) else {
            throw RuntimeError.invalidConfiguration("catalog origin is invalid")
        }
        let policy = RemoteURLPolicy(
            allowedOrigins: channel == .production ? [productionOrigin] : [productionOrigin, catalogOrigin],
            allowsInsecureLoopback: channel == .staging
        )
        try policy.validate(catalogURL, label: "catalog URL")
        return RuntimeConfiguration(
            channel: channel,
            catalogURL: catalogURL,
            galleryURL: galleryURL,
            remotePolicy: policy,
            protectionBypass: channel == .staging ? environment["BLANK_CANVAS_STAGING_BYPASS"] : nil
        )
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func parseURL(_ raw: String?, fallback: URL, label: String) throws -> URL {
        guard let raw else { return fallback }
        guard let url = URL(string: raw), url.host != nil else {
            throw RuntimeError.invalidConfiguration("\(label) is invalid")
        }
        return url
    }

    private static func derivedGalleryURL(from catalogURL: URL) -> URL {
        var components = URLComponents(url: catalogURL, resolvingAgainstBaseURL: false)!
        if let range = components.path.range(of: "/wallpapers/") {
            components.path = String(components.path[..<range.upperBound].dropLast())
        } else {
            components.path = "/"
        }
        components.query = nil
        components.fragment = nil
        return components.url!
    }
}
