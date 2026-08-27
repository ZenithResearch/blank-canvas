#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_DIR="$PROJECT_DIR/build/blank-canvas-staging.app"
CATALOG_URL="${1:-${BLANK_CANVAS_CATALOG_URL:-}}"

if [[ ! -x "$APP_DIR/Contents/MacOS/BlankCanvas" ]]; then
  "$PROJECT_DIR/scripts/build-staging-app.sh"
fi

ARGS=(--test-mode)
if [[ -n "$CATALOG_URL" ]]; then
  ARGS+=(--catalog-url "$CATALOG_URL")
fi

if [[ -n "${BLANK_CANVAS_STAGING_BYPASS:-}" ]]; then
  launchctl setenv BLANK_CANVAS_STAGING_BYPASS "$BLANK_CANVAS_STAGING_BYPASS"
  trap 'launchctl unsetenv BLANK_CANVAS_STAGING_BYPASS' EXIT
fi

open -na "$APP_DIR" --args "${ARGS[@]}"
sleep 1

echo "blank-canvas staging launched${CATALOG_URL:+ with $CATALOG_URL}"
