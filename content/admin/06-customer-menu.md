# 客户菜单功能专区（架构 · 统计 SQL · AI 算法）

这一页是给**运维和客户对接人**用的：客户登录后左侧每一个菜单，点进去看到的数字
从哪来、存在哪张表、用什么 SQL 能自己核对一遍。

> **为什么不写在客户手册里**：客户只需要看数，不需要知道 `ts_kv` 长什么样。
> 但客户对账时一定会问「你这个 1588.31 是怎么算的」—— 这一页就是答案。

---

## 一、左侧菜单全貌（14 项）

```
客户登录（customer@…）
│
├─ 能耗概览            ← 落地页，登录即见（HomeMenuItem，指向「能耗概览」看板）
│
├─ 能耗查询
│   ├─ 实时能耗        看板：realtime_energy
│   ├─ 历史能耗        看板：history_energy
│   └─ 抄表功能        页面：/meter-reading（抄表台账 + 记录 + 现场补抄）
│
├─ 能耗分析
│   ├─ 峰谷分析        看板：energy_management_analysis_bar + /api/energy/tou-analysis
│   ├─ 分项能耗        看板：item_energy
│   ├─ 区域能耗        看板：area_energy
│   └─ 我的账单        看板：energy_management_billing_list + /api/energy/billing/*
│
├─ 综合报表
│   ├─ 基础报表        看板：basic_report
│   ├─ 手工填报        页面：手工填报（虚拟表月度录入）
│   └─ 参数报表        页面：/param-report（品种 × 指标字典）
│
├─ 能耗优化
│   ├─ 闲时能耗        页面 + /api/energy/idle-analysis
│   ├─ 负载预测  【AI】 /ngxapi/biz/forecast      Prophet
│   ├─ 用能建议  【AI】 /ngxapi/biz/advice        规则引擎（非机器学习）
│   └─ 用能质量  【AI】 /ngxapi/biz/quality       规则 + 统计（非机器学习）
│
├─ 告警中心            /alarm-center + /api/energy/alarms
│
├─ 设备管理
│   ├─ 设备运维        /device-management（设备列表 + 测点参数）
│   ├─ 设备分组        /device-group（分组树 + 设备归属）
│   └─ 设备拓扑        /device-topology + /api/energy/topologies
│
├─ 平台自检            /self-check + /api/energy/self-check
│
├─ 综合能耗            看板：energy_overview
├─ 能源流向            看板：energy_management_sankey_flow
├─ 电能质量            看板：energy_management_power_quality
├─ 盘查报告            看板：energy_management_audit_report
├─ 节能记录            看板：energy_management_saving_records
└─ 组织                /sites（组织 → 场站 → 设备 三级）
```

> **2026-10-26 改名**：原来一级叫「设备运维」，它下面第一项又叫「设备管理」——
> 两个词互为父子，客户点之前分不清哪个是哪个。
> 现在一级用上位概念「设备管理」，三个二级项用各自的动作：
> **设备运维**（看设备状态与测点）/ **设备分组**（给设备归类）/ **设备拓扑**（看接线）。
> URL 全部不变；「平台自检」升为一级（出问题时第一个该点的地方）。
> 存量客户重启不会自动变，走一次「平台自检 → 一键修复初始化」即可（幂等）。

**四种页面类型**，排查时先分清是哪一种：

| 类型 | 特征 | 数据从哪来 |
| --- | --- | --- |
| ThingsBoard 看板 | URL 里是 `/dashboards/<id>` | 部件直接查 `ts_kv`（前端发查询，后端只做聚合） |
| 自建页面 | 供应商自己的路由（`/meter-reading` 等） | 调 guard-server 的 `/api/energy/*` |
| AI 页面 | 走 `ngx-ai` 服务（18081/18801 端口） | Python 服务读同一份 `ts_kv` 或 tb_rest |
| 静态清单页 | `/self-check`、`/param-report` | 读字典/元数据，不算电量 |

---

## 二、数据存哪（先看这张，再看各功能）

### 2.1 遥测：`ts_kv` 一张表装全部

```text
表结构（分区表，按 ts 范围切分区）
entity_id  uuid     -- 设备/资产 id
key        integer  -- ★ 不是键名，是 key_dictionary.key_id
ts         bigint   -- 毫秒时间戳
bool_v / str_v / long_v / dbl_v / json_v   -- 五种存储列，按值的类型落其中一列
```

**第一个坑**：`ts_kv.key` 存的是**整数 id**，键名在 `key_dictionary`：

```sql
-- 读到键名必须联表
SELECT d.name AS 设备, kd.key AS 指标,
       to_char(to_timestamp(t.ts/1000) AT TIME ZONE 'Asia/Shanghai', 'MM-DD HH24:MI') AS 时间,
       coalesce(t.dbl_v, t.long_v) AS 值
FROM ts_kv t
JOIN key_dictionary kd ON kd.key_id = t.key
JOIN device d ON d.id = t.entity_id
WHERE d.name = '单相园-1#进线总表·星河工业园'
  AND kd.key = 'energy_reading'
ORDER BY t.ts DESC LIMIT 10;
```

**第二个坑**：同一个「数」可能落在不同列。金额类属性存 `str_v`，
计数类存 `dbl_v` —— 读数值一律写 `coalesce(dbl_v, str_v::numeric)`。

### 2.2 属性：`attribute_kv`（分三种作用域）

```text
attribute_type = 1  →  CLIENT_SCOPE（设备可读可写）
attribute_type = 2  →  SERVER_SCOPE（只有服务端，客户看不到）
attribute_type = 3  →  SHARED_SCOPE（设备可读）
```

平台自己的配置几乎都在 **SERVER_SCOPE（=2）**：倍率、计量层级、费率、账单字段。

### 2.3 自建表（不在 ThingsBoard 原生模型里）

| 表 | 存什么 | 谁写 |
| --- | --- | --- |
| `meter_reading_batch` | 每次抄表批次（谁触发、几台、状态） | 抄表任务 |
| `meter_reading_record` | 抄表明细，**按月分区**（`_2026_10`…） | 抄表任务 / 现场补抄 |
| `tb_sync_log` | 与外部系统同步的日志 | 同步任务 |
| `billing` / `billing_detail` | 建好了但**当前不使用**（账单实际存为资产） | — |

> 账单为什么不进 `billing` 表：现有两个消费方（台账金额、账单交叉表）
> 读的都是 `energy_bill` 资产的 SERVER_SCOPE 属性。换表等于把已跑通的链路推倒。

### 2.4 账单位置

```
asset.type = 'energy_bill'
  name = BILL-<客户码8位>-<账期>-<品种>-<表码>   ← 资产名就是账单号
  属性（SERVER_SCOPE）：amount / usage / energyFee / basicFee /
                        powerFactorFee / surchargeFee / meterLevel /
                        status / usageSource / details(JSON) …
```

---

## 三、逐功能：统计 SQL 对照

下面每节给的都是**可直接复制执行**的 SQL。
页面数字与 SQL 结果对不上时，先看该节「口径提示」。

### 3.0 先看两件事：场站和时间

**场站**：在**看板右上角**选，不在左侧「查询设置」里。它是整块看板共用的统计范围，
树形展开（组织 → 子组织 → 场站），只列具体场站 —— 没有「全部场站」，
默认第一个，选择记在 Cookie 里。

新客户第一次登录时若一个场站都没有，会被不可关闭的蒙屏挡住，先建场站才能进系统。

**时间**：在左侧「查询设置」或顶部「分析条件」里选，有「实时 / 历史」两个页签。

换场站后**结果会自动重查**，不用再点「查询」：统计表、曲线、明细表会一起换成新场站的
设备。如果换了场站但数字没变，那是缺陷（见 [③ 初始化 → 场站与查询条件的加载顺序](/admin/03-init)）。

### 3.0.1 时间是怎么选的（每个页面都适用）

所有能源看板的时间都在**部件里**选，不在看板右上角（那里已经隐藏，见
[③ 初始化 → 时间怎么选](/admin/03-init)）。两个部件、两套页签，语义完全相同：

| 页签 | 控件 | 窗口 |
| --- | --- | --- |
| 实时 | `最近 [N] [秒/分钟/小时/天]` | 右端 = 当前时刻，随时间向前滚 |
| 历史 | 按日 / 按月 / 按年 + 起止 | 固定区间 |

**实时模式会自动回看**：部件先探该实体最后一个数据点（按「勾选的设备 → 品种 →
树节点 → 场站」顺序试），若它已落在窗口之外，**整个窗口**滑到能兜住它
（宽度不变），并在标题写 `数据止于 HH:MM`。所以「实时页一片空白」通常不是没数据，
而是数据停在几小时前 —— 标题那行字就是答案，别急着查接口。

**跨度会真实改变结果**：桶宽 = 窗口 ÷ 40（1 秒 ~ 1 小时），随 `payload.intervalMs`
下发。选 5 分钟是 8 秒一桶，选 60 分钟是 90 秒一桶；报表表格的列数也随之变化
（5 分钟约 6 列、60 分钟约 60 列）。若发现改跨度后表格/曲线完全没变，那是缺陷。

**时间入口只有一处**：看板里有查询设置（或分析条件）时，其余部件不再自带
「按日/按月/按年」或「时/日/月/年」控件 —— 它们的粒度由 `payload.grain` 决定。
峰谷分析右侧的时分段已于 2026-10-25 删除。

`数据止于` 只对**演示数据**常见（逐小时快照，初始化后不再增长）。
接真实 RTU 时窗口右端贴着现在，这句话不会出现。

**用实时页验一条数据到底通没通**：

```bash
# 0) 拿一个令牌（客户账号即可，只能读到自己名下的设备）
TOKEN=$(curl -s -X POST http://127.0.0.1:8090/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"customer@126.com","password":"12345678"}' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')

# 1) 这台设备在库里叫什么 id（换成你要查的名字）
DEV=$(docker exec -i energy-postgres psql -U postgres -d thingsboard -tAc \
  "SELECT id FROM device WHERE name='单相园-1#进线总表·星河工业园'")

# 2) 平台侧最后 3 个点（实时页「数据止于」取的就是这里的第一条）
curl -s -H "X-Authorization: Bearer $TOKEN" \
  "http://127.0.0.1:8090/api/plugins/telemetry/DEVICE/$DEV/values/timeseries?keys=energy,power_total&startTs=0&endTs=$(($(date +%s)*1000))&limit=3&orderBy=DESC" \
  | python3 -m json.tool

# 3) 判读
#    最新点是刚才   → 页面选「实时」，窗口调到能覆盖它的跨度，曲线会持续出点
#    最新点早很多   → 设备侧没在报，按 [④ 设备接入](/admin/04-device-access) 的顺序查
#    完全没有返回值 → key 名不对（换品种）或该设备从未上报过
```

**看板级时间窗口**（编辑模式下仍可改）与部件时间是两件事：
部件发布条件时会调 `onUpdateTimewindow` 把看板窗口同步过去，
所以你在部件里选的历史区间，右键「编辑仪表板」看到的时间也是同一段。

---

### 3.0.2 「查询设置」部件里的树长什么样

带「查询设置」的看板（历史能耗 / 基础报表 / 参数报表 / 实时能耗 / 分项能耗…）
左侧那棵树有两种维度，规则不同：

**按设备层级** —— 场站是**根节点**，设备挂在它下面：

```
单相场站                  ← 根：当前选中的场站（虚拟节点，不能勾选）
  单相园-1#进线总表
  单相园-照明分项总表
  单相园-A栋照明回路
```

场站根只是个收拢层：它没有勾选框（场站资产本身没有遥测，勾进来只会在提交载荷里
多一个不产生数据的实体），点箭头可以折起来，切换场站时根名跟着变。
把场站当根是为了让树先回答「这是哪个场站的表」—— 以前设备平铺，
单相场站和三相场站的表混在一起，只能靠名字猜归属。

**按分组维度** —— 根是维度容器（电能 / 用电分项 / 用能区域 / 用能性质 / 空间位置），
**根下直接是分类节点，没有场站层**：

```
用电分项                  ← 根：维度名
  照明
  插座
  给排水
```

数据模型里每个维度下确实有一层「场站分组」（`asset.type='场站分组'`，label = 场站名），
它是**内部隔离层**：同一客户多个场站时，各场的分类不能混在一起。
界面只保留当前场站那一个分组，并把它的子节点提升到维度根下 ——
客户看到的第一反应不能是「场站怎么跑到分项下面去了」：场站是**归属**，不是分项的子类目。

数据模型一行不动，只在渲染时穿透。所以「新建子分类 / 添加设备 / 拖拽落点」的真实
挂载父仍是那个场站分组 —— 否则新节点会挂到维度容器下、脱离场站分区、聚合断掉。

右上角切到哪个场站，按分组维度的树就只显示那个场站的分项/区域。
如果切了场站树里还有别的场站的分类，那是缺陷。

---

### 3.0.3 图表部件的两种形态与统一规格

6 个图表部件（能耗概览 / 分项能耗 / 历史能耗 / 实时能耗 / 能源流向 / 峰谷分析）
都提供 **图表 ⇄ 数据表** 切换，且规格统一：

| 项 | 规格 |
| --- | --- |
| 位置 | 右上角，`top: 34px`（避开 TB 自带的部件操作按钮） |
| 尺寸 | 图标 26×26，容器 padding 2px，圆角 6px |
| 显隐 | 默认 `opacity: 0; pointer-events: none`，`:hover` 时恢复 |
| 激活色 | `--tb-primary-600`（当前形态高亮） |
| 数据 | 两种形态读同一份数据（如 `bEnergy` / `billingRows`），数字必须一致 |

改任一部件时，另外 5 个要一起改 —— 类名与样式分散在各部件内，
没有共享 CSS（TB 部件之间无法互相引用样式）。

**看板高度**：`gridSettings.autoFillHeight` 让网格恰好一屏。
≤ 20 行的看板开启，> 20 行（如 36 行的「我的账单」）保持固定行高、页面可滚 ——
否则行高被均摊到 25px，部件全被压扁。

**查询设置高度**：`query_panel.sizeY` 必须等于「该看板最大底边 − 它自己的 row」，
否则左侧会矮一截或在中间才开始。

### 3.1 能耗概览 / 实时能耗

**看什么**：当前功率、今日电量、负荷率、三相电压电流。

**数据键**：

| 键 | 含义 | 聚合 |
| --- | --- | --- |
| `power_total` | 有功总功率（kW） | 瞬时值（取最新） |
| `energy` | 本小时用电量（kWh） | 求和 |
| `energy_day` | 当日累计电量 | 取最新 |
| `load_rate` | 负荷率（%） | 取最新 |
| `voltage_a/b/c`、`current_a/b/c` | 分相电压/电流 | 取最新 |

```sql
-- 某台设备最近 1 小时的关键指标（实时页的「当前值」）
SELECT kd.key AS 指标,
       to_char(to_timestamp(max(t.ts)/1000) AT TIME ZONE 'Asia/Shanghai','MM-DD HH24:MI:SS') AS 最新时间,
       (array_agg(coalesce(t.dbl_v, t.long_v) ORDER BY t.ts DESC))[1] AS 最新值
FROM ts_kv t
JOIN key_dictionary kd ON kd.key_id = t.key
WHERE t.entity_id = (SELECT id FROM device WHERE name = '单相园-1#进线总表·星河工业园')
  AND kd.key IN ('power_total','energy_day','load_rate','voltage_a','current_a')
  AND t.ts > (extract(epoch from now()) - 3600) * 1000
GROUP BY kd.key
ORDER BY kd.key;
```

**今日电量**（按东八区切天，不能用 UTC）：

```sql
SELECT round(sum(coalesce(t.dbl_v, t.long_v))::numeric, 2) AS 今日电量_kWh
FROM ts_kv t
JOIN key_dictionary kd ON kd.key_id = t.key
WHERE t.entity_id = (SELECT id FROM device WHERE name = '单相园-1#进线总表·星河工业园')
  AND kd.key = 'energy'
  AND t.ts >= (extract(epoch FROM date_trunc('day', now() AT TIME ZONE 'Asia/Shanghai')
                              AT TIME ZONE 'Asia/Shanghai') * 1000)::bigint
  AND t.ts % 3600000 = 0;        -- 只取整点，排除手工注入的测试点
-- 说明：ts_kv.ts 是 bigint 毫秒，比较前必须换算成毫秒数；
--       直接拿 timestamptz 比会报 bigint >= timestamp
```

**口径提示**：

- `energy` 是**本小时增量**，不是累积表底。求和得到区间电量。
- 切天必须用 `Asia/Shanghai`。按 UTC 切会把北京时间 08:00 之后算到前一天。
- 页面上的「实时值」是设备上报的瞬时量，不等于「区间累加」。

**⚠ 「能耗概览」的四张卡读的是资产，不是设备**

上面两条 SQL 查的是**设备**（单台表）。而概览页的
「今日 / 本月 / 今年 / 总用电量」四张卡，取数实体是**场站资产**，
键名也不同：

| 页面卡片 | 取数实体 | 键 | 聚合 |
| --- | --- | --- | --- |
| 今日用电量 | 场站 ASSET | `energy_total` | 按日 SUM |
| 本月用电量 | 场站 ASSET | `energy_total` | 按日 SUM 后累加 |
| 今年用电量 | 场站 ASSET | `energy_total` | 按日 SUM 后累加 |
| 总用电量 | 场站 ASSET | `energy_total` | 全部历史累加 |

```sql
-- 概览页「今日用电量」对应的公开 SQL（与部件同一口径）
-- 部件实际走 timeseries 接口按日聚合；这是一次性核对用的等价写法
SELECT round(sum(coalesce(t.dbl_v, t.long_v))::numeric, 2) AS 今日_场站合计_kWh
FROM ts_kv t
JOIN key_dictionary kd ON kd.key_id = t.key
WHERE t.entity_id = '<场站资产id>'
  AND kd.key = 'energy_total'
  AND t.ts >= (extract(epoch FROM date_trunc('day', now() AT TIME ZONE 'Asia/Shanghai')
                              AT TIME ZONE 'Asia/Shanghai') * 1000)::bigint;
```

资产上的 `energy_total` 由 `AssetTotalsScheduler` 每小时汇总一次
（设备 `energy` → 资产 `energy_total`）。设备有数但场站是 0，就是这一步没跑 ——
成因、SQL 与排查顺序见[⑦ 数据流第六节](/admin/data-pipeline)。

---

### 3.2 历史能耗

**看什么**：任意时间段内的电量趋势（小时/日/月粒度）。

```sql
-- 按日汇总某设备一个月的电量
SELECT to_char(to_timestamp(t.ts/1000) AT TIME ZONE 'Asia/Shanghai','YYYY-MM-DD') AS 日期,
       round(sum(coalesce(t.dbl_v, t.long_v))::numeric, 3) AS 电量
FROM ts_kv t
JOIN key_dictionary kd ON kd.key_id = t.key
WHERE t.entity_id = (SELECT id FROM device WHERE name = '单相园-1#进线总表·星河工业园')
  AND kd.key = 'energy'
  AND t.ts >= 1790784000000 AND t.ts < 1793462400000   -- 2026-10 全月
  AND t.ts % 3600000 = 0
GROUP BY 1 ORDER BY 1;
```

**口径提示**：区间上界用 `<`，不要用 `<=` —— `energy[t]` 覆盖 `(t−1h, t]`，
含上界会把下个账期第一个小时算进来。

---

### 3.3 抄表功能（抄表台账 / 记录 / 现场补抄）

**看什么**：每台表的本期表底、上期表底、用量、抄表质量。

**核心表**：`meter_reading_record`（按月分区）

```sql
-- 本账期每台表的账期累计用量（台账页的「用量」列）
WITH rec AS (
    SELECT r.* FROM meter_reading_record r
    WHERE r.tenant_id = '<租户id>' AND r.period = '2026-10'
      AND (r.quality <> 'abnormal' OR r.curr_reading IS NOT NULL)
), agg AS (
    SELECT device_id,
           max(CASE WHEN rn_first = 1
                    THEN coalesce(prev_reading, curr_reading) END) AS 期初表底,
           max(CASE WHEN rn_last  = 1 THEN curr_reading END)       AS 期末表底,
           max(ratio) AS 倍率
    FROM (
        SELECT r.*,
               row_number() OVER (PARTITION BY r.device_id ORDER BY r.created_time ASC)  AS rn_first,
               row_number() OVER (PARTITION BY r.device_id ORDER BY r.created_time DESC) AS rn_last
        FROM rec r WHERE r.curr_reading IS NOT NULL
    ) t GROUP BY device_id
)
SELECT (SELECT name FROM device WHERE id = a.device_id) AS 设备,
       期初表底, 期末表底, 倍率,
       round(((期末表底 - 期初表底) * coalesce(倍率,1))::numeric, 4) AS 用量
FROM agg a ORDER BY 设备;
```

**口径提示（最容易搞错的一条）**：

台账用量 = **期末表底 − 期初表底**，不是「最后一次抄表的 usage 增量」。

现场一个月会抄多次（建基线 / 月中核对 / 月末出账）。取「最新一条的 usage」
在月末那次没有新增读数时就会显示 0 —— 实测踩过：实际用了 94.575 kWh，台账报 0。

`DISTINCT ON (device_id) ORDER BY created_time DESC` 取的是「最新一条记录」，
不是「账期累计」。要累计就必须像上面这样算首末差。

**现场补抄的三个字段**：

| 字段 | 含义 |
| --- | --- |
| `field_status` | `pending`（待审）/ `approved` / `rejected` |
| `field_value` | 现场抄回的表底 |
| `field_note` | 现场备注（表位、异常情况） |

```sql
-- 待审的现场补抄
SELECT to_char(to_timestamp(reading_time/1000) AT TIME ZONE 'Asia/Shanghai','MM-DD HH24:MI') AS 抄表时间,
       device_name AS 设备, field_value AS 现场表底, field_note AS 备注
FROM meter_reading_record
WHERE tenant_id = '<租户id>' AND field_status = 'pending'
ORDER BY reading_time DESC;
```

---

### 3.4 峰谷分析

**看什么**：尖 / 峰 / 平 / 谷 / 深谷 五档电量，逐小时或逐日。

**数据链路**（三层，逐层可验证）：

```
① ts_kv       energy_reading（累积表底，每小时一个点）
      ↓  HOUR + MAX 聚合（TB 内部）
② 小时表底    bucket_center_ms → reading
      ↓  相邻两点求差 × 倍率
③ 逐小时用量  inc × ratio → usage
      ↓  按 tou_scheme 判档
④ 五档合计    Σ = 总量
```

```sql
-- ① 原始小时表底
SELECT entity_id,
       (ts / 3600000) * 3600000 + 1800000 AS 桶中心ms,
       max(coalesce(dbl_v, long_v))       AS 表底
FROM ts_kv
WHERE entity_id = '<设备id>'
  AND key = (SELECT key_id FROM key_dictionary WHERE key = 'energy_reading')
  AND ts > 1792465033230 AND ts <= 1792727833230
GROUP BY entity_id, ts / 3600000
ORDER BY 桶中心ms;

-- ②③ 逐小时用量 + 区间两个口径
WITH pts AS (
    SELECT entity_id,
           (ts / 3600000) * 3600000 + 1800000 AS bucket_center_ms,
           max(coalesce(dbl_v, long_v))       AS reading
    FROM ts_kv
    WHERE entity_id = '<设备id>'
      AND key = (SELECT key_id FROM key_dictionary WHERE key = 'energy_reading')
      AND ts > 1792465033230 AND ts <= 1792727833230
    GROUP BY entity_id, ts / 3600000
), diff AS (
    SELECT entity_id, bucket_center_ms, reading,
           reading - lag(reading) OVER (PARTITION BY entity_id ORDER BY bucket_center_ms) AS inc
    FROM pts
)
SELECT count(*) AS 点数,
       min(reading) AS 首表底, max(reading) AS 末表底,
       round(((max(reading) - min(reading)) * 1)::numeric, 4)                     AS 首末差_台账口径,
       round((sum(CASE WHEN inc >= 0 THEN inc ELSE 0 END) * 1)::numeric, 4)       AS 正增量累加_页面口径,
       count(*) FILTER (WHERE inc < 0)                                            AS 倒走段数
FROM diff GROUP BY entity_id;
```

**口径提示（关键）**：

1. **桶中心**：TB 小时聚合返回桶中心（整点数据 → `:30`）。
   所以桶时间要还原成 `(ts/3600000)*3600000 + 1800000`，否则边界判断会错半小时。
2. **上界 `+1ms`**：TB 的区间是左闭右开，`<= to` 要写 `to + 1`，
   否则 `to` 那一刻的点取不回来 —— 每天少 1/24。
3. **两个口径不等是正常的**：表底倒走（换表/归零/报错值）时，
   `首末差 > 正增量累加`。页面 `backwardSegments > 0` 就说明有跳过。
4. **五档怎么判**：`tou_scheme` 存在租户级资产上，Java 按时段定义判档，
   SQL 给不出 —— 但 `Σ各档 == 总量` 一定成立，可用上面的总量反验。

---

### 3.5 分项能耗 / 区域能耗

**看什么**：按「用能分项」或「用能区域」聚合电量。

> ⚠ **这两页必须显示不同数据。** 如果两页的图例和图完全一样
> （都是「照明 插座 炊事 … A栋办公区 食堂」这种混在一起），
> 说明踩了三个坑之一，按顺序查：
>
> **① 演示数据只建了「分项」一条分类线**
> 「用能区域」维度下只有空的场站容器，0 个区域节点。
> 查：`SELECT count(*) FROM asset WHERE type='区域' AND customer_id='<客户id>';`
> 修：重跑 `POST /api/energy/demo-data`（会调 `backfillDemoAreas` 补齐）。
>
> **② `siteChildType` 没配**
> 场站的 Contains 里同时有分项和区域，不配置就会把两套混在一起。
> 修：分项能耗配 `siteChildType: "分项"`，区域能耗配 `"区域"`
> （`analysis_bar` 的【外观】→「场站下的子节点类型」）。
> 结果部件靠 state 里的 `childType` 同步剪枝，所以要连模板一起推、刷客户副本。
>
> **③ 区域资产没有汇总遥测**
> 图例只显示**有 data 的序列**。区域没有 `energy_total` 时一条都画不出来，
> 页面看起来还是分项的数据。查：
> `SELECT a.label, count(*) FROM asset a JOIN ts_kv kv ON kv.entity_id=a.id WHERE a.type='区域' GROUP BY 1;`
> 修：`POST /api/energy/asset-totals/rebuild`（要**客户身份**，会写自己域内资产）。
>
> 正确形态（2026-10-26 实测，演示客户本月）：
>
> ```
> 分项能耗   7 条序列   总 4.58 kW·h   照明分项总表 / A栋照明回路 / 插座分项总表 …
> 区域能耗   3 条序列   总 4.58 kW·h   公共区域 2.21 / A栋办公区 1.92 / 食堂 0.45
> ```
>
> 总量一致（同一批设备的不同分组方式），明细完全不同。
> 详见 `03-init.md` 的「用能维度：分项 / 区域 / 性质 / 位置 各自独立」。

**分组靠 `relation` 表（Contains 关系）**：

```sql
-- 某场站下每台设备的电量合计
SELECT d.name AS 设备,
       round(sum(coalesce(t.dbl_v, t.long_v))::numeric, 3) AS 电量
FROM ts_kv t
JOIN key_dictionary kd ON kd.key_id = t.key
JOIN device d ON d.id = t.entity_id
WHERE kd.key = 'energy'
  AND d.additional_info::jsonb->>'siteId' = '<场站资产id>'
  AND t.ts >= 1790784000000 AND t.ts < 1793462400000
  AND t.ts % 3600000 = 0
GROUP BY d.name ORDER BY 电量 DESC;
```

**设备属于哪个场站**：`device.additional_info ->> 'siteId'`（不是 relation！）

```sql
-- 列出某客户全部设备及其场站
SELECT d.name AS 设备, d.label AS 显示名,
       a.name AS 场站, d.additional_info::jsonb->>'siteId' AS 场站id
FROM device d
LEFT JOIN asset a ON a.id = (d.additional_info::jsonb->>'siteId')::uuid
WHERE d.customer_id = '<客户id>'
ORDER BY 1;
```

**口径提示**：分项/区域聚合时，如果该分项里有「总表 + 分表」父子关系，
直接 `sum` 会把同一度电算两遍。平台按 `meterLevel` 去重（见第 3.7 节）。

---

### 3.6 我的账单

**看什么**：每台表一张账单，含四项费用与合计。

```sql
-- 客户某账期的全部账单（逐张，金额 = 四项之和）
WITH bill AS (
    SELECT a.id, a.name,
           max(CASE WHEN kd.key='deviceName'  THEN ak.str_v END) AS 设备,
           max(CASE WHEN kd.key='energy'      THEN ak.str_v END) AS 品种,
           max(CASE WHEN kd.key='status'      THEN ak.str_v END) AS 状态,
           max(CASE WHEN kd.key='usageSource' THEN ak.str_v END) AS 用量来源,
           max(CASE WHEN kd.key='meterLevel'  THEN coalesce(ak.dbl_v, ak.str_v::numeric) END) AS 层级,
           max(CASE WHEN kd.key='usage'       THEN coalesce(ak.dbl_v, ak.str_v::numeric) END) AS 用量,
           max(CASE WHEN kd.key='energyFee'   THEN coalesce(ak.dbl_v, ak.str_v::numeric) END) AS 电度费,
           max(CASE WHEN kd.key='basicFee'    THEN coalesce(ak.dbl_v, ak.str_v::numeric) END) AS 基本费,
           max(CASE WHEN kd.key='powerFactorFee' THEN coalesce(ak.dbl_v, ak.str_v::numeric) END) AS 力调费,
           max(CASE WHEN kd.key='surchargeFee' THEN coalesce(ak.dbl_v, ak.str_v::numeric) END) AS 附加费,
           max(CASE WHEN kd.key='amount'      THEN coalesce(ak.dbl_v, ak.str_v::numeric) END) AS 合计
    FROM asset a
    JOIN attribute_kv ak ON ak.entity_id = a.id AND ak.attribute_type = 2
    JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
    WHERE a.type = 'energy_bill'
      AND a.tenant_id = '<租户id>'
      AND a.name LIKE 'BILL-%2026-10%'
    GROUP BY a.id, a.name
)
SELECT 设备, 品种, 状态, 用量来源, 层级, 用量,
       电度费, 基本费, 力调费, 附加费, 合计,
       round((coalesce(电度费,0)+coalesce(基本费,0)
              +coalesce(力调费,0)+coalesce(附加费,0))::numeric, 2) AS 四项和
FROM bill ORDER BY 品种, 设备;

-- 汇总（对应页头三个数）
WITH bill AS (
    SELECT a.id,
           max(CASE WHEN kd.key='energy'     THEN ak.str_v END) AS energy,
           max(CASE WHEN kd.key='meterLevel' THEN coalesce(ak.dbl_v, ak.str_v::numeric) END) AS lvl,
           max(CASE WHEN kd.key='amount'     THEN coalesce(ak.dbl_v, ak.str_v::numeric) END) AS amount
    FROM asset a
    JOIN attribute_kv ak ON ak.entity_id = a.id AND ak.attribute_type = 2
    JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
    WHERE a.type = 'energy_bill' AND a.tenant_id = '<租户id>'
      AND a.name LIKE 'BILL-%2026-10%'
    GROUP BY a.id
), top AS (
    SELECT DISTINCT energy FROM bill WHERE lvl = 1
)
SELECT count(*) AS 账单数,
       round(sum(CASE WHEN b.lvl = 1 OR t.energy IS NULL THEN b.amount ELSE 0 END)::numeric, 2) AS 应付_进线口径,
       round(sum(b.amount)::numeric, 2)                                                        AS 全表合计
FROM bill b LEFT JOIN top t ON t.energy = b.energy;
```

**口径提示**：

- `合计 = 电度费 + 基本费 + 力调费 + 附加费`，四个字段和必须相等（差 0.01 是舍入）。
- **基本电费/力调电费只算进线总表（`meterLevel=1`）**。11 台表各收 1600 元会高一个数量级。
- **应付 ≠ 全表合计**：同一品种里有进线总表时，只汇总进线（否则总表含的分表被再加一遍）。
  没有进线总表的品种（水/气/汽全是 level 0）按全部表汇总。
- 金额类属性存在 `str_v`，不是 `dbl_v` —— 只读 `dbl_v` 会全是 NULL。

---

### 3.7 一级 / 二级 / 三级计量（`meterLevel`）

**这是「数据准不准」的根基**，单列一节说清楚。

| `meterLevel` | 含义 | 在统计里的作用 |
| --- | --- | --- |
| 1 | 进线总表（关口表） | 站点级费用（基本电费/力调）只算它；同品种汇总只算它 |
| 2 | 分项总表 | 参与明细，不参与「应付」汇总（有 level 1 时） |
| 3 | 回路（末端） | 同上 |
| 0 / 未设置 | 未声明 | 不参与分层 —— 全部相加（可能虚高） |

**存储位置**：`device` 的 SERVER_SCOPE 属性 `meterLevel`

```sql
-- 看全租户设备的计量层级
SELECT d.name AS 设备,
       (SELECT coalesce(ak.dbl_v, ak.long_v, ak.str_v::numeric)
          FROM attribute_kv ak JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
         WHERE ak.entity_id = d.id AND ak.attribute_type = 2 AND kd.key = 'meterLevel') AS 层级,
       d.additional_info::jsonb->>'siteId' AS 场站id
FROM device d
WHERE d.tenant_id = '<租户id>'
ORDER BY 层级 NULLS LAST, 设备;
```

**校验层级守恒**（父表电量 ≥ 子表之和，差额 = 线损 + 未装表）：

```sql
-- 按 Contains 关系找父子对，比较区间增量
WITH meter AS (
    SELECT d.id, d.name,
           (SELECT coalesce(ak.dbl_v, ak.long_v)
              FROM attribute_kv ak JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
             WHERE ak.entity_id = d.id AND ak.attribute_type = 2 AND kd.key = 'meterLevel') AS lvl
    FROM device d WHERE d.tenant_id = '<租户id>'
), inc AS (
    SELECT t.entity_id,
           max(coalesce(t.dbl_v, t.long_v)) - min(coalesce(t.dbl_v, t.long_v)) AS delta
    FROM ts_kv t
    WHERE key = (SELECT key_id FROM key_dictionary WHERE key = 'energy_reading')
      AND t.ts >= 1790784000000 AND t.ts < 1793462400000
    GROUP BY t.entity_id
)
SELECT parent.name AS 上级表,
       round(p.delta::numeric, 2) AS 上级增量,
       round(sum(ci.delta)::numeric, 2) AS 下级合计,
       round((p.delta - sum(ci.delta))::numeric, 2) AS 差额
FROM relation r
JOIN meter parent ON parent.id = r.from_id
JOIN meter c ON c.id = r.to_id
JOIN inc p ON p.entity_id = parent.id
JOIN inc ci ON ci.entity_id = c.id
WHERE r.relation_type = 'Contains'
GROUP BY parent.name, p.delta
ORDER BY 差额;
```

> 演示数据的差额严格等于「线损 + 未装表」系数（如 ×1.025）。
> 差额为**负数**说明父子关系配错了，或某台表被重复计算。

**配置入口**：

```bash
GET  /api/energy/device-config?deviceId=<id>    # 读层级 + 倍率
POST /api/energy/device-config                  # 写
  {"deviceId":"...","meterLevel":1,
   "ctRatio":"200/5","ptRatio":"10000/100","ratioApplied":false}
```

也就在「组织与场站 → 选中场站 → 设备面板」里可视化编辑。

---

### 3.8 手工填报（虚拟表）

**看什么**：没装表的分项（空调、其他水表），按月人工填一个总量。

**看板由三个 TB 原生部件组成**（2026-10-26 拆的，与其它 13 个报表看板同构）：

| 位置 | 部件 | 职责 |
| --- | --- | --- |
| 左 6×11 | `energy_management.query_panel` | 选设备 / 指标 / 时间 |
| 右上 18×7 | `energy_management.timeseries_chart` | 折线图 + 数据表（同一部件内切换） |
| 右下 18×4 | `energy_management.manual_entry` | 「用能数据录入」按钮 + 右侧抽屉 |

拆之前是一个 `manual_entry` 包办三者：查询设置自绘一套、折线图也自绘一套，
于是同类系统里出现两套查询样式、两份图案，而且手工填报的图没有图例开关 / tooltip /
图表-表格切换 / 缩放条（`timeseries_chart` 全都有）。

**查询设置的两个专用开关**（都只在这个看板打开）：

| 设置 | 值 | 为什么 |
| --- | --- | --- |
| `virtualOnly` | `true` | 设备树只列 `additionalInfo.deviceVirtual='virtual'` 的表。默认 `false`，其它看板不受影响 |
| `defaultCurrentYear` | `true` | 时间默认「今年 1/1 ~ 12/31」+ 粒度「按年」。默认 `false` |

`virtualOnly` 打开时**同时跳过品种过滤**（`inSourceProfiles` 直接返回 true）：
虚拟表跨品种，而三相场站唯一的虚拟表是水表 —— 若还按「电能」筛，树是空的。
品种下拉也一并隐藏（`showKind=false`），留着只会误导。

**只对虚拟表开放**（三道门，缺一不可）：

1. 前端设备树：`virtualOnly` 过滤（见上）
2. 后端元数据：`/api/energy/manual-entry/meta` 只返回 `MeteringMath.isVirtual(Device)` 为真的设备
3. 后端保存：`/api/energy/manual-entry/save` 再校验一次，非虚拟设备返回 400

前两道只是体验，**第三道才是门闩** —— 否则改个请求就能写脏数据。

**时间粒度**：`query_panel` 按跨度自动定档（>31 天 → 月）。月度数据在
`timeseries_chart` 里用「日桶 + 前端按自然月归并」的方式取，横轴才是真正的
`2026-01` / `2026-02`。直接给服务端 30 天桶会串月（实测 2 月变 2630、3 月丢失）。

**存储**：写在 `energy` 键的**月首 00:00** 这一个点上（整月总量，不是小时增量）。

```sql
-- 某虚拟表本年各月的填报值
SELECT to_char(to_timestamp(t.ts/1000) AT TIME ZONE 'Asia/Shanghai','YYYY-MM') AS 月份,
       coalesce(t.dbl_v, t.long_v) AS 填报用量
FROM ts_kv t
WHERE t.entity_id = '<虚拟表设备id>'
  AND t.key = (SELECT key_id FROM key_dictionary WHERE key = 'energy')
  AND extract(day from to_timestamp(t.ts/1000) AT TIME ZONE 'Asia/Shanghai') = 1
  AND to_char(to_timestamp(t.ts/1000) AT TIME ZONE 'Asia/Shanghai','HH24:MI') = '00:00'
ORDER BY 月份;
```

**口径提示**：

- 虚拟表**没有** `energy_reading`（没有表底，人工填的就是用量）。
- 出账时整月归「平」档，账单标 `touAssumedFlat=true` ——
  人工填的总量没有小时分布，硬拆峰谷等于编数。
- 判定依据是 `device.additional_info ->> 'deviceVirtual'`，**不是** SERVER_SCOPE 属性。
  平台统一用 `MeteringMath.isVirtual(Device)`，不要再各写一份。

### 3.9 参数报表

**入口**：综合报表 → 参数报表 → **看板**（`query_panel` + `timeseries_table`），
与其它 12 个报表统一。

> 2026-10-26 之前这个菜单项指向独立页面 `/param-report`。那是手写的 Angular 组件
> （`pages/param-report`），自带一套 `tb-pr-query-bar`，与看板里「查询设置」部件的
> 样式、交互、指标口径都不是一套。已改为 `linkType=DASHBOARD`。
> 存量客户的菜单由 `repair-init` 自动重建（检测菜单里是否还残留 `/param-report`）。

**看什么**：先选一只表 → 勾一级指标 → 右侧表格出该指标下的二级指标。

```
左侧「指标参数」                     右侧表格（每台表 × 每个二级指标一列）
  相电压              ← 一级        时间 | …· A相电压 | …· B相电压 | …· C相电压 | …· 平均相电压
    A相电压           ← 二级（= 遥测键 voltage_a）
    B相电压                        voltage_b
    C相电压                        voltage_c
    平均相电压                      voltage_avg
  有功功率 / 功率因数 …（同构）
```

**这条规则适用于所有带「查询设置」的看板**：一级用于选择，二级用于取值。
默认勾哪一组看 `query_panel` 的 `defaultParamCode`：参数报表配「相电压」（code=14），
因为部分表没有用电量历史，默认勾它打开就是空表。

**存储**：租户级资产 `type='default'`，挂在「能源参数字典」下（`relation` 边）。

```sql
-- 电能品种的二级指标清单
SELECT child.name AS 指标名,
       (SELECT ak.str_v FROM attribute_kv ak JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
         WHERE ak.entity_id = child.id AND kd.key = 'key') AS 遥测键,
       (SELECT ak.str_v FROM attribute_kv ak JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
         WHERE ak.entity_id = child.id AND kd.key = 'unit') AS 单位
FROM relation r
JOIN asset lib ON lib.id = r.from_id AND lib.type = 'energy_type_library'
JOIN asset parent ON parent.id = r.to_id AND parent.name LIKE '%电能%'
JOIN relation r2 ON r2.from_id = parent.id
JOIN asset child ON child.id = r2.to_id
WHERE r.from_id = lib.id
ORDER BY 指标名;
```

**口径提示**：字典是**真相源**。报表能显示哪些指标、单位是什么，全看这里。
一级指标上的 `agg`（电压 AVG / 电量 SUM）决定取数聚合方式 ——
混选电压和电量时不会用同一个聚合方式算错。
设备上报了字典里没有的键，报表认不出来（`05-troubleshoot.md` 现象 H）。

**看板入口的归属**：菜单指向的看板是客户自己名下那份副本
（`dashboard.customer_id = 该客户`），所以看板内容可以按客户单独调，
模板则保留在租户级（`customer_id IS NULL`）。

---

### 3.10 闲时能耗

**看什么**：非生产时段是否仍有持续负荷。

**存储**：日粒度结果写 `ts_kv`，四个键：

| 键 | 含义 |
| --- | --- |
| `idle_energy` | 闲时时段电量 |
| `idle_avg_power` | 闲时平均功率 |
| `idle_delta_count` | 与基线的偏差次数 |
| `idle_exceed` | 是否超标（0/1，用来触发告警） |

```sql
-- 某设备近 30 天的闲时判定结果
SELECT to_char(to_timestamp(t.ts/1000) AT TIME ZONE 'Asia/Shanghai','MM-DD') AS 日期,
       max(CASE WHEN kd.key='idle_energy'      THEN coalesce(t.dbl_v,t.long_v) END) AS 闲时电量,
       max(CASE WHEN kd.key='idle_avg_power'   THEN coalesce(t.dbl_v,t.long_v) END) AS 闲时平均功率,
       max(CASE WHEN kd.key='idle_exceed'      THEN coalesce(t.dbl_v,t.long_v) END) AS 是否超标
FROM ts_kv t JOIN key_dictionary kd ON kd.key_id = t.key
WHERE t.entity_id = '<设备id>'
  AND kd.key LIKE 'idle_%'
  AND t.ts > (extract(epoch from now()) - 30*86400) * 1000
GROUP BY 1 ORDER BY 1 DESC;
```

**闲时怎么判定**（不是机器学习，是阈值规则）：

```
某小时属于闲时  ⟺  该小时落在场站配置的「非工作时段」内
                    AND 该小时平均功率 > 待机功率阈值

场站配置存：asset（场站）SERVER_SCOPE 属性 idleConfig
  { "workStart": "08:00", "workEnd": "18:00",
    "workdays": [1,2,3,4,5], "standbyPowerKw": 5.0, "idleRatio": 0.15 }
```

**口径提示**：`idle_exceed` 是「日粒度标记」，由设备档案上的计算字段
「闲时能耗超标」消费并产生告警 —— 不要直接拿它当小时值。

---

### 3.11 告警中心

**存储**：ThingsBoard 原生 `alarm` / `entity_alarm` 表。

```sql
-- 某客户当前未清除的告警
SELECT a.type AS 告警类型, a.severity AS 级别,
       CASE WHEN a.cleared THEN '已清除'
            WHEN a.acknowledged THEN '已确认未清除'
            ELSE '未确认未清除' END AS 状态,
       to_char(to_timestamp(a.start_ts/1000) AT TIME ZONE 'Asia/Shanghai','MM-DD HH24:MI') AS 开始时间,
       d.name AS 设备
FROM alarm a
LEFT JOIN device d ON d.id = a.originator_id
WHERE a.tenant_id = '<租户id>'
  AND a.cleared = false                 -- 只列活动告警
ORDER BY a.start_ts DESC;
-- 说明：alarm 表没有 status 列，状态由 acknowledged / cleared 两个布尔列表达
```

**告警怎么产生**（三层）：

```
① 设备档案上的计算字段（calculated_field）
     「闲时能耗超标」「电压越限」「三相不平衡度」「负荷率」「碳排放」
        ↓ 条件命中
② 计算字段的 alarm 配置 → 产生 entity_alarm
        ↓
③ 告警中心展示（/api/energy/alarms 按 visibleDeviceIds 收口）
```

**口径提示**：客户账号只能看到「自己名下设备」的告警。
授权为场站级时，按 `visibleSiteIds` → `visibleDeviceIds` 过滤。

---

### 3.12 设备管理：设备运维 / 设备分组 / 设备拓扑

**三个页面各自管什么**（2026-10-26 改版后）：

| 菜单 | 路由 | 是干什么的 | 主要数据源 |
| --- | --- | --- | --- |
| 设备运维 | `/device-management` | 看设备**本身**：状态、参数、测点实时值、历史曲线、计量配置 | `/api/customer/{cid}/deviceInfos` + `ts_kv` + `/api/energy/device-config` |
| 设备分组 | `/device-group` | 看设备**归在哪个分类**：分项 / 区域 / 性质 / 位置 | `/api/customer/{cid}/assets` + `relation` |
| 设备拓扑 | `/device-topology` | 看设备**怎么接线**：进线 → 变压器 → 母线 → 出线 | `asset.type='topology'` + `relation` |

**存储**：

| 内容 | 位置 |
| --- | --- |
| 拓扑图 | `asset.type='topology'`，`additionalInfo` 存布局 |
| 拓扑节点/连线 | `relation`（`Contains` + `additionalInfo` 里的坐标） |
| 设备分组 | `entity_group` + `relation` |
| 设备分组内的**人工排序** | `relation.additional_info ->> 'order'`（设备分组页「上移 / 下移」写入） |
| 设备所属场站 | `device.additional_info ->> 'siteId'` |
| 计量层级 / 倍率 | `attribute_kv`（`DEVICE` + `SERVER_SCOPE`：`meterLevel` / `ctRatio` / `ptRatio` / `meterRatio`） |

```sql
-- 某个分组下设备的排列顺序（设备分组页「上移/下移」的结果）
SELECT d.name AS 设备,
       coalesce((r.additional_info::jsonb ->> 'order')::int, 9999) AS 顺序
FROM relation r
JOIN device d ON d.id = r.to_id
WHERE r.from_id = '<分组资产id>'
  AND r.relation_type = 'Contains'
  AND r.to_type = 'DEVICE'
ORDER BY 顺序, d.name;

-- 某台设备的计量配置（attribute_kv 的 key 是整数，要 join key_dictionary）
SELECT k.key AS 字段, a.long_v, a.str_v
FROM attribute_kv a
JOIN key_dictionary k ON k.key_id = a.attribute_key
WHERE a.entity_id = '<设备id>'
  AND a.attribute_type = 2   -- 2 = SERVER_SCOPE（1=CLIENT_SCOPE, 3=SHARED_SCOPE）
  AND k.key IN ('meterLevel','ctRatio','ptRatio','meterRatio','ratioApplied');
```

**设备的三个展示口径**（改造后三处一致，排查时按这张表对）：

| 列 | 取值 | 说明 |
| --- | --- | --- |
| 设备名称 | `asset/device.label`，为空回退 `name` | 客户看到的展示名 |
| 设备编号 | `device.name` | 技术名，租户内唯一；现场对表用它 |
| 设备一级类型 | 按**设备档案名**归类 | 电能 / 水表 / 燃气 / 蒸汽 / 环境 / 接入设备 / 其他 |
| 设备二级类型 | `device_profile.name` | 单相电能表 / 电能表 / 水表 / 温湿度变送器 / 网关… |

**网关不进「设备分组 → 添加设备」的候选**（2026-10-22 定，仍是这个口径）：

**设备分组的每一层都按右上角场站收窄**（2026-10-26 补齐）：

| 位置 | 数据来源 | 收窄依据 |
| --- | --- | --- |
| 左侧分组树 | `/api/customer/{id}/assets` + 关系 | `filterTreeBySite`（场站分组穿透） |
| 右侧设备表 | 选中节点下的设备 | 跟随树（树已裁剪） |
| 添加设备候选 | `/api/customer/{id}/devices` | `additionalInfo.siteId` |

添加设备的候选里保留两类特殊设备：**未分配场站**的（新接入，要在这里归属）
与全局场站为空时的全部（租户视角未定位）。

网关是代下级设备上报的通信代理，本身不产生能耗。把它挂进分项/区域，
上级汇总会多出一行没有电量、也无法解释的节点。抽屉底部会写明「已排除 N 台网关」，
所以它不会凭空消失 —— 在「设备运维」和「组织」里仍然看得到、也仍然统计在线状态。

**「设备分组 → 添加设备」的类型页签是「全部 / 关口表 / 普通表」**（2026-10-26 改）：

判定依据是**计量层级** `meterLevel`（设备的 `SERVER_SCOPE` 属性），不是设备档案名：

| 页签 | `meterLevel` | 含义 |
| --- | --- | --- |
| 全部 | —— | 不筛 |
| 关口表 | `1` | 进线总表（站点算费的入口） |
| 普通表 | `2` / `3` / `0` | 分项总表 / 回路表 / 非计量设备（温湿度、虚拟表…） |

为什么要分成这两档：**关口表读数已含下属分项与回路表**。混在一屏时，客户按页签
批量勾选极易把总表和分表一起选进来，聚合就是重复计量（金额虚高 2~3 倍）。

层级怎么拿到的：`GET /api/energy/meters` 随设备档案一次性下发 `meterLevel`，
前端不逐台请求。逐台请求 `device-config` 要几十次往返（实测十几秒，抽屉一直转圈）。
该接口失败时抽屉**照常打开**，所有设备一律当普通表 —— 漏掉分类远不如漏掉设备严重。

```sql
-- 校验：某场站的关口表 / 普通表各几台
SELECT COALESCE(dbl_v::int, 0) AS 计量层级, count(*) AS 台数
FROM device d
JOIN attribute_kv ak ON ak.entity_id = d.id
JOIN key_dictionary kd ON kd.key_id = ak.attribute_key AND kd.key = 'meterLevel'
WHERE d.customer_id = '<客户id>'
GROUP BY 1 ORDER BY 1;
```

```sql
-- 某场站的设备与拓扑视图
SELECT t.name AS 拓扑名, t.type,
       jsonb_array_length(coalesce(t.additional_info::jsonb->'nodes','[]'::jsonb)) AS 节点数
FROM asset t
WHERE t.type = 'topology'
  AND t.additional_info::jsonb->>'siteId' = '<场站id>';
```

---

### 3.13 平台自检

**看什么**：初始化数据缺不缺（11 项）。**不算电量，只数数量**。

```sql
-- 手工复核自检的核心几项（租户 id 自行替换）
-- ① 能源参数字典品种数（期望 4）
SELECT count(*) AS 品种数
FROM asset child
JOIN relation r ON r.to_id = child.id AND r.to_type = 'ASSET'
JOIN asset lib ON lib.id = r.from_id AND lib.type = 'energy_type_library'
WHERE child.tenant_id = '<租户id>' AND child.type = 'default';

-- ② 设备档案里标了 isMeter 的数量（期望 ≥5）
SELECT count(*) AS 表计档案数
FROM device_profile dp
JOIN attribute_kv ak ON ak.entity_id = dp.id
JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
WHERE dp.tenant_id = '<租户id>' AND kd.key = 'isMeter' AND ak.bool_v = true;

-- ③ 计算字段（告警 + 派生指标）条数（期望 11）
SELECT count(*) AS 规则数
FROM calculated_field cf
JOIN device_profile dp ON dp.id = cf.entity_id
WHERE cf.tenant_id = '<租户id>';

-- ④ 费率配置覆盖的品种数（期望 ≥1）
SELECT count(DISTINCT kind) AS 已配价品种 FROM (
    SELECT json_object_keys(ak.json_v) AS kind
      FROM attribute_kv ak JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
      JOIN asset a ON a.id = ak.entity_id
     WHERE a.tenant_id = '<租户id>' AND kd.key = 'energyRates' AND ak.json_v IS NOT NULL
    UNION
    SELECT json_object_keys(ak.json_v)
      FROM attribute_kv ak JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
      JOIN asset a ON a.id = ak.entity_id
     WHERE a.tenant_id = '<租户id>' AND kd.key = 'siteCustomRates'
       AND ak.json_v IS NOT NULL AND ak.json_v::text <> '{}'
    UNION
    SELECT json_object_keys(c.additional_info::json->'energyRates')
      FROM customer c WHERE c.tenant_id = '<租户id>'
) t;
```

---

### 3.14 组织（组织 → 场站 → 设备）

```sql
-- 组织树：组织 → 场站 → 设备数
SELECT o.name AS 组织, s.name AS 场站,
       (SELECT count(*) FROM device d
         WHERE d.additional_info::jsonb->>'siteId' = s.id::text) AS 设备数
FROM asset o
JOIN relation r ON r.from_id = o.id AND r.relation_type = 'Contains'
JOIN asset s ON s.id = r.to_id AND s.type = '场站'
WHERE o.type = '组织' AND o.tenant_id = '<租户id>'
ORDER BY o.name, s.name;
```

**口径提示**：场站归属客户靠 `asset.customer_id`，设备归属场站靠
`additional_info.siteId` —— 这两条不是同一个机制，别混。

---

## 四、AI 功能：算法与数据集格式

「能耗优化」下三项里，**只有负载预测是真的机器学习**，另外两项是规则/统计。

### 4.1 负载预测 —— Prophet（时序分解 + 加法/乘法模型）

**算法**：Meta 的 **Prophet**（`prophet` Python 包，Stan 后端拟合）。

**为什么是这个**（代码注释里的实测对比）：

| 方案 | 优点 | 在这个场景的问题 |
| --- | --- | --- |
| **Prophet** | 容忍缺口、自带日/周/年季节、可加回归量 | 需要足够历史（≥7 天） |
| ARIMA | 统计上严谨 | 对缺失值敏感，缺口要插补 |
| LSTM | 能学复杂模式 | 需要大量数据；现场只有 14 天 |

实测（同一批数据）：朴素基线 MAE 17.34，Prophet MAE 31.49 —— 数据只有强日周期
没有周周期时，Prophet 默认的周季节反而拖累。所以预测结果里**同时给两个基线**，
让用户自己看谁更准，而不是只报模型输出。

**输入数据格式**（两列，DSL 就这两列）：

```python
# Prophet 要求的 DataFrame
   ds          y
2026-10-01 00:00:00   12.34     # ds: 时间戳（小时粒度）
2026-10-01 01:00:00   11.87     # y : 该小时电量（kWh）
...
```

**取数 SQL**（等价于服务内部的查询）：

```sql
SELECT to_timestamp(t.ts/1000) AT TIME ZONE 'Asia/Shanghai' AS ds,
       coalesce(t.dbl_v, t.long_v)                           AS y
FROM ts_kv t
WHERE t.entity_id = '<设备id>'
  AND key = (SELECT key_id FROM key_dictionary WHERE key = 'energy')
  AND t.ts >= 1790784000000 AND t.ts <= 1793462400000   -- 2026-10 全月，按需改
ORDER BY t.ts;
```

**预处理三步**（不做就会得到垃圾结果）：

1. **去重**：同一小时可能有多条（重传），按均值合并。
2. **补缺口**：`resample('h')` 后缺失小时填 NaN，由 Prophet 内部处理。
3. **数据质量筛查**（`quality.py`）：
   - 点数 < 预期 30% → 该实体剔除
   - 中位采样间隔与其他实体差 3 倍以上 → 多实体聚合时剔除

> 这一步不是可选的。实测：40 台设备里有 27 台只有 1 个数据点（月粒度虚拟表），
> 混进来做 `sum` 会把整月累计值加到 1 个小时上，造出 20150 的假尖峰
> （其余时刻合计只有 188），峰均比虚高 87 倍。

**输出**：

```json
{ "ds": "2026-10-24 00:00:00", "yhat": 12.1, "yhat_lower": 9.8, "yhat_upper": 14.6 }
```

**接口**：`POST /ngxapi/biz/forecast`（客户侧）、`POST /ngxapi/forecast/run`（租户侧）

---

### 4.2 用能建议 —— 规则引擎（**不是**机器学习）

**算法**：确定性规则 + 统计阈值。每类建议的判据：

| 建议类型 | 判据 | 数据要求 |
| --- | --- | --- |
| 峰谷转移 `peak_shift` | 峰段用电占比 + 谷段闲置容量 | 小时粒度 ≥7 天 |
| 待机损耗 `standby_loss` | 非生产时段仍有持续负荷（可削减 60%） | 小时粒度 ≥14 天 |
| 需量控制 `demand_control` | 最大需量出现时刻 + 负荷曲线 | 小时粒度 ≥30 天 |
| 同类对比 `peer_gap` | 同 profile 设备的单位产出能耗 | ≥3 台同类 |
| 异常处置 `anomaly_action` | 异常检测的持续偏差 | 异常检测结果 |
| 容量利用 `capacity` | 峰值 / 变压器容量 | 需提供容量参数 |

**为什么用规则不用模型**：每条建议必须带「触发依据 + 量化影响 + 可执行动作 +
置信度」。模型给不出可解释的依据时，运维看完不知道做什么。

**输入数据**：小时粒度电量序列（同 4.1）+ 场站工业时段配置。
**最少点数**：24（一天的日周期都覆盖不全，任何结论都站不住）。

**接口**：`POST /ngxapi/biz/advice`（客户侧）、`POST /ngxapi/advice/run`（租户侧）

> 两个入口共用同一个执行器（`advice_engine.py`）——
> 各写一遍必然出现「同一批数据在租户页和客户页得出不同建议」。

---

### 4.3 用能质量 —— 统计诊断（**不是**机器学习）

**算法**：数据质量诊断 + 统计量（峰均比、标准差、变异系数）。

**判据**（只看两条客观事实，不按数值大小剔除）：

1. **点数太少**：目标窗口内点数 < 预期点数的 30%
2. **粒度不一致**：该实体中位采样间隔与其他实体差 3 倍以上
   （只在多实体聚合时启用 —— 求和场景特有）

**输出**：每个实体的 `points` / `interval` / `score`，以及整体可用性结论。

**接口**：`GET /ngxapi/biz/quality`

---

## 五、埋点：日志里的可复制 SQL

平台在关键统计接口上打了 **SQL 埋点**，日志里能直接拿到执行过的
等价 SQL（参数已代入），复制到 psql 就能和页面数字对照。

### 5.1 怎么用

```bash
# 实时看（跟着点页面，日志就会输出）
docker logs -f energy-server 2>&1 | grep -A40 "SQL 埋点"

# 只看某个功能
docker logs energy-server 2>&1 | grep -A40 "SQL 埋点 \[峰谷分析\]"
docker logs energy-server 2>&1 | grep -A40 "SQL 埋点 \[抄表台账\]"
docker logs energy-server 2>&1 | grep -A40 "SQL 埋点 \[我的账单"

# 从日志文件（生产 profile 按天落盘）
grep -A40 "SQL 埋点" ~/energy-app/logs/guard-server.log
```

输出长这样：

```
╔══ SQL 埋点 [峰谷分析] GET /api/energy/tou-analysis
║ ⚠ 本埋点用于页面结果与 SQL 结果对照：未经用户同意不得删除；…
║ 参数: scopeType=device, scopeId=66fa…, granularity=day, from=1792…, to=1792…
║ ── 可复制 SQL（参数已代入）──
║ -- (1/3) -- ① 原始小时表底…
║ SELECT entity_id, …
╚════════════════════════════════════════════════════════════════
```

`║ ` 前缀是日志装饰，复制时去掉即可（或用 `sed 's/^║ //'`）。

### 5.2 已覆盖的接口

| 功能 | 接口 | 埋点内容 |
| --- | --- | --- |
| 峰谷分析 | `GET /api/energy/tou-analysis` | ① 小时表底 ② 逐小时用量 ③ 两个口径的区间总量 |
| 抄表台账 | `GET /api/energy/meter-reading/ledger` | 台账主查询（与实现同一份 SQL 文本） |
| 我的账单 | `GET /api/energy/billing/summary` | 账单明细 + 四项和 |
| 出账 | `POST /api/energy/billing/generate` | 落库后的账单 + 汇总口径 |
| 设备计量配置 | `POST /api/energy/device-config` | 写入后的层级/倍率属性 |

### 5.3 开关

```yaml
# 默认 true。关掉会让页面数字无法用 SQL 复核，只在日志噪音影响排查时临时关
energy:
  sql-trace:
    enabled: true
```

### 5.4 ⚠ 给维护者的约定（写在代码注释里）

> **未经用户明确同意，不得删除任何 `SqlTrace.trace(...)` 调用**，
> 也不得为「日志干净」「性能」把它注释掉或降级。
>
> **埋点 SQL 与实现不一致属于缺陷**，可以并且应该更新 ——
> 更新时保证：参数代入方式不变、仍可直接复制执行。
>
> **新增统计接口时必须补埋点**，否则用户无法自行核对数据。

代码位置：`guard-server/src/main/java/com/guard/server/util/SqlTrace.java`（类头有完整约定）。

### 5.5 ⚠ 自绘部件与实时刷新的两条约定

**1）自绘部件必须声明 `self.typeParameters`。**

用 `self.ctx.http` 自己取数的部件（本平台 `energy_management_*` 绝大多数都是），
必须在脚本开头声明：

```js
self.typeParameters = function () {
  return { datasourcesOptional: true, processNoDataByWidget: true, dataKeysOptional: true };
};
```

否则 TB 在「数据源没解析成功」时会**跳过 `onInit`**，页面只显示「部件无数据可显示」。
客户看板里的别名可能指向租户级占位符（`00000000-…`），解析必然失败。
排查与修复见 `05-troubleshoot.md` 现象 Y。

**2）有副作用的结果部件靠 `runId` 判断「用户是否真的点了按钮」。**

`query_panel` 的 `emitRunId=true` 时，每次提交会带一个 `runId`；
结果部件只在收到**新 runId** 时才执行（抄表就是这么做的：
`meter_reading_board` 看到新 runId 才下发 RTU 采集并写库）。

约定：**自动提交（首屏 / 切场站 / 实时轮询）不生成 runId**，
只有用户点「查询」按钮才生成。内部调用必须写成 `scope.submit(true)`。

2026-10-26 修过一个真实缺陷：自动提交也生成 runId，导致**打开抄表页面
就抄了一遍表**（实测三分钟三次打开 → 写了 3 批 18 条 `meter_reading_record`）。
现在首屏空态显示「请在左侧查询设置中选好范围与指标，然后点一键抄表」，
不再偷偷写库。

**3）`refreshSecs` 不低于 10 秒。**

实时部件一轮刷新 = 每台设备一个 telemetry 请求。3 秒一轮会把浏览器的
6 条连接占满，导致切场站后重建设备树要排队十几秒（现象 X）。
看板模板里两个实时部件（`realtime_kpi` / `realtime_trend`）统一填 `10`，
部件代码也会把下限卡在 8 秒。

---

## 六、常见对不上账的四种情况

| 现象 | 真实原因 | 怎么确认 |
| --- | --- | --- |
| 页面电量 > 台账 | 页面按逐小时增量累加，台账按账期首末差 | 看 `backwardSegments` 是否 > 0 |
| 全表合计是应付的 1.8 倍 | 总表 + 分表相加了同一度电 | 看 `meterLevel` 是否配齐（3.7 节） |
| 账单金额是 0 | 该品种没配电价 / 表底不足两点 | `POST /billing/generate` 带 `dryRun` 看 `reason` |
| 虚拟表查不到表底 | 虚拟表本来就没有 `energy_reading` | 查 `energy` 月首点（3.8 节） |
| 峰谷全 0 | 表没挂场站 → 解析不到时段方案 | 看 `device.additional_info.siteId` |
