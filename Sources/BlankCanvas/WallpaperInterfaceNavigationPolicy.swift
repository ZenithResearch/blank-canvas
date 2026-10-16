import Foundation

struct WallpaperInterfaceNavigationPolicy {
    private let entryURL: URL
    private var allowedInitialNavigation = false

    init(entryURL: URL) {
        self.entryURL = entryURL
    }

    mutating func allowsNavigation(to url: URL?, isMainFrame: Bool) -> Bool {
        guard !allowedInitialNavigation,
              isMainFrame,
              url == entryURL else { return false }
        allowedInitialNavigation = true
        return true
    }
}
