#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_DIR="$PROJECT_DIR/build/blank-canvas-staging.app"
CATALOG_URL="${1:-${BLANK_CANVAS_CATALOG_URL:-http://127.0.0.1:3001/wallpapers/v1/catalog.json}}"

"$PROJECT_DIR/scripts/build-staging-app.sh"

open -na "$APP_DIR" --args --dev-mode --catalog-url "$CATALOG_URL"
sleep 1

echo "blank-canvas development launched against $CATALOG_URL"
