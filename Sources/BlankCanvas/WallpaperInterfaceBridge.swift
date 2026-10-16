import Foundation

enum WallpaperInterfaceBridge {
    static let apiVersion = "1.0.0"
    static let messageHandlerName = "zenithInterface"
    static let maximumActionIDLength = 128

    static let bootstrapScript = #"""
    (() => {
      if (globalThis.zenithWallpaperInterface) return;
      const post = id => window.webkit?.messageHandlers?.zenithInterface?.postMessage({
        type: "perform-action",
        id,
      });
      const api = {
        apiVersion: "1.0.0",
        performAction(id) {
          if (typeof id !== "string" || id.length === 0 || id.length > 128) return false;
          post(id);
          return true;
        },
      };
      Object.freeze(api);
      Object.defineProperty(globalThis, "zenithWallpaperInterface", {
        configurable: false,
        enumerable: true,
        writable: false,
        value: api,
      });
    })();
    """#

    static func actionID(from body: Any, declaredActionIDs: Set<String>) -> String? {
        guard let message = body as? [String: Any],
              message.count == 2,
              message["type"] as? String == "perform-action",
              let actionID = message["id"] as? String,
              !actionID.isEmpty,
              actionID.utf8.count <= maximumActionIDLength,
              declaredActionIDs.contains(actionID) else { return nil }
        return actionID
    }
}
