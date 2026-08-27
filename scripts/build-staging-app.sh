#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
BUILD_DIR="$PROJECT_DIR/.build"
APP_DIR="$PROJECT_DIR/build/blank-canvas-staging.app"
CONTENTS_DIR="$APP_DIR/Contents"
REPOSITORY_DIR="${PROJECT_DIR:h:h}"
DOWNLOAD_PATH="$REPOSITORY_DIR/public/wallpapers/downloads/blank-canvas-staging-2.0.0-macOS.zip"
TEMP_DOWNLOAD_PATH="$PROJECT_DIR/build/blank-canvas-staging-2.0.0-macOS.zip"
PUBLIC_KEY="$PROJECT_DIR/../../public/wallpapers/v1/keys/zenith-wallpapers-2026-01.pub"
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_DIR/ModuleCache"

xcrun swift build \
  --package-path "$PROJECT_DIR" \
  --build-path "$BUILD_DIR" \
  --disable-sandbox \
  -c release

if [[ -d "$APP_DIR" ]]; then
  mv "$APP_DIR" "$PROJECT_DIR/build/blank-canvas-staging.previous.$(date +%s).app"
fi
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$BUILD_DIR/release/BlankCanvas" "$CONTENTS_DIR/MacOS/BlankCanvas"
cp "$PROJECT_DIR/Packaging/Info-Staging.plist" "$CONTENTS_DIR/Info.plist"
cp "$PUBLIC_KEY" "$CONTENTS_DIR/Resources/WallpaperPublicKey.txt"

plutil -lint "$CONTENTS_DIR/Info.plist"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
rm -f "$TEMP_DOWNLOAD_PATH"
(
  cd "$PROJECT_DIR/build"
  /usr/bin/zip -X -q -r "$TEMP_DOWNLOAD_PATH" "blank-canvas-staging.app"
)
mv "$TEMP_DOWNLOAD_PATH" "$DOWNLOAD_PATH"

echo "$DOWNLOAD_PATH"
