# ① Docker：安装、运维、卸载

> 这一页只管 Docker 本身。平台的部署在[② 平台部署](/admin/deploy)。
>
> 装一次、用很久，但**运维三件事必须知道**：磁盘会满、日志会涨、端口会冲突。
> 每节都给了现成命令，照着敲即可。

---

## 一、安装

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

## 二、一次性调优（装完就做）

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

## 三、日常运维

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

### 进入容器排查

```bash
docker compose exec energy-server sh
docker compose exec postgres psql -U postgres -d thingsboard
```

---

## 四、卸载 Docker

> 这一节会把**整台机器上所有 Docker 项目**的镜像和卷都删掉。
> 只想卸载本平台，看[② 平台部署](/admin/deploy)的「卸载平台」一节。

### 第一步：确认没有别的项目在跑

```bash
docker ps -a
docker volume ls
```

有别的项目的卷，先备份或迁走。

### 第二步：停止本项目并删掉数据

```bash
cd ~/energy-app
bash docker-99-uninstall.sh --purge --yes
```

### 第三步：卸载 Docker 引擎

**Ubuntu / Debian**：

```bash
sudo apt-get purge -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
sudo apt-get autoremove -y
```

**CentOS / Rocky / RHEL**：

```bash
sudo dnf remove -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
```

### 第四步：删除数据目录

```bash
sudo rm -rf /var/lib/docker
sudo rm -rf /var/lib/containerd
```

如果改过 `data-root`，还要删那个目录：

```bash
sudo rm -rf /data/docker
```

### 第五步：删配置与用户组

```bash
sudo rm -rf /etc/docker
sudo groupdel docker 2>/dev/null || true
```

### 第六步：验证

```bash
docker --version                  # 应提示 command not found
ls /var/lib/docker                # 应提示 No such file or directory
docker ps 2>&1 | head -2          # 应提示无法连接
```

三条都符合，才算卸干净。

---

## 五、常见问题

| 现象 | 原因 | 解决 |
| --- | --- | --- |
| `permission denied ... docker.sock` | 用户不在 docker 组 | `sudo usermod -aG docker $USER && newgrp docker` |
| `Cannot connect to the Docker daemon` | 没启动 | `sudo systemctl start docker` |
| 拉镜像 `EOF` / 超时 | 网络 | 配镜像加速（第二节） |
| 磁盘满，`df` 显示 100% | 构建缓存 + 日志 | 第三节的清理三连 |
| 日志文件几十 GB | 没配 log-opts | 第二节 daemon.json |
| `port is already allocated` | 端口被占 | `lsof -nP -iTCP:端口 -sTCP:LISTEN` 找出占用者 |
| 改 daemon.json 后 Docker 起不来 | JSON 语法错 | `sudo dockerd --validate` 看错误 |
| 容器时区不对 | 容器默认 UTC | 本平台镜像已固定 Asia/Shanghai，无需额外配 |

> 平台层面的故障（登录失败、报表空白、上报不通）见[常见问题](/admin/troubleshoot)。
