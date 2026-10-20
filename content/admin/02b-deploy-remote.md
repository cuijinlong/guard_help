# 方案 B：从本地上传到服务器

> 代码在你的电脑，服务要跑在另一台 Linux 服务器上。本文每一步都标明**在哪台机器、cd 到哪个目录**。

**适用**：有一台云服务器（阿里云/腾讯云/AWS/自建机房），要 7×24 对外提供服务。

## 两台机器，六个位置

先认识本文会用到的两台机器和两个目录，后面所有命令都按这个约定标注：

| 标记 | 含义 |
| --- | --- |
| 【你的电脑 · 仓库根目录】 | 有 `guard-server`、`shiyongshouce` 的那一层 |
| 【你的电脑 · 任意目录】 | 无所谓，在哪都行 |
| 【服务器 · 任意目录】 | 刚 ssh 登录进去的默认位置 |
| 【服务器 · /opt/energy-app】 | 部署目录，下面会创建 |

`root@1.2.3.4` 这种写法是 **`用户名@服务器IP`**，换成你自己的即可：

- 用户名：常见 `root`；Ubuntu 云主机没开 root 时可能是 `ubuntu`
- IP：服务器公网地址
- 冒号后面是**服务器上的路径**

## 服务器前提

**在哪执行：【服务器 · 任意目录】**

```bash
docker version --format '{{.Server.Version}}'   # 需要 20.10+
docker compose version                          # 需要 v2
```

没装 Docker 的话（Ubuntu/Debian）：

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER && newgrp docker
```

内存 ≥ 4 GB，磁盘 ≥ 5 GB。

## 第 0 步：在本机打包

**在哪执行：【你的电脑 · 仓库根目录】**

```bash
cd /path/to/iot-rule-engine     # 换成你的仓库实际路径
bash shiyongshouce/downloads/deploy/docker-00-prepare.sh --pack
```

**你会看到**：

```
  ✓ 发布包：/Users/你/iot-rule-engine/dist/energy-deploy-20261020.tar.gz（409M）

下一步：把包传到服务器。下面的 root@1.2.3.4 换成 你的用户名@你的服务器IP。

  ── 在你自己的电脑上执行 ──
    scp /Users/你/.../dist/energy-deploy-20261020.tar.gz root@1.2.3.4:/opt/

  ── 登录服务器后执行 ──
    ssh root@1.2.3.4
    cd /opt && tar -xzf energy-deploy-20261020.tar.gz && cd energy-deploy
    bash docker-01-install.sh    # 会自动生成 .env，无需手工配置
```

> 提示「找不到 jar」：先 `cd guard-server && mvn package -DskipTests`，再回来打包。

## 第 1 步：上传到服务器

**在哪执行：【你的电脑 · 任意目录】**

把上一步输出里的命令抄过来，把 `root@1.2.3.4` 换成你的：

```bash
scp /Users/你/iot-rule-engine/dist/energy-deploy-20261020.tar.gz root@1.2.3.4:/opt/
```

**会看到**进度的百分比，最后回到提示符。409 MB，视带宽约 1–10 分钟。

**如果这一步失败**：

- `Permission denied` → 用户名或密码/密钥不对，确认 `root@` 前缀
- `No such file or directory` → 服务器上没有 `/opt` 或没有写权限，改成 `~/` 试：
  `scp ... root@1.2.3.4:~/`
- `Connection refused` → 服务器没开 SSH，或端口不是 22（加 `-P 2222`）

**其他上传方式**（任选其一，效果相同）：

```bash
# rsync，支持断点续传，大文件更稳
rsync -avP dist/energy-deploy-20261020.tar.gz root@1.2.3.4:/opt/

# 服务器有公网且你的仓库可被访问时，也可以在服务器上直接下载
# （多数私有仓库不适用，优先用 scp/rsync）
```

## 第 2 步：登录服务器并解压

**在哪执行：【服务器 · 任意目录】**

```bash
ssh root@1.2.3.4
```

登录后：

```bash
cd /opt
tar -xzf energy-deploy-20261020.tar.gz
cd energy-deploy
ls
```

**应看到**：

```
data  docker-01-install.sh  docker-02-start.sh  docker-99-uninstall.sh
docker-compose.yml  env.example  guard-server-4.4.0.jar  logs  scripts
```

> 现在你在 **【服务器 · /opt/energy-deploy】** 目录。记住这个位置，下面几步都在这里。
>
> 脚本内部会自己切到所在目录，即使你在别处执行也不会出错；文档写明 cd 是为了方便你 `pwd` 核对。

## 第 3 步：建库并初始化

**在哪执行：【服务器 · /opt/energy-deploy】**

```bash
cd /opt/energy-deploy
bash docker-01-install.sh
```

**不需要手工创建 `.env`** —— 脚本发现没有会自动生成：`APP_HOME` 填当前目录、数据库密码随机、端口冲突自动避让。

**预计输出**：

```
[17:14:03] 检查环境
[17:14:03] 未找到 .env，已自动生成（APP_HOME=/opt/energy-deploy，端口 8090/5432，密码随机）
  ✓ docker / compose / 文件 / 端口 检查通过
  ✓ 数据库健康（12s）
  ✓ install 完成：112 张表 / 726 个部件 / 34 个 bundle / 0 个用户

  ✓ 第 1 步完成
```

**记下数据库密码**：

```bash
grep DB_PASSWORD /opt/energy-deploy/.env
```

这串密码只有这里有，丢了只能重装。

## 第 4 步：启动服务并创建管理员

**在哪执行：【服务器 · /opt/energy-deploy】**

```bash
cd /opt/energy-deploy
bash docker-02-start.sh \
  --admin-email admin@example.com \
  --admin-pass 'ChangeMe123!'
```

**预计输出**：

```
[17:16:20] 启动服务
  ✓ 服务已就绪（130s）：{"status":"ACCOUNT_REQUIRED"}
  ✓ 管理员已创建
  ✓ 系统管理员可登录，权限 SYS_ADMIN

  ✓ 第 2 步完成
```

## 第 5 步：对外开放访问

此时服务只监听服务器本机。要让浏览器能访问，两条路：

**路线一：直接开端口（最快，仅测试用）**

在你买服务器的地方（安全组/防火墙）放行 TCP 8090，然后浏览器打开 `http://服务器IP:8090/`。

**路线二：Nginx 反代 + 域名（推荐正式用）**

**在哪执行：【服务器 · 任意目录】**

```bash
apt install -y nginx        # 或 yum install -y nginx

cat > /etc/nginx/conf.d/energy.conf <<'EOF'
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
        # WebSocket 必须
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
    }
}
EOF

nginx -t && systemctl reload nginx
```

再配 HTTPS（有域名后）：

```bash
apt install -y certbot python3-certbot-nginx
certbot --nginx -d 你的域名
```

> WebSocket 头漏了会导致页面能打开但数据不刷新。

## 第 6 步：开租户与开客户

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

**预计输出**：

```
  ✓ 租户已创建
  ✓ 租户管理员已激活并取得会话
  ✓ 客户已创建
  ✓ 客户管理员已创建并激活
  ✓ 能源参数字典：1 个
  ✓ 四个维度根齐全
  ✓ 全部验证通过
```

## 第 7 步：验收

**在哪执行：【服务器 · /opt/energy-deploy】**

```bash
cd /opt/energy-deploy
bash scripts/03-verify.sh \
  --base http://127.0.0.1:8090 \
  --tenant tenant@example.com --tenant-pass 'Tenant@12345' \
  --customer customer@example.com --customer-pass 'Customer@123'
```

**预计输出**：

```
  通过 17 / 失败 0
```

## 日常运维

**在哪执行：【服务器 · /opt/energy-deploy】**

```bash
cd /opt/energy-deploy

docker compose ps
docker compose logs -f --tail=100 server
docker compose restart server
docker compose stop
docker compose up -d

# 备份到服务器本地
docker compose exec -T postgres pg_dump -U postgres thingsboard \
  | gzip > /backup/thingsboard-$(date +%F).sql.gz
```

想把备份拉回本地：

**在哪执行：【你的电脑 · 任意目录】**

```bash
scp root@1.2.3.4:/backup/thingsboard-2026-10-20.sql.gz ~/Downloads/
```

## 更新版本

**在哪执行：【你的电脑 · 仓库根目录】** 重新打包

```bash
bash shiyongshouce/downloads/deploy/docker-00-prepare.sh --pack
```

**在哪执行：【你的电脑 · 任意目录】** 上传新的 jar

```bash
scp dist/energy-deploy-20261020.tar.gz root@1.2.3.4:/tmp/
```

**在哪执行：【服务器 · 任意目录】** 只替换 jar 并重启（**不要**重跑 install，会拒绝执行）

```bash
tar -xzf /tmp/energy-deploy-20261020.tar.gz -C /tmp/
cd /opt/energy-deploy
docker compose stop server
cp /tmp/energy-deploy/guard-server-4.4.0.jar .
docker compose up -d server
```

## 常见失败

- **`scp: command not found`** → 在 Windows 上用 PowerShell 自带 `scp`，或用 WinSCP
- **上传后 `tar: not found`** → 服务器极简系统，装 `tar`：`apt install -y tar`
- **页面打不开** → 先确认服务器本机能访问：`curl -s --noproxy '*' http://127.0.0.1:8090/`
- **能登录但数据不刷新** → Nginx 缺 WebSocket 头，检查 `Upgrade` / `Connection`
- **容器日志报 OOM** → 服务器内存不够，改 `.env` 的 `SERVER_HEAP=1g` 后重启

更多见[故障排查](/admin/troubleshoot)。卸载见[卸载与重置](/admin/uninstall)。
