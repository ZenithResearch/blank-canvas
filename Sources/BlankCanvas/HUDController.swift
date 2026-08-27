import AppKit
import SwiftUI

@MainActor
final class HUDController {
    private let panel: NSPanel

    init(model: RuntimeModel, dismiss: @escaping () -> Void) {
        let hostingView = NSHostingView(rootView: HUDView(model: model, dismiss: dismiss))
        hostingView.frame = NSRect(x: 0, y: 0, width: 380, height: 590)
        panel = NSPanel(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.title = "blank-canvas"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
    }

    func show() {
        positionIfNeeded()
        panel.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func hide() { panel.orderOut(nil) }
    func toggle() { panel.isVisible ? hide() : show() }

    private func positionIfNeeded() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 24, y: visible.maxY - panel.frame.height - 24))
    }
}
