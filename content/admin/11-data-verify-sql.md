# 数据验证 SQL（RTU 演示环境）

> 这一页的 SQL 都是**实际跑过、结果确认过**的，不是凭 schema 猜的。
> 每条都标了「回答什么问题」和「怎样算正常」，异常时看那一行就知道卡在哪。
>
> **为什么需要它**：演示环境出问题时，页面只会告诉你「没有数据」。
> 到底是没有设备、没有属性、没有遥测，还是属性有但口径不对 ——
> 页面看不出来，只有查库能看出来。下面按「从上游到下游」的顺序排：
> 字典 → 档案 → 设备属性 → 遥测 → 资产汇总。

---

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
  COUNT(*) FILTER (WHERE code LIKE '%_seq_%')            AS 序分量,
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
SELECT d.name, t1.v AS 品种, dt.v AS 一级类型, k.kind AS 字典里的品种
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

## 9. 一键体检

不想逐条跑，用脚本（只读，不改数据）：

```bash
bash scripts/29-rtu-demo-up.sh --check
```

它按同样顺序核一遍：探活 → 品种库 → 字典 key 数 → 客户/场站 → 设备属性 →
模拟设备 → 待清理项，最后打印一份 dry-run 计划。

---

## 10. 排查顺序（别跳步）

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

## 11. 已知偏差（截至 2026-11-02）

如实记录，不粉饰。下面这些**当前确实是这个状态**，排查时别当成自己的错。

### 11.1 单相园区的资产汇总为 0

```
三相园区·平台演示中心 | energy_total=0.649  energy_day=2281.5   ✓
单相园区·平台演示中心 | energy_total=0.000  energy_day=0.0      ✗
```

单相园区下**确实有数据**（`WaterMeter-SIM` 当日 19.6、`GasMeter-SIM` 5.8，
加上真实的 `PowerMeter-DDSU666`），但 `seedAssetTotals` 没给它写汇总。

**排查入口**：用 §5.2 查单相园区的设备层级 —— 那几台都是 `level=2`，
而三相园区有一台 `level=1` 的进线总表。怀疑汇总逻辑在「没有 level=1 时」
的取数分支上有问题。

**影响范围**：单相园区的场站看板显示 0；设备级数据、抄表、参数报表都不受影响。

**临时规避**：给单相园区加一台 `meterLevel=1` 的表，或者在事件里按设备维度看。

### 11.2 `repair-init` 会重建 10 台演示设备

见 `/admin/rtu-demo-env` 第五节。演示前别点「一键修复初始化」，
误点了跑 `30-rtu-env-init.py --prune`。

### 11.3 两个客户共用一套真实 RTU 设备

`PowerMeter-DDSU666` / `Sensor-HZ8706` / `Relay-8CH` 的名字写死在板子
`main.py` 里，全局只有一套，只属于主演示客户「平台演示中心」。
给其他客户初始化时，`30-rtu-env-init.py` 会**跳过**这三台（不是漏了）。

想让第二个客户也有真实设备，只能再烧一块板子、改 `main.py` 里的
`METER_DEVICE` 等常量，让名字不冲突。
