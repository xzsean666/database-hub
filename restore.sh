#!/usr/bin/env bash
# ==============================================================================
# Database Hub - Universal Restore CLI
# ==============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/scripts/restore.sh" "$@"
