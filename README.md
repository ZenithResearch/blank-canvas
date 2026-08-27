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

Launch it against the local production build:

```sh
zsh scripts/launch-test-mode.sh \
  http://127.0.0.1:3001/wallpapers/v1/catalog.json
```

Or launch it against the protected Vercel preview after exporting its protection-bypass secret:

```sh
export BLANK_CANVAS_STAGING_BYPASS='…'
zsh scripts/launch-test-mode.sh \
  https://zenith-landing-git-feat-remote-wallpaper-832d6e-zenith-research.vercel.app/wallpapers/v1/catalog.json
```

Test mode permits plain HTTP only for `localhost` and `127.0.0.1`. All catalog, manifest, preview, and archive URLs must still use either the exact selected staging origin or the production Zenith origin. Pack signature, SHA-256, byte-length, path, and runtime checks remain enabled. Production ignores catalog overrides unless `--test-mode` is present.
