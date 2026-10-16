# Blank Canvas wallpaper host API

Blank Canvas injects `globalThis.zenithWallpaper` before wallpaper JavaScript runs. The additive API is the common runtime boundary between the macOS host and every wallpaper. Wallpapers should continue to expose `globalThis.wallpaperHost` while migrating; Blank Canvas uses it as the legacy fallback when no standard event listener is registered.

## Runtime events

```js
const host = globalThis.zenithWallpaper;

host.addEventListener("preferences-change", ({ detail }) => {
  setReducedMotion(Boolean(detail.reducedMotion));
});

host.addEventListener("action", ({ detail }) => {
  runAction(detail.id);
});

host.addEventListener("visibility-change", ({ detail }) => {
  setAnimationRunning(detail.visible);
});

host.ready({ apiVersion: "1.0", capabilities: ["webgl2"] });
```

| Event | Detail |
| --- | --- |
| `host-ready` | `{ hostApiVersion, wallpaperApiVersion, capabilities }` |
| `preferences-change` | `{ reducedMotion }` |
| `action` | `{ id }` |
| `visibility-change` | `{ visible }` |

`on(type, listener)` returns an unsubscribe function. `off`, `addEventListener`, and `removeEventListener` are also available.

## Pull-only wallpaper updates

Update messages are not runtime events and wallpaper JavaScript cannot post them. A wallpaper opts in by placing a read-only endpoint in its signed manifest:

```json
{
  "notifications": {
    "feedURL": "https://zenith-research.ca/wallpapers/v1/notifications/starward-loggia.json",
    "format": "zenith-json-v1",
    "pollIntervalMinutes": 15
  }
}
```

The endpoint returns:

```json
{
  "schemaVersion": 1,
  "wallpaperID": "starward-loggia",
  "generatedAt": "2026-08-31T09:27:58Z",
  "items": [{
    "id": "release-1.0.2",
    "publishedAt": "2026-08-31T09:27:58Z",
    "title": "A new view is ready",
    "body": "The Loggia lighting has been refined.",
    "url": "https://zenith-research.ca/wallpapers"
  }]
}
```

The private wallpaper repository publishes this document to `POST /api/admin/wallpapers/notifications` using a short-lived GitHub OIDC identity. Zenith exposes it as a cacheable, CORS-enabled GET endpoint. A repository may write only its own wallpaper ID.

In Blank Canvas, **Pull wallpaper updates** is off by default. When enabled, the app checks the endpoints declared by installed, signature-verified packs and presents messages in its in-app inbox. It does not register for push, request macOS notification permission, or let wallpaper content contact a privileged native notification API.

`requestNotification()` is retained only so older experiments fail safely. It always resolves to `{ status: "unavailable", reason: "publish-to-declared-feed" }`.

## Optional wallpaper-provided controls

Runtime 2.1 adds an optional signed interface declaration. Packs without it continue to use Blank Canvas’s native action grid.

```json
{
  "runtime": {
    "api": "zenith-wallpaper-host",
    "minimumVersion": "2.1.0",
    "maximumExclusiveVersion": "3.0.0"
  },
  "interface": {
    "version": 1,
    "entry": "controls/interface.html",
    "height": 220
  }
}
```

Version 1 accepts a safe pack-relative `.html` entry and a height from 96 through 360 points. The file must be present in the signed archive and remains under the verified extracted content root. Existing digest, signature, archive-path, and link checks still apply.

Blank Canvas renders this entry in a dedicated non-persistent `WKWebView` at the isolated `blank-canvas://interface/` origin. On supported macOS releases WebKit manages the process model because explicit `WKProcessPool` selection is deprecated and has no isolation effect. Its CSP sets `connect-src 'none'`, denies frames, objects, forms, and base URLs, and does not allow `unsafe-eval`. Only the first main-frame navigation to the declared entry is allowed. Popups, subsequent navigations, subframes, HTTP, and HTTPS are denied.

The interface receives one frozen API at document start:

```js
const accepted = globalThis.zenithWallpaperInterface.performAction("ring-bell");
```

`performAction` accepts a non-empty string of at most 128 UTF-8 bytes. Native code revalidates the exact two-field message and dispatches only action IDs listed in the signed manifest. Version 1 has no state channel, dynamic resizing, filesystem access, credential access, general native messaging, or arbitrary view injection.

The interface message handler, delegates, pending navigation policy, and page load are torn down when SwiftUI removes the view, including pack/version switches and HUD replacement. Load failures and WebKit content-process termination are scoped to that exact pack version and restore the native action grid. A different version remains eligible for its own interface.

Interface authors should use semantic HTML, visible keyboard focus, sufficient contrast, descriptive labels, and `prefers-reduced-motion`. Controls must remain operable at the declared fixed height. Interface files must not contain credentials or rely on a network connection.

## Compatibility

- Host API 1.1 is additive to runtime 2.x and feature-detectable through `globalThis.zenithWallpaper`.
- Older packs that only implement `globalThis.wallpaperHost` remain supported.
- New packs should register event listeners before calling `ready`.
- Unknown events, capabilities, and optional manifest fields must be ignored.
