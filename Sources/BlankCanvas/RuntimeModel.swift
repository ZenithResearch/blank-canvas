import AppKit
import Foundation
import os

@MainActor
final class RuntimeModel: ObservableObject {
    @Published private(set) var catalog: WallpaperCatalog?
    @Published private(set) var installedPack: InstalledPack?
    @Published private(set) var status = "Connecting to the wallpaper catalog…"
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    let configuration: RuntimeConfiguration

    var activatePack: ((InstalledPack) -> Void)?
    var performAction: ((String) -> Void)?

    private let client: CatalogClient
    private let store: PackStore
    private let installer: PackInstaller
    private let publicKeyData: Data
    private let logger = Logger(subsystem: "ca.zenith-research.blank-canvas", category: "runtime")

    init(configuration: RuntimeConfiguration) throws {
        self.configuration = configuration
        client = CatalogClient(configuration: configuration)
        store = try PackStore(namespace: configuration.cacheNamespace, defaultsPrefix: configuration.defaultsPrefix)
        let keyURL = Bundle.main.url(forResource: "WallpaperPublicKey", withExtension: "txt")
        guard let keyURL,
              let encoded = try? String(contentsOf: keyURL, encoding: .utf8),
              let publicKey = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw RuntimeError.missingPublicKey
        }
        publicKeyData = publicKey
        installer = PackInstaller(client: client, store: store, publicKeyData: publicKey)
    }

    var featuredPack: CatalogPack? {
        catalog?.packs.first(where: \.featured) ?? catalog?.packs.first
    }

    func start() {
        if let selected = try? store.selectedPack(),
           (try? PackSecurity.verify(manifest: selected.manifest, publicKeyData: publicKeyData)) != nil {
            installedPack = selected
            status = "\(selected.manifest.id) \(selected.manifest.version) · ready offline"
            activatePack?(selected)
            logger.notice("Activated cached pack \(selected.manifest.id, privacy: .public)@\(selected.manifest.version, privacy: .public)")
        } else {
            logger.notice("No cached wallpaper selected; showing the native empty state")
        }
        refreshCatalog()
    }

    func refreshCatalog() {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        if installedPack == nil { status = "Connecting to the wallpaper catalog…" }
        Task {
            do {
                let catalog = try await client.fetchCatalog()
                self.catalog = catalog
                if let installedPack {
                    self.status = "\(installedPack.manifest.id) \(installedPack.manifest.version) · catalog current"
                } else if catalog.packs.isEmpty {
                    self.status = "Catalog connected · no published worlds"
                } else {
                    self.status = "Choose a world to begin"
                }
                self.logger.notice(
                    "Catalog loaded from \(self.configuration.catalogURL.absoluteString, privacy: .public) with \(catalog.packs.count) pack(s)"
                )
            } catch {
                self.errorMessage = error.localizedDescription
                self.status = installedPack == nil ? "Catalog unavailable" : "Offline · using downloaded world"
                self.logger.error("Catalog refresh failed: \(error.localizedDescription, privacy: .public)")
            }
            self.isBusy = false
        }
    }

    func installFeaturedPack() {
        guard let pack = featuredPack else { return }
        install(pack)
    }

    func install(_ pack: CatalogPack) {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        status = "Downloading and verifying \(pack.title)…"
        Task {
            do {
                let installed = try await installer.install(pack)
                self.installedPack = installed
                self.status = "\(pack.title) \(installed.manifest.version) · installed"
                self.activatePack?(installed)
                self.logger.notice("Installed pack \(installed.manifest.id, privacy: .public)@\(installed.manifest.version, privacy: .public)")
            } catch {
                self.errorMessage = error.localizedDescription
                self.status = "Installation failed"
            }
            self.isBusy = false
        }
    }

    func isActive(_ pack: CatalogPack) -> Bool {
        installedPack?.manifest.id == pack.id && installedPack?.manifest.version == pack.currentVersion
    }

    func isDownloaded(_ pack: CatalogPack) -> Bool {
        (try? store.installedPack(id: pack.id, version: pack.currentVersion)) != nil
    }

    func runAction(_ id: String) {
        performAction?(id)
    }

    func openGallery() {
        NSWorkspace.shared.open(configuration.galleryURL)
    }
}
