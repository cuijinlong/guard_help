# RTU 演示环境（双网关 · 全品种 · 电能质量）

> 演示现场只有一块 RTU（一台真实单相电表 + 一个温湿度 + 一路继电器），
> 但客户想看的是**整套系统**：三相电能质量、水、燃气、蒸汽、热力、可控设备。
> 这一页给你一套**可重复执行**的脚本，装完新电脑一键就能把演示环境准备好。
>
> **不碰 Java 代码** —— 全部走 REST，改一行重跑几秒。改 Java 要重新打包 + 重启，
> 一次 10 分钟起步，演示前一天晚上改错一行就完蛋了。

---

## 一、脚本与完整部署链路

都在 `scripts/` 下，与平台部署脚本同目录。

### ⚠️ 先弄清楚：`29` 不是从裸库开始的第一步

| 顺序 | 脚本 | 干什么 |
| --- | --- | --- |
| ① | `01-install.sh` | 建库表（122 张）+ 装系统资源（743 个部件）+ 建系统管理员 |
| ② | `02-onboard.sh` | 建租户 + 租户管理员（`tenant@126.com`） |
| ③ | **`29-rtu-demo-up.sh`** | **一键：客户 / 场站 / 设备 / 数据 / 汇总** |

裸库直接跑 `29` 会卡在「租户管理员登录」—— 账号还没建。

### 三个脚本的分工

| 脚本 | 干什么 | 什么时候跑 |
| --- | --- | --- |
| `29-rtu-demo-up.sh` | **一键编排**：探活 → 登录 → 品种库 → 客户 → 维度 → 设备 → 回填 30 天 → 重算汇总 | 新电脑部署完，跑**一条**就够 |
| `30-rtu-env-init.py` | 只建/补齐数据（客户、场站、档案、设备、测点、RPC、归属关系） | 改了设备或关系后重跑 |
| `31-rtu-simulate.py` | 只发数据（持续上报 / 回填历史） | 演示期间常驻 |

```bash
cd <部署目录>

# 一键（推荐）：初始化 + 回填 30 天 + 重算汇总
bash scripts/29-rtu-demo-up.sh

# 只初始化（不改数据）
python3 scripts/30-rtu-env-init.py --prune

# 只发数据
python3 scripts/31-rtu-simulate.py --interval 30
```

### 29 的常用参数

| 参数 | 作用 |
| --- | --- |
| `--customer "客户名"` | 给指定客户初始化（默认「平台演示中心」） |
| `--backfill-days N` | 回填最近 N 天历史，默认 **30**（综合能耗默认窗口就是近 30 天） |
| `--backfill-days 0` | 不回填（真实 RTU 现场用过，不想造假历史） |
| `--sim-only` | 只跑持续上报，不碰数据 |
| `--check` | 只体检（dry-run），不改数据 |
| `--interval N` | 持续上报间隔秒数，默认 30 |

> **为什么默认回填 30 天**：只发一轮实时数据的话，7 天窗口里只有 1 个点，
> 客户打开看板看到的是「0.59 kW·h + 一条平线」，演示效果等同于没数据。

### 首次部署要等一会儿（正常现象）

新建客户时，后端会在**同一个请求里同步**跑完整套演示数据初始化
（4 个维度根 / 2 个场站 / 12 个分项 / 21 台设备 / 一批遥测 + 费率），
实测 **60~120 秒**。这段时间里其他请求会排队，属正常现象。

- `29` 已把这个请求的超时放宽到 600 秒
- 如果仍然看到 `timed out`：客户其实建好了，等 1 分钟重跑 `29` 即可（幂等）
- `29` 遇到失败会**立即停下**（不会假装跑完）—— 按提示排查

`--prune` 会删掉白名单以外的设备。**演示环境建议始终带上**，原因见第五节。

---

## 二、建出来的拓扑

```
单相园区·平台演示中心（办公园区）
└─ ED1-Gateway          真实 RTU（HaaS506-ED1 板子）
   ├─ PowerMeter-DDSU666   单相电表（正泰 DDSU666，真实）      → 插座分项 · 公共区域
   ├─ Sensor-HZ8706        温湿度传感器（真实，env）           → 公共区域
   └─ Relay-8CH            8 路继电器（真实）            ← 可控 → A栋办公区
   ＋ PowerMeter-1P-SIM    单相模拟表（照明总表）              → 照明分项 · 公共区域
   ＋ WaterMeter-SIM       水表（模拟）                        → 给排水分项 · 公共区域
   ＋ GasMeter-SIM         燃气表（模拟）                      → 炊事分项 · 食堂区域

三相园区·平台演示中心（生产园区）
└─ ED2-Gateway          模拟（脚本发数据）
   ├─ PowerMeter-3P-SIM    三相电表 3P4W  ← 电能质量全场景    → 生产车间区域
   ├─ SteamMeter-SIM       蒸汽表                              → 蒸汽分项 · 锅炉房
   ├─ HeatMeter-SIM        热力表                              → 锅炉分项 · 锅炉房
   ├─ AHU-SIM              新风机组（env）              ← 可控 → 办公区
   └─ Breaker-SIM          智能空开（带计量）            ← 可控 → 动力分项 · 生产车间
```

**真实设备与模拟设备分属两个网关、两个场站** —— 客户看到的两个园区都有数据，
而不是「一个满一个空」。

> 一块 RTU 板子只能当一个网关（`main.py` 里的 `GATEWAY_NAME` 写死一个）。
> 第二个网关的模拟数据由 `31-rtu-simulate.py` 在服务器侧发出，不需要第二块板子。

### ⚠ 归属关系是看板能出数的前提

设备上写 `additionalInfo.siteId` **只够归档，不够出数**。三个能耗看板都靠**关系**遍历：

| 关系 | 用途 |
| --- | --- |
| 场站 `--SiteContains-->` 设备 | 「设备属于哪个场站」的**唯一**依据 |
| 区域 / 分项 `--Contains-->` 设备 | 区域能耗 / 分项能耗按节点取数 |
| 网关 `--Contains-->` 设备 | 设备树、RPC 路由 |

`30-rtu-env-init.py` 的 **第 ⑩ 步**会把这三类关系全部补齐，**并清掉不属于当前映射的旧边**
（历史演示数据给同一台表挂过两个区域，会双算）。所以：

- 任何时候只要改了设备、场站、区域/分项，**重跑一次 `30-` 脚本**即可，不用碰 Java
- 跑完必须 `POST /api/energy/asset-totals/rebuild`，否则资产上的 `energy_total` 还是旧值

---

## 三、电能质量覆盖了什么

三相模拟表（`PowerMeter-3P-SIM`）的 49 个测点按国标参数布局：

| 场景 | 遥测键 | 国标限值 | 脚本生成范围 |
| --- | --- | --- | --- |
| 三相电压趋势 | `voltage_a/b/c`、`voltage_avg` | 220V ±7%（204.6~235.4） | 218~229 V |
| 电压偏差 | `voltage_deviation_a/b/c` | ±7% | −3%~+4% |
| 频率偏差 | `frequency`、`frequency_deviation` | 50 ± 0.2 Hz | 49.95~50.05 |
| 三相不平衡 | `voltage_unbalance`、`current_unbalance` | ≤ 2% | ≤ 1.2% |
| 序分量 | `voltage_seq_positive/negative/zero`、`current_seq_*` | —— | 负序 ≈ 不平衡×0.6 |
| 谐波畸变 | `voltage_thd_a/b/c`、`current_thd_a/b/c` | 电压 ≤ 5% | 1.2~3.8% |
| 分次谐波 | `voltage_harmonic_3/5/7/9/11/13`、`current_harmonic_*` | 国标分次限值 | 按次数递减 |
| 电压闪变 | `flicker_pinst`、`flicker_pst`、`flicker_plt` | Pst ≤ 1.0，Plt ≤ 0.8 | 0.15~0.95 |

**全部按国标范围内的合理值生成**，不是随机乱数 —— 电能质量看板的越限判定
（超阈值标红）不会被无意义的假数据误触发。

---

## 四、远程控制（RPC）命令

可控设备在平台上有 `rpcCommands` 属性，记着它能接受哪些指令。
真实设备由 RTU 执行，模拟设备由脚本记录（不改变实际状态）。

### Relay-8CH（真实，8 路继电器）

| 方法 | 参数 | 说明 |
| --- | --- | --- |
| `setRelay` | `{"ch": 1..8, "state": true/false}` | 单路开关 |
| `setGroupRelay` | `{"chs": [1,2,3], "state": true/false}` | 多路同开同关 |
| `setAllRelay` | `{"state": true/false}` | 全部开关 |
| `readMeterNow` | `{}` | 立即抄表（触发一次采集并上报） |

### AHU-SIM（模拟，新风机组）

| 方法 | 参数 | 说明 |
| --- | --- | --- |
| `setMode` | `{"mode": "auto/manual/off"}` | 运行模式 |
| `setFanSpeed` | `{"freq": 0..50}` | 风机频率 Hz |

### Breaker-SIM（模拟，智能空开）

| 方法 | 参数 | 说明 |
| --- | --- | --- |
| `setState` | `{"state": true/false}` | 合闸 / 分闸 |
| `getState` | `{}` | 读当前状态 |

### 怎么从平台下发

设备详情页 → **RPC** 面板 → 选方法、填参数。或命令行：

```bash
TOKEN=<租户管理员 token>
DEVICE=<设备 id>

curl -X POST "http://127.0.0.1:8090/api/rpc/oneway/$DEVICE" \
  -H "X-Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"method":"setRelay","params":{"ch":1,"state":true},"timeout":10000}'
```

要同步拿回复用 `/api/rpc/twoway/$DEVICE`（`setRelay` / `getState` 有返回值）。

> **真实继电器的前提**：板上 `main.py` 的 `ENABLE_RELAY = True`，且 RS485 接好。
> 命令走 `v1/gateway/rpc` 到板子，由 `dispatch_rpc` 执行。

---

## 五、`repair-init` 会重建演示设备（务必知道）

`POST /api/energy/repair-init` 里的 `repairHvacModule` 会**无条件**为每个客户
重建 10 台空调/环境演示设备（A栋新风机组、锅炉、热水泵、室内环境…）。

对刚装好、要初始化字典的库这是好事；但对 RTU 演示环境是噪音 ——
客户看到一堆没有数据源的设备，会以为系统坏了。

**所以：演示前跑过一次 `--prune` 清掉它们；之后不要再点「一键修复初始化」。**

如果误点了，重跑即可：

```bash
python3 scripts/30-rtu-env-init.py --prune
```

---

## 六、验证数据真的在动

```bash
# 每台设备最近的写入时间与键数
docker exec energy-postgres psql -U postgres -d thingsboard -c "
SELECT d.name, count(*) AS keys,
       to_char(to_timestamp(max(kv.ts)/1000),'HH24:MI:SS') AS last
FROM ts_kv kv JOIN device d ON d.id=kv.entity_id
WHERE d.name LIKE '%-SIM' GROUP BY d.name ORDER BY d.name;"
```

好的输出长这样（键数固定，时间一直在走）：

```
 AHU-SIM            |    8 | 15:42:45
 Breaker-SIM        |    6 | 15:42:45
 PowerMeter-3P-SIM  |   52 | 15:42:46
 WaterMeter-SIM     |    6 | 15:42:45
```

再验一层：抄表能不能读出台底。

```bash
curl -X POST "http://127.0.0.1:8090/api/energy/meter-reading/run" \
  -H "X-Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"deviceIds":["<PowerMeter-3P-SIM 的 id>"],"period":"day"}'
```

期望 `state: normal`，`metrics` 里带着 `energy_reading` 与各项电能质量。

---

## 七、新电脑部署清单

按顺序，一步都别跳。**下面的顺序是 2026-11-02 在干净库上完整跑过一遍的**。

```bash
# ① 建表 + 装系统资源 + 建系统管理员（约 2-3 分钟）
bash scripts/01-install.sh \
  --admin-email langmen@126.com --admin-pass '******'

# ② 建租户 + 租户管理员（这是 29 能不能跑的前提）
bash scripts/02-onboard.sh \
  --admin langmen@126.com --admin-pass '******' \
  --tenant '星河能源集团' \
  --tenant-email tenant@126.com --tenant-pass ********

# ③ 一键：客户 / 场站 / 设备 / 回填 30 天 / 重算汇总（约 6 分钟）
bash scripts/29-rtu-demo-up.sh

# ④ 演示期间常驻：持续上报（Ctrl-C 停）
bash scripts/29-rtu-demo-up.sh --sim-only

# ⑤ RTU 烧录 main.py（真实设备接进来）
#    WiFi / 平台地址 / 网关令牌 三处按新环境改
```

### 验收基线（实测数字，对不上就是没装对）

| 检查项 | 应有值 |
| --- | --- |
| 库表 | 122 张 |
| 系统部件（install 后 DB 行数） | 743 个 |
| 交付的部件文件 | 583 个 |
| 能源参数字典 | 1 个资产，标准 key **125** 个 |
| 能耗管理部件 | 39 个 |
| 演示客户 | 「平台演示中心」，10 台设备（其中 8 台可模拟） |
| 归属关系 | 场站 10 条 `SiteContains`，区域/分项按拓扑挂好 |
| 客户看得见的计量点 | 综合能耗页显示「当前 **8** 台计量点」 |

验证 SQL 见《数据校验 SQL》手册。

### 换电脑前必须检查部署物料

干净库 install 读的是 **`<部署目录>/data/`**，不是源码目录。
源码改了不同步过去，新库装进去的就是旧部件（实测事故：
综合能耗少了场站下拉、只剩 3 台计量点）。

```bash
# 拷贝到新电脑前跑一次，必须回「一致」
bash scripts/32-check-deploy-sync.sh --app <新部署目录>
bash scripts/32-check-deploy-sync.sh --app <新部署目录> --fix   # 有差异时同步
```

**换网段时改什么**：`rtu/main.py` 顶部的 `WIFI_SSID` / `WIFI_PASS` /
`TB_HOST`。其余不用动。

---

## 八、常见问题

| 现象 | 原因 | 怎么办 |
| --- | --- | --- |
| 脚本报「找不到客户」 | 客户名不叫「平台演示中心」 | `--customer` 参数改掉 |
| 模拟设备测点是 0 条 | 属性写成字符串了（TB 存到 `str_v`，平台读 `json_v`） | 用脚本建，别手工 POST |
| 看板 `energy_total` 是 0 | 数据还不够一天，汇总窗口从昨天 00:00 起 | 让模拟器跑够一晚，或手工调 `/api/energy/asset-totals/rebuild` |
| 抄表判 `abnormal` | 表底不单调（被两个源同时写） | 确认模拟器没碰 `PowerMeter-DDSU666` |
| 又冒出一批 A栋/锅炉设备 | 跑了「一键修复初始化」 | `30-rtu-env-init.py --prune` |
| RTU 连不上 | 5GHz/2.4GHz 双频问题，或路由器防蹭网 | 关双频合一；关防蹭网；看板子串口的探活日志 |
| `29` 卡在「租户管理员登录」 | 裸库没跑 02，账号不存在 | 先跑 `01-install.sh` + `02-onboard.sh` |
| `29` 报 `POST /api/customer → 0 TimeoutError` | 后端在同步建演示数据（ 60~120s） | 等 1 分钟重跑；客户已建好了，幂等 |
| 新库看板少了场站下拉 / 只剩 3 台计量点 | 部署目录 `data/` 是旧部件 | `32-check-deploy-sync.sh --fix` 后重建库 |
| install 报 `NoSuchFileException: schema-entities.sql` | 部署侧 `data/sql` 被 `rsync --delete` 删了 | 从源码 `guard-server/src/main/data/sql` 实体复制过去 |
| 分项能耗选电能是空的 | 水/气/汽/热分项本来就不写 `energy_total` | 切到对应品种；这是正确行为 |
| 分项里出现 31272 kW·h 这种天文数字 | 设备把开关次数写进了 `energy` 键 | 检查测点映射，见铁律 E32 ② |
| 真实电表读数突然是 7777.7 / 8888.8 | 调试期哨兵值，差分后会把汇总炸飞 | 删掉后重算汇总，SQL 见《数据校验 SQL》§6.3 |
