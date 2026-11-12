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

## 🚀 部署实战命令示例

在使用之前，只需复制对应的 `.example` 为您自己的 `.env` 文件，并填写强密码：

### 示例 1: 远程部署 PostgreSQL (生产高配置)
```bash
# 1. 复制模板并配置密码
cp envs/postgres/prod-high-perf.env.example envs/postgres/prod.env
# 编辑 envs/postgres/prod.env 修改密码

# 2. 远程部署（并应用 Linux 主机内核优化）
./deploy.sh \
  --ssh "ssh -i ~/ssh/sean -p 22 root@192.168.31.33" \
  --env envs/postgres/prod.env \
  --db postgres \
  --tune-host
```

---

### 示例 2: 远程部署 Redis 高性能缓存
```bash
# 1. 复制模板
cp envs/redis/cache-lru.env.example envs/redis/cache.env

# 2. 部署到远程服务器
./deploy.sh \
  --ssh "ssh -i ~/ssh/sean -p 22 root@192.168.31.33" \
  --env envs/redis/cache.env \
  --db redis
```

---

### 示例 3: 远程部署常见 Web 组合（PostgreSQL + Redis）
```bash
# 复制整合版环境文件
cp envs/all/prod.env.example envs/all/my-prod.env

# 指定部署 postgres 和 redis 两种数据库
./deploy.sh \
  --ssh "ssh -i ~/ssh/sean -p 22 root@192.168.31.33" \
  --env envs/all/my-prod.env \
  --db postgres,redis
```

---

### 示例 4: 远程部署 MySQL 8.x
```bash
cp envs/mysql/prod-high-perf.env.example envs/mysql/prod.env

./deploy.sh \
  --ssh "ssh -i ~/ssh/sean -p 22 root@192.168.31.33" \
  --env envs/mysql/prod.env \
  --db mysql
```

---

### 示例 5: 远程部署 MongoDB 7.0
```bash
cp envs/mongodb/prod-high-perf.env.example envs/mongodb/prod.env

./deploy.sh \
  --ssh "ssh -i ~/ssh/sean -p 22 root@192.168.31.33" \
  --env envs/mongodb/prod.env \
  --db mongodb
```

---

### 示例 6: 本地开发环境部署全部 4 种数据库
```bash
# 复制开发模板
cp envs/all/dev.env.example .env

# 本地快速拉起
./deploy.sh --local --env .env --db all
```

---

### 示例 7: 远程服务健康检查与状态监控
```bash
./deploy.sh \
  --ssh "ssh -i ~/ssh/sean -p 22 root@192.168.31.33" \
  --env envs/postgres/prod.env \
  --action status
```

---

### 示例 8: 实时查看远程容器运行日志
```bash
./deploy.sh \
  --ssh "ssh -i ~/ssh/sean -p 22 root@192.168.31.33" \
  --env envs/postgres/prod.env \
  --action logs
```
