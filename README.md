# blank-canvas

A native macOS wallpaper runtime with no bundled wallpapers. It discovers signed packs at `https://zenith-research.ca/wallpapers/v1/catalog.json`, verifies and installs them locally, then renders them behind desktop icons through an isolated WebKit origin.

Build with:

```sh
zsh scripts/build-app.sh
```

The release ZIP is written to `public/wallpapers/downloads/blank-canvas-2.0.0-macOS.zip` in the repository root. The app bundle contains only the executable and the public wallpaper-signing key.

## Test mode

Build a separate, visibly labelled staging app with an isolated cache and bundle identifier:

```sh
zsh scripts/build-staging-app.sh
```

The downloadable staging ZIP is written to `public/wallpapers/downloads/blank-canvas-staging-2.0.0-macOS.zip`. It always reads `https://zenith-research.ca/wallpapers/v1/staging/catalog.json`; no Vercel preview hostname is embedded.

Launch it against the local production build:

```sh
zsh scripts/launch-test-mode.sh \
  http://127.0.0.1:3001/wallpapers/v1/catalog.json
```

Test mode permits plain HTTP only for `localhost` and `127.0.0.1`. All catalog, manifest, preview, and archive URLs must still use either the exact selected staging origin or the production Zenith origin. Pack signature, SHA-256, byte-length, path, and runtime checks remain enabled. Production ignores catalog overrides unless `--test-mode` is present.
