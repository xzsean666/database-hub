#!/usr/bin/env bash
# ==============================================================================
# Automated Docker CE & Docker Compose Installer
# Supports: Debian, Ubuntu, CentOS, Rocky Linux, AlmaLinux
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}===> Checking Docker installation on host...${NC}"

if command -v docker &>/dev/null && docker compose version &>/dev/null; then
    echo -e "${GREEN}✓ Docker and Docker Compose are already installed:${NC}"
    docker --version
    docker compose version
    exit 0
fi

echo -e "${YELLOW}Docker or Docker Compose is missing. Starting installation...${NC}"

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${YELLOW}Warning: Installation requires root privileges. Using sudo...${NC}"
    SUDO="sudo"
else
    SUDO=""
fi

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo -e "${RED}Error: Cannot detect OS distribution (/etc/os-release not found).${NC}"
    exit 1
fi

case "$OS" in
    ubuntu|debian)
        echo -e "${BLUE}Detected Debian/Ubuntu. Installing Docker using official repository...${NC}"
        $SUDO apt-get update -y
        $SUDO apt-get install -y ca-certificates curl gnupg lsb-release
        $SUDO install -m 0755 -d /etc/apt/keyrings
        if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
            curl -fsSL "https://download.docker.com/linux/$OS/gpg" | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            $SUDO chmod a+r /etc/apt/keyrings/docker.gpg
        fi
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS $(lsb_release -cs) stable" | $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null
        $SUDO apt-get update -y
        $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        ;;
    centos|rhel|rocky|almalinux)
        echo -e "${BLUE}Detected RHEL-family OS. Installing Docker...${NC}"
        $SUDO yum install -y yum-utils
        $SUDO yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        $SUDO yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        ;;
    *)
        echo -e "${YELLOW}Attempting convenience installation script (get.docker.com)...${NC}"
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        $SUDO sh /tmp/get-docker.sh
        rm -f /tmp/get-docker.sh
        ;;
esac

# Start and enable Docker service
$SUDO systemctl enable --now docker || service docker start || true

echo -e "${GREEN}✓ Docker and Docker Compose successfully installed!${NC}"
docker --version
docker compose version
