import AppKit
import CoreGraphics
import Foundation
import os
import WebKit

@MainActor
final class WallpaperController {
    private var surfaces: [WallpaperSurface] = []
    private(set) var pack: InstalledPack

    init(pack: InstalledPack) {
        self.pack = pack
    }

    func start() {
        rebuildSurfaces()
    }

    func rebuildSurfaces() {
        surfaces.forEach { $0.close() }
        surfaces = NSScreen.screens.map { WallpaperSurface(screen: $0, pack: pack) }
    }

    func performAction(_ action: String) {
        surfaces.forEach { $0.performAction(action) }
    }

    func applyMotionPreference(reduced: Bool) {
        surfaces.forEach { $0.applyPreferences(reducedMotion: reduced) }
    }

    func stop() {
        surfaces.forEach { $0.close() }
        surfaces = []
    }
}

@MainActor
private final class WallpaperSurface: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let window: NSWindow
    private let webView: WKWebView
    private let resourceHandler: WallpaperResourceSchemeHandler
    private let logger: Logger

    init(screen: NSScreen, pack: InstalledPack) {
        logger = Logger(subsystem: "ca.zenith-research.blank-canvas", category: "pack.\(pack.manifest.id)")
        let configuration = WKWebViewConfiguration()
        let handler = WallpaperResourceSchemeHandler(rootURL: pack.contentRoot)
        resourceHandler = handler
        configuration.setURLSchemeHandler(handler, forURLScheme: WallpaperResourceSchemeHandler.scheme)
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: """
                document.documentElement?.setAttribute('data-wallpaper', 'true');
                if (typeof WebAssembly === 'object') WebAssembly.instantiateStreaming = undefined;
                """,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: """
                (() => {
                  const report = (type, value) => {
                    const message = value instanceof Error ? value.stack || value.message : String(value ?? 'unknown');
                    window.webkit?.messageHandlers?.zenithRuntime?.postMessage({ type, message });
                  };
                  window.addEventListener('error', event => report('fatal-error', event.error || event.message));
                  window.addEventListener('unhandledrejection', event => report('fatal-error', event.reason));
                })();
                """,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        configuration.preferences.isElementFullscreenEnabled = false
        webView = WKWebView(frame: screen.frame, configuration: configuration)
        window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )

        super.init()
        configuration.userContentController.add(self, name: "zenithRuntime")
        webView.navigationDelegate = self
        window.contentView = webView
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()

        if let pageURL = handler.pageURL(for: pack.entryURL) {
            webView.load(URLRequest(url: pageURL))
        }
    }

    func close() {
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "zenithRuntime")
        window.orderOut(nil)
        window.close()
    }

    func performAction(_ action: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: action, options: .fragmentsAllowed),
              let json = String(data: data, encoding: .utf8) else { return }
        evaluateWhenReady("api.performAction(\(json));")
    }

    func applyPreferences(reducedMotion: Bool) {
        evaluateWhenReady("api.applyPreferences?.({ reducedMotion: \(reducedMotion ? "true" : "false") });")
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let allowed = navigationAction.request.url?.scheme == WallpaperResourceSchemeHandler.scheme
        decisionHandler(allowed ? .allow : .cancel)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let detail = body["message"] as? String ?? String(describing: body)
        if type == "fatal-error" {
            logger.error("[\(type, privacy: .public)] \(detail, privacy: .public)")
        } else {
            logger.notice("[\(type, privacy: .public)] \(detail, privacy: .public)")
        }
    }

    private func evaluateWhenReady(_ command: String) {
        webView.evaluateJavaScript(
            """
            (() => {
              let attempts = 0;
              const run = () => {
                const api = window.wallpaperHost;
                if (api) { \(command) }
                else if (attempts++ < 200) window.setTimeout(run, 50);
              };
              run();
            })();
            """
        )
    }
}
