import Foundation

enum RuntimeChannel: String, Sendable {
    case production
    case staging
    case development
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

    var cacheNamespace: String {
        switch channel {
        case .production: "blank-canvas"
        case .staging: "blank-canvas-staging"
        case .development: "blank-canvas-development"
        }
    }

    var defaultsPrefix: String {
        switch channel {
        case .production: ""
        case .staging: "staging."
        case .development: "development."
        }
    }

    var displayChannel: String { channel.rawValue.capitalized }

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
        let bundleChannelValue = (bundleValues["BlankCanvasChannel"] as? String)?.lowercased()
        let bundleChannel = bundleChannelValue.flatMap(RuntimeChannel.init(rawValue:))
        if bundleChannelValue != nil, bundleChannel == nil {
            throw RuntimeError.invalidConfiguration("bundle channel is invalid")
        }
        let developmentMode = argumentSet.contains("--dev-mode")
            || argumentSet.contains("--test-mode")
            || environment["BLANK_CANVAS_DEV_MODE"] == "1"
            || environment["BLANK_CANVAS_TEST_MODE"] == "1"
        let channel: RuntimeChannel = developmentMode ? .development : bundleChannel ?? .production

        let explicitCatalog = value(after: "--catalog-url", in: arguments)
            ?? environment["BLANK_CANVAS_CATALOG_URL"]
        if channel != .development, explicitCatalog != nil {
            throw RuntimeError.invalidConfiguration("catalog overrides require --dev-mode")
        }
        let bundledCatalog = bundleValues["BlankCanvasCatalogURL"] as? String
        let configuredCatalog = channel == .development ? explicitCatalog : bundledCatalog
        let catalogFallback: URL
        switch channel {
        case .production: catalogFallback = productionCatalogURL
        case .staging: catalogFallback = stagingCatalogURL
        case .development: catalogFallback = localCatalogURL
        }
        let catalogURL = try parseURL(
            configuredCatalog,
            fallback: catalogFallback,
            label: "catalog URL"
        )
        if channel == .development {
            guard let origin = RemoteOrigin(url: catalogURL),
                  origin.host == "127.0.0.1" || origin.host == "localhost" else {
                throw RuntimeError.invalidConfiguration("development catalog must use localhost")
            }
        }
        let explicitGallery = value(after: "--gallery-url", in: arguments)
            ?? environment["BLANK_CANVAS_GALLERY_URL"]
        if channel != .development, explicitGallery != nil {
            throw RuntimeError.invalidConfiguration("gallery overrides require --dev-mode")
        }
        let bundledGallery = bundleValues["BlankCanvasGalleryURL"] as? String
        let configuredGallery = channel == .development
            ? explicitGallery
            : bundledGallery
        let galleryFallback: URL
        switch channel {
        case .production: galleryFallback = productionGalleryURL
        case .staging: galleryFallback = stagingGalleryURL
        case .development: galleryFallback = derivedGalleryURL(from: catalogURL)
        }
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
            allowedOrigins: channel == .development ? [productionOrigin, catalogOrigin] : [productionOrigin],
            allowsInsecureLoopback: channel == .development
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
