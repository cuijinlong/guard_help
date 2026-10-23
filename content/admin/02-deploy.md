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

**`.env` 里的遥测后端**（新版本新增，默认 `cassandra`）：

```properties
DATABASE_TS_TYPE=cassandra        # cassandra（默认）| sql
DATABASE_TS_LATEST_TYPE=sql       # 建议留 sql：查询快、与实体同库
```

| 值 | 起几个容器 | 首次启动 | 什么时候选 |
| --- | --- | --- | --- |
| `cassandra`（默认） | postgres + **cassandra** + server… | 约 7 分钟 | 正式部署，设备会持续增长 |
| `sql` | postgres + server… | 约 2 分钟 | 只有 2GB 内存，或纯功能演示 |

脚本会读这个值：`cassandra` 时自动带 `--profile cassandra` 起容器并等它就绪，
`sql` 时**不启动** Cassandra（不白占 2G 内存）。详见[②b Cassandra](/admin/cassandra)。

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
  --admin-pass 'CJLqh@163' \
  --public-url 'http://<你的IP>:8090'
```

**`--public-url` 决定客户拿到的激活链接**（不传会自动探测本机 IP + 端口）。
生产环境请传真实域名，传错的表现是客户点开链接 404 —— 见
[故障排查 → 现象 A2](/admin/troubleshoot#_现象-a2-客户账号建好了-但激活链接点开是-80-打不开)。

**预计输出**：

```
[10:16:30] 等待服务就绪（Cassandra 首次约 5–8 分钟）
  ✓ 服务已就绪（420s）：{"status":"ACCOUNT_REQUIRED"}
[10:17:10] 创建系统管理员 langmen@126.com
  ✓ 管理员已创建
  ✓ 设备接入通道已开放（HTTP + MQTT）
  ✓ MQTT 端口 1883 正在监听
```

**首次启动 3–5 分钟**（要构建分析服务镜像），之后重启 20 秒。

**验证**：浏览器打开 `http://本机IP:8090`，用 `langmen@126.com / CJLqh@163` 登录。

### 顺手确认两件事（生产必做）

**① 日志是不是按天落盘**

```bash
cd ~/energy-app
grep '^SPRING_PROFILE' .env     # 期望 pro（dev 只有控制台，不留文件）
ls -lh logs/                     # 期望看到 guard-server.log
```

不是 `pro` 就改：

```bash
sed -i 's/^SPRING_PROFILE=.*/SPRING_PROFILE=pro/' .env
docker compose --profile split up -d --force-recreate energy-server
```

**② 对外地址是否正确**

```bash
docker compose exec -T postgres psql -U postgres -d thingsboard -tAc \
  "SELECT json_value FROM admin_settings WHERE key='general';"
# 期望 baseUrl 是你的真实地址，不是 localhost:8080
```

> 日志规则：`pro` 一天一个文件 `guard-server.YYYY-MM-DD.log`，保留 30 天、总量上限 2GB。
> 详见 [⑤ 常见问题 → 日志在哪](/admin/troubleshoot#_日志在哪-没有文件日志-全在-docker-里)。

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
✓ 以系统管理员身份操作
! 租户已存在，跳过创建            ← 首次部署是「租户已创建」
! 租户管理员已存在，复用该账号
✓ 已切换为租户管理员身份
✓ 客户已创建
✓ 客户管理员已创建并激活（可用该邮箱登录）
✓ 能源参数字典：1 个
✓ 四个维度根齐全
✓ 系统部件：726 个
✓ 能耗管理部件：32 个
✓ 演示数据：2 个场站 / 12 个分项
✓ 演示设备：21 台
✓ 演示拓扑：2 张（每个场站一张）
✓ 客户菜单已安装
✓ 仪表板已分配给客户：20 个
✓ 全部验证通过
```

**这一步就把所有初始化做完了** —— 用户、字典、字段、菜单、演示数据、拓扑、看板，一次到位。

除了上面逐项打印的，这一步还会建好以下内容（数量由代码里的常量决定，
脚本不逐条比对，但 `scripts/08-verify-release.sh` 会验）：

> 资产档案 14 个 / 设备档案 7 个、告警与派生指标 11 条（挂在电表档案上）、
> 厂商 17 个 / 设备型号 9 个、分时时段方案 4 套。

明细见[③ 数据初始化](/admin/init)。

> **脚本会自己核对结果，不是「调完接口就说成功」。**
> 上面 11 项验证全部实测；任何一项不对都会以非 0 退出并指明缺什么。
> 这是「平台上线的底座」这条定位的硬要求 —— 创建成功但页面空着，比直接报错更难查。

#### 如果 install 报「No qualifying bean」

```
Error creating bean with name 'energyBootstrapInstaller':
No qualifying bean of type 'com.guard.server.service.energy.IdleEnergyService'
```

**这不是数据库问题，是 install 程序的装配范围问题。**

install 用的是 `ThingsboardInstallApplication`，它的 `@ComponentScan` 只扫建库需要的包。
如果业务服务里新加了对 `service.energy` 的注入却忘了同步扫描范围，
Spring 在建库之前就起不来，日志表现为「建库失败」。

修复（2026-10-22 已修，记在这里供排查参考）：
`ThingsboardInstallApplication` 的 `@ComponentScan` 必须包含
`com.guard.server.service.energy`；同时 `IdleEnergyService` 对
`TelemetrySubscriptionService` 的依赖必须是 `@Autowired(required = false)` ——
后者是运行时组件，install 阶段不存在。

> **判断口径**：install 报 bean 找不到 → 看那个 bean 所在的包在不在
> `@ComponentScan` 里；如果是「bean 在但依赖为 null」→ 把运行时依赖改成可选。

#### 一键开通一个客户（只给一个账号，带演示数据）

**这是最常见的日常动作**：平台已上线，来了一家合作企业，
只想给他一个账号，他登录就能用。

```bash
cd ~/energy-app
bash scripts/09-onboard-customer.sh \
  --email customer2@company.com \
  --password 'Cust@123456'
```

就这两个参数。**客户名不传时从邮箱前缀推导**（`customer2@company.com` → `customer2`），
也可以用 `--name '某某公司'` 指定。

租户管理员凭据自动从 `DEPLOY-CREDENTIALS.txt` 读（重装时生成），不用再填。

**它会做什么**：

| 步 | 动作 |
| --- | --- |
| 1 | 建客户 + 建客户管理员账号 + 激活（密码就是 `--password`） |
| 2 | 确保演示数据（2 场站 / 12 分项 / 21 台设备 / 近 7 天逐小时遥测） |
| 3 | 装客户菜单 13 项（第一项是落地页）+ 复制 20 个看板 |
| 4 | 逐项验证，任何一样缺失就报错 |

**输出**（真实样例）：

```
步骤 1/3　建客户与账号（复用 02-onboard.sh）
  ✓ 场站：2
  ✓ 分项（分类）：12
  ✓ 设备：21
  ✓ 拓扑图：2
  ✓ 客户看板：20
  ✓ 客户菜单项：13
  ✓ 落地页（菜单第一项是 home）

  客户已开通
 登录地址   http://127.0.0.1:8090
 账号       demo2@test.com
 密码       Demo@123456
 客户 ID    d26cf2b0-ce10-11f1-830e-2bd5ff07be79
```

同时打印**数据落表清单**与**查询 SQL**，并把交付信息写到
`ONBOARDED-<客户ID>.txt`（权限 600，反复入驻时回查用）。

**几条要点**：

- **幂等**：同一个邮箱重复执行会复用客户与账号，不会建第二份演示数据
- **不写死任何密码**：凭据从部署目录的 `DEPLOY-CREDENTIALS.txt` 读
- **密码至少 8 位**（TB 的默认要求）
- **演示数据可随时清空**：客户「平台自检」或 `DELETE /api/energy/demo-data?customerId=<id>`，
  只删 `additionalInfo.demo=true` 的实体，客户自建的不受影响

> 客户拿到账号登录后：直接落在「能耗概览」，左侧 13 项菜单全部有数据。
> 他可以在「组织与场站」改场站、在「设备分组」挂设备、在「设备拓扑」看图，
> 现场装好 RTU 填上令牌就能采数 —— 不需要平台方再介入。

> 数据落在哪些表、怎么查，见
> [运维常用 SQL → 14.16 一个客户的数据落在哪些表](/admin/troubleshoot#_14-16-一个客户的数据落在哪些表-入驻后自查)。

#### 清理一个客户（不合作了 / 建错了）

试用客户谈不成、或者测试建错了要重来，就把这个客户**连带它的全部数据**删掉。

```bash
cd ~/energy-app
bash scripts/10-cleanup-customer.sh --email customer2@company.com --dry-run   # 先看要删什么
bash scripts/10-cleanup-customer.sh --email customer2@company.com             # 确认后执行
```

**定位客户**三选一：`--id <uuid>` / `--name '完整客户名'` / `--email <账号邮箱>`。
`--email` 先按「客户名 = 邮箱前缀」匹配，匹配不到会用用户表反查，所以自定义客户名也能找到。

**它会做什么**：

| 步 | 动作 |
| --- | --- |
| 1 | 定位客户，盘点名下数据（场站 / 分项 / 拓扑 / 设备 / 看板 / 用户 / 遥测点数） |
| 2 | 预检：待删设备是否真的都属于这个客户（不通过就中止） |
| 3 | 拍快照：记录「目标以外世界」的实体数与 id 指纹 |
| 4 | 删客户（级联删资产 / 设备 / 用户 / 看板 / 关系 / 属性） |
| 5 | 清遥测（`ts_kv`，按**删前记下的设备 id** 精确匹配） |
| 6 | 清该客户的菜单（按删前记下的 id，且确认无其他客户引用） |
| 7 | 复查一：目标是否清零 |
| 8 | 复查二：**其他客户与租户级数据是否一字节没动** |

**输出**（真实样例）：

```
  ✓ 预检：21 台设备全部属于「清理测试C」
  ✓ 预检：客户名下实体租户归属一致
============================================================
  即将删除：「清理测试C」
============================================================
 客户 ID    700b5f50-ce13-11f1-830e-2bd5ff07be79
 场站 2   分项 12   拓扑图 2   资产合计 29
 设备       21
 看板副本   20
 用户       1
 遥测数据   130082 个数据点（一并删除）
------------------------------------------------------------
 影响面     仅此客户。其他客户 131 个实体（含租户级）已拍快照，
            删后逐项校验，不一致会报错退出。
------------------------------------------------------------
  ✓ 已删除 130082 个数据点（删前计数 130082）
  ✓ 已彻底清理（客户 / 资产 / 设备 / 看板 / 用户 全为 0）
  ✓ 遥测：目标以外 129651 → 129651 点（本次删了 130082 点，未波及他人）
  ✓ 遥测：目标设备已无残留（0 点）
  ✓ 隔离校验通过：其他客户 131 个实体与租户级数据均未受影响
```

**为什么多了一个「隔离校验」**

删客户是**高危操作**。只靠「代码看起来只删这一个客户」不够，脚本会给出证据：
删除前给「目标以外的所有实体」拍一个指纹（实体数 + 全库 id 的 md5），
删完必须逐位相同；遥测则要求「目标以外的点数只增不减」。
任何一项不符 → **退出码 2** 并打印差异，明确提示立即恢复备份。

**实测确认**（删一个 29 资产 / 21 设备的客户）：

```
全库资产   98 → 69   减少 29 = 该客户的资产数
全库设备   42 → 21   减少 21
全库看板   60 → 40   减少 20
全库客户    2 → 1
星河工业园 29 资产 / 21 设备 / 20 看板 / 1 用户 / 129302 点   ← 一个数都没动
```

**几条要点**：

- **删了就没了**：平台没有客户级回收站。删前建议先备份
- **默认要输入 `yes` 确认**；脚本化调用加 `--yes`
- **只想清演示数据、保留客户和账号**：用
  `DELETE /api/energy/demo-data?customerId=<id>`，它只删 `additionalInfo.demo=true` 的实体
- **遥测默认一并删除**。要留着做分析就加 `--keep-telemetry`
  （注意：保留的遥测会变成设备表里查不到的孤儿数据）
- **不会碰的**：租户、租户管理员、其他客户、租户级主数据（字典 / 费率模板 / 分时方案）、
  TB 内置的三个默认菜单模板、TB 自身的系统监控指标
- **设备删了但遥测没删是 TB 的原生行为** —— `ts_kv` 按 `entity_id` 存在分区表里，
  不随设备级联。不清理会一直占盘，这正是脚本要在删客户**之前**记设备 id 的原因

**清理后怎么复核**：

```sql
-- 换成刚删掉的客户 id，下面每条都应该是 0
SELECT (SELECT count(*) FROM customer  WHERE id = '<客户id>')
     + (SELECT count(*) FROM asset     WHERE customer_id = '<客户id>')
     + (SELECT count(*) FROM device    WHERE customer_id = '<客户id>')
     + (SELECT count(*) FROM dashboard WHERE customer_id = '<客户id>')
     + (SELECT count(*) FROM tb_user   WHERE customer_id = '<客户id>');

-- 有没有留下悬空的菜单引用（应为 0）
SELECT count(*) FROM customer c
WHERE c.custom_menu_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM custom_menu cm WHERE cm.id = c.custom_menu_id);

-- 其他客户还在不在（数量应与删除前一致）
SELECT title FROM customer ORDER BY created_time;
```

> 排查这类问题的方法论（为什么不能用总量等式校验、TB 系统指标为什么会出现在 `ts_kv` 里），
> 见知识库 `05-踩坑清单.md` 第十节「客户清理与隔离校验」。

#### 再入驻一个客户（不重装、不影响老客户）

租户已经建好了，只是要再加一个客户。**不要传 `--tenant`**：

```bash
cd ~/energy-app
bash scripts/02-onboard.sh \
  --base http://127.0.0.1:8090 \
  --admin langmen@126.com --admin-pass 'CJLqh@163' \
  --tenant-email tenant@126.com --tenant-pass '12345678' \
  --customer "第二客户" \
  --customer-email customer2@126.com --customer-pass '12345678'
```

**为什么用系统管理员还要传 `--tenant-email`**：

TB 的 `CustomerController` 只允许 `TENANT_ADMIN` / `CUSTOMER_USER` 建客户，
系统管理员（`SYS_ADMIN`）不属于任何租户，直接建会被 **403** 拒绝。
脚本拿到这两个参数后会**切换成租户管理员身份**再继续 ——
这也正是真实 SaaS 的入驻分权：平台方只开通租户，租户内的客户由租户自己维护。

不传的后果是脚本直接报错并提示补参数，不会留下半套数据。

**重跑是安全的**：租户 / 客户 / 账号已存在时都会跳过创建并复用，
不会重复建演示数据，也不会影响已有客户。

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
bash docker-02-start.sh --admin-email langmen@126.com --admin-pass 'CJLqh@163' \
  --public-url 'https://energy.example.com'
bash scripts/02-onboard.sh ...（参数同上，--base 换成服务器地址）
```

**`--public-url` 要传对**（不传会自动探测本机 IP + 端口）：
它决定客户拿到的**激活链接**和**忘记密码链接**里的地址。
填错的表现是客户点开链接 404 / 连接被拒 —— 见
[故障排查 → 现象 A2](/admin/troubleshoot#_现象-a2-客户账号建好了-但激活链接点开是-80-打不开)。

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

#### 改完后端，先跑自检（30 秒）

`docker-97-preflight.sh` 检查「源码 / 部署 jar / 脚本 / 运行服务 / 手册」五处是否一致：

```bash
bash shiyongshouce/downloads/deploy/docker-97-preflight.sh
# 期望末行：产物一致，可以开始验收。
```

它防的是本次真实踩过的坑：**改了源码没 `cp` jar，测的是旧代码，白查半天**。
自检不过就不要往下验收 —— 那是在验旧版本。

检查项：

| 项 | 不一致说明什么 |
| --- | --- |
| 部署目录完整性 | 组装脚本没跑全 |
| jar 一致性（比 md5） | 忘了 `cp target/guard-server-4.4.0.jar` |
| 脚本一致性 | 改了 `downloads/scripts/` 没同步到 `~/energy-app/scripts/` |
| 服务健康 | 容器没起 / 端口不对 |
| 手册一致性 | 没跑 `check-docs.py` / `sync.sh` |

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

## 脚本一览（谁负责什么）

**仓库里**：`shiyongshouce/downloads/`

| 脚本 | 干什么 | 在哪跑 |
| --- | --- | --- |
| `deploy/docker-00-prepare.sh` | 组装部署目录（拷 jar / 脚本 / 模板） | 仓库根 |
| `deploy/docker-01-install.sh` | 建库 | `~/energy-app` |
| `deploy/docker-02-start.sh` | 启动全栈 + 建管理员 | `~/energy-app` |
| `deploy/docker-97-preflight.sh` | **一致性自检**（jar / 脚本 / 服务 / 手册） | 任意 |
| `deploy/docker-98-rebuild.sh` | **一键重装**（推荐） | 仓库根 |
| `deploy/docker-99-uninstall.sh` | 卸载（`--purge` 连卷一起删） | `~/energy-app` |
| `scripts/01-install.sh` | install 的容器内入口 | 被 01 调用 |
| `scripts/02-onboard.sh` | 租户 + 客户入驻 | `~/energy-app` |
| `scripts/03-verify.sh` | 结构验收 | `~/energy-app` |
| `scripts/04-verify-data.sh` | 数据验收 | `~/energy-app` |
| `scripts/05-import-customer-data.py` | 客户台账导入 | `~/energy-app` |
| `scripts/06-verify-e2e.sh` | 全链路验收（53 项） | `~/energy-app` |
| `scripts/07-init-menu.sh` | 菜单重建 | `~/energy-app` |
| `scripts/08-verify-release.sh` | 发布内容验收（75 项） | `~/energy-app` |
| `scripts/09-onboard-customer.sh` | **一键开通一个客户**（带演示数据） | `~/energy-app` |
| `scripts/10-cleanup-customer.sh` | **清理一个客户**（连带遥测，含隔离校验） | `~/energy-app` |
| `scripts/11-cassandra.sh` | **Cassandra 管理**（status/init/enable/disable/uninstall） | `~/energy-app` |
| `scripts/20-rtu-simulator.py` | **RTU 模拟器**（无硬件时造新鲜数据；顺带验 key 转换） | `~/energy-app` |

> `docker-00` 与 `docker-97` / `docker-98` **只在仓库里**，不要从部署目录找 ——
> 它们要读仓库源码。

**部署目录 `~/energy-app` 该有哪些**（少一个就是组装不完整）：

```
docker-compose.yml  docker-01-install.sh  docker-02-start.sh  docker-99-uninstall.sh
scripts/01..11-*.sh  scripts/05-import-customer-data.py  scripts/20-rtu-simulator.py
```

**改脚本的铁律**：

```
shiyongshouce/downloads/scripts/*.sh   ← 唯一真相，只改这里
        ↓ cp（或跑 docker-00-prepare.sh）
~/energy-app/scripts/*.sh              ← 运行副本，不直接改
```

改完不同步 = 手册说能过、实际跑的是旧脚本。`docker-97-preflight.sh` 第 3 节会查这个。

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
