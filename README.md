# blank-canvas

A native macOS wallpaper runtime with no bundled wallpapers. It discovers signed packs at `https://zenith-research.ca/wallpapers/v1/catalog.json`, verifies and installs them locally, then renders them behind desktop icons through an isolated WebKit origin.

Build with:

```sh
zsh scripts/build-app.sh
```

The release ZIP is written to `dist/blank-canvas-2.0.0-macOS.zip`. The app bundle contains only the executable and the public wallpaper-signing key. Publish that artifact through the Zenith landing-site release workflow; wallpaper packs remain in their own repositories.

Local builds are ad-hoc signed. Public downloads must use a Developer ID Application identity and a stored `notarytool` profile so Gatekeeper can verify them:

```sh
export BLANK_CANVAS_SIGNING_IDENTITY="Developer ID Application: Zenith Research (…)"
export BLANK_CANVAS_NOTARY_PROFILE="blank-canvas-notary"
zsh scripts/build-app.sh
zsh scripts/build-staging-app.sh
```

The scripts enable the hardened runtime, submit each ZIP to Apple, staple the notarization ticket to the app, and recreate the distributable ZIP. Do not publish the ad-hoc local artifacts from `dist/`.

The manual `Notarized macOS release` GitHub Actions workflow performs the same operation on a clean macOS runner. It requires these repository secrets: `MACOS_CERTIFICATE_P12_BASE64`, `MACOS_CERTIFICATE_PASSWORD`, `MACOS_KEYCHAIN_PASSWORD`, `MACOS_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, and `APPLE_TEAM_ID`.

## Test mode

Build a separate, visibly labelled staging app with an isolated cache and bundle identifier:

```sh
zsh scripts/build-staging-app.sh
```

The downloadable staging ZIP is written to `dist/blank-canvas-staging-2.0.0-macOS.zip`. It always reads `https://zenith-research.ca/wallpapers/v1/staging/catalog.json`; no Vercel preview hostname is embedded.

Launch it against the local production build:

```sh
zsh scripts/launch-test-mode.sh \
  http://127.0.0.1:3001/wallpapers/v1/catalog.json
```

Test mode permits plain HTTP only for `localhost` and `127.0.0.1`. All catalog, manifest, preview, and archive URLs must still use either the exact selected staging origin or the production Zenith origin. Pack signature, SHA-256, byte-length, path, and runtime checks remain enabled. Production ignores catalog overrides unless `--test-mode` is present.
