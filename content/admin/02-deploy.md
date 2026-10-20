# 部署（照着做）

> 本页是从零到能用的**唯一主线**。全程 5 条命令，按顺序复制执行即可。
> 部署到另一台服务器、或用单容器模式，在最后一节说明。

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
