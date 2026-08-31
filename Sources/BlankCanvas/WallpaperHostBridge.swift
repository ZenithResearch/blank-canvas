import Foundation

enum WallpaperHostBridge {
    static let apiVersion = "1.1.0"

    static let bootstrapScript = #"""
    (() => {
      if (globalThis.zenithWallpaper) return;

      const target = new EventTarget();
      const listeners = new Map();
      const post = payload => window.webkit?.messageHandlers?.zenithRuntime?.postMessage(payload);
      const listenersFor = type => {
        if (!listeners.has(type)) listeners.set(type, new Set());
        return listeners.get(type);
      };
      const receive = (type, detail = {}) => {
        target.dispatchEvent(new CustomEvent(type, { detail }));
        return listenersFor(type).size > 0;
      };

      const api = {
        apiVersion: "1.1.0",
        capabilities: Object.freeze(["events", "notification-feeds"]),
        addEventListener(type, listener, options) {
          if (typeof listener !== "function") return;
          listenersFor(type).add(listener);
          target.addEventListener(type, listener, options);
        },
        removeEventListener(type, listener, options) {
          if (typeof listener !== "function") return;
          listenersFor(type).delete(listener);
          target.removeEventListener(type, listener, options);
        },
        on(type, listener, options) {
          api.addEventListener(type, listener, options);
          return () => api.removeEventListener(type, listener, options);
        },
        off(type, listener, options) {
          api.removeEventListener(type, listener, options);
        },
        ready(metadata = {}) {
          post({
            type: "ready",
            apiVersion: metadata.apiVersion ?? "1.0",
            capabilities: Array.isArray(metadata.capabilities) ? metadata.capabilities : [],
          });
        },
        async requestNotification() {
          return { status: "unavailable", reason: "publish-to-declared-feed" };
        },
      };

      Object.defineProperties(api, {
        __dispatch: { value: receive },
        __hasListeners: { value: type => listenersFor(type).size > 0 },
      });
      Object.freeze(api);
      Object.defineProperty(globalThis, "zenithWallpaper", {
        configurable: false,
        enumerable: true,
        writable: false,
        value: api,
      });
    })();
    """#

    static func json(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }
}
