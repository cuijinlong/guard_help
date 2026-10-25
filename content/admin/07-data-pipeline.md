# 数据流处理：从 RTU 上报到页面数字

这一页回答运维最常问的四个问题：

1. **一级 / 二级 / 三级计量**——怎么配、怎么生效、配错了什么后果
2. **倍率（CT × PT）**——存在哪、怎么算、什么情况会算错
3. **「表的总数」还是「增量」**——两个键的语义，为什么不能混用
4. **各厂家指标名不一样**——怎么转成平台标准名

最后给出完整的**端到端数据流**，以及每一步的**校验 SQL**。

---

## 一、全景：一条数据从 RTU 到页面的八步

```
┌─────────────────────────────────────────────────────────────────────┐
│ ① RTU / 网关                                                        │
│    上报厂家原始代号：{"U":220.1,"I":15.2,"P":3.3,"Ep":33705.42}      │
│    走 MQTT:1883 或 HTTP:8090/api/v1/<token>/telemetry                │
└───────────────────────────────┬─────────────────────────────────────┘
                                ↓
┌─────────────────────────────────────────────────────────────────────┐
│ ② 规则链「电表Key标准化」节点                                        │
│    U→voltage_a  I→current_a  P→power_total  Ep→energy_reading        │
│    原始键名留在 metadata.rawKeys 里（可追溯）                         │
└───────────────────────────────┬─────────────────────────────────────┘
                                ↓
┌─────────────────────────────────────────────────────────────────────┐
│ ③ ts_kv 落库                                                        │
│    key   = key_dictionary.key_id（整数！）                           │
│    ts    = 毫秒时间戳                                                │
│    dbl_v = 数值（绝大部分遥测）                                       │
└───────────────────────────────┬─────────────────────────────────────┘
                                ↓
┌─────────────────────────────────────────────────────────────────────┐
│ ④ 计算字段（设备档案上，同档案设备自动继承）                          │
│    energy_day / energy_flat / load_rate / voltage_unbalance /        │
│    carbon / idle_exceed → 再写回 ts_kv 或触发告警                    │
└───────────────────────────────┬─────────────────────────────────────┘
                                ↓
┌─────────────────────────────────────────────────────────────────────┐
│ ④b 资产汇总（AssetTotalsScheduler，默认每小时一轮）                   │
│    设备 energy → 资产 energy_total / energy_day / power_total         │
│    ★ 平台不会在每次上报时自动汇总到资产；这一步是场站页、分项页、      │
│      概览页「有数」的唯一来源。详见第六节。                            │
└───────────────────────────────┬─────────────────────────────────────┘
                                ↓
┌─────────────────────────────────────────────────────────────────────┐
│ ⑤ 统计接口（guard-server /api/energy/*）                             │
│    读 ts_kv + device 属性（倍率、层级）→ 聚合 → 返回                 │
│    每次调用输出 SQL 埋点（日志里可复制）                              │
└───────────────────────────────┬─────────────────────────────────────┘
                                ↓
┌─────────────────────────────────────────────────────────────────────┐
│ ⑥ 页面（看板 / 自建页面 / AI 页面）                                  │
│    看板部件直接查 ts_kv；自建页面调 /api/energy/*                     │
└───────────────────────────────┬─────────────────────────────────────┘
                                ↓
┌─────────────────────────────────────────────────────────────────────┐
│ ⑦ 账（可选）：抄表记录 → 账单资产                                    │
│    meter_reading_record（凭证）→ energy_bill 资产（客户可见）         │
└─────────────────────────────────────────────────────────────────────┘
```

**关键点**：③ 之后所有环节都**只读 ts_kv**，不再碰原始上报报文。
所以「页面数字不对」时，先确认 ③ 里到底存了什么（用第一节的 SQL），
再往上查 ④⑤。

---

## 二、问题一：一级 / 二级 / 三级计量

### 2.1 平台怎么表达层级

**一个属性：`meterLevel`**，写在 `device` 的 SERVER_SCOPE：

| 值 | 含义 | 典型设备名 |
| --- | --- | --- |
| `1` | 进线总表（关口表） | 「1#进线总表」「综合配电表」 |
| `2` | 分项总表 | 「车间动力总表」「照明分项总表」 |
| `3` | 回路（末端） | 「空压机组」「A栋照明回路」 |
| `0` / 未设置 | 未声明 | —— |

**存储**：

```sql
-- 看某台设备的层级
SELECT d.name AS 设备,
       (SELECT coalesce(ak.dbl_v, ak.long_v, ak.str_v::numeric)
          FROM attribute_kv ak
          JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
         WHERE ak.entity_id = d.id
           AND ak.attribute_type = 2          -- 2 = SERVER_SCOPE
           AND kd.key = 'meterLevel') AS 层级
FROM device d
WHERE d.name = '单相园-1#进线总表·星河工业园';
```

### 2.2 它在哪些地方生效

| 场景 | 规则 | 不配的后果 |
| --- | --- | --- |
| 账单·基本电费 | 只对 `level=1` 收 | 11 台表各收 1600 元，高一个数量级 |
| 账单·力调电费 | 只对 `level=1` 算 | 同上 |
| 台账汇总 | 有 `level=1` 时只汇总进线 | 总表 + 分表相加，同一度电算两遍 |
| 账单汇总 `totalAmount` | 同上 | 应付金额虚高（实测 2.8 倍） |
| 闲时能耗合计 | 只取「集合里没有上级」的表 | 场站合计翻倍 |

### 2.3 怎么配

**方式一：页面**（推荐）

组织与场站 → 选中场站 → 设备面板 → 「计量层级」下拉。

**方式二：接口**

```bash
# 读
curl --noproxy '*' -s -H "X-Authorization: Bearer $TOKEN" \
  "http://127.0.0.1:8090/api/energy/device-config?deviceId=<设备id>"

# 写（只传要改的字段，未传的不动）
curl --noproxy '*' -s -X POST \
  -H "X-Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"deviceId":"<设备id>","meterLevel":1}' \
  http://127.0.0.1:8090/api/energy/device-config
```

返回里带 `meterLevelName` 和 `effectiveRatio`，配完立刻能看到生效值。

### 2.4 怎么验证层级配对了

**方法一：看守恒**——父表电量必须 ≥ 子表之和（差额 = 线损 + 未装表）：

```sql
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
      AND t.ts >= 1790784000000 AND t.ts < 1793462400000   -- 2026-10，按需改
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

- **差额为正**：正常（线损 + 未装表负荷）
- **差额为负**：父子关系配错，或某台表被重复计算 → 立刻查
- **差额为 0 且比例恰好等于配置系数**：演示数据的正常表现

**方法二：看汇总口径**

```sql
-- 台账汇总（应等于页面 totals）
WITH bill AS (
    SELECT a.id,
           max(CASE WHEN kd.key='energy'     THEN ak.str_v END) AS energy,
           max(CASE WHEN kd.key='meterLevel' THEN coalesce(ak.dbl_v, ak.str_v::numeric) END) AS lvl,
           max(CASE WHEN kd.key='usage'      THEN coalesce(ak.dbl_v, ak.str_v::numeric) END) AS usage,
           max(CASE WHEN kd.key='amount'     THEN coalesce(ak.dbl_v, ak.str_v::numeric) END) AS amount
    FROM asset a
    JOIN attribute_kv ak ON ak.entity_id = a.id AND ak.attribute_type = 2
    JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
    WHERE a.type = 'energy_bill' AND a.tenant_id = '<租户id>'
      AND a.name LIKE 'BILL-%<账期>%'
    GROUP BY a.id
), top AS (SELECT DISTINCT energy FROM bill WHERE lvl = 1)
SELECT b.energy AS 品种,
       count(*) AS 表数,
       round(sum(b.usage)::numeric, 4) AS 全表用量,
       round(sum(CASE WHEN b.lvl = 1 OR t.energy IS NULL THEN b.usage ELSE 0 END)::numeric, 4) AS 汇总用量
FROM bill b LEFT JOIN top t ON t.energy = b.energy
GROUP BY b.energy;
```

---

## 三、问题二：倍率（CT × PT）

### 3.1 四个字段

| 属性 | 例 | 含义 |
| --- | --- | --- |
| `ctRatio` | `200/5` | 电流互感器变比 |
| `ptRatio` | `10000/100` | 电压互感器变比 |
| `meterRatio` | `4000` | 综合倍率（**兜底**，CT/PT 都空时才用） |
| `ratioApplied` | `false` | 遥测是否**已经是折算值** |

**存储**：`device` 的 SERVER_SCOPE 属性。

### 3.2 计算规则（`MeteringMath.effectiveRatio`）

```
ratioApplied = true   →  计算系数 = 1
                          （RTU 已经乘过倍率，再乘就重复）

CT/PT 都为空          →  计算系数 = meterRatio（综合倍率）
                          否则填了综合倍率却不生效

其余情况              →  计算系数 = CT × PT
                          例：200/5 × 10000/100 = 40 × 100 = 4000
```

**为什么 CT/PT 优先于 `meterRatio`**：CT/PT 信息更完整（能看出变比来源与用途），
且是「基础配置中心 › 设备倍率」与「组织与场站 › 设备档案」共同填的那两个字段。
两者都填时以变比为准，避免两个来源打架。

### 3.3 用量怎么算

```
用量 = (本期表底 − 上期表底) × 计算系数
```

**不是** `表底 × 系数`。表底本身是「二次侧累计读数」，乘系数才是一次侧电量。

```sql
-- 验算：某设备某段区间的用量（含倍率）
--
-- 注意：倍率三个字段都可能是空串（没配）。直接 ::numeric 会报
--       `invalid input syntax for type numeric: ""`，所以先用正则守卫。
WITH dev AS (
    SELECT id, name FROM device WHERE name = '单相园-1#进线总表·星河工业园'
), cfg AS (
    SELECT d.id,
           (SELECT coalesce(ak.str_v,'') FROM attribute_kv ak
              JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
             WHERE ak.entity_id = d.id AND ak.attribute_type = 2 AND kd.key = 'ctRatio') AS ct,
           (SELECT coalesce(ak.str_v,'') FROM attribute_kv ak
              JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
             WHERE ak.entity_id = d.id AND ak.attribute_type = 2 AND kd.key = 'ptRatio') AS pt,
           (SELECT coalesce(ak.str_v,'') FROM attribute_kv ak
              JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
             WHERE ak.entity_id = d.id AND ak.attribute_type = 2 AND kd.key = 'meterRatio') AS mr,
           (SELECT coalesce(ak.bool_v,false) FROM attribute_kv ak
              JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
             WHERE ak.entity_id = d.id AND ak.attribute_type = 2 AND kd.key = 'ratioApplied') AS applied
    FROM dev d
), ratio AS (
    SELECT ct, pt, mr, applied,
           CASE
             WHEN applied THEN 1::numeric
             -- 综合倍率兜底：CT/PT 都空时才用
             WHEN ct = '' AND pt = '' AND mr ~ '^[0-9]+(\.[0-9]+)?$' THEN mr::numeric
             ELSE
               -- CT/PT 都按 "一次/二次" 解析；缺项按 1 处理
               (CASE WHEN split_part(ct,'/',1) ~ '^[0-9]+(\.[0-9]+)?$'
                      AND split_part(ct,'/',2) ~ '^[0-9]+(\.[0-9]+)?$'
                     THEN split_part(ct,'/',1)::numeric / nullif(split_part(ct,'/',2),'0')::numeric
                     ELSE 1 END)
             * (CASE WHEN split_part(pt,'/',1) ~ '^[0-9]+(\.[0-9]+)?$'
                      AND split_part(pt,'/',2) ~ '^[0-9]+(\.[0-9]+)?$'
                     THEN split_part(pt,'/',1)::numeric / nullif(split_part(pt,'/',2),'0')::numeric
                     ELSE 1 END)
           END AS 计算系数
    FROM cfg
), pts AS (
    SELECT max(coalesce(t.dbl_v, t.long_v)) - min(coalesce(t.dbl_v, t.long_v)) AS delta
    FROM ts_kv t
    WHERE t.entity_id = (SELECT id FROM dev)
      AND t.key = (SELECT key_id FROM key_dictionary WHERE key = 'energy_reading')
      AND t.ts >= 1790784000000 AND t.ts < 1793462400000
)
SELECT ct, pt, mr, applied, 计算系数,
       round(p.delta::numeric, 4) AS 表底差,
       round((p.delta * 计算系数)::numeric, 4) AS 用量
FROM ratio, pts p;
```

> **SQL 写法坑（实测 2026-10-23）**：`nullif(x,'')::numeric` 会报
> `invalid input syntax for type numeric: ""` —— 因为 `::` 只绑定到 nullif 的
> **第二个参数** `''`，等价于 `nullif(x, ''::numeric)`。
> 必须写成 `(nullif(x,''))::numeric`（把 nullif 整个括起来）。
> 空字符串转数值是现场数据最常见的脏数据形态，这个坑值得记牢。

### 3.4 三种典型错误

| 错误 | 表现 | 怎么发现 |
| --- | --- | --- |
| 该乘没乘 | 用量偏小 4000 倍（几乎为 0） | 抄表台账用量与现场电表读数差一个数量级 |
| 乘了两次 | 用量偏大 4000 倍（天文数字） | RTU 已乘过 + `ratioApplied` 还是 `false` |
| CT/PT 填反 | 偏差 40/100 倍 | 检查是否把 `10000/100` 填进了 `ctRatio` |

**自查 SQL**（找出没配倍率但明显是大表的设备）:

```sql
SELECT d.name AS 设备,
       (SELECT coalesce(ak.str_v,'') FROM attribute_kv ak
          JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
         WHERE ak.entity_id = d.id AND ak.attribute_type = 2 AND kd.key = 'ctRatio') AS ct,
       (SELECT coalesce(ak.str_v,'') FROM attribute_kv ak
          JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
         WHERE ak.entity_id = d.id AND ak.attribute_type = 2 AND kd.key = 'meterRatio') AS 综合倍率
FROM device d
WHERE d.tenant_id = '<租户id>'
  AND d.name LIKE '%进线%'
ORDER BY d.name;
```

进线表如果 CT/PT 和综合倍率都为空 → 基本可以确定没配倍率（大表不可能没有互感器）。

---

## 四、问题三：「表的总数」还是「增量」

### 4.1 两个键，两个语义

平台用**两个不同的键**表达两件事，绝不能混用：

| 键 | 语义 | 示例值 | 特点 |
| --- | --- | --- | --- |
| `energy` | **本小时用电量（增量）** | 0.5 / 0.5049 / 1.0195 | 与 `power_total` 同量级 |
| `energy_reading` | **累积表底（单调递增）** | 33705.42 / 33705.93 / 33706.43 | 只增不减 |

**恒等式**（演示数据与真实设备都必须满足）：

```
energy_reading[n] − energy_reading[n−1] == energy[n]
```

### 4.2 为什么必须两个都存

- 只存 `energy`：能算区间电量，但**算不出账期累计**（边界受查询范围影响）
- 只存 `energy_reading`：能算差值，但**看不出每小时分布**（峰谷拆不出来）
- 两个都存：互相校验，任一个出错都能被发现

### 4.3 用量一律用「表底差」，不用 `sum(energy)`

| 口径 | 公式 | 用在哪 |
| --- | --- | --- |
| 表底差 | `末点 − 首点` × 系数 | 台账、账单、峰谷总量 |
| 增量累加 | `Σ energy` | 页面逐小时柱状图 |

**为什么主口径选表底差**：

- `energy[t]` 覆盖 `(t−1h, t]`，用 `>= from` 取点会把账期首小时多算进来
- 表底差与峰谷分析、账单同源，三个页面的数天然对得上
- 换表/补录时表底差仍然自洽（只要新表底是接着涨的）

**什么时候两者会差**：表底倒走（换表 / 归零 / 报错值）。
算法跳过倒走段，于是 `Σ正增量 < 首末差`。

```sql
-- 一次看清两个口径 + 倒走段数
WITH pts AS (
    SELECT (ts / 3600000) * 3600000 + 1800000 AS bucket_center_ms,
           max(coalesce(dbl_v, long_v))       AS reading
    FROM ts_kv
    WHERE entity_id = '<设备id>'
      AND key = (SELECT key_id FROM key_dictionary WHERE key = 'energy_reading')
      AND ts > 1790780400000 AND ts <= 1793462400000   -- 起点前一小时 ~ 期末
    GROUP BY ts / 3600000
), diff AS (
    SELECT bucket_center_ms, reading,
           reading - lag(reading) OVER (ORDER BY bucket_center_ms) AS inc
    FROM pts
)
SELECT count(*) AS 点数,
       min(reading) AS 首表底, max(reading) AS 末表底,
       round((max(reading)-min(reading))::numeric, 4)                          AS 首末差,
       round(sum(CASE WHEN inc >= 0 THEN inc ELSE 0 END)::numeric, 4)          AS 正增量累加,
       count(*) FILTER (WHERE inc < 0)                                         AS 倒走段数
FROM diff;
```

### 4.4 自检：两个键必须逐点自洽

```sql
-- 找出不自洽的点（期望 0 行）
WITH e AS (
    SELECT ts, coalesce(dbl_v, long_v) AS v
    FROM ts_kv
    WHERE entity_id = '<设备id>'
      AND key = (SELECT key_id FROM key_dictionary WHERE key = 'energy')
), r AS (
    SELECT ts, coalesce(dbl_v, long_v) AS v,
           coalesce(dbl_v, long_v) - lag(coalesce(dbl_v, long_v)) OVER (ORDER BY ts) AS delta
    FROM ts_kv
    WHERE entity_id = '<设备id>'
      AND key = (SELECT key_id FROM key_dictionary WHERE key = 'energy_reading')
)
SELECT to_char(to_timestamp(e.ts/1000) AT TIME ZONE 'Asia/Shanghai','MM-DD HH24:MI') AS 时间,
       e.v AS energy,
       round(r.delta::numeric, 4) AS 表底差
FROM e JOIN r ON r.ts = e.ts
WHERE r.delta IS NOT NULL
  AND abs(e.v - r.delta) > 0.01;
-- 说明：lag() 是窗口函数，不能直接写在 WHERE 里，
--       所以在 CTE 里先算好 delta 再过滤。
```

### 4.5 各厂家上报的可能是哪一种

| 厂家习惯 | 上报内容 | 接入时怎么办 |
| --- | --- | --- |
| 上报累积表底（Ep） | 33705.42 递增 | 直接映射到 `energy_reading`；`energy` 由计算字段或平台算 |
| 上报小时增量 | 0.5 / 0.51 | 映射到 `energy`；**不要**映射到 `energy_reading` |
| 两者都报 | 都有 | 各归各位，然后用 4.4 的 SQL 验自洽 |

**判定方法**：看一台设备连续几个点，数值一直涨 → 累积；上下波动 → 增量。

```sql
-- 判定某键是累积还是增量
SELECT to_char(to_timestamp(ts/1000) AT TIME ZONE 'Asia/Shanghai','MM-DD HH24:MI') AS 时间,
       coalesce(dbl_v, long_v) AS 值
FROM ts_kv
WHERE entity_id = '<设备id>'
  AND key = (SELECT key_id FROM key_dictionary WHERE key = '<键名>')
ORDER BY ts DESC LIMIT 20;
```

---

## 五、问题四：各厂家指标名不一样

### 5.1 平台标准名（真相源是字典）

标准键名定义在**能源参数字典**里（租户级资产 `type='default'` 的子节点）。
报表、看板、统计接口全部按这些名字取数。

常用电能键：

| 标准键 | 含义 | 单位 |
| --- | --- | --- |
| `voltage_a/b/c`、`voltage_avg` | 分相/平均电压 | V |
| `current_a/b/c`、`current_avg` | 分相/平均电流 | A |
| `power_total` | 有功总功率 | kW |
| `reactive_power_total` | 无功总功率 | kvar |
| `apparent_power_total` | 视在功率 | kVA |
| `power_factor_total` | 功率因数 | — |
| `frequency` | 频率 | Hz |
| `energy` | 小时电量（增量） | kWh |
| `energy_reading` | 累积表底 | kWh |
| `load_rate` | 负荷率 | % |
| `voltage_unbalance` | 三相不平衡度 | % |

完整清单见 `admin/03-init.md`「三、能源参数字典」。

### 5.2 转换机制：规则链节点

**位置**：根规则链 → `Message Type Switch` → **`电表Key标准化`** → `Save Timeseries`

**脚本**（平台内置，随建客户自动部署）：

```javascript
var MAP = {
  "U":    "voltage_a",
  "I":    "current_a",
  "P":    "power_total",
  "Q":    "reactive_power_total",
  "S":    "apparent_power_total",
  "PF":   "power_factor_total",
  "Freq": "frequency",
  "Ep":   "energy_reading"
};
// 未命中 MAP 的键原样保留（不会丢数据）
// 发生改名时，原始键名写进 metadata.rawKeys
```

### 5.3 存储位置（三处，别找错）

| 内容 | 存在哪 |
| --- | --- |
| 转换脚本 | `rule_node` 表，节点名「电表Key标准化」，`configuration.jsScript` |
| 标准键定义 | 能源参数字典（`asset` + `relation`），`type='default'` 的子节点 |
| 设备实际上报的键 | `ts_kv` + `key_dictionary` |

```sql
-- 看转换脚本当前内容
SELECT n.name AS 节点, n.type AS 类型,
       n.configuration::jsonb->>'jsScript' AS 脚本
FROM rule_node n
JOIN rule_chain rc ON rc.id = n.rule_chain_id
WHERE n.name = '电表Key标准化';

-- 看某设备上报了哪些键（用来判断映射是否生效）
SELECT kd.key AS 键名, count(*) AS 点数,
       to_char(to_timestamp(max(t.ts)/1000) AT TIME ZONE 'Asia/Shanghai','MM-DD HH24:MI') AS 最后上报
FROM ts_kv t
JOIN key_dictionary kd ON kd.key_id = t.key
WHERE t.entity_id = '<设备id>'
GROUP BY kd.key ORDER BY 点数 DESC;
```

### 5.4 怎么发现「映射没生效」

**症状**：`ts_kv` 里存的是 `U` / `I` / `P` / `Ep` 这种原始代号，报表全空。

```sql
-- 找字典里没有的键（大概率是没映射的原始代号）
SELECT kd.key AS 可疑键, count(*) AS 点数,
       count(DISTINCT t.entity_id) AS 设备数
FROM ts_kv t
JOIN key_dictionary kd ON kd.key_id = t.key
WHERE kd.key !~ '^(voltage|current|power|energy|reactive|apparent|frequency|load_rate|carbon|idle|demand|temperature|humidity|co2|pressure|flow|level|status|alarm|lastReading|manualEntry|meterLevel|ct|pt|ratio)'
  AND length(kd.key) <= 12
GROUP BY kd.key ORDER BY 点数 DESC LIMIT 30;
```

**修法**：

1. 打开「平台自检」→ 看「电表 Key 标准化节点」是否 OK
2. 不 OK 就点「一键修复初始化」（幂等，不会重复加节点）
3. 节点在但仍不生效 → 检查连线：`Switch --Post telemetry--> 标准化 --Success--> Save Timeseries`，
   且**不能**有 `Switch --Post telemetry--> Save Timeseries` 直连（会让原始代号照样落库）

```bash
# 节点与连线的完整判定由平台自检接口给出（节点在 / 脚本最新 / 两条连线 / 无直连）
curl --noproxy '*' -s -H "X-Authorization: Bearer $TOKEN" \
  "http://127.0.0.1:8090/api/energy/self-check" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); \
      print([x for x in d['items'] if 'Key' in x['name'] or 'key' in x['code']])"
```

> 更可靠的做法是看「平台自检」接口，它用 `isMeterKeyTransformReady()` 一次判全：
> 节点在、脚本是最新版、两条连线齐全、无直连。

### 5.5 厂家映射表怎么加

现场厂家代号不在内置 8 个里（比如 `VolA` / `Ia` / `kWh`）：

**方式一：改设备的「测点管理」（推荐，按设备配）**

组织与场站 → 选中场站 → 设备面板 → 测点管理，把厂家字段映射到标准键。
存在设备 SERVER_SCOPE 属性里，只影响这台设备。

**方式二：改规则链脚本（按租户配，影响所有设备）**

规则链 → 根规则链 → `电表Key标准化` → 编辑脚本 → 在 `MAP` 里加一行：

```javascript
var MAP = {
  "VolA": "voltage_a",     // ← 新增
  "kWh":  "energy_reading",// ← 新增
  "U": "voltage_a", /* …原有… */
};
```

保存后运行时立即重载，**不用重启**。

> ⚠ 改了脚本后，**平台自检会报「节点脚本不是最新版」** ——
> 因为自检比对的是平台内置版本。这是预期的：
> 自检的「一键修复」会把脚本改回内置版，覆盖你的自定义。
> 所以：**按租户改脚本后，不要再点一键修复**；要保留自定义就改用「测点管理」按设备配。

---

## 六、设备有数、页面却是 0：资产汇总与部件取数

这一节对应一个很具体的现象：

> 客户登录后，设备列表里看得见数据，但「能耗概览」四张卡片全是 `0.0`，
> 日历热力图写着「所选范围内无数据」，或者部件一直停在「加载中…」。

它有**两个独立成因**，必须分开查 —— 混在一起会白折腾半天：

- **成因 A：资产上没有汇总值**。设备有 `energy`，但场站/分项资产没有 `energy_total`。
- **成因 B：部件把「品种资产」当成了取数实体**。品种资产没有遥测，查出来必然是空。

2026-10-23 这两条同时命中，所以「接口全 200、页面全 0」。

---

### 6.1 三层数据，三个不同的键名

页面上的数字来自三个层级，键名不一样，混用就会查不到：

```
┌──────────────────────────────────────────────────────────────┐
│ 设备层  DEVICE                                                │
│   energy          本小时增量（kWh）        ← RTU 上报         │
│   energy_reading  累积表底（单调递增）      ← RTU 上报         │
│   energy_day      当日累计                 ← 计算字段         │
└───────────────────────────┬──────────────────────────────────┘
                            │  ④b 资产汇总（每小时，见 6.2）
                            ↓
┌──────────────────────────────────────────────────────────────┐
│ 资产层  ASSET（场站 / 分项 / 组织）                            │
│   energy_total    该资产下所有表的本小时合计                   │
│   energy_day      当日累计                                    │
│   power_total     合计功率（仅电）                             │
│   water_total / gas_total / steam_total（按品种分开）          │
└───────────────────────────┬──────────────────────────────────┘
                            │  不汇总，也不采集
                            ↓
┌──────────────────────────────────────────────────────────────┐
│ 品种层  ASSET（电能 / 水表 / 燃气 / 蒸汽）                     │
│   只有 paramDict 属性（指标名、单位、参数定义）                │
│   ★ 没有任何遥测 —— 它是「维度节点」，不是「计量点」           │
└──────────────────────────────────────────────────────────────┘
```

一句话记住：**设备读 `energy`，资产读 `energy_total`，品种什么都不读。**

---

### 6.2 资产汇总从哪来（谁写、何时写）

平台**不会**在每次设备上报时自动汇总到资产 —— 根规则链里没有这种节点。
汇总由一个定时任务批量算：

```
AssetTotalsScheduler（guard-server）
  每 1 小时一轮，启动后延迟 5 分钟
    ↓
  rebuildAssetTotals(tenantId, customerId, backfillDays=2)
    ↓  按「设备 → 所属场站 / 分项 / 组织 / 维度容器」分组
    ↓  组内同品种只取 meterLevel 最小者（避免总表 + 分表重复计电）
    ↓  按 ts 覆盖写 energy_total / energy_day / power_total
```

**维度容器也要写**：`用电分项 / 用能区域 / 用能性质 / 空间位置` 四个维度下，
每个场站都有一个「场站分组」节点。它没有 `Contains` 关系，靠 SERVER_SCOPE 的
`siteId` 属性指向场站（与设备同一口径）。不写这些节点，**区域能耗 / 综合能耗 /
能源流向**三个页面就是整页空白 —— 而同一页的排名部件走设备级数据，照样有数，
看起来就像图表坏了。

**为什么不用规则链**：规则链是逐条消息触发的，一台表每小时一个点，
一次汇总要读该场站下**全部**表的历史。逐条触发等于每点都全量重算，
代价随表数量平方增长。定时批处理按小时算一次，与表数量线性相关。

**开关**（`application.yml` 或环境变量）：

```properties
energy.asset-totals.refresh.enabled=true          # 关掉就退回手工重算
energy.asset-totals.refresh.initial-delay-ms=300000
energy.asset-totals.refresh.interval-ms=3600000
```

**手工触发**（客户也能调，只影响自己）：

```bash
# 客户或租户 token 均可
curl -s -X POST -H "X-Authorization: Bearer $TOKEN" \
  'http://127.0.0.1:8090/api/energy/asset-totals/rebuild' \
  -H 'Content-Type: application/json' -d '{"days":2}'
# → {"assetsWritten": 25}      ← 随客户资产规模变化（分项 + 维度容器 + 组织）
```

**窗口必须对齐整天**：`rebuildAssetTotals` 的起点是「今天 00:00 往前推 N−1 天」，
不是「现在往前推 N 天」。因为 `energy_day` 是当日累计，从窗口里第一个点开始加 ——
窗口若从某天中途开始，那天的 `energy_day` 会少算前半段。

---

### 6.3 部件怎么选取数实体（成因 B 的根源）

三个部件 `overview_stats` / `calendar_heatmap` / `asset_stats_chart` 都用同一套
`resolveEntity()` 选目标。**正确顺序**是：

```
① state.treeNode（用户在分析范围树里点选的节点）
② state.entityId（状态实体）
③ 部件数据源别名 alias（场站 / 分项）
```

品种资产只用来提供**指标名和单位**（读 `paramDict`），**不能当取数目标**。
两个原因：

1. 它没有遥测 —— 拿它查 `energy_total` 返回 `{}`，页面就是 0；
2. 它的 `Contains` 子节点**横跨同租户下所有客户** —— 遍历子树会读到别家的分项。

> 历史版本把品种放在优先级第一（`targetMode=kind`），于是「接口 200 + 空对象」
> 被当成正常，页面四张卡全 0。这是 2026-10-23 修复的核心。

**统计图还要再下一层**：选中节点是「维度根 / 场站分组」这类**组织节点**时，
它们本身没有遥测，真实分项在下一层。`asset_stats_chart` / `distribution_chart`
会沿 `Contains` 展开到叶子资产（带 visited 去重 —— 维度树不是严格树，同一资产会
挂在多个父下），每个叶子画一条序列。

**部件额外做的过滤**：`00000000-0000-0000-0000-…` 开头的占位哨兵 id 一律跳过。
客户看板里「能源参数字典」「电能品种」保留占位符，是**有意为之** ——
换成真实 id 会让客户去读租户级资产，触发 403。

---

### 6.4 SQL：三层各查一次，问题立刻定位

以客户「星河工业园」为例（id 换成实际的）。

**① 设备到底有没有数**

```sql
SELECT d.name AS 设备,
       to_char(to_timestamp(max(t.ts)/1000) AT TIME ZONE 'Asia/Shanghai','MM-DD HH24:MI') AS 最新点,
       count(*) FILTER (WHERE k.key='energy')         AS energy点数,
       count(*) FILTER (WHERE k.key='energy_reading') AS 表底点数
FROM device d
LEFT JOIN ts_kv t ON t.entity_id = d.id
LEFT JOIN key_dictionary k ON k.key_id = t.key
WHERE d.customer_id = '<客户id>'
GROUP BY d.name
ORDER BY 最新点 NULLS FIRST;
```

> 设备有数 → 问题在资产层，继续 ②。
> 设备没数 → 问题在上报/规则链，回第四节与第五节。

**② 资产有没有汇总值**

```sql
SELECT a.name AS 资产, a.type,
       to_char(to_timestamp(max(t.ts)/1000) AT TIME ZONE 'Asia/Shanghai','MM-DD HH24:MI') AS 最新汇总,
       count(*) FILTER (WHERE k.key='energy_total') AS 汇总点数
FROM asset a
LEFT JOIN ts_kv t ON t.entity_id = a.id
LEFT JOIN key_dictionary k ON k.key_id = t.key
WHERE a.customer_id = '<客户id>'
  AND a.type IN ('场站','分项','组织')
GROUP BY a.name, a.type
ORDER BY 汇总点数, 资产;
```

> 有场站/分项是 0 点 → 成因 A：定时任务没跑或失败，跑 6.2 的手工接口。
> 全都有点但页面还是 0 → 成因 B：部件取数目标不对，见 6.3。

**③ 品种资产确认是空的（应该为空）**

```sql
SELECT a.name, a.type,
       (SELECT count(*) FROM ts_kv t WHERE t.entity_id = a.id)        AS 遥测点数,
       (SELECT count(*) FROM attribute_kv v WHERE v.entity_id = a.id) AS 属性数
FROM asset a
WHERE a.type IN ('default')
  AND a.customer_id = '13814000-1dd2-11b2-8080-808080808080';   -- NULL_UUID = 租户级
```

正常结果：`遥测点数 = 0`，`属性数 > 0`（有 `paramDict`）。
如果这里遥测点数不为 0，说明有人往品种资产上写过数据，那是错的。

---

### 6.5 日聚合的桶边界（另一个容易踩的坑）

部件按日取数用：

```
GET /api/plugins/telemetry/ASSET/<id>/values/timeseries
    ?keys=energy_total&startTs=<起点>&endTs=<现在>
    &interval=86400000&agg=SUM
```

**`startTs` 必须对齐到当地 00:00**，否则：

- TB 从 `startTs` 起按 `interval` 切桶，返回的 `ts` 是**桶中心**；
- 起点若是「现在往前推 400 天」这种任意时刻，桶边界就落在每天 07:49 之类的位置；
- 于是「今天」的桶实际覆盖**昨天 19:49 → 今天 19:49**，跨天数据被算进同一天。

实测偏差：页面显示今日 `83.4`，数据库真实合计 `66.81`，多出来的正是昨天两小时。

对齐零点后桶起点 = 每天 00:00、桶中心 = 12:00，`dkey(桶中心)` 才等于自然日。

> **附带一个显示陷阱**：TB 对**未闭合的今天桶**返回的 `ts` 是
> `(桶起点 + 请求时刻) / 2`，19:56 请求会拿到 09:56 —— 既不等于数据截止时间，
> 也不等于当前时间。所以「截止至」只显示到**日**，不显示时分秒。

---

### 6.6 清除演示数据后，看板为什么会指向旧实体

**这是「清除 → 重新初始化」这条路的专属故障，很容易被当成部件坏了。**

```
① 客户点了「清除演示数据」
      → 场站 / 分项 / 设备被删（只有 additionalInfo.demo=true 的）
② 客户再点「初始化演示数据」
      → 重新生成一套，**实体 uuid 全是新的**
③ 看板呢？
      → entityAliases 里存的是**旧 uuid**
      → 部件去查一个已经不存在的实体
      → 页面显示「部件无数据可显示」，而接口、服务、数据全都正常
```

实测偏差（2026-10-23）：清除后重建，看板 alias 指向 `96a283c0`，
新场站是 `d8d83670` —— 差了 22 处引用里的 9 处场站引用。

> 注意区分：这不是「看板配置写死了某台机器的实体 id」那种架构病。
> 正常开户时占位符替换是对的；只有「删掉实体再重建」才会让旧引用悬空。

#### 平台怎么修（两段闭环）

```
清除时（EnergyBootstrapInstaller.deleteDemoData）
  记录被删的场站 id
      ↓
  把客户看板里这些 id 替换回占位符 00000000-0000-0000-0000-0000000005a1
      ↓
  日志：看板「能耗概览」还原 1 处场站引用（等下次初始化重绑）

初始化时（assignDashboardsToCustomer）
  对**已存在**的看板重新执行占位符替换（旧逻辑是直接跳过）
      ↓
  日志：处理 6 个仪表板（新建 0 / 重绑场站 6，共 20 个模板）
```

只还原**场站**：四个维度根（用能区域 / 用电分项 / 空间位置 / 用能性质）
没有 demo 标记、不会被删，动它们反而会弄坏客户的维度树。

#### 怎么确认修复生效

```sql
-- 清除之后：alias 应变成占位符
SELECT configuration::jsonb->'entityAliases'
  FROM dashboard WHERE customer_id = '<客户id>' AND title = '能耗概览';
-- 期望看到 "场站" → 00000000-0000-0000-0000-0000000005a1

-- 初始化之后：alias 应指向**当前**场站
SELECT a.id FROM asset a WHERE a.customer_id='<客户id>' AND a.type='场站';
-- 与上面 alias 里的 id 一致才对
```

一条 SQL 查全部悬空（排除有意保留的占位符）：

```sql
SELECT d.title, a.value->>'alias' AS alias, a.value->'filter'->'singleEntity'->>'id' AS 实体
FROM dashboard d, LATERAL jsonb_each(d.configuration::jsonb->'entityAliases') a
WHERE d.customer_id = '<客户id>'
  AND (a.value->'filter'->'singleEntity'->>'id') IS NOT NULL
  AND (a.value->'filter'->'singleEntity'->>'id') NOT LIKE '00000000-%'
  AND NOT EXISTS (SELECT 1 FROM asset x WHERE x.id = (a.value->'filter'->'singleEntity'->>'id')::uuid)
  AND NOT EXISTS (SELECT 1 FROM device x WHERE x.id = (a.value->'filter'->'singleEntity'->>'id')::uuid);
-- 期望：0 行
```

#### 清除后还没初始化，页面该长什么样

看板 alias 是占位符 → 部件不发实体查询 → 显示「请为本部件绑定一个数据源实体」。
**这是正确状态**（确实没有数据），不是故障。

---

### 6.7 部件的三个「静默清零」缺陷（2026-10-23 修复）

这三个 bug 有个共同特征：**接口全 200、数据齐全，页面却一个数都不出**。
它们都在部件 JS 里，探针只打接口时完全看不见。

#### 缺陷 A：`isVirtual` 用黑名单判定

```js
// ✗ 修复前
var v = (ai || {}).deviceVirtual;
if (v === undefined || v === null || v === '' || v === false
    || v === 'false' || v === 0 || v === '0') {
  return false;   // 只有这些算「实表」
}
return true;      // 其余一律当「虚拟表」
```

平台给实表写的是 `additionalInfo.deviceVirtual = "real"` —— **`'real'` 不在排除列表里**，
于是每台真实表都被判成虚拟，`devicesWithMeta` 把整个设备池跳过：

```
poolDevices = 0 台
  → KPI 全 0.00
  → 趋势图「当前范围内没有遥测数据」
  → 但顶栏还写着「范围：数据源（10 台）」（那一步不看虚拟标记）
```

这种**自相矛盾**的显示最容易把人带偏。

```js
// ✓ 修复后：白名单，未知值按实表处理
return v === true || v === 'true' || v === 1 || v === '1'
    || v === 'virtual' || v === 'VIRTUAL';
```

> 影响 5 个部件：综合能耗、能耗洞察、盘查报告、电能质量、能源流向。
> 原则：宁可把手工表算进来（数据显示 0），也不能把真实表整批丢掉。

#### 缺陷 B：关系只加载一层

```js
// ✗ 修复前：只拉传入那一层
function loadRelationsBatch(http, assetIds, cb) {
  var pending = assetIds.length;
  for (...) { loadRelations(http, assetIds[i], ...); }
}
```

而 `collectDevices` 是**递归**往下走的：

```
场站 → 7 个分项（ASSET）→ 分项下 9 台设备
```

第一层只拿到分项（没直接挂设备），递归到分项时 `rels[分项id]` 是 undefined
→ 收集到 0 台。现场表现：

```
范围：数据源（1 台）      ← 只有直接挂在场站下那 1 台
当前 1 台计量点
能源消费总量 0.20 tce     ← 其余 9 台没算进去
```

修复是改成 **BFS 逐层展开**（同层并发、`seen` 防环）。

#### 缺陷 C：设备类型名精确匹配

```js
// ✗ 修复前
ENERGY_OF_TYPE = { '电能表': 'elec', '水表': 'water', ... }
```

演示数据的单相表类型是 **`单相电能表`** —— 精确表里没有 → `energyOf()` 返回 `''`
→ 设备被过滤掉。

改成按关键字归类，`单相电能表 / 三相电能表 / 智能电表 / 导轨式电表` 都不会再漏：

```js
function energyTypeOfName(t) {
  if (ENERGY_OF_TYPE[t]) { return ENERGY_OF_TYPE[t]; }
  if (t.indexOf('电能表') >= 0 || t.indexOf('电表') >= 0) { return 'elec'; }
  ...
}
```

#### 怎么自查（一条命令）

```bash
python3 scripts/27-customer-surface-probe.py ... --strict
```

新增的 **S3** 断言会直连 Postgres 查全部 `energy*` / `idle*` 部件的
`controllerScript`，凡是 `isVirtual` 仍为黑名单的直接报出来：

```
✗ S3 部件虚拟表判据错误（1 条）
    200  energy_management.energy_overview
         → isVirtual 用黑名单判定，deviceVirtual='real' 会被当成虚拟表，设备池被清空
```

#### 改完必须同步三处

```
① 仓库种子  guard-server/src/main/data/json/system/widget_types/*.json
② 挂载目录  $APP_HOME/data/json/system/widget_types/*.json
③ 运行库    widget_type.descriptor
```

只改一处，重启或重装就会回退。

---

### 6.8 排查顺序（照着走）

```
页面数字是 0
  ├─ 最近「清除」过演示数据吗？
  │      是 → 看板 alias 可能指向已删实体 → 查 6.6，重新初始化即可重绑
  │      否 ↓
  ├─ 设备有 energy 吗？ ── 没有 → 查上报链路（第四节 / 第五节）
  │        │有
  ├─ 场站/分项有 energy_total 吗？ ── 没有 → 等一轮定时任务，或手工 rebuild
  │        │有
  ├─ 部件取数目标是品种资产吗？ ── 是 → 部件版本旧，重新部署 energy_management.*
  │        │否
  ├─ 顶栏「数据源（N 台）」但下面全 0？ ── 查 6.7 的三个静默清零缺陷
  │        │否
  └─ 数字偏大/偏小？ ── 查日桶边界是否对齐零点（6.5）
```

一条命令覆盖前两步：

```bash
python3 scripts/27-customer-surface-probe.py \
  --base http://127.0.0.1:8090 \
  --tenant tenant@126.com --tenant-pass 12345678 \
  --customer customer@126.com --customer-pass 12345678 --strict
```

它不只判 4xx，还断言两件用户能看见的事：

- **S1** 设备有遥测 → 所属场站的 `energy_total` 必须非空
- **S2** 看板 alias 不能把品种/字典资产当取数实体

---

### 6.9 能源分项属性：AI 三页「按分项」的唯一依据

**位置**：设备的 `additional_info.energyCategory`（不是资产属性，也不是 SERVER_SCOPE 遥测）。

AI 侧三个页面都按它聚合：

| 页面 | 用法 |
| --- | --- |
| 负载预测 · 按分项 | `/ngxapi/biz/targets` 返回 `scope_type=category` 的已发布绑定 |
| 用能建议 · 按分项 | `/ngxapi/biz/advice-targets`，再把该分项展开成设备列表 |
| 用能质量 · 分项口径 | 同上，按分项汇总评分 |

**取值表**（与 `ngx-ai/backend/app/api/biz.py` 的 `CATEGORY_LABELS` 一一对应）：

| 值 | 显示名 | 谁该有 |
| --- | --- | --- |
| `total` | 总用电 | 进线总表 |
| `power` | 动力用电 | 车间动力、空压机、车床 |
| `lighting` | 照明插座 | 照明、插座回路 |
| `hvac` | 空调 | 空调分项 |
| `water_utility` | 用水 | 水表 |
| `gas` | 燃气 | 燃气表 |
| `steam` | 蒸汽 | 蒸汽表 |

温湿度、网关、继电器、虚拟表**不写**这个字段 —— 它们不参与用能分项聚合。

**空值会怎样**：分项下拉全灰、按分项分析「0 台设备」、分项汇总落到「其他」。
页面不报错，只是没法选。

**谁负责写入**：

- 新装客户：`EnergyBootstrapInstaller#createDevice` 按「设备档案 + 所在分项 + 计量层级」
  自动写入，不需要额外步骤。
- 存量数据：跑脚本补齐（幂等，只补空值，不动已有值）。

```bash
# 检查（退出码 1 = 有缺失）
python3 scripts/24-device-categories.py --check

# 补齐
python3 scripts/24-device-categories.py --fix

# 只看会改哪些
python3 scripts/24-device-categories.py --fix --dry-run
```

**运维 SQL：按客户看哪些计量设备还没分类**

```sql
SELECT c.title AS 客户, p.name AS 档案, d.name AS 设备
FROM device d
JOIN device_profile p ON p.id = d.device_profile_id
JOIN customer c ON c.id = d.customer_id
WHERE (p.name LIKE '%电能%' OR p.name LIKE '%水表%'
       OR p.name LIKE '%燃气%' OR p.name LIKE '%蒸汽%')
  AND coalesce(nullif(d.additional_info::jsonb->>'energyCategory',''),'') = ''
ORDER BY c.title, p.name, d.name;
```

**运维 SQL：每个分项下有几台表、多少设备**

```sql
SELECT coalesce(nullif(d.additional_info::jsonb->>'energyCategory',''),'(未分类)') AS 分项,
       count(*) AS 设备数,
       count(*) FILTER (WHERE p.name LIKE '%电能%') AS 电表,
       count(*) FILTER (WHERE p.name NOT LIKE '%电能%') AS 水气汽表
FROM device d
JOIN device_profile p ON p.id = d.device_profile_id
WHERE d.customer_id = '<客户id>'
GROUP BY 1
ORDER BY 2 DESC;
```

> 分项绑定（`scope_type=category`）由租户在 AI 侧发布，不在本表。
> 判据是**设备 id**？不是 —— 分项绑定存的是 `scope_value=power` 这类**分项码**，
> 与设备无关，重建客户后照样有效；但**模型本身**训练时的 `entity_ids`
> 指向具体设备，设备重建后 id 变了，必须重训。
>
> **重装 / 重建客户后必做两步**：
>
> ```bash
> # 1) 用新设备 id 重训（15 秒左右）
> curl -X POST http://127.0.0.1:8090/ngxapi/models/forecast \
>   -H "X-Authorization: Bearer $TENANT_TOKEN" -H 'Content-Type: application/json' \
>   -d '{"name":"演示-三相园进线-小时负荷预测","entity_type":"DEVICE",
>        "entity_ids":["<新设备id>"],"key":"energy","history_days":60,
>        "forecast_horizon":24,"granularity_ms":3600000,
>        "aggregate":"sum","backtest_horizon":24,"overwrite":true}'
>
> # 2) 重新发布 4 条绑定（forecast/advice × device/category）
> curl -X POST http://127.0.0.1:8090/ngxapi/models/<model_id>/publish \
>   -H "X-Authorization: Bearer $TENANT_TOKEN" -H 'Content-Type: application/json' \
>   -d '{"feature":"forecast","scope_type":"category","scope_value":"power",
>        "scope_label":"动力用电","key":"energy"}'
> ```
>
> 第 1 步忘了 → 预测页能选对象但结果为空（模型读的是已删设备的历史）。
> 第 2 步忘了 → 下拉里根本看不到对象。

---

## 七、端到端校验清单

新装或新接一批表之后，按顺序跑一遍：

### 第 1 步：原始数据到了吗

```sql
SELECT kd.key AS 键, count(*) AS 点数,
       to_char(to_timestamp(min(t.ts)/1000) AT TIME ZONE 'Asia/Shanghai','MM-DD HH24:MI') AS 最早,
       to_char(to_timestamp(max(t.ts)/1000) AT TIME ZONE 'Asia/Shanghai','MM-DD HH24:MI') AS 最新
FROM ts_kv t JOIN key_dictionary kd ON kd.key_id = t.key
WHERE t.entity_id = '<设备id>'
GROUP BY kd.key ORDER BY 点数 DESC;
```

- 只有 `U`/`I`/`P` → **映射没生效**（第五节）
- 有标准键但点数很少 → 设备离线或上报间隔太长

### 第 2 步：两个电量键自洽吗

跑第 4.4 节的 SQL，期望 0 行。

### 第 3 步：倍率配了吗

跑第 3.4 节的自查 SQL。进线表的 CT/PT 不该为空。

### 第 4 步：层级配了吗

```sql
SELECT count(*) FILTER (WHERE lvl = 1) AS 进线表数,
       count(*) FILTER (WHERE lvl = 2) AS 分项表数,
       count(*) FILTER (WHERE lvl = 3) AS 回路数,
       count(*) FILTER (WHERE lvl IS NULL OR lvl = 0) AS 未配数
FROM (
    SELECT (SELECT coalesce(ak.dbl_v, ak.long_v)
              FROM attribute_kv ak JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
             WHERE ak.entity_id = d.id AND ak.attribute_type = 2 AND kd.key = 'meterLevel') AS lvl
    FROM device d WHERE d.tenant_id = '<租户id>'
) t;
```

- 有进线但分项/回路全是「未配」→ 汇总会重复计算
- 全都没配 → 只能按「全部相加」出账，金额会虚高

### 第 5 步：页面数字能用 SQL 复现吗

打开「能耗优化 → …」或任一统计页，然后：

```bash
docker logs energy-server 2>&1 | grep -A40 "SQL 埋点" | tail -50
```

把日志里的 SQL 复制到 psql 执行，逐项对比页面数字。
对不上时看第 4.3 节（两个口径）与 `06-customer-menu.md` 各节的「口径提示」。

### 第 6 步：层级守恒吗

跑第 2.4 节的守恒 SQL。差额为负 → 立刻排查。

---

## 八、常见误解对照表

| 误解 | 实际 | 依据 |
| --- | --- | --- |
| 「表的总数」就是用量 | `energy_reading` 是表底，用量要算差值 | 第四节 |
| `sum(energy)` 就是账期用量 | 边界差 1 小时；主口径用表底差 | 4.3 |
| 倍率是「表底 × 系数」 | 是「表底差 × 系数」 | 3.3 |
| RTU 已经乘过倍率了，平台不用管 | 要设 `ratioApplied=true`，否则再乘一次 | 3.2 |
| 分项电表加起来就是总电量 | 总表含分表，直接加会翻倍 | 第二节 |
| 虚拟表也要有表底 | 虚拟表只有 `energy`，没有 `energy_reading` | `06-customer-menu.md` 3.8 |
| 峰谷各档数字跳动说明算错了 | 不同时间段命中不同季节方案，档位构成会变 | `03-init.md` 九之三 |
| 改了规则链脚本，平台自检报错就是坏了 | 自检比对内置版本，自定义脚本必然不符 | 5.5 |
| 设备有数，页面就该有数 | 资产要另算一遍 `energy_total`，平台不自动汇总 | 6.2 |
| 页面 0.0 说明没采到数据 | 也可能是部件把品种资产当取数实体，查了空对象 | 6.3 |
| 「电能」品种资产上应该有遥测 | 它是维度节点，只有 `paramDict` 属性，从不采集 | 6.1 |
| 日用量偏大是算法错了 | 先看日桶边界有没有对齐零点，否则会混进昨天 | 6.5 |
