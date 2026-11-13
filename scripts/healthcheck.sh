#!/usr/bin/env bash
# ==============================================================================
# Database Health & Connectivity Verification
# ==============================================================================

set -euo pipefail

ENV_FILE="${1:-.env}"

if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BLUE}================================================================${NC}"
echo -e "${BOLD}Database Health & Status Verification${NC}"
echo -e "${BLUE}================================================================${NC}"

# 1. PostgreSQL check
PG_NAME="${POSTGRES_CONTAINER_NAME:-${INSTANCE_ID:-database-hub}-postgres}"
if docker ps --format '{{.Names}}' | grep -q "^${PG_NAME}$"; then
    echo -n "Checking PostgreSQL (${PG_NAME})... "
    if docker exec "$PG_NAME" pg_isready -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-app_db}" > /dev/null 2>&1; then
        echo -e "${GREEN}[OK] Running & Responsive${NC}"
    else
        echo -e "${YELLOW}[PENDING] Container running but not ready yet${NC}"
    fi
fi

# 2. MySQL check
MYSQL_NAME="${MYSQL_CONTAINER_NAME:-${INSTANCE_ID:-database-hub}-mysql}"
if docker ps --format '{{.Names}}' | grep -q "^${MYSQL_NAME}$"; then
    echo -n "Checking MySQL (${MYSQL_NAME})... "
    if docker exec -e MYSQL_PWD="${MYSQL_ROOT_PASSWORD:-mysql_root_secure_pass}" "$MYSQL_NAME" mysqladmin ping -h localhost -u root > /dev/null 2>&1; then
        echo -e "${GREEN}[OK] Running & Responsive${NC}"
    else
        echo -e "${YELLOW}[PENDING] Container running but initializing${NC}"
    fi
fi

# 3. MongoDB check
MONGO_NAME="${MONGO_CONTAINER_NAME:-${INSTANCE_ID:-database-hub}-mongodb}"
if docker ps --format '{{.Names}}' | grep -q "^${MONGO_NAME}$"; then
    echo -n "Checking MongoDB (${MONGO_NAME})... "
    if docker exec "$MONGO_NAME" mongosh --quiet --eval "db.adminCommand({ping:1})" > /dev/null 2>&1 || \
       docker exec "$MONGO_NAME" mongosh -u "${MONGO_INITDB_ROOT_USERNAME:-root}" -p "${MONGO_INITDB_ROOT_PASSWORD:-mongo_root_secure_pass}" --authenticationDatabase admin --quiet --eval "db.adminCommand({ping:1})" > /dev/null 2>&1; then
        echo -e "${GREEN}[OK] Running & Responsive${NC}"
    else
        echo -e "${YELLOW}[PENDING] Container running but initializing${NC}"
    fi
fi

# 4. Redis check
REDIS_NAME="${REDIS_CONTAINER_NAME:-${INSTANCE_ID:-database-hub}-redis}"
if docker ps --format '{{.Names}}' | grep -q "^${REDIS_NAME}$"; then
    echo -n "Checking Redis (${REDIS_NAME})... "
    REDIS_RES=$(docker exec -e REDISCLI_AUTH="${REDIS_PASSWORD:-}" "$REDIS_NAME" redis-cli ping 2>/dev/null || true)
    if [[ "$REDIS_RES" == *"PONG"* ]]; then
        echo -e "${GREEN}[OK] Running & Responsive${NC}"
    else
        echo -e "${YELLOW}[PENDING] Container running but not ready${NC}"
    fi
fi

echo -e "\n${BLUE}Container Overview:${NC}"
proj_name="${COMPOSE_PROJECT_NAME:-${INSTANCE_ID:-database-hub}}"
if [ -f "$ENV_FILE" ]; then
    docker compose -p "$proj_name" --env-file "$ENV_FILE" ps 2>/dev/null || docker compose ps
else
    docker compose -p "$proj_name" ps 2>/dev/null || docker compose ps
fi
