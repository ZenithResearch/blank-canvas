# blank-canvas

A native macOS wallpaper runtime with no bundled wallpapers. It discovers signed packs at `https://zenith-research.ca/wallpapers/v1/catalog.json`, verifies and installs them locally, then renders them behind desktop icons through an isolated WebKit origin.

Wallpaper developers integrate through the additive [`zenithWallpaper` host event API](docs/WALLPAPER-HOST-API.md). It standardizes app actions, preferences, lifecycle readiness, and user-controlled local notification requests while preserving the original `window.wallpaperHost` fallback.

The application icon is generated reproducibly from `Resources/BlankCanvasIcon.svg`:

```sh
zsh scripts/build-icon.sh
```

Build with:

```sh
zsh scripts/build-app.sh
```

The release ZIP is written to `dist/blank-canvas-2.0.0-macOS.zip`. The app bundle contains only the executable and the public wallpaper-signing key. Publish that artifact through the Zenith landing-site release workflow; wallpaper packs remain in their own repositories.

Local builds are ad-hoc signed. Public downloads must use a Developer ID Application identity and a stored `notarytool` profile so Gatekeeper can verify them:

```sh
export BLANK_CANVAS_SIGNING_IDENTITY="Developer ID Application: Zenith Research (…)"
export BLANK_CANVAS_NOTARY_PROFILE="blank-canvas-notary"
export BLANK_CANVAS_EXPECTED_TEAM_ID="…"
zsh scripts/build-app.sh
zsh scripts/build-staging-app.sh
```

The scripts enable the hardened runtime, submit each ZIP to Apple, staple the notarization ticket to the app, and recreate the distributable ZIP. Do not publish the ad-hoc local artifacts from `dist/`.

Use the same Developer ID Application certificate and Apple Team Identifier as Hypha. The build fails if the signed Team Identifier differs, ensuring both applications resolve to the same Apple-verified developer identity once notarized. There is no persistent “known developer” identity for ad-hoc signatures; those releases remain per-app Gatekeeper exceptions.

The manual `Notarized macOS release` GitHub Actions workflow performs the same operation on a clean macOS runner. It requires these repository secrets: `MACOS_CERTIFICATE_P12_BASE64`, `MACOS_CERTIFICATE_PASSWORD`, `MACOS_KEYCHAIN_PASSWORD`, `MACOS_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, and `APPLE_TEAM_ID`.

## Temporary ad-hoc release

Until those credentials are available, produce the explicitly non-distributable release boundary with:

```sh
BLANK_CANVAS_RELEASE_MODE=adhoc \
BLANK_CANVAS_ALLOW_NON_DISTRIBUTABLE_RELEASE=1 \
zsh scripts/package-release.sh
```

This generates both ZIPs, machine-readable release metadata, and `SHA256SUMS`. The metadata must report `mode: adhoc`, `notarized: false`, and `distributable: false`; the website must display [the required Gatekeeper notice](release/ADHOC_RELEASE_NOTICE.md) beside these downloads.

## Staging

Build a separate, visibly labelled staging app with an isolated cache and bundle identifier:

```sh
zsh scripts/build-staging-app.sh
```

The downloadable staging ZIP is written to `dist/blank-canvas-staging-2.0.0-macOS.zip`. It always reads `https://zenith-research.ca/wallpapers/v1/staging/catalog.json`; no Vercel preview hostname is embedded.

## Development mode

Launch the renderer against the local catalogue at `http://127.0.0.1:3001`:

```sh
zsh scripts/launch-dev-mode.sh
```

Development mode permits plain HTTP only for `localhost` and `127.0.0.1`. An alternate loopback URL can be passed as the first argument. Pack signature, SHA-256, byte-length, path, and runtime checks remain enabled. The legacy `launch-test-mode.sh` and `--test-mode` flag remain aliases for development mode.

The modes are intentionally isolated: production uses the production catalogue and cache, staging uses the stable hosted staging catalogue and staging cache, and development uses only a loopback catalogue and development cache. Catalogue overrides are rejected outside development mode.
