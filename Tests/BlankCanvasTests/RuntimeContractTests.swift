import CryptoKit
import Foundation
import Testing
@testable import BlankCanvas

@Suite("blank-canvas contracts")
struct RuntimeContractTests {
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

    @Test("The host bridge exposes additive events and guarded notification requests")
    func hostBridgeContract() {
        #expect(WallpaperHostBridge.apiVersion == "1.0.0")
        #expect(WallpaperHostBridge.bootstrapScript.contains("globalThis.zenithWallpaper"))
        #expect(WallpaperHostBridge.bootstrapScript.contains("requestNotification"))
        #expect(WallpaperHostBridge.bootstrapScript.contains("notification-result"))
        #expect(WallpaperHostBridge.json("action") == "\"action\"")
    }

    @Test("Wallpaper notifications validate content and rate-limit each pack")
    func notificationContract() throws {
        let first = try WallpaperNotificationRequest(
            message: [
                "requestId": "request-1",
                "notification": ["title": "Starfall", "body": "The current is bright.", "tag": "starfall"],
            ],
            packID: "starward-loggia"
        )
        #expect(first.title == "Starfall")
        #expect(first.body == "The current is bright.")

        #expect(throws: WallpaperNotificationValidationError.self) {
            try WallpaperNotificationRequest(
                message: [
                    "requestId": "request-2",
                    "notification": ["title": String(repeating: "x", count: 81)],
                ],
                packID: "starward-loggia"
            )
        }

        var gate = WallpaperNotificationGate(minimumInterval: 60)
        let now = Date(timeIntervalSince1970: 1_000)
        let firstAllowed = gate.permits(first, now: now)
        let duplicateAllowed = gate.permits(first, now: now.addingTimeInterval(61))
        #expect(firstAllowed)
        #expect(!duplicateAllowed)
        let second = try WallpaperNotificationRequest(
            message: ["requestId": "request-3", "notification": ["title": "Again"]],
            packID: "starward-loggia"
        )
        let secondAllowed = gate.permits(second, now: now.addingTimeInterval(30))
        #expect(!secondAllowed)
        let third = try WallpaperNotificationRequest(
            message: ["requestId": "request-4", "notification": ["title": "Later"]],
            packID: "starward-loggia"
        )
        let thirdAllowed = gate.permits(third, now: now.addingTimeInterval(61))
        #expect(thirdAllowed)
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
    @Test("WASM and browser assets use explicit MIME types")
    func mimeTypes() {
        #expect(WallpaperResourceSchemeHandler.mimeType(forExtension: "wasm") == "application/wasm")
        #expect(WallpaperResourceSchemeHandler.mimeType(forExtension: "js") == "text/javascript")
        #expect(WallpaperResourceSchemeHandler.mimeType(forExtension: "css") == "text/css")
        #expect(WallpaperResourceSchemeHandler.mimeType(forExtension: "html") == "text/html")
    }
}
