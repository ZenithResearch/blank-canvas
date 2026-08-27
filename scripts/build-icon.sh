#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
SOURCE="$PROJECT_DIR/Resources/BlankCanvasIcon.svg"
WORK_DIR="$PROJECT_DIR/build/icon"
ICONSET="$WORK_DIR/BlankCanvasIcon.iconset"
MASTER="$WORK_DIR/BlankCanvasIcon-1024.png"
OUTPUT="$PROJECT_DIR/Resources/BlankCanvasIcon.icns"

mkdir -p "$WORK_DIR" "$ICONSET"
qlmanage -t -s 1024 -o "$WORK_DIR" "$SOURCE" >/dev/null
mv "$WORK_DIR/BlankCanvasIcon.svg.png" "$MASTER"

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$MASTER" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$MASTER" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$OUTPUT"
echo "$OUTPUT"

