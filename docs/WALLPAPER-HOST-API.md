# Blank Canvas wallpaper host API

Blank Canvas injects `globalThis.zenithWallpaper` before wallpaper JavaScript runs. The additive v1 API is the common boundary between the macOS host and every wallpaper. Wallpapers should continue to expose `globalThis.wallpaperHost` while migrating; Blank Canvas uses it as the legacy fallback when no standard event listener is registered.

## Connect to host events

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

host.addEventListener("notification-state", ({ detail }) => {
  console.log(detail.enabled, detail.authorization);
});

host.ready({ apiVersion: "1.0", capabilities: ["webgl2"] });
```

The event names and detail payloads are:

| Event | Detail |
| --- | --- |
| `host-ready` | `{ hostApiVersion, wallpaperApiVersion, capabilities }` |
| `preferences-change` | `{ reducedMotion }` |
| `action` | `{ id }` |
| `visibility-change` | `{ visible }` |
| `notification-state` | `{ enabled, authorization }` |
| `notification-result` | `{ requestId, status, reason? }` |

`on(type, listener)` returns an unsubscribe function. `off`, `addEventListener`, and `removeEventListener` are also available.

## Request a notification

```js
const result = await globalThis.zenithWallpaper.requestNotification({
  title: "Starfall is beginning",
  body: "A silver current is crossing the eastern sky.",
  tag: "starfall",
});
```

Wallpaper code never asks macOS for notification permission. The person using Blank Canvas controls permission with the **Wallpaper notifications** switch in the app. Requests are plain local alerts: title is limited to 80 characters, body to 240 characters, and tag to 64 identifier characters. URLs, scripts, custom actions, sound, and remote push tokens are not accepted. Blank Canvas permits at most one delivered alert per wallpaper per minute and deduplicates request IDs across displays.

The returned status is one of `delivered`, `disabled`, `denied`, `rate-limited`, `invalid`, `failed`, or `unavailable`. Treat every request as optional; wallpaper visuals must work when notifications are off.

## Browser development

The producer template includes `src/zenith-wallpaper.js`. It supplies the same event surface in an ordinary browser and returns `{ status: "unavailable", reason: "native-host-required" }` for notification requests. This keeps local previews deterministic without simulating OS permission.

## Compatibility

- Host API v1 is additive to runtime 2.x and feature-detectable through `globalThis.zenithWallpaper`.
- Older packs that only implement `globalThis.wallpaperHost` remain supported.
- New packs should register event listeners before calling `ready`.
- Unknown events and capabilities must be ignored.
