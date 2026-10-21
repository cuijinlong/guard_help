# ② 平台部署

> 从「Docker 装好了」到「能登录、有数据、菜单完整」，4 条命令。
> **按顺序执行，每步都有验证方法。**
>
> Docker 还没装？先看[① Docker](/admin/docker)。

---

## 开始前

```bash
docker version --format '{{.Server.Version}}'
docker compose version
docker run --rm hello-world | head -3
```

三条都过才继续。然后记住三个变量，后面直接用：

| 项目 | 本文使用的值 | 说明 |
| --- | --- | --- |
| 系统管理员 | `langmen@126.com` / `CJLqh@163` | 平台最高权限 |
| 租户管理员 | `tenant@126.com` / `12345678` | 能源服务商 |
| 客户用户 | `customer@126.com` / `12345678` | 工厂/园区 |

> 正式环境请换成自己的邮箱和强密码。密码改了要同步改脚本参数。

---

## 第 1 步：准备部署文件

**在哪执行：【仓库根目录】** —— 有 `guard-server/`、`shiyongshouce/` 的那一层。

```bash
cd /你的路径/iot-rule-engine
bash shiyongshouce/downloads/deploy/docker-00-prepare.sh
```

**预计输出**：

```
[10:12:03] 检查源文件
  ✓ jar：425M
  ✓ json：12M
  ✓ sql：8 个文件
[10:12:05] 组装部署目录：/Users/你/energy-app
  ✓ 已生成 .env（APP_HOME 已填好，端口检测后取 8090/5432/1883，密码随机生成）
```

**做了什么**：在 `~/energy-app` 备好全部文件，并生成 `.env`（数据库密码随机）。

**验证**：

```bash
ls ~/energy-app/guard-server-4.4.0.jar
ls ~/energy-app/data/json/tenant/dashboards/ | wc -l     # 必须是 20
```

> **`.env` 是隐藏文件**，`ls` 看不到。看内容：`cat ~/energy-app/.env`。
> **要装到别的目录**：`bash docker-00-prepare.sh /data/energy-app`。

---

## 第 2 步：建库并导入部件

**在哪执行：【部署目录】**

```bash
cd ~/energy-app
bash docker-01-install.sh
```

**预计输出**：

```
[10:13:12] 初始化数据库
  ✓ 112 张表
[10:13:40] 导入部件
  ✓ 726 个部件 / 34 个 bundle
```

**验证**：

```bash
docker compose --profile split exec -T postgres \
  psql -U postgres -d thingsboard -tAc \
  "select count(*) from information_schema.tables where table_schema='public'"
```

输出 `112` 或更多即可。

---

## 第 3 步：启动服务并创建管理员

**在哪执行：【部署目录】**

```bash
cd ~/energy-app
bash docker-02-start.sh \
  --admin-email langmen@126.com \
  --admin-pass 'CJLqh@163'
```

**预计输出**：

```
[10:16:30] 等待服务就绪（首次约 60–120 秒）
  ✓ 服务已就绪（90s）：{"status":"ACCOUNT_REQUIRED"}
[10:17:10] 创建系统管理员 langmen@126.com
  ✓ 管理员已创建
  ✓ 设备接入通道已开放（HTTP + MQTT）
  ✓ MQTT 端口 1883 正在监听
```

**首次启动 3–5 分钟**（要构建分析服务镜像），之后重启 20 秒。

**验证**：浏览器打开 `http://本机IP:8090`，用 `langmen@126.com / CJLqh@163` 登录。

---

## 第 4 步：建租户、客户，并初始化全部数据

**在哪执行：【部署目录】**

```bash
cd ~/energy-app
bash scripts/02-onboard.sh \
  --base http://127.0.0.1:8090 \
  --admin langmen@126.com --admin-pass 'CJLqh@163' \
  --tenant "环宇能源集团" \
  --tenant-email tenant@126.com --tenant-pass '12345678' \
  --customer "星河工业园" \
  --customer-email customer@126.com --customer-pass '12345678'
```

**预计输出**：

```
✓ 租户已创建
✓ 能源参数字典：4 品种 / 26 项电能指标
✓ 资产档案 14 个 / 设备档案 7 个
✓ 告警与派生指标 11 条（挂在电表档案上）
✓ 厂商 17 个 / 设备型号 9 个
✓ 分时方案 4 套
✓ 客户已创建
✓ 演示数据：单相园区（7 台表 + 温湿度）、三相园区（4 台表 + 温湿度）
✓ 仪表板已复制给客户：20 个
✓ 客户菜单已安装（13 项）
✓ 租户菜单已安装（11 项）
✓ 全部验证通过
```

**这一步就把所有初始化做完了** —— 用户、字典、字段、菜单、演示数据、看板，一次到位。
明细见[③ 数据初始化](/admin/init)。

---

## 部署到另一台服务器

**在哪执行：【构建机 · 仓库根目录】**

```bash
bash shiyongshouce/downloads/deploy/docker-00-prepare.sh --pack
```

产物：`dist/energy-deploy-<日期>.tar.gz`（约 420MB）。

**传到服务器**：

```bash
scp dist/energy-deploy-*.tar.gz root@服务器IP:/opt/
ssh root@服务器IP
cd /opt && tar -xzf energy-deploy-*.tar.gz
```

**然后照第 2 步往后做**（目录叫 `/opt/energy-deploy`，不叫 `~/energy-app`）：

```bash
cd /opt/energy-deploy
bash docker-01-install.sh
bash docker-02-start.sh --admin-email langmen@126.com --admin-pass 'CJLqh@163'
bash scripts/02-onboard.sh ...（参数同上，--base 换成服务器地址）
```

**服务器要额外做两件事**：

```bash
# 1. 放行端口
sudo ufw allow 8090/tcp      # Web
sudo ufw allow 1883/tcp      # RTU 上报
# CentOS 用 firewall-cmd --add-port=8090/tcp --permanent && firewall-cmd --reload

# 2. 确认内存够（4GB 起）
free -g
```

---

## 单容器模式（内存紧张时）

默认是**分容器**（postgres / server / gateway / ai 四个），适合正式环境。
2GB 内存的机器可以用单容器：

```bash
cd ~/energy-app
sed -i 's/^DEPLOY_MODE=.*/DEPLOY_MODE=allinone/' .env
```

然后照第 2 步往后做。

| | 分容器 | 单容器 |
| --- | --- | --- |
| 内存 | ≥ 4GB | ≥ 2GB |
| 排障 | 每个服务独立日志 | 混在一起 |
| 建议 | **正式环境用这个** | 演示机 / 边缘设备 |

---

## 改代码后怎么更新

**不要手工 cp jar**，用一条命令跑完整个循环：

```bash
cd /你的路径/iot-rule-engine
bash shiyongshouce/downloads/deploy/docker-98-rebuild.sh \
  --admin langmen@126.com --admin-pass 'CJLqh@163' \
  --tenant tenant@126.com --tenant-pass '12345678' --tenant-title '环宇能源集团' \
  --customer customer@126.com --customer-pass '12345678' --customer-title '星河工业园' \
  --yes
```

> ⚠️ **注意参数名和 `02-onboard.sh` 不一样**：
> 这里 `--tenant` 是**邮箱**，名称要用 `--tenant-title`；
> 而 `02-onboard.sh` 的 `--tenant` 是**名称**，邮箱用 `--tenant-email`。
> 传错会报「未知参数」。

它做 9 件事：卸载 → 重新组装 → 建库 → 启动 → 开租户 → 四步验收。约 7 分钟。

四步验收是**依次跑四个脚本**，任何一步有失败项都会在结尾汇总：

| 步 | 脚本 | 验什么 |
| --- | --- | --- |
| 6 | `scripts/03-verify.sh` | 接口与权限（结构） |
| 7 | `scripts/04-verify-data.sh` | 量值准确性与自洽 |
| 8 | `scripts/06-verify-e2e.sh` | 组织→设备→上报→存储→报表 全链路 |
| 9 | `scripts/08-verify-release.sh` | **这一版的功能点是否都在**（菜单/看板/字典/计算字段/前端产物） |

第 9 步是关键：它把本版每处改动变成断言，重装后不用再逐条人工确认。
细节见 [初始化与验收](03-init.html) 的「第 0 条」。

**常用开关**：

| 开关 | 作用 |
| --- | --- |
| `--no-verify` | 跳过四步验收（快 2 分钟） |
| `--keep-data` | 不删数据库，只换 jar 并重建租户 |
| `--rebuild-web` | 强制重建前端产物（默认源码没变就复用） |

**只改了 `.env`（端口、密码）**：

```bash
cd ~/energy-app
docker compose --profile split up -d
```

---

## 卸载平台（一步一步）

> 只删本平台，**Docker 本身保留**给别的项目用。
> 要把 Docker 也卸掉，见[① Docker](/admin/docker)第四节。

### 先确认在哪个目录

```bash
ls ~/energy-app/docker-compose.yml 2>/dev/null && echo "本机：~/energy-app"
ls /opt/energy-deploy/docker-compose.yml 2>/dev/null && echo "服务器：/opt/energy-deploy"
```

卸载脚本**必须在部署目录里执行**（要读同目录的 `.env`）。

### 选项 A：只停服务，保留数据

```bash
cd ~/energy-app
bash docker-99-uninstall.sh
```

**输出**：

```
  ✓ 已停止。数据仍在卷 energy-pgdata 与 ~/energy-app/data
   重新启动：bash docker-02-start.sh
   彻底删除：bash docker-99-uninstall.sh --purge
```

保留：数据库卷、目录、jar、data、日志。再启动：

```bash
bash docker-02-start.sh
```

### 选项 B：彻底删除，不留痕（含数据卷）

**先看会删什么**（推荐每次都先跑这个）：

```bash
cd ~/energy-app
bash docker-99-uninstall.sh --purge --dry-run
```

输出会逐项列出：数据卷、容器、网络、部署目录、镜像策略。**不删任何东西**，
还有一行专门提示机器上其它 ThingsBoard 实例（本脚本不会动它们）。

确认无误再执行：

```bash
cd ~/energy-app
bash docker-99-uninstall.sh --purge
```

要输入大写 `YES` 确认。会删：容器、**数据卷（全部数据）**、网络、部署目录。

无人值守版（脚本里用）：

```bash
cd ~/energy-app
bash docker-99-uninstall.sh --purge --yes --images=none
```

### 三个参数分别管什么

| 参数 | 作用 | 什么时候用 |
| --- | --- | --- |
| `--purge` | 删容器 + **数据卷** + 网络 + 部署目录 | 要从零重来时必须加；不加就只是停服务 |
| `--yes` | 跳过大写 YES 确认 | 脚本调用、自动化 |
| `--dry-run` | 只列清单不执行 | **每次删之前先跑一遍** |
| `--images=none` | 保留镜像（默认） | 马上要重装 —— 省 5–20 分钟构建 |
| `--images=app` | 只删自建镜像 | 不再用这个平台 |
| `--images=all` | 连 postgres/nginx/temurin 一起删 | 彻底清理，但会影响机器上别的项目 |

**`--purge` 删的是哪几个卷**（脚本里写死的，不会误删别人的）：

```
energy-pgdata          PostgreSQL 数据（设备、遥测、用户、菜单，全在这）
energy-ngxai-data      AI 服务的数据（模型、预测缓存）
energy-allinone-data   单容器模式的 SQLite 与日志
```

### 机器上还有别的 ThingsBoard 实例怎么办

本脚本只处理 `energy-*`。如果你以前装过单独的 ThingsBoard（容器名如 `tb-postgres`），
它**不会被删**，脚本会在末尾列出来。

先看清它的挂载与占用：

```bash
docker inspect tb-postgres --format '{{json .Mounts}}'
docker system df -v | grep -A2 tb-postgres
```

确认无用后单独删（**这一步不可恢复，先确认不是你要留的数据**）：

```bash
docker rm -f tb-postgres
docker volume rm tb-postgres-data
```

> 这类旧实例常见于早期调研阶段，占 1–2 GB。留着不影响新平台运行，
> 但会一直占磁盘，而且 `docker volume ls` 里容易看混。

### 只想重装、不想手工分两步

`docker-98-rebuild.sh` **自己会先 purge 再装**，不需要先跑卸载脚本：

```bash
cd /你的路径/iot-rule-engine
bash shiyongshouce/downloads/deploy/docker-98-rebuild.sh \
  --admin langmen@126.com --admin-pass 'CJLqh@163' \
  --tenant tenant@126.com   --tenant-pass '12345678' --tenant-title '环宇能源集团' \
  --customer customer@126.com --customer-pass '12345678' --customer-title '星河工业园' \
  --yes
```

它内部调用 `docker-99-uninstall.sh --purge --yes`，**数据卷一样会删**。
所以「重装」和「彻底删了再装」是同一件事，不需要额外操作。

无人值守：

```bash
cd ~/energy-app
bash docker-99-uninstall.sh --purge --yes
```

**输出**：

```
  ✓ 容器：无残留
  ✓ 卷：无残留
  ✓ 网络：无残留
  ✓ 端口 8090：无残留
  ✓ 目录：已删除
  ✓ 卸载完成，无残留
```

> 脚本会把自己所在的目录删掉，所以最后一行的 `cd` 会失效 —— 正常，`cd ~` 即可。

### 镜像删不删

默认**一个都不删**，重新部署时省 5–20 分钟构建。

```bash
# 保留全部镜像（最快重装）
bash docker-99-uninstall.sh --purge --yes --images=none

# 只删自建镜像（energy/ngxai-backend、energy/allinone）
bash docker-99-uninstall.sh --purge --yes --images=app

# 连公共基础镜像一起删（影响机器上其他项目）
bash docker-99-uninstall.sh --purge --yes --images=all
```

**怎么选**：马上重装 → `none`；不再用但机器上有别的项目 → `app`；完全清理 → `all`。

### 自己再验一遍

```bash
docker ps -a --format '{{.Names}}' | grep energy      # 应无输出
docker volume ls --format '{{.Name}}' | grep energy   # 应无输出
docker network ls --format '{{.Name}}' | grep energy  # 应无输出
ls -d ~/energy-app                                    # 应提示不存在
curl -s --noproxy '*' -m 3 http://127.0.0.1:8090/ >/dev/null && echo '仍在监听' || echo '已释放'
```

五条都空 / 提示不存在，才算干净。

### 卸载后磁盘没释放多少？

构建缓存不会被 `down -v` 碰到：

```bash
docker system df
docker builder prune -f
docker image prune -f
```

### 只想清空数据、不卸目录

```bash
cd ~/energy-app
docker compose down -v          # 删容器和数据卷，保留目录与 jar
rm -f .env                      # 让下一步重新生成密码与端口

bash docker-01-install.sh
bash docker-02-start.sh --admin-email langmen@126.com --admin-pass 'CJLqh@163'
bash scripts/02-onboard.sh ...（参数同上）
```

> ⚠️ **这条不会升级版本** —— 它保留目录里的 jar 和数据。
> 要换新版本，用上面的 `docker-98-rebuild.sh`。

---

## 部署完成后的状态

| 项目 | 期望值 | 怎么查 |
| --- | --- | --- |
| 数据库表 | 112+ | 第 2 步的验证命令 |
| 部件 | 726 个 | 租户登录 → 部件库 |
| 资产档案 | 14 个 | 租户 → 资产 → 档案 |
| 设备档案 | 7 个 | 租户 → 设备档案 |
| 告警 / 派生指标 | 11 条 | 租户 → 设备档案 → 单相电能表/电能表 → 计算字段 |
| 厂商 / 型号 | 17 / 9 | 租户 → 资产 |
| 能源参数 | 4 品种 / 26 项电能指标 | 运营配置 → **品种指标** |
| 分时方案 | 4 套 | 运营配置 → **峰谷时段** |
| 租户菜单 | 11 个顶层项 | 租户登录后看左侧 |
| 场站 | 2 个 | 客户登录 → 组织与场站 |
| 电表 | 11 台（一级 2 / 二级 4 / 三级 5） | 客户 → 设备管理 |
| 水气汽表 | 6 台 | 客户 → 设备管理 |
| 虚拟表 | 2 台 | 客户 → 手工填报 |
| 仪表板 | 40 个（租户 20 + 客户 20） | 客户 → 仪表板 |
| 客户菜单 | 13 个顶层项 | 客户登录后看左侧 |

---

## 装完第一件事：打开平台自检

登录后先别急着看报表，去这两个地方之一打开「平台自检」：

- 租户管理员：左侧 **Platform → 平台自检**
- 客户用户：左侧 **设备运维 → 平台自检**

这一页把初始化清单逐条数一遍，缺什么、怎么补、看手册哪一页都写在上面。
顶部横幅全绿 = 初始化完整；有红项就先按提示补齐，再往下做业务。

为什么必须先看：初始化缺项**不报错**。页面照常开、按钮照常点，
只是某些报表空白、某些统计为 0 —— 不看自检往往要等客户提问才发现。

详见[③ 数据初始化](/admin/init)的「一之三」。

---

## 装不上时

| 现象 | 原因 | 怎么办 |
| --- | --- | --- |
| `docker 守护进程未运行` | 没装/没启动/无权限 | [① Docker](/admin/docker) 第一节 |
| `端口 8090 已被占用` | 别的程序占了 | 改 `.env` 的 `HTTP_PORT` |
| `端口 1883 已被占用` | mosquitto 之类 | 改 `.env` 的 `MQTT_PORT`，RTU 地址跟着改 |
| 启动后 502 | 后端还在启动 | 等 2 分钟；`docker compose logs energy-server` |
| 内存不足 / 进程被杀 | 机器 < 4GB | 用单容器模式 |
| 忘了管理员密码 | — | 见[常见问题](/admin/troubleshoot)的密码重置 |
| 客户登录后菜单是 TB 原生的 | 菜单未装 | `bash scripts/07-init-menu.sh ...` |

更多见[常见问题](/admin/troubleshoot)。
