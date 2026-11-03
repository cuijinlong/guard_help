# ① 安装环境（Docker）

> 这一页只管 Docker 本身。平台的部署在[② 系统部署](/admin/deploy)。
>
> 支持三种部署宿主机：**Ubuntu/Debian**、**CentOS 7 / RHEL / Rocky**、**macOS（Docker Desktop）**。
> 命令不通用，别跨段照抄 —— 尤其 CentOS 7 没有 `dnf`。
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

> 只出 Client 段、没有 Server 段 = daemon 没跑，接着往下装 / 启动。

---

### Ubuntu / Debian

支持 18.04 / 20.04 / 22.04 / 24.04，以及 Debian 11 / 12。

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

> Debian 要把上面两处 `ubuntu` 换成 `debian`，`VERSION_CODENAME` 保留即可。

---

### CentOS 7

> ⚠ **CentOS 7 没有 `dnf`** —— 网上一堆教程写 `dnf install`，在这台机器上会直接
> `command not found`。7 只能用 `yum`。

```bash
sudo yum install -y yum-utils device-mapper-persistent-data lvm2
sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo yum install -y docker-ce docker-ce-cli containerd.io
```

**Compose v2 插件单独装**（CentOS 7 的 Docker 源里常常没有 `docker-compose-plugin`，
装到最后一步报 `No package docker-compose-plugin available`）：

```bash
sudo mkdir -p /usr/local/lib/docker/cli-plugins
ARCH=$(uname -m)   # x86_64 或 aarch64
sudo curl -fSL "https://github.com/docker/compose/releases/download/v2.28.1/docker-compose-linux-${ARCH}" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
```

判据：`docker compose version` 出 `v2.x` 才算成（不是 `docker-compose version`）。

**CentOS 7 两个必查项**（不处理会在安装后半段才爆，很难定位）：

```bash
# ① SELinux 必须放过容器卷挂载，否则 postgres 起不来
#    报错长这样：Permission denied on /var/lib/postgresql/data
sudo setenforce 0                          # 临时（重启失效）
sudo sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config   # 永久

# ② firewalld 与 docker 的 iptables 会打架：宿主机能访问，局域网访问不了
sudo systemctl stop firewalld && sudo systemctl disable firewalld
#    要保留防火墙就必须放行业务端口，见下一条
```

> 客户环境必须开防火墙时，放行端口（至少 HTTP 与 MQTT）：
>
> ```bash
> sudo firewall-cmd --permanent --add-port=8090/tcp --add-port=1883/tcp
> sudo firewall-cmd --reload
> ```
>
> 注意 `docker run -p` 走的是 NAT，可能绕过 firewalld 规则。以「从另一台机器
> `curl http://<IP>:8090` 能通」为最终判据，别只看 `firewall-cmd --list-all`。

---

### CentOS 8+ / Rocky / AlmaLinux / RHEL

```bash
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
```

SELinux / firewalld 的处理与上面 CentOS 7 一致。

---

### macOS（Docker Desktop）

**不要用 brew 装 docker CLI**，那只有客户端，没有 daemon。必须装 Docker Desktop：

```bash
# Apple Silicon / Intel 同一个包，官网自动选
curl -fSL https://desktop.docker.com/mac/main/arm64/Docker.dmg -o /tmp/Docker.dmg
```

或者直接下载安装包：<https://docs.docker.com/desktop/install/mac-install/>

装完必须**手动启动一次**并同意条款（第一次会弹权限框，要点允许）：

```bash
open -a Docker
```

等菜单栏鲸鱼图标停止转动（首次 30-60 秒），然后验证：

```bash
docker version --format '{{.Server.Version}}'   # 要看到 27.x 这种 Server 版本
docker compose version                          # 要看到 v2.x
```

> macOS 没有 `systemctl`、没有 `/var/run/docker.sock` 的 root 属主概念，
> **也不要照搬手册里任何 `sudo` 开头的 docker 命令** —— Mac 上的 docker 本来就
> 不该用 sudo 跑，加了 sudo 反而会因为 socket 属主变成 root 而把环境搞坏。

**内存给够**：Docker Desktop → Settings → Resources，建议 ≥ 8 GB。
平台 split 模式要跑 postgres + cassandra + 后端 + 网关，4 GB 会 OOM。

**开机自启**（跑演示环境时建议开）：Settings → General →
`Start Docker Desktop when you sign in`。

---

### Linux 通用：启动 + 开机自启 + 免 sudo

```bash
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
newgrp docker       # 只对新 shell 生效，重开终端更省事
```

> **不做这两步，后面所有脚本都会报**「守护进程未运行 / 无权限」。这是最常见的卡点。
>
> 判据（一条命令分清楚）：
>
> ```bash
> docker info >/dev/null 2>&1 && echo "OK" || echo "还没好"
> sudo systemctl status docker --no-pager | head -5
> ```

---

### 验证

```bash
docker version --format '{{.Server.Version}}'
docker compose version
docker run --rm hello-world | head -3
```

三条全过才算装好。

---

## 一之二、装完仍报错？按症状对号入座

`docker info` 有三种失败形态，**修法完全不同**，别混着试。部署脚本（
`docker-01-install.sh` / `docker-02-start.sh`）已经内置了这个判别，会自动
尝试拉起 daemon 并按平台给出对应命令；下面是你需要手工介入时的对照表。

### ① 立刻报错 `Cannot connect to the Docker daemon`

daemon 没启动。Linux：`sudo systemctl start docker`。
macOS：`open -a Docker` 等鲸鱼图标停止转动。

### ② 立刻报错 `permission denied ... docker.sock`

daemon 在跑，是权限问题。

```bash
sudo usermod -aG docker $USER && newgrp docker
```

macOS 上一般不会出现；真遇到了先看 context：`docker context ls`，不对就
`docker context use desktop-linux`。

### ③ 命令**卡住不返回**（等几十秒到几分钟，不报错也不退出）

这是最容易被误判成「没装 / 没启动」的形态。**daemon 进程在、socket 文件也在，
但就是不应答。** 实测于 macOS 的 Docker Desktop：宿主侧 socket 转发卡死，
VM 里的 dockerd 其实是好的。

```bash
# 判据：socket 存在但 _ping 超时
ls -l ~/.docker/run/docker.sock
curl -s -m 5 --unix-socket ~/.docker/run/docker.sock http://localhost/_ping   # 超时即命中
```

**macOS 修法**（`quit` 常常无效，进程赖着不走 —— 那本身就是它卡住的证据）：

```bash
osascript -e 'quit app "Docker"'
# 等 30 秒；backend 还在就强杀
pkill -f com.docker.backend
open -a Docker
```

**Linux 修法**：

```bash
sudo systemctl restart docker
sudo journalctl -u docker -n 50 --no-pager    # 看它为什么卡
```

> 卡死状态下**不要**直接 `docker compose down` / 重跑安装脚本 —— 它们全都会挂住。
> 先把 daemon 救活。

---

## 二、调优（装完就做）

> 本节命令都是 **Linux 路径**（`/etc/docker/daemon.json` + `systemctl`）。
> **macOS 上没有这些文件，也不要 `sudo`** —— 在 Docker Desktop 里改：
> Settings → Docker Engine，把同样的 JSON 填进编辑框，点 Apply & Restart。
> 「根目录换盘」在 Mac 上叫 Settings → Resources → Disk image location。

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

> **默认后端是 SQL（Postgres 存遥测），命令要不要带 `--profile cassandra`？**
>
> 2026-11-03 起默认 `DATABASE_TS_TYPE=sql`（旧逻辑是「物理内存 ≥10GB 就选
> cassandra」）。业务代码里的峰谷分析、电能质量、手册的运维 SQL 全部基于
> `ts_kv` 表，Cassandra 部署下这些路径要么报错要么退化。详见下面「Cassandra」一节。
>
> 只有明确指定 `DATABASE_TS_TYPE=cassandra` 时才有 Cassandra 容器。
> 带不带 `--profile cassandra` 的对照：
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

### 用 Cassandra 会损失什么（2026-11-03 实测）

选 Cassandra **不是**“换个更快的存储”那么简单 —— 有一批功能会变慢或不可用。
切之前先确认这些都能接受：

| 功能 | SQL 后端 | Cassandra 后端 |
| --- | --- | --- |
| 峰谷分析（tou-analysis） | 一条 SQL 算小时桶 | 不能直查，退化为逐时段读；**慢一个数量级** |
| 电能质量数据集圈选 | `INSERT…SELECT` 直接搬 | 读回 JVM 再写；**大量数据时内存吃紧** |
| 手册的运维 SQL（⑩） | 可执行 | **一条都跑不了**（ts_kv 不存在） |
| 抄表树“最近有数据优先”排序 | 查 ts_kv | 改查 ts_kv_latest，语义一致 |
| 设备参数报表 / 基础报表 | 正常 | 正常（走 timeseriesService） |

平台已经做了适配：查历史前会先探测后端类型（`TelemetryBackend`），
走不通就自动降级，不会再把 500 砸给用户。**但降级就是慢** ——
数据量大时差异很明显。

> 判据：`docker exec energy-server env | grep DATABASE_TS_TYPE`。
> 如果看到 `cassandra` 而你并不需要它（只是内存大），建议改成 `sql` 重建库 ——
> `/workspace/iot-rule-engine` 的 `docker-00-prepare.sh` 现在默认就是 sql。
