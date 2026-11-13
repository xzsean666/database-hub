#!/usr/bin/env bash
# ==============================================================================
# Database Hub - Deployment Script (Alias to dbhub.sh)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo -e "\033[1;33m[Notice] 'deploy.sh' has evolved to 'dbhub.sh' (Database Hub Unified CLI).\033[0m"
echo -e "\033[1;33m[Notice] Automatically forwarding your command to dbhub.sh...\033[0m\n"

exec "$PROJECT_ROOT/dbhub.sh" "$@"
