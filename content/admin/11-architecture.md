# 架构导航：怎么驾驭这套系统

> 这一页回答「代码在哪、谁在写、数据怎么流」。
> 想知道某个具体页面用了哪些接口和表，直接翻 [页面链路卡](/admin/page-map)。

> 给「能读代码、会 SQL、会前端」的人。
>
> **手册已经有了，不用通读。** [平台运维手册](/admin/index) 有 18,562 行，
> [④ 数据模型](/admin/data-model)（1301 行）、[⑤ 数据流](/admin/data-flow)（325 行）、[⑧ 运维 SQL](/admin/ops-sql)（1652 行）
> 讲清了「数据长什么样」。它缺的是「代码在哪」——本文补这一块。
>
> 本文只有一件事：**让你从任何一个现象，5 分钟内定位到该看的文件。**

## 一、先认清规模：不可能通读

```
controller        135 文件 / 55,092 行      自研
service/energy     24 文件 / 14,564 行      自研
service/install    62 文件 / 21,604 行      自研（初始化，平时不用碰）
前端 TS         2,368 文件                  自研

动态部件（这里有个好消息）：
  数据库 widget_type 表         739 条
    ├─ 自研 energy 系列          50 条   ← 你只需要懂这些
    └─ TB 自研以外（自带）       689 条   ← 不用管
```

**自研部件只占 7%。** 739 这个数字听着吓人，实际要理解的是 50 个。

**结论：不要按目录读，要按问题倒推。** 目标不是"读完"，是"知道去哪找"。

## 二、三层地图（记住这张图就够一半）

```
┌─ 第 1 层：配置层（全是 TB 实体，存在 PostgreSQL 里）────────────────┐
│                                                                    │
│   dashboard ──(configuration.widgets)──> widget_type              │
│       │                                      │                     │
│       └─ states/layouts                      └─ controllerScript   │
│                                                   （JS，578 个都有） │
│   asset / device / asset_profile / device_profile                  │
│   rule_chain / calculated_field / notification_*                   │
│                                                                    │
│   ★ 这一层用 SQL 就能完全看懂，不需要读 Java                        │
└────────────────────────────────────────────────────────────────────┘
                              │ 部件脚本调后端
                              ▼
┌─ 第 2 层：自研接口层（/api/energy/*，130 个端点）──────────────────┐
│                                                                    │
│   Energy*Controller  ←── 55,092 行，135 个文件                      │
│       │                                                            │
│       └─> service/energy/*（14,564 行）← 真正的业务逻辑             │
│                                                                    │
│   ★ 只在你需要改/查这个功能时才进去读                                │
└────────────────────────────────────────────────────────────────────┘
                              │ 调 TB 原生
                              ▼
┌─ 第 3 层：TB 原生能力（不用读源码，要知道边界）────────────────────┐
│                                                                    │
│   遥测读写：/api/plugins/telemetry/*                                │
│   关系查询：/api/relations                                          │
│   实体查询：/api/entitiesQuery/find（只能取 latest）                │
│   规则链：aggregate latest 等 70 个节点                             │
│   报表：report_template / report                                    │
│                                                                    │
│   ★ 边界见 AGENTS.md「TB 原生能力边界」章，已实测过多次              │
└────────────────────────────────────────────────────────────────────┘
```

**关键认知：你 90% 的工作在第 1 层。**
584 个动态部件 + 139 资产 + 35 设备 + 32 看板，全是数据库里的 JSON。
改这些不需要碰 Java，改完刷新页面就生效。

> 📇 **26 个页面的现成链路卡**见 [页面链路卡](/admin/page-map) ——
> 每个页面一张卡：看板 → 部件 → 接口 → Controller → 关键表，全部自动提取。
> 下面这一节讲「怎么自己走一遍」，那份文档是「别人已经走完的结果」。

## 三、倒推四步法（核心方法）

选一个你看到的现象，比如「分项能耗页面的柱子不对」：

### 第 1 步：这个页面是哪个 dashboard

```sql
SELECT id, title FROM dashboard WHERE title LIKE '%分项%';
```

### 第 2 步：它用了哪些部件

```sql
SELECT w.key AS widget_id,
       w.value->>'typeFullFqn' AS widget_type,
       w.value->'config'->'settings' AS settings
FROM dashboard d, jsonb_each((d.configuration::jsonb)->'widgets') w
WHERE d.title = '分项能耗';
```

> ⚠️ 布局和尺寸在 `configuration.states.<state>.layouts.<layout>.widgets`，
> `configuration.widgets` 只存部件配置。两处要对齐。

### 第 3 步：这个部件调了哪些后端接口

```bash
python3 - <<'PY'
import json,re
f='guard-server/src/main/data/json/system/widget_types/energy_management_asset_stats_chart.json'
s=json.load(open(f,encoding='utf-8'))['descriptor']['controllerScript']
for m in sorted(set(re.findall(r"['\"](/api/[a-zA-Z0-9_/\-{}]+)", s))):
    print(m)
PY
```

输出（实测）：

```
/api/asset/                    ← TB 原生
/api/device/                   ← TB 原生
/api/energy/entity-briefs      ← 自研
/api/energy/telemetry-series   ← 自研
/api/plugins/telemetry/        ← TB 原生
/api/relations                 ← TB 原生
```

> ⚠️ **`fqn` 前缀不一致（容易踩）**：
> 库里 `widget_type.fqn` 存的是 `energy_management.asset_stats_chart`（**无** `system.`），
> 看板配置里引用的是 `system.energy_management.asset_stats_chart`（**有** `system.`）。
> 写 SQL 用前者，看看板 JSON 用后者。

**这一步就分清了：哪些逻辑在自研后端，哪些是直接读 TB。**

### 第 4 步：找到那个端点的实现

```bash
grep -rn '"/energy/telemetry-series"' guard-server/src/main/java/
```

一条命令定位到 `EnergyTelemetryController`。从这里再往下跟 service。

> 这四步走完，任何一个页面你都摸清了。**重复 5 次，你就有系统全图了。**

## 四、功能索引（130 个 energy 端点按二级路径）

```
model            17   能耗模型分析
topologies       11   物理结构（分项/区域树的配置）
meter-reading    11   抄表（最复杂，EnergyMeterReadingController 4299 行）
manual-entry      7   手工填报
alarm-events      7   告警事件查询
alarm-rules       5   告警规则
diagnosis         4   诊断报告
billing           4   账单
audit-report      4   盘查报告口径存档
vendor-models     3   厂商型号
metric-params     3   指标参数
demo-data         3   演示数据
structure-settings 2  组织/场站结构
site-rate-*       4   场站费率绑定与自定义
site-groups       2   场站分组
idle-config       2   闲时能耗配置
forecast          2   负载预测
dictionaries      2   业务字典
device-config     2   设备配置
customer-purge    2   客户数据清理
visible-sites     1   可见场站（客户权限）
tou-*             2   分时电价方案与分析
```

**从端点前缀就能猜到去哪个 Controller**，不用全局搜索。

## 五、数据流主干（三条，记住就不迷路）

### 5.1 遥测：设备 → 库 → 页面

```
RTU / 模拟器
  └─ MQTT :11883 ──> TB Core ──> ts_kv / ts_kv_latest
                                      │
        ┌─────────────────────────────┼──────────────────────┐
        ▼                             ▼                      ▼
  部件直接读                    AssetTotalsScheduler    计算字段
  /api/plugins/telemetry/        每小时算汇总            （告警）
                                 写资产 energy_total
```

### 5.2 汇总：设备遥测 → 资产

```
AssetTotalsScheduler.refresh()          每 1 小时
  └─> EnergyBootstrapInstaller.writeAssetTotal(...)
        时间轴 = 各设备上报 ts 并集
        逐 ts 重算「截至该 ts 最新值之和」
        陈旧剔除 lv>0 && (ts-lts) <= 2h
        空载不写（energy>0 / power>0 才写）
  └─> 资产的 energy_total / power_total / energy_day
```

> **这是全系统最容易出错的地方**，也因此踩过最多坑。
> 细节见 仓库根 `AGENTS.md` 的「二、资产汇总」与 `05-data-flow.md`。

### 5.3 展示：看板 → 部件 → 接口

```
dashboard.configuration.widgets
  └─> widget_type.descriptor.controllerScript
        ├─ 直接读 TB（relations / telemetry）→ 快，但每个部件各查一遍
        └─ 调自研接口 → 能复用缓存，但多一跳
```

## 六、按你会的能力分工

| 你想搞清 | 用什么 | 具体做法 |
| --- | --- | --- |
| 数据长什么样 | **SQL**（最强抓手） | 读 [⑧ 运维 SQL](/admin/ops-sql)，1652 行全是可直接跑的查询 |
| 页面为什么这样 | **前端 + JSON** | 看 `widget_type.descriptor`，重点 `controllerScript` |
| 某个数字怎么算的 | **代码** | 倒推四步法 → 跟到 `service/energy/*` |
| TB 能做什么 | **不读源码** | 查 仓库根 `AGENTS.md`「TB 原生能力边界」，都是实测结论 |
| 初始化/字典怎么来的 | **代码** | `service/install/*`（62 文件，只在重建环境时看） |

## 七、三条「先别读」清单（省你时间）

1. **别读 `service/install/`（62 文件 21,604 行）**
   那是初始化器，只在建新环境时跑。除非你要改演示数据生成规则，否则完全不用碰。

2. **别读 584 个动态部件**
   按需查。`ls guard-server/src/main/data/json/system/widget_types/ | grep 关键词`
   就够了，不要一个个看。

3. **别读 TB 内核**（`ui-ngx/src/app` 通用代码、`application/` 模块）
   那些是 fork 来的上游代码。要知道「TB 能干什么」，查实测文档比读源码快得多。

## 八、一条建议的自测闭环

理解对不对，用这个验证：

```bash
# 1) 改一个部件的文案或阈值（只改 DB 里的 JSON）
# 2) 刷新页面看是否生效 → 证明你找对了部件
# 3) 改回去
```

比读十遍代码管用。**「改一处、看反应、改回去」是最快的理解方式。**

## 九、建议的学习顺序（约 3 天）

```
第 1 天：数据层
  ├─ 跑通 08-ops-sql.md 的「按症状找 SQL」里的 10 条查询
  ├─ 用 SQL 看清：1 个场站 → 它的设备 → 它们的遥测 → 它的汇总值
  └─ 目标：能在库里找到任何一个页面数字的来源表

第 2 天：展示层
  ├─ 挑「能耗概览」一个页面，走完倒推四步法
  ├─ 打开 widget_type 的 controllerScript，看懂它查了什么
  └─ 目标：任意页面能在 5 分钟内定位到部件和接口

第 3 天：计算层
  ├─ 跟一条完整链路：设备遥测 → AssetTotalsScheduler → 资产汇总 → 部件
  ├─ 读 writeAssetTotal 的注释（那里记着踩过的坑）
  └─ 目标：能解释「为什么场站功率是 0 而设备有值」
```

三天后你不会有全图，但会有**定位能力**——这比记住细节有用得多。

## 十、附：几条最常用的勘察 SQL

```sql
-- 全平台家底（最常用的一条）
SELECT 'device' t, count(*) FROM device
UNION ALL SELECT 'asset', count(*) FROM asset
UNION ALL SELECT 'dashboard', count(*) FROM dashboard
UNION ALL SELECT 'widget_types', count(*) FROM widget_type
UNION ALL SELECT 'rule_chain', count(*) FROM rule_chain;
-- 实测：35 / 139 / 32 / 739 / 2

-- 只要自研部件（别被 739 吓到，其中 689 是 TB 自带）
SELECT fqn, name FROM widget_type
WHERE fqn LIKE '%energy%' ORDER BY fqn;   -- 50 条

-- 某场站下所有设备（关系三口径之一）
SELECT d.name, k.key, coalesce(l.dbl_v,l.long_v) val, l.ts
FROM relation r
JOIN device d ON d.id = r.to_id AND r.to_type = 'DEVICE'
LEFT JOIN ts_kv_latest l ON l.entity_id = d.id
LEFT JOIN key_dictionary k ON k.key_id = l.key
WHERE r.from_id = '<场站id>'::uuid
  AND r.relation_type IN ('Contains','SiteContains');

-- 设备的键值清单（查某个 key 为什么没有）
SELECT k.key, coalesce(l.dbl_v,l.long_v) val,
       round((extract(epoch from now())*1000 - l.ts)/60000.0,1) age_min
FROM ts_kv_latest l JOIN key_dictionary k ON k.key_id = l.key
WHERE l.entity_id = '<设备id>'::uuid ORDER BY age_min;

-- 一个看板用了哪些部件
SELECT w.value->>'typeFullFqn' AS widget_type, count(*)
FROM dashboard d, jsonb_each((d.configuration::jsonb)->'widgets') w
WHERE d.title = '<看板名>'
GROUP BY 1 ORDER BY 2 DESC;
```
