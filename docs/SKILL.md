---
name: database-hub
description: Comprehensive operational guide and skill manual for managing, deploying, backing up, restoring, and replicating databases (PostgreSQL 18, MySQL 8.4 LTS, MongoDB 8.0, Redis 7.4) using the unified Database Hub toolkit (dbhub.sh).
---

# Database Hub Operational Skill Manual

Database Hub (`database-hub`) is a production-grade, modular database deployment and management toolkit for Linux environments. It supports standalone, multi-instance, and high-availability Master-Replica setups across local and remote (SSH) machines.

---

## 1. Supported Database Engines & Versions

| Engine | Default Image / Version | Container Name Pattern | Default Internal Port | Backup Engine |
|---|---|---|---|---|
| **PostgreSQL** | `postgres:18-alpine` (PostgreSQL 18) | `${INSTANCE_ID}-postgres` | `5432` | `pg_dump` / `pg_basebackup` + `zstd -19` |
| **MySQL** | `mysql:8.4` (MySQL 8.4 LTS) | `${INSTANCE_ID}-mysql` | `3306` | `mysqldump` / binary log + `zstd -19` |
| **MongoDB** | `mongo:8.0` (MongoDB 8.0) | `${INSTANCE_ID}-mongodb` | `27017` | `mongodump` (archive stream) + `zstd -19` |
| **Redis** | `redis:7.4-alpine` (Redis 7.4) | `${INSTANCE_ID}-redis` | `6379` | RDB snapshot + `zstd -19` |

---

## 2. Host Storage & Data Directory Rules

Database Hub organizes persistent data on the host with automatic isolation:

### Default Path Logic
All databases default to root `/app/database`:
```text
/app/database/<engine>/<container_name>
```
* **PostgreSQL**: `/app/database/postgres/<container_name>`
* **MySQL**: `/app/database/mysql/<container_name>`
* **MongoDB**: `/app/database/mongodb/<container_name>`
* **Redis**: `/app/database/redis/<container_name>`

### Custom Path Rules
* **Explicit Absolute Path** (e.g., `DATA_DIR=/ssd1/database` or `MYSQL_DATA_DIR=/var/data/mysql`):
  Respects the specified path as-is.
* **Relative Path** (e.g., `DATA_DIR=./data/my-instance` or `DATA_DIR=./my-instance`):
  Automatically normalized under `/app/database/<engine>/...` (e.g. `/app/database/mysql/my-instance`).

---

## 3. Environment Configuration (`.env`)

Each database stack instance is driven by an `.env` file. Key parameters:

```ini
# Instance & Stack Isolation
INSTANCE_ID=my-service-dev
COMPOSE_PROJECT_NAME=my-service-dev

# Network & Host Binding
TZ=UTC
BIND_IP=0.0.0.0
DOCKER_NETWORK_NAME=my-service-dev-net

# Storage Base (defaults to /app/database)
DATA_DIR=/app/database

# Engine-Specific Configurations (Example: MySQL 8.4 LTS)
MYSQL_IMAGE=mysql:8.4
MYSQL_CONTAINER_NAME=my-service-dev-mysql
MYSQL_PORT=10202
MYSQL_ROOT_PASSWORD=<strong_root_password>
MYSQL_DATABASE=my_app_dev
MYSQL_USER=my_app_user
MYSQL_PASSWORD=<strong_user_password>
MYSQL_DATA_DIR=/app/database/mysql/my-service-dev-mysql

# Performance (Dev vs Prod)
MYSQL_BUFFER_POOL_SIZE=512M
MYSQL_MAX_CONNECTIONS=200
MYSQL_FLUSH_LOG_AT_TRX_COMMIT=2

# Backup Automation
AUTO_BACKUP_ENABLED=false
AUTO_BACKUP_SCHEDULE="0 2 * * *"
AUTO_BACKUP_RETENTION=7
BACKUP_DIR=./backups
BACKUP_COMPRESSION=zstd
```

---

## 4. CLI Execution Workflows (`dbhub.sh`)

The entry point for all operations is `./dbhub.sh`.

### A. Local Operations
```bash
# Interactive wizard
./dbhub.sh

# Deploy specific engine locally
./dbhub.sh --local --env envs/mysql/dev.env --db mysql

# Deploy all databases with auto-backup (daily at 02:00, keep 7)
./dbhub.sh --local --env .env --db all --auto-backup --backup-schedule daily --backup-retention 7

# Inspect container status & healthcheck
./dbhub.sh --local --env .env --action status

# View live container logs
./dbhub.sh --local --env .env --action logs
```

### B. Remote Deployment over SSH
When deploying remotely, `dbhub.sh` securely packages and streams the codebase and target `.env` over SSH, creates host data directories, and launches containers:

```bash
# Standard Remote Deploy
./dbhub.sh \
  --ssh "ssh -i ~/ssh/key.pem -p 22 root@192.168.1.100" \
  --env envs/mysql/.env.soneium.portal.dev \
  --db mysql

# Remote Deploy with Port / Non-standard SSH & Auto Docker Install
./dbhub.sh \
  --ssh "ssh -i ~/ssh/sean -p 443 root@54.248.165.38" \
  --env envs/mysql/.env.soneium.portal.dev \
  --db mysql \
  --install-docker
```

---

## 5. Connection URL Matrix

Once deployed, connection strings depend on the client's network vantage point:

| Access Type | Host | Port | Format Example |
|---|---|---|---|
| **Docker Internal** (same docker network) | `${CONTAINER_NAME}` | `3306` / `5432` / `27017` / `6379` | `mysql://user:pass@soneium-portal-dev-mysql:3306/db_name` |
| **Host Local** (process running on host OS) | `127.0.0.1` | `${HOST_PORT}` (e.g. `10202`) | `mysql://user:pass@127.0.0.1:10202/db_name` |
| **External Client** (remote developer / cloud) | `${SERVER_IP}` | `${HOST_PORT}` (e.g. `10202`) | `mysql://user:pass@54.248.165.38:10202/db_name` |

---

## 6. Backup, Inspection & Restore Guide

### Automated Backups
When `--auto-backup` is enabled, `dbhub.sh` registers a Systemd timer (`dbhub-backup-${INSTANCE_ID}.timer`) with automatic retention cleanup.
```bash
# Check backup schedule, next trigger, and existing archive list
./dbhub.sh --ssh "root@host" --env .env --action backup-status

# Trigger an immediate ad-hoc backup
./dbhub.sh --ssh "root@host" --env .env --action backup
```

### Universal Restore
```bash
# Interactive restore wizard (scans available archives and guides safely)
./restore.sh

# Non-interactive remote restore of the latest backup
./restore.sh --ssh "root@host" --env .env --db mysql --latest
```

---

## 7. Master-Replica High Availability

Promote standalone instances to Master and spin up real-time replicas:

```bash
# 1. Upgrade running instance to Master (in-place, zero data loss)
./dbhub.sh --ssh "root@master-ip" --action make-master --env .env --db postgres

# 2. Deploy a replica tracking the master
./dbhub.sh --replica \
  --ssh "root@replica-ip" \
  --master-ssh "root@master-ip" \
  --master-env ".env" \
  --db postgres \
  --max-rate "30M"

# 3. Check replication sync lag
./dbhub.sh --ssh "root@replica-ip" --action repl-status --env .env
```

---

## 8. Common Troubleshooting & Rules for AI Agents

1. **Host Storage Permissions**: Host directories under `/app/database/` require root creation. `dbhub.sh` creates them automatically prior to container startup.
2. **Port Collisions**: Always verify target port availability when deploying multiple instances on the same host (e.g. `MYSQL_PORT=10202`).
3. **Password Security**: Passwords in `.env` are auto-ignored by Git (`.gitignore: envs/**/.env*`). Never hardcode production credentials in `.example` files.
4. **Daemon Persistence**: Systemd timers persist across remote host reboots; removing an instance with `./dbhub.sh -a down` also cleanly disables the associated backup daemon.
