#!/usr/bin/env bash
# ==============================================================================
# Linux Host Kernel & System Optimization for Databases
# Specifically tuned for Redis, MongoDB, MySQL, and PostgreSQL
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}===> Applying Linux Host Optimizations for Databases...${NC}"

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${YELLOW}Warning: This script requires root privileges to change kernel parameters.${NC}"
    echo -e "Attempting to run with sudo..."
    SUDO="sudo"
else
    SUDO=""
fi

SYSCTL_CONF="/etc/sysctl.d/99-database-hub.conf"

$SUDO tee "$SYSCTL_CONF" > /dev/null << 'EOF'
# Database Hub System Optimizations
# Memory overcommit (Critical for Redis fork / bgsave)
vm.overcommit_memory = 1

# Increase max open connections in listen queue (somaxconn)
net.core.somaxconn = 4096

# Increase TCP syn backlog
net.ipv4.tcp_max_syn_backlog = 4096

# File descriptor limits
fs.file-max = 2097152

# Reduce aggressive swapping
vm.swappiness = 10

# Increase maximum memory map areas (for MongoDB & ClickHouse)
vm.max_map_count = 262144
EOF

echo -e "${GREEN}✓ Created $SYSCTL_CONF${NC}"

# Apply sysctl settings immediately
$SUDO sysctl --system > /dev/null 2>&1 || $SUDO sysctl -p "$SYSCTL_CONF" > /dev/null 2>&1 || true
echo -e "${GREEN}✓ Applied sysctl kernel parameters${NC}"

# Disable Transparent Huge Pages (THP) for MongoDB and Redis latency stability
if [ -d "/sys/kernel/mm/transparent_hugepage" ]; then
    if [ -f "/sys/kernel/mm/transparent_hugepage/enabled" ]; then
        echo never | $SUDO tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null 2>&1 || true
    fi
    if [ -f "/sys/kernel/mm/transparent_hugepage/defrag" ]; then
        echo never | $SUDO tee /sys/kernel/mm/transparent_hugepage/defrag > /dev/null 2>&1 || true
    fi
    echo -e "${GREEN}✓ Disabled Transparent Huge Pages (THP)${NC}"
fi

echo -e "${GREEN}Host optimization completed successfully!${NC}"
