# 部署（照着做）

> 本页是从零到能用的**唯一主线**。全程 5 条命令，按顺序复制执行即可。
> 部署到另一台服务器、或用单容器模式，在最后一节说明。

## 先决条件：装好 Docker

在开始之前，目标机器上必须有 Docker 20.10+ 和 Compose v2：

```bash
docker version --format '{{.Server.Version}}'
docker compose version
```

两条都不通过，先看[Docker 安装与运维](/admin/docker-ops)：

- [Ubuntu 安装](/admin/docker-ops)（第二节）
- [CentOS / RHEL / Rocky 安装](/admin/docker-ops)（第三节）
- 国内网络慢 → 镜像加速（第四节）
- 非 root 用户 → 加 docker 组（第五节）

装好后回到本页，从第 1 步开始。

## 全程就这 5 条命令

假设你在**当前这台机器**上部署（最常用）：

| # | 在哪执行 | 命令 | 大约耗时 |
| --- | --- | --- | --- |
| 1 | 仓库根目录 | `bash shiyongshouce/downloads/deploy/docker-00-prepare.sh` | 1 分钟 |
| 2 | `~/energy-app` | `bash docker-01-install.sh` | 2–3 分钟 |
| 3 | `~/energy-app` | `bash docker-02-start.sh --admin-email admin@example.com --admin-pass 'ChangeMe123!'` | 5–10 分钟 |
| 4 | `~/energy-app` | `bash scripts/02-onboard.sh ...`（见第 4 步） | 30 秒 |
| 5 | `~/energy-app` | `bash scripts/03-verify.sh ...`（见第 5 步） | 1 分钟 |

第 2 步之后就能用浏览器登录了。第 4、5 步是开租户和验收，可以晚点做。

---

## 第 1 步：准备文件

**在哪执行：【仓库根目录】** —— 就是有 `guard-server/`、`shiyongshouce/` 的那一层。

```bash
cd /path/to/iot-rule-engine
bash shiyongshouce/downloads/deploy/docker-00-prepare.sh
```

**你会看到**：

```
============================================================
 第 1 步完成：部署文件已准备好
============================================================

  部署目录
    /Users/你/energy-app
    （脚本默认装到 ~/energy-app，不是当前目录）

  配置文件
    /Users/你/energy-app/.env
    （隐藏文件，ls 看不到；要看内容用：cat /Users/你/energy-app/.env）

  数据库密码
    7f948db0959105589ba8d115
    ⚠ 现在就记到密码管理器，重装时还要用

------------------------------------------------------------
 下一步：复制下面这一整行执行
------------------------------------------------------------

  cd /Users/你/energy-app && bash docker-01-install.sh
```

**关于 `.env`**：它是**隐藏文件**，`ls` 默认不显示，要 `ls -a` 或 `cat .env` 才能看到。脚本已经替你生成好了，**不需要手工创建**。

**如果没有看到这段输出**，或者提示「找不到 jar」：

```bash
cd guard-server && mvn package -DskipTests && cd ..
bash shiyongshouce/downloads/deploy/docker-00-prepare.sh
```

---

## 第 2 步：建库并初始化

**在哪执行：【`~/energy-app`】**

```bash
cd ~/energy-app
bash docker-01-install.sh
```

**你会看到**：

```
  ✓ docker / compose / 文件 / 端口 检查通过
  ✓ 数据库健康（6s）
  ✓ install 完成：112 张表 / 726 个部件 / 34 个 bundle / 0 个用户

============================================================
 第 2 步完成：数据库已初始化
============================================================
  用户数为 0 是正常的：install 只建表，不建账号。
  服务尚未启动，现在还不能用浏览器访问。
```

此时**还不能访问**网页，因为服务还没启动。`0 个用户`也是正常的。

---

## 第 3 步：启动服务并创建管理员

**在哪执行：【`~/energy-app`】**

```bash
cd ~/energy-app
bash docker-02-start.sh \
  --admin-email admin@example.com \
  --admin-pass 'ChangeMe123!'
```

把邮箱和密码换成你要用的（密码至少 8 位）。

**你会看到**：

```
  ✓ 服务已就绪（105s）：{"status":"ACCOUNT_REQUIRED"}
  ✓ 管理员已创建
  ✓ 系统管理员可登录，权限 SYS_ADMIN

============================================================
 第 3 步完成：服务已启动，管理员已就绪
============================================================
  访问地址
    http://localhost:8090/
  系统管理员
    admin@example.com
  现在可以用浏览器登录了。
```

**打开浏览器**：`http://localhost:8090/`
用刚才的邮箱密码登录，应该能进首页。

> 如果第 1 步提示端口不是 8090，就用那个数字。

---

## 第 4 步：开一个租户和一个客户

这一步可以不马上做，但不做的话登录进去是空的（没有租户、没有演示数据）。

**在哪执行：【`~/energy-app`】**

```bash
cd ~/energy-app
bash scripts/02-onboard.sh \
  --base http://127.0.0.1:8090 \
  --admin admin@example.com --admin-pass 'ChangeMe123!' \
  --tenant "环宇能源集团" \
  --tenant-email tenant@example.com --tenant-pass 'Tenant@12345' \
  --customer "星河工业园" \
  --customer-email customer@example.com --customer-pass 'Customer@123'
```

**你会看到**：

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

这一步会自动建好：4 个能源品种、4 个维度根、6 个仪表板、3 台演示表计和一周演示数据。

---

## 第 5 步：验收

**在哪执行：【`~/energy-app`】**

```bash
cd ~/energy-app
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

看到这一行才算部署完成。有 FAIL 会打印具体项，按提示查[故障排查](/admin/troubleshoot)。

---

## 完成后的状态

> 客户登录后看到的菜单是**能源管理主题**（能耗查询 / 能耗优化 / 设备运维 / 组织 / 报表与账单），
> 租户的能源配置收在 `Platform → 能源配置` 里。这两套菜单都在初始化时自动装好，
> 不用手工配。菜单不对时见[左侧菜单](/admin/menus)。

| 地址 | 内容 |
| --- | --- |
| `http://localhost:8090/` | 主平台（Java 前端 + API） |
| `http://localhost:8090/ngxai/` | 分析平台（ngx-ai 前端） |
| `http://localhost:8090/ngxapi/health` | 分析服务健康检查 |

账号：

| 角色 | 邮箱 | 密码 |
| --- | --- | --- |
| 系统管理员 | `admin@example.com` | 你在第 3 步设的 |
| 租户管理员 | `tenant@example.com` | `Tenant@12345` |
| 客户用户 | `customer@example.com` | `Customer@123` |

---

## 更新到新版本（含重新初始化演示数据）

改了后端代码、部件或仪表板模板后，**重启容器不会生效**，因为容器里跑的是旧 jar、
旧模板。必须把文件换掉，再让初始化逻辑重新跑一遍。

> **想省事就直接用一条命令**：如果你会反复重装（改代码 → 验证 → 再改），
> 用[全链路验收](/admin/verify-e2e)里那个 `docker-98-rebuild.sh`，
> 它把「卸载 → 装回 → 建库 → 开租户 → 三步验收」串成一条命令，约 6 分钟。
> 下面这一节是拆开讲每一步在做什么，出问题时对照看。

### 先搞清楚三件事

**第一件：初始化只跑一次。**
租户级的能源字典、厂商型号、仪表板只在**创建租户那一刻**写入数据库；
客户级的场站、设备、演示遥测只在**创建客户那一刻**写入。
租户已经在库里，你再重启一万次，也不会重跑这些逻辑。

**第二件：容器不会自己变新。**
`docker compose up -d` 用的是部署目录里那个 jar 构建出来的镜像。
只要 `~/energy-app/guard-server-4.4.0.jar` 还是旧的，重建镜像还是旧的。

**第三件：`docker-01-install.sh` 只吃当前目录的文件。**
它不会去仓库里找新 jar。新文件必须由 `docker-00-prepare.sh` 放进来。

### 先确认你的部署目录是不是旧的

**在哪执行：【部署机 · 部署目录】**

```bash
cd ~/energy-app

# 部署目录里的 jar 时间
ls -la guard-server-4.4.0.jar

# 部署目录里的仪表板模板数量
ls data/json/tenant/dashboards/ | wc -l
```

**在哪执行：【构建机 · 仓库根目录】**

```bash
cd /你的仓库路径/iot-rule-engine

# 新构建出来的 jar 时间
ls -la guard-server/target/guard-server-4.4.0.jar

# 仓库里的仪表板模板数量
ls guard-server/src/main/data/json/tenant/dashboards/ | wc -l
```

两边数字一样（模板数量相同、jar 时间相同），才是新版。
部署目录的模板数少于仓库，说明你跑的是旧版，下面照做。

### 选哪条路

| 你的情况 | 走哪条路 | 耗时 |
| --- | --- | --- |
| 刚部署，库里只有演示数据 | **路 A：彻底重装** | 15–25 分钟 |
| 库里已有真实数据，不能丢 | **路 B：备份 → 换文件 → 重建租户** | 20 分钟 + 备份时间 |
| 只改了 `.env`、`nginx.conf` | 重启容器即可 | 1 分钟 |

> 两条路都会**删掉管理员账号以外的业务数据**，因为初始化只在建租户时触发。
> 路 B 有备份可回滚，路 A 没有。

---

### 路 A：彻底重装（推荐给刚部署的情况）

**特点**：干净、一次到位、不留旧文件。会丢掉管理员账号，要重新创建。

**① 卸载（保留镜像，省 5–20 分钟重建）**

**在哪执行：【部署机 · 部署目录】**

```bash
cd ~/energy-app
bash docker-99-uninstall.sh --purge --yes --images=none
```

跑完当前目录会被删掉，提示符会失效，属正常。先回上级目录：

```bash
cd ~
```

**② 重新准备部署目录（关键：这一步才会带进新 jar 和新模板）**

**在哪执行：【构建机 · 仓库根目录】**（就是有源码和 jar 的那台）

```bash
cd /你的仓库路径/iot-rule-engine
bash shiyongshouce/downloads/deploy/docker-00-prepare.sh
```

**预计输出**：

```
[21:40:02] 检查源文件
  ✓ jar：425M
  ✓ json：12M
  ✓ sql：8 个文件
[21:40:05] 组装部署目录：/Users/你/energy-app
  ✓ 已生成 .env（APP_HOME=/Users/你/energy-app）
```

**验证这一条**（模板数必须是 22，不是 6）：

```bash
ls ~/energy-app/data/json/tenant/dashboards/ | wc -l
```

**③ 建库**

**在哪执行：【部署机 · 部署目录】**

```bash
cd ~/energy-app
bash docker-01-install.sh
```

**预计输出**：

```
[21:41:10] 初始化数据库
  ✓ 112 张表
[21:41:35] 导入部件
  ✓ 726 个部件 / 34 个 bundle
```

**④ 启动并创建管理员**

```bash
bash docker-02-start.sh \
  --admin-email admin@your.com \
  --admin-pass 'YourPassword123'
```

**⑤ 建租户和客户**（这一步才会写入演示数据）

```bash
bash scripts/02-onboard.sh \
  --base http://127.0.0.1:8090 \
  --admin admin@your.com --admin-pass 'YourPassword123' \
  --tenant "你的租户名" \
  --tenant-email tenant@your.com --tenant-pass 'Tenant@123' \
  --customer "你的客户名" \
  --customer-email customer@your.com --customer-pass 'Customer@123'
```

**⑥ 验收**

```bash
bash scripts/03-verify.sh \
  --base http://127.0.0.1:8090 \
  --tenant tenant@your.com --tenant-pass 'Tenant@123' \
  --customer customer@your.com --customer-pass 'Customer@123' \
  --ai http://127.0.0.1:8090
```

期望最后一行：`通过 22 / 失败 0`

---

### 路 B：保留数据库，换文件后重建租户

**特点**：管理员账号和平台级配置保留；租户下的数据会删掉，所以**必须先备份**。

**① 备份数据库**

**在哪执行：【部署机 · 部署目录】**

```bash
cd ~/energy-app

docker compose exec -T postgres pg_dump -U postgres thingsboard \
  | gzip > ~/backup-$(date +%F-%H%M).sql.gz

ls -lh ~/backup-*.sql.gz
```

文件大小应是几 MB 到几十 MB。如果是 0 字节，说明备份失败，别往下走。

**② 重新生成部署目录（会被旧 `.env` 挡住，这是保护机制）**

**在哪执行：【构建机 · 仓库根目录】**

```bash
cd /你的仓库路径/iot-rule-engine
bash shiyongshouce/downloads/deploy/docker-00-prepare.sh
```

会看到：

```
 第 1 步已经做过了
  部署目录已存在，里面已有配置：/Users/你/energy-app/.env
```

**这是对的**，不要加 `--force` —— 那会换掉数据库密码，旧库立刻连不上。

改成手动换文件，见下一步。

**③ 只换 jar 和模板，保留 `.env`**

**在哪执行：【部署机 · 部署目录】**

```bash
cd ~/energy-app

# 停服务
docker compose --profile split stop energy-server gateway 2>/dev/null || docker compose stop energy-server gateway

# 换 jar（路径换成你仓库里的实际位置）
cp /你的仓库路径/iot-rule-engine/guard-server/target/guard-server-4.4.0.jar .

# 换租户级模板（仪表板）
rm -rf data/json/tenant/dashboards
cp -R /你的仓库路径/iot-rule-engine/guard-server/src/main/data/json/tenant/dashboards \
      data/json/tenant/

# 换系统级部件
rm -rf data/json/system/widget_types
cp -R /你的仓库路径/iot-rule-engine/guard-server/src/main/data/json/system/widget_types \
      data/json/system/

# 确认
ls -la guard-server-4.4.0.jar
ls data/json/tenant/dashboards/ | wc -l
```

模板数应为 22。

**④ 重建镜像并启动**

```bash
bash docker-01-install.sh
bash docker-02-start.sh
```

`docker-01-install.sh` 会发现库已有表，提示跳过建库，这是正常的 —— 它仍会重建镜像。

**⑤ 删掉旧租户，让它按新逻辑重建**

租户级初始化只在建租户时触发。旧租户留着，就永远不会重跑。

在平台里操作：系统管理员登录 → 租户 → 删除 → 重新创建。

或用 API（更快）：

```bash
# 登录取 token
TOKEN=$(curl -s --noproxy '*' -X POST http://127.0.0.1:8090/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin@your.com","password":"YourPassword123"}' \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])")

# 列出租户，记下 ID
curl -s --noproxy '*' -H "X-Authorization: Bearer $TOKEN" \
  'http://127.0.0.1:8090/api/tenants?pageSize=100&page=0' \
  | python3 -c "import json,sys; [print(t['id']['id'], t['title']) for t in json.load(sys.stdin)['data']]"

# 删除（把 <租户ID> 换成上一行输出的 ID）
curl -s --noproxy '*' -X DELETE -H "X-Authorization: Bearer $TOKEN" \
  'http://127.0.0.1:8090/api/tenant/<租户ID>'
```

删租户会连带删掉它下面的客户、设备、仪表板。**第 ① 步的备份就是为这一步准备的。**

**⑥ 重建租户和客户**

```bash
bash scripts/02-onboard.sh \
  --base http://127.0.0.1:8090 \
  --admin admin@your.com --admin-pass 'YourPassword123' \
  --tenant "你的租户名" \
  --tenant-email tenant@your.com --tenant-pass 'Tenant@123' \
  --customer "你的客户名" \
  --customer-email customer@your.com --customer-pass 'Customer@123'
```

**⑦ 验收**

```bash
bash scripts/03-verify.sh \
  --base http://127.0.0.1:8090 \
  --tenant tenant@your.com --tenant-pass 'Tenant@123' \
  --customer customer@your.com --customer-pass 'Customer@123' \
  --ai http://127.0.0.1:8090
```

---

### 只想补演示数据，不删租户

租户已经建好、只想给某个客户补一套演示场站：

```bash
# 删客户（连带它的设备与演示数据）
curl -s --noproxy '*' -X DELETE -H "X-Authorization: Bearer $TOKEN" \
  'http://127.0.0.1:8090/api/customer/<客户ID>'

# 重新建客户，会自动带新的演示数据
curl -s --noproxy '*' -X POST -H "X-Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"title":"你的客户名"}' \
  'http://127.0.0.1:8090/api/customer'
```

> 这一招只补**客户级**数据（维度根、场站、设备、遥测）。
> 租户级的能源字典、厂商型号、仪表板**不会**重建 —— 那些必须删租户。

---

### 新版本应该建成什么样

重建完成后，用这些数字核对。**数字不对就是没生效**，别急着往下用。

| 项目 | 期望值 | 怎么查 |
| --- | --- | --- |
| 仪表板模板 | 22 个 | `ls data/json/tenant/dashboards/ \| wc -l` |
| 租户仪表板 | 22 个 | 租户管理员登录 → 仪表板列表 |
| 设备档案 | 7 个 | 租户管理员 → 设备档案 |
| 厂商 | 17 个 | 租户管理员 → 资产 → 厂商 |
| 设备型号 | 9 个 | 租户管理员 → 资产 → 设备型号 |
| 能源品种 | 5 个 | 租户管理员 → 资产 → 能源品种（电/水/燃气/蒸汽/热力） |
| 能源参数 | 46 个 | 租户管理员 → 资产 → 能源品种 → 展开 |
| 客户场站 | 2 个 | 客户登录 → 场站（单相园 / 三相园） |
| 客户设备 | 5 台 | 客户登录 → 设备 |
| 演示遥测 | 14 天 | 任一设备 → 最新遥测 |

## 上线前必改的三项

| 项 | 位置 | 为什么 |
| --- | --- | --- |
| JWT 签名密钥 | `thingsboard.yml` → `security.jwt.tokenSigningKey` | 默认值公开，不换等于任何人可伪造 token |
| 站点地址 | 系统管理员 → 常规设置 → `baseUrl` | 影响激活邮件链接与前端跳转，填错用户点不开 |
| 邮件服务器 | `spring.mail.*` | 不发激活邮件可后置，但客户自助注册要用 |

> 默认账号 `tenant/tenant`、`customer/customer` 只用于演示，**对外开服前必须改密码**。
> 数据库端口不对宿主暴露（compose 里已做到），客户隔离已由验收脚本的两处 403 覆盖。

## 日常命令

**在哪执行：【`~/energy-app`】**

```bash
cd ~/energy-app

docker compose ps                          # 看状态
docker compose logs -f --tail=100 gateway  # 跟踪网关日志
docker compose restart energy-server       # 重启主服务
docker compose stop                        # 全部停止（数据保留）
docker compose up -d                       # 再启动

# 备份数据库
docker compose exec -T postgres pg_dump -U postgres thingsboard \
  | gzip > ~/thingsboard-$(date +%F).sql.gz
```

---

## 其他情况

- **要部署到另一台服务器** → [部署到服务器](/admin/deploy-remote)
- **想用单容器（全部进程一个容器）** → [单容器 or 分容器](/admin/deploy-modes)
- **不能装 Docker** → [裸机部署](/admin/baremetal)
- **要删掉重来** → [卸载与重置](/admin/uninstall)

## 常见失败

**`找不到 jar`**
还没构建：`cd guard-server && mvn package -DskipTests`，然后重跑第 1 步。

**`port is already allocated`**
编辑 `~/energy-app/.env` 改 `HTTP_PORT`，然后重跑当前步骤。

**`UnsupportedClassVersionError 69.0`**
jar 是 Java 25 编译的，镜像必须是 `eclipse-temurin:25-jre`，别改成 21。

**第 2 步说「库已有 N 张表，拒绝重复初始化」**
这是保护。要重来先跑 `bash docker-99-uninstall.sh --purge --yes`。

**第 3 步说「240 秒内服务未就绪」**

```bash
docker compose logs --tail=60 energy-server gateway
docker inspect energy-server --format '{{.State.OOMKilled}}'
```

多数是内存不足或数据库密码与 `.env` 不一致。

**`Mounts denied`（macOS）**
只在部署目录不在 `/Users` 下时出现。用默认的 `~/energy-app` 不会遇到。
