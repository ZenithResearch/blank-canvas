import Foundation

enum WallpaperHostBridge {
    static let apiVersion = "1.0.0"

    static let bootstrapScript = #"""
    (() => {
      if (globalThis.zenithWallpaper) return;

      const target = new EventTarget();
      const listeners = new Map();
      const pendingNotifications = new Map();
      let sequence = 0;

      const post = payload => window.webkit?.messageHandlers?.zenithRuntime?.postMessage(payload);
      const listenersFor = type => {
        if (!listeners.has(type)) listeners.set(type, new Set());
        return listeners.get(type);
      };
      const receive = (type, detail = {}) => {
        if (type === "notification-result" && detail.requestId) {
          const pending = pendingNotifications.get(detail.requestId);
          if (pending) {
            window.clearTimeout(pending.timer);
            pendingNotifications.delete(detail.requestId);
            pending.resolve(detail);
          }
        }
        target.dispatchEvent(new CustomEvent(type, { detail }));
        return listenersFor(type).size > 0;
      };

      const api = {
        apiVersion: "1.0.0",
        capabilities: Object.freeze(["events", "notifications"]),
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
        requestNotification(notification = {}) {
          const requestId = `wallpaper-${Date.now()}-${++sequence}`;
          return new Promise(resolve => {
            const timer = window.setTimeout(() => {
              pendingNotifications.delete(requestId);
              resolve({ requestId, status: "unavailable", reason: "host-timeout" });
            }, 15000);
            pendingNotifications.set(requestId, { resolve, timer });
            post({ type: "notification-request", requestId, notification });
          });
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
