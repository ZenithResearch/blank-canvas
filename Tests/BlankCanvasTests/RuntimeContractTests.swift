import CryptoKit
import Foundation
import Testing
@testable import BlankCanvas

@Suite("blank-canvas contracts")
struct RuntimeContractTests {
    @Test("Release surfaces agree on runtime 2.1.0")
    func releaseVersionConsistency() throws {
        #expect(runtimeVersion == SemanticVersion("2.1.0"))
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let expectations = [
            ("Sources/BlankCanvas/HUDView.swift", "Wallpaper runtime · 2.1.0"),
            ("Packaging/Info.plist", "<string>2.1.0</string>"),
            ("Packaging/Info-Staging.plist", "<string>2.1.0</string>"),
            ("scripts/build-app.sh", "blank-canvas-2.1.0-macOS.zip"),
            ("scripts/build-staging-app.sh", "blank-canvas-staging-2.1.0-macOS.zip"),
            ("scripts/write-release-metadata.mjs", "const version = \"2.1.0\""),
            (".github/workflows/notarized-release.yml", "blank-canvas-2.1.0-macOS"),
            ("README.md", "dist/blank-canvas-2.1.0-macOS.zip"),
        ]
        for (relativePath, expected) in expectations {
            let source = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
            #expect(source.contains(expected), "\(relativePath) must contain \(expected)")
        }
    }

    @Test("Semantic runtime versions compare numerically")
    func semanticVersions() {
        #expect(SemanticVersion("2.0.0")! < SemanticVersion("2.1.0")!)
        #expect(SemanticVersion("2.10.0")! > SemanticVersion("2.2.9")!)
        #expect(SemanticVersion("2.0") == nil)
    }

    @Test("Pack paths cannot escape the verified root")
    func safePaths() {
        #expect(PackSecurity.validateRelativePath("index.html"))
        #expect(PackSecurity.validateRelativePath("pkg/wallpaper_bg.wasm"))
        #expect(!PackSecurity.validateRelativePath("../index.html"))
        #expect(!PackSecurity.validateRelativePath("pkg//module.js"))
        #expect(!PackSecurity.validateRelativePath("/index.html"))
    }

    @Test("Production, staging and development use distinct catalogue routes")
    func runtimeConfiguration() throws {
        let production = try RuntimeConfiguration.load(bundleValues: [:], environment: [:], arguments: ["BlankCanvas"])
        #expect(production.channel == .production)
        #expect(production.catalogURL == RuntimeConfiguration.productionCatalogURL)
        #expect(production.cacheNamespace == "blank-canvas")

        let development = try RuntimeConfiguration.load(
            bundleValues: [:],
            environment: [:],
            arguments: ["BlankCanvas", "--dev-mode"]
        )
        #expect(development.channel == .development)
        #expect(development.catalogURL == RuntimeConfiguration.localCatalogURL)
        #expect(development.cacheNamespace == "blank-canvas-development")
        #expect(development.galleryURL == RuntimeConfiguration.localGalleryURL)
        try development.remotePolicy.validate(development.catalogURL, label: "catalog")

        let stableStaging = try RuntimeConfiguration.load(
            bundleValues: ["BlankCanvasChannel": "staging"],
            environment: [:],
            arguments: ["BlankCanvas"]
        )
        #expect(stableStaging.catalogURL == RuntimeConfiguration.stagingCatalogURL)
        #expect(stableStaging.galleryURL == RuntimeConfiguration.stagingGalleryURL)
        #expect(stableStaging.cacheNamespace == "blank-canvas-staging")

        let legacyDevelopment = try RuntimeConfiguration.load(
            bundleValues: [:],
            environment: [:],
            arguments: ["BlankCanvas", "--test-mode", "--catalog-url", "http://localhost:8080/wallpapers/v1/catalog.json"]
        )
        #expect(legacyDevelopment.channel == .development)
        #expect(legacyDevelopment.catalogURL.host == "localhost")

        #expect(throws: RuntimeError.self) {
            try RuntimeConfiguration.load(
                bundleValues: [:],
                environment: ["BLANK_CANVAS_CATALOG_URL": "http://127.0.0.1:3001/catalog.json"],
                arguments: ["BlankCanvas"]
            )
        }
        #expect(throws: RuntimeError.self) {
            try RuntimeConfiguration.load(
                bundleValues: [:],
                environment: [:],
                arguments: ["BlankCanvas", "--dev-mode", "--catalog-url", "http://example.com/catalog.json"]
            )
        }
        #expect(throws: RuntimeError.self) {
            try RuntimeConfiguration.load(
                bundleValues: ["BlankCanvasChannel": "staging"],
                environment: ["BLANK_CANVAS_CATALOG_URL": "http://127.0.0.1:3001/catalog.json"],
                arguments: ["BlankCanvas"]
            )
        }
    }

    @Test("Canonical manifests verify with their pinned Ed25519 key")
    func manifestSignature() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        var manifest = fixtureManifest
        let signature = try privateKey.signature(for: PackSecurity.canonicalPayload(for: manifest))
        manifest.signature = PackSignature(
            algorithm: "ed25519",
            keyID: "zenith-wallpapers-2026-01",
            value: signature.base64EncodedString()
        )
        try PackSecurity.verify(manifest: manifest, publicKeyData: privateKey.publicKey.rawRepresentation)
        manifest.signature = PackSignature(
            algorithm: "ed25519",
            keyID: "zenith-wallpapers-2026-01",
            value: Data(repeating: 0, count: 64).base64EncodedString()
        )
        #expect(throws: RuntimeError.self) {
            try PackSecurity.verify(manifest: manifest, publicKeyData: privateKey.publicKey.rawRepresentation)
        }
    }

    @Test("A producer-signed manifest fixture verifies in Swift")
    func publishedManifest() throws {
        var repositoryRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { repositoryRoot.deleteLastPathComponent() }
        let fixtureRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
        let manifest = try JSONDecoder().decode(
            PackManifest.self,
            from: Data(contentsOf: fixtureRoot.appendingPathComponent("signed-manifest.json"))
        )
        let encodedKey = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Resources/WallpaperPublicKey.txt"),
            encoding: .utf8
        )
        let publicKey = try #require(Data(base64Encoded: encodedKey.trimmingCharacters(in: .whitespacesAndNewlines)))
        try PackSecurity.verify(manifest: manifest, publicKeyData: publicKey)
    }

    @Test("A pack interface resolves inside the verified content root")
    func packInterfaceEntry() throws {
        let manifest = try JSONDecoder().decode(PackManifest.self, from: Data(#"""
        {
          "schemaVersion": 1,
          "id": "custom-world",
          "version": "1.0.0",
          "releasedAt": "2026-10-13T00:00:00Z",
          "entry": "index.html",
          "runtime": {
            "api": "zenith-wallpaper-host",
            "minimumVersion": "2.0.0",
            "maximumExclusiveVersion": "3.0.0"
          },
          "requirements": { "webgl2": false, "wasm": false, "minimumMacOS": "13.0.0" },
          "archive": {
            "url": "https://example.com/custom-world.zip",
            "bytes": 100,
            "sha256": "0000000000000000000000000000000000000000000000000000000000000000"
          },
          "actions": [{ "id": "ring", "title": "Ring", "symbol": "bell" }],
          "motion": { "supportsReducedMotion": true },
          "interface": { "version": 1, "entry": "controls/interface.html", "height": 220 }
        }
        """#.utf8))
        let contentRoot = URL(fileURLWithPath: "/tmp/custom-world/content", isDirectory: true)
        let installed = InstalledPack(manifest: manifest, contentRoot: contentRoot)

        #expect(manifest.interface?.version == 1)
        #expect(manifest.interface?.height == 220)
        #expect(installed.interfaceURL == contentRoot.appendingPathComponent("controls/interface.html"))
    }

    @Test("Pack interfaces reject unsupported versions, unsafe paths, and unbounded heights")
    func packInterfaceValidation() throws {
        try PackInterface(version: 1, entry: "controls/interface.html", height: 220).validate()
        #expect(throws: RuntimeError.self) {
            try PackInterface(version: 2, entry: "controls/interface.html", height: 220).validate()
        }
        #expect(throws: RuntimeError.self) {
            try PackInterface(version: 1, entry: "../outside.html", height: 220).validate()
        }
        #expect(throws: RuntimeError.self) {
            try PackInterface(version: 1, entry: "controls/interface.js", height: 220).validate()
        }
        #expect(throws: RuntimeError.self) {
            try PackInterface(version: 1, entry: "controls/interface.html", height: 800).validate()
        }
    }

    @Test("Installation requires every signed browser entry in the archive")
    func archiveRequiresInterfaceEntry() throws {
        var manifest = fixtureManifest
        manifest.interface = PackInterface(version: 1, entry: "controls/interface.html", height: 220)

        #expect(throws: RuntimeError.self) {
            try PackInstaller.validateArchiveEntries(["index.html"], manifest: manifest)
        }
        try PackInstaller.validateArchiveEntries(
            ["index.html", "controls/interface.html", "controls/interface.css"],
            manifest: manifest
        )
    }

    @Test("Cached packs require their declared interface entry")
    func cachedPackInterfaceEntry() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("blank-canvas-interface-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = try PackStore(rootURL: temporary, defaultsPrefix: "test-interface-")
        let versionRoot = store.versionRoot(id: "starward-loggia", version: "1.0.0")
        let contentRoot = versionRoot.appendingPathComponent("content", isDirectory: true)
        let interfaceURL = contentRoot.appendingPathComponent("controls/interface.html")
        try FileManager.default.createDirectory(
            at: interfaceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("<!doctype html>".utf8).write(to: contentRoot.appendingPathComponent("index.html"))
        try Data("<!doctype html>".utf8).write(to: interfaceURL)
        var manifest = fixtureManifest
        manifest.interface = PackInterface(version: 1, entry: "controls/interface.html", height: 220)
        try JSONEncoder().encode(manifest).write(to: versionRoot.appendingPathComponent("manifest.json"))

        #expect(try store.installedPack(id: "starward-loggia", version: "1.0.0")?.interfaceURL == interfaceURL)
        try FileManager.default.removeItem(at: interfaceURL)
        #expect(throws: RuntimeError.self) {
            try store.installedPack(id: "starward-loggia", version: "1.0.0")
        }
    }

    @Test("HUD interface failure is scoped to the exact pack version")
    func interfacePresentationFallback() {
        var manifest = fixtureManifest
        manifest.interface = PackInterface(version: 1, entry: "controls/interface.html", height: 220)
        let installed = InstalledPack(
            manifest: manifest,
            contentRoot: URL(fileURLWithPath: "/tmp/starward-loggia/content", isDirectory: true)
        )
        let identity = WallpaperInterfacePresentation.identity(for: installed)

        #expect(identity == "starward-loggia@1.0.0")
        #expect(WallpaperInterfacePresentation.usesCustomInterface(installed, failedIdentity: nil))
        #expect(!WallpaperInterfacePresentation.usesCustomInterface(installed, failedIdentity: identity))
        #expect(WallpaperInterfacePresentation.usesCustomInterface(
            installed,
            failedIdentity: "starward-loggia@0.9.0"
        ))

        var legacyManifest = fixtureManifest
        legacyManifest.interface = nil
        let legacy = InstalledPack(manifest: legacyManifest, contentRoot: installed.contentRoot)
        #expect(!WallpaperInterfacePresentation.usesCustomInterface(legacy, failedIdentity: nil))
    }

    @Test("The interface bridge accepts only declared bounded action messages")
    func interfaceBridgeAllowlist() {
        let declared = Set(["ring-bell", "visit-porch"])

        #expect(WallpaperInterfaceBridge.actionID(
            from: ["type": "perform-action", "id": "ring-bell"],
            declaredActionIDs: declared
        ) == "ring-bell")
        #expect(WallpaperInterfaceBridge.actionID(
            from: ["type": "perform-action", "id": "unknown"],
            declaredActionIDs: declared
        ) == nil)
        #expect(WallpaperInterfaceBridge.actionID(
            from: ["type": "resize", "id": "ring-bell"],
            declaredActionIDs: declared
        ) == nil)
        #expect(WallpaperInterfaceBridge.actionID(
            from: ["type": "perform-action", "id": String(repeating: "a", count: 129)],
            declaredActionIDs: declared
        ) == nil)
        #expect(WallpaperInterfaceBridge.actionID(
            from: ["type": "perform-action", "id": "ring-bell", "extra": true],
            declaredActionIDs: declared
        ) == nil)
    }

    @Test("The host bridge exposes additive app events and feed capability")
    func hostBridgeContract() {
        #expect(WallpaperHostBridge.apiVersion == "1.1.0")
        #expect(WallpaperHostBridge.bootstrapScript.contains("globalThis.zenithWallpaper"))
        #expect(WallpaperHostBridge.bootstrapScript.contains("notification-feeds"))
        #expect(WallpaperHostBridge.bootstrapScript.contains("requestNotification"))
        #expect(WallpaperHostBridge.bootstrapScript.contains("publish-to-declared-feed"))
        #expect(!WallpaperHostBridge.bootstrapScript.contains("notification-request"))
        #expect(WallpaperHostBridge.json("action") == "\"action\"")
    }

    @Test("Wallpaper JSON and RSS update feeds parse into the shared inbox model")
    func notificationFeedContract() throws {
        let json = Data(#"""
        {
          "schemaVersion": 1,
          "wallpaperID": "starward-loggia",
          "items": [{
            "id": "starfall-2026",
            "publishedAt": "2026-08-31T07:00:00Z",
            "title": "Starfall",
            "body": "The current is bright.",
            "url": "https://zenith-research.ca/wallpapers"
          }]
        }
        """#.utf8)
        let jsonItems = try WallpaperNotificationFeedParser.parseJSON(
            json,
            packID: "starward-loggia",
            wallpaperTitle: "Starward Loggia"
        )
        #expect(jsonItems.count == 1)
        #expect(jsonItems.first?.title == "Starfall")
        #expect(jsonItems.first?.packID == "starward-loggia")

        let rss = Data(#"""
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel><item>
          <guid>arrival-1</guid><title>Arrival</title>
          <description>A new view is ready.</description>
          <pubDate>Sun, 31 Aug 2026 07:00:00 +0000</pubDate>
          <link>https://zenith-research.ca/wallpapers</link>
        </item></channel></rss>
        """#.utf8)
        let rssItems = try WallpaperNotificationFeedParser.parseRSS(
            rss,
            packID: "starward-loggia",
            wallpaperTitle: "Starward Loggia"
        )
        #expect(rssItems.count == 1)
        #expect(rssItems.first?.body == "A new view is ready.")

        #expect(throws: RuntimeError.self) {
            try WallpaperNotificationFeedParser.parseJSON(
                json,
                packID: "different-wallpaper",
                wallpaperTitle: "Different"
            )
        }
    }

    private var fixtureManifest: PackManifest {
        PackManifest(
            schemaVersion: 1,
            id: "starward-loggia",
            version: "1.0.0",
            releasedAt: "2026-08-25T20:00:00Z",
            entry: "index.html",
            runtime: PackRuntime(
                api: "zenith-wallpaper-host",
                minimumVersion: "2.0.0",
                maximumExclusiveVersion: "3.0.0"
            ),
            requirements: PackRequirements(webgl2: true, wasm: true, minimumMacOS: "13.0.0"),
            archive: PackArchive(
                url: URL(string: "https://zenith-research.ca/wallpapers/v1/packs/starward-loggia/1.0.0/pack.zip")!,
                bytes: 100,
                sha256: String(repeating: "0", count: 64)
            ),
            actions: [PackAction(id: "hero-view", title: "Hero View", symbol: "viewfinder")],
            motion: PackMotion(supportsReducedMotion: true),
            signature: nil
        )
    }
}

@Suite("Private pack transport")
@MainActor
struct WallpaperResourceSchemeHandlerTests {
    @Test("Interface navigation permits only its first declared local main frame")
    func interfaceNavigationPolicy() {
        let entry = URL(string: "blank-canvas://interface/controls/interface.html")!
        var policy = WallpaperInterfaceNavigationPolicy(entryURL: entry)

        let first = policy.allowsNavigation(to: entry, isMainFrame: true)
        let repeatLoad = policy.allowsNavigation(to: entry, isMainFrame: true)
        let localSibling = policy.allowsNavigation(
            to: URL(string: "blank-canvas://interface/controls/help.html")!,
            isMainFrame: true
        )
        let subframe = policy.allowsNavigation(to: entry, isMainFrame: false)
        let remote = policy.allowsNavigation(to: URL(string: "https://example.com")!, isMainFrame: true)

        #expect(first)
        #expect(!repeatLoad)
        #expect(!localSibling)
        #expect(!subframe)
        #expect(!remote)
    }

    @Test("Wallpaper and interface resources use distinct origins and policies")
    func interfaceResourceIsolation() throws {
        let root = URL(fileURLWithPath: "/tmp/custom-world/content", isDirectory: true)
        let entry = root.appendingPathComponent("controls/interface.html")
        let interface = WallpaperResourceSchemeHandler(rootURL: root, surface: .interface)
        let wallpaper = WallpaperResourceSchemeHandler(rootURL: root, surface: .wallpaper)
        let interfaceURL = try #require(interface.pageURL(for: entry))

        #expect(interfaceURL.host == "interface")
        #expect(interface.resolve(interfaceURL) == entry)
        #expect(interface.resolve(URL(string: "blank-canvas://pack/controls/interface.html")!) == nil)
        #expect(interface.contentSecurityPolicy.contains("connect-src 'none'"))
        #expect(!interface.contentSecurityPolicy.contains("'unsafe-eval'"))
        #expect(wallpaper.contentSecurityPolicy.contains("connect-src 'self'"))
    }

    @Test("WASM and browser assets use explicit MIME types")
    func mimeTypes() {
        #expect(WallpaperResourceSchemeHandler.mimeType(forExtension: "wasm") == "application/wasm")
        #expect(WallpaperResourceSchemeHandler.mimeType(forExtension: "js") == "text/javascript")
        #expect(WallpaperResourceSchemeHandler.mimeType(forExtension: "css") == "text/css")
        #expect(WallpaperResourceSchemeHandler.mimeType(forExtension: "html") == "text/html")
    }
}
