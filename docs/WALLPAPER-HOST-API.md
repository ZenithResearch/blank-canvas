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

## Compatibility

- Host API 1.1 is additive to runtime 2.x and feature-detectable through `globalThis.zenithWallpaper`.
- Older packs that only implement `globalThis.wallpaperHost` remain supported.
- New packs should register event listeners before calling `ready`.
- Unknown events, capabilities, and optional manifest fields must be ignored.
