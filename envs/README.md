# Database Hub - Environment Configurations (`envs/`)

本目录按不同数据库与使用场景分类整理了环境配置文件模板（`.env.example`）。

> 🔒 **安全说明**：`.gitignore` 已配置忽略 `envs/**/*.env` 与真实配置文件，防止敏感账号密码被意外提交到 Git。所有的 `*.example` 模板文件会被正常版本控制。

---

## 📁 目录组织

```text
envs/
├── README.md                          # 本文档：说明与命令示例
├── postgres/
│   ├── dev.env.example                # 开发/测试环境（低内存开销）
│   └── prod-high-perf.env.example     # 生产环境（NVMe/SSD 优化，高缓存）
├── mysql/
│   ├── dev.env.example                # 开发测试（小型缓冲池）
│   └── prod-high-perf.env.example     # 生产环境（4GB+ 缓冲池，Direct I/O）
├── mongodb/
│   ├── dev.env.example                # 单机轻量开发测试
│   └── prod-high-perf.env.example     # 生产环境（WiredTiger 4GB 缓存，Snappy 压缩）
├── redis/
│   ├── cache-lru.env.example          # 高性能缓存模式（allkeys-lru）
│   └── persistent.env.example         # 持久化存储/消息队列模式（AOF+RDB, volatile-lru）
└── all/
    ├── dev.env.example                # 4 种数据库整合开发配置
    └── prod.env.example               # 4 种数据库整合生产高配
```

---

## 💡 多数据库 / 多实例部署原理（`INSTANCE_ID` 与端口规划）

当你在同一台服务器上部署**多个数据库实例**（例如业务 A 的 PostgreSQL 与业务 B 的 PostgreSQL，或多个不同业务线）时：

### 1. 为什么数据库只暴露一个端口？
每个数据库引擎标准协议下都只需要一个主网络端口：
- **PostgreSQL**：`5432`
- **MySQL**：`3306`
- **MongoDB**：`27017`
- **Redis**：`6379`

在 Docker 容器内部，监听端口永远是标准默认值；而宿主机映射端口（Host Port）可以在各自的 `.env` 中灵活指定。

### 2. 多实例隔离机制：
通过在 `.env` 中为每个实例指定独立的 **`INSTANCE_ID`** 与宿主机端口：
- **容器命名隔离**：自动命名为 `${INSTANCE_ID}-postgres`，避免容器名冲突。
- **Docker Compose 隔离**：使用 `-p ${INSTANCE_ID}` 独立栈隔离。
- **端口不冲突**：实例 A 监听 `5432`，实例 B 监听 `5433`。
- **自动备份定时器隔离**：Systemd 自动生成 `dbhub-backup-${INSTANCE_ID}.timer`，多套定时器独立自启、互不覆盖。
- **备份归档与轮转隔离**：备份文件包含 `${INSTANCE_ID}` 标记，自动按保留上限（Retention）清理旧备份时，绝不误删其他实例的备份！

---

## 🚀 部署实战命令示例

在使用之前，只需复制对应的 `.example` 为您自己的 `.env` 文件，并填写强密码：

### 示例 1: 部署第 1 套数据库（例如商城的 PostgreSQL，端口 5432）
```bash
# 复制模板并配置
cp envs/postgres/prod-high-perf.env.example envs/postgres/mall.env
# 在 mall.env 中设置:
# INSTANCE_ID=mall-db
# POSTGRES_PORT=5432

# 部署并开启自启动备份
./dbhub.sh --env envs/postgres/mall.env --db postgres --auto-backup
```

### 示例 2: 在同一台机器部署第 2 套数据库（例如计费系统的 PostgreSQL，端口 5433）
```bash
# 复制模板并配置
cp envs/postgres/prod-high-perf.env.example envs/postgres/billing.env
# 在 billing.env 中设置:
# INSTANCE_ID=billing-db
# POSTGRES_PORT=5433

# 部署并开启自启动备份
./dbhub.sh --env envs/postgres/billing.env --db postgres --auto-backup
```

### 示例 3: 远程部署 Redis 缓存
```bash
cp envs/redis/cache-lru.env.example envs/redis/cache.env

./dbhub.sh \
  --ssh "ssh -i ~/ssh/sean -p 22 root@192.168.31.33" \
  --env envs/redis/cache.env \
  --db redis
```

### 示例 4: 远程部署常见 Web 组合（PostgreSQL + Redis）
```bash
cp envs/all/prod.env.example envs/all/my-prod.env

./dbhub.sh \
  --ssh "ssh -i ~/ssh/sean -p 22 root@192.168.31.33" \
  --env envs/all/my-prod.env \
  --db postgres,redis
```

### 示例 5: 远程服务健康检查与备份状态监控
```bash
./dbhub.sh \
  --ssh "ssh -i ~/ssh/sean -p 22 root@192.168.31.33" \
  --env envs/postgres/mall.env \
  --action backup-status
```
