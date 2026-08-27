#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
BUILD_DIR="$PROJECT_DIR/.build"
APP_DIR="$PROJECT_DIR/build/blank-canvas-staging.app"
CONTENTS_DIR="$APP_DIR/Contents"
DOWNLOAD_PATH="$PROJECT_DIR/dist/blank-canvas-staging-2.0.0-macOS.zip"
TEMP_DOWNLOAD_PATH="$PROJECT_DIR/build/blank-canvas-staging-2.0.0-macOS.zip"
PUBLIC_KEY="$PROJECT_DIR/Resources/WallpaperPublicKey.txt"
SIGNING_IDENTITY="${BLANK_CANVAS_SIGNING_IDENTITY:--}"
NOTARY_PROFILE="${BLANK_CANVAS_NOTARY_PROFILE:-}"
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
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources" "${DOWNLOAD_PATH:h}"
cp "$BUILD_DIR/release/BlankCanvas" "$CONTENTS_DIR/MacOS/BlankCanvas"
cp "$PROJECT_DIR/Packaging/Info-Staging.plist" "$CONTENTS_DIR/Info.plist"
cp "$PUBLIC_KEY" "$CONTENTS_DIR/Resources/WallpaperPublicKey.txt"
cp "$PROJECT_DIR/Resources/BlankCanvasIcon.icns" "$CONTENTS_DIR/Resources/BlankCanvasIcon.icns"

plutil -lint "$CONTENTS_DIR/Info.plist"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - "$APP_DIR"
else
  codesign --force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_DIR"
fi
codesign --verify --deep --strict "$APP_DIR"
rm -f "$TEMP_DOWNLOAD_PATH"
(
  cd "$PROJECT_DIR/build"
  /usr/bin/zip -X -q -r "$TEMP_DOWNLOAD_PATH" "blank-canvas-staging.app"
)

if [[ -n "$NOTARY_PROFILE" ]]; then
  if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    echo "BLANK_CANVAS_NOTARY_PROFILE requires a Developer ID signing identity" >&2
    exit 1
  fi
  xcrun notarytool submit "$TEMP_DOWNLOAD_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_DIR"
  rm -f "$TEMP_DOWNLOAD_PATH"
  (
    cd "$PROJECT_DIR/build"
    /usr/bin/zip -X -q -r "$TEMP_DOWNLOAD_PATH" "blank-canvas-staging.app"
  )
fi

mv "$TEMP_DOWNLOAD_PATH" "$DOWNLOAD_PATH"

echo "$DOWNLOAD_PATH"
