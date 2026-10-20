# 部署模式：单容器 or 分容器

> 同一套代码，两种装法。安装前选一次，写在 `.env` 的 `DEPLOY_MODE` 里。

## 一、先看区别

| | 分容器 `split`（默认） | 单容器 `allinone` |
| --- | --- | --- |
| 容器数 | 4 个（postgres / java / python / nginx） | 1 个 |
| 对外端口 | 1 个（nginx） | 1 个 |
| 单独重启某组件 | ✅ `docker compose restart energy-server` | ❌ 只能重启整个容器 |
| 单独看某组件日志 | ✅ `docker logs energy-server` | ⚠️ 分文件：`/var/lib/energy/logs/*.log` |
| 镜像体积 | 小（公共镜像复用） | 大（约 3 GB） |
| 首次构建 | 只构建 ngx-ai 后端（约 5-10 分钟） | 构建完整镜像（约 10-20 分钟） |
| 升级某个组件 | ✅ 替换 jar 重启即可 | ❌ 重建整个镜像 |
| 适合 | 生产、需要排障与灰度 | 试用、边缘设备、单机演示 |

两者功能完全一致：都跑通了 22 项验收（含 ngx-ai 5 项）。

## 二、怎么选

```bash
cd ~/energy-app
vi .env
```

```ini
# 分容器（默认，推荐生产用）
DEPLOY_MODE=split

# 单容器（试用、边缘设备）
DEPLOY_MODE=allinone
```

改完直接跑后续步骤，脚本会自动按模式选 compose profile 与等待时间。

## 三、分容器模式

### 架构

```
浏览器 :8090
    │
    ▼
energy-gateway (nginx)
    ├── /          → energy-server (Java, 8090，仅内网)
    ├── /ngxai/    → 静态文件（容器内直接发）
    ├── /ngxapi/   → energy-ngxai-backend (Python, 18801，仅内网)
    └── /api/...   → energy-server

energy-postgres (仅内网，无端口映射)
```

### 命令

```bash
cd ~/energy-app

bash docker-01-install.sh                       # 建库 + install
bash docker-02-start.sh --admin-email ... --admin-pass ...
```

### 单组件操作

```bash
cd ~/energy-app

docker compose --profile split ps
docker compose --profile split logs -f --tail=100 energy-server
docker compose --profile split restart energy-server
docker compose --profile split restart energy-ngxai-backend

# 只更新 jar（不动数据库）
docker compose --profile split stop energy-server
cp /path/to/new/guard-server-4.4.0.jar .
docker compose --profile split up -d energy-server
```

## 四、单容器模式

### 架构

```
浏览器 :8090
    │
    ▼
energy-allinone（一个容器内）
    nginx :80 ──┬── /         → Java :8090
                ├── /ngxai/  → 本地静态文件
                └── /ngxapi/ → Python :18801
    PostgreSQL :5432（仅 127.0.0.1）
```

### 命令

```bash
cd ~/energy-app

bash docker-01-install.sh    # 只做检查，提示"install 由容器自动完成"
bash docker-02-start.sh --admin-email ... --admin-pass ...
```

首次启动时容器内会自动：初始化 PostgreSQL → install → 启动 Java/Python/Nginx。约 3–5 分钟。

### 操作

```bash
cd ~/energy-app

docker logs -f --tail=100 energy-allinone        # 合并日志
docker exec energy-allinone tail -f /var/lib/energy/logs/energy-server.log

# 各组件日志分开在容器内
docker exec energy-allinone ls /var/lib/energy/logs/
#   install.log  postgres.log  energy-server.log  ngxai-backend.log  nginx.log  supervisord.log

# 重启整个服务
docker compose --profile allinone restart allinone

# 重启单个进程（容器内 supervisord）
docker exec energy-allinone supervisorctl restart energy-server
docker exec energy-allinone supervisorctl status
```

### 数据在哪

```bash
# 命名卷 energy-allinone-data，挂到容器 /var/lib/energy
docker volume inspect energy-allinone-data

docker exec energy-allinone ls /var/lib/energy/
#   pgdata/  logs/  run/
```

备份：

```bash
docker exec energy-allinone su postgres -c \
  "pg_dump -U postgres thingsboard" | gzip > ~/thingsboard-$(date +%F).sql.gz
```

## 五、切换模式

两者数据互不通用（分容器用 `energy-pgdata`，单容器用 `energy-allinone-data`）。切换等于重装：

```bash
cd ~/energy-app

# 1. 先备份（如果旧模式有数据）
docker compose --profile split exec -T postgres pg_dump -U postgres thingsboard \
  | gzip > ~/backup-before-switch.sql.gz

# 2. 卸载旧模式（保留镜像）
bash docker-99-uninstall.sh --purge --yes --images=none

# 3. 重新准备并选新模式
cd /path/to/iot-rule-engine
bash shiyongshouce/downloads/deploy/docker-00-prepare.sh
vi ~/energy-app/.env      # 改 DEPLOY_MODE
bash ~/energy-app/docker-01-install.sh
```

## 六、镜像与卸载

卸载脚本的 `--images` 参数独立控制镜像去留：

```bash
# 只停服务，数据与镜像都留着（最快再起）
bash docker-99-uninstall.sh

# 删容器/卷/目录，但保留镜像（下次部署省 5-20 分钟）
bash docker-99-uninstall.sh --purge --yes --images=none

# 删容器/卷/目录 + 自建镜像（energy/ngxai-backend、energy/allinone）
bash docker-99-uninstall.sh --purge --yes --images=app

# 连公共基础镜像一起删（postgres/nginx/temurin/python/node）
bash docker-99-uninstall.sh --purge --yes --images=all
```

**默认 `--images=none`**，因为：

- ngx-ai 后端镜像要 pip 装依赖 + 编译 Stan，重建 5–10 分钟
- 单容器镜像更大，重建 10–20 分钟
- 公共镜像往往被别的项目复用，删了会影响别人

详见[卸载与重置](/admin/uninstall)。

## 七、两种模式的实测结果

| 项目 | split | allinone |
| --- | --- | --- |
| install | 112 表 / 726 部件 / 34 bundle | 同（容器内自动完成） |
| 首次就绪耗时 | 约 100–160 秒 | 约 180–210 秒 |
| 验收脚本 | 22 通过 / 0 失败 | 22 通过 / 0 失败 |
| ngx-ai 前端 | ✅ `/ngxai/` | ✅ `/ngxai/` |
| ngx-ai 后端 | ✅ `/ngxapi/health` | ✅ `/ngxapi/health` |
| 深链接刷新 | ✅ | ✅ |
| 静态资源 | ✅ | ✅ |
| 卸载残留 | 5 项全空 | 5 项全空 |
