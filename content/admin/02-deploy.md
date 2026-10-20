# 部署（Docker）

> 一台装了 Docker 的机器，四条命令上线。每一步都给出**命令**和**你会看到的输出**，对上了再往下走。

## 你会得到什么

| 组件 | 容器名 | 端口 | 数据在哪 |
| --- | --- | --- | --- |
| 应用服务 | `energy-server` | 8090 | 无状态，重启不丢 |
| PostgreSQL 16 | `energy-postgres` | 仅 127.0.0.1:5432 | Docker 卷 `energy-pgdata` |
| 部署文件 | — | — | 你指定的 `APP_HOME` 目录 |

设计上**不构建自定义镜像**：官方 JRE 镜像 + 挂载 jar 和 data。好处是镜像层里没有业务数据，卸载时删目录就真干净了。

## 前置要求

```bash
docker version --format '{{.Server.Version}}'   # 需要 20.10+
docker compose version                          # 需要 v2（有 "docker compose"，不是 docker-compose）
```

- 内存 ≥ 4 GB（JVM 2G + PostgreSQL）
- 端口 8090（对外）、5432（仅本机）未被占用
- 磁盘 ≥ 5 GB

## 第 0 步：准备发布包

发布包 = `jar + data（json/sql）+ compose + 脚本`，约 400 MB。

**方式 A：小文件从本站下载，大文件从构建机传**（推荐）

在服务器上：

```bash
mkdir -p /opt/energy-app/data/sql /opt/energy-app/logs
cd /opt/energy-app

# 1. 部署文件（几十 KB，直接下载）
curl -fsSLO https://guard-help.langmen.workers.dev/downloads/deploy/docker-compose.yml
curl -fsSLO https://guard-help.langmen.workers.dev/downloads/deploy/env.example
curl -fsSLO https://guard-help.langmen.workers.dev/downloads/deploy/docker-01-install.sh
curl -fsSLO https://guard-help.langmen.workers.dev/downloads/deploy/docker-02-start.sh
curl -fsSLO https://guard-help.langmen.workers.dev/downloads/deploy/docker-99-uninstall.sh
chmod +x docker-*.sh
cp env.example .env

# 3. 开通与验收脚本（后续两步要用）
mkdir -p scripts
curl -fsSL https://guard-help.langmen.workers.dev/downloads/scripts/02-onboard.sh -o scripts/02-onboard.sh
curl -fsSL https://guard-help.langmen.workers.dev/downloads/scripts/03-verify.sh  -o scripts/03-verify.sh
chmod +x scripts/*.sh

# 2. 建表脚本（8 个）
for f in schema-entities.sql schema-entities-idx.sql schema-entities-idx-psql-addon.sql \
         schema-functions.sql schema-views.sql schema-ts-psql.sql \
         schema-ts-latest-psql.sql schema-timescale.sql; do
  curl -fsSL "https://guard-help.langmen.workers.dev/downloads/sql/$f" -o "data/sql/$f"
done
```

再从**构建机**传两个大文件（jar 与 json 资源）：

```bash
scp guard-server/target/guard-server-4.4.0.jar user@server:/opt/energy-app/
rsync -a guard-server/src/main/data/json/ user@server:/opt/energy-app/data/json/
```

**方式 B：整包传输**

在构建机打包：

```bash
bash shiyongshouce/downloads/deploy/docker-00-package.sh /tmp/dist
# 输出：✓ 发布包：/tmp/dist/energy-deploy-20261020.tar.gz
scp /tmp/dist/energy-deploy-20261020.tar.gz user@server:/opt/
```

服务器上解压：

```bash
cd /opt && tar -xzf energy-deploy-20261020.tar.gz
mv energy-deploy /opt/energy-app
```

**检查目录结构**（这是后面一切的前提）：

```bash
cd /opt/energy-app && ls
```

期望看到：

```
data  docker-01-install.sh  docker-02-start.sh  docker-99-uninstall.sh
docker-compose.yml  env.example  guard-server-4.4.0.jar  logs
```

再确认两个必需目录：

```bash
ls data/sql/schema-entities.sql && ls -d data/json/system/widget_types
```

两条都必须成功。`data/sql` 下应有 8 个 `.sql` 文件。

## 第 1 步：配置 .env

```bash
cd /opt/energy-app
cp env.example .env
vi .env
```

必须改的只有三项：

```ini
APP_HOME=/opt/energy-app        # 必须与实际目录完全一致，且是绝对路径
DB_PASSWORD=换成你的强密码
HTTP_PORT=8090                  # 被占用时改这里
```

其余可保持默认。`SPRING_PROFILE=dev` 是单机内嵌队列模式，已实测可用。

> 验证：`grep APP_HOME .env` 输出的路径必须与 `pwd` 一致。

## 第 2 步：建库并初始化

```bash
bash docker-01-install.sh
```

这条命令会：检查环境 → 启动 PostgreSQL → 等健康 → 跑 install → 校验结果。

**预计输出**（首次拉镜像会多 1 分钟）：

```
[16:01:03] 检查环境
  ✓ docker / compose / 文件 / 端口 检查通过
[16:01:05] 启动 PostgreSQL（首次会拉取镜像，约 1 分钟）
  ✓ 数据库健康（6s）
[16:01:13] 执行 install（建表 + 装载系统资源，约 1-3 分钟）
  ✓ install 完成：112 张表 / 726 个部件 / 34 个 bundle / 0 个用户

  ✓ 第 1 步完成
```

**这一步之后的状态**：数据库有表、有系统部件，但**没有任何用户**，服务还没启动。这是正常的。

如果输出不是这个，看文末「常见失败」。

## 第 3 步：启动服务并创建管理员

```bash
bash docker-02-start.sh \
  --admin-email admin@example.com \
  --admin-pass 'ChangeMe123!'
```

**预计输出**：

```
[16:03:53] 启动服务
  ✓ 服务已就绪（100s）：{"status":"ACCOUNT_REQUIRED"}
[16:05:40] 创建系统管理员 admin@example.com
  ✓ 管理员已创建
  ✓ 系统管理员可登录，权限 SYS_ADMIN

  ✓ 第 2 步完成
   访问地址：http://<服务器IP>:8090/
```

浏览器打开 `http://<服务器IP>:8090/`，用这个邮箱密码登录，应进入首页。

> 为什么管理员要单独一步：`install` 不创建用户，第一个管理员只能由 `POST /api/noauth/setup/complete` 创建，且该接口只在库里没有 `SYS_ADMIN` 时接受请求。这是防止匿名者接管已开通实例的保护。

## 第 4 步：开租户与开客户

```bash
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
  ✓ 租户管理员已创建（待激活）
  ✓ 租户管理员已激活并取得会话
  ✓ 客户已创建
  ✓ 客户管理员已创建并激活（可用该邮箱登录）
  ✓ 能源参数字典：1 个
  ✓ 四个维度根齐全
  ✓ 系统部件：726 个
  ✓ 能耗管理部件：32 个
  ✓ 全部验证通过
```

脚本幂等，重复执行只会提示「已存在」，不会产生重复数据。

## 第 5 步：验收

```bash
bash scripts/03-verify.sh \
  --base http://127.0.0.1:8090 \
  --tenant tenant@example.com --tenant-pass 'Tenant@12345' \
  --customer customer@example.com --customer-pass 'Customer@123'
```

**预计输出**：

```
  通过 17 / 失败 0
```

看到这一行才算上线完成。任何 FAIL 都会打印具体项，按提示查[故障排查](/admin/troubleshoot)。

## 日常运维命令

```bash
cd /opt/energy-app

docker compose ps                      # 状态
docker compose logs -f --tail=100 server   # 跟踪日志
docker compose restart server          # 重启应用（数据库不动）
docker compose stop                    # 全部停止（数据保留）
docker compose up -d                   # 再启动
```

**备份数据库**：

```bash
docker compose exec -T postgres pg_dump -U postgres thingsboard \
  | gzip > /backup/thingsboard-$(date +%F).sql.gz
```

**恢复**：

```bash
gunzip -c /backup/thingsboard-2026-10-20.sql.gz \
  | docker compose exec -T postgres psql -U postgres -d thingsboard
```

## 常见失败

**`port is already allocated`**
改 `.env` 的 `HTTP_PORT` 或 `DB_PORT`，然后重跑当前步骤。

**`Mounts denied: path ... is not shared`**（仅 macOS Docker Desktop）
Docker Desktop 默认只共享 `/Users`、`/Volumes`。把部署目录放到用户目录下，或在 Docker Desktop → Settings → Resources → File Sharing 里加 `/opt`。

**`UnsupportedClassVersionError ... class file version 69.0`**
jar 是 Java 25 编译的，运行镜像必须用 `eclipse-temurin:25-jre`。compose 里已经是 25，不要改成 21。

**install 退出码非 0**
看 `/tmp/energy-install.log` 末尾。最常见是 `data/sql` 缺文件或 `data/json` 不完整。

**服务 240 秒未就绪**
```bash
docker compose logs --tail=80 server | grep -E "ERROR|Caused by"
```
多数是数据库密码与 `.env` 不一致，或内存不足被杀（`docker inspect energy-server --format '{{.State.OOMKilled}}'`）。

## 不用 Docker 的裸机部署

见[裸机部署](/admin/baremetal)。适用于不能装 Docker 或需要直接调 JVM 参数的场景。

## 卸载

见[卸载与重置](/admin/uninstall)。支持「只停服务保留数据」和「彻底删除不留痕」两种。
