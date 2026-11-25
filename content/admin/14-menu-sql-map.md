# ⑭ 菜单 → SQL 核对卡（客户 26 个页面）

> **这一章怎么用**：左侧菜单按系统里客户看到的顺序排；每个页面钻到**功能点（部件）**，
> 每个功能点给出它调什么接口、读什么键，再给一段**可运行 SQL** 去核对该页面的数字。

> 结构与部件清单由 `tools/gen-menu-sql-map.py` 从库里实时生成 —— 
> **菜单改了必须重跑脚本**，否则本章会停在旧菜单上。

## 0. 通用前置（每页都要用）

```bash
docker exec -it energy-postgres psql -U postgres -d thingsboard
```

**取客户 id（顶栏一级：先选客户）**

```sql
SELECT id, title, created_time
FROM customer ORDER BY created_time;
```

**取该客户的场站（顶栏二级）**

```sql
SELECT id, name, label
FROM asset
WHERE type = '场站' AND customer_id = (SELECT id FROM customer WHERE title = '平台演示中心')
ORDER BY name;
```

**三张「字典」别搞混**

```sql
SELECT 'key_dictionary'  AS 表, count(*) AS 行数,
       '遥测/属性的键名（整数字典，ts_kv.key 指向它）' AS 用途
FROM key_dictionary
UNION ALL SELECT 'admin_settings', count(*), '业务公共字典（energyDictionaries 等 JSON）'
FROM admin_settings
UNION ALL SELECT 'key_dictionary（重复项提醒）', count(*),
       '同名 key 只应有一条；多条会让 join 出重复行'
FROM (SELECT key FROM key_dictionary GROUP BY key HAVING count(*) > 1) d;
```

> 下面所有 SQL 里的客户名都是 `'平台演示中心'` —— **换成你自己的客户名**即可。
> 时间字段 `ts` 是 epoch 毫秒，`to_timestamp(ts/1000)` 出来是北京时间。

> 三个会得出相反结论的坑：`attribute_kv` 没有 `entity_type` 列（只能按 entity_id join）、
> 属性值是**多列**的（str_v/long_v/dbl_v/bool_v/json_v）、
> `billing` 表是空的（账单在 `asset(type='energy_bill')`）。

## 1. 菜单全貌（与系统逐级一致）

| 一级菜单 | 二级菜单 | 看板 | dashboardId | 功能点数 |
| --- | --- | --- | --- | --- |
| 能耗概览（首页） | — | 能耗概览 | `73dd2240-d2bd-11f1-b794-31725d9e3862` | 8 |
| 能耗查询 | 实时能耗 | 实时能耗 | `74466b60-d2bd-11f1-b794-31725d9e3862` | 3 |
| 能耗查询 | 历史能耗 | 历史能耗 | `73e6bf30-d2bd-11f1-b794-31725d9e3862` | 2 |
| 能耗查询 | 抄表功能 | 抄表功能 | `742ca1d0-d2bd-11f1-b794-31725d9e3862` | 4 |
| 能耗分析 | 峰谷分析 | 峰谷分析 | `745670f0-d2bd-11f1-b794-31725d9e3862` | 2 |
| 能耗分析 | 分项能耗 | 分项能耗 | `7412d840-d2bd-11f1-b794-31725d9e3862` | 4 |
| 能耗分析 | 区域能耗 | 区域能耗 | `7397b4d0-d2bd-11f1-b794-31725d9e3862` | 5 |
| 能耗分析 | 用能账单 | 我的账单 | `7431aae0-d2bd-11f1-b794-31725d9e3862` | 2 |
| 综合报表 | 基础报表 | 基础报表 | `73b500d0-d2bd-11f1-b794-31725d9e3862` | 2 |
| 综合报表 | 手工填报 | 手工填报 | `7426ae60-d2bd-11f1-b794-31725d9e3862` | 4 |
| 能耗优化 | 闲时能耗 | 闲时能耗 | `74091440-d2bd-11f1-b794-31725d9e3862` | 6 |
| 能耗优化 | 负载预测 | 负载预测 | `741d86a0-d2bd-11f1-b794-31725d9e3862` | 3 |
| 能耗优化 | 用能建议 | 用能建议 | `1cebb370-da6f-11f1-aec2-1192e109281d` | 1 |
| 能耗优化 | 用能质量 | 用能质量 | `1d661390-da6f-11f1-aec2-1192e109281d` | 1 |
| 告警事件 | — | 告警事件 | `573f38b0-d3d2-11f1-9ee9-c3a7be535a93` | 1 |
| 设备管理 | 设备运维 | 设备运维 | `a9061a40-d3ca-11f1-9ee9-c3a7be535a93` | 2 |
| 设备管理 | 设备分组 | 设备分组 | `a4917020-d3cc-11f1-9ee9-c3a7be535a93` | 1 |
| 设备管理 | 设备拓扑 | 设备拓扑 | `4dd17660-d3cf-11f1-9ee9-c3a7be535a93` | 1 |
| 综合能耗 | — | 综合能耗 | `73ba09e0-d2bd-11f1-b794-31725d9e3862` | 5 |
| 能源流向 | — | 能源流向 | `744ef6e0-d2bd-11f1-b794-31725d9e3862` | 2 |
| 盘查报告 | — | 盘查报告 | `73abb200-d2bd-11f1-b794-31725d9e3862` | 1 |
| 节能记录 | — | 节能记录 | `7452c770-d2bd-11f1-b794-31725d9e3862` | 1 |
| 空调管理 | 空调运行监控 | 空调运行监控 | `73f58c40-d2bd-11f1-b794-31725d9e3862` | 1 |
| 空调管理 | 运行计划与配置 | 运行计划与配置 | `74001390-d2bd-11f1-b794-31725d9e3862` | 1 |
| 空调管理 | 每日复盘报告 | 每日复盘报告 | `73ed9d00-d2bd-11f1-b794-31725d9e3862` | 1 |
| 组织 | — | 组织与场站 | `04e26da0-d3b7-11f1-8238-c3a7be535a93` | 1 |

> 合计 **13 个一级菜单 / 26 个页面 / 65 个功能点（部件）**。菜单来源：`custom_menu` 中 `scope=CUSTOMER` 的那一份（客户实际看到的就是它）。

## 2. 逐页核对卡

### 2.1 能耗概览

- 菜单位置：顶层菜单「能耗概览」
- 看板：**能耗概览**　`73dd2240-d2bd-11f1-b794-31725d9e3862`

**功能点（部件）**

| 功能点 | 部件类型 | 接口 | 读取的键（脚本字面量） |
| --- | --- | --- | --- |
| analysis_bar | `energy_management.analysis_bar` | `/api/energy/entity-briefs`<br>`/api/energy/metric-params`<br>`/api/energy/time-anchor`<br>`/api/energy/visible-sites` | `gas` |
| overview_stats | `energy_management.overview_stats` | — | `energy`, `energy_total`, `gas_total`, `heat_total`, `paramDict`, `steam_total`, `water_total` |
| 历史{metric}详细 | `energy_management.calendar_heatmap` | — | `energy`, `energy_total`, `gas_total`, `heat_total`, `paramDict`, `steam_total`, `water_total` |
| asset_stats_chart | `energy_management.asset_stats_chart` | `/api/energy/entity-briefs`<br>`/api/energy/telemetry-series`<br>`/api/energy/time-anchor` | `energy`, `energy_total`, `energy_total_real`, `energy_total_virtual`, `gas_total`, `heat_total`, `paramDict`, `steam_total`… |
| distribution_chart | `energy_management.distribution_chart` | `/api/energy/entity-briefs`<br>`/api/energy/telemetry-series`<br>`/api/energy/time-anchor` | `energy`, `energy_total`, `energy_total_real`, `energy_total_virtual`, `gas_total`, `heat_total`, `paramDict`, `steam_total`… |
| ranking_list | `energy_management.ranking_list` | `/api/energy/entity-briefs`<br>`/api/energy/meters`<br>`/api/energy/telemetry-series`<br>`/api/energy/time-anchor` | `energy`, `energy_total`, `gas_total`, `heat_total`, `paramDict`, `steam_total`, `water_total` |
| 峰谷平用电能耗统计 | `energy_management.tou_summary` | `/api/energy/meters`<br>`/api/energy/time-anchor`<br>`/api/energy/tou-analysis`<br>`/api/energy/visible-sites` | — |
| 功率因数与负荷需量 | `energy_management.power_load` | `/api/energy/meters`<br>`/api/energy/time-anchor`<br>`/api/energy/visible-sites` | `apparent_power_total`, `capacityKw`, `demand_max`, `power`, `power_factor_total`, `power_total` |

**① 配置核对（看板与部件是否在线）**

```sql
SELECT d.title AS 看板,
       (SELECT count(*) FROM jsonb_object_keys(d.configuration::jsonb->'widgets')) AS 部件数
FROM dashboard d WHERE d.id = '73dd2240-d2bd-11f1-b794-31725d9e3862';
```

**② 数据核对（页面数字从哪来）**

*1. 资产汇总键：各品种 *_total 的点数与合计*

```sql
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心')
SELECT kd.key AS 键, count(*) AS 点数,
       round(sum(t.dbl_v)::numeric, 2) AS 合计,
       to_timestamp(max(t.ts) / 1000) AS 最新
FROM ts_kv t
JOIN key_dictionary kd ON kd.key_id = t.key
JOIN asset a ON a.id = t.entity_id
WHERE a.customer_id = (SELECT id FROM c)
  -- 括号不能省：AND 优先级高于 OR
  AND (kd.key LIKE '%\_total' ESCAPE '\' OR kd.key = 'energy_day')
GROUP BY 1 ORDER BY 2 DESC;
```

*2. 哪些场站的汇总没写（空节点也要写，否则整页空白）*

```sql
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心')
SELECT s.name AS 场站,
       count(t.*) AS 该场站资产上的汇总点数
FROM asset s
LEFT JOIN relation r ON r.to_id = s.id AND r.relation_type = 'Contains'
LEFT JOIN asset ch ON ch.id = r.from_id
LEFT JOIN ts_kv t ON t.entity_id = ch.id
     AND t.key = (SELECT key_id FROM key_dictionary WHERE key = 'energy_total')
WHERE s.type = '场站' AND s.customer_id = (SELECT id FROM c)
GROUP BY 1 ORDER BY 2;
```

**判据**：电/水/气/汽/热各有对应的 `*_total`；`最新` 在近 1 小时内（数据滞后会显示「数据滞后 N 小时」标记，那是数据源停了，不是看板坏）。

---

### 2.2 能耗查询 / 实时能耗

- 菜单位置：一级「能耗查询」/ 二级「实时能耗」
- 看板：**实时能耗**　`74466b60-d2bd-11f1-b794-31725d9e3862`

**功能点（部件）**

| 功能点 | 部件类型 | 接口 | 读取的键（脚本字面量） |
| --- | --- | --- | --- |
| realtime_kpi | `energy_management.realtime_kpi` | — | `energy`, `energy_total`, `opening`, `paramDict`, `power`, `power_total`, `pump_freq`, `running`… |
| realtime_trend | `energy_management.realtime_trend` | — | `opening`, `paramDict`, `power`, `power_total`, `pump_freq`, `running`, `temperature`, `water_in_temp`… |
| 查询设置 | `energy_management.query_panel` | `/api/energy/meters`<br>`/api/energy/metric-params`<br>`/api/energy/time-anchor`<br>`/api/energy/visible-sites` | `deviceCode`, `meterLevel`, `meterNo`, `paramDict`, `participateEnergyCalc`, `power`, `type1` |

**① 配置核对（看板与部件是否在线）**

```sql
SELECT d.title AS 看板,
       (SELECT count(*) FROM jsonb_object_keys(d.configuration::jsonb->'widgets')) AS 部件数
FROM dashboard d WHERE d.id = '74466b60-d2bd-11f1-b794-31725d9e3862';
```

**② 数据核对（页面数字从哪来）**

*1. 每台设备的最新值（看板读的就是 ts_kv_latest）*

```sql
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心')
SELECT d.name AS 设备, kd.key AS 键, t.dbl_v AS 值,
       to_timestamp(t.ts / 1000) AS 时间
FROM ts_kv_latest t
JOIN key_dictionary kd ON kd.key_id = t.key
JOIN device d ON d.id = t.entity_id
WHERE d.customer_id = (SELECT id FROM c)
  AND kd.key IN ('energy', 'power_total')
ORDER BY 设备, 键;
```

**判据**：每个计量点都有值。**要找出掉线的**：把末尾的 `ORDER BY 设备, 键` 改成 `ORDER BY t.ts`，时间最早的就是最久没上报的。

---

### 2.3 能耗查询 / 历史能耗

- 菜单位置：一级「能耗查询」/ 二级「历史能耗」
- 看板：**历史能耗**　`73e6bf30-d2bd-11f1-b794-31725d9e3862`

**功能点（部件）**

| 功能点 | 部件类型 | 接口 | 读取的键（脚本字面量） |
| --- | --- | --- | --- |
| 查询设置 | `energy_management.query_panel` | `/api/energy/meters`<br>`/api/energy/metric-params`<br>`/api/energy/time-anchor`<br>`/api/energy/visible-sites` | `deviceCode`, `meterLevel`, `meterNo`, `paramDict`, `participateEnergyCalc`, `power`, `type1` |
| 查询结果 | `energy_management.timeseries_chart` | `/api/energy/telemetry-series` | — |

**① 配置核对（看板与部件是否在线）**

```sql
SELECT d.title AS 看板,
       (SELECT count(*) FROM jsonb_object_keys(d.configuration::jsonb->'widgets')) AS 部件数
FROM dashboard d WHERE d.id = '73e6bf30-d2bd-11f1-b794-31725d9e3862';
```

**② 数据核对（页面数字从哪来）**

*1. 区间用量 = 末值 − 初值（表底差，不是求和）*

```sql
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心'),
w AS (SELECT (extract(epoch FROM now() - interval '7 day') * 1000)::bigint AS f,
             (extract(epoch FROM now()) * 1000)::bigint AS e)
SELECT d.name AS 设备,
       round(min(k.dbl_v)::numeric, 2) AS 初值,
       round(max(k.dbl_v)::numeric, 2) AS 末值,
       round((max(k.dbl_v) - min(k.dbl_v))::numeric, 2) AS 用量,
       count(*) AS 点数
FROM ts_kv k
JOIN key_dictionary kd ON kd.key_id = k.key
JOIN device d ON d.id = k.entity_id
CROSS JOIN w
WHERE kd.key = 'energy_reading'
  AND d.customer_id = (SELECT id FROM c)
  AND k.ts BETWEEN w.f AND w.e
GROUP BY d.name ORDER BY 用量 DESC NULLS LAST;
```

**判据**：末值 ≥ 初值（表底单调递增）。出现 7777.7 / 8888.8 是哨兵读数，见 ⑧ §6.3。

---

### 2.4 能耗查询 / 抄表功能

- 菜单位置：一级「能耗查询」/ 二级「抄表功能」
- 看板：**抄表功能**　`742ca1d0-d2bd-11f1-b794-31725d9e3862`

**功能点（部件）**

| 功能点 | 部件类型 | 接口 | 读取的键（脚本字面量） |
| --- | --- | --- | --- |
| 查询设置 | `energy_management.query_panel` | `/api/energy/meters`<br>`/api/energy/metric-params`<br>`/api/energy/time-anchor`<br>`/api/energy/visible-sites` | `deviceCode`, `meterLevel`, `meterNo`, `paramDict`, `participateEnergyCalc`, `power`, `type1` |
| meter_reading_board | `energy_management.meter_reading_board` | `/api/energy/meter-reading/batches`<br>`/api/energy/meter-reading/retry`<br>`/api/energy/meter-reading/run`<br>`/api/energy/meters`… | `energy_reading`, `meterNo`, `note`, `period`, `power`, `usage` |
| 批次明细 | `energy_management.meter_batch_detail` | `/api/energy/meter-reading/records`<br>`/api/energy/meter-reading/retry`<br>`/api/energy/meters`<br>`/api/energy/metric-params` | `meterNo`, `usage` |
| 抄表计划 | `energy_management.meter_plan` | `/api/energy/meter-reading/batches`<br>`/api/energy/meter-reading/run-plan`<br>`/api/energy/meters`<br>`/api/energy/visible-sites` | `name`, `period`, `power`, `running` |

**① 配置核对（看板与部件是否在线）**

```sql
SELECT d.title AS 看板,
       (SELECT count(*) FROM jsonb_object_keys(d.configuration::jsonb->'widgets')) AS 部件数
FROM dashboard d WHERE d.id = '742ca1d0-d2bd-11f1-b794-31725d9e3862';
```

**② 数据核对（页面数字从哪来）**

*1. 最近 10 个抄表批次*

```sql
SELECT b.period AS 账期, b.status AS 状态, b.trigger_type AS 触发方式,
       b.total AS 应抄, b.normal_count AS 正常,
       b.missing_count AS 缺抄, b.abnormal_count AS 异常,
       to_timestamp(b.reading_time / 1000) AS 抄表时间
FROM meter_reading_batch b
WHERE b.tenant_id = (SELECT tenant_id FROM customer WHERE title = '平台演示中心')
ORDER BY b.created_time DESC LIMIT 10;
```

*2. 明细条数 / 用量按账期汇总*

```sql
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心')
SELECT period AS 账期, source AS 来源, quality AS 质量,
       count(*) AS 条数, round(sum(usage)::numeric, 2) AS 用量合计
FROM meter_reading_record
WHERE customer_id = (SELECT id FROM c)
GROUP BY 1, 2, 3 ORDER BY 1 DESC;
```

**判据**：批次 `total = normal + missing + abnormal`；明细用量合计 = 页面的「抄表电量」。`source` 的 auto/manual 说明这条是自动读的还是手工填的。

---

### 2.5 能耗分析 / 峰谷分析

- 菜单位置：一级「能耗分析」/ 二级「峰谷分析」
- 看板：**峰谷分析**　`745670f0-d2bd-11f1-b794-31725d9e3862`

**功能点（部件）**

| 功能点 | 部件类型 | 接口 | 读取的键（脚本字面量） |
| --- | --- | --- | --- |
| 查询设置 | `energy_management.query_panel` | `/api/energy/meters`<br>`/api/energy/metric-params`<br>`/api/energy/time-anchor`<br>`/api/energy/visible-sites` | `deviceCode`, `meterLevel`, `meterNo`, `paramDict`, `participateEnergyCalc`, `power`, `type1` |
| tou_analysis | `energy_management.tou_analysis` | `/api/energy/tou-analysis` | — |

**① 配置核对（看板与部件是否在线）**

```sql
SELECT d.title AS 看板,
       (SELECT count(*) FROM jsonb_object_keys(d.configuration::jsonb->'widgets')) AS 部件数
FROM dashboard d WHERE d.id = '745670f0-d2bd-11f1-b794-31725d9e3862';
```

**② 数据核对（页面数字从哪来）**

*1. 五个时段键各自的点数与合计*

```sql
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心')
SELECT kd.key AS 时段键, count(*) AS 点数,
       round(sum(k.dbl_v)::numeric, 2) AS 合计
FROM ts_kv k
JOIN key_dictionary kd ON kd.key_id = k.key
JOIN device d ON d.id = k.entity_id
WHERE d.customer_id = (SELECT id FROM c)
  AND kd.key IN ('energy_tip', 'energy_peak', 'energy_flat', 'energy_valley', 'energy_deep')
GROUP BY 1 ORDER BY 1;
```

*2. 时段方案（★ 租户级资产，**不要按客户过滤**）*

```sql
-- 坑：tou_scheme 的 customer_id 是占位值（13814000-…），
--     按客户过滤会返回 0 行，看起来像「方案没配」，其实是查错了。
SELECT a.name AS 方案, a.label, kd.key AS 属性, left(ak.str_v, 120) AS 值
FROM asset a
JOIN attribute_kv ak ON ak.entity_id = a.id
JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
WHERE a.type = 'tou_scheme'
ORDER BY 1, 3;
```

**判据**：五个时段键齐全。峰谷合计 ≠ 台账用量是正常的（按小时切片 vs 按抄表周期）。

---

### 2.6 能耗分析 / 分项能耗

- 菜单位置：一级「能耗分析」/ 二级「分项能耗」
- 看板：**分项能耗**　`7412d840-d2bd-11f1-b794-31725d9e3862`

**功能点（部件）**

| 功能点 | 部件类型 | 接口 | 读取的键（脚本字面量） |
| --- | --- | --- | --- |
| asset_stats_chart | `energy_management.asset_stats_chart` | `/api/energy/entity-briefs`<br>`/api/energy/telemetry-series`<br>`/api/energy/time-anchor` | `energy`, `energy_total`, `energy_total_real`, `energy_total_virtual`, `gas_total`, `heat_total`, `paramDict`, `steam_total`… |
| distribution_chart | `energy_management.distribution_chart` | `/api/energy/entity-briefs`<br>`/api/energy/telemetry-series`<br>`/api/energy/time-anchor` | `energy`, `energy_total`, `energy_total_real`, `energy_total_virtual`, `gas_total`, `heat_total`, `paramDict`, `steam_total`… |
| ranking_list | `energy_management.ranking_list` | `/api/energy/entity-briefs`<br>`/api/energy/meters`<br>`/api/energy/telemetry-series`<br>`/api/energy/time-anchor` | `energy`, `energy_total`, `gas_total`, `heat_total`, `paramDict`, `steam_total`, `water_total` |
| analysis_bar | `energy_management.analysis_bar` | `/api/energy/entity-briefs`<br>`/api/energy/metric-params`<br>`/api/energy/time-anchor`<br>`/api/energy/visible-sites` | `gas` |

**① 配置核对（看板与部件是否在线）**

```sql
SELECT d.title AS 看板,
       (SELECT count(*) FROM jsonb_object_keys(d.configuration::jsonb->'widgets')) AS 部件数
FROM dashboard d WHERE d.id = '7412d840-d2bd-11f1-b794-31725d9e3862';
```

**② 数据核对（页面数字从哪来）**

*1. 分项资产上各品种的汇总*

```sql
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心')
SELECT a.name AS 分项, kd.key AS 键, count(*) AS 点数,
       round(sum(k.dbl_v)::numeric, 2) AS 合计
FROM ts_kv k
JOIN key_dictionary kd ON kd.key_id = k.key
JOIN asset a ON a.id = k.entity_id
WHERE a.type = '分项' AND a.customer_id = (SELECT id FROM c)
  AND kd.key LIKE '%\_total' ESCAPE '\'
GROUP BY 1, 2 ORDER BY 1, 2;
```

**判据**：选「电」时水/气/汽/热为空是正常的。分项合计 > 场站总量 = 有表挂了两个分项（重复计）。

---

### 2.7 能耗分析 / 区域能耗

- 菜单位置：一级「能耗分析」/ 二级「区域能耗」
- 看板：**区域能耗**　`7397b4d0-d2bd-11f1-b794-31725d9e3862`

**功能点（部件）**

| 功能点 | 部件类型 | 接口 | 读取的键（脚本字面量） |
| --- | --- | --- | --- |
| ranking_list | `energy_management.ranking_list` | `/api/energy/entity-briefs`<br>`/api/energy/meters`<br>`/api/energy/telemetry-series`<br>`/api/energy/time-anchor` | `energy`, `energy_total`, `gas_total`, `heat_total`, `paramDict`, `steam_total`, `water_total` |
| distribution_chart | `energy_management.distribution_chart` | `/api/energy/entity-briefs`<br>`/api/energy/telemetry-series`<br>`/api/energy/time-anchor` | `energy`, `energy_total`, `energy_total_real`, `energy_total_virtual`, `gas_total`, `heat_total`, `paramDict`, `steam_total`… |
| asset_stats_chart | `energy_management.asset_stats_chart` | `/api/energy/entity-briefs`<br>`/api/energy/telemetry-series`<br>`/api/energy/time-anchor` | `energy`, `energy_total`, `energy_total_real`, `energy_total_virtual`, `gas_total`, `heat_total`, `paramDict`, `steam_total`… |
| analysis_bar | `energy_management.analysis_bar` | `/api/energy/entity-briefs`<br>`/api/energy/metric-params`<br>`/api/energy/time-anchor`<br>`/api/energy/visible-sites` | `gas` |
| ranking_list | `energy_management.ranking_list` | `/api/energy/entity-briefs`<br>`/api/energy/meters`<br>`/api/energy/telemetry-series`<br>`/api/energy/time-anchor` | `energy`, `energy_total`, `gas_total`, `heat_total`, `paramDict`, `steam_total`, `water_total` |

**① 配置核对（看板与部件是否在线）**

```sql
SELECT d.title AS 看板,
       (SELECT count(*) FROM jsonb_object_keys(d.configuration::jsonb->'widgets')) AS 部件数
FROM dashboard d WHERE d.id = '7397b4d0-d2bd-11f1-b794-31725d9e3862';
```

**② 数据核对（页面数字从哪来）**

*1. 区域资产上各品种的汇总*

```sql
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心')
SELECT a.name AS 区域, kd.key AS 键, count(*) AS 点数,
       round(sum(k.dbl_v)::numeric, 2) AS 合计
FROM ts_kv k
JOIN key_dictionary kd ON kd.key_id = k.key
JOIN asset a ON a.id = k.entity_id
WHERE a.type = '区域' AND a.customer_id = (SELECT id FROM c)
  AND kd.key LIKE '%\_total' ESCAPE '\'
GROUP BY 1, 2 ORDER BY 1, 2;
```

**判据**：同一台表挂两个区域会双算 —— 用 ⑧ §6.1 的归属 SQL 查重复。

---

### 2.8 能耗分析 / 用能账单

- 菜单位置：一级「能耗分析」/ 二级「用能账单」
- 看板：**我的账单**　`7431aae0-d2bd-11f1-b794-31725d9e3862`

**功能点（部件）**

| 功能点 | 部件类型 | 接口 | 读取的键（脚本字面量） |
| --- | --- | --- | --- |
| 查询设置 | `energy_management.query_panel` | `/api/energy/meters`<br>`/api/energy/metric-params`<br>`/api/energy/time-anchor`<br>`/api/energy/visible-sites` | `deviceCode`, `meterLevel`, `meterNo`, `paramDict`, `participateEnergyCalc`, `power`, `type1` |
| billing_workspace | `energy_management.billing_workspace` | `/api/energy/billing/crosstab`<br>`/api/energy/billing/delete`<br>`/api/energy/billing/generate` | `basicFee`, `energy`, `powerFactorFee`, `surchargeFee` |

**① 配置核对（看板与部件是否在线）**

```sql
SELECT d.title AS 看板,
       (SELECT count(*) FROM jsonb_object_keys(d.configuration::jsonb->'widgets')) AS 部件数
FROM dashboard d WHERE d.id = '7431aae0-d2bd-11f1-b794-31725d9e3862';
```

**② 数据核对（页面数字从哪来）**

*1. 账单列表（金额在 asset 属性里，不在 billing 表）*

```sql
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心')
SELECT a.name AS 账单元, a.label,
       max(CASE WHEN kd.key = 'period' THEN ak.str_v END) AS 账期,
       max(CASE WHEN kd.key = 'usage'  THEN ak.dbl_v END) AS 用量,
       max(CASE WHEN kd.key = 'amount' THEN ak.dbl_v END) AS 金额,
       max(CASE WHEN kd.key = 'status' THEN ak.str_v END) AS 状态
FROM asset a
JOIN attribute_kv ak ON ak.entity_id = a.id
LEFT JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
WHERE a.type = 'energy_bill' AND a.customer_id = (SELECT id FROM c)
GROUP BY a.id, a.name, a.label
ORDER BY 账期 DESC;
```

*2. 金额分解：amount 应等于四项之和*

```sql
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心')
SELECT a.name,
       max(CASE WHEN kd.key = 'amount'        THEN ak.dbl_v END) AS 金额,
       max(CASE WHEN kd.key = 'energyFee'     THEN ak.dbl_v END) AS 电度电费,
       max(CASE WHEN kd.key = 'basicFee'      THEN ak.dbl_v END) AS 基本电费,
       max(CASE WHEN kd.key = 'powerFactorFee' THEN ak.dbl_v END) AS 力调电费,
       max(CASE WHEN kd.key = 'surchargeFee'  THEN ak.dbl_v END) AS 附加费
FROM asset a
JOIN attribute_kv ak ON ak.entity_id = a.id
LEFT JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
WHERE a.type = 'energy_bill' AND a.customer_id = (SELECT id FROM c)
GROUP BY a.id, a.name;
```

*3. 确认 billing 表确实是空的（别再白查一次）*

```sql
SELECT (SELECT count(*) FROM billing)        AS "billing 行数",
       (SELECT count(*) FROM billing_detail) AS "billing_detail 行数";
```

**判据**：金额 = 电度 + 基本 + 力调 + 附加；`billing` / `billing_detail` 为 0 是当前设计，账单落在 `asset(type=energy_bill)` 的属性里。

---

### 2.9 综合报表 / 基础报表

- 菜单位置：一级「综合报表」/ 二级「基础报表」
- 看板：**基础报表**　`73b500d0-d2bd-11f1-b794-31725d9e3862`

**功能点（部件）**

| 功能点 | 部件类型 | 接口 | 读取的键（脚本字面量） |
| --- | --- | --- | --- |
| 查询设置 | `energy_management.query_panel` | `/api/energy/meters`<br>`/api/energy/metric-params`<br>`/api/energy/time-anchor`<br>`/api/energy/visible-sites` | `deviceCode`, `meterLevel`, `meterNo`, `paramDict`, `participateEnergyCalc`, `power`, `type1` |
| basic_report_workspace | `energy_management.basic_report_workspace` | `/api/energy/telemetry-series` | — |

**① 配置核对（看板与部件是否在线）**

```sql
SELECT d.title AS 看板,
       (SELECT count(*) FROM jsonb_object_keys(d.configuration::jsonb->'widgets')) AS 部件数
FROM dashboard d WHERE d.id = '73b500d0-d2bd-11f1-b794-31725d9e3862';
```

**② 数据核对（页面数字从哪来）**

*1. 报表取数的设备键（与历史能耗同一口径）*

```sql
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心')
SELECT d.name AS 设备, kd.key AS 键, count(*) AS 点数,
       to_timestamp(max(k.ts) / 1000) AS 最新
FROM ts_kv k
JOIN key_dictionary kd ON kd.key_id = k.key
JOIN device d ON d.id = k.entity_id
WHERE d.customer_id = (SELECT id FROM c)
  AND kd.key IN ('energy_reading', 'energy', 'power_total')
GROUP BY 1, 2 ORDER BY 1, 2;
```

**判据**：报表的数字来自同一批键 —— 与历史能耗页对不上时，先比这两页的查询条件（时间窗、设备树）。

---

### 2.10 综合报表 / 手工填报

- 菜单位置：一级「综合报表」/ 二级「手工填报」
- 看板：**手工填报**　`7426ae60-d2bd-11f1-b794-31725d9e3862`

**功能点（部件）**

| 功能点 | 部件类型 | 接口 | 读取的键（脚本字面量） |
| --- | --- | --- | --- |
| 用能数据录入 | `energy_management.manual_entry` | `/api/energy/manual-entry/category`<br>`/api/energy/manual-entry/category/`<br>`/api/energy/manual-entry/meta`<br>`/api/energy/manual-entry/save`… | `gas` |
| 查询设置 | `energy_management.query_panel` | `/api/energy/meters`<br>`/api/energy/metric-params`<br>`/api/energy/time-anchor`<br>`/api/energy/visible-sites` | `deviceCode`, `meterLevel`, `meterNo`, `paramDict`, `participateEnergyCalc`, `power`, `type1` |
| 月度用量 | `energy_management.monthly_bar` | — | — |
| 数据表详情 | `energy_management.device_total` | — | — |

**① 配置核对（看板与部件是否在线）**

```sql
SELECT d.title AS 看板,
       (SELECT count(*) FROM jsonb_object_keys(d.configuration::jsonb->'widgets')) AS 部件数
FROM dashboard d WHERE d.id = '7426ae60-d2bd-11f1-b794-31725d9e3862';
```

**② 数据核对（页面数字从哪来）**

*1. 填报属性挂在设备或分项资产上*

```sql
SELECT coalesce(d.name, a.name) AS 实体,
       coalesce(d.type, a.type) AS 类型,
       kd.key AS 属性,
       left(coalesce(ak.json_v::text, ak.str_v), 160) AS 值
FROM attribute_kv ak
LEFT JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
LEFT JOIN device d ON d.id = ak.entity_id
LEFT JOIN asset  a ON a.id = ak.entity_id
WHERE kd.key IN ('manualEntryMonths', 'manualYearValueType', 'manualEntryItemId')
ORDER BY 1, 3;
```

**判据**：每个填报对象都有 `manualEntryMonths`。数字大得离谱时看是不是把「正向有功总电度」当成了增量（那是累计表底，应该用末值−初值）。

---

### 2.11 能耗优化 / 闲时能耗

- 菜单位置：一级「能耗优化」/ 二级「闲时能耗」
- 看板：**闲时能耗**　`74091440-d2bd-11f1-b794-31725d9e3862`

**功能点（部件）**

| 功能点 | 部件类型 | 接口 | 读取的键（脚本字面量） |
| --- | --- | --- | --- |
| kpi | `idle_energy.kpi` | `/api/energy/idle-analysis` | — |
| share | `idle_energy.share` | `/api/energy/idle-analysis` | — |
| trend | `idle_energy.trend` | `/api/energy/idle-analysis` | — |
| curve | `idle_energy.curve` | `/api/energy/idle-analysis` | — |
| table | `idle_energy.table` | `/api/energy/idle-analysis` | — |
| analysis_bar | `energy_management.analysis_bar` | `/api/energy/entity-briefs`<br>`/api/energy/metric-params`<br>`/api/energy/time-anchor`<br>`/api/energy/visible-sites` | `gas` |

**① 配置核对（看板与部件是否在线）**

```sql
SELECT d.title AS 看板,
       (SELECT count(*) FROM jsonb_object_keys(d.configuration::jsonb->'widgets')) AS 部件数
FROM dashboard d WHERE d.id = '74091440-d2bd-11f1-b794-31725d9e3862';
```

**② 数据核对（页面数字从哪来）**

*1. 场站的闲时配置（JSON 属性 idleConfig）*

```sql
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心')
SELECT a.name AS 场站, left(ak.json_v::text, 200) AS 配置
FROM asset a
JOIN attribute_kv ak ON ak.entity_id = a.id
JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
WHERE a.type = '场站' AND a.customer_id = (SELECT id FROM c)
  AND kd.key = 'idleConfig';
```

*2. 闲时计算的产出键（规则链写的遥测）*

```sql
SELECT kd.key AS 键, count(*) AS 点数, round(sum(k.dbl_v)::numeric, 2) AS 合计
FROM ts_kv k
JOIN key_dictionary kd ON kd.key_id = k.key
WHERE kd.key LIKE 'idle\_%' ESCAPE '\' OR kd.key = 'work_energy'
GROUP BY 1 ORDER BY 2 DESC;
```

**判据**：场站有 `idleConfig` 就行。**产出键为空不一定是坏事**：`/api/energy/idle-analysis` 在找不到落库结果时会按原始遥测**实时计算**并在响应里给告警。两边都空、且页面也空 → 规则链没部署或设备没上报 `energy_reading` / `power_total`。

---

### 2.12 能耗优化 / 负载预测

- 菜单位置：一级「能耗优化」/ 二级「负载预测」
- 看板：**负载预测**　`741d86a0-d2bd-11f1-b794-31725d9e3862`

**功能点（部件）**

| 功能点 | 部件类型 | 接口 | 读取的键（脚本字面量） |
| --- | --- | --- | --- |
| 负荷情况 | `energy_management.forecast_context` | `/api/energy/forecast/context`<br>`/api/energy/time-anchor`<br>`/api/energy/visible-sites` | — |
| 负荷预测分析 | `energy_management.forecast_chart` | `/api/energy/forecast/predict` | — |
| diagnosis_brief | `energy_management.diagnosis_brief` | `/api/energy/diagnosis/brief`<br>`/api/energy/diagnosis/forecast`<br>`/api/energy/diagnosis/sites` | — |

**① 配置核对（看板与部件是否在线）**

```sql
SELECT d.title AS 看板,
       (SELECT count(*) FROM jsonb_object_keys(d.configuration::jsonb->'widgets')) AS 部件数
FROM dashboard d WHERE d.id = '741d86a0-d2bd-11f1-b794-31725d9e3862';
```

**② 数据核对（页面数字从哪来）**

*1. 预测的输入：近 7 天逐小时功率*

```sql
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心')
SELECT date_trunc('day', to_timestamp(k.ts / 1000)) AS 日期,
       count(*) AS 点数,
       round(avg(k.dbl_v)::numeric, 2) AS 平均功率,
       round(max(k.dbl_v)::numeric, 2) AS 最大功率
FROM ts_kv k
JOIN key_dictionary kd ON kd.key_id = k.key
JOIN device d ON d.id = k.entity_id
WHERE d.customer_id = (SELECT id FROM c)
  AND kd.key = 'power_total'
  AND k.ts > (extract(epoch FROM now() - interval '7 day') * 1000)::bigint
GROUP BY 1 ORDER BY 1;
```

**判据**：每天都有点。历史不足 7 天时预测会退化（算法需要至少两个完整周期）。

---

### 2.13 能耗优化 / 用能建议

- 菜单位置：一级「能耗优化」/ 二级「用能建议」
- 看板：**用能建议**　`1cebb370-da6f-11f1-aec2-1192e109281d`

**功能点（部件）**

| 功能点 | 部件类型 | 接口 | 读取的键（脚本字面量） |
| --- | --- | --- | --- |
| diagnosis_brief | `energy_management.diagnosis_brief` | `/api/energy/diagnosis/brief`<br>`/api/energy/diagnosis/forecast`<br>`/api/energy/diagnosis/sites` | — |

**① 配置核对（看板与部件是否在线）**

```sql
SELECT d.title AS 看板,
       (SELECT count(*) FROM jsonb_object_keys(d.configuration::jsonb->'widgets')) AS 部件数
FROM dashboard d WHERE d.id = '1cebb370-da6f-11f1-aec2-1192e109281d';
```

**② 数据核对（页面数字从哪来）**

*1. 诊断结论（intent=energy_advice）*

```sql
-- 坑：这张表的 customer_id 目前**全为空**（历史回填没补上），
--     按客户过滤会一条都查不到，看起来像「没跑过诊断」。按租户查。
WITH t AS (SELECT tenant_id FROM customer WHERE title = '平台演示中心')
SELECT intent AS 类别, kind AS 类型, severity AS 级别,
       site_id AS 场站, count(*) AS 条数,
       max(run_at) AS 最近运行
FROM energy_analysis_finding
WHERE tenant_id = (SELECT tenant_id FROM t) AND intent = 'energy_advice'
GROUP BY 1, 2, 3, 4 ORDER BY 5 DESC;
```

**判据**：**只看 `最近运行` 这一列**：距今天超过 1 天就是诊断没重跑 —— 页面显示旧结论或为空都是这个原因，不是看板坏。`customer_id` 为空会让按客户过滤的接口少数据（AGENTS.md A2m 已记），所以上面按 `tenant_id` 查。

---

### 2.14 能耗优化 / 用能质量

- 菜单位置：一级「能耗优化」/ 二级「用能质量」
- 看板：**用能质量**　`1d661390-da6f-11f1-aec2-1192e109281d`

**功能点（部件）**

| 功能点 | 部件类型 | 接口 | 读取的键（脚本字面量） |
| --- | --- | --- | --- |
| diagnosis_brief | `energy_management.diagnosis_brief` | `/api/energy/diagnosis/brief`<br>`/api/energy/diagnosis/forecast`<br>`/api/energy/diagnosis/sites` | — |

**① 配置核对（看板与部件是否在线）**

```sql
SELECT d.title AS 看板,
       (SELECT count(*) FROM jsonb_object_keys(d.configuration::jsonb->'widgets')) AS 部件数
FROM dashboard d WHERE d.id = '1d661390-da6f-11f1-aec2-1192e109281d';
```

**② 数据核对（页面数字从哪来）**

*1. 电能质量结论（intent=power_quality）*

```sql
WITH t AS (SELECT tenant_id FROM customer WHERE title = '平台演示中心')
SELECT intent AS 类别, kind AS 类型, severity AS 级别, metric AS 指标,
       site_id AS 场站, count(*) AS 条数, max(run_at) AS 最近运行
FROM energy_analysis_finding
WHERE tenant_id = (SELECT tenant_id FROM t) AND intent = 'power_quality'
GROUP BY 1, 2, 3, 4, 5 ORDER BY 6 DESC;
```

**判据**：`limit` 是越限、`trend` 是趋势。一个指标都没有 = 设备没上报对应键（voltage_thd_* / unbalance / flicker_*），见 ⑧ §4。

---

### 2.15 告警事件

- 菜单位置：顶层菜单「告警事件」
- 看板：**告警事件**　`573f38b0-d3d2-11f1-9ee9-c3a7be535a93`

**功能点（部件）**

| 功能点 | 部件类型 | 接口 | 读取的键（脚本字面量） |
| --- | --- | --- | --- |
| events_page | `energy_alarm.events_page` | `/api/energy/alarm-events`<br>`/api/energy/alarm-events/ack`<br>`/api/energy/alarm-events/assign`<br>`/api/energy/alarm-events/assignees`… | `name`, `status` |

**① 配置核对（看板与部件是否在线）**

```sql
SELECT d.title AS 看板,
       (SELECT count(*) FROM jsonb_object_keys(d.configuration::jsonb->'widgets')) AS 部件数
FROM dashboard d WHERE d.id = '573f38b0-d3d2-11f1-9ee9-c3a7be535a93';
```

**② 数据核对（页面数字从哪来）**

*1. 按类型与级别统计（含未清除数）*

```sql
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心')
SELECT type AS 类型, severity AS 级别, count(*) AS 条数,
       count(*) FILTER (WHERE clear_ts IS NULL) AS 未清除
FROM alarm
WHERE customer_id = (SELECT id FROM c)
GROUP BY 1, 2 ORDER BY 3 DESC;
```

*2. 告警规则是否启用*

```sql
SELECT name AS 规则, enabled AS 启用, count(*) OVER () AS 规则总数
FROM alarm_rule ORDER BY enabled DESC, name;
```

**判据**：页面只列未清除的（`clear_ts IS NULL`）。条数为 0 但设备确实异常 → 规则没启用或没绑。

---

### 2.16 设备管理 / 设备运维

- 菜单位置：一级「设备管理」/ 二级「设备运维」
- 看板：**设备运维**　`a9061a40-d3ca-11f1-9ee9-c3a7be535a93`

**功能点（部件）**

| 功能点 | 部件类型 | 接口 | 读取的键（脚本字面量） |
| --- | --- | --- | --- |
| ops_page | `energy_device.ops_page` | `/api/energy/alarms`<br>`/api/energy/meters`<br>`/api/energy/metric-params`<br>`/api/energy/visible-sites` | `name`, `online`, `unit` |
| gateway_detail | `energy_device.gateway_detail` | — | `name`, `online`, `status` |

**① 配置核对（看板与部件是否在线）**

```sql
SELECT d.title AS 看板,
       (SELECT count(*) FROM jsonb_object_keys(d.configuration::jsonb->'widgets')) AS 部件数
FROM dashboard d WHERE d.id = 'a9061a40-d3ca-11f1-9ee9-c3a7be535a93';
```

**② 数据核对（页面数字从哪来）**

*1. 每台设备最近上报时间（最上面的是掉线的）*

```sql
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心')
SELECT d.name AS 设备, d.type AS 类型,
       to_timestamp(max(k.ts) / 1000) AS 最近上报,
       count(*) AS 键数
FROM device d
LEFT JOIN ts_kv_latest k ON k.entity_id = d.id
WHERE d.customer_id = (SELECT id FROM c)
GROUP BY d.id, d.name, d.type
ORDER BY 3 NULLS FIRST;
```

**判据**：`最近上报` 为空 = 从没上报过；超过 24 小时 = 掉线。

---

### 2.17 设备管理 / 设备分组

- 菜单位置：一级「设备管理」/ 二级「设备分组」
- 看板：**设备分组**　`a4917020-d3cc-11f1-9ee9-c3a7be535a93`

**功能点（部件）**

| 功能点 | 部件类型 | 接口 | 读取的键（脚本字面量） |
| --- | --- | --- | --- |
| group_page | `energy_device.group_page` | `/api/energy/device-profiles/meta`<br>`/api/energy/device-profiles/meta}`<br>`/api/energy/devices/type-meta`<br>`/api/energy/dictionaries`… | `name`, `power` |

**① 配置核对（看板与部件是否在线）**

```sql
SELECT d.title AS 看板,
       (SELECT count(*) FROM jsonb_object_keys(d.configuration::jsonb->'widgets')) AS 部件数
FROM dashboard d WHERE d.id = 'a4917020-d3cc-11f1-9ee9-c3a7be535a93';
```

**② 数据核对（页面数字从哪来）**

*1. 设备档案（device_profile）与设备数*

```sql
SELECT dp.name AS 档案, dp.type AS 类型, count(d.id) AS 设备数
FROM device_profile dp
LEFT JOIN device d ON d.device_profile_id = dp.id
GROUP BY dp.id, dp.name, dp.type ORDER BY 3 DESC;
```

**判据**：设备数为 0 的档案是残留；设备档案决定「设备分组」页的树形结构。

---

### 2.18 设备管理 / 设备拓扑

- 菜单位置：一级「设备管理」/ 二级「设备拓扑」
- 看板：**设备拓扑**　`4dd17660-d3cf-11f1-9ee9-c3a7be535a93`

**功能点（部件）**

| 功能点 | 部件类型 | 接口 | 读取的键（脚本字面量） |
| --- | --- | --- | --- |
| topology_page | `energy_device.topology_page` | `/api/energy/topologies`<br>`/api/energy/topologies/` | `gateway` |

**① 配置核对（看板与部件是否在线）**

```sql
SELECT d.title AS 看板,
       (SELECT count(*) FROM jsonb_object_keys(d.configuration::jsonb->'widgets')) AS 部件数
FROM dashboard d WHERE d.id = '4dd17660-d3cf-11f1-9ee9-c3a7be535a93';
```

**② 数据核对（页面数字从哪来）**

*1. 拓扑图资产与它的属性数*

```sql
SELECT a.name AS 拓扑图, a.label, count(ak.*) AS 属性数
FROM asset a
LEFT JOIN attribute_kv ak ON ak.entity_id = a.id
WHERE a.type = 'topology'
GROUP BY a.id, a.name, a.label ORDER BY 1;
```

**判据**：属性数为 0 的拓扑图打开是空的（没保存过布局或连线）。

---

### 2.19 综合能耗

- 菜单位置：顶层菜单「综合能耗」
- 看板：**综合能耗**　`73ba09e0-d2bd-11f1-b794-31725d9e3862`

**功能点（部件）**

| 功能点 | 部件类型 | 接口 | 读取的键（脚本字面量） |
| --- | --- | --- | --- |
| kpi | `comprehensive.kpi` | `/api/energy/comprehensive` | — |
| share | `comprehensive.share` | `/api/energy/comprehensive` | — |
| trend | `comprehensive.trend` | `/api/energy/comprehensive` | — |
| table | `comprehensive.table` | `/api/energy/comprehensive` | — |
| analysis_bar | `energy_management.analysis_bar` | `/api/energy/entity-briefs`<br>`/api/energy/metric-params`<br>`/api/energy/time-anchor`<br>`/api/energy/visible-sites` | `gas` |

**① 配置核对（看板与部件是否在线）**

```sql
SELECT d.title AS 看板,
       (SELECT count(*) FROM jsonb_object_keys(d.configuration::jsonb->'widgets')) AS 部件数
FROM dashboard d WHERE d.id = '73ba09e0-d2bd-11f1-b794-31725d9e3862';
```

**② 数据核对（页面数字从哪来）**

*1. 折标煤 / 碳排 / 费用 的输入：各品种合计*

```sql
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心')
SELECT kd.key AS 键, count(*) AS 点数, round(sum(k.dbl_v)::numeric, 2) AS 合计
FROM ts_kv k
JOIN key_dictionary kd ON kd.key_id = k.key
JOIN asset a ON a.id = k.entity_id
WHERE a.customer_id = (SELECT id FROM c)
  AND kd.key LIKE '%\_total' ESCAPE '\'
GROUP BY 1 ORDER BY 2 DESC;
```

*2. 折算系数（字典没填时用国标兜底，响应里会告警）*

```sql
-- 电能 0.1229 tce/kWh、碳排 0.5703 kg/kWh、电价 0.65 元/kWh
SELECT 'elec' AS 品种, 0.1229 AS 折标煤系数, 0.5703 AS 碳排系数, 0.65 AS 单价
UNION ALL SELECT 'water', 0.2429, 0.3440, 3.50
UNION ALL SELECT 'gas',   1.3300, 2.1620, 3.20
UNION ALL SELECT 'steam', 94.300, 110.00, 260
UNION ALL SELECT 'heat',  34.120, 110.00, 90;
```

**判据**：tce ≈ Σ(各品种用量 × 系数) / 1000。数字为 0 且显示「当前 N 台计量点」→ 汇总资产上没写 `*_total`。

---

### 2.20 能源流向

- 菜单位置：顶层菜单「能源流向」
- 看板：**能源流向**　`744ef6e0-d2bd-11f1-b794-31725d9e3862`

**功能点（部件）**

| 功能点 | 部件类型 | 接口 | 读取的键（脚本字面量） |
| --- | --- | --- | --- |
| 能源流向 | `energy_management.sankey_flow` | `/api/energy/child-relations`<br>`/api/energy/comprehensive`<br>`/api/energy/comprehensive}`<br>`/api/energy/meters` | `energy`, `gas`, `idle_energy`, `region`, `work_energy` |
| analysis_bar | `energy_management.analysis_bar` | `/api/energy/entity-briefs`<br>`/api/energy/metric-params`<br>`/api/energy/time-anchor`<br>`/api/energy/visible-sites` | `gas` |

**① 配置核对（看板与部件是否在线）**

```sql
SELECT d.title AS 看板,
       (SELECT count(*) FROM jsonb_object_keys(d.configuration::jsonb->'widgets')) AS 部件数
FROM dashboard d WHERE d.id = '744ef6e0-d2bd-11f1-b794-31725d9e3862';
```

**② 数据核对（页面数字从哪来）**

*1. 流向的骨架：Contains 关系（谁包含谁）*

```sql
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心')
SELECT pa.name AS 上级, pa.type AS 上级类型,
       ca.name AS 下级, ca.type AS 下级类型
FROM relation r
JOIN asset pa ON pa.id = r.to_id
JOIN asset ca ON ca.id = r.from_id
WHERE r.relation_type = 'Contains'
  AND (pa.customer_id = (SELECT id FROM c) OR ca.customer_id = (SELECT id FROM c))
ORDER BY 1, 3
LIMIT 50;
```

**判据**：环节完整（组织→场站→分项→设备）。缺一层则流向图断在该处、数字为 0。

---

### 2.21 盘查报告

- 菜单位置：顶层菜单「盘查报告」
- 看板：**盘查报告**　`73abb200-d2bd-11f1-b794-31725d9e3862`

**功能点（部件）**

| 功能点 | 部件类型 | 接口 | 读取的键（脚本字面量） |
| --- | --- | --- | --- |
| 能源盘查报告 | `energy_management.audit_report` | `/api/energy/audit-report/precheck`<br>`/api/energy/audit-report/precheck}`<br>`/api/energy/audit-report/versions`<br>`/api/energy/audit-report/versions/`… | `energy`, `gas`, `idle_energy`, `region`, `work_energy` |

**① 配置核对（看板与部件是否在线）**

```sql
SELECT d.title AS 看板,
       (SELECT count(*) FROM jsonb_object_keys(d.configuration::jsonb->'widgets')) AS 部件数
FROM dashboard d WHERE d.id = '73abb200-d2bd-11f1-b794-31725d9e3862';
```

**② 数据核对（页面数字从哪来）**

*1. 已保存的盘查版本*

```sql
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心')
SELECT a.name AS 版本, a.label AS 范围, count(ak.*) AS 属性数,
       to_timestamp(a.created_time / 1000) AS 创建时间
FROM asset a
LEFT JOIN attribute_kv ak ON ak.entity_id = a.id
WHERE a.type = 'audit_report_version' AND a.customer_id = (SELECT id FROM c)
GROUP BY a.id, a.name, a.label, a.created_time
ORDER BY a.created_time DESC;
```

**判据**：报告内容在资产属性里；没有版本 = 还没点过「保存版本」。

---

### 2.22 节能记录

- 菜单位置：顶层菜单「节能记录」
- 看板：**节能记录**　`7452c770-d2bd-11f1-b794-31725d9e3862`

**功能点（部件）**

| 功能点 | 部件类型 | 接口 | 读取的键（脚本字面量） |
| --- | --- | --- | --- |
| saving_records | `energy_management.saving_records` | `/api/energy/meters` | `energy`, `gas`, `idle_energy`, `period`, `work_energy` |

**① 配置核对（看板与部件是否在线）**

```sql
SELECT d.title AS 看板,
       (SELECT count(*) FROM jsonb_object_keys(d.configuration::jsonb->'widgets')) AS 部件数
FROM dashboard d WHERE d.id = '7452c770-d2bd-11f1-b794-31725d9e3862';
```

**② 数据核对（页面数字从哪来）**

*1. 节能项目与其核验字段*

```sql
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心')
SELECT a.name AS 项目,
       max(CASE WHEN kd.key = 'actualSaving'  THEN ak.dbl_v END) AS 实际节约,
       max(CASE WHEN kd.key = 'targetSaving'  THEN ak.dbl_v END) AS 目标节约,
       max(CASE WHEN kd.key = 'verifyStatus'  THEN ak.str_v END) AS 核验状态,
       max(CASE WHEN kd.key = 'implementDate' THEN ak.str_v END) AS 实施日期
FROM asset a
JOIN attribute_kv ak ON ak.entity_id = a.id
LEFT JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
WHERE a.type = 'saving_record' AND a.customer_id = (SELECT id FROM c)
GROUP BY a.id, a.name ORDER BY 1;
```

**判据**：每条都有 `actualSaving`。核验期内没有实际节约数据 = 设备在核验窗口内没数。

---

### 2.23 空调管理 / 空调运行监控

- 菜单位置：一级「空调管理」/ 二级「空调运行监控」
- 看板：**空调运行监控**　`73f58c40-d2bd-11f1-b794-31725d9e3862`

**功能点（部件）**

| 功能点 | 部件类型 | 接口 | 读取的键（脚本字面量） |
| --- | --- | --- | --- |
| operation_monitor | `hvac_management.operation_monitor` | `/api/energy/visible-sites` | `ahu_freq`, `boiler_run_count`, `indoor_co2`, `indoor_temp`, `pump_freq_big`, `pump_freq_small`, `pump_run_big`, `pump_run_small` |

**① 配置核对（看板与部件是否在线）**

```sql
SELECT d.title AS 看板,
       (SELECT count(*) FROM jsonb_object_keys(d.configuration::jsonb->'widgets')) AS 部件数
FROM dashboard d WHERE d.id = '73f58c40-d2bd-11f1-b794-31725d9e3862';
```

**② 数据核对（页面数字从哪来）**

*1. 空调设备的实时键*

```sql
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心')
SELECT d.name AS 设备, kd.key AS 键, k.dbl_v AS 值,
       to_timestamp(k.ts / 1000) AS 时间
FROM ts_kv_latest k
JOIN key_dictionary kd ON kd.key_id = k.key
JOIN device d ON d.id = k.entity_id
WHERE d.customer_id = (SELECT id FROM c)
  AND kd.key IN ('indoor_temp', 'indoor_co2', 'ahu_freq', 'boiler_run_count',
                 'pump_freq_big', 'pump_freq_small', 'pump_run_big', 'pump_run_small')
ORDER BY 设备, 键;
```

**判据**：室内温湿度/CO₂ 有空值 = 该设备没接环境传感器（不影响机组本身）。

---

### 2.24 空调管理 / 运行计划与配置

- 菜单位置：一级「空调管理」/ 二级「运行计划与配置」
- 看板：**运行计划与配置**　`74001390-d2bd-11f1-b794-31725d9e3862`

**功能点（部件）**

| 功能点 | 部件类型 | 接口 | 读取的键（脚本字面量） |
| --- | --- | --- | --- |
| plan_config | `hvac_management.plan_config` | `/api/energy/visible-sites` | — |

**① 配置核对（看板与部件是否在线）**

```sql
SELECT d.title AS 看板,
       (SELECT count(*) FROM jsonb_object_keys(d.configuration::jsonb->'widgets')) AS 部件数
FROM dashboard d WHERE d.id = '74001390-d2bd-11f1-b794-31725d9e3862';
```

**② 数据核对（页面数字从哪来）**

*1. 运行模式资产：配置在单个 JSON 属性 hvacMode 里*

```sql
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心')
SELECT a.name AS 模式, a.label AS 季节,
       ak.str_v::json->>'season'   AS 季节码,
       ak.str_v::json->>'dateType' AS 日期类型,
       ak.str_v::json->>'control'  AS 控制方式,
       ak.str_v::json->>'tempMin'  AS 温度下限
FROM asset a
JOIN attribute_kv ak ON ak.entity_id = a.id
JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
WHERE a.type = '运行模式' AND a.customer_id = (SELECT id FROM c)
  AND kd.key = 'hvacMode'
ORDER BY 1;
```

**判据**：每种季节（夏/冬）× 日期类型（工作日/节假日）都有模式。缺一档则该天计划回退到默认。

---

### 2.25 空调管理 / 每日复盘报告

- 菜单位置：一级「空调管理」/ 二级「每日复盘报告」
- 看板：**每日复盘报告**　`73ed9d00-d2bd-11f1-b794-31725d9e3862`

**功能点（部件）**

| 功能点 | 部件类型 | 接口 | 读取的键（脚本字面量） |
| --- | --- | --- | --- |
| daily_report | `hvac_management.daily_report` | `/api/energy/visible-sites` | — |

**① 配置核对（看板与部件是否在线）**

```sql
SELECT d.title AS 看板,
       (SELECT count(*) FROM jsonb_object_keys(d.configuration::jsonb->'widgets')) AS 部件数
FROM dashboard d WHERE d.id = '73ed9d00-d2bd-11f1-b794-31725d9e3862';
```

**② 数据核对（页面数字从哪来）**

*1. 复盘用到的机组遥测（当日）*

```sql
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心')
SELECT kd.key AS 键, count(*) AS 点数,
       round(avg(k.dbl_v)::numeric, 2) AS 均值,
       to_timestamp(max(k.ts) / 1000) AS 最新
FROM ts_kv k
JOIN key_dictionary kd ON kd.key_id = k.key
JOIN device d ON d.id = k.entity_id
WHERE d.customer_id = (SELECT id FROM c)
  AND kd.key IN ('indoor_temp', 'indoor_co2', 'ahu_freq')
  AND k.ts > (extract(epoch FROM now() - interval '1 day') * 1000)::bigint
GROUP BY 1 ORDER BY 2 DESC;
```

**判据**：当日有数才算得出口径。空白报告 = 当天机组没上报。

---

### 2.26 组织

- 菜单位置：顶层菜单「组织」
- 看板：**组织与场站**　`04e26da0-d3b7-11f1-8238-c3a7be535a93`

**功能点（部件）**

| 功能点 | 部件类型 | 接口 | 读取的键（脚本字面量） |
| --- | --- | --- | --- |
| sites_page | `energy_org.sites_page` | `/api/energy/core-dictionaries`<br>`/api/energy/customer-roles`<br>`/api/energy/device-display-name`<br>`/api/energy/dictionaries`… | `active`, `apparent_power_a`, `apparent_power_b`, `apparent_power_c`, `apparent_power_total`, `baselineEnabled`, `baselineValue`, `batchRules`… |

**① 配置核对（看板与部件是否在线）**

```sql
SELECT d.title AS 看板,
       (SELECT count(*) FROM jsonb_object_keys(d.configuration::jsonb->'widgets')) AS 部件数
FROM dashboard d WHERE d.id = '04e26da0-d3b7-11f1-8238-c3a7be535a93';
```

**② 数据核对（页面数字从哪来）**

*1. 场站清单（顶栏一级/二级下拉的来源）*

```sql
SELECT a.id AS 场站id, a.name AS 场站, a.label, c.title AS 客户,
       (SELECT count(*) FROM relation r
        WHERE r.to_id = a.id AND r.relation_type = 'Contains') AS 下级数
FROM asset a
LEFT JOIN customer c ON c.id = a.customer_id
WHERE a.type = '场站'
ORDER BY c.title, a.name;
```

*2. 场站绑定的电价方案（关系类型 uses，不是属性）*

```sql
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心')
SELECT s.name AS 场站, t.name AS 方案模板,
       (SELECT ak.str_v FROM attribute_kv ak JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
        WHERE ak.entity_id = t.id AND kd.key = 'energy' LIMIT 1) AS 能源品种
FROM asset s
JOIN relation r ON r.from_id = s.id AND r.relation_type = 'uses'
JOIN asset t ON t.id = r.to_id AND t.type = 'rate_template'
WHERE s.type = '场站' AND s.customer_id = (SELECT id FROM c)
ORDER BY 1, 3;
```

**判据**：每个客户至少一个场站；组织只做「客户→场站」两级，场站是后面所有功能的第一维度。绑定表为空 = 这些场站没单独绑电价，**继承客户默认方案**（不是故障）。

---

## 3. 一张表看清「每个功能的数字落在哪张表」

| 功能 | 权威表 | 别去哪查 |
| --- | --- | --- |
| 能耗概览 / 分项 / 区域 / 综合能耗 / 能源流向 | `ts_kv`（资产上的 `*_total`、`energy_day`） | 别查设备表，汇总写在资产上 |
| 实时能耗 | `ts_kv_latest`（设备上的 `energy`、`power_total`） | 别查 `ts_kv` 取最新（慢一个量级） |
| 历史能耗 / 峰谷 / 基础报表 / 负载预测 | `ts_kv`（设备上的 `energy_reading`，用末值−初值） | **不要 sum**，表底是累计值 |
| 抄表 | `meter_reading_record` / `meter_reading_batch` | 别用峰谷的切片数代替台账 |
| 用能账单 | `asset(type='energy_bill')` + `attribute_kv` | **`billing` 表是空的** |
| 手工填报 | `attribute_kv`（`manualEntryMonths`，挂在设备或分项资产） | 别查 `ts_kv` |
| 闲时能耗 | 场站资产属性 `idleConfig` + `ts_kv` 的 `idle_*` | 别只看配置，要看产出键 |
| 用能建议 / 用能质量 | `energy_analysis_finding`（`intent` 区分） | 别从告警表推 |
| 告警事件 | `alarm`（`clear_ts IS NULL` 才是未清除） | `entity_alarm` 是关联表，不是内容表 |
| 盘查报告 | `asset(type='audit_report_version')` + 属性 | 别查 `report` 表（那是 TB 原生报表） |
| 节能记录 | `asset(type='saving_record')` + 属性 | — |
| 空调管理 | `asset(type='运行模式')` + 属性；设备遥测 | 模式是资产，不是设备 |
| 组织 / 设备分组 / 设备拓扑 | `asset` / `device` / `relation` / `device_profile` | — |

## 4. 全量体检（一条 SQL 看八件事）

```sql
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心')
SELECT '客户'  AS 检查项, (SELECT count(*) FROM customer)::text AS 值, '至少 1 个' AS 期望
UNION ALL SELECT '场站', (SELECT count(*) FROM asset WHERE type='场站' AND customer_id=(SELECT id FROM c))::text, '≥1'
UNION ALL SELECT '设备', (SELECT count(*) FROM device WHERE customer_id=(SELECT id FROM c))::text, '>0'
UNION ALL SELECT '有遥测的设备', (SELECT count(DISTINCT entity_id) FROM ts_kv_latest
       WHERE entity_id IN (SELECT id FROM device WHERE customer_id=(SELECT id FROM c)))::text, '= 设备数'
UNION ALL SELECT '资产汇总键', (SELECT count(*) FROM ts_kv k
       JOIN key_dictionary kd ON kd.key_id=k.key JOIN asset a ON a.id=k.entity_id
       WHERE a.customer_id=(SELECT id FROM c) AND kd.key LIKE '%\_total' ESCAPE '\')::text, '>0'
UNION ALL SELECT '未清除告警', (SELECT count(*) FROM alarm
       WHERE customer_id=(SELECT id FROM c) AND clear_ts IS NULL)::text, '可多可少'
UNION ALL SELECT '诊断结论', (SELECT count(*) FROM energy_analysis_finding
       WHERE customer_id=(SELECT id FROM c))::text, '>0'
UNION ALL SELECT '抄表记录', (SELECT count(*) FROM meter_reading_record
       WHERE customer_id=(SELECT id FROM c))::text, '>0'
UNION ALL SELECT 'billing 表', (SELECT count(*) FROM billing)::text, '0 是正常的';
```

> 「有遥测的设备」< 设备数 → 有设备从没上报，先查 `ts_kv_latest` 为空的那几台。

## 5. 重新生成本章

```bash
python3 tools/gen-menu-sql-map.py            # 重新生成
python3 tools/gen-menu-sql-map.py --check    # 只比对（退出码 1 = 手册过期）
cd shiyongshouce && ./sync.sh                # 同步到发布目录
```

**什么时候必须重跑**：改菜单（`custom_menu`）、加删看板部件、新增能源接口。
脚本会重新读库，这些结构性内容不会手抄漏项。

> SQL 部分是固化在 `tools/gen-menu-sql-map.py` 的 `PAGE_SQL` 里的人工核对结果 ——
> 改了业务口径（比如账单改存 `billing` 表），要同步改那里，否则本章会骗人。

