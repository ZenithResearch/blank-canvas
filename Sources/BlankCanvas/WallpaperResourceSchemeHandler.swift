import Foundation
import WebKit

@MainActor
final class WallpaperResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "blank-canvas"
    static let host = "pack"

    private let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              let resourceURL = resolve(requestURL),
              let data = try? Data(contentsOf: resourceURL) else {
            urlSchemeTask.didFailWithError(RuntimeError.invalidArchive("requested file is unavailable"))
            return
        }

        let extensionName = resourceURL.pathExtension
        let mimeType = Self.mimeType(forExtension: extensionName)
        let contentType = Self.isText(extensionName) ? "\(mimeType); charset=utf-8" : mimeType
        guard let response = HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": contentType,
                "Content-Length": String(data.count),
                "Cache-Control": "no-cache",
                "Content-Security-Policy": "default-src 'self' data: blob:; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self'; frame-src 'none'; object-src 'none'; base-uri 'none'",
            ]
        ) else {
            urlSchemeTask.didFailWithError(RuntimeError.invalidArchive("response creation failed"))
            return
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    func pageURL(for entryURL: URL) -> URL? {
        let rootPath = rootURL.path + "/"
        let entry = entryURL.standardizedFileURL
        guard entry.path.hasPrefix(rootPath) else { return nil }
        let relativePath = String(entry.path.dropFirst(rootPath.count))
        guard PackSecurity.validateRelativePath(relativePath) else { return nil }
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.path = "/" + relativePath
        return components.url
    }

    func resolve(_ requestURL: URL) -> URL? {
        guard requestURL.scheme == Self.scheme, requestURL.host == Self.host else { return nil }
        let relativePath = requestURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard PackSecurity.validateRelativePath(relativePath) else { return nil }
        let candidate = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        guard candidate.path.hasPrefix(rootURL.path + "/") else { return nil }
        return candidate
    }

    static func mimeType(forExtension rawExtension: String) -> String {
        switch rawExtension.lowercased() {
        case "html", "htm": "text/html"
        case "js", "mjs": "text/javascript"
        case "css": "text/css"
        case "wasm": "application/wasm"
        case "json", "map": "application/json"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "avif": "image/avif"
        case "webp": "image/webp"
        case "svg": "image/svg+xml"
        case "woff": "font/woff"
        case "woff2": "font/woff2"
        default: "application/octet-stream"
        }
    }

    private static func isText(_ rawExtension: String) -> Bool {
        ["html", "htm", "js", "mjs", "css", "json", "map", "svg"].contains(rawExtension.lowercased())
    }
}
