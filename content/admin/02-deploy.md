# ② 包干到底部署

从**空机器**到**客户登录就能看到数据**，五步。每步都有验收判据，对不上就是没装对。

> 这一页只讲部署。开户/销户见 [③](/admin/onboard)，
> 设备接入见 [⑦](/admin/device-access)，装不上见 [⑨](/admin/troubleshoot)。

---

## 总览

> **除第 ① 步外，所有命令都在 `~/energy-app` 下执行。**
> 第 ② 步已经 `cd ~/energy-app`，之后就别再切走了 —— 手册里的
> `bash scripts/xxx.sh` 都是相对这个目录的。

```bash
# ① 组装部署目录（在仓库根目录）
bash shiyongshouce/downloads/deploy/docker-00-prepare.sh

# ② 建库 + 装系统资源（约 2-3 分钟）
cd ~/energy-app && bash docker-01-install.sh

# ③ 启动 + 建系统管理员（约 2 分钟）
bash docker-02-start.sh --admin-email you@example.com --admin-pass '你的密码'

# ④ 建租户 + 租户管理员（一次就够）
bash scripts/02-onboard.sh --admin you@example.com --admin-pass '你的密码' \
  --tenant '某某集团' --tenant-email tenant@example.com --tenant-pass '租户密码'

# ⑤ 一键到「有数据、有账号、能演示」（约 6 分钟）
bash scripts/29-rtu-demo-up.sh
```

**做完这五步，演示环境就齐了**：两个场站、两个网关、8 台模拟设备、
30 天历史数据、资产汇总、客户账号。

> **有真实 RTU 的现场**不必跑模拟：第 ⑤ 步加 `--no-sim`，
> 看板就只反映真实表。想知道谁在报：
> `bash scripts/29-rtu-demo-up.sh --status`。
> 两者也可以并存（默认），场站总量是真实 + 模拟之和。

---

## ① 准备部署目录

**在哪执行：【仓库根目录】** —— 有 `guard-server/`、`shiyongshouce/` 的那一层。

```bash
cd /你的路径/iot-rule-engine
bash shiyongshouce/downloads/deploy/docker-00-prepare.sh
```

**它做什么**：在 `~/energy-app` 备好全部文件，并生成 `.env`（数据库密码随机）。

**验收**：

```bash
ls ~/energy-app/guard-server-4.4.0.jar
ls ~/energy-app/data/json/tenant/dashboards/ | wc -l     # 必须是 24
ls ~/energy-app/data/sql/*.sql | wc -l                   # 必须是 8
```

> `.env` 是隐藏文件，`ls` 看不到。看内容：`cat ~/energy-app/.env`。
> **要装到别的目录**：`bash docker-00-prepare.sh /data/energy-app`。

### sql 与 Cassandra 脚本的来源（2026-11-02 已自包含）

| 物料 | 位置 | 消费方式 |
| --- | --- | --- |
| 建表 SQL（8 个） | `guard-server/src/main/data/sql/` | install 读 `install.data_dir/sql/` |
| Cassandra CQL（3 个） | `guard-server/src/main/data/cassandra/` | 切 Cassandra 时才用 |

两份都已从 `dao/` 模块**实体化**进 guard-server，不再依赖符号链接
（dao 模块清理后不会断链）。确认依赖已切断：

```bash
grep -n "dao/src" shiyongshouce/downloads/deploy/docker-00-prepare.sh   # 应该无输出
```

---

## ② 建库 + 装系统资源

**在哪执行：【部署目录】**

```bash
cd ~/energy-app
bash docker-01-install.sh
```

**它做什么**：建 122 张表、装 743 个系统部件、35 个 bundle。

**验收**：

```bash
docker exec energy-postgres psql -U postgres -d thingsboard -tAc "
SELECT (SELECT count(*) FROM information_schema.tables WHERE table_schema='public'),
       (SELECT count(*) FROM widget_type);"
# 期望：122|743
```

> **这一步不是幂等的**：库非空会拒绝执行并提示先 `DROP DATABASE`。
> 要重装就先卸载（见文末）。

---

## ③ 启动服务 + 建管理员

```bash
cd ~/energy-app
bash docker-02-start.sh --admin-email you@example.com --admin-pass '你的密码'
```

**它做什么**：起四个容器，等健康，然后调 `/api/noauth/setup/complete` 建系统管理员。

**验收**：

```bash
docker ps --format '{{.Names}}\t{{.Status}}' | grep energy
# 四个容器都要 healthy

curl -s --noproxy '*' http://127.0.0.1:8090/api/noauth/setup/state
# 期望：{"status":"OK"}（不是 ACCOUNT_REQUIRED）
```

**服务地址**：

| 端口 | 是什么 | 用途 |
| --- | --- | --- |
| `HTTP_PORT`（默认 **8090**） | **gateway / nginx** | 浏览器入口，日常就用这个 |
| `SERVER_DIRECT_PORT`（默认 **8091**） | **energy-server 直连** | 只用于排查，会绕过 nginx |
| `MQTT_PORT`（默认 **1883**） | 设备侧 MQTT | RTU / 网关上报 |
| `MQTT_RTU_PORT`（默认 **11883**） | MQTT 别名端口 | 现场固件把 11883 写死，平台额外监听 |

```
浏览器 ──▶ :8090 gateway(nginx) ──┬──▶ energy-server :8090 (Java)
                                  ├──▶ ngxai-backend :18801
                                  └──▶ /ngxai/ 静态文件
          :8091 energy-server ─────────┘（直连，仅供排查）
设备   ──▶ :1883 / :11883 MQTT
```

**为什么 8090 不是 Java**：容器里 Java 监听 8090，但它**不映射到宿主机**
（compose 里只有 `expose`）。宿主机的 8090 是 nginx，由它反代到 Java。
这样 `/ngxai` 反代、gzip、SPA 回退才能生效。

**页面打不开时先分清是谁的问题**：

```bash
# 两个口都探一次
curl -s --noproxy '*' -o /dev/null -w 'gateway  :%{http_code}\n' http://127.0.0.1:8090/api/noauth/energy/health
curl -s --noproxy '*' -o /dev/null -w 'java直连 :%{http_code}\n' http://127.0.0.1:8091/api/noauth/energy/health
```

| 结果 | 结论 | 怎么办 |
| --- | --- | --- |
| 8090 通、8091 通 | 服务正常，问题在浏览器/网络 | 查防火墙、代理、浏览器缓存 |
| 8090 不通、8091 通 | **gateway 挂了** | `docker compose logs gateway` |
| 两个都不通 | **Java 挂了** | `docker compose logs --tail=80 energy-server` |
| 两个都不通且容器没起 | 端口被占 | 看 `docker compose ps` 与 `.env` 的端口 |

> 端口被别的程序占用时，`docker-00-prepare.sh` 会自动顺延并写进 `.env`。
> **实际端口以 `.env` 为准**，不要假设一定是 8090。

### 从别的机器访问需要放行防火墙

容器端口映射只管**宿主机本机**。客户用自己的电脑访问、或云服务器，还要放行：

```bash
# Ubuntu / Debian
sudo ufw allow 8090/tcp
sudo ufw allow 1883/tcp        # 设备上报
sudo ufw allow 11883/tcp       # 现场固件写死的端口

# CentOS / RHEL
sudo firewall-cmd --add-port=8090/tcp --permanent
sudo firewall-cmd --add-port=1883/tcp --permanent
sudo firewall-cmd --add-port=11883/tcp --permanent
sudo firewall-cmd --reload
```

云服务器（阿里云/腾讯云/AWS）还要在控制台**安全组**放行同样的 TCP 端口。
这是“容器起来了但外面访问不了”最常见的原因。

---

## ④ 建租户 + 租户管理员

**为什么必须单独一步**：平台没有「默认租户」。系统管理员**不能直接建客户**
（TB 返回 403），必须先有租户管理员身份。

```bash
cd ~/energy-app
bash scripts/02-onboard.sh \
  --admin you@example.com --admin-pass '你的密码' \
  --tenant '某某集团' \
  --tenant-email tenant@example.com --tenant-pass '租户密码'
```

**它做什么**：建租户 → 建租户管理员 → 激活 → 切换身份 → 验证业务资源。

**验收输出**：

```
✓ 租户已创建
✓ 租户管理员已创建（待激活）
✓ 租户管理员已激活并取得会话
✓ 已切换为租户管理员身份
✓ 能源参数字典：1 个
✓ 系统部件：743 个
✓ 能耗管理部件：39 个
✓ 全部验证通过
```

> **建租户时会自动铺租户级主数据**（字典 / 档案 / 费率 / 分时 / 菜单），
> 不用另外跑初始化。这是平台的自带行为，明细见 [④ 数据模型](/admin/data-model)。
>
> 如果前面想给客户直接建账号，`02-onboard.sh` 也支持
> `--customer / --customer-email / --customer-pass`，但**日常开户用 09 脚本更省事**
> （见 [③ 开户与销户](/admin/onboard)）。

---

## ⑤ 一键到「有数据、能演示」

这一步是「包干到底」的核心：**一条命令把演示环境建完整**。

```bash
cd ~/energy-app
bash scripts/29-rtu-demo-up.sh
```

**它做什么**（幂等，反复跑无害）：

```
0. 探活
1. 租户管理员登录
2. 检查/补齐品种库（能源参数字典）
3. 客户 / 场站 / 档案 / 网关 / 8 台模拟设备 / 测点 / RPC / 归属关系
4. 发一轮实时数据 + 回填 30 天历史（每小时一个点）
5. 重算资产汇总（看板读的是资产上的 energy_total）
```

**预计输出**：

```
✓ 平台在线
✓ 登录成功
✓ 品种库已存在  · 标准 key 137 个
✓ 单相园区·平台演示中心 / 三相园区·平台演示中心
✓ 客户「平台演示中心」已建
✓ 后端初始化已完成（45 个资产）
✓ 设备档案 5 个
✓ 模拟设备 8 / 8
✓ 场站归属 +10 / 区域 +10 / 分项 +6
✓ 回填 5760 个数据点
[第 1 轮] 成功 8 / 失败 0
✓ 写入资产: 26 个，窗口 60 天
```

### 常用参数

| 参数 | 作用 |
| --- | --- |
| `--customer "客户名"` | 给指定客户初始化（默认「平台演示中心」） |
| `--backfill-days N` | 回填最近 N 天历史，默认 **30** |
| `--backfill-days 0` | 不回填（真实 RTU 现场，不造假历史） |
| `--sim-only` | 只跑持续上报，不碰数据（演示期间常驻） |
| `--check` | 只体检（dry-run），不改数据 |
| `--interval N` | 持续上报间隔秒数，默认 30 |

### 验收基线（实测数字）

| 检查项 | 应有值 |
| --- | --- |
| 库表 | 122 张 |
| 系统部件（install 后 DB 行数） | 743 个 |
| 交付的部件文件 | 584 个 |
| 能源参数字典 | 1 个资产，标准 key **137** 个（电能 122） |
| 演示客户 | 「平台演示中心」，10 台设备（8 台可模拟） |
| 归属关系 | 场站 10 条 `SiteContains`，区域/分项按拓扑挂好 |
| 客户看到的计量点 | 综合能耗页显示「当前 **8** 台计量点」 |

---

## 首次部署的两处等待（正常现象）

### ① 建客户会阻塞 60~120 秒

新建客户时，后端会在**同一个请求里同步**跑完整套演示数据初始化
（4 个维度根 / 2 个场站 / 12 个分项 / 21 台设备 / 一批遥测 + 费率）。

- `29` 已把这个请求的超时放宽到 600 秒
- 如果仍看到 `timed out`：**客户其实建好了**，等 1 分钟重跑 `29` 即可（幂等）

### ② 首次 `install` 约 2-3 分钟

建 122 张表 + 导入 743 个部件。机器慢的话会到 5 分钟，属正常。

---

## 装完第一件事：跑平台自检

```
左侧菜单 → 平台自检 → 一键体检
```

它检查字典、设备属性、资产汇总、菜单、看板、费率，**比翻日志快**，
而且会直接告诉你「缺什么、去哪补」。判据见 [⑧ 运维 SQL](/admin/ops-sql)。

---

## 部署到另一台服务器

三种方式，按场景选：

| 方式 | 适用 | 做法 |
| --- | --- | --- |
| 搬部署目录 | 同架构、已有数据要带走 | `docker-00-prepare.sh --pack` 打包，目标机解压后跑 02/03 |
| 只搬配置 | 全新环境，数据不要 | 拷 `.env` + `data/`，重新跑 01-install |
| 数据库迁移 | 数据量大 | `pg_dump` / `pg_restore`，见 [⑧ 运维 SQL](/admin/ops-sql#备份与恢复) |

**搬之前必须检查部署物料一致**（否则新机器装进去的是旧部件）：

```bash
bash scripts/32-check-deploy-sync.sh --app <目标部署目录>
bash scripts/32-check-deploy-sync.sh --app <目标部署目录> --fix   # 有差异时同步
```

---

## 内存紧张时：单容器模式

平台默认四个容器。**物理内存 < 10GB** 的机器，可以合并成单容器：

```bash
cd ~/energy-app
bash docker-02-start.sh --allinone --admin-email ... --admin-pass ...
```

单容器省一个容器、省 ~2GB 常驻。代价是「重启一个全部重启」。
**演示机、笔记本推荐单容器**；生产环境用默认四容器。

---

## 改代码后怎么更新

见 [⑩ 开发与构建](/admin/dev-build)。一句话：
**能改看板 JSON / 部件就别改 Java**，改 Java 要重新打包 + 重启（约 10 分钟）。

但不管改哪一类，**部署目录里的东西都不会自己更新**。改完先跑这个：

```bash
cd ~/energy-app
bash scripts/32-check-deploy-sync.sh        # 只报，不改
```

它比三类物料：`data/json/`（部件）、`data/sql/`（建库脚本）、`scripts/`（运维脚本）。
有差异加 `--fix` 自动同步（会先备份）。

> 从部署目录里跑它会被拒绝 —— 那样是拿自己比自己，永远报「一致」。
> 要在仓库里跑：`bash shiyongshouce/downloads/scripts/32-check-deploy-sync.sh --fix`

## 升级已有部署（不重建库）

现场已经在跑，只想把新脚本 / 新部件送上去。**两类东西走两条路**：

```bash
# ① 脚本 / sql / 部件 JSON 的**文件**送进部署目录
#    在仓库里跑（不能在部署目录里跑）
bash shiyongshouce/downloads/scripts/32-check-deploy-sync.sh --fix

# ② 部件 JSON 还要**写进数据库**（存量库的 widget_type 记录）
#    同样在仓库根目录跑，指定部件名或 --all
bash shiyongshouce/downloads/scripts/31-deploy-widget.sh --all

# ③ 改了后端代码才需要：重打 jar + 重启（约 10 分钟）
cd guard-server && mvn package -o -DskipTests -Dmaven.test.skip=true -q
cp target/guard-server-4.4.0.jar ~/energy-app/ && docker restart energy-server
```

**只改脚本的话，②③ 都不用做** —— 脚本是 shell/python，拷过去就能跑。

两张路的分工列一下，别搞混：

| 脚本 | 干什么 | 写数据库 | 改完部件该跑哪个 |
| --- | --- | --- | --- |
| `32-check-deploy-sync.sh --fix` | 三类文件比对 + 同步 | ✗ | 新建库前必跑 |
| `31-deploy-widget.sh <名>` | 推库 + 同步挂载目录 | ✓ | 存量库改部件 |
| `docker-00-prepare.sh` | 全量组装（会 `rm -rf` 目标目录） | ✗ | 全新机器才用 |

> 两个脚本都**必须从仓库跑**。从 `~/energy-app/scripts` 跑时，
> `32` 会直接拒绝（拿自己比自己永远报一致），`31` 会因找不到仓库路径而报错。
> 它们自己知道自己被拷进了部署目录 —— 这就是预防。

### 升级时 .env 的端口项（2026-11-03）

`SERVER_DIRECT_PORT`（直连排查口）是后加的。**老部署的 .env 里没有这一项**，
compose 会自动用默认值 `8091`。多数情况无需处理，但两种场景要看一眼：

```bash
# ① 宿主机 8091 已被别的服务占用 → compose up 会报
#    Bind for 0.0.0.0:8091 failed: port is already allocated
lsof -nP -iTCP:8091 -sTCP:LISTEN

# ② 确实被占了：在 .env 里显式改一个空闲端口
#    注意不能与 HTTP_PORT 相同（两个容器抢一个宿主端口）
echo 'SERVER_DIRECT_PORT=8093' >> ~/energy-app/.env
docker compose up -d gateway energy-server
```

> 新部署（跑过新版 `docker-00-prepare.sh` 的）不用管 —— 它会自动找一个
> 既空闲、又不与 `HTTP_PORT` 相同的值写进 `.env`。

### 为什么需要这一节（真实故障）

`docker-00-prepare.sh` 只在**组装时**拷一次脚本。之后仓库里新增的脚本
（比如 `29-rtu-demo-up.sh`）不会自己跑进已经部署的目录。

现场表现：手册写得对、仓库里文件也在、容器跑得好好的，只有命令报

```
bash: scripts/29-rtu-demo-up.sh: No such file or directory
```

判据：

```bash
ls ~/energy-app/scripts/ | grep 29-           # 空的 = 没同步
ls shiyongshouce/downloads/scripts/ | grep 29-   # 这里应该有
```

实际踩到的场景：`~/energy-app/scripts/` 还停在 10-29 那一批（26 个），
而仓库已经有 30 个。差的 4 个恰好是本次新写的演示/初始化脚本 ——
**手册里最新、最想用的命令，恰好是最容易缺的那几个**。

以后手册里出现的每个脚本，**都必须先跑过一次 `--fix`**。

---

## 卸载平台

```bash
cd ~/energy-app

# 只停服务，保留数据
bash docker-99-uninstall.sh

# 彻底删除（含数据卷，不可恢复）
bash docker-99-uninstall.sh --purge --yes
```

**三个参数分别管什么**：

| 参数 | 作用 |
| --- | --- |
| （无） | 停容器、删容器，保留下层数据卷 |
| `--purge` | 连数据卷一起删（库、日志全没） |
| `--yes` | 跳过交互确认（脚本化用） |

**只想重装、不想手工分两步**：

```bash
bash docker-99-uninstall.sh --purge --yes && \
bash docker-01-install.sh && \
bash docker-02-start.sh --admin-email ... --admin-pass ...
```

**镜像删不删**：`docker-99-uninstall.sh --purge` 不删镜像（下次装更快）。
要彻底清盘再加 `docker rmi energy/guard-server:4.4.0 eclipse-temurin:25-jre postgres:16`。

**验证删干净了**：

```bash
docker ps -a | grep energy          # 应该无输出
docker volume ls | grep energy      # 应该无输出
ls ~/energy-app                     # 只剩 data/ 和 .env（如果没 --purge）
```

---

## 两个只在干净库才暴露的坑

### ① install 报 `No qualifying bean of type ...IdleEnergyService`

**不是数据库问题，是 install 程序的装配范围问题。**

install 用 `ThingsboardInstallApplication`，它的 `@ComponentScan` 只扫建库需要的包。
业务服务新加了对 `service.energy` 的注入却忘了同步扫描范围，Spring 在建库之前就起不来，
日志看起来像「建库失败」。

判据：install 报 bean 找不到 → 看那个 bean 的包在不在 `@ComponentScan` 里；
如果是「bean 在但依赖为 null」→ 把运行时依赖改成 `@Autowired(required = false)`。

### ② install 报 `NoSuchFileException: /opt/energy/data/sql/schema-entities.sql`

部署目录的 `data/sql` 被删了（比如 `rsync --delete` 同步过整个 `data/`）。

```bash
cp -R shiyongshouce/../../../guard-server/src/main/data/sql ~/energy-app/data/sql
ls ~/energy-app/data/sql/*.sql | wc -l    # 必须 8
```

**绝不要用 `rsync --delete` 同步整个 `data/`**：部署侧有源码没有的 `cassandra/`。
用 `scripts/32-check-deploy-sync.sh --fix`，它同步 `json/`、`sql/` 与 `scripts/`
三类，且不会删部署侧多余的文件。
