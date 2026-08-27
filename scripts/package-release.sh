#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
MODE="${BLANK_CANVAS_RELEASE_MODE:-notarized}"

case "$MODE" in
  adhoc)
    if [[ "${BLANK_CANVAS_ALLOW_NON_DISTRIBUTABLE_RELEASE:-0}" != "1" ]]; then
      echo "Ad-hoc packaging is non-distributable and requires explicit opt-in." >&2
      exit 1
    fi
    BLANK_CANVAS_SIGNING_IDENTITY=- BLANK_CANVAS_NOTARY_PROFILE= "$PROJECT_DIR/scripts/build-app.sh"
    BLANK_CANVAS_SIGNING_IDENTITY=- BLANK_CANVAS_NOTARY_PROFILE= "$PROJECT_DIR/scripts/build-staging-app.sh"
    ;;
  notarized)
    : "${BLANK_CANVAS_SIGNING_IDENTITY:?Developer ID Application identity is required}"
    : "${BLANK_CANVAS_NOTARY_PROFILE:?notarytool keychain profile is required}"
    "$PROJECT_DIR/scripts/build-app.sh"
    "$PROJECT_DIR/scripts/build-staging-app.sh"
    ;;
  *)
    echo "Unsupported BLANK_CANVAS_RELEASE_MODE=$MODE" >&2
    exit 1
    ;;
esac

node "$PROJECT_DIR/scripts/write-release-metadata.mjs" "$MODE"
(
  cd "$PROJECT_DIR/dist"
  shasum -a 256 -c SHA256SUMS
)

echo "$PROJECT_DIR/dist"

