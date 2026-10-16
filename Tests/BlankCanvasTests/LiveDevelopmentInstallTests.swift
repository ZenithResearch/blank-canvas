import Foundation
import Testing
@testable import BlankCanvas

@Suite("Live development pack installation")
struct LiveDevelopmentInstallTests {
    @Test(
        "A served development pack installs through the production verifier",
        .enabled(if: ProcessInfo.processInfo.environment["BLANK_CANVAS_LIVE_CATALOG"] != nil)
    )
    func installServedDevelopmentPack() async throws {
        let environment = ProcessInfo.processInfo.environment
        let catalogValue = try #require(environment["BLANK_CANVAS_LIVE_CATALOG"])
        let publicKeyPath = try #require(environment["BLANK_CANVAS_LIVE_PUBLIC_KEY"])
        let storePath = try #require(environment["BLANK_CANVAS_LIVE_STORE"])
        let configuration = try RuntimeConfiguration.load(
            bundleValues: [:],
            environment: [:],
            arguments: ["BlankCanvasTests", "--dev-mode", "--catalog-url", catalogValue]
        )
        let client = CatalogClient(configuration: configuration)
        let catalog = try await client.fetchCatalog()
        let pack = try #require(catalog.packs.first(where: { $0.id == "delvetalk-town" }))
        let encodedKey = try String(contentsOfFile: publicKeyPath, encoding: .utf8)
        let publicKey = try #require(Data(base64Encoded: encodedKey.trimmingCharacters(in: .whitespacesAndNewlines)))
        let store = try PackStore(
            rootURL: URL(fileURLWithPath: storePath, isDirectory: true),
            defaultsPrefix: "development."
        )
        let installer = PackInstaller(client: client, store: store, publicKeyData: publicKey)
        let installed = try await installer.install(pack)

        #expect(installed.manifest.id == "delvetalk-town")
        #expect(installed.manifest.version == "0.4.0")
        #expect(installed.manifest.interface?.version == 1)
        #expect(installed.manifest.interface?.entry == "controls/interface.html")
        #expect(installed.manifest.interface?.height == 220)
        #expect(installed.interfaceURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
    }
}
