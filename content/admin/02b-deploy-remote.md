# 部署到服务器

> 本页是[部署：照着做](/admin/deploy)的**分支版**：只有第 1–3 步不同，第 4、5 步完全一样。
>
> 适用：代码在你这台电脑，服务要跑在另一台 Linux 服务器上。

## 和主线有什么区别

| 步骤 | 主线（本机） | 本页（服务器） |
| --- | --- | --- |
| 1 | 直接准备文件 | 1a 打包 → 1b 上传 → 1c 解压 |
| 2 | `docker-01-install.sh` | 同 |
| 3 | `docker-02-start.sh` | 同 |
| 4–5 | 开租户、验收 | 同 |

---

## 第 1a 步：打包

**在哪执行：【你的电脑 · 仓库根目录】**

```bash
cd /path/to/iot-rule-engine
bash shiyongshouce/downloads/deploy/docker-00-prepare.sh --pack
```

**你会看到**：

```
============================================================
 打包完成
============================================================

  发布包
    /Users/你/iot-rule-engine/dist/energy-deploy-20261020.tar.gz
    （410M）

  数据库密码（已写进包内 .env）
    7f948db0959105589ba8d115
    ⚠ 现在就记到密码管理器

------------------------------------------------------------
 下一步 A：在你自己的电脑上执行
------------------------------------------------------------

  scp /Users/你/.../energy-deploy-20261020.tar.gz root@1.2.3.4:/opt/

  把 root@1.2.3.4 换成 你的用户名@你的服务器IP
```

`root@1.2.3.4` 的含义是 **`服务器登录用户名@服务器IP`**：

- 用户名：常见 `root`；Ubuntu 云主机可能是 `ubuntu`
- IP：服务器公网地址
- 冒号后面是服务器上的路径

---

## 第 1b 步：上传

**在哪执行：【你的电脑 · 任意目录】**

把上一步输出的命令抄过来，替换 `root@1.2.3.4`：

```bash
scp /Users/你/iot-rule-engine/dist/energy-deploy-20261020.tar.gz root@1.2.3.4:/opt/
```

**你会看到**传输进度百分比，最后回到提示符。410 MB，约 1–10 分钟。

失败时：

| 报错 | 原因 | 处理 |
| --- | --- | --- |
| `Permission denied` | 用户名或密钥不对 | 确认 `root@` 前缀，或换 `ubuntu@` |
| `No such file or directory` | 服务器没有 `/opt` 或无写权限 | 改成 `root@1.2.3.4:~/` |
| `Connection refused` | SSH 端口不是 22 | 加 `-P 2222` |

也可以用 rsync（支持断点续传）：

```bash
rsync -avP dist/energy-deploy-20261020.tar.gz root@1.2.3.4:/opt/
```

---

## 第 1c 步：解压

**在哪执行：【服务器 · 任意目录】**

```bash
ssh root@1.2.3.4
```

登录后：

```bash
cd /opt
tar -xzf energy-deploy-20261020.tar.gz
cd energy-deploy
ls -a
```

**你应该看到 `.env`**（它在包里，不用手工创建）：

```
.  ..  .dockerignore  .env  allinone  data  docker-01-install.sh
docker-02-start.sh  docker-99-uninstall.sh  docker-compose.yml
guard-server-4.4.0.jar  logs  nginx  ngxai-backend  ngxai-dist  scripts
```

`.env` 里的 `APP_HOME` 是空值 —— **不要手动改**，下一步的脚本会自动填成 `/opt/energy-deploy`。

---

## 第 2 步：建库并初始化

**在哪执行：【服务器 · /opt/energy-deploy】**

```bash
cd /opt/energy-deploy
bash docker-01-install.sh
```

**你会看到**：

```
[..] 部署模式：split
  ✓ docker / compose / 文件 / 端口 检查通过
[..] 已把 .env 的 APP_HOME 修正为当前目录：/opt/energy-deploy
  ✓ 数据库健康（6s）
  ✓ install 完成：112 张表 / 726 个部件 / 34 个 bundle / 0 个用户

============================================================
 第 2 步完成：数据库已初始化
============================================================
```

> 如果服务器没装 Docker：
> ```bash
> curl -fsSL https://get.docker.com | sh
> sudo usermod -aG docker $USER && newgrp docker
> ```

---

## 第 3 步：启动服务并创建管理员

**在哪执行：【服务器 · /opt/energy-deploy】**

```bash
cd /opt/energy-deploy
bash docker-02-start.sh \
  --admin-email admin@example.com \
  --admin-pass 'ChangeMe123!'
```

**你会看到**：

```
  ✓ 服务已就绪（130s）：{"status":"ACCOUNT_REQUIRED"}
  ✓ 管理员已创建
  ✓ 系统管理员可登录，权限 SYS_ADMIN

============================================================
 第 3 步完成：服务已启动，管理员已就绪
============================================================
  访问地址
    http://localhost:8090/
    （服务器部署则用 http://服务器IP:8090/）
```

---

## 第 3.5 步：对外开放访问

服务本来能用了，但浏览器还进不来。两条路选一条。

### 路线一：直接开端口（最快，仅测试）

在云厂商控制台的**安全组**里放行 TCP 8090，然后浏览器打开 `http://服务器IP:8090/`。

### 路线二：Nginx 反代 + 域名（推荐正式用）

**在哪执行：【服务器 · 任意目录】**

```bash
apt install -y nginx

cat > /etc/nginx/conf.d/energy-public.conf <<'EOF'
server {
    listen 80;
    server_name 你的域名;

    client_max_body_size 50m;

    location / {
        proxy_pass http://127.0.0.1:8090;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        # WebSocket 必须，否则页面能开但数据不刷新
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
    }
}
EOF

nginx -t && systemctl reload nginx
```

有域名后配 HTTPS：

```bash
apt install -y certbot python3-certbot-nginx
certbot --nginx -d 你的域名
```

> 注意：这个 `energy-public.conf` 是**服务器上的系统 Nginx**，与容器内的 `energy-gateway` 是两层，互不冲突。前者负责 80/443 对外，后者负责容器内部路由。

---

## 第 4 步：开租户

**在哪执行：【服务器 · /opt/energy-deploy】**

```bash
cd /opt/energy-deploy
bash scripts/02-onboard.sh \
  --base http://127.0.0.1:8090 \
  --admin admin@example.com --admin-pass 'ChangeMe123!' \
  --tenant "环宇能源集团" \
  --tenant-email tenant@example.com --tenant-pass 'Tenant@12345' \
  --customer "星河工业园" \
  --customer-email customer@example.com --customer-pass 'Customer@123'
```

**你会看到**结尾 `✓ 全部验证通过`。

---

## 第 5 步：验收

**在哪执行：【服务器 · /opt/energy-deploy】**

```bash
cd /opt/energy-deploy
bash scripts/03-verify.sh \
  --base http://127.0.0.1:8090 \
  --tenant tenant@example.com --tenant-pass 'Tenant@12345' \
  --customer customer@example.com --customer-pass 'Customer@123' \
  --ai http://127.0.0.1:8090
```

**你会看到**：

```
==================================
  通过 22 / 失败 0
==================================
```

---

## 日常运维

**在哪执行：【服务器 · /opt/energy-deploy】**

```bash
cd /opt/energy-deploy

docker compose ps
docker compose logs -f --tail=100 gateway
docker compose restart energy-server

# 备份
docker compose exec -T postgres pg_dump -U postgres thingsboard \
  | gzip > /backup/thingsboard-$(date +%F).sql.gz
```

把备份拉回本地：

**在哪执行：【你的电脑 · 任意目录】**

```bash
scp root@1.2.3.4:/backup/thingsboard-2026-10-20.sql.gz ~/Downloads/
```

---

## 更新版本（保留数据）

**在哪执行：【你的电脑 · 仓库根目录】**

```bash
bash shiyongshouce/downloads/deploy/docker-00-prepare.sh --pack
```

**在哪执行：【你的电脑 · 任意目录】**

```bash
scp dist/energy-deploy-20261020.tar.gz root@1.2.3.4:/tmp/
```

**在哪执行：【服务器 · 任意目录】**

```bash
tar -xzf /tmp/energy-deploy-20261020.tar.gz -C /tmp/
cd /opt/energy-deploy
docker compose stop energy-server
cp /tmp/energy-deploy/guard-server-4.4.0.jar .
docker compose up -d energy-server
```

**不要**重跑 `docker-01-install.sh` —— 它会因为库非空而拒绝执行，这是保护机制。

---

## 常见失败

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `scp: command not found` | Windows 没装 OpenSSH | 用 PowerShell（自带 scp）或 WinSCP |
| 页面打不开 | 安全组没放行 / Nginx 没配 | 先在服务器上 `curl http://127.0.0.1:8090/` 确认本机可访问 |
| 能登录但不刷新数据 | Nginx 缺 WebSocket 头 | 检查 `Upgrade` / `Connection` 两行 |
| 容器反复重启 | 内存不足 | 改 `.env` 的 `SERVER_HEAP=1g`，重启 |
| `UnsupportedClassVersionError` | 镜像被改成 JDK 21 | 必须是 `eclipse-temurin:25-jre` |
