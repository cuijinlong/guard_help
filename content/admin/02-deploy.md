# ② 系统部署

从一台空机器，到客户能登录看到数据。**照着走，不用改任何东西。**

只有一种情况需要停下来查别的页：Docker 本身装不上 → [① 安装环境](/admin/install)。

---

## 先看这两行

**这一页 8 步，顺序不能换。** 每步都有一句「看到这个才算成功」——对不上就别往下走。

| 第几步 | 做什么 | 大概多久 |
| --- | --- | --- |
| 第 1 步 | 检查电脑环境 | 10 秒 |
| 第 2 步 | 打 jar（含前端） | 12 分钟 |
| 第 3 步 | 组装部署目录 | 1 分钟 |
| 第 4 步 | 建库 | 2–3 分钟 |
| 第 5 步 | 启动 + 建系统管理员 | 1–2 分钟 |
| 第 6 步 | 建租户 | 1 分钟 |
| 第 7 步 | 建第一个客户 | 1–2 分钟 |
| 第 7b 步 | 接入真实 RTU（现场演示必做） | 3 分钟 |
| 第 8 步 | 登录验收 | 2 分钟 |

**开始前记下三个密码，后面每一步都要用：**

| 什么时候设 | 是什么 | 记在哪 |
| --- | --- | --- |
| 第 3 步自动生成 | 数据库密码 | 第 3 步会打印，抄下来 |
| 第 5 步你自己定 | 系统管理员密码 | 自己想一个 |
| 第 6 步你自己定 | 租户管理员密码 | 自己想一个 |

---

## 软件怎么带到现场

**手册和软件包是两条路，别混。**

| 东西 | 多大 | 怎么带 |
| --- | --- | --- |
| 这套手册 | 几 MB | Cloudflare Pages 自动发布，现场用手机/笔记本直接看 |
| 软件包 | **约 550 MB** | **U 盘带过去**。不要往 Cloudflare 传 —— 静态站点不适合发大文件，而且现场往往没网 |

### 出发前在办公室打一个包

```bash
cd <你的仓库目录>
bash shiyongshouce/downloads/deploy/docker-00-prepare.sh --pack
```

产出 `dist/energy-deploy-<日期>.tar.gz`（约 550 MB），里面已经包含：

- `guard-server-4.4.0.jar`（含前端产物）
- 586 个部件定义、30 个看板模板
- 建表 SQL、运维脚本、`docker-compose.yml`
- **现场要用的 `scripts/09-onboard-customer.sh` 与 `30-rtu-env-init.py`**

拷到 U 盘前先自检一遍：

```bash
ls -lh dist/energy-deploy-*.tar.gz
tar -tzf dist/energy-deploy-*.tar.gz | head -20
md5sum dist/energy-deploy-*.tar.gz > dist/md5.txt   # 一起拷到 U 盘
```

> **jar 是包里的主要体积**（430 MB 左右），前端产物已经打进 jar，
> 现场不需要 `npm install`、不需要 Node、不需要联网。

### 到现场解压后继续

```bash
# 目标机上（U 盘挂载后）
tar -xzf /media/usb/energy-deploy-*.tar.gz -C /opt/
cd /opt/energy-deploy
md5sum -c /media/usb/md5.txt        # 先验完整性
```

然后从**第 1 步**开始（装 Docker），第 3 步不用再跑 `--pack`，
直接按第 4 步建库即可。

> **为什么现场不需要重新构建**：jar 已经带了前端产物与全部部件定义。
> 构建那 12 分钟只在**改代码之后**才需要，客户现场不做开发。

---

## 第 1 步　检查电脑环境

```bash
java -version 2>&1 | head -1
node -v
docker ps > /dev/null 2>&1 && echo "docker 正常" || echo "docker 没起来"
```

**看到这个才算成功**：

```
java version "25..."        ← 必须是 25 或更高
v22.x.x                     ← 18 以上都行
docker 正常
```

不对怎么办：

| 现象 | 怎么办 |
| --- | --- |
| java 版本低于 25 | `brew install --cask temurin@25`（macOS） |
| 没有 node | 装 Node 18+ |
| docker 没起来 | 打开 Docker Desktop，等鲸鱼图标不再转 |

---

## 第 2 步　打 jar（含前端）

**在哪执行：仓库根目录**（有 `guard-server/` 和 `shiyongshouce/` 的那一层）

```bash
cd <你的仓库目录>
bash guard-server/pack.sh
```

等 12 分钟左右。它会依次做：**同步远端 → 构建前端 → 打包后端 → 检查 jar 里有没有前端**。

> **两台机器开发**（2026-11-07 起）：第 1 步会自动 `git fetch + pull`，
> 并把另一台推上来的部件/看板改动直接应用到运行环境。
> 离线或不想拉：`--no-sync`。详见后面「三个会让你翻车的坑」的坑 1.2。
>
> **想一条命令到重启**：
>
> ```bash
> bash guard-server/pack.sh --deploy
> ```
>
> 打完拷 jar 到 `~/energy-app/`、重启 `energy-server` 并等到 healthy（实测 1–2 分钟）。
> 部署目录不在 `~/energy-app`：`--app-home /path/to/app`。

**看到这个才算成功**：

```
✓ 打包成功  用时 12m14s

  JAR : .../guard-server/target/guard-server-4.4.0.jar
  大小: 576M
```

再确认这两行也是 ✓：

```
✓ 内嵌 UI：index.html 存在，public/ 下 10268 个文件
✓ 主类 ThingsboardServerApplication
```

不对怎么办：

| 现象 | 怎么办 |
| --- | --- |
| `jar 内无 UI` | 前端没打进去。去掉 `--skip-ui` 重跑 |
| 报「需要 JDK 25」 | 回第 1 步 |
| 要连跑第二次 | 只改了 Java：`bash guard-server/pack.sh --skip-ui`（省 4 分钟） |
| `--skip-ui` 报「前端产物与源码不一致」 | 确实改了前端：去掉 `--skip-ui`；只改 Java 想复用：加 `UI_ALLOW_STALE=1` |
| `--deploy` 报「找不到 docker-compose.yml」 | `--app-home` 指向错的目录，或这台机器没装部署环境 |

> 已经打过 jar、这次没改后端代码？**跳过这一步**，直接去第 3 步。

---

## 第 3 步　组装部署目录

**在哪执行：仓库根目录**

```bash
cd <你的仓库目录>
bash shiyongshouce/downloads/deploy/docker-00-prepare.sh
```

它把 jar、部件、看板模板、建表 SQL、运维脚本全部装进 `~/energy-app`，并生成数据库密码。

**看到这个才算成功**：

```
第 1 步完成：部署文件已准备好

  部署目录
    /Users/<你>/energy-app

  数据库密码
    ce604943640f7b6c287c992b    ← 抄下来！
```

**马上验证三个数字**：

```bash
ls ~/energy-app/guard-server-4.4.0.jar
ls ~/energy-app/data/json/tenant/dashboards/ | wc -l     # 必须是 30
ls ~/energy-app/data/sql/*.sql | wc -l                   # 必须是 8
```

30 和 8，对不上就是组装漏了东西，回第 2 步确认 jar 存在后重跑。

> **要装到「另一台机器」？** 这一步换成：
> ```bash
> bash shiyongshouce/downloads/deploy/docker-00-prepare.sh --pack
> ```
> 会把同样的东西打成一个 `dist/energy-deploy-<日期>.tar.gz`（约 549MB）。
> 然后传过去解压，再接着做第 4 步：
> ```bash
> scp dist/energy-deploy-*.tar.gz root@<目标机IP>:/opt/
> ssh root@<目标机IP>
> cd /opt && tar -xzf energy-deploy-*.tar.gz && cd energy-deploy
> ```
> 之后第 4–8 步一模一样，只是要把 `~/energy-app` 换成 `/opt/energy-deploy`。

---

## 第 4 步　建库

```bash
cd ~/energy-app
bash docker-01-install.sh
```

建表 + 导入系统部件。等 2–3 分钟。

**看到这个才算成功**（数字由脚本自己算，不是写死的）：

```
✓ install 完成：153 张表 / 744 个部件 / N 个 bundle / N 个用户
```

想确认真的建好了，再查一次：

```bash
docker exec energy-postgres psql -U postgres -d thingsboard -tAc \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';"
```

输出应该在 **150 上下**（会随版本增加）。**不是 0 就是对的**。

不对怎么办：

| 现象 | 怎么办 |
| --- | --- |
| `库已有 N 张表` | 这台装过了。**不要重来**，直接去第 5 步 |
| `NoSuchFileException: .../sql/schema-entities.sql` | 部署目录不完整，回第 3 步 |

---

## 第 5 步　启动服务 + 建系统管理员

`you@example.com` 和 `'你的密码'` 换成你自己的（密码自己想，先记下来）。

```bash
cd ~/energy-app
bash docker-02-start.sh --admin-email you@example.com --admin-pass '你的密码'
```

起容器 → 等健康 → 建管理员。

**看到这个才算成功**：

```
✓ 管理员已创建
...
✓ Web 入口 8090 正常（经 gateway）
```

不对怎么办：

| 现象 | 怎么办 |
| --- | --- |
| 卡在「等待服务」超过 3 分钟 | `docker logs energy-server --tail 50` 看日志 |
| `HTTP 000` / 连不上 | 后端还没起来，等 1 分钟重跑同一条命令 |
| `HTTP 502/503` | 同上 |

> 内存小于 10GB 的机器（笔记本、演示机），加 `--allinone` 用单容器模式，省约 2GB。

---

## 第 5b 步　数据分析子应用（spsspro）

平台自带一个独立的分析子应用，用于「模拟电表遥测 → 选区设备建数据集 →
发现用能质量线索 → 训练模型 → 出报告」的完整闭环。它跟 ngx-ai 一样，
是 gateway 后面的一个平级服务，**不用单独装、不用单独配**。

### 在哪

```
http://<平台IP>:8090/spsspro/
```

从平台左侧导航的「数据分析」进去也行。

### 三个必须知道的事实

**① 数据是模拟的，不是现场真实数据**

底部健康接口明确返回 `has_real_data: false`。模拟器按物理模型生成
三相电压/电流/功率/谐波等 46 个指标，并在其中**故意埋了 5 类用能质量问题**
（谐波超标、三相不平衡、功率因数低、电压偏差、负荷异常）。
用途是：在没有真实表计的时候，把"从数据发现问题"的完整流程跑通、
把分析方法和报告模板定下来。**给客户演示时必须说明这一点。**

**② 数据独立存一个卷，不跟 ThingsBoard 混**

```
energy-spsspro-data  →  容器内 /data
                        ├── JJTDDatasets/        上传的数据集
                        ├── JJTDTempDatasets/    临时数据集
                        ├── metadata.duckdb      数据集元数据
                        └── models/              训练产物
```

删容器、升级镜像都**不会**丢；只有 `docker compose down -v` 才会删。

**③ 第一次启动慢**

镜像要装 numpy/scipy/scikit-learn/catboost/shap/statsmodels/matplotlib，
体积约 1.3GB，首次构建实测 **13 分钟左右**（其中 pip 下载 llvmlite 一个包就占 6 分钟）。
之后只要 `requirements.txt` 没改，重建走层缓存，几十秒。

### 验证它真的能用

```bash
# 后端活着（绕过 nginx）
docker exec energy-spsspro-backend curl -fsS http://127.0.0.1:9000/health
# 期望：{"status":"ok"}

# 经 gateway（这才是客户实际走的路径）
curl -s --noproxy '*' http://127.0.0.1:8090/spssproapi/explore/health
# 期望：{"success":true,...,"has_real_data":false}

# 前端页面
curl -s --noproxy '*' -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8090/spsspro/
# 期望：200
```

### 不对怎么查

| 现象 | 原因 | 怎么办 |
| --- | --- | --- |
| `/spsspro/` 返回 **500** | 前端产物没挂上（目录不存在） | `ls ~/energy-app/spsspro-dist/index.html`；没有就重跑 `docker-00-prepare.sh` 再 `docker compose up -d --force-recreate --no-deps gateway` |
| `/spsspro/` 返回 **404** | 同上，或 gateway 未重建 | 同上 |
| 页面能开但**一片白屏** | 构建时 base 不是 `/spsspro/` | `grep -o 'src="[^"]*"' ~/energy-app/spsspro-dist/index.html`，应该带 `/spsspro/assets/` |
| `/spssproapi/...` 返回 **404** | 请求被转给了 Java 服务 | 确认访问的是 `/spssproapi/` 而不是 `/api/` |
| 接口 **超时 / 504** | 算法真的在跑（shap 很慢） | nginx 已设 600s；换个窗口看 `docker logs -f energy-spsspro-backend` |
| 容器一直 **unhealthy** | 依赖没装完或启动报错 | `docker logs energy-spsspro-backend --tail 50` |

> **不要**把 8090 的 `/spsspro/` 改成直连后端 9000 —— 直连会丢掉
> nginx 的 SPA 回退（刷新深链接直接 404）、gzip 和 WebSocket 升级。

#### 改了 Python 代码怎么生效（**不用重新 build**）

后端业务代码是通过 compose 的 `volumes` **挂进容器**的，镜像只装 pip 依赖。
所以改完 `.py` 只需要 3 秒：

```bash
cd <仓库目录>/spsspro/deploy && ./sync.sh --backend     # 仓库 → ~/energy-app，秒级
cd ~/energy-app && docker compose --profile split restart spsspro-backend
```

**不要** `docker compose build`（5~8 分钟）—— 只有改了 `requirements.txt`
（新增第三方包）才需要：

```bash
cd ~/energy-app && docker compose --profile split up -d --build spsspro-backend
```

两条排错要点：

- **新增的 `.py` 必须放进已挂载的目录**（`energyflow/` `routers/` `dvadmin/`
  `config/` `tcp/`）。挂到别处容器里读不到，且不报错。
- **不要挂单个文件**（`main.py` 除外）。单文件 bind mount 在容器内写文件时
  inode 会断，容器读到的还是旧内容 —— 表现就是「改了没生效」。

### 电能质量分析：从建表到出报告

这一节是完整的一条链路，照做就能得到一份「哪台表该先改、主要问题是什么」的报告。

#### ① 建 6 台三相质量示范表

> **这一步不是自动的。** 部署脚本（`01-install.sh` / `02-onboard.sh`）**不会**
> 建这 6 台表 —— 只有手工跑 `43-seed-quality-meters.mjs` 才有。
> 新环境照下面两条命令做一次即可（脚本幂等，重跑不会重复建）。

```bash
cd <仓库目录>
node nenghaobao/energy-config/43-seed-quality-meters.mjs          # 先看会建什么（dry-run）
node nenghaobao/energy-config/43-seed-quality-meters.mjs run      # 执行
node nenghaobao/energy-config/43-seed-quality-meters.mjs verify   # 自检属性是否齐全
```

**只建档案不写数据**，遥测由第 ② 步的模拟器上报。

> 脚本必须写齐 5 个平台标准属性：`type1`（电能）、`type2`（表计类型）、
> `meterLevel`（2 分项）、`wiring`（3P4W）、`additionalInfo.siteId`（质量示范站）。
> **少任何一个，数据探索的设备树里就看不到这台表** ——
> 表现是「品种空 / 层级 0 / 无场站」，而脚本本身不报错。

6 台表各对应一类典型问题，属性里带 `qualityProfile`：

| 表 | 画像 | 特征 |
| --- | --- | --- |
| 三相质量-01 正常 | `normal` | 对照组，各项在国标限值内 |
| 三相质量-02 谐波超标 | `harmonic` | 电流 THD 26~38%（限值 8%） |
| 三相质量-03 三相不平衡 | `unbalance` | 电流不平衡约 50%（工程口径 ≤10%） |
| 三相质量-04 功率因数低 | `low_pf` | cosφ 0.64~0.72（考核值 0.90） |
| 三相质量-05 重载过载 | `overload` | 日间负载率峰值约 105% |
| 三相质量-06 电压偏差 | `voltage` | 相电压约 201V，偏差 -8.4%（限值 ±7%） |

#### ② 灌数据（模拟上报）

```bash
cd spsspro/tools/meter-sim
python3 sim.py list                      # 确认 6 台表和画像
python3 sim.py backfill --days 7         # 回填 7 天（5 分钟粒度，约 10 秒）
python3 sim.py check --days 1            # 抽查物理自洽性
```

上报走的是**设备的 ACCESS_TOKEN 接口**，和现场 RTU / 网关同一条链路 ——
不是直接写数据库。所以设备在线状态、最后活跃时间都会跟着更新。

> **为什么要 5 分钟粒度**：用能质量看的是波形特征，1 小时均值会把谐波尖峰、
> 不平衡抖动全部抹平。现场电能质量仪表的标准记录间隔就是 3~15 分钟。

```bash
python3 sim.py stream --interval 300     # 常驻实时上报（演示用，Ctrl+C 停）
```

#### ③ 在页面上做分析（三步向导）

菜单入口 **「分析向导」**（`/spsspro/wizard`）。整条路径是三步，和 TB 的
模型创建流程一致：**先说查什么 → 再定义对象 → 最后调参并启动**。

> 页面里**没有场站下拉框** —— 场站只认右上角那一个。从客户账号菜单进来时
> 默认取第一个有表的场站；右上角切了，页面 800ms 内自动换树并清空已选设备。
> 一个页面两个场站源，迟早会出现「树上是 A 园区、数据是 B 园区」。

**第一步：你想检测什么 / 想预测什么**

两类模型，回答两个不同的问题，不能混：

| 类型 | 回答的问题 | 引擎 |
| --- | --- | --- |
| 检测模型 | 过去到现在，哪里出了问题？ | 国标判据 + 隔离森林 + AHP/TOPSIS |
| 预测模型 | 接下来会发生什么？ | 季节性基线 + 趋势，walk-forward 回测 |

检测场景 4 个：电能质量诊断、用能异常排查、容量与负荷匹配、计量数据可信度。

预测按四种策略分（与 TB 预测控件同名，客户不用重新学）：

- **预报** · 未来轨迹 —— 预测明天每台设备的负荷曲线
- **短视 · 达到阈值所需时间** —— 负荷何时会超过变压器容量
- **期末总计** —— 到月底该场站将消耗多少电能
- **击中目标** —— 本月用电能否控制在目标值以内

**第二步：输入配置（目标实体 + 遥测字段）**

- 目标实体：设备树，可按关口/普通表、相制筛选；默认只列**三相四线**表
- 遥测字段：**按场景预置**。检测类可多选（必需项取消会被拦下）；
  预测类只能选一个主指标 —— 多指标各建一个模型，不能混在一个预测里
- 时间范围：7 / 14 / 30 / 60 天 + 重采样粒度

**第三步：审查与构建**

左边审查配置并列出「这份数据能支撑哪些判据」（缺哪项、依据哪条国标），
中间按实际工况微调检测参数（每项都写了改了会怎样），右边选运行方式：

- **仅运行一次** → 立即出结果
- **保存为定时任务** → 每隔 N 分钟 / 每天定时自动跑

点「启动分析」后一次跑完：取数 → 建数据集 → 检测/预测 → 统计分析 → 归因 → 报告。

**结果区看到什么**

- 检测：整改优先级排序（TOPSIS 健康度 + 主要问题实测/限值）、线索清单、
  **跨设备统计验证**（最差那台 vs 其余：Mann-Whitney/Welch + 效应量 + p 值）、
  相关线索（最强的一对，附「相关不等于因果」）
- 预测：每台一张卡，含结论、动作建议、关键数字、**回测误差与可用性判定**
  （误差 >15% 会明说「只能看趋势，不能拿具体数字做决策」）

#### ③a 三层分工（2026-11-07 定案）

```
仪表板部件（TB dashboard）   ← 业务界面，与告警/设备管理同一套做法
     │  /api/energy/model/*
guard-server（业务层）       ← 权限 / 场站 / 设备范围 / 问题台账
     │  device_ids + intent + params
spsspro（模型层）            ← 取数 → 判据 → 预测 → 统计 → 归因 → 建议
```

| 层 | 负责 | 不负责 |
| --- | --- | --- |
| 部件 | 展示、交互、场站切换 | 选设备、算指标 |
| Java | 权限、场站范围、设备清单、问题台账、定时任务入口 | 判据、算法、统计检验 |
| Python | 取数、判据检测、预测、统计、归因、建议 | 判断用户能不能看 |

> **为什么设备清单必须由 Java 传**：spsspro 用固定服务账号连平台，
> 能看到全部租户的设备。让它自己选设备，等于把「看哪些数据」的决定权
> 交给一个不知道用户是谁的服务。
>
> **为什么 Java 不重写算法**：判据表、AHP 权重、统计检验全在 Python。
> 搬一份等于两套代码要同步维护，而且 Java 侧没有建模能力，只是透传。

**Java 侧接口**

```
GET  /api/energy/model/topics?siteId=      专题清单 + 服务可用性
GET  /api/energy/model/topics/{id}/run     跑专题（同步，8~15 秒）
GET  /api/energy/model/meters?siteId=      设备清单（只显示，不计算）
GET  /api/energy/model/findings/overview   积压总览（待处理数/设备排行/复现率）
GET  /api/energy/model/findings            问题明细
POST /api/energy/model/findings/resolve    标记已处理（按 fingerprint）
GET  /api/energy/model/findings/by-site    场站维度对比
```

#### ③a2 问题台账：模型结论落成业务数据

**为什么必须落库**：模型返回的 `clues` 是一次运行的**瞬时结论**。不落库就查不出
「这台表连续三周报谐波超标」、算不出「本月发现多少问题、处理了几个」、
也无法判断「哪些问题反复出现」。运维换人后全靠口头交接。

表 `energy_analysis_finding`（业务库，随 PG 备份）：

```
tenant_id / customer_id / site_id / device_id / device_name
intent / metric / kind / severity / title / judgment / standard
fingerprint / evidence(JSON) / run_at / run_id / resolved_at
```

**问题指纹** = `设备 | 问题族 | 判据类型`，不含具体数值：

- 数值从 37.6% 变 37.8% **不算**新问题
- 一台表电压偏差三相都超 → **一个问题**（族 `voltage_dev` 自动合并），不是三个
- 电流不平衡与电压不平衡 → 两个问题（判据不同、整改动作不同）

> **问题族在哪定**：`spsspro/energyflow/discover.py` 的 `METRIC_FAMILY`，
> 模型层在每条线索里返回 `family` 字段，业务层直接用。
> Java 侧不要复制这份映射 —— 两边各写一份会出现「分析页说 7 个问题、台账说 4 个」。

**统计整合看到什么**

| 指标 | 含义 |
| --- | --- |
| 未处理问题数 | 按 fingerprint 去重，**不因运行次数翻倍** |
| 按设备排行 | 哪几台表问题最多（客户最想看的） |
| 按问题类型 | 主要是哪类问题（谐波 / 不平衡 / 功率因数…） |
| 复现率 | 出现 ≥3 次的「老问题」—— 说明整改没落地 |

**定时任务的结果怎么进台账**：`FindingSyncService` 每 5 分钟拉 spsspro 的
运行历史（`/jobs/{id}/runs`，带完整结果），按 `run_id` 去重后写入。
任务建的时候会在 spsspro 的 job 里写 `meta.tenant_id`（模型层原样存回，
不解析）—— 没有租户归属的记录落库后任何查询都查不到，等于制造垃圾数据。

#### ③a3 业务入口：菜单直接开到专题

三个专题共用一块看板「用能分析」，菜单靠 query 参数区分（2026-11-07）：

```
/dashboards/<用能分析看板id>?topic=load-forecast     负载预测
/dashboards/<用能分析看板id>?topic=power-quality     用能质量
/dashboards/<用能分析看板id>?topic=energy-advice      用能建议
```

| 菜单项 | 配置 |
| --- | --- |
| 负载预测 | `linkType=DASHBOARD` + `dashboardId`（老的独立看板，仍可用） |
| 用能建议 | `linkType=URL` + 上面带 `topic=energy-advice` 的地址，`openInNewTab=false` |
| 用能质量 | `linkType=URL` + 上面带 `topic=power-quality` 的地址，`openInNewTab=false` |
| 问题台账 | `linkType=DASHBOARD` + 问题台账看板 id |

> **`openInNewTab` 必须是 false**。以前这两个项是 `true`，所以每点一次就
> 弹一个新标签页，里面是 ngxai 的旧表单页 —— 客户报的就是这个。
>
> **菜单改完必须重启 `energy-server`**：`custom_menu` 有内存缓存，
> 直接 `UPDATE` 库后接口还会返回旧值（实测：重启前 `/api/customMenu`
> 仍返回 `/ngxai/biz/advice`，重启后变成新地址）。
>
> 菜单重建逻辑在 `EnergyMenuInstaller`，幂等判据是 `needsLegacyLinkUpgrade()` + `LEGACY_MENU_URLS`。
> 把旧 url 加进这个集合，存量客户启动时会自动重建菜单；
> 不要靠「菜单名改了没」这类代理判据（见 E45）。

#### ③b 定时任务：让分析持续跑

入口 **「分析任务」**（`/spsspro/jobs`）。三步向导第三步选「保存为定时任务」即可创建。

页面显示：调度器状态、启用数量、下次运行时间；每个任务一行，带
**上次结论摘要**与 **「结论有变化」标记**。

> **为什么要有「有变化」这个标记**：每天推一模一样的 5 条问题，
> 客户第三天就不看了。系统比对相邻两次的**结论指纹**（设备+指标+类型+严重度），
> 只有真的变了（新增/消失/严重度升级）才标记。数值从 37.6% 变 37.8% 不算变化。

- **立即运行**：同步执行并出结果，不用等下一次
- **暂停/启用**：开关即改 `enabled`，下次时间自动重算
- **详情**：配置 + 最近一次完整结果 + 历史记录（含每次是定时还是手动触发）

任务与历史存在 `/data/jobs.db`（SQLite，和 `spsspro-data` 卷一起备份）。
容器重启后任务定义不丢，到点继续跑。

> **调度器没跑起来会长什么样**：任务页顶部显示「调度器未运行」。
> 其余功能不受影响，只是不再自动执行 —— 这类静默失效必须能一眼看出来。

排查：

| 现象 | 原因 | 怎么办 |
| --- | --- | --- |
| 「调度器未运行」 | `/data` 不可写，SQLite 建库失败 | `docker logs energy-spsspro-backend \| grep 任务库` |
| 任务到点没执行 | 容器时钟/时区不对 | `docker exec energy-spsspro-backend date`，应显示北京时间 |
| 一直「尚无历史」 | `next_run_at` 是未来 | 详情里看下次时间；或点「立即运行」验证链路 |
| 上次状态「失败」 | 设备没数据 / 平台接口超时 | 详情看错误原文；失败也会推进下次时间，不会每 10 秒重试刷爆接口 |

#### ④ 归因结果怎么看

报告第五章的排序表：

```
#   设备              健康度   主要问题            实测     限值
1   三相质量-02 谐波超标   41.8%   电流谐波总畸变率    35.29    8.00
2   三相质量-03 三相不平衡  56.4%   电流不平衡度        53.56   10.00
...
6   三相质量-01 正常      93.8%   全部达标            —        —
```

- **健康度** = TOPSIS 相对贴近度，100% 表示各项都理想。
  它**不是一个分数**，不要拿它跨项目比较。
- **主要问题**只从**真的超标**的指标里选（严重度 ≥1），
  不会因为某个指标权重高就把它当主因。
- **占总扣分** 说明该问题在这台设备的所有问题里占多大比重。

> **方法边界（必须如实告诉客户）**：
> ① 权重来自专家判断（安全影响 > 经济影响 + 有无国标硬限值），
>    不是从数据里学出来的。换一套判断矩阵排序会变 —— 所以报告里把权重也列出来，接受质疑。
> ② 整改方向是**排查路径**，不是施工方案。同一个谐波超标，可能是变频器、
>    UPS 或 LED 驱动，必须现场实测才能定论。
> ③ 判断矩阵通过一致性检验（CR<0.1）才会被采用；不通过会退化为等权并在报告里标明。

#### ⑤ 常见问题

| 现象 | 原因 | 怎么办 |
| --- | --- | --- |
| `sim.py list` 说没有符合条件的表 | 没跑 43 脚本，或设备缺 `wiring=3P4W`（相制按 wiring 判，不回退到名字） | 重跑 `43-seed-quality-meters.mjs run`，再 `verify` 看属性 |
| 设备树里看不到这 6 台表 | 缺 `type1`/`type2`/`meterLevel`/`additionalInfo.siteId` 之一 | `43-seed-quality-meters.mjs verify` 逐个查；树上的空态提示会说是「没挂表」还是「被筛选掉了」 |
| 生成数据集报「没有遥测」 | 没灌数据，或时间范围太短 | `python3 sim.py backfill --days 7` |
| 页面顶部显示「模拟数据」 | spsspro 连不上平台，退回了内置模型 | 检查容器内 `TB_BASE`（应为 `http://energy-server:8090`，不是 127.0.0.1） |
| 数据集 ID 提示「不存在或已过期」 | 后端重启会清空内存会话 | 重新生成数据集（数据没丢，在库里） |
| 归因里某台表「全部达标」但线索里有它 | 线索是单指标判据，归因要求该指标严重度 ≥1 | 两者口径不同，以线索为准去复核 |


---

## 第 6 步　建租户

**为什么单独一步**：平台没有默认租户，系统管理员不能直接建客户（会 403）。

`you@example.com` / `'你的密码'` 用**第 5 步刚设的**系统管理员。

```bash
cd ~/energy-app
bash scripts/02-onboard.sh \
  --admin you@example.com --admin-pass '你的密码' \
  --tenant '某某集团' \
  --tenant-email tenant@example.com --tenant-pass '租户密码'
```

租户邮箱和密码自己想（**必填**，少了脚本会拒绝）。

**这一步会自动记下凭据**，写到 `~/energy-app/DEPLOY-CREDENTIALS.txt`（权限 600）：

```
租户管理员     tenant@example.com / 租户密码
租户名称       某某集团
```

第 7 步建客户时，`09-onboard-customer.sh` 会**自动从这里读**，不用再手传。
所以你现在不用抄任何东西。

**看到这个才算成功**（最后一行）：

```
✓ 全部验证通过
```

前面还应该有这几行：

```
✓ 能源参数字典：1 个
✓ 系统部件：7xx 个
✓ 四个维度根齐全
```

中间还会看到：

```
凭据已写入 /Users/xxx/energy-app/scripts/../DEPLOY-CREDENTIALS.txt（权限 600）
建客户时不用再手传 --tenant-email / --tenant-pass
```

验证段末尾还应有这两行（2026-11-07 新增）：

```
✓ 客户看板无占位符残留
```

> **为什么加这两行（2026-11-07 实测）**
>
> 本脚本会建一个演示客户并给他复制看板。看板模板里的实体引用是**母版占位符**
> （`00000000-…-05a1` 场站 / `d101~d104` 四个维度根），复制时由
> `substitutePlaceholders` 换成客户的真实 id。
>
> 替换只要有一项没命中，客户打开看板就会报错：部件拿着假 id 查实体，
> `GET /api/asset/<占位符>` 404、回退 `GET /api/device/<占位符>` 又 404，
> 页底挂一条「404: OK」红条 —— 实测客户「基础报表」点「按分组维度」就中招。
>
> 修它的入口是 `POST /api/energy/repair-init`（幂等）。
> `09-onboard-customer.sh` 早就调了它，但**首装走的这条脚本从来没调** ——
> 所以全新部署的演示客户必定带着这批占位符。已补：先调一次 `repair-init`，
> 再逐份检查客户看板，除 `11b7`（能源参数字典）/ `e1ec`（电能品种）
> 两个故意保留的租户级哨兵外，再出现 `00000000-…-xxxx` 就报错。
>
> 看到 `! 客户看板仍残留占位符：…` 就是没修干净，再跑一次
> `POST /api/energy/repair-init` 并看这一项是否转绿。详见 ⑨ 排障。

> **为什么需要这个文件（2026-11-04 实测）**
>
> `09-onboard-customer.sh` 建客户时必须用租户管理员身份（系统管理员直接建客户会被 TB 403）。
> 它默认去读 `../DEPLOY-CREDENTIALS.txt`，而原来**只有 `docker-98-rebuild.sh` 会写这个文件** ——
> 主线的 01/02 都不写。于是全新机器上跑到第 7 步直接失败：
> ```
> 读不到租户管理员凭据。要么在部署目录放 DEPLOY-CREDENTIALS.txt，
> 要么显式传：--tenant-email xxx@yyy.com --tenant-pass '密码'
> ```
> 客户必须手抄一遍密码才能往下走，抄错一个字符就建不出来。
> 已修：`02-onboard.sh` 建完租户后自动落盘。

---

## 第 7 步　建第一个客户

```bash
cd ~/energy-app
bash scripts/09-onboard-customer.sh \
  --email customer@example.com --password 'Cust@123456' \
  --name '某某厂区'
```

**不用传租户凭据** —— 第 6 步已经写进 `DEPLOY-CREDENTIALS.txt`，本脚本自动读。

它会：建客户 → 建客户管理员 → 铺演示数据 → 装菜单 → 复制看板 → 逐项验证。

**这一步会卡 60–120 秒**（要铺 33 天遥测），不是死了。

**看到这个才算成功**（最后一块）：

```
============================================================
  客户已开通
============================================================

 登录地址   http://127.0.0.1:8090
 账号       customer@example.com
 密码       Cust@123456
 客户名     某某厂区
 客户 ID    xxxxxxxx-xxxx-...
```

中间应该都是 `✓ 设备档案：N`、`✓ 落地页（菜单第一项是 home）` 这类逐项检查。
任何一行打 `✗`，脚本会停下来并报「有验证失败项」。

同时会在部署目录写 `ONBOARDED-<客户id>.txt`（权限 600）。

不对怎么办：

| 现象 | 怎么办 |
| --- | --- |
| `读不到租户管理员凭据` | 第 6 步没跑或没传 `--tenant-email`/`--tenant-pass`。回第 6 步，或手动补：`--tenant-email tenant@example.com --tenant-pass '租户密码'` |
| `timed out` | 客户其实建好了。等 1 分钟重跑同一条命令（幂等） |

---

## 第 7b 步　接入真实 RTU（现场演示必做）

**平台侧不需要任何操作。** 第 7 步建客户时已经把网关建成固件认的那一台：

| 项 | 值 | 谁定 |
| --- | --- | --- |
| 网关设备名 | `ED1-Gateway` | `rtu/main.py` 写死，平台侧跟着建 |
| 访问令牌 | 固件里那个固定值 | 平台侧主动设成它，**不是** TB 随机生成 |
| 下挂设备名 | `PowerMeter-DDSU666` / `Sensor-HZ8706` / `Relay-8CH` | 同上 |

所以 **不用重新烧录固件**。第 7 步的输出里会有一段核对卡，直接对照：

```
--- RTU 现场核对（与固件 rtu/main.py 的配置区对照）---
  网关名    : ED1-Gateway
  访问令牌  : <与固件 TB_TOKEN 相同>
  ★ 与固件 TB_TOKEN 一致 → 插入 RTU、配好网络即可上报，无需烧录
  下挂设备  : PowerMeter-DDSU666 / Sensor-HZ8706 / Relay-8CH
  平台地址  : 填本机局域网 IP（macOS: ipconfig getifaddr en0），不能填 127.0.0.1
  MQTT 端口 : 11883（不通会自动回退 1883）
```

### RTU 侧只改两组

打开 `rtu/main.py` 的配置区，**只动这两处**：

```python
# ① WiFi —— 改成现场的网络
WIFI_SSID = "现场WiFi名"
WIFI_PASS = "现场WiFi密码"

# ② 平台地址 —— 跑这套系统那台电脑的局域网 IP
TB_HOST = "192.168.1.50"        # 不能填 127.0.0.1，板子连不到
```

> **怎么查这台电脑的局域网 IP**：macOS `ipconfig getifaddr en0`，
> Linux `hostname -I | awk '{print $1}'`，Windows `ipconfig`。
> 必须与 RTU 连的是**同一个网段**（前三段相同）。

`TB_TOKEN`、`GATEWAY_NAME`、三个设备名**一概不要动** —— 平台侧已经对准了。

### ⚠️ 最常见的坑：Thonny 开着，板子就不上报

**症状**：板子通电、WiFi 也连上了、串口看着正常，但平台侧
`netstat | grep 1883` **0 条连接**，设备「从未上报」。

**原因**：Thonny 连接板子时带 `interrupt_on_connect` ——
一连上就按 Ctrl-C **中断正在运行的 `main.py`**。
你以为在看日志，其实程序已经停了。

**判据**：

```bash
pgrep -fl Thonny          # 有输出 = Thonny 开着
lsof /dev/cu.wchusbserial* # 有输出 = 串口被占
```

**处理**：**完全退出 Thonny**（`Cmd+Q`，不是关窗口），然后按 `RST` 或重新插拔 USB，
让板子重新跑 `main.py`。

> 要在 Thonny 里看日志也可以，但看完必须点「运行 ▶」把程序放回去，
> 否则拔掉 USB 后板子复位了才会重新跑。

### 改完 `main.py` 必须重新上传到板子

改电脑上的 `rtu/main.py` **不影响板子** —— 板子跑的是 flash 里的副本。
换电脑、换网段后 `TB_HOST` 变了，必须上传。

```bash
cd ~/energy-app

# ① 先看板子上现在是什么（只读，安全）
bash scripts/35-rtu-flash.sh --dry-run

#    输出会并排列出「板子上」与「本地」的 TB_HOST / 端口 / 网关名 / 令牌末四位。
#    两边不一致 —— 就是「改了没生效」。

# ② 上传（会重启板子）
bash scripts/35-rtu-flash.sh --serial /dev/cu.wchusbserial1410

# ③ 验证平台侧真的收到了
bash scripts/34-rtu-diagnose.sh --customer '某某厂区'
```

`35-rtu-flash.sh` 会推 `main.py` 与整个 `lib/`（`serial.py` / `functions.py` / `const.py`），
`lib/` 是 `from serial import Serial` 的依赖，漏了板子会报 `ImportError`。

> **只需装一次 mpremote**：`pip3 install --user mpremote`
> macOS 上装完在 `~/Library/Python/3.9/bin`，脚本会自动加进 PATH。

### 上电后按这个顺序看

1. **串口第一屏是「配置自检」**：WiFi 名、平台 IP、端口、令牌末四位、三个设备名。
   对着上面那张表核一遍，比事后猜快得多。
2. **WiFi 连上了**：串口打印 `WiFi OK  <IP>`。
3. **平台探活通过**：打印 `平台在线`。
4. **MQTT 连上了**：打印 `MQTT OK`（先试 11883，不通自动回退 1883）。
5. **开始上报**：每隔几秒打印 `电表 / 传感器 / 继电器` 的读数。

### 验证它在平台侧真的进来了

```bash
cd ~/energy-app

# ① 三台设备有遥测（把名字换成核对卡上的）
docker exec energy-postgres psql -U postgres -d thingsboard -tAc "
select d.name, count(*) from ts_kv k join device d on d.id=k.entity_id
 where d.name in ('PowerMeter-DDSU666','Sensor-HZ8706','Relay-8CH')
 group by d.name;"

# ② 浏览器里看：设备管理 → 设备运维 → 网关下应挂 11 台
#    综合能耗看板副标题应是「数据源（43 台） · 当前 25 台计量点」
```

### 对不上怎么查

| 串口现象 | 原因 | 处理 |
| --- | --- | --- |
| `WiFi 失败` | SSID/密码错，或路由器 5G-only | 改成 2.4G 频段；核对密码 |
| `平台不在线` | `TB_HOST` 填了 127.0.0.1 或不是同一网段 | 改成本机局域网 IP |
| `MQTT 认证失败` | 令牌不是固件里那个 | 平台侧重跑 `30-rtu-env-init.py`，看核对卡 |
| 串口正常但平台 0 连接 | **Thonny 挂着，把程序中断了** | 完全退出 Thonny，按 RST 复位 |
| 改了 `main.py` 没变化 | 只改了电脑上那份 | `35-rtu-flash.sh` 上传到板子 |
| `MQTT` 连上但设备不出现 | 设备名对不上（差一个字符也算） | 核对卡上的三个名字必须逐字一致 |
| 只有电表有数，传感器没有 | 传感器没接 / 地址不对（`SENSOR_ADDR`） | 查 485 接线 |

> **一个网关只能属于一个客户**（`credentials_id` 有唯一索引）。
> 平台上已经有别的客户占着 `ED1-Gateway` 时，新建客户会退回模拟网关，
> 输出里会有 `! ED1-Gateway 已属于客户 …` 的告警。
> 现场单客户演示不会遇到；多客户共存时真实 RTU 只能给其中一家。

### 演示时数据从哪来

| 数据 | 来源 | 说明 |
| --- | --- | --- |
| 正泰电表 / 温湿度 / 8路继电器 | **真实 RTU 上报** | 插上就有，随硬件实时变化 |
| 8 台 `*-SIM`（三相电、水、气、汽、热、空压、空开） | `31-rtu-simulate.py` 模拟 | 用来看多品种、多分项的效果 |
| 单相园 / 三相园 那 21–31 台 | 建客户时铺的历史遥测 | 看板曲线立刻有形，不用等数据攒 |

模拟数据要不要跑，看现场需不需要展示多品种：

```bash
cd ~/energy-app
nohup bash scripts/29-rtu-demo-up.sh --sim-only --customer '某某厂区' \
  --interval 30 > /tmp/rtu-sim.log 2>&1 &
# 停：pkill -f 31-rtu-simulate.py
```

> 模拟脚本会**跳过** `PowerMeter-DDSU666` 等真实设备（`REAL_DEVICES` 白名单），
> 不会用假数据覆盖真表读数。

---

## 第 8 步　登录验收

浏览器打开 `http://<这台机器的IP>:8090`，用**第 7 步的客户账号**登录。

**看到这个才算成功**：

1. 左侧是**业务菜单**（能耗概览 / 能耗查询 / 设备管理 / 电能质量…），不是 TB 原生那套（仪表板 / 告警 / 实体）
2. 点「设备管理 → 设备运维」：能看到设备卡片网格，顶部有 `设备管理 > 设备运维` 面包屑
3. 点「平台自检」：逐项通过

**只有本机能访问？** 云服务器或别的电脑打不开，是防火墙没放行：

```bash
# Ubuntu / Debian
sudo ufw allow 8090/tcp
# CentOS / RHEL
sudo firewall-cmd --add-port=8090/tcp --permanent && sudo firewall-cmd --reload
```

云服务器还要在控制台安全组放行 8090。放行方法见本页末尾「附录：出问题时查」的第一节。

---

## 装完了，收个尾

```bash
# 部署目录里的临时备份，留最近一份
cd ~/energy-app/data && ls -dt json.bak.* 2>/dev/null | tail -n +2 | xargs -r rm -rf
cd ~/energy-app && ls -dt scripts.bak.* 2>/dev/null | tail -n +2 | xargs -r rm -rf

# 旧 jar 备份，留一份
cd ~/energy-app && ls -t guard-server-4.4.0.jar.bak-* 2>/dev/null | tail -n +2 | xargs -r rm -v

# 旧发布包，留一个
cd <你的仓库目录> && ls -t dist/energy-deploy-*.tar.gz 2>/dev/null | tail -n +2 | xargs -r rm -v
```

**部署目录 `~/energy-app` 不要删** —— 以后升级、查日志、跑运维脚本都要用。

---

# 以下是维护场景，不是部署

上面 8 步做完就不用看了。下面三段是「以后要改东西」时用的。

## A　就地升级（已经装好，只想换版本）

不动数据、不动 `.env`，只换 jar 和物料。

```bash
# ① 在仓库里，把新物料同步进部署目录（会先备份）
cd <你的仓库目录>
bash shiyongshouce/downloads/scripts/32-check-deploy-sync.sh --app ~/energy-app --fix

# ② 打 jar（只改了 Java 就加 --skip-ui）
bash guard-server/pack.sh --skip-ui

# ③ 换 jar 重启
docker stop energy-server
cd ~/energy-app && mv guard-server-4.4.0.jar guard-server-4.4.0.jar.bak-$(date +%H%M)
cp <你的仓库目录>/guard-server/target/guard-server-4.4.0.jar ~/energy-app/
docker start energy-server

# ④ 等健康
for i in $(seq 1 50); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8090/ 2>/dev/null)
  [ "$code" = "200" ] && { echo "就绪（第 ${i} 次）"; break; }
  sleep 3
done
```

**判据**：打印 `就绪`；`docker logs energy-server --since 3m | grep -iE "ERROR|Exception"` 无输出。

## B　只改了部件 / 脚本（最轻，不用重启）

改了 `widget_types/*.json`、看板模板、运维脚本 —— **不用打 jar，不用重启**。

部件是运行时从数据库读的，跟 jar 无关。很多人改完部件就跑 `pack.sh`，白等 12 分钟。

```bash
cd <你的仓库目录>

# ① 文件同步进部署目录
bash shiyongshouce/downloads/scripts/32-check-deploy-sync.sh --app ~/energy-app --fix

# ② 部件 JSON 还要写进数据库（存量库的 widget_type 记录）
bash shiyongshouce/downloads/scripts/31-deploy-widget.sh --all
```

浏览器硬刷新即可。

两者分工：

| 脚本 | 干什么 | 写数据库 | 什么时候用 |
| --- | --- | --- | --- |
| `32-check-deploy-sync.sh --fix` | 三类文件比对 + 同步 | ✗ | 改了 json / sql / 脚本 |
| `31-deploy-widget.sh <名>` | 推库 + 同步挂载目录 | ✓ | 存量库改部件 |

> 两个都**必须从仓库跑**。从 `~/energy-app/scripts` 跑时，`32` 会拒绝（拿自己比自己永远报一致）。

## C　彻底重来（数据全不要了）

```bash
cd ~/energy-app
bash docker-99-uninstall.sh --purge --dry-run   # 先看会删什么
bash docker-99-uninstall.sh --purge --yes       # 真删
```

删容器 + 卷 + 网络 + 整个 `~/energy-app` 目录。**不可恢复。**

删完从本页最上面的**第 1 步**重新走。

> **删完立刻跑物料校验会报「目录不存在」—— 这是正常的**，不是错误。
> 说明这台机器现在是空的，直接从第 2 步（或第 3 步，jar 还在的话）开始。

---

# 附录：出问题时查

## 放行防火墙

容器端口映射只管**宿主机本机**。别的电脑访问、或云服务器，还要放行：

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

> macOS 本机不需要放行。但首次启动 Docker Desktop 会弹「是否允许接受传入网络连接」，
> **必须点允许**。误点了拒绝：系统设置 → 网络 → 防火墙 → 选项，把 Docker 加回来。

## 内存紧张：单容器模式

物理内存 < 10GB，把四个容器合成一个，省约 2GB：

```bash
cd ~/energy-app
bash docker-02-start.sh --allinone --admin-email ... --admin-pass ...
```

代价是「重启一个全部重启」。演示机、笔记本推荐；生产用默认四容器。

## 验收基线（装对了应该是什么样）

| 检查项 | 应有值 |
| --- | --- |
| 库表 | 150 上下（`SELECT count(*) FROM information_schema.tables WHERE table_schema='public'`） |
| 系统部件（install 后 DB 行数） | 740 上下 |
| 交付的部件文件 | 588 个 |
| 客户看板模板 | 30 个 |
| 建表 SQL | 8 个 |
| 能源参数字典 | 1 个资产，标准 key **137** 个（电能 122） |
| 演示客户 | 10 台设备（8 台可模拟） |

## 两个「等很久」是正常的

**① 建客户阻塞 60–120 秒** —— 同步铺场站、分项、二十多台设备、约一个月的遥测。
`09` 已把超时放宽到 600 秒。看到 `timed out` 说明客户其实建好了，等 1 分钟重跑（幂等）。

**② 首次 `install` 2–3 分钟** —— 建 150 上下张表 + 导入 740 上下个部件。机器慢会到 5 分钟。

## 先回答一个常被问的问题：干净重装能避免翻车吗

**不能。这是最容易被误解的一点，必须说清楚。**

| 问题类型 | 干净重装有用吗 | 为什么 |
| --- | --- | --- |
| 累积脏状态：多套前端产物叠在同一个 jar、旧 jar 没换、数据库残留旧配置 | **有用** | 这些是「越用越脏」，清空重建就没了 |
| **代码 bug**：部件管道缺失、`scope` 作用域、网关只查不建 | **没用** | 干净装上跑的还是同一份代码，一样翻车 |

实测例子：2026-11-04 修的「整页空白」是 `DecimalPipe` 没进动态组件作用域，
「没样式」是 Material 指令没进 imports —— 这两个在**全新安装的干净库里
百分之百复现**，因为它们是构建产物的问题，跟数据一点关系都没有。

**真正能防翻车的是三道机制，不是重装**：

```bash
# ① 构建前：部件依赖自检（586 个模板，缺管道/Material 直接退出码 1）
cd ui-ngx && node esbuild/check-widget-deps.mjs

# ② 部署前：jar 比前端产物旧就中止（防「只 build 前端没重打 jar」）
#    已内置在 docker-98-rebuild.sh

# ③ 装完：跑验收脚本，看实际渲染，不看退出码
bash scripts/08-verify-release.sh
```

> 结论：干净重装解决「脏」，不解决「错」。
> 每次改动后**按验收清单实际点一遍页面**，才是唯一的保险。

---

## 三个会让你翻车的坑

### 坑 1：只 `git pull` 不 build → 源码新的、界面旧的

`ui-ngx/target/` 在 `.gitignore` 里，**前端产物不进版本控制**。
pull 之后不跑 `pack.sh`，浏览器里就是上一次构建的界面。

**已经不用你记了**（2026-11-07 起）：`pack.sh` 第 1 步就是 `git fetch + pull` 并应用
部件/看板改动，第 5 步构建前端。直接跑：

```bash
bash guard-server/pack.sh            # 同步 → 前端 → 后端
bash guard-server/pack.sh --deploy   # 再加：拷 jar + 重启并等 healthy
```

**想知道产物新不新**：

```bash
node tools/check-ui-freshness.mjs    # 0 新鲜 / 1 过期 / 2 无产物
```

> **别看 mtime**。git 检出会把文件时间刷成「现在」，刚 pull 完但源码没变时，
> mtime 判据会报假警报；真正该报的「改了源码忘了重建」反而不一定报。
> 工具用 **ui-ngx 子树 hash**（`git rev-parse HEAD:ui-ngx`），只随内容变。

**⚙ `--skip-ui` 会被拦住**：产物与源码不一致时 `pack.sh` 直接报错退出，
不会默默把旧前端打进 jar。确实要复用（只改了 Java）：
`UI_ALLOW_STALE=1 bash guard-server/pack.sh --skip-ui`。

### 坑 1.2：两台机器开发，各自的产物是独立的

两台机器用 git 同步源码，但**下面这三样 git 同步不了**：

| 东西 | 在哪 | git 同步吗 |
| --- | --- | --- |
| 部件描述符 | 数据库 `widget_type.descriptor` | ❌ 仓库只存副本 |
| 看板配置 | 数据库 `dashboard.configuration` | ❌ 仓库只存模板 |
| 前端产物 | `ui-ngx/target/generated-resources/public` | ❌ 被 `target/` 忽略 |

于是：

```
机器 A：改部件/前端 → 构建 → push
机器 B：pull（源码新了）→ 打包 → jar 里是旧前端 + 库里是旧部件
```

**症状**：代码明明更新了，页面还是老样子；构建日志一切正常。

**现在一条命令自动处理**（`pack.sh` 第 1 步调 `tools/sync-from-git.mjs --apply`）：

1. `git fetch` + `pull --ff-only`
2. 把变动的**部件 / 看板 / spsspro 直接应用到运行环境**（秒级）
3. Java / 前端交给后面的构建步骤，不另外啰嗦

不阻断打包的情况（各打一行告警就继续）：
**离线**、**分支无上游**、**本地有未提交改动拉不动**（打断手里的活比装旧代码更糟）。

**只想看远端有没有新东西**（不拉、不推库）：

```bash
node tools/sync-from-git.mjs --check   # 0 最新 / 2 有更新（会列出该跑什么）
```

**前提**：两台机器都要把改动 **push 到同一个远端分支**，并各自设好上游：

```bash
git push -u origin master
```

### 坑 1.5：反复 `pack.sh` 会把多套前端叠进同一个 jar（新机器才暴露）

**这是 2026-11-04 新机器「页面空白 + 无效的部件 HTML 模板 + 按钮无样式」的真正的根因。**

`pom.xml` 用 `<resource>` 把 `ui-ngx/target/generated-resources/public`
拷进 `target/classes/public`，而 **Maven 只增/覆盖，从不删除上轮遗留**。
于是每跑一次 `pack.sh`，旧的那套前端就多积一层：

| | public/ 文件数 | 日期种类 | chunk 数 | 体积 |
| --- | --- | --- | --- | --- |
| 脏 jar（跑过多次） | 10268 | **8 个日期** | 156 | 576MB |
| 干净 jar（`mvn clean`） | 9066 | **1 个日期** | 88 | 424MB |

实测日期分布：8842 个 11-02 / 1298 个 11-03 / 61 个 10-29 / 24 个 11-01 …

**为什么致命**：`index.html` 只引最新那套（带 hash 文件名），
但 `assets/` 下的**同名**静态文件（字体、i18n、locale、图片）会被旧构建覆盖
→ CSS/JS 版本对不上 →

- 部件报「**无效的部件 HTML 模板**」（NG0 编译错误）
- 部分**样式丢失**（按钮没背景色、下拉框高度怪异）
- 部分**页面全白**，另一些正常（哪些坏取决于哪套文件被覆盖）

**开发机看不出来**（浏览器缓存着旧资源）；**新机器上必现**。

**三条命令判断**（干净 jar 应为 9066 / 1 / 88）：

```bash
JAR=~/energy-app/guard-server-4.4.0.jar
unzip -l $JAR | grep -cF "BOOT-INF/classes/public/"                        # ≈ 9066
unzip -l $JAR | grep -F "BOOT-INF/classes/public/" | awk '{print $2}' \
  | sort -u | wc -l                                                       # 必须是 1
unzip -l $JAR | grep -cE "public/chunk-[A-Z0-9]+[.]js$"                     # ≈ 88
```

或者直接跑 `bash scripts/33-check-widget-style.sh`，L1 会报红。

**修**（**不需要重建库，也不需要重新 install** —— 数据都在 PostgreSQL 里，jar 只是应用）：

```bash
# ── ① 在有源码的那台机器上，打干净 jar（会重建前端，约 12 分钟）
cd <仓库>
bash guard-server/pack.sh --clean

# ── ② 换 jar。只换这一个文件，data/ 与 .env 一律不动
docker stop energy-server
cd ~/energy-app
mv guard-server-4.4.0.jar guard-server-4.4.0.jar.bak-$(date +%H%M)
cp <仓库>/guard-server/target/guard-server-4.4.0.jar ~/energy-app/
docker start energy-server

# ── ③ 等就绪
for i in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8090/)
  [ "$code" = "200" ] && { echo "就绪（第 ${i} 次）"; break; }
  sleep 3
done
```

然后浏览器 **硬刷新**：`Cmd+Shift+R`（macOS）/ `Ctrl+F5`（Windows）。

**验证（两个都要绿）**：

```bash
cd ~/energy-app
bash scripts/33-check-widget-style.sh
```

```
L1  前端产物：production（带 hash），public/ 下 9066 个文件   ← 约 9066
    前端产物日期一致（单一构建，无叠加）                      ← 必须这句
    chunk 数正常（88 个）
L2/L3/L4 全 ✓
```

然后点这几个页面，都应正常（这是 2026-11-04 实测坏掉的那几个）：
综合能耗 · 能源流向 · 盘查报告 · 节能记录 · 组织

**! 三个绝对不要做的**（会让事情变得更糟）：

| 别做 | 为什么 |
| --- | --- |
| `docker-99-uninstall.sh --purge` | 连数据卷和整个部署目录一起删，客户数据全没 |
| `docker compose down -v` | `-v` 删卷 = 删库 |
| 重跑 `docker-01-install.sh` | 会报「库已有 N 张表」；它不会修前端问题 |

**还不行的话**，按顺序查：

| 现象 | 含义 | 处理 |
| --- | --- | --- |
| 33 的 L1 仍报「混了 N 个日期」 | `--clean` 没真清掉 `target` | `rm -rf guard-server/target/classes/public` 后重跑 `pack.sh --clean` |
| `pack.sh` 报错说找不到前端 | 新机器上没有 `ui-ngx/node_modules` | `cd ui-ngx && npm ci` 后再打（或直接拿发布包里的 jar） |
| L1 全绿但页面仍旧 | 浏览器缓存 | 开无痕窗口访问，对比一下 |
| 某几个页面仍空白 | 不是本条问题 | 跑 `33` 看 L2/L3，按输出处置 |

> 如果不想在新机器上构建（没 Node / 内存不够），
> 直接拿发布包里的 jar：
> ```bash
> tar -xzf energy-deploy-*.tar.gz -C /tmp energy-deploy/guard-server-4.4.0.jar
> docker stop energy-server
> cp /tmp/energy-deploy/guard-server-4.4.0.jar ~/energy-app/
> docker start energy-server
> ```

> `pack.sh` 已修（2026-11-04）：打包前自动 `rm -rf target/classes/public`，
> 并在产物校验里新增「多个日期 / chunk > 200」硬检测，命中就报红。
> 以后就算不加 `--clean` 也不会积脏。但**已经脏了的 jar 必须重打**。

### 坑 2：改了源码，忘了同步部署目录 → 物料旧

部署侧读 `~/energy-app/data`，源码改的是 `guard-server/src/main/data`。**不会自动同步。**

**判据**：`bash shiyongshouce/downloads/scripts/32-check-deploy-sync.sh --app ~/energy-app` 全绿。

**修**：加 `--fix`，或重新跑第 3 步（`docker-00-prepare.sh --force`）。

### 坑 3：新机器用了旧脚本 → 静默退出

旧版 `docker-02-start.sh` 里是 `CODE=$(curl ...)`，而脚本有 `set -euo pipefail`。
新机器上服务刚起来、curl 连不上时**赋值语句整体非零 → 脚本静默退出**，
只看到「服务已就绪」然后就没了，管理员没建成。

**判据**：`grep -c 'CODE="000"' ~/energy-app/docker-02-start.sh` 必须 ≥ 1。

**修**：`32-check-deploy-sync.sh --fix`（把新脚本同步过去）。

## 两台电脑同时改同一个仓库

**日常只需要这一条命令**（已实测跑通，9 分 43 秒）：

```bash
bash guard-server/pack.sh --deploy
```

它依次做：`git fetch + pull --ff-only` → 把变动的**部件/看板**直接推入库
（秒级）→ 构建前端 → 打包后端 → 拷 jar 到 `~/energy-app` → 重启并等 healthy。
**不用手跑 31/32/26/36 任何脚本。**

| 场景 | 命令 | 耗时 |
| --- | --- | --- |
| 日常更新（含 Java / 前端改动） | `bash guard-server/pack.sh --deploy` | ~10 分钟 |
| 只同步部件/看板（不改 Java/前端） | `node tools/sync-from-git.mjs` | 秒级 |
| 只改了 Java | `bash guard-server/pack.sh --skip-ui --deploy` | ~5 分钟 |
| 先看远端有没有新东西 | `node tools/sync-from-git.mjs --check` | 秒级 |
| 只看三段链路一致不一致 | `node tools/verify-deploy.mjs` | ~10 秒 |

> `--skip-ui` 需要前端产物有构建印记（`pack.sh` 构建时会写）。
> 产物来源不可考时它直接拒绝——这是故意的，防止把旧前端打进 jar。

`git pull --rebase --autostash` 会把未提交改动临时 stash 起来，
**冲突时静默留在 `stash@{0}`**，工作区看起来「变回旧版」。

```bash
git stash list
git stash show -p stash@{0} | head -40
```

但**大多数「代码变旧了」不是这个原因**，按这个顺序查：

1. 这一屏由谁渲染？菜单 `linkType` 是 `DASHBOARD`（部件）还是 `URL`（Angular 路由）
2. 前端产物时间 vs `ui-ngx/src` 时间（坑 1）
3. `32-check-deploy-sync.sh` 是否全绿（坑 2）
4. 最后才怀疑 git：`git reflog` / `git stash list` / `git fsck --lost-found`

### ★ 母版模板被本机运行态污染（2026-11-07 实测）

两台机器开发最容易出的一类错：**把本机数据库里的真实 id 提交进母版模板**。

模板（`guard-server/src/main/data/json/tenant/dashboards/*.json`）里的
实体引用**必须是占位符**（`00000000-0000-0000-0000-00000000xxxx`），
复制给客户时由 `substitutePlaceholders` 换成客户自己的实体。
写死真实 id 会：

- 换一台机器部署 → 指向不存在的实体 → 部件 404、整页空
- 新建客户复制模板 → 直接指向**别的客户**的实体
- 真实 id 一旦被删（清演示数据）→ 模板永久坏死

实测本机发现 2 个：`audit_report.json`（盘查报告）与 `sankey_flow.json`（能源流向）
的「场站」别名指向 `c49164e0-…`（本机「总部·演示厂区A」组织），
引入提交 `7cb4c4d1`。

**一分钟查完全库模板**（应该一条都不输出）：

```bash
cd <仓库>
python3 - <<'PY'
import json, glob, os, re
D = 'guard-server/src/main/data/json/tenant/dashboards'
PAT = re.compile(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')
PH  = re.compile(r'^00000000-0000-0000-0000-00000000[0-9a-f]{4}$')
bad = []
def walk(o, path):
    if isinstance(o, dict):
        for k, v in o.items(): walk(v, path + '.' + k)
    elif isinstance(o, list):
        for i, v in enumerate(o): walk(v, path + '[%d]' % i)
    elif isinstance(o, str):
        if '.entityAliases.' in path and (path.endswith('.singleEntity.id')
                or '.entityList[' in path):
            if PAT.match(o) and not PH.match(o): bad.append((path, o))
for p in sorted(glob.glob(D + '/*.json')):
    d = json.load(open(p, encoding='utf-8'))
    c = d.get('configuration') or d
    if isinstance(c, str): c = json.loads(c)
    walk(c, os.path.basename(p))
for b in bad: print('  ✗', b[0], b[1])
print('  ✓ 全部是占位符' if not bad else '  ↑ 上面这些要改成占位符')
PY
```

占位符对照（`EnergyBootstrapInstaller` 的常量）：

| 后缀 | 含义 | 谁用 |
| --- | --- | --- |
| `…05a1` | 第一个场站（单相园区） | 单场站看板 |
| `…05a2` | 客户组织（全部场站） | 综合能耗 / 能耗洞察 / 能源流向 / 电能质量 / 盘查报告 |
| `…11b7` | 能源参数字典（租户级） | 保持占位，**故意不替换** |
| `…17e0` | 用电分项根 | 分项类看板 |
| `…d101`~`d104` | 四个维度根 | 「按分组维度」 |

> **为什么 `…11b7` / `…e1ec` 不替换**：它们指向**租户级**资产，
> 客户直接读会 403。部件取品种走 `/api/energy/metric-params`，
> 不依赖这两个实体。（详见 ⑨ 排障）

**顺手会发现的另一类：模板在源码里根本不存在**

实测 `energy_overview.json` 的 title 是「综合能耗」，与 `composite_energy.json` 撞名；
而真正的「能耗概览」（客户菜单首页落地页，8 个部件）**只在库里**——
它是 `nenghaobao/tools/apply-energy-overview.mjs` 生成的，不入 git。
后果：

- `26-sync-dashboard-templates.py` 按 title 匹配 → 源码那份会把
  「综合能耗」模板覆盖成 8 部件版（串台）
- 全新部署后首页看板从哪里来，源码里查不到

已从库导出完整母版写回源码（title/name = 能耗概览）。

**三方比对口诀**（发现「某页与另一台机器不一样」时先做这个）：

```bash
node tools/verify-deploy.mjs        # 源码 / 库 / 部署物料 三段链路
```

它会把「库中缺失 / 内容不同 / 部署物料缺失」分开报。
出现偏差时按这个顺序定方向：

1. 先看 git 历史确认源码是新的还是旧的（`git log -1 -- <文件>`）
2. 再 `diff` 库与部署物料：如果两者相同而源码不同，**源码才是真相**
   （说明运行态被改过）；如果部署物料单独不同，是物料漂移（跑 `32 --fix`）
3. **绝不要**用旧源码覆盖新库 —— 那会把另一台机器刚加的功能抹掉

## 推送手册被拒（`! [rejected] main -> main (fetch first)`）

不是权限问题，不是网络问题。含义：**远端有你本地没有的提交。**

```bash
cd /Users/<你>/Documents/workspace/guard_help
git fetch origin
git log --oneline HEAD..origin/main      # 远端有、你没有

git pull --rebase origin main            # 拉平（保留你的提交）
git push origin main
```

冲突了（`UU` 标记）**不要直接 `--ours/--theirs`**，先判断能不能丢内容：

```bash
git merge-base <远端提交> <你的提交>
git diff <远端提交> <你的提交> -- <冲突文件> | grep '^-'
#   ↑ 输出为空 = 你的版本已包含远端全部内容，取你的版本安全

git show <你的提交>:<冲突文件> > <冲突文件>
git add <冲突文件> && git rebase --continue
```

**预防**：开推之前先拉一次 —— `git pull --rebase origin main && git push origin main`

## 附录：两个只在干净库才暴露的坑

### ① install 报 `No qualifying bean of type ...IdleEnergyService`

只在**全新空库**出现。原因是 `@PostConstruct` 早于 bean 就绪。

**修**：已在 2026-10-29 修（`EnergyBootstrapInstaller` 改为懒加载）。若仍遇到，说明用了旧 jar。

### ② install 报 `NoSuchFileException: /opt/energy/data/sql/schema-entities.sql`

`schema-entities.sql` 不在部署目录的 `data/sql/` 下。

**原因**：`docker-00-prepare.sh` 漏拷，或手工拼的部署目录。

**修**：重跑第 3 步。验：`ls ~/energy-app/data/sql/*.sql | wc -l` 必须是 8。

---

## 一页速查

```bash
# ── 部署（8 步）──────────────────────────────
cd <仓库>
bash guard-server/pack.sh                                       # 2. 打 jar（12 分钟）
bash shiyongshouce/downloads/deploy/docker-00-prepare.sh        # 3. 组装（记下 DB 密码）
cd ~/energy-app
bash docker-01-install.sh                                       # 4. 建库
bash docker-02-start.sh --admin-email you@x.com --admin-pass '密码'   # 5. 启动
bash scripts/02-onboard.sh --admin you@x.com --admin-pass '密码' \
     --tenant '某某集团' --tenant-email t@x.com --tenant-pass '密码'  # 6. 建租户（必填，会写凭据文件）
bash scripts/09-onboard-customer.sh --email c@x.com --password '密码' \
     --name '某某厂区'                                              # 7. 建客户（凭据自动读）
# 8. 浏览器 http://<IP>:8090 用客户账号登录

# ── 装到另一台机器 ────────────────────────────
# 第 3 步改成 --pack，然后 scp 过去解压，其余相同

# ── 只改部件 / 脚本（不用打 jar）──────────────
bash shiyongshouce/downloads/scripts/32-check-deploy-sync.sh --app ~/energy-app --fix
bash shiyongshouce/downloads/scripts/31-deploy-widget.sh --all

# ── 唯一一个「一切正常」的信号（部署目录存在时）──
bash shiyongshouce/downloads/scripts/32-check-deploy-sync.sh --app ~/energy-app
# → ✓ 部署物料与源码一致，可以 install / 打包
```
