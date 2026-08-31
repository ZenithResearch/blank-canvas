import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: RuntimeModel?
    private var wallpaperController: WallpaperController?
    private var hudController: HUDController?
    private var statusItem: NSStatusItem?
    private var hudHotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let configuration = try RuntimeConfiguration.load()
            let model = try RuntimeModel(configuration: configuration)
            self.model = model
            model.activatePack = { [weak self] pack in self?.activate(pack) }
            model.performAction = { [weak self] action in self?.wallpaperController?.performAction(action) }

            hudController = HUDController(model: model) { [weak self] in self?.hudController?.hide() }
            setupStatusItem()
            hudHotKey = try GlobalHotKey(
                keyCode: UInt32(kVK_ANSI_H),
                modifiers: UInt32(cmdKey | optionKey)
            ) { [weak self] in self?.hudController?.toggle() }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(screenConfigurationChanged),
                name: NSApplication.didChangeScreenParametersNotification,
                object: nil
            )
            let workspaceNotifications = NSWorkspace.shared.notificationCenter
            workspaceNotifications.addObserver(
                self,
                selector: #selector(workspaceBecameHidden),
                name: NSWorkspace.screensDidSleepNotification,
                object: nil
            )
            workspaceNotifications.addObserver(
                self,
                selector: #selector(workspaceBecameHidden),
                name: NSWorkspace.sessionDidResignActiveNotification,
                object: nil
            )
            workspaceNotifications.addObserver(
                self,
                selector: #selector(workspaceBecameVisible),
                name: NSWorkspace.screensDidWakeNotification,
                object: nil
            )
            workspaceNotifications.addObserver(
                self,
                selector: #selector(workspaceBecameVisible),
                name: NSWorkspace.sessionDidBecomeActiveNotification,
                object: nil
            )
            hudController?.show()
            model.start()
        } catch {
            NSAlert(error: error).runModal()
            NSApplication.shared.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        wallpaperController?.stop()
    }

    private func activate(_ pack: InstalledPack) {
        wallpaperController?.stop()
        let controller = WallpaperController(pack: pack)
        wallpaperController = controller
        controller.start()
        controller.applyMotionPreference(reduced: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        controller.applyVisibility(true)
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "rectangle.on.rectangle.angled",
            accessibilityDescription: "blank-canvas"
        )
        let menu = NSMenu()
        menu.addItem(withTitle: "Toggle Controls  ⌥⌘H", action: #selector(toggleControls), keyEquivalent: "")
        menu.addItem(withTitle: "Check for Wallpapers", action: #selector(refreshCatalog), keyEquivalent: "r")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit blank-canvas", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleControls() { hudController?.toggle() }
    @objc private func refreshCatalog() { model?.refreshAll() }
    @objc private func screenConfigurationChanged() { wallpaperController?.rebuildSurfaces() }
    @objc private func workspaceBecameHidden() { wallpaperController?.applyVisibility(false) }
    @objc private func workspaceBecameVisible() { wallpaperController?.applyVisibility(true) }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
