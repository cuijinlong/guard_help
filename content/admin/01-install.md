# ① 安装环境（Docker）

> 这一页只管 Docker 本身。平台的部署在[② 平台部署](/admin/deploy)。
>
> 装一次、用很久，但**运维三件事必须知道**：磁盘会满、日志会涨、端口会冲突。
> 每节都给了现成命令，照着敲即可。

---

## 一、装 Docker

### 先检查有没有装

```bash
docker version --format '{{.Server.Version}}'
docker compose version
```

两条都出结果（Docker ≥ 20.10、Compose ≥ v2）就**跳到第二节**。

### Ubuntu / Debian

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
```

### CentOS / Rocky / RHEL

```bash
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
```

### 启动并开机自启

```bash
sudo systemctl enable --now docker
```

### 让当前用户免 sudo 用 docker

```bash
sudo usermod -aG docker $USER
newgrp docker
```

> **不执行这一步，后面所有脚本都会报**
> `docker 守护进程未运行（或当前用户无权限）`。这是最常见的卡点。

### 验证

```bash
docker version --format '{{.Server.Version}}'
docker compose version
docker run --rm hello-world | head -3
```

---

## 二、调优（装完就做）

### 1. 配镜像加速 + 日志轮转

国内拉镜像慢，以及**容器日志默认无限增长**（跑几个月能把磁盘塞满）—— 一起解决：

```bash
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json > /dev/null <<'EOF'
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://dockerproxy.com"
  ],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3"
  }
}
EOF
sudo systemctl restart docker
docker info | grep -A3 "Registry Mirrors"
```

改完后**每个容器日志最多占 150MB**（50m × 3），不再无限涨。

### 2. Docker 根目录换到大盘（可选）

`/var/lib/docker` 在系统盘、镜像和卷几十 GB 时会把根分区撑爆。换到数据盘：

```bash
# 假设大盘挂在 /data
sudo systemctl stop docker
sudo mkdir -p /data/docker
sudo rsync -aHAX /var/lib/docker/ /data/docker/
sudo tee /etc/docker/daemon.json > /dev/null <<'EOF'
{
  "data-root": "/data/docker",
  "registry-mirrors": ["https://docker.m.daocloud.io"],
  "log-opts": { "max-size": "50m", "max-file": "3" },
  "log-driver": "json-file"
}
EOF
sudo systemctl start docker
docker info | grep "Docker Root Dir"
```

确认新目录生效后，再删旧目录：

```bash
sudo rm -rf /var/lib/docker
```

> **注意**：`data-root` 改完，**已有的容器和镜像不会自动搬过去**。
> 上面的 `rsync` 就是干这个的，别省。搬之前先 `docker ps` 确认服务能停。

---

## 三、Docker 日常运维

### 看磁盘占用

```bash
docker system df
```

输出四行：Images / Containers / Local Volumes / **Build Cache**。

**构建缓存经常是最大的一块**（几次重构下来能到几十 GB），而且 `docker system prune`
默认只清一部分。

### 清理构建缓存（最常做）

```bash
docker builder prune -f
```

**这是最安全的一项**：只删构建中间层，正在运行的容器、镜像、卷都不动。
改完代码重新构建慢一点，但磁盘立刻回来。

看能回收多少（不实际删）：

```bash
docker builder prune --all --dry-run 2>/dev/null || docker system df
```

### 清理悬空镜像

```bash
docker image prune -f
```

只删 `<none>:<none>` 的中间镜像。加 `-a` 会删**所有**没被容器使用的镜像 ——
下次启动要重新拉，别随手加。

### 清理停止的容器

```bash
docker container prune -f
```

### 一套完整清理（安全版）

```bash
docker builder prune -f
docker image prune -f
docker container prune -f
docker system df      # 再确认一次
```

**不要用这个**：

```bash
docker system prune -a --volumes -f      # ⚠️ 会删掉未使用的命名卷
```

`--volumes` 会把数据库卷一起删掉 —— 如果那一刻容器刚好没在跑，数据就没了。
清理卷只应该在**确认不要数据**时手工删：

```bash
docker volume ls
docker volume rm <卷名>
```

### 清空某个容器日志（磁盘告急时）

配了 `log-opts` 之后不会无限涨，但已经涨起来的要先清：

```bash
# 把 <容器名> 换成实际的
sudo truncate -s 0 $(docker inspect --format='{{.LogPath}}' <容器名>)
```

`truncate` 而不是 `rm`：删文件后 Docker 还持有句柄，空间不会释放。

### 看容器占用

```bash
docker stats --no-stream
```

看单个容器的日志尾巴：

```bash
docker compose logs -f --tail=100 energy-server
docker compose logs --since 30m gateway
```

### 重启与重建

```bash
# 只重启，不重建
docker compose restart energy-server

# 改了 compose 或 .env：重建容器
docker compose --profile split up -d

# 强制作废镜像重建（改了 Dockerfile）
docker compose --profile split up -d --build
```

> **默认后端是 Cassandra，命令要不要带 `--profile cassandra`？**
>
> | 命令 | 要不要带 | 原因 |
> | --- | --- | --- |
> | `restart energy-server` | 不用 | 只重启已有容器 |
> | `up -d energy-server` | 不用 | 只动指定的服务 |
> | `exec -T postgres …` | 不用 | 只进 postgres |
> | `up -d`（不带服务名） | **建议带** | 否则日志里有 orphan 提示；不影响运行 |
> | `down` | **必须带** | 不带的话 Cassandra 容器会成为孤儿，`down -v` 也删不掉它的卷 |
>
> 最稳妥：直接带上 `--profile split --profile cassandra`，或者用
> `bash scripts/11-cassandra.sh status` 确认后端与容器状态。

### 进入容器排查

```bash
docker compose exec energy-server sh
docker compose exec postgres psql -U postgres -d thingsboard
```

---

---

## 四、可选：遥测换成 Cassandra

**默认不换。** 平台默认 `DATABASE_TS_TYPE=sql`，遥测与实体同库（`ts_kv` 分区表）。
这个默认值在**单机、几十台表、几千万点**的规模下完全够用，而且备份/恢复简单。

### 什么时候才该换

| 规模 | 建议 |
| --- | --- |
| ≤ 100 台表，1 年内 | **保持 SQL** |
| 100~500 台表，多点位 | SQL 仍可以，注意 `ts_kv` 分区与磁盘 |
| > 500 台表 / 上亿点 / 要水平扩展 | 考虑 Cassandra |

判据：`ts_kv` 单表超过 200GB，或遥测写入成为瓶颈。

### 切换的两个坑

**① 只改 `.env` 再重启 = 数据全丢**

```
遥测是按后端类型分库存的：
  SQL          → postgres 的 ts_kv
  Cassandra    → cassandra 的 thingsboard keyspace
改 DATABASE_TS_TYPE 只是换了读取端，旧数据留在原库不动 ——
页面表现为「设备有、数据全空」，看起来像坏了。
```

**切换前必须**：备份 `ts_kv`，切完之后重新灌数据（或写迁移脚本）。

**② Cassandra 内存要求高**

默认 JVM 堆 4GB 起步。**8GB 内存的机器开 Cassandra 会把平台挤到 swap**，
表现为「Cassandra 无限重启 + 平台 502」。

判据：`docker stats` 看 cassandra 容器 RSS 是否接近物理内存上限。
8GB 机器建议直接放弃 Cassandra。

### 验证真的在工作

```bash
# ① 后端确实是 cassandra 模式
docker compose exec -T energy-server env | grep DATABASE_TS_TYPE
# 期望：DATABASE_TS_TYPE=cassandra

# ② Cassandra 里有数据
docker compose exec -T cassandra nodetool tablestats thingsboard.ts_kv | head -20

# ③ 平台能读出来（不是只看写）
curl -s -H "X-Authorization: Bearer $TOKEN" \
  "http://127.0.0.1:8090/api/plugins/telemetry/DEVICE/<设备id>/values/timeseries?keys=energy&limit=5"
```

**三者都对才算切换成功。** ① 对但 ③ 空 → 数据没迁过来。

### 集群运维速查

| 要做什么 | 命令 |
| --- | --- |
| 看节点状态 | `nodetool status` |
| 看表大小 | `nodetool tablestats thingsboard.ts_kv` |
| 修复一致性 | `nodetool repair thingsboard` |
| 清理已删数据 | `nodetool cleanup thingsboard` |
| 快照备份 | `nodetool snapshot -t <tag> thingsboard` |

> 平台的数据卷在 `~/energy-app`。**Cassandra 恢复比 SQL 麻烦得多**，
> 这也是默认不用它的原因之一。
