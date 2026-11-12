# Database Hub 🚀

> **A high-performance, modular database management and deployment toolkit for Local and Remote (SSH) Linux environments.**  
> Supports **PostgreSQL 18**, **MySQL 8.4 LTS**, **MongoDB 8.0**, and **Redis 7.4**, with deep production tuning, **automated extreme-compression backups (`zstd -19`)**, self-starting timers, retention pruning, and a **universal one-command restore engine**.

---

## 📦 Supported Database Engines & Versions

| Engine | Supported / Default Image | Container Name Pattern | Default Internal Port | Backup Strategy |
|---|---|---|---|---|
| **PostgreSQL** | `postgres:18-alpine` (PostgreSQL 18) | `${INSTANCE_ID}-postgres` | `5432` | `pg_dump` stream + `zstd -19` / `pg_basebackup` |
| **MySQL** | `mysql:8.4` (MySQL 8.4 LTS) | `${INSTANCE_ID}-mysql` | `3306` | `mysqldump` stream + `zstd -19` / Binlog replication |
| **MongoDB** | `mongo:8.0` (MongoDB 8.0) | `${INSTANCE_ID}-mongodb` | `27017` | `mongodump` archive stream + `zstd -19` |
| **Redis** | `redis:7.4-alpine` (Redis 7.4) | `${INSTANCE_ID}-redis` | `6379` | RDB snapshot stream + `zstd -19` |

> 💡 Detailed operational guide & AI skill: see [docs/SKILL.md](file:///ssd0/git/database-hub/docs/SKILL.md).

---

## 🌟 Highlights & Features

- ⚡ **Unified CLI (`dbhub.sh`)**: Deploy, manage, backup, inspect, and restore databases locally or across remote servers via SSH (`dbhub.sh` with `deploy.sh` backwards-compatible alias).
- 🗜️ **Extreme Auto-Backup (`zstd -19`)**:
  - Direct stream compression into **Zstandard level 19 (`zstd -19 -T0`)** (with automatic fallback to `xz -9e` or `gzip -9`).
  - No temporary uncompressed dumps taking up gigabytes of disk space.
  - Generates SHA256 integrity checksums for every backup archive.
- ⏰ **Self-Starting Daemon & Frequency Control**:
  - Automatically installs and starts a **Systemd Timer** (`database-hub-backup.timer`) that survives server reboots (with automatic Linux cron fallback).
  - Flexible frequency: `daily` (1 day 1 time at 02:00 AM), `12h` (twice a day), `6h`, or custom cron expressions.
- 🧹 **Intelligent Retention Pruning**:
  - Specify maximum backups to retain per database (e.g. `--backup-retention 7`).
  - Automatically cleans up older archives and checksum files after each backup run.
- 🔄 **Universal Restore Engine (`restore.sh`)**:
  - Generic restore tool for Local and Remote (SSH) deployments.
  - Automatically scans and lists available backups with timestamps and sizes.
  - Decompresses and streams data into the target container with safety confirmation and post-restore health verification.
- 📊 **Real-Time Backup Status Inspection**:
  - One command (`./dbhub.sh -a backup-status`) to view daemon status, next trigger time, schedule, disk usage, backup file inventory table, and execution logs.
- 🧩 **Clean Modular Architecture**:
  - Decoupled into `scripts/lib/common.sh`, `scripts/lib/scheduler.sh`, `scripts/lib/summary.sh`, `scripts/backup.sh`, and `scripts/restore.sh`.
- 🛠️ **Deep Production Performance Tuning**:
  - Pre-tuned configurations for NVMe/SSDs, memory buffers, thread concurrency, and Linux host kernel sysctl optimizations.

---

## 📁 Project Structure

```text
database-hub/
├── dbhub.sh                      # Primary Unified CLI (Deploy, Backup, Restore, Status)
├── restore.sh                    # Universal Database Restore CLI (Local & Remote SSH)
├── deploy.sh                     # Compatibility wrapper (forwards to dbhub.sh)
├── docker-compose.yml            # Docker Compose specification with modular profiles
├── .env.example                  # Environment configuration with backup & tuning options
├── docs/                         # Documentation and operational skills
│   └── SKILL.md                  # Comprehensive operational guide for humans and AI agents
├── envs/                         # Database-specific environment templates (dev & prod)
├── configs/                      # Database configuration templates & init scripts
│   ├── postgres/                 # PostgreSQL performance configs
│   ├── mysql/                    # MySQL InnoDB performance configs
│   ├── mongodb/                  # WiredTiger engine tuning
│   └── redis/                    # Redis memory, multithreaded I/O & persistence configs
├── scripts/
│   ├── lib/                      # Reusable modular shell libraries
│   │   ├── common.sh             # Shared utilities, SSH execution, extreme compressor detection
│   │   ├── scheduler.sh          # Systemd timer & cron auto-backup manager
│   │   └── summary.sh            # Formatted access summary & banners
│   ├── backup.sh                 # Backup engine (dump, extreme compression, retention, status)
│   ├── restore.sh                # Restore engine (inspect, decompress, import, verify)
│   ├── healthcheck.sh            # Live database connectivity & health check
│   ├── setup-remote-docker.sh    # Automated Docker & Compose installer for Linux
│   └── tune-host.sh              # Host kernel sysctl & THP tuning
└── backups/                      # Backup storage directory (ignored by git)
```

---

## 🚀 Quick Start

### 1. Configure Environment

Copy the universal configuration or select a template from `envs/`:

```bash
# Option A: Universal configuration
cp .env.example .env

# Option B: Dedicated database templates (from envs/)
cp envs/postgres/prod-high-perf.env.example envs/postgres/prod.env
cp envs/redis/cache-lru.env.example envs/redis/cache.env
cp envs/mysql/prod-high-perf.env.example envs/mysql/prod.env
cp envs/mongodb/prod-high-perf.env.example envs/mongodb/prod.env
```

### 2. Interactive Wizard Mode

Simply run `./dbhub.sh` (or `./deploy.sh`) without arguments to launch the wizard:

```bash
./dbhub.sh
```

---

## 📦 Deployment Commands

### Remote Deployment (via SSH)

```bash
# Deploy all databases remotely with auto-backup enabled (1 day 1 time, keep 7 backups)
./dbhub.sh --ssh "ssh -i ~/ssh/key -p 22 root@192.168.31.33" --env .env --db all --auto-backup

# Deploy only PostgreSQL and Redis with host tuning and custom backup frequency
./dbhub.sh --ssh "root@192.168.31.33" --env .env --db postgres,redis --tune-host \
  --auto-backup --backup-schedule "0 2 * * *" --backup-retention 14
```

### Local Deployment

```bash
# Deploy all databases locally with auto-backup enabled
./dbhub.sh --local --env .env --db all --auto-backup --backup-schedule daily --backup-retention 7

# Deploy only MySQL locally
./dbhub.sh --local --env .env --db mysql
```

---

## 💾 Automated Backup & Status Inspection

### Inspect Backup Status & Available Archives

You can inspect the auto-backup daemon status, schedule, next execution time, and storage inventory anytime:

```bash
# Locally
./dbhub.sh --action backup-status

# Remotely over SSH
./dbhub.sh --ssh "root@192.168.31.33" --action backup-status
```

Example status output:
```text
========================================================================
                 DATABASE HUB - BACKUP STATUS & INVENTORY               
========================================================================
[Automated Backup Daemon]
  Status:        ● ACTIVE
  Engine:        Systemd Timer
  Next Trigger:  2026-11-13 02:00:00 UTC
  Config Schedule: 0 2 * * * (Daily at 02:00 AM)
  Retention Limit: Keep latest 7 backups per database
  Compressor:     zstd -19 -T0 --quiet (Extreme Compression)

[Storage & Backups]
  Backup Dir:     /opt/database-hub/backups
  Total Storage:  128.5 MB

[Available Backup Files]
ID   DATABASE     CREATED AT           SIZE       FILENAME
---- ------------ -------------------- ---------- ----------------------------------------
1    postgres     2026-11-12 02:00:00  42.5 MB    postgres_app_db_20261112_020000.sql.zst
2    mysql        2026-11-12 02:00:00  18.2 MB    mysql_app_db_20261112_020000.sql.zst
3    mongodb      2026-11-12 02:00:00  62.1 MB    mongodb_app_db_20261112_020000.archive.zst
4    redis        2026-11-12 02:00:00  5.7 MB     redis_20261112_020000.tar.zst
========================================================================
```

### Trigger Immediate Backup

```bash
# Run backup for all running databases immediately
./dbhub.sh --action backup

# Remotely
./dbhub.sh --ssh "root@192.168.31.33" --action backup
```

---

## 🔄 Universal Database Restore (`restore.sh`)

The generic restore tool automatically connects to the local or remote host, inspects existing backups, and provides an interactive selection menu or non-interactive CLI flags:

### 1. Interactive Restore Wizard

```bash
# Launch interactive restore wizard (Local or Remote)
./restore.sh
```

### 2. List Available Backups

```bash
# List local backups
./restore.sh --list

# List remote backups over SSH
./restore.sh --ssh "root@192.168.31.33" --list
```

### 3. Restore by Database or File

```bash
# Restore latest PostgreSQL backup on remote server
./restore.sh --ssh "root@192.168.31.33" --db postgres --latest

# Restore specific backup archive locally
./restore.sh --local --file postgres_app_db_20261112_020000.sql.zst

# Restore via dbhub.sh
./dbhub.sh --action restore
```

---

## 🔗 Master-Replica High Availability & Replication

Database Hub supports in-place conversion of running databases into **Masters**, and automated bootstrapping of **Replicas** across remote servers via SSH, strictly scoped by `.env` to support multiple database stacks per host.

### 1. Upgrade Running Database to Master (Zero Data Loss)

Seamlessly promote an existing standalone database stack to Master:

```bash
# Locally
./dbhub.sh --action make-master --env .env --db all

# Remotely over SSH for a specific environment
./dbhub.sh --ssh "root@192.168.1.101" --action make-master --env envs/user-db.env --db postgres
```

### 2. Deploy a Replica Tracking a Master (Cross-SSH Support)

Deploy a replica onto another server, inheriting configuration from the Master `.env`, pulling an initial throttled base backup (`--max-rate 30M`), and streaming real-time incremental updates:

```bash
# Deploy a replica on 192.168.1.102 tracking Master on 192.168.1.101
./dbhub.sh --replica \
  --ssh "root@192.168.1.102" \
  --master-ssh "root@192.168.1.101" \
  --master-env "envs/user-db.env" \
  --db postgres \
  --max-rate "30M"
```

### 3. Inspect Cluster Replication Status & Sync Lag

```bash
# Inspect replication health and lag
./dbhub.sh --action repl-status --env envs/user-db.env
```

### 4. Interactive Replication Wizard

Simply run `./dbhub.sh` to launch the interactive menu, select `10) make-master` or `11) deploy-replica`, and the wizard will automatically scan Master environments, calculate non-colliding ports, derive replica configs, and bootstrap replication.

---

## ⚙️ CLI Reference (`dbhub.sh`)

| Option | Description |
|---|---|
| `-s, --ssh "<cmd>"` | Remote SSH command or connection target (e.g. `"ssh -i key.pem -p 22 root@host"` or `"root@host"`). |
| `-l, --local` | Run on current local host (default). |
| `-e, --env <path>` | Path to `.env` configuration file (default: `.env`). |
| `-d, --db <list>` | Databases to deploy: `postgres`, `mysql`, `mongodb`, `redis`, or `all` (comma-separated, default: `all`). |
| `-a, --action <act>` | Action: `up` (default), `down`, `restart`, `status`, `logs`, `backup`, `backup-status`, `restore`, `make-master`, `deploy-replica`, `repl-status`, `scan`, `tune-host`. |
| `--make-master` | Shortcut to upgrade specified database instance to Master. |
| `--replica` | Shortcut to deploy replica instance tracking a Master. |
| `--master-ssh "<cmd>"` | SSH connection string to the Master server. |
| `--master-env <path>` | Path to Master's `.env` configuration file on Master server. |
| `--max-rate <rate>` | Bandwidth limit for initial full sync (default: `30M`, e.g. `10M`, `50M`). |
| `--auto-backup` | Enable automated extreme-compression backup daemon. |
| `--backup-schedule <c>` | Backup frequency: `daily` (default, 1 day 1 time at 02:00 AM), `12h`, `6h`, or custom cron. |
| `--backup-retention <n>`| Maximum number of backups to keep per database (default: `7`). |
| `-r, --remote-dir <p>` | Remote directory path on destination server (default: `/opt/database-hub`). |
| `--tune-host` | Apply Linux kernel performance tuning (`vm.overcommit_memory=1`, THP disable, etc.). |
| `--install-docker` | Automatically install Docker CE & Docker Compose on remote if missing. |
| `-i, --interactive` | Launch interactive wizard. |
| `-h, --help` | Show help message. |

---

## 🔒 Security Best Practices

1. **Firewall & Bind IP**: By default, ports bind to `BIND_IP=0.0.0.0`. If you only want local container-to-container access, change `BIND_IP=127.0.0.1` in your `.env`.
2. **Strong Passwords**: Never use default passwords in production. Set strong passwords in `.env`.
3. **Data Persistence & Storage Path**:
   - **Default Path**: All databases default to host path `/app/database/<engine>/<container_name>` (e.g. `/app/database/mysql/<container_name>`).
   - **Custom Absolute Path**: If `DATA_DIR` or `<DB>_DATA_DIR` is set to an absolute path (e.g. `/var/data`), it follows the specified path.
   - **Relative Path**: If set to a relative path starting with `./` (e.g. `./data` or `./my-instance`), it automatically normalizes under `/app/database/<engine>/...`.
4. **Backup Protection**: Backups are generated in `backups/` and excluded from git version control.
