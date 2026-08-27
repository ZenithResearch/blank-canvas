#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
exec "$PROJECT_DIR/scripts/launch-dev-mode.sh" "$@"
