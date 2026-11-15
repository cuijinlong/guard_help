# 页面链路卡：页面 → 看板 → 部件 → 接口 → 类 → 表

> 26 个客户页面，每页一张卡。**先看下面的总览表找到你要查的页，再点左侧目录跳过去。**
> 想学「怎么自己挖出来」，看 [架构导航](/admin/architecture)。

**怎么读一张卡**：

- `[自研]` 的部件是本项目写的；`[TB]` 是平台自带
- 接口里 `/api/energy/*` 是自研后端，其余是 TB 原生接口
- 最后一列是「关键表」——想核对数字就去这些表查

> 本页由脚本自动生成（2026-11-15），数据全部来自实测：数据库 + 部件脚本 + 源码。
> 改了看板或代码后请重跑文末脚本，**不要手改**。

## 一、总览（26 个页面）

| 页面 | 看板 | 部件 | 自研接口 | 主要 Controller |
| --- | --- | --- | --- | --- |
| [能耗概览](#能耗概览) | 能耗概览 | 8 | 7 | EnergyAnalysisController, EnergyMeterReadingController, EnergyMetricParamController… |
| [能耗查询 / 实时能耗](#实时能耗-能耗查询) | 实时能耗 | 3 | 6 | EnergyMeterReadingController, EnergyMetricParamController, EnergyRatePolicyController… |
| [能耗查询 / 历史能耗](#历史能耗-能耗查询) | 历史能耗 | 2 | 5 | EnergyMeterReadingController, EnergyMetricParamController, EnergyRatePolicyController… |
| [能耗查询 / 抄表功能](#抄表功能-能耗查询) | 抄表功能 | 4 | 9 | EnergyMeterReadingController, EnergyMetricParamController, EnergyRatePolicyController… |
| [能耗分析 / 峰谷分析](#峰谷分析-能耗分析) | 峰谷分析 | 2 | 5 | EnergyAnalysisController, EnergyMeterReadingController, EnergyMetricParamController… |
| [能耗分析 / 分项能耗](#分项能耗-能耗分析) | 分项能耗 | 4 | 6 | EnergyMeterReadingController, EnergyMetricParamController, EnergyRatePolicyController… |
| [能耗分析 / 区域能耗](#区域能耗-能耗分析) | 区域能耗 | 5 | 6 | EnergyMeterReadingController, EnergyMetricParamController, EnergyRatePolicyController… |
| [能耗分析 / 用能账单](#用能账单-能耗分析) | 我的账单 | 2 | 7 | EnergyAnalysisController, EnergyBillingController, EnergyMeterReadingController… |
| [综合报表 / 基础报表](#基础报表-综合报表) | 基础报表 | 2 | 5 | EnergyMeterReadingController, EnergyMetricParamController, EnergyRatePolicyController… |
| [综合报表 / 手工填报](#手工填报-综合报表) | 手工填报 | 4 | 8 | EnergyManualEntryController, EnergyMeterReadingController, EnergyMetricParamController… |
| [能耗优化 / 闲时能耗](#闲时能耗-能耗优化) | 闲时能耗 | 1 | 3 | EnergyRatePolicyController, IdleEnergyController |
| [能耗优化 / 负载预测](#负载预测-能耗优化) | 负载预测 | 2 | 4 | EnergyForecastController, EnergyRatePolicyController, EnergyTimeAnchorController |
| [能耗优化 / 用能建议](#用能建议-能耗优化) | 用能建议 | 1 | 3 | EnergyDiagnosisController |
| [能耗优化 / 用能质量](#用能质量-能耗优化) | 用能质量 | 1 | 3 | EnergyDiagnosisController |
| [告警事件](#告警事件) | 告警事件 | 1 | 8 | AlarmEventController, AlarmRuleCrudController |
| [设备管理 / 设备运维](#设备运维-设备管理) | 设备运维 | 2 | 4 | EnergyMeterReadingController, EnergyMetricParamController, EnergyRatePolicyController… |
| [设备管理 / 设备分组](#设备分组-设备管理) | 设备分组 | 1 | 5 | EnergyDeviceProfileMetaController, EnergyDictionaryController, EnergyRatePolicyController… |
| [设备管理 / 设备拓扑](#设备拓扑-设备管理) | 设备拓扑 | 1 | 1 | EnergyTopologyController |
| [综合能耗](#综合能耗) | 综合能耗 | 1 | 2 | EnergyMetricParamController, EnergyTelemetryController |
| [能源流向](#能源流向) | 能源流向 | 2 | 5 | EnergyMetricParamController, EnergyRatePolicyController, EnergyTimeAnchorController |
| [盘查报告](#盘查报告) | 盘查报告 | 1 | 2 | EnergyAuditReportController, EnergyMetricParamController |
| [节能记录](#节能记录) | 节能记录 | 1 | 1 | EnergyMetricParamController |
| [空调管理 / 空调运行监控](#空调运行监控-空调管理) | 空调运行监控 | 1 | 1 | EnergyRatePolicyController |
| [空调管理 / 运行计划与配置](#运行计划与配置-空调管理) | 运行计划与配置 | 1 | 1 | EnergyRatePolicyController |
| [空调管理 / 每日复盘报告](#每日复盘报告-空调管理) | 每日复盘报告 | 1 | 1 | EnergyRatePolicyController |
| [组织](#组织) | 组织与场站 | 1 | 13 | DeviceDisplayNameController, EnergyDictionaryController, EnergyMetricParamController… |

## 二、七个基础设施接口（伪代码 + 可运行 SQL）

这 7 个接口被 4~18 个页面共用，**搞懂它们，26 个页面通一半**。
每条 SQL 都由实测跑通，`<tenant_id>` 换成你自己的租户 id 即可。

```sql
-- 先取租户 id（后面所有 SQL 都用它）
SELECT id FROM tenant WHERE title = '星河能源集团';
```

### 2.1 `/api/energy/visible-sites` → `EnergyRatePolicyController.getVisibleSites:249`

**用途**：当前用户能看到哪些场站/组织。18 个页面在调用，是权限入口。

**伪代码**

```text
user = 当前用户; tenant = 当前租户
targetCustomer = user 是客户用户 ? user.customerId : null       // 客户用户忽略入参，防越权
if targetCustomer == null && 传了 customerId:
    targetCustomer = customerId

assetGroupIds = 客户用户 ? 该用户可见的资产组 : {}
restricted    = 客户用户 && 资产组非空
orgProfileIds = 组织类档案 id 集合                                // 只算一次，局部传参

if !restricted:
    候选 = targetCustomer 有值 ? 该客户的资产 : 全租户资产        // 租户不传客户 = 看全租户
    collected = { 候选 中 isOrgOrSite 的 }
else:
    for 每个资产组:
        collected += 组内资产 中 isOrgOrSite 的
    BFS 沿 Contains 向上补齐组织链                                // 否则场站无处挂载

return { restricted, sites: collected }

isOrgOrSite(asset):
    return asset.type ∈ {场站, 组织} || asset.asset_profile_id ∈ orgProfileIds
```

**关键 SQL**（等价于 `!restricted` 分支）

```sql
-- 场站 + 组织清单（18 个页面的下拉框数据源）
SELECT a.id, a.name, coalesce(a.type, p.name) AS kind
FROM asset a
LEFT JOIN asset_profile p ON p.id = a.asset_profile_id
WHERE a.tenant_id = '<tenant_id>'::uuid
  AND (a.type IN ('场站', '组织') OR p.name IN ('场站', '组织'))
ORDER BY kind, a.name;
```

实测输出：

```
三相园区·平台演示中心   type=场站
单相园区·平台演示中心   type=场站
质量示范·平台演示中心   type=场站
总部·平台演示中心       type=组织
```

> ⚠️ **两个坑**：
> 1. `asset.type` 会在「资产档案改名」时被 TB 同步回写，所以代码里同时看
>    `type` 和 `asset_profile_id`（双保险）。SQL 里也要两个都判。
> 2. 客户用户的可见范围不是 `customer_id` 一个条件就够 —— 还要叠加
>    `entity_group` + `group_permission`。上面这条 SQL 只等价租户视角。

---

### 2.2 `/api/energy/metric-params` → `EnergyMetricParamController.getMetricParams:786`

**用途**：能源品种与指标参数定义（单位/小数位/口径）。13 个页面在用。

**伪代码**

```text
lib = 找 type='energy_type_library' 的资产                        // 回退按 name='能源参数字典'
if lib == null: return { libraryId: null, kinds: [] }

visible = 不按场站过滤 ? null : 该场站声明的能源品种集合            // null = 不过滤
kindAssets = lib 的 Contains 子资产
kindAttrs  = 批量读这些子资产的 SERVER_SCOPE 属性                  // 一条 SQL 查 attribute_kv

for kind in kindAssets:
    node = { code, name, unit, data_shape(缺省 cumulative),
             is_energy(缺省 true), paramDict, device_types, ... }
    if visible 非空 && node.code ∉ visible: skip
    if energyOnly && node.is_energy == false: skip

return { libraryId, siteId, filtered, kinds }
```

**关键 SQL**

```sql
-- 根字典资产
SELECT id, name FROM asset
WHERE tenant_id = '<tenant_id>'::uuid AND type = 'energy_type_library';

-- 8 个能源品种及其属性
SELECT k.name AS kind_name,
       max(CASE WHEN kd.key='code' THEN ak.str_v END) AS code,
       max(CASE WHEN kd.key='unit' THEN ak.str_v END) AS unit,
       max(CASE WHEN kd.key='data_shape' THEN ak.str_v END) AS data_shape
FROM asset lib
JOIN relation r ON r.from_id = lib.id AND r.relation_type = 'Contains'
JOIN asset k   ON k.id = r.to_id
LEFT JOIN attribute_kv ak ON ak.entity_id = k.id AND ak.attribute_type = 2
LEFT JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
WHERE lib.type = 'energy_type_library'
  AND lib.tenant_id = '<tenant_id>'::uuid
GROUP BY k.id, k.name
ORDER BY k.name;
-- 只数品种个数时用 count(DISTINCT k.id)，否则 JOIN relation 会重复计数
```

> **缓存**：控制器内有 `SITE_KINDS_CACHE`（`ConcurrentHashMap`，TTL 30 秒），
> key 是 `tenantId|siteId`。品种属性本身不缓存（`CachedAttributesService.findAll`
> 在 keys 未知时绕过缓存）。

---

### 2.3 `/api/energy/time-anchor` → `EnergyTimeAnchorController.getTimeAnchor:80`

**用途**：所有「今天/本月」类时间窗的基准日。12 个页面在用。

**伪代码**

```text
today = LocalDate.now(Asia/Shanghai)
out   = { today, anchor: today, demo: false }

cid = 当前用户是客户用户 ? 其 customerId : null
if cid == null: return out                                        // 租户视角用真实今天

attr = 读 CUSTOMER 的 SERVER_SCOPE 属性 'energyDemoWindow'
if attr 不存在或为空: return out

node = JSON.parse(attr.strValue)                                  // ★ 是 StringDataEntry，不是 Json
if node.to 为空: return out

out.anchor = node.to; out.demo = true
out.windowFrom = node.from; out.windowTo = node.to; out.days = node.days
return out
```

**关键 SQL**

```sql
-- 演示窗口锚点（客户实体上的 SERVER_SCOPE 属性）
SELECT c.title AS customer, ak.str_v AS energy_demo_window
FROM customer c
LEFT JOIN attribute_kv ak
  ON ak.entity_id = c.id
 AND ak.attribute_type = 2                                        -- 2 = SERVER_SCOPE
 AND ak.attribute_key = (SELECT key_id FROM key_dictionary WHERE key = 'energyDemoWindow')
WHERE c.tenant_id = '<tenant_id>'::uuid;
```

实测输出：

```
平台演示中心 -> {"from":"2026-09-12","to":"2026-11-12","days":62,"generatedAt":1794470888165}
```

> ⚠️ 值是 **StringDataEntry**（JSON 字符串），不是 JsonDataEntry。
> 用 `ak.json_v` 读会得到 NULL，必须用 `ak.str_v`。

---

### 2.4 `/api/energy/meters` → `EnergyMeterReadingController.meters`

**用途**：电表清单（含档案、倍率、归属）。10 个页面在用。

**伪代码**

```text
devices = 全租户设备分页拉取
filter:
    if 传了 deviceIds: 只留这些
    if 客户用户: 只留 customer 归属匹配的
    排除虚拟设备（MeteringMath.isVirtual）
    排除网关（additionalInfo.gateway == true）

for dev in devices:
    属性 = 读 SERVER_SCOPE（meterNo / ctRatio / ptRatio / meterRatio / ratioApplied）
    档案 = device_profile
    最新表底 = timeseriesService.findLatest(dev, 'energy_reading')     // 单点，非区间
    场站/组织 = 由 additionalInfo.siteId 反查 asset 及其父资产

return [ { id, name, meterNo, ratio, siteId, siteName, lastReading, ... } ]
```

**关键 SQL**

```sql
-- 电表清单 + 最新表底 + 归属场站
SELECT d.id, d.name,
       max(CASE WHEN kd.key='meterNo'      THEN ak.str_v END) AS meter_no,
       max(CASE WHEN kd.key='meterRatio'   THEN ak.str_v END) AS meter_ratio,
       max(CASE WHEN kd.key='ratioApplied' THEN ak.bool_v::text END) AS ratio_applied,
       l.dbl_v AS last_reading,
       to_char(to_timestamp(l.ts/1000) AT TIME ZONE 'Asia/Shanghai','MM-DD HH24:MI') AS reading_at,
       d.additional_info::jsonb->>'siteId' AS site_id
FROM device d
LEFT JOIN attribute_kv ak ON ak.entity_id = d.id AND ak.attribute_type = 2
LEFT JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
LEFT JOIN ts_kv_latest l ON l.entity_id = d.id
  AND l.key = (SELECT key_id FROM key_dictionary WHERE key = 'energy_reading')
WHERE d.tenant_id = '<tenant_id>'::uuid
  AND coalesce(d.additional_info::jsonb->>'gateway','false') <> 'true'   -- ★ varchar，必须 ::jsonb
GROUP BY d.id, d.name, l.dbl_v, l.ts, d.additional_info
ORDER BY d.name;
```

---

### 2.5 `/api/energy/telemetry-series` → `EnergyTelemetryController.telemetrySeries`

**用途**：取一组实体的时序数据（部件画图用）。7 个页面在用。

**伪代码**

```text
实体 = 参数里的 entityIds（或按场站/分项解析出的集合）
keys  = 参数里的遥测键
时间窗 = [startTs, endTs]

for 每个实体:
    原始点 = timeseriesService.findAll(实体, keys, startTs, endTs)   // 明细，不做区间聚合
    if 需要按间隔: 交给前端做分桶，或走 TB 的 aggregate 接口

return { 实体id: { key: [{ts, value}] } }
```

**关键 SQL**（等价的明细查询）

```sql
-- 某设备某键的原始序列（示意：最近 1 小时）
SELECT to_char(to_timestamp(kv.ts/1000) AT TIME ZONE 'Asia/Shanghai','HH24:MI:SS') AS t,
       coalesce(kv.dbl_v, kv.long_v) AS value
FROM ts_kv kv
JOIN key_dictionary kd ON kd.key_id = kv.key
WHERE kv.entity_id = '<device_id>'::uuid
  AND kd.key = 'voltage_a'
  AND kv.ts > (extract(epoch from now())*1000 - 3600000)
ORDER BY kv.ts DESC
LIMIT 20;
```

> **口径**：这个接口取的是**明细点**，不是聚合值。要「本月累计」得由调用方
> 或前端算 —— 这和我们实测过的「TB 报表引擎不做区间聚合」是同一件事。

---

### 2.6 `/api/energy/entity-briefs` → `EnergyMetricParamController.entityBriefs:609`

**用途**：批量取实体名称/类型（部件渲染前先拿名字）。5 个页面在用。

**伪代码**

```text
ids = 参数里的实体 id 列表
result = {}
for 分批(ids):
    批量查 asset → 填入 name
    批量查 device → 填入 name + 档案
    批量查 device_profile / asset_profile → 填入类型名
return { id: { name, type, profileName } }
```

**关键 SQL**

```sql
-- 批量取实体名称（UNION 资产与设备）
SELECT 'ASSET' AS kind, a.id, a.name, coalesce(p.name,'-') AS profile
FROM asset a LEFT JOIN asset_profile p ON p.id = a.asset_profile_id
WHERE a.id IN ('<id1>'::uuid, '<id2>'::uuid)
UNION ALL
SELECT 'DEVICE', d.id, d.name, coalesce(p.name,'-')
FROM device d LEFT JOIN device_profile p ON p.id = d.device_profile_id
WHERE d.id IN ('<id1>'::uuid, '<id2>'::uuid);
```

---

### 2.7 `/api/energy/child-relations` → `EnergyMetricParamController.childRelations:478`

**用途**：沿 `Contains` 取子节点（四棵树的下钻）。4 个页面在用。

**伪代码**

```text
fromId = 当前节点
relations = 查 fromId 出发的 Contains（COMMON 组）
if relations 为空 && fromId 是实体组: 回退查实体组的成员

children = [ findAssetById(r.toId) 或 findDeviceById(r.toId) ]
按 additionalInfo 排序字段排序
return [ { id, name, type, hasChildren } ]
```

**关键 SQL**

```sql
-- 某节点的直接子节点（资产 + 设备）
SELECT r.to_type AS kind, r.to_id AS id,
       coalesce(a.name, d.name) AS name,
       coalesce(ap.name, dp.name) AS profile
FROM relation r
LEFT JOIN asset  a  ON r.to_type='ASSET'  AND a.id = r.to_id
LEFT JOIN asset_profile ap ON ap.id = a.asset_profile_id
LEFT JOIN device d  ON r.to_type='DEVICE' AND d.id = r.to_id
LEFT JOIN device_profile dp ON dp.id = d.device_profile_id
WHERE r.from_id = '<parent_asset_id>'::uuid
  AND r.relation_type = 'Contains'
ORDER BY name;

-- 顺手看这个节点有几层子树（判断 hasChildren 用）
WITH RECURSIVE tree AS (
  SELECT id FROM asset WHERE id = '<parent_asset_id>'::uuid
  UNION ALL
  SELECT r.to_id FROM relation r JOIN tree t ON r.from_id = t.id
  WHERE r.relation_type = 'Contains' AND r.to_type = 'ASSET'
)
SELECT count(*) AS subtree_size FROM tree;
```

> ⚠️ `relation` 表有 `Contains` 和 `SiteContains` 两套口径并存。
> 下钻用 `Contains`；场站→设备汇总用 `SiteContains`。混用会得到不同结果。

## 三、页面独有接口（伪代码 + 关键 SQL）

> 只列「某页面专属」的接口。共用接口见第二章，不重复。

### 3.1 组织（12 个接口）

这一页管的是「组织树 + 费率下发」，是权限与定价的交汇点。

#### `/api/energy/structure-settings` → `EnergyStructureController`

**伪代码**

```text
settings = admin_settings[tenant].energyStructureSettings           // 不存在则默认
result = {
  orgProfileIds: 档案里 energyRole='org' 的 id 集合,                 // 自愈：缺失时写回
  siteProfileIds: 同理 'site',
  canManageOrg: 当前用户有租户级写权限
}
```

**关键 SQL**

```sql
-- 组织/场站档案是怎么标记的
SELECT ap.id, ap.name,
       max(CASE WHEN kd.key='energyRole' THEN ak.str_v END) AS energy_role
FROM asset_profile ap
LEFT JOIN attribute_kv ak ON ak.entity_id = ap.id AND ak.attribute_type = 2
LEFT JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
WHERE ap.tenant_id = '<tenant_id>'::uuid
GROUP BY ap.id, ap.name
HAVING max(CASE WHEN kd.key='energyRole' THEN ak.str_v END) IS NOT NULL;
```

> ⚠️ `energyRole` 是 2026-11-15 加的**自愈属性**：老库没有这条属性时，
> 代码会按档案名推断一次并写回。这叫「档案改名不再失效」的修法。
> 如果这里查出来是空的，说明自愈还没触发（需要访问一次相关接口）。

#### `/api/energy/rate-policies` → `getRatePolicies:137`

**伪代码**

```text
templates = 租户级 rate_template 资产                              // customerId 为 null 或 NULL_UUID
schemes   = 租户级 tou_scheme 资产
result.templates = [{ id, name, SERVER_SCOPE 属性, schemeIds=该模板 uses 的目标 }]
result.schemes   = [{ id, name, 属性 }]

if 传了 siteId:
    site = 校验可访问（客户用户跨客户 → 403）
    result.siteBindings    = site uses→ 模板
    result.siteCustomRates = site 的 SERVER_SCOPE 'siteCustomRates'
    owner = 沿父链找最近一个配了 energyRates 的组织
    if owner: result.orgRates = owner.energyRates

result.customerRates = 客户级费率（**已停用**，见下）
```

> **客户级费率已停用（2026-11-14 客户定案，2026-11-15 实测复核）**
>
> 业务上只有**组织级费率**一个维护入口（「组织与场站 → 选中组织 → 能源费率」）。
> 客户级这条链路：
> - 前端入口已移除（`customers-table-config.resolver.ts:230-249`），组件保留未删
> - 客户自己登录改的是组织级（`org-rate.component.ts`）
> - 组织与场站部件 0 次调用 `customer-rate`
> - 当前库里零个客户配过（`additionalInfo` 只有 `homeDashboardId` 等）
>
> **但后端 `POST /energy/customer-rate` 仍在，且能真实影响账单**：
> 实测写入 `elec = 9999 元/度` 后，把组织费率临时置空，账单从
> 502,209.64 元变成 **1,685,246,364.66 元**（16.8 亿）；组织费率恢复后回到正常值。
> 也就是说它是「无入口但可达」的隐藏兜底层，不是死代码。
>
> 排查账单金额离谱时，先查这个属性：
>
> ```sql
> SELECT title, (additional_info::jsonb -> 'energyRates')::text
> FROM customer WHERE tenant_id = '<tenant_id>'::uuid;
> ```
>
> 正确答案应为空（NULL 或 `{}`）。

**关键 SQL**

```sql
-- 租户级费率模板 + 分时方案
SELECT a.type, a.id, a.name,
       max(CASE WHEN kd.key='energy'  THEN ak.str_v END) AS energy,
       max(CASE WHEN kd.key='rateType' THEN ak.str_v END) AS rate_type
FROM asset a
LEFT JOIN attribute_kv ak ON ak.entity_id = a.id AND ak.attribute_type = 2
LEFT JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
WHERE a.tenant_id = '<tenant_id>'::uuid
  AND a.type IN ('rate_template', 'tou_scheme')
  AND (a.customer_id IS NULL OR a.customer_id = '13814000-1dd2-11b2-8080-808080808080'::uuid)
GROUP BY a.type, a.id, a.name
ORDER BY a.type, a.name;

-- 某场站绑定了哪些模板（uses 关系）
SELECT t.name AS template, t.type
FROM relation r JOIN asset t ON t.id = r.to_id
WHERE r.from_id = '<site_asset_id>'::uuid
  AND r.relation_type = 'uses' AND r.to_type = 'ASSET';
```

> **优先级**（代码注释原文）：`场站自定义 > 场站绑定模板 > 客户默认绑定`。

#### `/api/energy/org-rate` → `saveOrgRate`

**伪代码**

```text
校验组织可访问（客户用户只能改自己名下组织）                          // 404 / 403
rates = body.energyRates; 必须是对象 → 否则 400
for (energy, rate) in rates: validateCustomerRate(energy, rate)
写 SERVER_SCOPE JsonDataEntry 'energyRates' 到组织资产
return { ok, energyRates }
```

**关键 SQL**

```sql
-- 组织上配的费率
SELECT a.name AS org,
       ak.json_v AS energy_rates
FROM asset a
JOIN attribute_kv ak ON ak.entity_id = a.id AND ak.attribute_type = 2
JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
WHERE kd.key = 'energyRates'
  AND a.type = '组织'
  AND a.tenant_id = '<tenant_id>'::uuid;
```

> `validateCustomerRate` 很严：`rateType ∈ {tou, tier, flat, tier_tou}`，
> `flat` 必须用 `fixedPrice`（不是 `prices.flat`）。旧版宽松校验存进去的错误结构，
> 账单侧会静默算不出价。

#### `/api/energy/site-rate-binding` → `bindSiteRate:409` / `unbindSiteRate:442`

**伪代码**

```text
校验 site、template 都可访问；template.type 必须是 rate_template
energy = template 的 SERVER_SCOPE 'energy'

if energy 非空:
    删掉该场站同能源品种的旧 uses 关系                            // 一个品种只留一份
saveRelation(site → template, type='uses', group=COMMON)
```

**关键 SQL**

```sql
-- 一个场站每个能源品种绑了几份模板（应各为 1）
SELECT s.name AS site,
       max(CASE WHEN kd.key='energy' THEN ak.str_v END) AS energy,
       count(*) AS bindings
FROM relation r
JOIN asset s ON s.id = r.from_id AND s.type = '场站'
JOIN asset t ON t.id = r.to_id   AND t.type = 'rate_template'
LEFT JOIN attribute_kv ak ON ak.entity_id = t.id AND ak.attribute_type = 2
LEFT JOIN key_dictionary kd ON kd.key_id = ak.attribute_key AND kd.key = 'energy'
WHERE r.relation_type = 'uses'
  AND s.tenant_id = '<tenant_id>'::uuid
GROUP BY s.name, t.id
HAVING count(*) > 1;      -- 有结果 = 存在重复绑定
```

#### `/api/energy/site-rate-custom` → `saveSiteRateCustom:468` / `deleteSiteRateCustom:506`

**伪代码**

```text
校验 site 可访问；energy 非空；custom 是对象
validateCustomerRate(energy, custom)                              // 结构错当场拒
all = site 的 SERVER_SCOPE 'siteCustomRates'（读不到 = {}）
all[energy] = custom + { energy, updatedTime }
写回
```

**关键 SQL**

```sql
-- 场站级自定义费率（覆盖模板）
SELECT a.name AS site, ak.json_v AS custom_rates
FROM asset a
JOIN attribute_kv ak ON ak.entity_id = a.id AND ak.attribute_type = 2
JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
WHERE kd.key = 'siteCustomRates'
  AND a.tenant_id = '<tenant_id>'::uuid;
```

#### `/api/energy/customer-roles`、`/api/energy/device-display-name`、`/api/energy/gateway`、`/api/energy/topologies`、`/api/energy/vendor-models`

| 接口 | 存储 | 一句话 |
| --- | --- | --- |
| `customer-roles` | `user_role` + `customer` | 客户下的角色清单（下拉框） |
| `device-display-name` | `device.label` | 只改显示名，不动 `name`（name 是唯一键） |
| `gateway` | `relation` + `device.additional_info` | 网关绑定：设备 `additionalInfo.gateway=true` |
| `topologies` | `asset.type='topology'` + `attribute_kv.layout` | 拓扑图节点每次动态派生，只存坐标 |
| `vendor-models` | 厂商/型号资产 + SERVER_SCOPE | 设备档案的可选项 |

**拓扑的 SQL（看坐标存哪）**

```sql
SELECT a.name AS topology, a.additional_info::jsonb->>'siteId' AS site_id,
       ak.json_v AS layout
FROM asset a
LEFT JOIN attribute_kv ak ON ak.entity_id = a.id AND ak.attribute_type = 2
LEFT JOIN key_dictionary kd ON kd.key_id = ak.attribute_key AND kd.key = 'layout'
WHERE a.type = 'topology' AND a.tenant_id = '<tenant_id>'::uuid;
```

---

### 3.2 告警事件（8 个接口）

> **先纠正一个常见误解**：本项目只有**两套**告警机制，不是三套。
> `device_profile.profile_data.alarms` **全是 null**（实测 0 个非空），
> 那只是 TB 的默认空字段。
>
> | 机制 | 存在哪 | 当前数量 | 谁评估 |
> | --- | --- | --- | --- |
> | ① 计算字段告警 | `calculated_field` type=ALARM，挂在 DEVICE_PROFILE | 7 条 | TB 原生 |
> | ② 客户自建规则 | `alarm_rule` / `alarm_rule_state` 表 | 0 条 | 自研 `AlarmRuleEngine`（30s） |
>
> 两套最终都写 **`alarm` 表**（8638 条），所以确认/清除/通知/TTL 逻辑统一。

#### `/api/energy/alarm-events` → `AlarmEventController.events:141`

**伪代码**

```text
view = tab ∈ {device, limit, log, group, all} ? tab : 'device'
scope = 按租户/客户/场站算出可见设备集合（空集合 → WHERE false）
limitTypes = SELECT alarm_type FROM alarm_rule                      // 用来区分「客户规则告警」

if view == 'group':
    只按 cleared=false + scope 分组统计，忽略其他所有筛选            // 注意这个分支
else:
    按 view 决定：
      limit   → a.type = ANY(limitTypes)
      device  → a.type IS NULL OR a.type <> ALL(limitTypes)
    再叠加 status / severity / 时间窗 / deviceId / deviceName
    if view ∈ {limit, log}: additional_info.details 的 key/direction 过滤
    count(*) 后分页，ORDER BY start_ts DESC
```

**关键 SQL**

```sql
-- 告警列表（等价常用筛选：按级别 + 时间窗 + 场站设备）
SELECT a.id, a.type, a.severity,
       to_char(to_timestamp(a.start_ts/1000) AT TIME ZONE 'Asia/Shanghai','MM-DD HH24:MI') AS started,
       a.cleared, a.acknowledged,
       d.name AS device,
       a.additional_info::jsonb->'details'->>'key'       AS metric_key,
       a.additional_info::jsonb->'details'->>'threshold' AS threshold
FROM alarm a
LEFT JOIN device d ON d.id = a.originator_id
WHERE a.tenant_id = '<tenant_id>'::uuid
  AND a.start_ts >= (extract(epoch from now())*1000 - 7*86400000)   -- 最近 7 天
  AND a.severity IN ('CRITICAL','MAJOR')
ORDER BY a.start_ts DESC
LIMIT 50;

-- 按「是否客户自建规则告警」区分
SELECT source, cnt FROM (
  SELECT CASE WHEN a.type = ANY(ARRAY(SELECT alarm_type FROM alarm_rule
               WHERE tenant_id='<tenant_id>'::uuid AND alarm_type IS NOT NULL))
              THEN '客户规则' ELSE '内置' END AS source,
         count(*) AS cnt
  FROM alarm a WHERE a.tenant_id = '<tenant_id>'::uuid
  GROUP BY 1
) t;
```

#### `/api/energy/alarm-events/ack` → `ack:466`

**伪代码**

```text
ids = body.ids[]
for raw in ids:
    id = 解析 uuid，非法 → skipped++
    originator = SELECT originator_id FROM alarm WHERE id=? AND tenant_id=?   // 不存在→skipped
    if 不在可见设备集合 → skipped++                                // 逐条鉴权，防越权
    alarmService.acknowledgeAlarm(tenant, DeviceId(originator), AlarmId(id))
return { acknowledged: ok, skipped, errors }
```

**关键 SQL**

```sql
-- 确认告警（生产里走 TB 接口；这里只演示等价写法）
-- ⚠️ 直接 UPDATE 会跳过 TB 的事件/通知链路，仅供核对
SELECT id, originator_id, type, acknowledged, ack_ts
FROM alarm
WHERE tenant_id = '<tenant_id>'::uuid
  AND acknowledged = false
ORDER BY start_ts DESC LIMIT 10;
```

#### `/api/energy/alarms` → `SiteAlarmListController.alarms:153`

另一套实现，走 TB `AlarmService.findAlarmDataByQueryForEntities`，按 SITE/CUSTOMER/TENANT 三级判定，
originator 集合来自场站子树 BFS。

**关键 SQL（场站子树）**

```sql
-- 某场站子树下的全部设备（供告警筛选）
WITH RECURSIVE tree AS (
  SELECT id FROM asset WHERE id = '<site_asset_id>'::uuid
  UNION ALL
  SELECT r.to_id FROM relation r JOIN tree t ON r.from_id = t.id
  WHERE r.relation_type IN ('Contains','SiteContains') AND r.to_type = 'ASSET'
)
SELECT d.id, d.name
FROM device d
WHERE d.id IN (
  SELECT r.to_id FROM relation r JOIN tree t ON r.from_id = t.id
  WHERE r.to_type = 'DEVICE' AND r.relation_type IN ('Contains','SiteContains')
);
```

#### 其余 5 个

| 接口 | 作用 | 存储 |
| --- | --- | --- |
| `/alarm-events/clear` | 清除告警 | 走 TB `AlarmService.clearAlarm` |
| `/alarm-events/assign` | 指派处理人 | `alarm.assignee_id` + `assign_ts` |
| `/alarm-events/assignees` | 可指派人员清单 | `tb_user` + 租户/客户归属 |
| `/alarm-events/sites` | 场站下拉 | `asset.type='场站'` |
| `/alarm-rules` | 客户自建规则 CRUD | `alarm_rule` 表 |

**自建规则的 SQL**

```sql
-- 客户自建告警规则（当前 0 条）
SELECT r.name, r.alarm_type, r.severity, r.enabled,
       r.site_ids, r.profile_ids,          -- ★ 是数组，不是 site_id / device_id
       r.ts_key, r.direction, r.threshold, r.interval_secs, r.times
FROM alarm_rule r
WHERE r.tenant_id = '<tenant_id>'::uuid
ORDER BY r.created_time DESC;

-- 规则的运行状态
SELECT s.rule_id, s.device_id, s.streak, s.active,
       s.alarm_id, s.last_value, s.last_check
FROM alarm_rule_state s ORDER BY s.last_check DESC NULLS LAST;
```

---

### 3.3 抄表功能（5 个接口）

#### `/api/energy/meter-reading/run` → `run:229`

**伪代码**

```text
period = body.period ?: 当前月 'yyyy-MM'; dryRun/pull = false
pullWaitMs = clamp(body.pullWaitMs ?: 15000, 0, 120000)
meters = 候选设备（排除虚拟/网关/无权限）

if !dryRun: batchId = 建 batch(status='running')
if pull && meters 非空:
    freshAfter = 下发时刻 - 2 分钟
    online = 最近 10 分钟有数据的设备
    逐台下发 RPC 'readMeterNow'
    轮询 400ms 直到到齐或超时 pullWaitMs

for dev in meters:
    attrs   = SERVER_SCOPE（倍率等）
    latest  = findLatest(dev, 'energy_reading')                   // 单点
    if latest 为空            → state='missing'
    else if latest.ts < freshAfter → state='stale'（记录离线时长）
    else 基线 = 最近一条有效 meter_reading_record，否则设备属性 lastReading
         if 基线为空          → state='first' 并建基线
         else usage = (curr - baseline) × 倍率
              负增量 → 跳过并记入 backwardSegments
if !dryRun: 更新 batch 统计
return { batchId, total, normal, missing, abnormal, items }
```

**关键 SQL**

```sql
-- ① 候选电表（排除网关和虚拟设备）
SELECT d.id, d.name, d.additional_info::jsonb->>'siteId' AS site_id
FROM device d
WHERE d.tenant_id = '<tenant_id>'::uuid
  AND coalesce(d.additional_info::jsonb->>'gateway','false') <> 'true';

-- ② 每台设备最近的抄表基线（代码里的取法）
SELECT DISTINCT ON (device_id)
       device_name, curr_reading, quality,
       to_char(to_timestamp(reading_time/1000) AT TIME ZONE 'Asia/Shanghai','MM-DD HH24:MI') AS read_at
FROM meter_reading_record
WHERE tenant_id = '<tenant_id>'::uuid
  AND curr_reading IS NOT NULL
  AND coalesce(quality,'') <> 'abnormal'
ORDER BY device_id, reading_time DESC;

-- ③ 本月抄表明细
SELECT device_name, period, prev_reading, curr_reading, usage, ratio, quality,
       to_char(to_timestamp(reading_time/1000) AT TIME ZONE 'Asia/Shanghai','MM-DD HH24:MI') AS read_at
FROM meter_reading_record
WHERE tenant_id = '<tenant_id>'::uuid AND period = '2026-11'
ORDER BY device_name, reading_time;
```

实测 ② 输出：

```
PowerMeter-3P-SIM   reading=13965.1750  quality=normal  time=11-02 15:43
正泰单相电表 DDSU666  reading=8.4100      quality=normal  time=11-02 17:42
```

> ⚠️ `reading_time` 是 **bigint 毫秒**，不能直接 `to_char`，必须
> `to_timestamp(reading_time/1000)`。
> 另外 `item.readingTime` 写的是**抄表时刻 now**，不是遥测 ts —— 两个概念别混。

#### 其余 4 个

| 接口 | 作用 | 关键表 |
| --- | --- | --- |
| `/meter-reading/batches` | 抄表批次列表 | `meter_reading_batch` |
| `/meter-reading/records` | 批次内明细 | `meter_reading_record` |
| `/meter-reading/retry` | 重试失败项 | 同上 + 重新下发 RPC |
| `/meter-reading/run-plan` | 定时计划 | `scheduler_event` |

```sql
-- 批次概览
SELECT id, status, period, total, normal_count, missing_count, abnormal_count,
       to_char(to_timestamp(created_time/1000) AT TIME ZONE 'Asia/Shanghai','MM-DD HH24:MI') AS created
FROM meter_reading_batch
WHERE tenant_id = '<tenant_id>'::uuid
ORDER BY created_time DESC LIMIT 10;
```

---

### 3.4 用能账单（3 个接口）

#### `/api/energy/billing/generate` → `EnergyBillingController.generate:73`

**伪代码**

```text
period = body.period ?: null; dryRun = body.dryRun ?: false
if 客户用户:
    onlyCustomer = 自己的 customerId; 空 → 400
else:
    onlyCustomer = body.customerId ?: null

out = billingService.generate(tenant, period, onlyCustomer, onlyDevices, dryRun)
  逐台设备：
    无 meterTrust 参与 / 无 energyTypeCode / 无客户归属 / 无匹配电价 / 电价生效日晚于账期 → skip
    billOne() → usable=false → skip
    dryRun ? 只计数 : upsertBill()（写成 energy_bill 资产）

return { scope, deviceCount, created, updated, skipped }
```

**关键 SQL**

```sql
-- 账单列表（★ 金额存在 str_v，不是 dbl_v）
SELECT a.name AS billing_no,
       max(CASE WHEN kd.key='period'   THEN ak.str_v END) AS period,
       max(CASE WHEN kd.key='energy'   THEN ak.str_v END) AS energy,
       max(CASE WHEN kd.key='status'   THEN ak.str_v END) AS status,
       max(CASE WHEN kd.key='usage'    THEN coalesce(ak.dbl_v::text, ak.str_v) END) AS usage,
       max(CASE WHEN kd.key='amount'   THEN coalesce(ak.dbl_v::text, ak.str_v) END) AS amount,
       max(CASE WHEN kd.key='deviceName' THEN ak.str_v END) AS device
FROM asset a
LEFT JOIN attribute_kv ak ON ak.entity_id = a.id AND ak.attribute_type = 2
LEFT JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
WHERE a.type = 'energy_bill'
  AND a.tenant_id = '<tenant_id>'::uuid
GROUP BY a.id, a.name
ORDER BY a.name DESC
LIMIT 10;
```

实测输出（金额 `3950.73` 等）：

```
BILL-7CE48900-2026-10-elec-7E9434D0   status=draft  amount=3950.73
BILL-7CE48900-2026-10-elec-7EF03780   status=draft  amount=1258.32
```

> ⚠️ **这是最容易踩的坑**：`centsToYuan()` 返回 **String**，进库走 `str_v`。
> 而 `meterLevel` 是数字走 `dbl_v`，`details` 走 `json_v`。
> 所以读金额必须 `coalesce(ak.dbl_v::text, ak.str_v)`，只读 `dbl_v` 会全是 NULL。

**用量怎么算（不是 sum(energy)）**

```text
readUsage:
    取 energy_reading 的**小时 MAX 序列**
    usage = (末点 - 首点) × 倍率(CT/PT/meterRatio，仅 ratioApplied 为真时生效)
    负增量 → 记入 backwardSegments 并跳过
```

**金额构成**

```text
amount = energyFee + powerFactorFee + basicFee + surchargeFee
  TOU   : Σ usage[档位] × prices[档位]
  阶梯  : tierFeeCents(usage.total, tiers)
  单一制: usage.total × fixedPrice
  力调  : 仅 meterLevel==1，PF 均值 vs 基准 0.9，按 rules 档位
  基本  : meterLevel==1，demand（15 分钟最大平均）或 capacity
```

#### `/api/energy/billing/crosstab` → `EnergyAnalysisController.billingCrosstab()`

交叉表：行=维度，列=期间。走 `ts_kv` 区间查询后聚合。

#### `/api/energy/billing/delete` → 按 id 删 `energy_bill` 资产

```sql
-- 找出某账期的账单（删除前确认范围）
SELECT a.id, a.name, a.customer_id
FROM asset a
WHERE a.type = 'energy_bill'
  AND a.name LIKE 'BILL-%2026-10%'
  AND a.tenant_id = '<tenant_id>'::uuid;
```

---

### 3.5 手工填报（4 个接口）

**存储口径**（实测确认）：

```
数值   → ts_kv 的 'energy' 键，写在该月 1 日 00:00（东八区）
归属   → 设备 SERVER_SCOPE 属性 manualEntryItemId + Contains 关系
快照   → 设备属性 manualEntryMonths
年口径 → 资产属性 manualYearValueType
```

**伪代码（save）**

```text
校验类目、场站、期间
数值 → 写 ts_kv(energy, 月首 00:00 Asia/Shanghai)
归属 → 写设备 SERVER_SCOPE manualEntryItemId
快照 → 更新 manualEntryMonths
```

**关键 SQL**

```sql
-- 手工填报写入的月度值
SELECT d.name AS device,
       to_char(to_timestamp(kv.ts/1000) AT TIME ZONE 'Asia/Shanghai','YYYY-MM-DD') AS month_start,
       kv.dbl_v AS energy
FROM ts_kv kv
JOIN key_dictionary kd ON kd.key_id = kv.key
JOIN device d ON d.id = kv.entity_id
WHERE kd.key = 'energy'
  AND d.tenant_id = '<tenant_id>'::uuid
  AND d.name LIKE '%手工%'
ORDER BY kv.ts DESC LIMIT 20;
```

### 3.6 其余页面接口速查

| 页面 | 接口 | 存哪 / 算什么 |
| --- | --- | --- |
| 能耗概览 | `diagnosis/brief` 等 | `ts_kv` 区间 + 资产汇总 |
| 峰谷分析 | `tou-analysis` | `ts_kv` + `tou_scheme` 资产分档 |
| 闲时能耗 | `idle-analysis` / `idle-config` | 闲时区间 `ts_kv` + `idleConfig` 属性 |
| 负载预测 | `forecast/predict` / `forecast/context` | 历史 `ts_kv` 序列 |
| 用能质量 | `diagnosis/*` | `ts_kv` 电压/电流/功率因数 + 计算字段 |
| 设备运维 | `device-config` / `device-profiles/meta` | `device` + `device_profile` SERVER_SCOPE |
| 设备分组 | `topologies` / `child-relations` | `asset` + `relation` |
| 盘查报告 | `audit-report/versions` | `audit_report_version` **资产** + SERVER_SCOPE |
| 节能记录 | 无独有接口 | `saving_record` **资产** |
| 空调管理 | 无独有接口 | 复用基础设施 |

**盘查报告口径存储的 SQL**

```sql
SELECT a.name AS version,
       max(CASE WHEN kd.key='dimension'    THEN ak.json_v::text END) AS dimension,
       max(CASE WHEN kd.key='factors'      THEN ak.json_v::text END) AS factors,
       max(CASE WHEN kd.key='prices'       THEN ak.json_v::text END) AS prices,
       max(CASE WHEN kd.key='completeness' THEN ak.dbl_v::text END)  AS completeness
FROM asset a
LEFT JOIN attribute_kv ak ON ak.entity_id = a.id AND ak.attribute_type = 2
LEFT JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
WHERE a.type = 'audit_report_version'
  AND a.tenant_id = '<tenant_id>'::uuid
GROUP BY a.id, a.name
ORDER BY a.name DESC;
```

> 盘查报告存的是**口径元数据**（边界/因子/价格/完整率），不是 PDF。
> 这正是它不能被 TB 报表引擎替代的原因 —— 报表只存文件与模板。

## 四、逐页链路卡（看板 → 部件）



### 能耗概览

```
看板    能耗概览
看板ID  73dd2240-d2bd-11f1-b794-31725d9e3862
部件    8 个
        [自研] system.energy_management.calendar_heatmap
        [自研] system.energy_management.tou_summary
        [自研] system.energy_management.asset_stats_chart
        [自研] system.energy_management.ranking_list
        [自研] system.energy_management.power_load
        [自研] system.energy_management.analysis_bar
        [自研] system.energy_management.overview_stats
        [自研] system.energy_management.distribution_chart

自研接口
        /api/energy/entity-briefs                  -> EnergyMetricParamController.java
        /api/energy/meters                         -> EnergyMeterReadingController.java
        /api/energy/metric-params                  -> EnergyMetricParamController.java
        /api/energy/telemetry-series               -> EnergyTelemetryController.java
        /api/energy/time-anchor                    -> EnergyTimeAnchorController.java
        /api/energy/tou-analysis                   -> EnergyAnalysisController.java
        /api/energy/visible-sites                  -> EnergyRatePolicyController.java
TB 原生接口
        /api/asset
        /api/auth/user
        /api/device
        /api/entitiesQuery/find
        /api/plugins/telemetry
        /api/plugins/telemetry/ASSET
        /api/plugins/telemetry/DEVICE
        /api/relations

关键表
        asset, device（名称/档案缓存）
        device, device_profile, relation, ts_kv_latest
        admin_settings(key=energyDictionaries), device_profile.profile_data
        ts_kv, ts_kv_latest, key_dictionary
        admin_settings
        ts_kv + tou_scheme 资产
        asset, relation（场站可见性）
```

### 告警事件

```
看板    告警事件
看板ID  573f38b0-d3d2-11f1-9ee9-c3a7be535a93
部件    1 个
        [自研] system.energy_alarm.events_page

自研接口
        /api/energy/alarm-events                   -> AlarmEventController.java
        /api/energy/alarm-events/ack               -> AlarmEventController.java
        /api/energy/alarm-events/assign            -> AlarmEventController.java
        /api/energy/alarm-events/assignees         -> AlarmEventController.java
        /api/energy/alarm-events/clear             -> AlarmEventController.java
        /api/energy/alarm-events/sites             -> AlarmEventController.java
        /api/energy/alarm-rules                    -> AlarmRuleCrudController.java
        /api/energy/alarm-rules/status             -> AlarmRuleCrudController.java
TB 原生接口
        /api/alarm
        /api/auth/user
        /api/plugins/telemetry/DEVICE

关键表
        alarm（TB 原生）
        ★ alarm_rule 表（自研规则）+ 产出 TB 原生 alarm
```

### 综合能耗

```
看板    综合能耗
看板ID  73ba09e0-d2bd-11f1-b794-31725d9e3862
部件    1 个
        [自研] system.energy_management.energy_overview

自研接口
        /api/energy/child-relations                -> EnergyMetricParamController.java
        /api/energy/telemetry-series               -> EnergyTelemetryController.java
TB 原生接口
        /api/alarms
        /api/customer
        /api/device
        /api/entitiesQuery/find
        /api/plugins/telemetry/ASSET
        /api/plugins/telemetry/DEVICE
        /api/relations
        /api/tenant/assets
        ...（共 9 个）

关键表
        relation
        ts_kv, ts_kv_latest, key_dictionary
```

### 能源流向

```
看板    能源流向
看板ID  744ef6e0-d2bd-11f1-b794-31725d9e3862
部件    2 个
        [自研] system.energy_management.analysis_bar
        [自研] system.energy_management.sankey_flow

自研接口
        /api/energy/child-relations                -> EnergyMetricParamController.java
        /api/energy/entity-briefs                  -> EnergyMetricParamController.java
        /api/energy/metric-params                  -> EnergyMetricParamController.java
        /api/energy/time-anchor                    -> EnergyTimeAnchorController.java
        /api/energy/visible-sites                  -> EnergyRatePolicyController.java
TB 原生接口
        /api/auth/user
        /api/customer
        /api/device
        /api/entitiesQuery/find
        /api/plugins/telemetry
        /api/plugins/telemetry/ASSET
        /api/plugins/telemetry/DEVICE
        /api/relations
        ...（共 10 个）

关键表
        relation
        asset, device（名称/档案缓存）
        admin_settings(key=energyDictionaries), device_profile.profile_data
        admin_settings
        asset, relation（场站可见性）
```

### 盘查报告

```
看板    盘查报告
看板ID  73abb200-d2bd-11f1-b794-31725d9e3862
部件    1 个
        [自研] system.energy_management.audit_report

自研接口
        /api/energy/audit-report/versions          -> EnergyAuditReportController.java
        /api/energy/child-relations                -> EnergyMetricParamController.java
TB 原生接口
        /api/customer
        /api/device
        /api/entitiesQuery/find
        /api/plugins/telemetry/ASSET
        /api/plugins/telemetry/DEVICE
        /api/relations
        /api/tenant/assets
        /api/tenant/devices

关键表
        ★ audit_report_version 资产（SERVER_SCOPE 属性）
        relation
```

### 节能记录

```
看板    节能记录
看板ID  7452c770-d2bd-11f1-b794-31725d9e3862
部件    1 个
        [自研] system.energy_management.saving_records

自研接口
        /api/energy/child-relations                -> EnergyMetricParamController.java
TB 原生接口
        /api/asset
        /api/customer
        /api/device
        /api/entitiesQuery/find
        /api/plugins/telemetry/ASSET
        /api/plugins/telemetry/DEVICE
        /api/relations
        /api/tenant/assets
        ...（共 9 个）

关键表
        relation
```

### 组织

```
看板    组织与场站
看板ID  04e26da0-d3b7-11f1-8238-c3a7be535a93
部件    1 个
        [自研] system.energy_org.sites_page

自研接口
        /api/energy/core-dictionaries              -> EnergyMetricParamController.java
        /api/energy/customer-roles                 -> SiteUserController.java
        /api/energy/device-display-name            -> DeviceDisplayNameController.java
        /api/energy/dictionaries                   -> EnergyDictionaryController.java
        /api/energy/gateway                        -> GatewayBindingController.java
        /api/energy/idle-config                    -> IdleEnergyController.java
        /api/energy/idle-recompute                 -> IdleEnergyController.java
        /api/energy/metric-params                  -> EnergyMetricParamController.java
        /api/energy/org-rate                       -> EnergyRatePolicyController.java
        /api/energy/rate-policies                  -> EnergyRatePolicyController.java
        /api/energy/site-rate-binding              -> EnergyRatePolicyController.java
        /api/energy/site-rate-custom               -> EnergyRatePolicyController.java
        /api/energy/vendor-models                  -> EnergyVendorModelController.java
TB 原生接口
        /api/asset
        /api/auth/user
        /api/customer
        /api/customers
        /api/device
        /api/entityGroup
        /api/entityGroups
        /api/groupPermission
        ...（共 15 个）

关键表
        admin_settings(key=energyDictionaries)
        admin_settings 或资产属性
        admin_settings(key=energyDictionaries), device_profile.profile_data
        rate_template 资产
        rate_template / tou_scheme 资产
        厂商/型号资产 + SERVER_SCOPE 属性
关键 SQL
        -- 本页的组织/场站识别：按档案属性 energyRole，**不能**按 a.type 或 p.name
        -- （TB 改档案名会把新名字回写 asset.type，两者会同时失效）
        -- org = 组织层级（可写 energyRates）；site = 场站（价格写 siteCustomRates）
        -- 实测输出：1 组织 + 3 场站 = 4 行，与 /energy/visible-sites 一致
        SELECT a.name, a.type, p.name AS profile_name, ak.str_v AS energy_role
        FROM asset a
        JOIN asset_profile p ON p.id = a.asset_profile_id
        JOIN attribute_kv ak ON ak.entity_id = p.id
        JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
        WHERE a.tenant_id = '<tenant_id>'::uuid
          AND kd.key = 'energyRole' AND ak.str_v IN ('org', 'site')
        ORDER BY ak.str_v, a.name;
```

**权限边界（2026-11-15 修）**

本页写接口全部经 `requireAccessibleSite` / `requireOrgAccessible`，两层判定：
客户归属 + 场站组授权。旧版只有前者，实测可越权：

```
授权「单相园区」的客户账号 → 对「三相园区」
  POST /energy/site-rate-custom   → 200 且落库（0.01 元/度）
  POST /energy/site-rate-binding  → 200 且写入 uses 关系
  GET  /energy/rate-policies      → 200 可读该场站费率
修复后三条全 403；已授权场站仍 200（无误伤）。

组织级费率另有限制：POST /energy/org-rate → 403
（组织费率是整个组织下所有场站的继承源，包括未授权给该账号的）
```

**身份判定（2026-11-15 修）**

组织与场站必须分开，判据是资产档案：

```
energyRole=org   → 组织层级（organizationRootProfileIds）
energyRole=site  → 场站（siteProfileIds）
organizationProfileIds = org ∪ site（超集，给可见性与结构树排除用）
```

接口下发的身份信息：

```
GET /energy/structure-settings  → organizationProfileIds + siteProfileIds
GET /energy/visible-sites       → 每个 asset 带 energyIsSite: true/false
```

> **为什么不能只看 `asset.type`**：TB 改档案名会回写 `asset.type`。实测只改后端时，
> 「组织与场站」部件的树从 4 个节点变 1 个、场站图标变组织图标 ——
> 因为部件读的是 `/api/customer/{cid}/assets`，那条路径不带后端算好的标记，
> 必须在部件里同时按 `siteProfileIds` 判（已改成这一点）。
>
> 判定口径的完整清单与踩坑记录见铁律 D15。


### 实时能耗（能耗查询）

```
看板    实时能耗
看板ID  74466b60-d2bd-11f1-b794-31725d9e3862
部件    3 个
        [自研] system.energy_management.query_panel
        [自研] system.energy_management.realtime_trend
        [自研] system.energy_management.realtime_kpi

自研接口
        /api/energy/entity-briefs                  -> EnergyMetricParamController.java
        /api/energy/meters                         -> EnergyMeterReadingController.java
        /api/energy/metric-params                  -> EnergyMetricParamController.java
        /api/energy/telemetry-series               -> EnergyTelemetryController.java
        /api/energy/time-anchor                    -> EnergyTimeAnchorController.java
        /api/energy/visible-sites                  -> EnergyRatePolicyController.java
TB 原生接口
        /api/asset
        /api/auth/user
        /api/customer
        /api/device
        /api/deviceProfileInfo
        /api/deviceProfiles
        /api/entitiesQuery/find
        /api/plugins/telemetry
        ...（共 13 个）

关键表
        asset, device（名称/档案缓存）
        device, device_profile, relation, ts_kv_latest
        admin_settings(key=energyDictionaries), device_profile.profile_data
        ts_kv, ts_kv_latest, key_dictionary
        admin_settings
        asset, relation（场站可见性）
```

### 历史能耗（能耗查询）

```
看板    历史能耗
看板ID  73e6bf30-d2bd-11f1-b794-31725d9e3862
部件    2 个
        [自研] system.energy_management.query_panel
        [自研] system.energy_management.timeseries_chart

自研接口
        /api/energy/meters                         -> EnergyMeterReadingController.java
        /api/energy/metric-params                  -> EnergyMetricParamController.java
        /api/energy/telemetry-series               -> EnergyTelemetryController.java
        /api/energy/time-anchor                    -> EnergyTimeAnchorController.java
        /api/energy/visible-sites                  -> EnergyRatePolicyController.java
TB 原生接口
        /api/asset
        /api/auth/user
        /api/customer
        /api/device
        /api/deviceProfileInfo
        /api/deviceProfiles
        /api/entitiesQuery/find
        /api/plugins/telemetry
        ...（共 12 个）

关键表
        device, device_profile, relation, ts_kv_latest
        admin_settings(key=energyDictionaries), device_profile.profile_data
        ts_kv, ts_kv_latest, key_dictionary
        admin_settings
        asset, relation（场站可见性）
```

### 抄表功能（能耗查询）

```
看板    抄表功能
看板ID  742ca1d0-d2bd-11f1-b794-31725d9e3862
部件    4 个
        [自研] system.energy_management.query_panel
        [自研] system.energy_management.meter_reading_board
        [自研] system.energy_management.meter_batch_detail
        [自研] system.energy_management.meter_plan

自研接口
        /api/energy/meter-reading/batches          -> EnergyMeterReadingController.java
        /api/energy/meter-reading/records          -> EnergyMeterReadingController.java
        /api/energy/meter-reading/retry            -> EnergyMeterReadingController.java
        /api/energy/meter-reading/run              -> EnergyMeterReadingController.java
        /api/energy/meter-reading/run-plan         -> EnergyMeterReadingController.java
        /api/energy/meters                         -> EnergyMeterReadingController.java
        /api/energy/metric-params                  -> EnergyMetricParamController.java
        /api/energy/time-anchor                    -> EnergyTimeAnchorController.java
        /api/energy/visible-sites                  -> EnergyRatePolicyController.java
TB 原生接口
        /api/asset
        /api/auth/user
        /api/customer
        /api/device
        /api/deviceProfileInfo
        /api/deviceProfiles
        /api/entitiesQuery/find
        /api/plugins/telemetry
        ...（共 14 个）

关键表
        meter_reading_batch, meter_reading_record
        meter_reading_record, ts_kv_latest
        device, device_profile, relation, ts_kv_latest
        admin_settings(key=energyDictionaries), device_profile.profile_data
        admin_settings
        asset, relation（场站可见性）
```


### 峰谷分析（能耗分析）

```
看板    峰谷分析
看板ID  745670f0-d2bd-11f1-b794-31725d9e3862
部件    2 个
        [自研] system.energy_management.query_panel
        [自研] system.energy_management.tou_analysis

自研接口
        /api/energy/meters                         -> EnergyMeterReadingController.java
        /api/energy/metric-params                  -> EnergyMetricParamController.java
        /api/energy/time-anchor                    -> EnergyTimeAnchorController.java
        /api/energy/tou-analysis                   -> EnergyAnalysisController.java
        /api/energy/visible-sites                  -> EnergyRatePolicyController.java
TB 原生接口
        /api/asset
        /api/auth/user
        /api/customer
        /api/device
        /api/deviceProfileInfo
        /api/deviceProfiles
        /api/entitiesQuery/find
        /api/plugins/telemetry
        ...（共 12 个）

关键表
        device, device_profile, relation, ts_kv_latest
        admin_settings(key=energyDictionaries), device_profile.profile_data
        admin_settings
        ts_kv + tou_scheme 资产
        asset, relation（场站可见性）
```

### 分项能耗（能耗分析）

```
看板    分项能耗
看板ID  7412d840-d2bd-11f1-b794-31725d9e3862
部件    4 个
        [自研] system.energy_management.asset_stats_chart
        [自研] system.energy_management.distribution_chart
        [自研] system.energy_management.ranking_list
        [自研] system.energy_management.analysis_bar

自研接口
        /api/energy/entity-briefs                  -> EnergyMetricParamController.java
        /api/energy/meters                         -> EnergyMeterReadingController.java
        /api/energy/metric-params                  -> EnergyMetricParamController.java
        /api/energy/telemetry-series               -> EnergyTelemetryController.java
        /api/energy/time-anchor                    -> EnergyTimeAnchorController.java
        /api/energy/visible-sites                  -> EnergyRatePolicyController.java
TB 原生接口
        /api/asset
        /api/auth/user
        /api/device
        /api/entitiesQuery/find
        /api/plugins/telemetry
        /api/plugins/telemetry/ASSET
        /api/relations

关键表
        asset, device（名称/档案缓存）
        device, device_profile, relation, ts_kv_latest
        admin_settings(key=energyDictionaries), device_profile.profile_data
        ts_kv, ts_kv_latest, key_dictionary
        admin_settings
        asset, relation（场站可见性）
```

### 区域能耗（能耗分析）

```
看板    区域能耗
看板ID  7397b4d0-d2bd-11f1-b794-31725d9e3862
部件    5 个
        [自研] system.energy_management.ranking_list
        [自研] system.energy_management.distribution_chart
        [自研] system.energy_management.asset_stats_chart
        [自研] system.energy_management.analysis_bar
        [自研] system.energy_management.ranking_list

自研接口
        /api/energy/entity-briefs                  -> EnergyMetricParamController.java
        /api/energy/meters                         -> EnergyMeterReadingController.java
        /api/energy/metric-params                  -> EnergyMetricParamController.java
        /api/energy/telemetry-series               -> EnergyTelemetryController.java
        /api/energy/time-anchor                    -> EnergyTimeAnchorController.java
        /api/energy/visible-sites                  -> EnergyRatePolicyController.java
TB 原生接口
        /api/asset
        /api/auth/user
        /api/device
        /api/entitiesQuery/find
        /api/plugins/telemetry
        /api/plugins/telemetry/ASSET
        /api/relations

关键表
        asset, device（名称/档案缓存）
        device, device_profile, relation, ts_kv_latest
        admin_settings(key=energyDictionaries), device_profile.profile_data
        ts_kv, ts_kv_latest, key_dictionary
        admin_settings
        asset, relation（场站可见性）
```

### 用能账单（能耗分析）

```
看板    我的账单
看板ID  7431aae0-d2bd-11f1-b794-31725d9e3862
部件    2 个
        [自研] system.energy_management.query_panel
        [自研] system.energy_management.billing_workspace

自研接口
        /api/energy/billing/crosstab               -> EnergyAnalysisController.java
        /api/energy/billing/delete                 -> EnergyBillingController.java
        /api/energy/billing/generate               -> EnergyBillingController.java
        /api/energy/meters                         -> EnergyMeterReadingController.java
        /api/energy/metric-params                  -> EnergyMetricParamController.java
        /api/energy/time-anchor                    -> EnergyTimeAnchorController.java
        /api/energy/visible-sites                  -> EnergyRatePolicyController.java
TB 原生接口
        /api/asset
        /api/auth/user
        /api/customer
        /api/device
        /api/deviceProfileInfo
        /api/deviceProfiles
        /api/entitiesQuery/find
        /api/plugins/telemetry
        ...（共 12 个）

关键表
        energy_bill 资产 + ts_kv
        ★ energy_bill 资产（SERVER_SCOPE 属性），**不写 billing 表**
        device, device_profile, relation, ts_kv_latest
        admin_settings(key=energyDictionaries), device_profile.profile_data
        admin_settings
        asset, relation（场站可见性）
```


### 基础报表（综合报表）

```
看板    基础报表
看板ID  73b500d0-d2bd-11f1-b794-31725d9e3862
部件    2 个
        [自研] system.energy_management.query_panel
        [自研] system.energy_management.basic_report_workspace

自研接口
        /api/energy/meters                         -> EnergyMeterReadingController.java
        /api/energy/metric-params                  -> EnergyMetricParamController.java
        /api/energy/telemetry-series               -> EnergyTelemetryController.java
        /api/energy/time-anchor                    -> EnergyTimeAnchorController.java
        /api/energy/visible-sites                  -> EnergyRatePolicyController.java
TB 原生接口
        /api/asset
        /api/auth/user
        /api/customer
        /api/device
        /api/deviceProfileInfo
        /api/deviceProfiles
        /api/entitiesQuery/find
        /api/plugins/telemetry
        ...（共 12 个）

关键表
        device, device_profile, relation, ts_kv_latest
        admin_settings(key=energyDictionaries), device_profile.profile_data
        ts_kv, ts_kv_latest, key_dictionary
        admin_settings
        asset, relation（场站可见性）
```

### 手工填报（综合报表）

```
看板    手工填报
看板ID  7426ae60-d2bd-11f1-b794-31725d9e3862
部件    4 个
        [自研] system.energy_management.manual_entry
        [自研] system.energy_management.query_panel
        [自研] system.energy_management.monthly_bar
        [自研] system.energy_management.device_total

自研接口
        /api/energy/manual-entry/category          -> EnergyManualEntryController.java
        /api/energy/manual-entry/meta              -> EnergyManualEntryController.java
        /api/energy/manual-entry/save              -> EnergyManualEntryController.java
        /api/energy/manual-entry/sites             -> EnergyManualEntryController.java
        /api/energy/meters                         -> EnergyMeterReadingController.java
        /api/energy/metric-params                  -> EnergyMetricParamController.java
        /api/energy/time-anchor                    -> EnergyTimeAnchorController.java
        /api/energy/visible-sites                  -> EnergyRatePolicyController.java
TB 原生接口
        /api/asset
        /api/auth/user
        /api/customer
        /api/device
        /api/deviceProfileInfo
        /api/deviceProfiles
        /api/entitiesQuery/find
        /api/plugins/telemetry
        ...（共 13 个）

关键表
        ★ 资产（手工填报表）
        device, device_profile, relation, ts_kv_latest
        admin_settings(key=energyDictionaries), device_profile.profile_data
        admin_settings
        asset, relation（场站可见性）
```


### 闲时能耗（能耗优化）

```
看板    闲时能耗
看板ID  74091440-d2bd-11f1-b794-31725d9e3862
部件    1 个
        [自研] system.idle_energy.analysis_board

自研接口
        /api/energy/idle-analysis                  -> IdleEnergyController.java
        /api/energy/idle-device                    -> IdleEnergyController.java
        /api/energy/visible-sites                  -> EnergyRatePolicyController.java
TB 原生接口
        /api/auth/user

关键表
        ts_kv + 资产汇总
        asset, relation（场站可见性）
```

### 负载预测（能耗优化）

```
看板    负载预测
看板ID  741d86a0-d2bd-11f1-b794-31725d9e3862
部件    2 个
        [自研] system.energy_management.forecast_context
        [自研] system.energy_management.forecast_chart

自研接口
        /api/energy/forecast/context               -> EnergyForecastController.java
        /api/energy/forecast/predict               -> EnergyForecastController.java
        /api/energy/time-anchor                    -> EnergyTimeAnchorController.java
        /api/energy/visible-sites                  -> EnergyRatePolicyController.java

关键表
        ts_kv（历史序列）
        admin_settings
        asset, relation（场站可见性）
```

### 用能建议（能耗优化）

```
看板    用能建议
看板ID  1cebb370-da6f-11f1-aec2-1192e109281d
部件    1 个
        [自研] system.energy_management.diagnosis_brief

自研接口
        /api/energy/diagnosis/brief                -> EnergyDiagnosisController.java
        /api/energy/diagnosis/forecast             -> EnergyDiagnosisController.java
        /api/energy/diagnosis/sites                -> EnergyDiagnosisController.java
TB 原生接口
        /api/plugins/telemetry/DEVICE

关键表
        ts_kv + 计算字段
```

### 用能质量（能耗优化）

```
看板    用能质量
看板ID  1d661390-da6f-11f1-aec2-1192e109281d
部件    1 个
        [自研] system.energy_management.diagnosis_brief

自研接口
        /api/energy/diagnosis/brief                -> EnergyDiagnosisController.java
        /api/energy/diagnosis/forecast             -> EnergyDiagnosisController.java
        /api/energy/diagnosis/sites                -> EnergyDiagnosisController.java
TB 原生接口
        /api/plugins/telemetry/DEVICE

关键表
        ts_kv + 计算字段
```


### 设备运维（设备管理）

```
看板    设备运维
看板ID  a9061a40-d3ca-11f1-9ee9-c3a7be535a93
部件    2 个
        [自研] system.energy_device.ops_page
        [自研] system.energy_device.gateway_detail

自研接口
        /api/energy/alarms                         -> SiteAlarmListController.java
        /api/energy/device-config                  -> EnergyMeterReadingController.java
        /api/energy/metric-params                  -> EnergyMetricParamController.java
        /api/energy/visible-sites                  -> EnergyRatePolicyController.java
TB 原生接口
        /api/asset
        /api/auth/user
        /api/customer
        /api/customers
        /api/device
        /api/deviceProfile
        /api/deviceProfileInfos
        /api/plugins/telemetry/DEVICE
        ...（共 9 个）

关键表
        alarm（TB 原生）
        device + device_profile
        admin_settings(key=energyDictionaries), device_profile.profile_data
        asset, relation（场站可见性）
```

### 设备分组（设备管理）

```
看板    设备分组
看板ID  a4917020-d3cc-11f1-9ee9-c3a7be535a93
部件    1 个
        [自研] system.energy_device.group_page

自研接口
        /api/energy/device-profiles/meta           -> EnergyDeviceProfileMetaController.java
        /api/energy/devices/type-meta              -> EnergyDeviceProfileMetaController.java
        /api/energy/dictionaries                   -> EnergyDictionaryController.java
        /api/energy/structure-settings             -> EnergyStructureController.java
        /api/energy/visible-sites                  -> EnergyRatePolicyController.java
TB 原生接口
        /api/asset
        /api/assetProfileInfos
        /api/auth/user
        /api/customer
        /api/customers
        /api/deviceProfileInfos
        /api/relation
        /api/relations

关键表
        device_profile.profile_data
        admin_settings(key=energyDictionaries)
        asset_profile(SERVER_SCOPE energyRole)
        asset, relation（场站可见性）
```

### 设备拓扑（设备管理）

```
看板    设备拓扑
看板ID  4dd17660-d3cf-11f1-9ee9-c3a7be535a93
部件    1 个
        [自研] system.energy_device.topology_page

自研接口
        /api/energy/topologies                     -> EnergyTopologyController.java
TB 原生接口
        /api/auth/user
        /api/customers
        /api/resource/js_module/system/cytoscape.min.js

关键表
        资产（topology 档案）+ relation
```


### 空调运行监控（空调管理）

```
看板    空调运行监控
看板ID  73f58c40-d2bd-11f1-b794-31725d9e3862
部件    1 个
        [TB  ] system.hvac_management.operation_monitor

自研接口
        /api/energy/visible-sites                  -> EnergyRatePolicyController.java
TB 原生接口
        /api/hvac/overview
        /api/plugins/telemetry/DEVICE

关键表
        asset, relation（场站可见性）
```

### 运行计划与配置（空调管理）

```
看板    运行计划与配置
看板ID  74001390-d2bd-11f1-b794-31725d9e3862
部件    1 个
        [TB  ] system.hvac_management.plan_config

自研接口
        /api/energy/visible-sites                  -> EnergyRatePolicyController.java
TB 原生接口
        /api/hvac/modes
        /api/hvac/plan

关键表
        asset, relation（场站可见性）
```

### 每日复盘报告（空调管理）

```
看板    每日复盘报告
看板ID  73ed9d00-d2bd-11f1-b794-31725d9e3862
部件    1 个
        [TB  ] system.hvac_management.daily_report

自研接口
        /api/energy/visible-sites                  -> EnergyRatePolicyController.java
TB 原生接口
        /api/hvac/daily-report

关键表
        asset, relation（场站可见性）
```

## 五、⭐ 告警只有**两套**机制（不是三套）

> 这里纠正过一版错误说法。之前写「三套」，其中「设备档案告警」是误判：
> `device_profile.profile_data.alarms` **实测 0 个非空**，那只是 TB 的默认空字段。
>
> ```sql
SELECT count(*) FROM device_profile
WHERE (profile_data->'alarms') IS NOT NULL
  AND (profile_data->'alarms')::text <> 'null';   -- 实测 0 ```

| 机制 | 存在哪 | 当前数量 | 谁评估 | 产出 |
| --- | --- | --- | --- | --- |
| ① 计算字段告警 | `calculated_field` type=ALARM，挂 DEVICE_PROFILE | **7 条** | TB 原生 CF 引擎 | TB 原生 alarm |
| ② 客户自建规则 | `alarm_rule` / `alarm_rule_state` 表 | **0 条** | 自研 `AlarmRuleEngine`（30s 轮询） | TB 原生 alarm |

两套最终都写 **`alarm` 表**（8,638 条），所以确认 / 清除 / 通知 / 看板 / TTL 清理全部统一。

**第 ① 套由 `AlarmRuleController` 直接对 `calculated_field` 做 CRUD** ——
它 import 的就是 `com.guard.server.common.data.cf.CalculatedField`，
不是独立的「告警规则表」。

**第 ② 套就是「客户用户可以根据自身情况创建告警规则」的实现**，
见 `AlarmRuleCrudController` 类注释。现在 0 行说明还没有客户建过规则。

当前 8,638 条告警的构成：

```sql
SELECT type, count(*) FROM alarm GROUP BY type ORDER BY count(*) DESC;
```

```
功率因数偏低        8593
电压越限              33
电压不平衡度超限        12
```

## 六、⚠️ 表名对得上，但数据不在那

这是最容易误导人的地方。三种情况要分清：

| 表 | 行数 | 真实情况 | 判断依据 |
| --- | --- | --- | --- |
| `billing` / `billing_detail` | **0** | **死表**。账单实际写 `energy_bill` 资产 + SERVER_SCOPE 属性 | `EnergyBillingController:106` 注释明确：「出账把结果写成 energy_bill 资产 + SERVER_SCOPE 属性（**不写 billing 表**）」 |
| `alarm_rule` / `alarm_rule_state` | **0** | **活着但没人用**。规则设计在这，还没客户建过 | 表由 `EnergySchemaInstaller:558` 创建，`AlarmRuleCrudController` 有完整 CRUD |
| `meter_reading_record` | **8** | **在用**，抄表记录明细 | 配套 `meter_reading_batch` 19 行 |

> **只有 `billing` 是真死表**（早期设计用表，后来改成资产，表没删）。
> 它现在只被 `EnergyCustomerPurgeController` 的清理清单引用。
>
> `alarm_rule` 是「功能已上线、尚未使用」——这是客户自建告警规则的存储，
> 现在 0 行说明还没有客户建过。
>
> **判据**：查数据前先 `SELECT count(*)`，别假设表名对就有数据。

## 七、关键表速查

| 你要查什么 | 查哪 |
| --- | --- |
| 有什么设备/资产/场站 | `device` / `asset` / `asset_profile` / `device_profile` |
| 谁归属谁 | `relation`（注意 `Contains` 和 `SiteContains` 两套口径） |
| 设备最新值 | `ts_kv_latest` + `key_dictionary` |
| 设备历史序列 | `ts_kv` + `key_dictionary` |
| 资产汇总（场站/分项/区域） | `ts_kv_latest`，entity 是 ASSET，key=`energy_total`/`power_total`/`energy_day` |
| 看板与部件 | `dashboard.configuration`（JSON） |
| 部件脚本 | `widget_type.descriptor.controllerScript` |
| 菜单 | `custom_menu.config` |
| [告警](#告警事件) | `alarm`（TB 原生，8638 条） |
| [抄表](#抄表功能-能耗查询) | `meter_reading_batch` / `meter_reading_record` |
| 账单 | `energy_bill` **资产**，不是 `billing` 表 |
| 盘查报告口径 | `audit_report_version` **资产** |
| [节能记录](#节能记录) | `saving_record` **资产** |
| 字典/口径参数 | `admin_settings` 里 key=`energyDictionaries` |
| 版本控制 | `admin_settings` 里 key=`entitiesVersionControl` |

**资产类数据的一个通用查法**（账单/盘查报告/节能记录都适用）：

```sql
SELECT a.name, k.key,
       coalesce(av.str_v, av.long_v::text, av.dbl_v::text, av.bool_v::text) AS val
FROM asset a
JOIN attribute_kv av ON av.entity_id = a.id AND av.attribute_type = 2   -- 2 = SERVER_SCOPE
JOIN key_dictionary k ON k.key_id = av.attribute_key
JOIN asset_profile p ON p.id = a.asset_profile_id
WHERE p.name = 'energy_bill'   -- 换成 audit_report_version / saving_record
ORDER BY a.name, k.key;
```

实跑输出（节选）：

```
BILL-7CE48900-2026-10-elec-7E9434D0   amount       3950.73
BILL-7CE48900-2026-10-elec-7E9434D0   basicFee     1500.00
BILL-7CE48900-2026-10-elec-7E9434D0   status       draft
BILL-7CE48900-2026-10-elec-7E9434D0   energy       elec
```

> ⚠️ **两个必须知道的字段陷阱**（踩过才知道）：
> - `attribute_kv.attribute_type` 是**整数枚举**，不是字符串：
>   `2 = SERVER_SCOPE`（1,516 行，业务数据几乎都在这）、`3 = SHARED_SCOPE`（18 行）。
>   写 `= 'SERVER_SCOPE'` 会报 `invalid input syntax for type integer`。
> - 数值列叫 `dbl_v`，不是 `double_v`。

## 八、怎么重新生成这份索引

这份文档的全部数据都是脚本提取的，**改了看板或代码后请重跑，不要手改**。

保存下面脚本为 `genpage.py`，在仓库根目录运行：

```python
#!/usr/bin/env python3
"""生成页面链路索引。在仓库根目录运行：python3 genpage.py"""
import json, re, glob, os, subprocess

PSQL = ['docker','exec','-i','energy-postgres','psql','-U','postgres','-d','thingsboard','-tA','-c']
def sql(q):
    return subprocess.run(PSQL+[q], capture_output=True, text=True).stdout

# 1) 菜单与看板
menu = json.loads(sql("SELECT config FROM custom_menu WHERE name LIKE '业务导航%';"))
dash = {d['id']: d for d in json.loads(sql(
    "SELECT json_agg(json_build_object('id',d.id::text,'title',d.title,"
    "'widgets',(SELECT json_agg(w.value->>'typeFullFqn')"
    " FROM jsonb_each((d.configuration::jsonb)->'widgets') w))) FROM dashboard d;"))}

# 2) 部件脚本里的接口
wf = {}
for f in glob.glob('guard-server/src/main/data/json/system/widget_types/*.json'):
    try: wf[json.load(open(f, encoding='utf-8'))['fqn']] = f
    except Exception: pass

def apis(fqn):
    f = wf.get(fqn) or wf.get(fqn.replace('system.', '', 1))
    if not f: return []
    try: s = json.load(open(f, encoding='utf-8'))['descriptor'].get('controllerScript', '')
    except Exception: return []
    return sorted({m.group(1).rstrip('/') for m in
                   re.finditer(r"['\"](/api/[a-zA-Z0-9_/\-{}.$]+)", s)})

# 3) 端点 -> Controller
ctrl = {}
for f in glob.glob('guard-server/src/main/java/com/guard/server/controller/*.java'):
    for m in re.finditer(r'@(?:Get|Post|Put|Delete)Mapping\(\s*(?:value\s*=\s*)?"([^"]+)"',
                         open(f, encoding='utf-8', errors='ignore').read()):
        p = m.group(1); p = '/api'+p if not p.startswith('/api') else p
        ctrl.setdefault(p,set()).add(os.path.basename(f)[:-5])

# 4) 遍历菜单
pages = []
def walk(ms, parent=''):
    for m in ms:
        did = m.get('dashboardId')
        did = did.get('id') if isinstance(did, dict) else did
        if m.get('pages') or m.get('children'):
            for k in ('pages','children'):
                if m.get(k): walk(m[k], m.get('name'))
        else: pages.append((parent, m.get('name'), did))
walk(menu.get('items', []))

# 5) 输出
print('# 客户页面链路索引\n')
print('| 页面 | 看板 | 部件 | 自研接口 | Controller |')
print('| --- | --- | --- | --- | --- |')
for parent, name, did in pages:
    d = dash.get(did) or {}
    wl = d.get('widgets') or []
    a = sorted({x for f in wl for x in apis(f) if '/energy/' in x})
    c = sorted({y for x in a for y in ctrl.get(x, ())})
    label = (parent+' / ' if parent else '') + name
    print('| %s | %s | %d | %d | %s |' % (label, d.get('title','-'), len(wl), len(a),
                                          ', '.join(c[:3]) + ('…' if len(c)>3 else '')))
```

```bash
python3 genpage.py > /tmp/gen.md
cp /tmp/gen.md shiyongshouce/content/admin/12-page-map.md   # 手册版（唯一权威）
cp /tmp/gen.md docs/PAGE-MAP.md                              # 仓库内快照
cd shiyongshouce && ./sync.sh                                # 同步到发布目录
```

> 两份内容必须一致：手册版是给人看的权威版本，`docs/` 是仓库内快照。
> 改完跑上面三行，不要只改一处。

脚本干什么：

1. 从 `custom_menu` 读菜单 → 页面与 `dashboardId`
2. 从 `dashboard.configuration.widgets` 读每个看板用了哪些部件
3. 扫 `widget_type.descriptor.controllerScript`，正则提取 `/api/...` 字面量
4. 扫 `controller/*.java` 的 `@*Mapping`，建立端点 → Controller 映射
5. 交叉输出

> 实测：26 个页面、54 个自研接口，**全部 54 个都能匹配到 Controller**。
> 如果重跑后出现未匹配，说明新加的端点路径和正则不匹配（只匹配
> `@GetMapping("...")` 字面量形式，动态拼接的路径抓不到）。

---

相关文档：[架构导航](/admin/architecture)（四步倒推法）· 
[④ 数据模型](/admin/data-model)（数据模型）· 
[⑧ 运维 SQL](/admin/ops-sql)（运维 SQL 1652 行）