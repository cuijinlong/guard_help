# ⑧ 运维 SQL

查数据对不对、库里有什么、怎么备份清理。**所有 SQL 都在真实库跑通过**。

> 库是空的？先看 [② 系统部署](/admin/deploy)。
> 表结构和字段含义见 [④ 数据模型](/admin/data-model)。

---

## 按症状找 SQL

| 你看到的现象 | 跑第几节 |
| --- | --- |
| 「品种指标」页是空的 / 只有电 | §1 字典 |
| 设备属性对不上、类型混乱 | §2 设备三层属性 |
| 设备列表有，但没数据 | §3 遥测 |
| 电能质量页指标不全 | §4 电能质量 |
| **设备有数、看板是 0** | §5 资产汇总（最常见） |
| 设备不在场站/区域/分项下 | §6 归属关系 |
| 分项显示 kWh 但装的是水表 | §6.2 按品种分键 |
| **分项/区域能耗页的合计对不上 / 两页数字一样** | §6.2b 统计核算 |
| **账单金额对不上 / 账单页与分时拆解页金额不同** | §6.2c 账单核算 |
| **基础报表/参数报表的曲线或明细对不上** | §6.2d 报表核对 |
| **手工填报页的月度数字/合计对不上** | §6.2e 手工填报核对 |
| 数字是天文数字 | §6.3 哨兵读数 |
| 抄表读不出表底 | §8 抄表 |
| 磁盘满了 / 要备份 | §9 表结构与空间、§10 备份 |
| 不知道从哪查 | §11 一键体检与排查顺序 |

## 0. 怎么进库

```bash
docker exec -it energy-postgres psql -U postgres -d thingsboard
```

三个必须知道的事（写错会得出相反结论）：

| 坑 | 说明 |
| --- | --- |
| `attribute_kv` **没有** `entity_type` 列 | 只能按 `entity_id` join。设备与资产的 id 都是 uuid，不会撞 |
| 属性值是**多列**的 | `str_v` / `long_v` / `dbl_v` / `bool_v` / `json_v`，不同属性落在不同列 |
| **不要硬编码 `attribute_key`** | key_id 会随库重建变化（`deviceType1` 是 343，曾经错记成 342，白查两轮） |

查 key_id 的标准写法（需要时先查，别猜）：

```sql
SELECT key_id, key FROM key_dictionary
WHERE key IN ('type1','type2','deviceType1','measurePoints','meterLevel');
```

常用 key_id 参考（**仅供对照，SQL 里一律用 join**）：

```
 43 energyTypeCode    73 type1              89 power_total      276 energyType
 45 wiring            75 type2             101 energy_day       290 measurePoints
 47 isMeter           81 model             156 energy_total     343 deviceType1
 70 meterLevel       356 rpcCommands
```

---

## 1. 字典：六类主数据齐不齐

### 1.1 字典版本与规模

```sql
SELECT
  kv.long_v AS dict_version,
  jsonb_array_length(kv2.json_v::jsonb -> 'standardKeys')  AS standard_keys,
  jsonb_array_length(kv2.json_v::jsonb -> 'deviceTypeL1')  AS l1_types,
  jsonb_array_length(kv2.json_v::jsonb -> 'wirings')       AS wirings,
  jsonb_array_length(kv2.json_v::jsonb -> 'energyKinds')   AS energy_kinds
FROM attribute_kv kv
JOIN key_dictionary kd  ON kd.key_id = kv.attribute_key
JOIN attribute_kv kv2   ON kv2.entity_id = kv.entity_id
                       AND kv2.attribute_type = 2
                       AND kv2.attribute_key = (
                             SELECT key_id FROM key_dictionary WHERE key='dictionaries')
WHERE kv.attribute_type = 2
  AND kd.key = 'dict_version'
  AND kv.entity_id = (
      SELECT id FROM asset WHERE name = '能源参数字典');
```

**正常**：`dict_version` 与 `energy_library.json` 里的 `dictionaries.version` 一致；
`standard_keys` = 125（含电能质量 63 个）；`wirings` = 2（1P2W / 3P4W，3P3W 已移除）。

**异常**：版本号对不上 = 升级没生效。改完 seed 必须点「平台自检 → 一键修复初始化」，
否则库里永远是旧版（实测：重启 3 次字典仍是旧版，跑一次修复才变）。

### 1.2 电能质量 key 是否齐

```sql
-- 直接数标准 key 里带电能质量特征的（不用查 attribute_kv，字典是一整块 JSON）
SELECT
  COUNT(*) FILTER (WHERE code LIKE 'voltage_harmonic_%') AS 电压分次谐波,
  COUNT(*) FILTER (WHERE code LIKE 'current_harmonic_%') AS 电流分次谐波,
  COUNT(*) FILTER (WHERE code LIKE 'flicker_%')          AS 闪变,
  COUNT(*) FILTER (WHERE code LIKE '%\_seq\_%' ESCAPE '\') AS 序分量,
  COUNT(*) FILTER (WHERE code LIKE 'voltage_deviation_%')AS 电压偏差
FROM (
  SELECT jsonb_array_elements(dic.json_v::jsonb -> 'standardKeys') ->> 'code' AS code
  FROM attribute_kv dic
  JOIN key_dictionary kd ON kd.key_id = dic.attribute_key
  WHERE kd.key = 'dictionaries'
    AND dic.entity_id = (SELECT id FROM asset WHERE name='能源参数字典')
) t;
```

**正常**：24 / 24 / 3 / 6 / 3（共 62 个电能质量 key）。

---

## 2. 设备：三层属性是否自洽

### 2.1 全部设备的总览（最常用的一条）

```sql
SELECT
  d.name                                        AS 设备,
  d.type                                        AS 档案,
  COALESCE(t1.v,  '-')                          AS 品种,
  COALESCE(t2.v,  '-')                          AS 二级类型,
  COALESCE(dt.v,  '-')                          AS 一级类型,
  COALESCE(jsonb_array_length(mp.j::jsonb)::text, '0') AS 测点数,
  COALESCE(site.name, '-')                      AS 场站,
  COALESCE(lv.long_v::text, '-')                AS 层级
FROM device d
LEFT JOIN LATERAL (
  SELECT str_v AS v FROM attribute_kv
  WHERE entity_id=d.id AND attribute_type=2
    AND attribute_key=(SELECT key_id FROM key_dictionary WHERE key='type1')) t1 ON TRUE
LEFT JOIN LATERAL (
  SELECT str_v AS v FROM attribute_kv
  WHERE entity_id=d.id AND attribute_type=2
    AND attribute_key=(SELECT key_id FROM key_dictionary WHERE key='type2')) t2 ON TRUE
LEFT JOIN LATERAL (
  SELECT str_v AS v FROM attribute_kv
  WHERE entity_id=d.id AND attribute_type=2
    AND attribute_key=(SELECT key_id FROM key_dictionary WHERE key='deviceType1')) dt ON TRUE
LEFT JOIN LATERAL (
  SELECT json_v::text AS j FROM attribute_kv
  WHERE entity_id=d.id AND attribute_type=2
    AND attribute_key=(SELECT key_id FROM key_dictionary WHERE key='measurePoints')) mp ON TRUE
LEFT JOIN LATERAL (
  SELECT long_v FROM attribute_kv
  WHERE entity_id=d.id AND attribute_type=2
    AND attribute_key=(SELECT key_id FROM key_dictionary WHERE key='meterLevel')) lv ON TRUE
LEFT JOIN asset site ON site.id::text = (d.additional_info::jsonb ->> 'siteId')
ORDER BY 场站, 设备;
```

**正常**（演示环境应长这样）：

```
ED1-Gateway          | 网关       | -    | -             | -            | 0  | 单相园区 | -
PowerMeter-DDSU666   | 单相电能表 | elec | -             | elec_meter   | 29 | 单相园区 | 2
Relay-8CH            | default    | elec | smart_breaker | smart_breaker| 29 | 单相园区 | 0
Sensor-HZ8706        | 温湿度变送器| env  | temp_humidity | env_device   | 2  | 单相园区 | 0
PowerMeter-3P-SIM·…  | 电能表     | elec | normal        | elec_meter   | 49 | 三相园区 | 1
...
```

**逐列怎么判**：

| 列 | 空/异常意味着什么 |
| --- | --- |
| 品种 空 | 这台设备不进任何能耗汇总（网关正常如此，计量设备不该空） |
| 一级类型 空 | role 判不出来，抄表会把非计量设备算进来（跑 `backfillDeviceType1`） |
| 测点数 0 | 键名不会翻译，上报的原始代号原样入库，报表全空 |
| 场站 空 | 按场站过滤的看板看不见它（用 `30-rtu-env-init.py` 补） |
| 层级 空 | **资产汇总取不到它**，看板 `energy_total` 为 0（这是最容易漏的一条） |

### 2.2 三层属性不一致的设备（应为空）

```sql
WITH dict AS (
  SELECT jsonb_array_elements(dic.json_v::jsonb -> 'deviceTypeL1') AS l1
  FROM attribute_kv dic
  JOIN key_dictionary kd ON kd.key_id = dic.attribute_key
  WHERE kd.key='dictionaries'
    AND dic.entity_id=(SELECT id FROM asset WHERE name='能源参数字典')
),
l1kind AS (
  SELECT l1 ->> 'code' AS code, l1 ->> 'energyKind' AS kind FROM dict
)
SELECT d.name, t1.str_v AS 品种, dt.str_v AS 一级类型, k.kind AS 字典里的品种
FROM device d
JOIN attribute_kv t1 ON t1.entity_id=d.id AND t1.attribute_type=2
     AND t1.attribute_key=(SELECT key_id FROM key_dictionary WHERE key='type1')
JOIN attribute_kv dt ON dt.entity_id=d.id AND dt.attribute_type=2
     AND dt.attribute_key=(SELECT key_id FROM key_dictionary WHERE key='deviceType1')
JOIN l1kind k ON k.code = dt.str_v
WHERE k.kind IS DISTINCT FROM t1.str_v;
```

**正常**：0 行。有行 = 一级类型与品种对不上（比如水表被标成 `elec_meter`）。

---

## 3. 遥测：数据在不在动

### 3.1 每台设备最近写入时间与键数

```sql
SELECT
  d.name,
  COUNT(DISTINCT kv.key)                             AS 键数,
  to_char(to_timestamp(MIN(kv.ts)/1000),'MM-DD HH24:MI') AS 最早,
  to_char(to_timestamp(MAX(kv.ts)/1000),'MM-DD HH24:MI') AS 最近,
  EXTRACT(EPOCH FROM now())::bigint - MAX(kv.ts)/1000 AS 距今秒
FROM ts_kv kv
JOIN device d ON d.id = kv.entity_id
WHERE d.name LIKE '%-SIM%'          -- 换成 %  看全部
GROUP BY d.name
ORDER BY 最近 DESC;
```

**正常**：模拟器在跑时，`距今秒` 应小于 2 × interval；键数固定不变。
实测基线（2026-11-02）：

```
PowerMeter-3P-SIM  52     HeatMeter-SIM   6     SteamMeter-SIM  5
GasMeter-SIM        4     AHU-SIM         4     Breaker-SIM     3
WaterMeter-SIM      3
```

**键数比基线少 = 测点快照缺项**，重跑 `30-rtu-env-init.py`。
（建完设备后一定要重跑一次 —— 快照是脚本按版本写的，不动不会自己补。）

**异常**：

| 现象 | 原因 |
| --- | --- |
| 距今秒很大（几分钟以上） | 模拟器没在跑 / 连不上平台 |
| 键数比预期少 | 测点快照缺项，重新跑 `30-rtu-env-init.py` |
| 键数是原始代号（`U`/`Ep`）而不是 `voltage_a` | 规则链没翻译（真实 RTU 才会出现） |

### 3.2 表底单调性（抄表判 abnormal 的判据）

```sql
SELECT d.name,
       COUNT(*) FILTER (WHERE v < prev) AS 倒流次数,
       MIN(v) AS 最小, MAX(v) AS 最大
FROM (
  SELECT kv.entity_id, kv.dbl_v AS v,
         LAG(kv.dbl_v) OVER (PARTITION BY kv.entity_id ORDER BY kv.ts) AS prev
  FROM ts_kv kv
  JOIN key_dictionary kd ON kd.key_id = kv.key
  WHERE kd.key = 'energy_reading'
) x
JOIN device d ON d.id = x.entity_id
GROUP BY d.name
HAVING COUNT(*) FILTER (WHERE v < prev) > 0;
```

**正常**：0 行（表底严格递增）。

**有行 = 表底倒流**，三个原因（按出现频率）：

| 原因 | 怎么判断 | 怎么修 |
| --- | --- | --- |
| 回填的起点低于平台上的现值 | 每台表都恰好 1 次，且紧挨着回填时间点 | 用修复后的 `31-rtu-simulate.py`（它会先读平台现值再往回推）；旧数据只能删了重填 |
| 同一台表被**两个源**同时写 | 只有个别表，且 `距今秒` 很小 | 确认模拟器没碰真实 RTU 的三台设备 |
| 设备被删了重建 | 表底从 0 或小数字重新开始 | 正常现象，重建设备后重新建立基线 |

> 回填这个坑实测过：旧版模拟器用内部计数（首次固定 1000）当起点，
> 回填写 1000~4000，而实时点已经 13995 —— 接上去就是一次倒流，
> 抄表判 `abnormal`。**每台表都中招，不是偶发。**

---

## 4. 电能质量：数值是否落在国标内

```sql
SELECT
  kd.key,
  ROUND(MIN(kv.dbl_v)::numeric, 2) AS 最小,
  ROUND(AVG(kv.dbl_v)::numeric, 2) AS 平均,
  ROUND(MAX(kv.dbl_v)::numeric, 2) AS 最大,
  COUNT(*)                          AS 点数
FROM ts_kv kv
JOIN device d          ON d.id = kv.entity_id
JOIN key_dictionary kd ON kd.key_id = kv.key
WHERE d.name LIKE 'PowerMeter-3P-SIM%'
  AND kd.key IN ('voltage_a','voltage_b','voltage_c','frequency',
                 'voltage_unbalance','voltage_thd_a','current_thd_a',
                 'flicker_pst','flicker_plt','voltage_deviation_a',
                 'voltage_seq_negative','voltage_harmonic_3')
  AND kv.ts > (EXTRACT(EPOCH FROM now())*1000 - 3600000)::bigint
GROUP BY kd.key ORDER BY kd.key;
```

**正常范围**（超出说明假数据写歪了，看板会误报越限）：

| key | 国标 | 脚本生成范围 |
| --- | --- | --- |
| `voltage_a/b/c` | 220V ±7%（204.6~235.4） | 218~229 |
| `frequency` | 50 ± 0.2 Hz | 49.95~50.05 |
| `voltage_unbalance` | ≤ 2% | ≤ 1.2% |
| `voltage_thd_a` | ≤ 5% | 1.2~3.8% |
| `flicker_pst` | ≤ 1.0 | 0.2~0.9 |
| `flicker_plt` | ≤ 0.8 | 0.15~0.75 |

---

## 5. 资产汇总：看板为什么是空的

**这是「设备有数据、看板没数」最常见的原因。**

### 5.1 汇总遥测是否存在

```sql
SELECT a.name AS 场站,
       to_char(to_timestamp(t.ts/1000),'MM-DD HH24:MI') AS 最近,
       ROUND(t.e::numeric, 3) AS energy_total,
       ROUND(t.d::numeric, 3) AS energy_day,
       ROUND(t.p::numeric, 2) AS power_total
FROM asset a
JOIN LATERAL (
  SELECT k.ts,
         MAX(k.dbl_v) FILTER (WHERE kd.key='energy_total') AS e,
         MAX(k.dbl_v) FILTER (WHERE kd.key='energy_day')   AS d,
         MAX(k.dbl_v) FILTER (WHERE kd.key='power_total')  AS p
  FROM ts_kv k JOIN key_dictionary kd ON kd.key_id = k.key
  WHERE k.entity_id = a.id
    AND kd.key IN ('energy_total','energy_day','power_total')
  GROUP BY k.ts ORDER BY k.ts DESC LIMIT 1
) t ON TRUE
WHERE a.type = '场站'
ORDER BY a.name;
```

> ⚠️ **为什么用 `LATERAL ... LIMIT 1` 而不是在外层 `MAX(kv.ts)`**：
> 外层聚合会把「所有资产的最新时间」当成一个值，再拿它去匹配每个资产的
> `energy_total` —— 匹配到的是别的资产那一刻的值，甚至匹配到 0。
> 第一版就是这么写的，实测给出 `0.059`（真实值 `0.649`），差点误判成「数据没写」。

**正常**：每个在场站一行，`最近` 是刚刚（模拟器在跑时），`energy_total` 有正数。

**一行都没有 / 全是 NULL**：跑一次重算。

```bash
TOKEN=$(curl -s -X POST http://127.0.0.1:8090/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"tenant@126.com","password":"12345678"}' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')

curl -X POST http://127.0.0.1:8090/api/energy/asset-totals/rebuild \
  -H "X-Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d '{}'
# 期望 {"ok":true,"assetsWritten":15,...}
```

> **这条 SQL 只回答「有没有写」，不回答「数值对不对」。**
> `energy_total` 的口径是「子树内最上层表计的一段区间用量」，
> 和「设备当日 `energy` 之和」不是同一个数，两者对不上是正常的 ——
> 别拿它们互相验算（实测：三相园区 `energy_total=0.649`，而设备当日 `energy` 之和 1126）。
> 判断数值合理性要看 `energy_day`（当日累计）与设备侧的日增量同量级。

> `assetsWritten: 0` 说明**没有任何设备满足汇总条件** —— 回去查第 2.1 节的
> 「层级」和「品种」两列，通常是 `meterLevel` 没设。
> 汇总写的是**遥测**（`ts_kv`），不是属性（`attribute_kv`），别查错表。

### 5.2 哪些设备参与了汇总

```sql
SELECT d.name, d.type,
       lv.long_v AS 层级,
       COALESCE(pk.str_v, '(无品种)') AS 档案品种
FROM device d
-- ★ device_profile 必须**先** JOIN：下面的 LATERAL 里要引用 dp.id，
--   放在后面会报 missing FROM-clause entry for table "dp"
JOIN device_profile dp ON dp.id = d.device_profile_id
LEFT JOIN LATERAL (
  SELECT long_v FROM attribute_kv
  WHERE entity_id=d.id AND attribute_type=2
    AND attribute_key=(SELECT key_id FROM key_dictionary WHERE key='meterLevel')) lv ON TRUE
LEFT JOIN LATERAL (
  SELECT str_v FROM attribute_kv
  WHERE entity_id=dp.id AND attribute_type=2
    AND attribute_key=(SELECT key_id FROM key_dictionary WHERE key='energyTypeCode')) pk ON TRUE
WHERE d.customer_id = (
    SELECT id FROM customer WHERE title = '平台演示中心')
ORDER BY 层级 NULLS LAST, d.name;
```

**判据**：汇总只收「档案有品种」的设备；`层级` 最小的那批决定取数
（1=进线总表优先，2=分项/回路）—— 这是为了不把总表 + 分表重复计一遍。

**实测基线**（2026-11-02）：

```
PowerMeter-3P-SIM·…  | 电能表     | 1    | elec
GasMeter-SIM·…       | 燃气表     | 2    | gas
HeatMeter-SIM·…      | 热力表     | 2    | heat
PowerMeter-DDSU666   | 单相电能表 | 2    | elec
SteamMeter-SIM·…     | 蒸汽表     | 2    | steam
WaterMeter-SIM·…     | 水表       | 2    | water
AHU-SIM·…            | 新风机组   | 0    | env
Breaker-SIM·…        | default    | 0    | (无品种)
Relay-8CH            | default    | 0    | (无品种)
Sensor-HZ8706        | 温湿度变送器| 0   | env
ED1-Gateway          | 网关       | 空   | (无品种)
```

**三个判据**：

- `层级 = 空` → **汇总取不到它**。这是「设备有数据、场站看板 0」最常见的原因，
  而且不报任何错。补法：`30-rtu-env-init.py` 会写；手工补用
  `POST /api/plugins/telemetry/DEVICE/{id}/SERVER_SCOPE {"meterLevel":2}`
- `档案品种 = (无品种)` → 不进任何能耗汇总（网关、可控设备正常如此）
- `层级 = 0` → 非计量设备，不进汇总（正确）

---

## 6. 网关关系：设备挂没挂在网关下

```sql
SELECT
  (SELECT name FROM device WHERE id = r.from_id) AS 网关,
  (SELECT name FROM device WHERE id = r.to_id)   AS 下游设备
FROM relation r
WHERE r.relation_type = 'Contains'
  AND r.from_id IN (SELECT id FROM device WHERE type = '网关')
ORDER BY 网关, 下游设备;
```

**正常**：每个网关下挂着它的设备。RTU 的 `main.py` 用
`v1/gateway/telemetry` 上报，TB 按**设备名**匹配 —— 名字对不上就会
「上报成功但数据落到另一台设备」或直接失败。

**异常**：设备不在任何网关下 → 网关上报的数据它收不到，只能走直连
（真实 RTU 板子只做网关模式）。

---

### 6.1 场站 / 区域 / 分项归属（三个能耗看板的前提）

**为什么单查这一条**：设备上的 `additionalInfo.siteId` 写得再对，看板也读不到 ——
综合能耗 / 分项能耗 / 区域能耗全部靠**关系**遍历。关系缺了，页面只会说
「当前筛选下没有可用计量点」，**不报错**。

```sql
-- 每台设备在哪个场站下（SiteContains），以及区域/分项分别挂到哪里
SELECT d.name AS 设备,
       (SELECT a.name FROM relation r JOIN asset a ON a.id = r.from_id
         WHERE r.to_id = d.id AND r.to_type = 'DEVICE'
           AND r.relation_type = 'SiteContains' LIMIT 1) AS 场站,
       (SELECT string_agg(a.name, ' / ') FROM relation r JOIN asset a ON a.id = r.from_id
         WHERE r.to_id = d.id AND r.to_type = 'DEVICE'
           AND r.relation_type = 'Contains' AND a.type = '区域') AS 区域,
       (SELECT string_agg(a.name, ' / ') FROM relation r JOIN asset a ON a.id = r.from_id
         WHERE r.to_id = d.id AND r.to_type = 'DEVICE'
           AND r.relation_type = 'Contains' AND a.type = '分项') AS 分项
FROM device d
WHERE d.customer_id = '<客户id>'
ORDER BY 场站, 设备;
```

**正常**：每台计量设备都有 `场站`，且 `区域`/`分项` 各**最多一个**。

| 现象 | 含义 | 处理 |
| --- | --- | --- |
| 场站 为空 | 看板里这台表根本不存在 | 重跑 `30-rtu-env-init.py` 第 ⑩ 步 |
| 区域或分项 有 **两个** | 历史演示数据留了脏边，区域能耗双算 | 重跑 `30-` 脚本，它会自动清旧边 |

---

### 6.2 分项/区域是按品种分键写的，`energy_total` 只给电

```sql
SELECT a.type AS 类型, a.name AS 资产, kd.key AS 键, count(*) AS 点数,
       round(sum(t.dbl_v)::numeric, 2) AS 合计
FROM ts_kv t
JOIN key_dictionary kd ON kd.key_id = t.key
JOIN asset a ON a.id = t.entity_id
WHERE t.ts > (extract(epoch from now()) * 1000)::bigint - 7 * 86400000
  AND kd.key IN ('energy_total','energy_day','power_total',
                 'water_total','gas_total','steam_total','heat_total')
  AND a.customer_id = '<客户id>'
GROUP BY 1, 2, 3 ORDER BY 1, 2, 3;
```

**判据**：

| 资产 | 应该有的键 |
| --- | --- |
| 装电表的场站/分项/区域 | `energy_total` + `energy_day` + `power_total` |
| 只装水/气/汽/热表 | 对应品种键（`water_total` 等），**没有 `energy_total`** |
| 维度容器（用能分项/用能区域根） | 子树的合计 |

> 「分项能耗」选**电能**时，燃气/水/汽/热分项是空的 —— 这是**正确**的，不是没数据。
> 切到对应品种才会出数。

---

### 6.2b 分项 / 区域能耗看板的数字怎么核对（统计准确性验收）

**什么时候用**：客户问「这个分布图的数字对不对」「分项和区域两页为什么差不多」
「合计是不是虚高了」。**不要凭观感点头**，一条 SQL 对到底。

**口径**（先记清这四条，否则算出来必定对不上）：

1. 看板读的是**资产的 `energy_total` 遥测**，不是设备、不是属性表 `attribute_kv`；
2. `energy_total` 是**每个时间桶的用量**（不是累积表底），所以区间合计 = `SUM`；
3. 分项与区域是**场站下两套并列分类**（`asset.type` = `分项` / `区域`），
   同一个场站下两者都存在 —— 交叉混入就会虚高约一倍；
4. 「按日」档是**单期**（只选一天），所以窗口 = 当天 `00:00` ~ 次日 `00:00`。

```sql
-- ① 某场站某一天，分项与区域各自的合计（把日期/场站 id 换掉）
SET TIME ZONE 'Asia/Shanghai';
WITH win AS (
  SELECT EXTRACT(EPOCH FROM (TIMESTAMP '2026-11-04 00:00:00' AT TIME ZONE 'Asia/Shanghai'))*1000 AS s,
         EXTRACT(EPOCH FROM (TIMESTAMP '2026-11-05 00:00:00' AT TIME ZONE 'Asia/Shanghai'))*1000 AS e
)
SELECT a.type AS 维度, a.label AS 名称,
       ROUND(SUM(COALESCE(kv.dbl_v, kv.long_v))::numeric, 2) AS 当日合计,
       count(*) AS 数据点
FROM relation r
JOIN asset a     ON a.id = r.to_id AND r.to_type = 'ASSET'
JOIN key_dictionary kd ON kd.key = 'energy_total'
JOIN ts_kv kv    ON kv.entity_id = a.id AND kv.key = kd.key_id
CROSS JOIN win
WHERE r.relation_type = 'Contains' AND r.relation_type_group = 'COMMON'
  AND r.from_id = '<场站资产id>'::uuid
  AND kv.ts >= win.s AND kv.ts < win.e
GROUP BY a.type, a.label
ORDER BY a.type, 当日合计 DESC;
```

**判据**（这就是「对」的样子）：

- `维度 = 分项` 的行加起来 = 分项能耗页分布图的「总用电量」；
- `维度 = 区域` 的行加起来 = 区域能耗页分布图的「总用电量」；
- **两个合计一般不相等**（两套分类各算各的），相等反而说明过滤没生效。

实测样例（演示厂区A / 办公园区 / 2026-11-04）：

| 维度 | 名称 | 当日合计 |
| --- | --- | --- |
| 分项 | 照明 | 297.83 |
| 分项 | 插座 | 0.90 |
| 区域 | 公共区域 | 406.97 |
| 区域 | A栋办公区 | 120.56 |

→ 分项页应显示 **298.73**，区域页应显示 **527.53**。

```sql
-- ② 换区间批量核对（近 N 天，按天出）
SELECT a.type AS 维度, a.label AS 名称,
       count(DISTINCT date_trunc('day', to_timestamp(kv.ts/1000) AT TIME ZONE 'Asia/Shanghai')) AS 天数,
       ROUND(SUM(COALESCE(kv.dbl_v, kv.long_v))::numeric, 2) AS 区间合计
FROM relation r
JOIN asset a ON a.id = r.to_id AND r.to_type = 'ASSET'
JOIN key_dictionary kd ON kd.key = 'energy_total'
JOIN ts_kv kv ON kv.entity_id = a.id AND kv.key = kd.key_id
WHERE r.relation_type = 'Contains' AND r.relation_type_group = 'COMMON'
  AND r.from_id = '<场站资产id>'::uuid
  AND kv.ts > (extract(epoch from now()) * 1000)::bigint - 7*86400000
GROUP BY a.type, a.label
ORDER BY a.type, 区间合计 DESC;
```

**三个已知的历史坑**（都实测踩过，见到对应现象直接按表处理）：

| 现象 | 根因 | 判据 |
| --- | --- | --- |
| 两页数字**完全相同**、合计约虚高一倍 | 消费部件没读 `childType`，分项和区域混算 | 分布图里出现「公共区域」（分项页）或「照明」（区域页） |
| 趋势图只有坐标轴、y 轴 `0.0~1.0`、一根柱都没有 | 读 `pt.value` 而接口返回 `pt.v` → 全 NaN | 浏览器里 `svg rect` 数为 0 |
| 趋势图空白，但分布图有数 | 趋势图下钻到叶子资产，而数据只到父级 | 叶子资产该区间 `energy_total` 为空 |

> 前两条是 2026-11-05 修掉的（`distribution_chart` / `asset_stats_chart`），
> 第三条同时修（趋势图在维度约束下不再下钻，与分布图同口径）。

---

### 6.2c 用能账单的数字怎么核对（含与分时拆解对不上时）

**什么时候用**：客户问「这张单为什么这么多钱」「账单页和分时拆解页金额不一样」
「账单是不是算错了」。

#### 先记死两件事，否则查出来全是空

**① 账单不在 `billing` 表**

`billing` / `billing_detail` 建好了但**没有任何写入方**（2026-11-06 实测各 0 行），
按它们查永远是空。账单是**资产**：

| 存什么 | 在哪 |
| --- | --- |
| 账单本体 | `asset`，`type = 'energy_bill'`，`name = BILL-<客户码>-<账期>-<品种>` |
| 账单字段 | `attribute_kv`，`attribute_type = 2`（SERVER_SCOPE） |
| 归属客户 | `asset.customer_id` |

**② 账单的金额字段存在 `str_v`，不是 `dbl_v`**

这是最容易踩的一条 —— 写成 `kv.dbl_v` 全部返回 NULL，看起来像「账单没数据」。

实测某张账单每个字段的落列（2026-11-06）：

| 存储列 | 字段 |
| --- | --- |
| `str_v` | `amount` `energyFee` `basicFee` `powerFactorFee` `surchargeFee` `usage` `ratio` `readingDelta` |
| `dbl_v` | `dataFrom` `dueDate` `generatedAt` `hourlyPoints` `meterLevel` |
| `bool_v` | `partialPeriod` |
| `json_v` | `details` |
| `str_v`（标识类） | `period` `energy` `unit` `status` `billingNo` `deviceId` `deviceName` `customerId` |

所以取数值一律用（片段，不是完整语句）：

```
coalesce(kv.dbl_v, nullif(kv.str_v, '')::numeric)
```

> 手册里的 ```sql 代码块会被 `check-docs.py` **真实执行**校验，
> 所以纯片段不要标 sql 语言，否则校验会报语法错误。

#### ① 某客户某账期，逐张核对（最常用）

```sql
SET TIME ZONE 'Asia/Shanghai';
WITH b AS (
  SELECT a.id,
    max(CASE WHEN kd.key='deviceName' THEN kv.str_v END) AS 计量点,
    max(CASE WHEN kd.key='period'     THEN kv.str_v END) AS 账期,
    max(CASE WHEN kd.key='energyFee'  THEN coalesce(kv.dbl_v, nullif(kv.str_v,'')::numeric) END) AS 电度,
    max(CASE WHEN kd.key='basicFee'   THEN coalesce(kv.dbl_v, nullif(kv.str_v,'')::numeric) END) AS 基本,
    max(CASE WHEN kd.key='powerFactorFee' THEN coalesce(kv.dbl_v, nullif(kv.str_v,'')::numeric) END) AS 力调,
    max(CASE WHEN kd.key='surchargeFee'   THEN coalesce(kv.dbl_v, nullif(kv.str_v,'')::numeric) END) AS 附加,
    max(CASE WHEN kd.key='amount'     THEN coalesce(kv.dbl_v, nullif(kv.str_v,'')::numeric) END) AS 应付
  FROM asset a
  JOIN attribute_kv kv ON kv.entity_id = a.id AND kv.attribute_type = 2
  JOIN key_dictionary kd ON kd.key_id = kv.attribute_key
  WHERE a.type = 'energy_bill' AND a.customer_id = '<客户id>'::uuid
  GROUP BY a.id
)
SELECT 计量点, 电度, 基本, 应付,
       round((coalesce(电度,0)+coalesce(基本,0)+coalesce(力调,0)+coalesce(附加,0))::numeric,2) AS 四项之和,
       round((应付 - (coalesce(电度,0)+coalesce(基本,0)+coalesce(力调,0)+coalesce(附加,0)))::numeric,2) AS 差
FROM b WHERE 账期 = '2026-11' ORDER BY 应付 DESC;
```

**判据 ①**：`应付 = 电度 + 基本 + 力调 + 附加`，`差` 应为 **0.00**（浮点四舍五入允许 0.01）。

实测（演示厂区A / 2026-11，19 张全部 `差 = 0.00`）：

| 计量点 | 电度 | 基本 | 应付 |
| --- | --- | --- | --- |
| 三相园-1#进线总表 | 12,004.42 | 1,500 | 13,504.42 |
| 三相园-车间动力总表 | 11,059.27 | 0 | 11,059.27 |
| 单相园-1#进线总表 | 264.48 | 1,500 | 1,764.48 |

#### ② 汇总构成

```sql
SELECT count(*) AS 账单数,
       round(sum(amount)::numeric,2)     AS 应付合计,
       round(sum(energy_fee)::numeric,2) AS 电度合计,
       round(sum(coalesce(basic_fee,0))::numeric,2) AS 基本合计,
       round(sum(coalesce(pf_fee,0))::numeric,2)    AS 力调合计,
       round(sum(coalesce(sur_fee,0))::numeric,2)   AS 附加合计
FROM (
  SELECT a.id,
    max(CASE WHEN kd.key='amount'     THEN coalesce(kv.dbl_v, nullif(kv.str_v,'')::numeric) END) AS amount,
    max(CASE WHEN kd.key='energyFee'  THEN coalesce(kv.dbl_v, nullif(kv.str_v,'')::numeric) END) AS energy_fee,
    max(CASE WHEN kd.key='basicFee'   THEN coalesce(kv.dbl_v, nullif(kv.str_v,'')::numeric) END) AS basic_fee,
    max(CASE WHEN kd.key='powerFactorFee' THEN coalesce(kv.dbl_v, nullif(kv.str_v,'')::numeric) END) AS pf_fee,
    max(CASE WHEN kd.key='surchargeFee'   THEN coalesce(kv.dbl_v, nullif(kv.str_v,'')::numeric) END) AS sur_fee
  FROM asset a
  JOIN attribute_kv kv ON kv.entity_id = a.id AND kv.attribute_type = 2
  JOIN key_dictionary kd ON kd.key_id = kv.attribute_key
  WHERE a.type='energy_bill' AND a.customer_id = '<客户id>'::uuid
  GROUP BY a.id) x;
```

实测：`19 | 56,746.35 | 53,746.35 | 3,000.00 | 0.00 | 0.00`
（53,746.35 + 3,000 = 56,746.35 ✓，基本电费正好是两张进线表各 1,500）

#### ③ 按月汇总（核对月度趋势）

```sql
WITH b AS (
  SELECT a.id,
    max(CASE WHEN kd.key='period' THEN kv.str_v END) AS period,
    max(CASE WHEN kd.key='amount' THEN coalesce(kv.dbl_v, nullif(kv.str_v,'')::numeric) END) AS amount
  FROM asset a
  JOIN attribute_kv kv ON kv.entity_id = a.id AND kv.attribute_type = 2
  JOIN key_dictionary kd ON kd.key_id = kv.attribute_key
  WHERE a.type='energy_bill' AND a.customer_id = '<客户id>'::uuid
    AND kd.key IN ('period','amount')
  GROUP BY a.id)
SELECT period AS 账期, count(*) AS 账单数, round(sum(amount)::numeric,2) AS 合计
FROM b GROUP BY period ORDER BY period;
```

#### ④ 账单是否重复（出账幂等被破坏时）

```sql
WITH b AS (
  SELECT a.id,
    max(CASE WHEN kd.key='period'   THEN kv.str_v END) AS period,
    max(CASE WHEN kd.key='energy'   THEN kv.str_v END) AS energy,
    max(CASE WHEN kd.key='deviceId' THEN kv.str_v END) AS device_id
  FROM asset a
  JOIN attribute_kv kv ON kv.entity_id = a.id AND kv.attribute_type = 2
  JOIN key_dictionary kd ON kd.key_id = kv.attribute_key
  WHERE a.type = 'energy_bill' GROUP BY a.id)
SELECT period, energy, device_id, count(*) AS 张数
FROM b GROUP BY 1,2,3 HAVING count(*) > 1;
```

**判据 ④**：结果应为**空**。出账幂等靠「资产名 = `BILL-<客户码>-<账期>-<能源>`」，
重跑只更新属性不新增。出现多行说明资产名规则被改过，或有手工建的账单。

#### 账单页和「分时拆解」页金额不一样 —— 两个数都没错

**实测样例**（三相园-1#进线总表 / 2026-11）：

| 页面 | 显示 | 含义 |
| --- | --- | --- |
| 账单明细 | 13,504.42 | **应付金额**（含基本电费） |
| 分时拆解 | 12,004.41 | **分时电度电费**（按逐时遥测 × 分时单价） |
| 差额 | **1,500.00** | 就是该表的基本电费 |

**只算电**的全客户核对（2026-11，与上面 ② 的全品种口径不同）：

```
分时拆解 feeTotal 合计        35,337.36
全部电费账单 energyFee 合计   35,337.36   ← 完全相等
全部电费账单 amount 合计      38,337.36
差额                           3,000.00   ← 两张进线表各 1,500 基本电费
```

所以界面上有一条对账：`分时电度电费 + 不可分摊 = 应付合计`，
其中「应付合计」一定与账单明细相等。这两个数永远对不上才是 bug。

**金额对不上时的排查顺序**：

1. 跑 ②，看 `应付合计` 是否等于页面「合计」 —— 不等是页面取数问题；
2. 相等，再看差额是否正好等于 `基本合计` —— 是则属口径正常，不是 bug；
3. 都不是，查分时单价与时段方案（见 §7 档案）。

#### 某台表没有账单 —— 是「还没出账」，不是「算错了」

**典型现象**：客户在「用能账单」里只勾几台表，结果列表里只出现一台，
其余几台什么都不显示（连「0 元」都没有）。

**根因：账单是一份快照，不是实时算的。** 出账（`POST /api/energy/billing/generate`）
写一次 `energy_bill` 资产，之后**不会自动重算** —— 设备后来才有表底数据，
也还是没它的账单，直到重新出账。

**测一下有没有漏出账**（该账期有表底、但库里没账单的设备）：

```sql
SET TIME ZONE 'Asia/Shanghai';
WITH p AS (SELECT '2026-11'::text AS period),
win AS (
  SELECT EXTRACT(EPOCH FROM (to_date(period||'-01','YYYY-MM-DD')::timestamp AT TIME ZONE 'Asia/Shanghai'))*1000 AS s,
         EXTRACT(EPOCH FROM ((to_date(period||'-01','YYYY-MM-DD') + INTERVAL '1 month')::timestamp AT TIME ZONE 'Asia/Shanghai'))*1000 AS e
  FROM p
),
billed AS (
  SELECT max(CASE WHEN kd.key='deviceId' THEN kv.str_v END)::uuid AS dev
  FROM asset a
  JOIN attribute_kv kv ON kv.entity_id=a.id AND kv.attribute_type=2
  JOIN key_dictionary kd ON kd.key_id=kv.attribute_key
  WHERE a.type='energy_bill'
    AND a.id IN (SELECT kv2.entity_id FROM attribute_kv kv2
                 JOIN key_dictionary kd2 ON kd2.key_id=kv2.attribute_key
                 WHERE kd2.key='period' AND kv2.str_v=(SELECT period FROM p))
  GROUP BY a.id
),
pts AS (
  SELECT kv.entity_id AS dev, count(*) AS 表底点数,
         min(kv.ts) AS 最早, max(kv.ts) AS 最晚
  FROM key_dictionary kd JOIN ts_kv kv ON kv.key=kd.key_id CROSS JOIN win
  WHERE kd.key='energy_reading' AND kv.ts>=win.s AND kv.ts<win.e
  GROUP BY kv.entity_id
)
SELECT d.label AS 设备, d.type AS 类型, pts.表底点数,
       to_char(to_timestamp(pts.最早/1000) AT TIME ZONE 'Asia/Shanghai','MM-DD HH24:MI') AS 最早,
       to_char(to_timestamp(pts.最晚/1000) AT TIME ZONE 'Asia/Shanghai','MM-DD HH24:MI') AS 最晚
FROM pts JOIN device d ON d.id = pts.dev
WHERE pts.表底点数 >= 2 AND pts.dev NOT IN (SELECT dev FROM billed WHERE dev IS NOT NULL)
ORDER BY pts.表底点数 DESC;
```

**判据**：结果非空就是「有数据但没出账」，而不是「算成了 0」。
实测 2026-11：13 台（DDSU666 5102 点、三相/单相电表各 483 点、新风机组各 85 点…）
都在这张列表里 —— 它们的表底是 11-04 之后才补进来的，而账单是 11-04 00:33 出的。

**「是不是还没出账」最快判据**：调一次 `dryRun`（只算不写），它会逐台返回
`usable` 与跳过原因：

```bash
curl -s --noproxy '*' -X POST -H "X-Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"period":"2026-11","dryRun":true}' \
  http://127.0.0.1:8090/api/energy/billing/generate \
  | python3 -c "import sys,json;d=json.load(sys.stdin);
print('total',d['total'],'skipped',d['skipped']);
[print(i.get('deviceName'),i.get('usable'),i.get('reason')) for i in d['items'] if not i.get('usable')]"
```

只有两种 `usable=false` 是正常的：

- `未配置「X」的电价` —— 该品种没有绑定费率模板（新风/热水泵是 env，本来就不计价）
- `本账期读数不足两点` —— 设备未上报

其余一律是真漏出账，重新生成即可（幂等，只更新不新增）。

#### 分时拆解的数字怎么复算（账期首小时会被跳过）

**统计口径**（`EnergyBillingService#readUsage`，2026-11-06 逐行核过）：

```
① 读 energy_reading（表底累计读数），按【小时 MAX】聚合
② TB 的聚合桶返回的 ts 是【桶中点】—— 整点时段的桶给 xx:30，⚠ 不是整点
③ 过滤 ts <= 账期起点 + 1h → 【丢掉账期第一个小时】
④ 相邻两点差分 × 倍率 = 该小时用量
⑤ 差分归入【后一个点】所在的 TOU 时段（峰/平/谷/深/尖峰）
⑥ 各档用量分别 × 单价，各档金额先取两位小数再相加 = 电度电费
```

**③ 这一条会让每月少算第一小时**。实测单相园-1#进线总表 2026-11：

```
账期 11-01 00:00 ~ 12-01 00:00
桶：00:30=7789.77  01:30=7792.09  02:30=7794.33 …
后端丢掉 00:30 → 从 01:30 起算 → 漏掉 00:00→01:00 这一段 2.32 kWh
账单 338.49 vs 含首小时的 340.81（0.7%）
```

这是**已知偏差**，不是随机误差：对每台表、每个月都等于「账期第一个小时用量」。
要修得改后端（读 `[from-1h, to]`，用 from 之前的最后一个读数做基线），
会改变已出账金额，需要客户确认后再动。

**独立复算（与上面的口径逐字对应）**：

```sql
SET TIME ZONE 'Asia/Shanghai';
WITH p AS (SELECT '2026-11'::text AS period),
win AS (
  SELECT EXTRACT(EPOCH FROM (to_date(period||'-01','YYYY-MM-DD')::timestamp AT TIME ZONE 'Asia/Shanghai'))*1000 AS s,
         EXTRACT(EPOCH FROM ((to_date(period||'-01','YYYY-MM-DD') + INTERVAL '1 month')::timestamp AT TIME ZONE 'Asia/Shanghai'))*1000 AS e
  FROM p
),
raw AS (
  SELECT a.id AS bill_id, kd.key, kv.str_v, kv.dbl_v
  FROM asset a
  JOIN attribute_kv kv ON kv.entity_id = a.id AND kv.attribute_type = 2
  JOIN key_dictionary kd ON kd.key_id = kv.attribute_key
  WHERE a.type='energy_bill'
    AND kd.key IN ('period','deviceId','deviceName','usage','usageSource','hourlyPoints')
),
bills AS (
  SELECT bill_id,
         max(CASE WHEN key='deviceId'   THEN str_v END) AS dev_id,
         max(CASE WHEN key='deviceName' THEN str_v END) AS 计量点,
         max(CASE WHEN key='usageSource' THEN str_v END) AS 来源,
         max(CASE WHEN key='usage'      THEN str_v END)::numeric AS 账单用量,
         max(CASE WHEN key='hourlyPoints' THEN dbl_v END)::int   AS 账单点数
  FROM raw
  WHERE bill_id IN (SELECT bill_id FROM raw WHERE key='period' AND str_v=(SELECT period FROM p))
  GROUP BY bill_id
),
h AS (
  -- 桶 ts = 桶起始 + 30min，与 TB 聚合桶中点一致
  SELECT kv.entity_id AS dev,
         (EXTRACT(EPOCH FROM date_trunc('hour', to_timestamp(kv.ts/1000)))*1000 + 1800000)::bigint AS ts,
         max(kv.dbl_v) AS reading
  FROM key_dictionary kd JOIN ts_kv kv ON kv.key=kd.key_id CROSS JOIN win
  WHERE kd.key='energy_reading' AND kv.ts>=win.s AND kv.ts<win.e
  GROUP BY 1,2
),
seq AS (
  SELECT h.dev, h.ts, h.reading,
         lag(h.reading) OVER (PARTITION BY h.dev ORDER BY h.ts) AS prev
  FROM h CROSS JOIN win WHERE h.ts > win.s + 3600000
),
calc AS (
  SELECT dev, round(sum(reading - prev)::numeric,4) AS 重算用量, count(*) AS 重算点数
  FROM seq WHERE prev IS NOT NULL GROUP BY dev
)
SELECT b.计量点, b.来源, b.账单用量, c.重算用量,
       round((b.账单用量 - coalesce(c.重算用量,0))::numeric,4) AS 差异,
       b.账单点数, c.重算点数,
       CASE WHEN b.来源 <> 'telemetry' THEN '（手工/非遥测）'
            WHEN abs(b.账单用量 - coalesce(c.重算用量,0)) < 0.01 THEN '✓'
            ELSE '✗' END AS 判定
FROM bills b LEFT JOIN calc c ON c.dev = b.dev_id::uuid
WHERE b.来源 = 'telemetry'
ORDER BY 判定 DESC, b.计量点;
```

**判据**：全部 `✓`，`差异` 均为 `0.0000`；
`账单点数 - 重算点数 = 1`（差的就是被丢掉的首小时）。
实测 2026-11：17 张遥测账单全部 ✓。

**分时电费复算**（各档金额先取两位再相加，不是先加再取两位）：

```
电度电费 = round(tip用量×1.35,2) + round(peak用量×1.15,2)
         + round(flat用量×0.72,2) + round(valley用量×0.38,2)
         + round(deep用量×0.25,2)
```

实测单相园-1#进线总表：`0×1.35 + 123.46×1.15 + 134.52×0.72 + 42.41×0.38 + 38.10×0.25`
= `0 + 141.98 + 96.85 + 16.12 + 9.53` = **264.48** ✓（若先加再取两位会得 264.47，差 1 分）。

> **单价不一定取上面这五个数**：以账单 `details` 里回写的 `prices` 为准。
> 水/气/汽走单一单价（`flat`），实测水 4.5 元/m³、燃气 3.6 元/m³、蒸汽 260 元/t。

#### 已知坑

| 现象 | 根因 | 判据 |
| --- | --- | --- |
| 按 `billing` 表查永远 0 行 | 账单存 `asset` 资产，不写那两张表 | `SELECT count(*) FROM billing` = 0 |
| SQL 能跑但金额列全是空 | 金额字段在 `str_v`，写成 `kv.dbl_v` | 用 `coalesce(kv.dbl_v, nullif(kv.str_v,'')::numeric)` |
| 账单页总额远大于「实际用电」 | 账单按表逐张出，含上下级重复（总表+分表各一张），供分层分摊 | 见页面绿色「实际用电/实际电费」条 |
| 客户看不到别人的账单 | TB owner 机制：`asset.customer_id` 隔离 | 租户账号查是全量 |

---

### 6.2d 基础报表 / 参数报表的数字怎么核对

**什么时候用**：客户问「图上这条线对不对」「明细表某个格子为什么是 `/`」
「合计跟别处对不上」。

**口径**（三条，缺一条就对不上）：

1. 报表读的是**设备遥测的原始键**（`energy` / `voltage_a` / `power_total` …），
   不是资产的汇总键（`energy_total` 那套是分项/区域能耗用的）；
2. 页面按**时间片聚合**：`interval=3600000&agg=SUM` 表示"每小时求和"，
   所以核对也要先按小时 `SUM`，别直接拿原始点求和；
3. **同一小时可能有多条原始点**（演示数据 10 分钟一条），按小时 SUM 后才是页面上的格子值。

```sql
-- ① 某设备某天，按小时聚合（与页面 interval=3600000 完全同口径）
SET TIME ZONE 'Asia/Shanghai';
WITH win AS (
  SELECT EXTRACT(EPOCH FROM (TIMESTAMP '2026-11-04 00:00:00' AT TIME ZONE 'Asia/Shanghai'))*1000 AS s,
         EXTRACT(EPOCH FROM (TIMESTAMP '2026-11-05 00:00:00' AT TIME ZONE 'Asia/Shanghai'))*1000 AS e
), h AS (
  SELECT kv.entity_id,
         date_trunc('hour', to_timestamp(kv.ts/1000) AT TIME ZONE 'Asia/Shanghai') AS 小时,
         sum(kv.dbl_v) AS 值, count(*) AS 原始点数
  FROM key_dictionary kd
  JOIN ts_kv kv ON kv.key = kd.key_id
  CROSS JOIN win
  WHERE kd.key = 'energy' AND kv.ts >= win.s AND kv.ts < win.e
  GROUP BY kv.entity_id, 小时
)
SELECT d.label AS 设备, h.小时, round(h.值::numeric, 2) AS 小时值, h.原始点数
FROM h JOIN device d ON d.id = h.entity_id
WHERE d.id = '<设备id>'::uuid
ORDER BY h.小时;
```

**判据**：页面「数据明细」页签里该设备的每个非 `/` 格子 = 上表对应小时的 `小时值`；
格子数 = 有数据的小时数。

```sql
-- ② 全天合计与极值（核对图上的峰值标注与整日合计）
SET TIME ZONE 'Asia/Shanghai';
WITH win AS (
  SELECT EXTRACT(EPOCH FROM (TIMESTAMP '2026-11-04 00:00:00' AT TIME ZONE 'Asia/Shanghai'))*1000 AS s,
         EXTRACT(EPOCH FROM (TIMESTAMP '2026-11-05 00:00:00' AT TIME ZONE 'Asia/Shanghai'))*1000 AS e
), h AS (
  SELECT kv.entity_id,
         date_trunc('hour', to_timestamp(kv.ts/1000) AT TIME ZONE 'Asia/Shanghai') AS 小时,
         sum(kv.dbl_v) AS 值
  FROM key_dictionary kd
  JOIN ts_kv kv ON kv.key = kd.key_id
  CROSS JOIN win
  WHERE kd.key = 'energy' AND kv.ts >= win.s AND kv.ts < win.e
  GROUP BY kv.entity_id, 小时
)
SELECT d.label AS 设备, count(*) AS 有数小时,
       round(sum(h.值)::numeric, 2) AS 全天合计,
       round(min(h.值)::numeric, 2) AS 小时最小,
       round(max(h.值)::numeric, 2) AS 小时最大
FROM h JOIN device d ON d.id = h.entity_id
WHERE d.id IN ('<设备id>'::uuid, '<设备id>'::uuid)
GROUP BY d.label ORDER BY 全天合计 DESC;
```

**判据**：`小时最大` = 图上峰值标注；`有数小时` = 明细表里该行的非 `/` 格数。

**实测样例**（演示厂区A / 办公园区 / 2026-11-04，与页面逐项核对一致）：

| 设备 | 有数小时 | 全天合计 | 小时最小 | 小时最大 | 页面 |
| --- | --- | --- | --- | --- | --- |
| 单相电表 | 9 | 296.57 | 0.59 | 101.78 | 峰值标签 `101.8`、明细 9 格合计 `296.58` |
| 1#进线总表 | 1 | 2.21 | 2.21 | 2.21 | 明细首格 `2.21` |

> 明细 9 格手工相加是 296.58、SQL 是 296.57 —— 差 0.01 是**每格已四舍五入到两位**
> 再相加造成的，属正常；核对时看「到分」即可，不要追到厘。

#### ⚠️ 核对时最容易踩的一条：`label` 不唯一

演示数据里**两台设备 label 都叫「1#进线总表」**：

| name | label |
| --- | --- |
| `单相园-1#进线总表·演示厂区A` | `1#进线总表` |
| `三相园-1#进线总表·演示厂区A` | `1#进线总表` |

按 `WHERE d.label = '1#进线总表'` 查会把两台加在一起（实测 62.51 = 2.21 + 60.30），
而页面只画了一台（2.21）—— 看着像"页面少了一半数据"，其实是 SQL 多算了。

**核对一律用 `d.id`，不要用 `label` / `name` 之外的模糊条件**。
要按可读名查就先跑一次 `SELECT id, name, label FROM device WHERE label = '…'`，
确认只命中一台。

---

### 6.2e 手工填报的数字怎么核对

**什么时候用**：客户问「我填的数怎么没上去」「合计跟 Excel 对不上」
「某个月为什么是空的」。

**口径**（三条，和报表页完全不同，别套 §6.2d 的聚合）：

1. 手工填报只认**虚拟设备**的 `energy` 键；接了 RTU 的真实表不在候选里，
   查真实表得到 0 行是正常的，不是故障。
2. 每个设备每个月**只有 1 个点**，时间戳是**该月 1 日 00:00**，值就是这个月的用量。
   所以核对**直接 `SUM(dbl_v)`，不要再按日/小时聚合** —— 再切一次时间片会把一个点拆散。
3. 页面的「合计」= 所选月份区间内所有点之和；**未来月份没有点 → 画空柱**，
   空柱不等于 0，也不等于漏填。

```sql
-- ① 某虚拟设备逐月用量（与页面抽屉里的 12 个格子、月度用量柱一一对应）
SET TIME ZONE 'Asia/Shanghai';
WITH win AS (
  SELECT EXTRACT(EPOCH FROM (TIMESTAMP '2026-01-01 00:00:00' AT TIME ZONE 'Asia/Shanghai'))*1000 AS s,
         EXTRACT(EPOCH FROM (TIMESTAMP '2027-01-01 00:00:00' AT TIME ZONE 'Asia/Shanghai'))*1000 AS e
)
SELECT to_char(date_trunc('month', to_timestamp(kv.ts/1000) AT TIME ZONE 'Asia/Shanghai'),
               'YYYY-MM') AS 月,
       round(sum(kv.dbl_v)::numeric, 2) AS 用量, count(*) AS 点数
FROM key_dictionary kd
JOIN ts_kv kv ON kv.key = kd.key_id
CROSS JOIN win
WHERE kd.key = 'energy'
  AND kv.entity_id = '<虚拟设备id>'::uuid
  AND kv.ts >= win.s AND kv.ts < win.e
GROUP BY 月 ORDER BY 月;
```

```sql
-- ② 全年合计与数据跨度（核对页面顶部的「合计」）
SET TIME ZONE 'Asia/Shanghai';
SELECT to_char(to_timestamp(min(kv.ts)/1000) AT TIME ZONE 'Asia/Shanghai','YYYY-MM-DD') AS 最早,
       to_char(to_timestamp(max(kv.ts)/1000) AT TIME ZONE 'Asia/Shanghai','YYYY-MM-DD') AS 最晚,
       round(sum(kv.dbl_v)::numeric, 2) AS 合计,
       count(*) AS 点数
FROM key_dictionary kd
JOIN ts_kv kv ON kv.key = kd.key_id
WHERE kd.key = 'energy' AND kv.entity_id = '<虚拟设备id>'::uuid;
```

**判据**：

- `点数` = 实际填过的月份数（**不是 12** 就说明有空月，属正常）；
- 页面「合计」= ② 的 `合计`；抽屉里逐月的数 = ① 的 `用量`；
- 页面上空着的月 = ① 里没有该月的行（不是 0）。

**实测样例**（演示厂区A / 空调虚拟表 `c4e37c80-d7a3-11f1-b139-b367a33eb8e4`，2026 年）：

| 月 | 用量 | 月 | 用量 |
| --- | --- | --- | --- |
| 2026-01 | 1820.00 | 2026-07 | 1450.00 |
| 2026-02 | 1650.00 | 2026-08 | 1780.00 |
| 2026-03 | 980.00 | 2026-09 | 1520.00 |
| 2026-04 | 420.00 | 2026-10 | 760.00 |
| 2026-05 | 310.00 | 2026-11 | 480.00 |
| 2026-06 | 620.00 | 2026-12 | （无点，空柱） |

合计 `11790.00`、`点数 11`、跨度 `2026-01-01 ~ 2026-11-01` ——
与页面「合计 11.8k kW·h」、12 根柱（12 月空）、抽屉里 11 个有数格完全一致。

**为什么 12 月是空的**：演示数据只填到 2026-11；页面按区间铺 12 根柱，
没点的月份画空柱。**不要把它当成 bug 去补 0** —— 补 0 会和「填了 0 度」混淆。

**两个容易误判的现象**：

- **虚拟表在分项/区域能耗里缺席**：先看设备的「参与厂站能耗计算」开关。
  关掉后手工填报页照常能填能看，但分项/区域汇总不含它（详见 §6.2b）。
- **改了数页面没变**：抽屉「保存」写的是资产/设备遥测，保存后要**点查询**才刷新；
  另外浏览器缓存会让旧值停留，`Cmd/Ctrl + Shift + R` 硬刷新一次。

---

### 6.3 哨兵读数：真实表底会突然变成 7777.7 / 8888.8

```sql
-- 找明显超出量程的表底（按现场实际量程改阈值）
SELECT d.name AS 设备, to_timestamp(t.ts/1000) AS 时间, t.dbl_v AS 表底
FROM ts_kv t
JOIN key_dictionary kd ON kd.key_id = t.key
JOIN device d ON d.id = t.entity_id
WHERE kd.key = 'energy_reading' AND t.dbl_v > 100
ORDER BY t.ts DESC LIMIT 20;
```

**实测**：DDSU666 在调试期上报过 `7777.7` 和 `8888.8`（正常值 8.37~8.47）。
差分后插座分项变成 1111.2 kW·h，而实际负载只有 0.1 kW。

清理后**必须重算汇总**，否则资产上的旧值还在：

```sql
-- ① 删掉哨兵读数（确认是垃圾再删）
DELETE FROM ts_kv
WHERE entity_id = '<设备id>'
  AND key = (SELECT key_id FROM key_dictionary WHERE key = 'energy_reading')
  AND dbl_v > 100;
```

```bash
# ② 重算
curl -X POST http://127.0.0.1:8090/api/energy/asset-totals/rebuild \
  -H "X-Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{}'
```

---

## 7. 档案：品种标注对不对

```sql
SELECT dp.name AS 档案,
       COALESCE(k.str_v,  '(无品种)') AS 品种,
       COALESCE(m.bool_v::text, '∅')   AS 是否计量,
       COALESCE(s.long_v::text, '∅')   AS 排序
FROM device_profile dp
LEFT JOIN LATERAL (
  SELECT str_v FROM attribute_kv
  WHERE entity_id=dp.id AND attribute_type=2
    AND attribute_key=(SELECT key_id FROM key_dictionary WHERE key='energyTypeCode')) k ON TRUE
LEFT JOIN LATERAL (
  SELECT bool_v FROM attribute_kv
  WHERE entity_id=dp.id AND attribute_type=2
    AND attribute_key=(SELECT key_id FROM key_dictionary WHERE key='isMeter')) m ON TRUE
LEFT JOIN LATERAL (
  SELECT long_v FROM attribute_kv
  WHERE entity_id=dp.id AND attribute_type=2
    AND attribute_key=(SELECT key_id FROM key_dictionary WHERE key='meterTypeSort')) s ON TRUE
WHERE dp.name NOT IN ('default','thermostat')
ORDER BY 排序 NULLS LAST, 档案;
```

**正常**：

```
单相电能表       | elec  | true  | 10
电能表           | elec  | true  | 15
水表             | water | true  | 20
燃气表           | gas   | true  | 30
蒸汽表           | steam | true  | 40
热力表           | heat  | true  | 45
温湿度变送器     | env   | false | 50
室内环境变送器   | env   | false | 55
新风机组         | env   | false | 60
锅炉 / 热水泵    | env   | false | —
网关             | (无品种) | false | —
```

**要点**：环境类设备（温湿度/新风/锅炉/热水泵）品种必须是 `env` 而不是
`elec` —— 归到电能会让它们出现在按「电能」筛选的台账里，还会让没声明品种的
场站被推断成「这个场站用电」（客户 2026-11-02 明确定的口径）。

---

## 8. 抄表：能不能读出台底

不用 SQL 也能查，用接口更直观：

```bash
# 列出抄表候选（含 role / deviceType1）
curl -s -H "X-Authorization: Bearer $TOKEN" \
  'http://127.0.0.1:8090/api/energy/meters' | python3 -m json.tool | head -40

# 对某台表执行一次抄表
curl -s -X POST -H "X-Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  'http://127.0.0.1:8090/api/energy/meter-reading/run' \
  -d '{"deviceIds":["<设备 id>"],"period":"day"}'
```

**正常**：`state: normal`，`metrics.energy_reading` 有值。

对应的 SQL 核查（抄表结果存在属性里）：

```sql
SELECT d.name,
       COALESCE(lr.str_v, '∅')                    AS 最后读数,
       to_char(to_timestamp((lv.long_v)/1000)::timestamp,'MM-DD HH24:MI') AS 抄表时间,
       COALESCE(q.str_v, '∅')                     AS 质量
FROM device d
LEFT JOIN LATERAL (
  SELECT str_v FROM attribute_kv
  WHERE entity_id=d.id AND attribute_type=2
    AND attribute_key=(SELECT key_id FROM key_dictionary WHERE key='lastReading')) lr ON TRUE
LEFT JOIN LATERAL (
  SELECT long_v FROM attribute_kv
  WHERE entity_id=d.id AND attribute_type=2
    AND attribute_key=(SELECT key_id FROM key_dictionary WHERE key='lastReadingTs')) lv ON TRUE
LEFT JOIN LATERAL (
  SELECT str_v FROM attribute_kv
  WHERE entity_id=d.id AND attribute_type=2
    AND attribute_key=(SELECT key_id FROM key_dictionary WHERE key='lastUsageQuality')) q ON TRUE
WHERE lr.str_v IS NOT NULL
ORDER BY lv.long_v DESC NULLS LAST;
```

**质量字段的取值**：

| 值 | 含义 | 什么时候出现 |
| --- | --- | --- |
| `normal` | 正常 | 数据在采集周期内 |
| `stale` | 数据陈旧 | 模拟器停了 / RTU 掉线（实测文案：`设备未上报新数据（数据采集于 …）`） |
| `abnormal` | 表底倒流或跳变 | 见 §3.2 |
| `first` | 首次抄表，建立基线 | 刚初始化完第一次抄 |

**`stale` 不是 bug** —— 只要 `31-rtu-simulate.py` 在跑，抄表就是 `normal`；
停了十几分钟再抄必然 `stale`。演示前确认模拟器在跑就行。

对应 `quality` 字段：`normal` / `estimated`（估算）等。`estimated` 配合 `stale`
出现时表示「用的是最后已知值，不是新数据」。

---


---

## 8.5 按功能对照查（页面数字从哪来）

每个功能页读的东西不同。**页面数字不对时，先用这张表定位该查哪**。

| 功能页 | 主要读 | 关键点 |
| --- | --- | --- |
| 能耗概览 | 资产 `energy_total` / `energy_day` | 跨场站概览，顶栏无场站选择器 |
| 实时能耗 | 设备 `energy` / `power_total` | 走查询设置的设备树 |
| 历史能耗 | 设备 `energy_reading` 差分 | 单相表只有 A 相 |
| 分项能耗 | 分项资产各品种 `*_total` | 选电能时水/气/汽/热为空，正常 |
| 区域能耗 | 区域资产各品种 `*_total` | 同一台表挂两个区域会双算 |
| 峰谷分析 | 设备 `energy_reading` 按小时切片 | 与台账口径不同，不是 bug |
| 用能账单 | **`asset`（`type='energy_bill'`）+ `attribute_kv`** | 金额 = 电度 + 基本 + 力调 + 其他；**不在 `billing` 表**（空表） |
| 抄表台账 | `meter_reading_record` / `meter_reading_batch` | 「用量来源」列说明用的是哪种（`source` = auto/manual） |
| 电能质量 | 设备 `voltage_thd_*` / `unbalance` / `flicker_*` | 逐桶判极值，不用均值 |
| 告警事件 | `alarm` 表 | 只读未清除的（`clear_ts IS NULL`） |

### 口径提示（对不上时先看这三条）

| 差异 | 原因 |
| --- | --- |
| 峰谷合计 ≠ 台账用量 | 峰谷按「时段切片」，台账按「抄表周期」，边界不同 |
| 分项合计 > 场站总量 | 有表挂了两个分项，重复计 |
| 场站总量 = 分项合计 × 2 | 总表与分表都被当成根，`parentDeviceId` 没配 |

### 一张表看清「每个页面读什么键」

```sql
-- 某客户下所有资产，各自有哪些品种的汇总键、多少点
SELECT a.type AS 资产类型, a.name AS 资产,
       kd.key,
       count(*) AS 点数,
       round(sum(t.dbl_v)::numeric, 2) AS 合计,
       to_timestamp(max(t.ts)/1000) AS 最新
FROM ts_kv t
JOIN key_dictionary kd ON kd.key_id = t.key
JOIN asset a ON a.id = t.entity_id
WHERE a.customer_id = '<客户id>'
  -- ★ 括号不能省：AND 优先级高于 OR，写成
  --   `customer_id = X AND key LIKE ... OR key = 'energy_day'`
  --   后半段会返回**所有客户**的 energy_day（能跑、不报错、结果错）。
  -- 另：LIKE 里的 `_` 是通配符，要匹配字面下划线必须转义。
  AND (kd.key LIKE '%\_total' ESCAPE '\' OR kd.key = 'energy_day')
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;
```

**判据**：场站有电/水/气三项、分项有对应品种项、区域有对应品种项 ——
三者对得上才说明汇总完整。

---

## 9. 表结构与空间

### 9.1 哪些表在长

```sql
-- 按表大小排序（找出真正占盘的）
SELECT c.relname AS 表,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS 总大小,
       pg_size_pretty(pg_relation_size(c.oid))       AS 表本体,
       coalesce(st.n_live_tup, 0)                    AS 行数
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_stat_user_tables st ON st.relid = c.oid
WHERE n.nspname = 'public' AND c.relkind = 'r'
ORDER BY pg_total_relation_size(c.oid) DESC
LIMIT 20;
```

**99% 的情况 `ts_kv` 占绝大部分**。它是分区表：

```sql
-- 看分区与各自大小
SELECT child.relname AS 分区,
       pg_size_pretty(pg_total_relation_size(child.oid)) AS 大小
FROM pg_inherits
JOIN pg_class parent ON pg_inherits.inhparent = parent.oid
JOIN pg_class child  ON pg_inherits.inhrelid  = child.oid
WHERE parent.relname = 'ts_kv'
ORDER BY pg_total_relation_size(child.oid) DESC
LIMIT 12;
```

### 9.2 两张「键名字典」不要搞混

| 表 | 管什么 | 谁写 |
| --- | --- | --- |
| `key_dictionary` | **属性**键名（`type1`、`meterLevel`…） | 属性写入时 |
| `ts_kv_dictionary` | **遥测**键名（`energy`、`voltage_a`…） | 遥测写入时 |

查属性用前者，查遥测用后者。**用错了会得到空结果，但不报错。**

### 9.3 删数据的正确姿势

```sql
-- ✅ 按条件删（走索引，安全）
DELETE FROM ts_kv
WHERE entity_id = '<设备id>'
  -- ★ 必须先把 now() 转 bigint 再减：epoch 是 numeric，
  --   写 (extract(...) * 1000)::bigint - 90*86400000 会先算整型乘法再相减，
  --   在 32 位整型下溢出（实测 integer out of range）。
  AND ts < ((extract(epoch from now()) * 1000)::bigint - 7776000000);

-- ❌ 绝不 DROP 分区来"清理"
--    一个分区里混着所有客户的数据，DROP 会跨客户删
```

删完回收空间：

```sql
VACUUM (VERBOSE, ANALYZE) ts_kv;
-- 分区表要对父表执行，PG 会递归
```

> **`ts_kv` 没有 `VACUUM FULL` 的必要**（会长时间锁表），
> 空间由 autovacuum 逐步回收。

### 9.4 索引现状

```sql
SELECT indexname, indexdef FROM pg_indexes
WHERE tablename = 'ts_kv' AND schemaname = 'public';
```

正常应有 `(entity_id, key, ts)` 相关索引。**查遥测按 `entity_id + key + ts`
范围**是最常见的访问模式，缺索引会让看板加载从秒级变成分钟级。

---

## 10. 备份与恢复

### 10.1 只备份结构（换机器重装用）

```bash
docker exec energy-postgres pg_dump -U postgres -d thingsboard \
  --schema-only > backup/schema-$(date +%m%d).sql
```

### 10.2 备份实体，不含遥测（最常用）

遥测通常占 95% 以上，**只备份实体能秒级完成**：

```bash
docker exec energy-postgres pg_dump -U postgres -d thingsboard \
  -t tenant -t customer -t asset -t device -t device_profile -t asset_profile \
  -t relation -t attribute_kv -t key_dictionary \
  -t dashboard -t widget_type -t widgets_bundle -t custom_menu \
  -t tb_user -t user_credentials \
  -t rate_template -t tou_scheme -t calculated_field \
  > backup/entities-$(date +%m%d-%H%M).sql
```

### 10.3 全量备份（含遥测）

```bash
docker exec energy-postgres pg_dump -U postgres -d thingsboard -Fc \
  > backup/full-$(date +%m%d).dump

# 恢复
docker exec -i energy-postgres pg_restore -U postgres -d thingsboard \
  --clean --if-exists < backup/full-1102.dump
```

> `-Fc`（自定义格式）比纯 SQL 小、能并行恢复。**大库一律用 `-Fc`。**

### 10.4 单个客户迁移

```bash
# ① 导出该客户的全部实体（把 <cid> 换成客户 uuid）
docker exec energy-postgres pg_dump -U postgres -d thingsboard \
  --column-inserts \
  -t customer -t asset -t device -t relation -t attribute_kv -t dashboard \
  --where="customer_id = '<cid>'" > backup/customer-<cid>.sql

# ② 遥测单独导（按 entity_id 过滤，pg_dump 不支持 where 时用 COPY）
```

**注意**：`pg_dump --where` 只对部分表有效，
复杂场景推荐用 `09-onboard-customer.sh` 重新建一遍 + 只迁遥测。

---

## 11. 一键体检

不想逐条跑，用脚本（只读，不改数据）：

```bash
bash scripts/29-rtu-demo-up.sh --check
```

它按同样顺序核一遍：探活 → 品种库 → 字典 key 数 → 客户/场站 → 设备属性 →
模拟设备 → 待清理项，最后打印一份 dry-run 计划。

---

## 12. 排查顺序（别跳步）

页面显示「没有数据」时，**从上游往下查**，跳步会白查：

```
字典齐不齐（§1）
  → 档案有品种吗（§7）
    → 设备三层属性自洽吗（§2）
      → 测点快照有吗（§2.1 的「测点数」列）
        → 遥测在写吗（§3.1）
          → 资产汇总写了吗（§5.1）
            → 抄表能读吗（§8）
```

**每层的现象都一样（页面空白），所以必须按顺序定位到具体一层。**
实测最常见的两个卡点：`测点数 = 0`（键名不翻译）和 `层级 = 空`
（资产汇总取不到，看板 0）。

---

## 13. 已知偏差（截至 2026-11-02）

如实记录，不粉饰。排查时别当成自己的错。

### 13.1 `repair-init` 会重建 10 台演示设备

见 [⑦ 设备接入 · 演示环境](/admin/device-access#演示环境无真实设备时)。演示前别点「一键修复初始化」，
误点了跑 `30-rtu-env-init.py --prune`。

### 13.2 两个客户共用一套真实 RTU 设备

`PowerMeter-DDSU666` / `Sensor-HZ8706` / `Relay-8CH` 的名字写死在板子
`main.py` 里，全局只有一套，只属于主演示客户「平台演示中心」。
给其他客户初始化时，`30-rtu-env-init.py` 会**跳过**这三台（不是漏了）。

想让第二个客户也有真实设备，只能再烧一块板子、改 `main.py` 里的
`METER_DEVICE` 等常量，让名字不冲突。
