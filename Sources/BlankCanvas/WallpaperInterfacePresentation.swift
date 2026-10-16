enum WallpaperInterfacePresentation {
    static func identity(for pack: InstalledPack) -> String {
        "\(pack.manifest.id)@\(pack.manifest.version)"
    }

    static func usesCustomInterface(_ pack: InstalledPack, failedIdentity: String?) -> Bool {
        pack.manifest.interface != nil && failedIdentity != identity(for: pack)
    }
}
