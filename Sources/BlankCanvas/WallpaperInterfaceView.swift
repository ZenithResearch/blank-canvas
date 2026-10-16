import AppKit
import os
import SwiftUI
import WebKit

@MainActor
struct WallpaperInterfaceView: NSViewRepresentable {
    let pack: InstalledPack
    let performAction: (String) -> Void
    let onFailure: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(pack: pack, performAction: performAction, onFailure: onFailure)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let resourceHandler = WallpaperResourceSchemeHandler(rootURL: pack.contentRoot, surface: .interface)
        configuration.setURLSchemeHandler(resourceHandler, forURLScheme: WallpaperResourceSchemeHandler.scheme)
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: WallpaperInterfaceBridge.bootstrapScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        configuration.userContentController.add(context.coordinator, name: WallpaperInterfaceBridge.messageHandlerName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear
        webView.setAccessibilityLabel("\(pack.manifest.id) wallpaper controls")

        guard let fileURL = pack.interfaceURL,
              let pageURL = resourceHandler.pageURL(for: fileURL) else {
            context.coordinator.fail()
            return webView
        }

        context.coordinator.attach(webView: webView, entryURL: pageURL)
        webView.load(URLRequest(url: pageURL))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.dismantle(webView)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
        private let declaredActionIDs: Set<String>
        private let performAction: (String) -> Void
        private let onFailure: () -> Void
        private var navigationPolicy: WallpaperInterfaceNavigationPolicy?
        private var isActive = false
        private var didFail = false
        private let logger = Logger(subsystem: "ca.zenith-research.blank-canvas", category: "wallpaper-interface")

        init(pack: InstalledPack, performAction: @escaping (String) -> Void, onFailure: @escaping () -> Void) {
            declaredActionIDs = Set(pack.manifest.actions.map(\.id))
            self.performAction = performAction
            self.onFailure = onFailure
        }

        func attach(webView: WKWebView, entryURL: URL) {
            navigationPolicy = WallpaperInterfaceNavigationPolicy(entryURL: entryURL)
            isActive = true
        }

        func fail() {
            guard !didFail else { return }
            didFail = true
            isActive = false
            onFailure()
        }

        func dismantle(_ webView: WKWebView) {
            isActive = false
            navigationPolicy = nil
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.configuration.userContentController.removeScriptMessageHandler(
                forName: WallpaperInterfaceBridge.messageHandlerName
            )
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard isActive,
                  message.name == WallpaperInterfaceBridge.messageHandlerName,
                  let actionID = WallpaperInterfaceBridge.actionID(
                    from: message.body,
                    declaredActionIDs: declaredActionIDs
                  ) else { return }
            logger.notice("Dispatching declared interface action \(actionID, privacy: .public)")
            performAction(actionID)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            let allowed = navigationPolicy?.allowsNavigation(
                to: navigationAction.request.url,
                isMainFrame: navigationAction.targetFrame?.isMainFrame == true
            ) ?? false
            decisionHandler(allowed ? .allow : .cancel)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: any Error
        ) {
            fail()
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: any Error
        ) {
            fail()
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            fail()
        }
    }
}
