import AppKit
import CoreGraphics
import Foundation
import os
import WebKit

@MainActor
final class WallpaperController {
    private var surfaces: [WallpaperSurface] = []
    private var notificationState: WallpaperNotificationState
    private let notificationHandler: (WallpaperNotificationRequest) -> Void
    private var reducedMotion = false
    private var visible = true
    private(set) var pack: InstalledPack

    init(
        pack: InstalledPack,
        notificationState: WallpaperNotificationState,
        notificationHandler: @escaping (WallpaperNotificationRequest) -> Void
    ) {
        self.pack = pack
        self.notificationState = notificationState
        self.notificationHandler = notificationHandler
    }

    func start() {
        rebuildSurfaces()
    }

    func rebuildSurfaces() {
        surfaces.forEach { $0.close() }
        surfaces = NSScreen.screens.map {
            WallpaperSurface(
                screen: $0,
                pack: pack,
                notificationState: notificationState,
                notificationHandler: notificationHandler
            )
        }
        surfaces.forEach {
            $0.applyPreferences(reducedMotion: reducedMotion)
            $0.applyVisibility(visible)
        }
    }

    func performAction(_ action: String) {
        surfaces.forEach { $0.performAction(action) }
    }

    func applyMotionPreference(reduced: Bool) {
        reducedMotion = reduced
        surfaces.forEach { $0.applyPreferences(reducedMotion: reduced) }
    }

    func applyVisibility(_ visible: Bool) {
        self.visible = visible
        surfaces.forEach { $0.applyVisibility(visible) }
    }

    func applyNotificationState(_ state: WallpaperNotificationState) {
        notificationState = state
        surfaces.forEach { $0.applyNotificationState(state) }
    }

    func applyNotificationResult(_ result: WallpaperNotificationResult) {
        surfaces.forEach { $0.applyNotificationResult(result) }
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
    private let packID: String
    private let notificationHandler: (WallpaperNotificationRequest) -> Void
    private var notificationState: WallpaperNotificationState

    init(
        screen: NSScreen,
        pack: InstalledPack,
        notificationState: WallpaperNotificationState,
        notificationHandler: @escaping (WallpaperNotificationRequest) -> Void
    ) {
        logger = Logger(subsystem: "ca.zenith-research.blank-canvas", category: "pack.\(pack.manifest.id)")
        packID = pack.manifest.id
        self.notificationState = notificationState
        self.notificationHandler = notificationHandler
        let configuration = WKWebViewConfiguration()
        let handler = WallpaperResourceSchemeHandler(rootURL: pack.contentRoot)
        resourceHandler = handler
        configuration.setURLSchemeHandler(handler, forURLScheme: WallpaperResourceSchemeHandler.scheme)
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: WallpaperHostBridge.bootstrapScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
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
        evaluateWhenReady(
            """
            const handled = globalThis.zenithWallpaper?.__dispatch('action', { id: \(json) }) ?? false;
            if (!handled) api.performAction?.(\(json));
            """
        )
    }

    func applyPreferences(reducedMotion: Bool) {
        evaluateWhenReady(
            """
            const preferences = { reducedMotion: \(reducedMotion ? "true" : "false") };
            const handled = globalThis.zenithWallpaper?.__dispatch('preferences-change', preferences) ?? false;
            if (!handled) api.applyPreferences?.(preferences);
            """
        )
    }

    func applyVisibility(_ visible: Bool) {
        evaluateWhenReady(
            """
            const visibility = { visible: \(visible ? "true" : "false") };
            const handled = globalThis.zenithWallpaper?.__dispatch('visibility-change', visibility) ?? false;
            if (!handled) api.setVisible?.(visibility.visible);
            """
        )
    }

    func applyNotificationState(_ state: WallpaperNotificationState) {
        notificationState = state
        dispatchHostEvent("notification-state", detail: state.eventDetail)
    }

    func applyNotificationResult(_ result: WallpaperNotificationResult) {
        dispatchHostEvent("notification-result", detail: result.eventDetail)
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
        if type == "notification-request" {
            do {
                notificationHandler(try WallpaperNotificationRequest(message: body, packID: packID))
            } catch {
                if let requestID = body["requestId"] as? String {
                    applyNotificationResult(WallpaperNotificationResult(
                        requestID: requestID,
                        status: "invalid",
                        reason: "invalid-payload"
                    ))
                }
                logger.error("[notification-request] rejected invalid payload")
            }
            return
        }
        if type == "ready" {
            let capabilities = body["capabilities"] as? [String] ?? []
            dispatchHostEvent("host-ready", detail: [
                "hostApiVersion": WallpaperHostBridge.apiVersion,
                "wallpaperApiVersion": body["apiVersion"] as? String ?? "unknown",
                "capabilities": capabilities,
            ])
            applyNotificationState(notificationState)
        }
        let detail = body["message"] as? String ?? String(describing: body)
        if type == "fatal-error" {
            logger.error("[\(type, privacy: .public)] \(detail, privacy: .public)")
        } else {
            logger.notice("[\(type, privacy: .public)] \(detail, privacy: .public)")
        }
    }

    private func dispatchHostEvent(_ type: String, detail: [String: Any]) {
        guard let typeJSON = WallpaperHostBridge.json(type),
              let detailJSON = WallpaperHostBridge.json(detail) else { return }
        webView.evaluateJavaScript(
            "globalThis.zenithWallpaper?.__dispatch(\(typeJSON), \(detailJSON));"
        )
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
