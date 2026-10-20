# Docker 安装与运维

> Docker 与 Compose 在 **Ubuntu** 和 **CentOS/RHEL** 上的安装、常用运维、磁盘调优。
> 只在这台机器上装一次，之后所有部署步骤都依赖它。

## 一、先确认系统

**在哪执行：【目标服务器 · 任意目录】**

```bash
cat /etc/os-release | head -3
uname -m
```

| 系统 | 支持情况 | 说明 |
| --- | --- | --- |
| Ubuntu 22.04 / 24.04 | ✅ 推荐 | 官方源支持，文档最全 |
| Debian 12 | ✅ 可用 | 步骤与 Ubuntu 基本相同 |
| Rocky / AlmaLinux 9 | ✅ 推荐 | CentOS 的替代品，官方源支持 |
| CentOS Stream 8 / 9 | ✅ 可用 | 同上，用 `dnf` |
| **CentOS 7** | ⚠️ 已 EOL | 官方源不再更新，只能装旧版，建议换 Rocky 9 |

> 判断依据是能否拿到新版 Docker。CentOS 7 于 2024-06 停止维护，不建议再用。

下面按系统选一节执行。

---

## 二、Ubuntu 安装

**在哪执行：【目标服务器 · 任意目录】**

### 1. 卸载可能存在的旧版本

```bash
sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
```

这只是清掉发行版自带的旧包，**不会**删除 `/var/lib/docker` 里的镜像和容器。

### 2. 添加官方源

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
```

### 3. 安装

```bash
sudo apt-get install -y \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
```

**`docker-compose-plugin` 是关键**：它提供 `docker compose`（v2，空格）。本手册所有脚本用的都是这个命令，不是老的 `docker-compose`（带连字符）。

### 4. 启动并设为开机自启

```bash
sudo systemctl enable --now docker
sudo systemctl status docker --no-pager
```

---

## 三、CentOS / RHEL / Rocky / Alma 安装

**在哪执行：【目标服务器 · 任意目录】**

### 1. 卸载旧版本

```bash
sudo dnf remove -y docker docker-client docker-client-latest docker-common \
  docker-latest docker-latest-logrotate docker-logrotate docker-engine 2>/dev/null || true
```

CentOS 7 用 `yum` 代替 `dnf`，命令其余部分相同。

### 2. 添加官方源

```bash
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
```

Rocky / Alma 也用这个源（它们与 RHEL 二进制兼容）。

### 3. 安装

```bash
sudo dnf install -y \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
```

### 4. 启动并设为开机自启

```bash
sudo systemctl enable --now docker
sudo systemctl status docker --no-pager
```

### CentOS 的两个坑

**① SELinux 导致挂载被拒**

CentOS 默认启用 SELinux。容器挂载宿主目录时报 `Permission denied`，先确认状态：

```bash
getenforce        # Enforcing 表示开着
```

两种处理：

```bash
# 方案 A（推荐）：给挂载目录打标签
sudo dnf install -y policycoreutils-python-utils
sudo semanage fcontext -a -t container_file_t "/opt/energy-app(/.*)?"
sudo restorecon -Rv /opt/energy-app

# 方案 B（简单粗暴，仅单机自用）：临时放宽
sudo setenforce 0
# 永久生效需改 /etc/selinux/config 的 SELINUX=permissive，然后重启
```

生产环境优先用方案 A。

**② firewalld 拦截端口**

```bash
sudo firewall-cmd --permanent --add-port=8090/tcp
sudo firewall-cmd --reload
sudo firewall-cmd --list-ports
```

Ubuntu 若启用了 ufw：

```bash
sudo ufw allow 8090/tcp
```

> 云服务器还要在控制台的**安全组**里放行，这是两层不同的防火墙。

---

## 四、国内网络：镜像加速

**在哪执行：【目标服务器 · 任意目录】**

拉取镜像慢或超时，配置 registry mirror：

```bash
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json > /dev/null <<'EOF'
{
  "registry-mirrors": ["https://docker.m.daocloud.io"]
}
EOF
sudo systemctl daemon-reload
sudo systemctl restart docker
```

验证是否生效：

```bash
docker info | grep -A 3 "Registry Mirrors"
```

⚠️ **公共镜像站经常失效或限流**，用之前先测：

```bash
docker pull hello-world && echo "镜像源可用"
```

失败就换一个，或去掉 `registry-mirrors` 直连。别把不可用的地址留在配置里 —— 它会让所有拉取都先超时。

---

## 五、非 root 用户使用 Docker

**在哪执行：【目标服务器 · 任意目录】**

默认只有 root 能跑 docker。加权限：

```bash
sudo usermod -aG docker $USER
newgrp docker          # 当前会话立即生效，或退出重新登录
docker ps              # 应该不再报 permission denied
```

> **安全提示**：`docker` 组等价于 root 权限（能挂载宿主根目录）。多人服务器上谨慎授权。

---

## 六、安装后自检

**在哪执行：【目标服务器 · 任意目录】**

```bash
docker version --format '{{.Server.Version}}'    # 期望 20.10+
docker compose version                            # 期望 v2.x
docker run --rm hello-world                       # 期望打印 Hello from Docker!
```

三条都通过，才算装好。任何一条失败先看下面「常见错误」。

---

## 七、日常运维

**在哪执行：【目标服务器 · 任意目录】**

### 服务管理

```bash
sudo systemctl start docker       # 启动
sudo systemctl stop docker        # 停止（容器会一起停）
sudo systemctl restart docker     # 重启
sudo systemctl status docker      # 状态
sudo systemctl enable docker      # 开机自启
sudo systemctl disable docker     # 取消自启
```

### 看日志

```bash
# Docker 守护进程自身的日志
sudo journalctl -u docker -n 100 --no-pager
sudo journalctl -u docker -f          # 实时跟踪

# 某个容器的日志
docker logs -f --tail=100 energy-gateway
```

### 升级 Docker

```bash
# Ubuntu
sudo apt-get update && sudo apt-get install -y --only-upgrade docker-ce docker-ce-cli containerd.io

# CentOS / Rocky
sudo dnf update -y docker-ce docker-ce-cli containerd.io

sudo systemctl restart docker
docker version
```

**升级会重启守护进程，容器会重启**。生产环境挑低峰期。

---

## 八、卸载 Docker

先分清要删的是什么：

| 想做的事 | 用哪 |
| --- | --- |
| 删掉本平台、保留 Docker 给别的项目用 | [卸载与重置](/admin/uninstall) 的 `docker-99-uninstall.sh` |
| Docker 本身也不要了（整机清理 / 重装系统前） | 本节 |

下面的命令会删除**这台机器上所有** Docker 容器、镜像、卷、网络。如果还有别的项目在跑，先看第一小节。

### 1. 卸载前：先看清楚会删什么

**在哪执行：【目标服务器 · 任意目录】**

```bash
# 正在运行的容器
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'

# 全部容器（含已停止的）
docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'

# 镜像、卷、占用空间
docker system df
docker volume ls
```

**如果有别的项目在跑，先停掉并备份**：

```bash
# 备份某个 PostgreSQL 容器的数据
docker exec <容器名> pg_dump -U postgres <库名> | gzip > ~/backup-$(date +%F).sql.gz
```

**本平台的数据**在命名卷 `energy-pgdata`（split 模式）或 `energy-allinone-data`（单容器模式）里：

```bash
docker volume ls --filter name=energy-
```

要先留一份：

```bash
# split 模式
docker compose -f ~/energy-app/docker-compose.yml exec -T postgres \
  pg_dump -U postgres thingsboard | gzip > ~/thingsboard-$(date +%F).sql.gz
```

### 2. Ubuntu / Debian 卸载

**在哪执行：【目标服务器 · 任意目录】**

```bash
# ① 停止并禁用服务
sudo systemctl stop docker docker.socket containerd 2>/dev/null || true
sudo systemctl disable docker docker.socket containerd 2>/dev/null || true

# ② 卸载软件包
sudo apt-get purge -y \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin \
  docker.io docker-doc docker-compose podman-docker containerd runc 2>/dev/null || true

# ③ 清理自动装上的依赖（不再被任何包使用的）
sudo apt-get autoremove -y --purge

# ④ 删除数据目录
sudo rm -rf /var/lib/docker /var/lib/containerd
sudo rm -rf /etc/docker /etc/containerd

# ⑤ 删除自定义的 apt 源与密钥
sudo rm -f /etc/apt/sources.list.d/docker.list
sudo rm -f /etc/apt/keyrings/docker.gpg
sudo apt-get update
```

第 ④ 步是真正释放空间的一步 —— 镜像和卷都在 `/var/lib/docker`。**执行前确认第 1 小节的备份已经做完。**

### 3. CentOS / RHEL / Rocky / Alma 卸载

**在哪执行：【目标服务器 · 任意目录】**

```bash
# ① 停止并禁用服务
sudo systemctl stop docker docker.socket containerd 2>/dev/null || true
sudo systemctl disable docker docker.socket containerd 2>/dev/null || true

# ② 卸载软件包
sudo dnf remove -y \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin \
  docker docker-client docker-common docker-engine 2>/dev/null || true

# ③ 删除数据目录
sudo rm -rf /var/lib/docker /var/lib/containerd
sudo rm -rf /etc/docker /etc/containerd

# ④ 删除 yum/dnf 源
sudo rm -f /etc/yum.repos.d/docker-ce.repo
sudo dnf clean all
```

CentOS 7 把 `dnf` 换成 `yum`。

**如果给挂载目录打过 SELinux 标签**，一并清掉（否则同名目录以后会被错误标记）：

```bash
sudo semanage fcontext -d "/opt/energy-app(/.*)?" 2>/dev/null || true
```

### 4. macOS（Docker Desktop）卸载

**在哪执行：【你的 Mac · 任意目录】**

先用界面卸载最稳妥：打开 Docker Desktop → 右上角设置 → Troubleshoot（虫子图标）→ **Uninstall**。

或手动删：

```bash
# 退出应用
osascript -e 'quit app "Docker"' 2>/dev/null || true
sleep 3

# 删应用
rm -rf /Applications/Docker.app

# 删用户数据（镜像、容器、卷全在这里，会释放大量空间）
rm -rf ~/Library/Containers/com.docker.docker
rm -rf ~/Library/Group\ Containers/group.com.docker
rm -rf ~/.docker

# 删命令行工具（如果装过）
sudo rm -f /usr/local/bin/docker /usr/local/bin/docker-compose \
             /usr/local/bin/docker-credential-desktop \
             /usr/local/bin/kubectl.docker
```

`~/Library/Containers/com.docker.docker` 里的 `Data/vms/0/data/Docker.raw` 是磁盘镜像文件，常有几十 GB，删掉立刻释放。

### 5. 验证是否卸干净

**在哪执行：【目标服务器 · 任意目录】**

```bash
# ① 命令应该不存在
command -v docker || echo "docker 命令已移除"

# ② 服务应该不存在
systemctl status docker 2>&1 | head -3

# ③ 数据目录应该不存在
ls -d /var/lib/docker /var/lib/containerd 2>/dev/null || echo "数据目录已删除"

# ④ 残留进程
ps aux | grep -E "dockerd|containerd" | grep -v grep || echo "无 Docker 进程"

# ⑤ 端口不再监听
ss -lntp 2>/dev/null | grep -E ":(2375|2376)\b" || echo "Docker API 端口已释放"
```

Linux 上如果 `docker` 命令还在，说明 PATH 里还有残留二进制：

```bash
sudo rm -f /usr/bin/docker /usr/bin/dockerd /usr/bin/containerd /usr/local/bin/docker*
```

### 6. 只想清数据、保留 Docker

不想卸载软件，只想把磁盘清空（比如重装本平台前）：

```bash
# ⚠️ 删除所有容器、镜像、卷、网络、缓存
docker system prune -a --volumes -f

# 确认
docker system df
```

这比卸载快得多，Docker 本身不用重装。**但 `--volumes` 会删掉所有命名卷**，包括数据库。

只清本平台的：

```bash
cd ~/energy-app
bash docker-99-uninstall.sh --purge --yes --images=app
```

详见[卸载与重置](/admin/uninstall)。

### 7. 卸载后重装

按本文第二节（Ubuntu）或第三节（CentOS）重新装即可。旧的数据目录已经删掉，重装后是全新的空环境。

如果想**保留数据目录重装**（例如只升级 Docker 版本但想留镜像）：

- 卸载时**跳过** `rm -rf /var/lib/docker`
- 重装后执行 `docker images` 确认镜像还在
- 版本跨大版本时可能不兼容，官方建议先 `docker save` 备份重要镜像

```bash
# 导出关键镜像（跨版本升级前）
docker save energy/allinone:4.4.0 | gzip > ~/allinone-image.tar.gz

# 重装后导入
gunzip -c ~/allinone-image.tar.gz | docker load
```

### 8. 卸载常见问题

**`Device or resource busy`（删不掉 `/var/lib/docker`）**

有进程还挂着这些文件：

```bash
sudo systemctl stop docker docker.socket containerd
sudo umount /var/lib/docker/* 2>/dev/null || true
# 找到占用者
sudo lsof +D /var/lib/docker 2>/dev/null | head
# 必要时重启后再删
sudo reboot
```

**卸载后磁盘空间没释放**

可能是容器日志或镜像层被其他进程持有，或删的是符号链接：

```bash
sudo du -sh /var/lib/docker 2>/dev/null
df -h /
```

重启后再看一次。仍不释放，检查是否 `data-root` 改过（第九节第 6 小节），实际数据在别处：

```bash
cat /etc/docker/daemon.json 2>/dev/null | grep data-root
```

**`docker` 命令还在，但服务没了**

PATH 里残留了二进制，见第 5 小节末尾的清理命令。

**重装后容器起不来**

旧数据目录残留导致版本不匹配。彻底删干净再来：

```bash
sudo rm -rf /var/lib/docker /var/lib/containerd
```

---

## 九、磁盘调优（重点）

Docker 占满磁盘是这套系统最常见的运维问题。三个来源，按占用从大到小：

| 来源 | 会不会自动回收 | 典型大小 |
| --- | --- | --- |
| 容器日志 | ❌ 不回收，无限增长 | 几 GB ~ 几十 GB |
| 构建缓存 | ❌ 不回收 | 十几 GB |
| 悬空镜像 | ❌ 不回收 | 几 GB |

### 1. 先看占了多少

```bash
docker system df          # 汇总
docker system df -v       # 明细：每个镜像/卷/缓存的大小
```

典型输出：

```
TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE
Images          28        7         25.32GB   21.15GB (83%)
Containers      7         3         246.6MB   4.188MB (1%)
Local Volumes   26        6         3.144GB   1.205GB (38%)
Build Cache     250       0         19.57GB   19.57GB
```

看 `RECLAIMABLE` 那一列 —— 那是删了能释放的空间。`ACTIVE 0` 且 `RECLAIMABLE` 等于总量的 Build Cache，删掉不影响任何正在运行的东西。

### 2. 清理命令（从安全到激进）

```bash
# ① 只清构建缓存（最安全，只影响下次构建速度）
docker builder prune -f

# ② 清悬空镜像（<none> 那些）和已停止的容器
docker image prune -f
docker container prune -f

# ③ 一键清所有未使用资源（镜像 + 容器 + 网络 + 构建缓存）
docker system prune -f
```

**`docker system prune -f` 不删命名卷**，数据库数据是安全的。

```bash
# ④ 连未使用的命名卷一起删
docker system prune -a --volumes -f
```

⚠️ **第 ④ 条危险**：它会删掉所有「当前没有容器在使用」的命名卷。如果 `energy-pgdata` 因为你执行过 `docker compose down` 而处于未使用状态，它也会被删，**数据库全丢**。

清理前后对比：

```bash
docker system df          # 清理前记一下
docker builder prune -f
docker system df          # 再看
```

### 3. 容器日志：最容易被忽略的大头

Docker 默认**不限制**容器日志大小，一个跑几个月的容器能写出几十 GB 的 `json.log`。

**根治：配置全局日志轮转**

```bash
sudo tee /etc/docker/daemon.json > /dev/null <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "5"
  }
}
EOF
sudo systemctl daemon-reload
sudo systemctl restart docker
```

含义：每个容器日志最多 50 MB，保留 5 个文件，单容器上限 250 MB。

> 本平台部署包里的 `docker-compose.yml` 已经为各服务配了这个限制，所以走 compose 部署的容器本来就有上限。但如果还有其他容器跑在同一台机器上，全局配置仍然值得加。

**已经写出去的旧日志要手动清**：

```bash
# 看每个容器的日志文件多大
sudo du -sh /var/lib/docker/containers/*/*-json.log 2>/dev/null | sort -h | tail -10
```

清空某个容器（**不要用 rm**，容器运行时会保持文件句柄，rm 后空间不释放）：

```bash
sudo truncate -s 0 /var/lib/docker/containers/<容器ID>/*-json.log
```

### 4. 清理策略一览

| 命令 | 删什么 | 影响 | 建议频率 |
| --- | --- | --- | --- |
| `docker builder prune -f` | 构建缓存 | 下次构建变慢 | 每月 / 磁盘告急时 |
| `docker image prune -f` | 悬空镜像 | 无 | 每月 |
| `docker container prune -f` | 已停止容器 | 无 | 每月 |
| `docker system prune -f` | 上述三者 + 未用网络 | 无（不碰命名卷） | 季度 |
| `docker system prune -a --volumes -f` | **含未使用命名卷** | **可能丢数据库** | 只在确定不要数据时 |

一条命令做例行维护：

```bash
docker builder prune -f && docker image prune -f
```

### 5. 只清本项目相关

不想影响同机其他项目时，按名字筛：

```bash
docker ps -a --filter name=energy-
docker volume ls --filter name=energy-
docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '^energy/'
```

### 6. 磁盘实在不够：迁移 data-root

Docker 默认把数据放 `/var/lib/docker`，在系统盘。系统盘小、数据盘大时，迁过去：

**在哪执行：【目标服务器 · 任意目录】**

```bash
# 1. 停服务
sudo systemctl stop docker

# 2. 确认新位置有足够空间
df -h /data

# 3. 复制（保留权限、硬链接、扩展属性）
sudo mkdir -p /data/docker
sudo rsync -aHAX --info=progress2 /var/lib/docker/ /data/docker/

# 4. 改配置
sudo tee /etc/docker/daemon.json > /dev/null <<'EOF'
{
  "data-root": "/data/docker"
}
EOF
sudo systemctl daemon-reload
sudo systemctl start docker

# 5. 验证
docker info | grep "Docker Root Dir"
docker images
```

确认镜像和容器都在之后，再删旧目录：

```bash
sudo rm -rf /var/lib/docker
```

**CentOS/Rocky 额外一步**（SELinux）：

```bash
sudo semanage fcontext -a -t container_var_lib_t "/data/docker(/.*)?"
sudo restorecon -Rv /data/docker
```

> 如果 `daemon.json` 里已有 `registry-mirrors` 或 `log-opts`，迁移时**要把它们一起写回去**，`tee` 会覆盖整个文件。

---

## 十、常见错误

### `Cannot connect to the Docker daemon`

守护进程没在跑。

```bash
sudo systemctl status docker      # 看状态
sudo systemctl start docker       # 启动
sudo journalctl -u docker -n 50   # 起不来看原因
```

macOS 上是 Docker Desktop 没启动，打开应用即可。

### `permission denied while trying to connect to the Docker daemon socket`

当前用户不在 `docker` 组：

```bash
sudo usermod -aG docker $USER && newgrp docker
```

### `docker: 'compose' is not a docker command`

装的是旧版（`docker-compose` 连字符），没有 v2 插件：

```bash
# Ubuntu
sudo apt-get install -y docker-compose-plugin
# CentOS / Rocky
sudo dnf install -y docker-compose-plugin
```

### `No space left on device`

按本文第九节清理。先 `docker system df` 看是谁占的。

### `pull access denied` / 拉取超时

```bash
# 先测网络
curl -I https://registry-1.docker.io/v2/

# 配镜像加速（见第四节）
```

### 端口被占用

```bash
# 谁在用
sudo lsof -nP -iTCP:8090 -sTCP:LISTEN
# 或
sudo ss -lntp | grep 8090
```

改 `.env` 里的 `HTTP_PORT` 换个端口，比停掉别人的服务省事。

### CentOS 上挂载目录报 `Permission denied`

SELinux，见本文第三节「CentOS 的两个坑」。

---

## 十一、与部署的关系

装好 Docker 后，回到[部署：照着做](/admin/deploy)从第 1 步开始。

部署阶段会用到：

| 命令 | 用在哪 |
| --- | --- |
| `docker compose up -d` | 启动服务 |
| `docker compose logs` | 看日志 |
| `docker compose exec` | 进容器（如执行 `pg_dump`） |
| `docker builder prune -f` | 磁盘告急时清理 |

部署完成后本页仍会反复用到：升级 Docker、排查磁盘、迁移数据目录。
