# Database Hub 🚀

> **A high-performance, automated database deployment toolkit for Local and Remote (SSH) Linux environments.**  
> Supports **PostgreSQL 16**, **MySQL 8.x**, **MongoDB 7.0**, and **Redis 7.2**, with deep production-grade performance tuning pre-configured.

---

## 🌟 Highlights & Features

- ⚡ **Local & Remote SSH Deployment**: One command to deploy databases locally or remotely across servers using your SSH command (e.g. `ssh -i ~/ssh/sean -p 22 root@192.168.31.33`).
- 🛠️ **Deep Performance Tuning**:
  - **PostgreSQL 16**: `shared_buffers`, `effective_cache_size`, `work_mem`, NVMe/SSD query plan cost (`random_page_cost=1.1`, `effective_io_concurrency=200`), large shared memory allocation (`shm_size`), and parallel workers.
  - **MySQL 8.x**: Tuned `innodb_buffer_pool_size`, `innodb_flush_log_at_trx_commit=2` for ultra-high transaction throughput, `innodb_flush_method=O_DIRECT`, `skip-name-resolve` to eliminate DNS latency, and large thread/table cache.
  - **MongoDB 7.0**: WiredTiger engine cache control (`wiredTigerCacheSizeGB`), `snappy` block compression, directoryPerDB, and increased connection limits (`maxIncomingConnections=10000`).
  - **Redis 7.2**: Multi-threaded I/O (`io-threads 4`), `maxmemory` + `allkeys-lru` eviction, hybrid persistence (AOF + RDB), lazy background deletions (`lazyfree-lazy-eviction`), and `net.core.somaxconn` sysctl tuning.
- 🎯 **Modular Profiles**: Deploy all databases or just what you need (e.g. `--db postgres,redis` or `--db mysql`).
- 🐧 **Linux Host Kernel Tuning**: Automated kernel sysctl optimization (`vm.overcommit_memory=1`, `net.core.somaxconn=4096`, file limits) and Transparent Huge Pages (THP) deactivation.
- 🐳 **Remote Auto-Docker Setup**: Detects if remote server is missing Docker/Docker Compose and can install it automatically.
- 📋 **Zero-Dependency Remote Sync**: Compresses and streams files over SSH via `tar` pipeline—no `rsync` or extra remote packages required!

---

## 📁 Project Structure

```text
database-hub/
├── deploy.sh                     # Unified deployment CLI (Local & Remote SSH)
├── docker-compose.yml            # Docker Compose specification with modular profiles
├── .env.example                  # Comprehensive environment & tuning configuration
├── envs/                         # Database-specific environment templates (dev & prod)
│   ├── README.md                 # Detailed examples and deployment commands
│   ├── postgres/                 # dev.env.example & prod-high-perf.env.example
│   ├── mysql/                    # dev.env.example & prod-high-perf.env.example
│   ├── mongodb/                  # dev.env.example & prod-high-perf.env.example
│   ├── redis/                    # cache-lru.env.example & persistent.env.example
│   └── all/                      # all-in-one stack env examples
├── configs/                      # Database configuration templates & init scripts
│   ├── postgres/
│   │   ├── conf.d/01-tuning.conf # PostgreSQL performance optimizations
│   │   └── init/                 # Optional SQL/shell initialization scripts
│   ├── mysql/
│   │   ├── conf.d/01-tuning.cnf  # MySQL InnoDB performance tuning
│   │   └── init/                 # Optional SQL initialization scripts
│   ├── mongodb/
│   │   ├── mongod.conf           # WiredTiger engine & network tuning
│   │   └── init/                 # Optional JS initialization scripts
│   └── redis/
│       └── redis.conf            # Redis memory, multithread I/O & persistence tuning
├── scripts/
│   ├── healthcheck.sh            # Live database connectivity & health check
│   ├── setup-remote-docker.sh    # Automated Docker & Compose installer for Linux
│   └── tune-host.sh              # Host kernel sysctl & THP tuning
└── README.md
```

---

## 🚀 Quick Start

### 1. Configure Environment

You can copy the root `.env.example` or choose a dedicated template from the `envs/` folder:

```bash
# Option A: Universal configuration
cp .env.example .env

# Option B: Dedicated database templates (from envs/)
cp envs/postgres/prod-high-perf.env.example envs/postgres/prod.env
cp envs/redis/cache-lru.env.example envs/redis/cache.env
cp envs/mysql/prod-high-perf.env.example envs/mysql/prod.env
cp envs/mongodb/prod-high-perf.env.example envs/mongodb/prod.env
```

### 2. Remote Deployment (via SSH)

Provide your SSH connection command and environment file:

```bash
# Deploy all databases remotely
./deploy.sh --ssh "ssh -i ~/ssh/sean -p 22 root@192.168.31.33" --env .env --db all

# Deploy only PostgreSQL and Redis with host kernel tuning
./deploy.sh --ssh "ssh -i ~/ssh/sean -p 22 root@192.168.31.33" --env .env --db postgres,redis --tune-host

# Simple user@host syntax is also supported
./deploy.sh --ssh "root@192.168.31.33" --env .env --db mongodb
```

### 3. Local Deployment

```bash
# Deploy all databases locally
./deploy.sh --local --env .env --db all

# Deploy only MySQL locally
./deploy.sh --local --env .env --db mysql
```

### 4. Interactive Wizard Mode

Simply run `./deploy.sh` without arguments to launch the step-by-step interactive wizard:

```bash
./deploy.sh
```

---

## ⚙️ Command-Line Options (`deploy.sh`)

| Option | Description |
|---|---|
| `-s, --ssh "<cmd>"` | Remote SSH command or connection target (e.g. `"ssh -i key.pem -p 22 root@host"` or `"root@host"`). |
| `-l, --local` | Run deployment on current local host. |
| `-e, --env <path>` | Path to `.env` file (default: `.env`). |
| `-d, --db <list>` | Databases to deploy: `postgres`, `mysql`, `mongodb`, `redis`, or `all` (comma-separated, default: `all`). |
| `-a, --action <act>` | Action to perform: `up` (default), `down`, `restart`, `status`, `logs`, `tune-host`. |
| `-r, --remote-dir <p>` | Remote directory path on destination server (default: `/opt/database-hub`). |
| `--tune-host` | Apply Linux kernel performance tuning (`vm.overcommit_memory=1`, THP disable, etc.). |
| `--install-docker` | Automatically install Docker CE & Docker Compose on remote if missing. |
| `-i, --interactive` | Launch interactive wizard. |
| `-h, --help` | Show help message. |

---

## 📊 Management & Maintenance Commands

### Check Health & Status

```bash
# Remotely
./deploy.sh --ssh "ssh -i ~/ssh/sean -p 22 root@192.168.31.33" --action status

# Locally
./deploy.sh --local --action status
```

### View Live Logs

```bash
# Remotely
./deploy.sh --ssh "ssh -i ~/ssh/sean -p 22 root@192.168.31.33" --action logs

# Locally
./deploy.sh --local --action logs
```

### Stop / Teardown Services

```bash
# Remotely
./deploy.sh --ssh "ssh -i ~/ssh/sean -p 22 root@192.168.31.33" --action down

# Locally
./deploy.sh --local --action down
```

---

## 🔧 Database Tuning Highlights

### 🐘 PostgreSQL 16
- **Shared Buffers & Cache**: Configurable directly via `POSTGRES_SHARED_BUFFERS=1GB` and `POSTGRES_EFFECTIVE_CACHE_SIZE=3GB`.
- **NVMe / SSD Storage**: `random_page_cost = 1.1`, `effective_io_concurrency = 200`.
- **Shared Memory**: `shm_size: 1g` (avoids default 64MB container limitation).
- **WAL & Checkpoints**: `checkpoint_completion_target = 0.9`, `wal_buffers = 16MB`, `max_wal_size = 4GB`.

### 🐬 MySQL 8.x
- **InnoDB Buffer Pool**: Set via `MYSQL_BUFFER_POOL_SIZE=1G`.
- **High Concurrency Throughput**: `innodb_flush_log_at_trx_commit = 2` (10x-50x write boost).
- **Direct I/O**: `innodb_flush_method = O_DIRECT` prevents double buffering in OS page cache.
- **Connection Latency**: `skip-name-resolve` disables DNS lookups on incoming client TCP connections.

### 🍃 MongoDB 7.0
- **WiredTiger Memory**: Controlled via `MONGO_CACHE_SIZE_GB=2`.
- **Compression & Indexing**: `snappy` block compression and prefix compression enabled.
- **Resource Limits**: Container `nofile: 65536` and `nproc: 65536`.

### ⚡ Redis 7.2
- **Multi-Threaded I/O**: `io-threads 4` and `io-threads-do-reads yes`.
- **Memory Management**: Configured via `REDIS_MAX_MEMORY=1gb` and `REDIS_MAXMEMORY_POLICY=allkeys-lru`.
- **Latency Protection**: Background non-blocking memory freeing (`lazyfree-lazy-eviction yes`).
- **Sysctls**: `net.core.somaxconn: 1024`.

---

## 🔒 Security Best Practices

1. **Firewall & Bind IP**: By default, ports bind to `BIND_IP=0.0.0.0`. If you only want local container-to-container access, change `BIND_IP=127.0.0.1` in your `.env`.
2. **Strong Passwords**: Never use default passwords in production. Set strong passwords in `.env`.
3. **Data Persistence**: All container data is stored in `${DATA_DIR:-./data}/<db_name>` on the host, ensuring data persists across updates and restarts.
