# ④ 数据模型

库里有什么、每张表管什么、设备的属性怎么分三层、公共字典怎么组织的。

> 想查数据对不对 → [⑧ 运维 SQL](/admin/ops-sql)。
> 想看数据怎么流动 → [⑤ 数据流](/admin/data-flow)。

---

## 一、表的分层

122 张表，但运维真正会用到的只有下面这些。**按层记，别按字母背**。

### 第 1 层：实体（有什么东西）

| 表 | 存什么 | 关键字段 |
| --- | --- | --- |
| `tenant` | 租户（一个部署通常一个） | `title` |
| `customer` | 客户 | `title`（租户内唯一）、`custom_menu_id` |
| `asset` | 资产：组织/场站/区域/分项/楼栋 | `type`（中文类型名）、`name`、`customer_id` |
| `device` | 设备 | `name`（租户内唯一）、`type`（设备档案名）、`customer_id` |
| `asset_profile` / `device_profile` | 资产 / 设备档案 | `name`（如「单相电能表」） |
| `dashboard` | 看板（模板与客户副本） | `title`、`tenant_id`、`assigned_customers` |
| `widget_type` | 部件定义 | `fqn`、`version`、`descriptor`(jsonb) |
| `widgets_bundle` | 部件分组 | `alias`、`scada_first` |
| `tb_user` / `user_credentials` | 账号与密码 | `email`、`authority`、`customer_id` |
| `custom_menu` | 菜单树 | `config`(json)、`name` |

> **`device.name` 是租户内唯一**。多个客户建同名设备会冲突，
> 所以开户脚本自动加 `·客户名` 后缀。`device.label` 才是给人看的中文名。

### 第 2 层：属性与关系（实体之间怎么连）

| 表 | 存什么 | 关键字段 |
| --- | --- | --- |
| `attribute_kv` | **所有实体的属性**（设备/资产/档案都用它） | `entity_id`、`attribute_type`、`attribute_key`、`json_v` / `str_v` / `long_v` / `dbl_v` / `bool_v` |
| `relation` | 实体关系 | `from_id`、`to_id`、`relation_type`（`Contains` / `SiteContains` / `Uses`…） |
| `key_dictionary` | **属性键名 → 数字 id 的映射** | `key`、`key_id` |

**两组必须记住的事实**（踩过多次）：

1. **`attribute_kv` 里没有 `attribute_key` 的字符串**，只有数字 `key_id`。
   查属性必须 join：
   ```sql
   SELECT kd.key, kv.str_v
   FROM attribute_kv kv
   JOIN key_dictionary kd ON kd.key_id = kv.attribute_key AND kd.key = 'type1'
   WHERE kv.entity_id = '<设备id>';
   ```
   **永远不要在 SQL 里硬编码 key_id** —— 换库就变。

2. **`attribute_type` 是整数**：`SERVER_SCOPE=2`、`SHARED_SCOPE=1`、`CLIENT_SCOPE=3`。
   业务属性一律 `SERVER_SCOPE`。

> **`json_v` 还是 `str_v` 是最大的坑**：
> 平台读列表/对象类属性（`measurePoints`、`rpcCommands`、`dictionaries`）时只看 **`json_v`**。
> 用脚本写入时如果 `json.dumps()` 成字符串传过去，TB 会存进 `str_v` ——
> 属性「存在」，界面却显示 0 条，而且**不报错**。必须传对象。

### 第 3 层：遥测（时序数据）

| 表 | 存什么 | 说明 |
| --- | --- | --- |
| `ts_kv` | 遥测主表 | `entity_id`、`key`(数字)、`ts`(毫秒)、`dbl_v`/`long_v`/`str_v`/`bool_v` |
| `ts_kv_latest` | 每设备每 key 的最新值 | 看板「当前值」读这里 |
| `ts_kv_dictionary` | 遥测键名 → 数字 id | 与 `key_dictionary` **不是同一张表** |

**`ts_kv` 是分区表**（按 `ts` 分区）。运维要知道两点：

- **删数据用 `DELETE`，不要 `DROP`** —— `DROP` 会删掉整个分区（跨客户的数据）。
- 删完记得 `VACUUM`，否则空间不回收。

### 第 4 层：业务扩展（能源功能自己的表）

| 表 | 存什么 |
| --- | --- |
| `billing` / `billing_detail` | 用能账单与明细 |
| `rate_template` | 电价模板（峰平谷单价） |
| `tou_scheme` | 分时时段方案 |
| `alarm` / `alarm_rule` | 告警与告警规则 |
| `calculated_field` | 派生指标定义（如三相不平衡度） |
| `audit_log` | 审计日志 |
| `api_usage_state` | 接口调用计次（限流用） |

> 业务扩展表的结构随版本会变，**排查前先用
> `\d 表名` 看一眼当前列**，不要照旧文档猜。

---

## 二、设备的属性分三层（最容易搞混）

一台设备的「身份」分散在三个属性里，各答一个问题。**混用会导致看板查不到设备**。

| 属性 | 存在哪 | 答什么问题 | 取值示例 |
| --- | --- | --- | --- |
| `type1` | `device` 的 `additionalInfo` + `SERVER_SCOPE` | **接的什么能源** | `elec` / `water` / `gas` / `steam` / `heat` / `env` |
| `type2` | 同上 | **它是哪种设备** | `normal` / `smart_breaker` / `temp_humidity` |
| `deviceType1` | `SERVER_SCOPE` | **一级设备类型**（字典 code） | `elec_meter` / `water_meter` / `env_device` |
| `meterLevel` | `SERVER_SCOPE` | **汇总层级** | `1`=总表 / `2`=分项 / `0`=非计量 |

### 关键判据：怎么区分「电表」和「接在电上的设备」

**`type1` 做不到这件事。** 8 路继电器、智能空开、逆变器的 `type1` 都是 `elec`，
但它们没有表底、没有计量单元。

唯一能区分的是**二级设备类型上标的 `role`**：

| role | 含义 | 例子 |
| --- | --- | --- |
| `meter` | 计量器具 | 单相电能表、三相电能表、水表、热力表 |
| `sensor` | 采集类（不计量） | 温湿度变送器 |
| `control` | 控制类（不计量） | 智能空开、8 路继电器、逆变器 |
| `other` | 其他 | 网关 |

`role` 由后端从「能源参数字典」的 `deviceTypeL1` 算出，随 `/api/energy/meters` 下发。
**查设备清单要判「是不是计量点」，一律用 `role`，不要用 `type1`。**

### 场站归属只认关系，不认属性

设备上有 `additionalInfo.siteId`，**但那只是归档，看板不读它**。

三个能耗看板（综合 / 分项 / 区域）都靠 `relation` 表遍历：

| 关系 | 用途 |
| --- | --- |
| 场站 `--SiteContains-->` 设备 | 「设备属于哪个场站」的**唯一**依据 |
| 区域 / 分项 `--Contains-->` 设备 | 区域能耗 / 分项能耗按节点取数 |
| 网关 `--Contains-->` 设备 | 设备树、RPC 路由 |

**只写 `siteId` 不建关系 = 场站下 0 台表**，界面只说
「当前筛选下没有可用计量点」，不报任何错。

修复：`bash scripts/30-rtu-env-init.py`（第 ⑩ 步会补齐并清理多余旧边）。

---

## 三、公共字典（租户级主数据）

平台有**六类**字典，都存在「能源参数字典」这一个资产的 `SERVER_SCOPE` 里，
键名 `dictionaries`（`json_v`），版本号 `dict_version`。

| 字典 | 存什么 | 谁在用 |
| --- | --- | --- |
| `kinds` | 用能品种（电能/水/燃气/蒸汽/热力/环境） | 场站声明、看板品种筛选 |
| `deviceTypeL1` | 一级设备类型 + **role** + 该类型的标准 key 清单 | 设备建档、抄表候选、计量点判定 |
| `deviceTypeL2` | 二级设备类型（normal / smart_breaker…） | 设备建档 |
| `wiring` | 接线方式（1P2W / 3P4W） | 决定能采哪些 key |
| `standardKeys` | **每个指标的标准 key + 单位 + 聚合 + tier + 标准** | RTU 上报键名、看板取数 |
| `builtinTables` | 内置对照表 | 报表 |

### 建租户时自动铺什么

平台的 `02-onboard.sh` 建租户时，后端会自动铺一套**租户级主数据**。
这些是**所有客户共用**的，改一次影响全部：

| 主数据 | 数量 | 改动的后果 |
| --- | --- | --- |
| 资产档案 | 17 个业务档案（库里共 23 行，含 6 个系统内置） | 影响所有客户的资产类型下拉 |
| 设备档案 | 7 个业务档案（库里共 14 行，含 7 个系统内置） | 影响所有客户建档可选类型 |
| 能源参数字典 | 5 品种 / 9 种设备类型 / 137 个标准 key / 2 种接线 | 影响所有设备的遥测可读性 |
| 分时时段方案 | 4 套 | 影响所有客户峰谷计算 |
| 费率模板（示例价） | 4 个 | 只是示例，客户应替换 |
| 告警 + 派生指标 | 11 条（5 种，租户 + 系统各一份） | 影响所有电表的告警 |
| 租户菜单 | 11 个顶层项 | 影响客户菜单模板 |

**判据**：客户登录看到「品种指标」是空的 → 上面这套没铺，重跑 `02-onboard.sh`。

> **「业务档案」与「库里行数」为什么不同**：`asset_profile` / `device_profile`
> 除了能源业务建的，还有平台自带的（`default`、`拓扑`、`厂商`、`设备型号` 等）。
> 手册里的数字指**能源业务建的那部分**，运维 `SELECT count(*)` 会多出来 ——
> 这不是缺漏，别去补。

### 读字典（任何脚本都这么读）

```bash
curl -s -H "X-Authorization: Bearer $TOKEN" \
  http://127.0.0.1:8090/api/energy/core-dictionaries
```

返回永远是**全量**（不受场站过滤）。要看某个场站声明了哪些品种，用：

```bash
curl -s -H "X-Authorization: Bearer $TOKEN" \
  "http://127.0.0.1:8090/api/energy/metric-params?siteId=<场站id>"
```

### 改字典（不改 Java）

写资产属性即可，**立刻生效**，不用重启：

```bash
curl -X POST -H "X-Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  http://127.0.0.1:8090/api/plugins/telemetry/ASSET/<字典资产id>/SERVER_SCOPE \
  -d '{"dictionaries": {...}, "dict_version": 9}'
```

> **必须传对象，不能传 JSON 字符串** —— 见上文 `json_v` 的坑。

### 标准 key 的能力分级（tier）

每个电能 key 带两个字段，回答「什么表能采、依据哪份标准」：

| tier | 含义 | 典型设备 |
| --- | --- | --- |
| `basic` | DL/T 645-2007 基础多功能表 | DDSU666、DDS1352 |
| `three_phase` | 三相表才有的分相量与无功/视在 | DTSD341、DTSD1352 |
| `harmonic` | 需带谐波测量的三相表（2~31 次） | DTSD342-PQ、PM8000 |
| `pq` | 需专业电能质量表（闪变 / 序分量 / 中性线电流） | PM8000、PAC4200、APView500 |
| `derived` | 平台用采集量算出，表不输出 | —— |

**`wiring` 决定可见 key**：`1P2W` 只有 22 项（基础 + 派生），
`3P4W` 有 122 项。单相表配了 B/C 相，那几项永远是空的（不报错）。

**改字典必须改源码**，否则下次装库又变回旧值：

```bash
python3 tools/rebuild-elec-keys.py --check   # 看差异
python3 tools/rebuild-elec-keys.py           # 写回 energy_library.json
```

这个脚本同时做四件事：删编造项、扩谐波到 31 次、给每个 key 打 `tier`/`standard`、
按 `tier` 重建 `keysByWiring`。**不要手改 JSON**。

### 品种的唯一权威来源

场站声明了哪些品种，存在**场站资产的 `energyType`** 属性（数组）。

| 概念 | 存在哪 | 例子 |
| --- | --- | --- |
| 场站涉猎的品种 | 场站资产 `energyType` | `["elec","water"]` |
| 品种主数据 | 字典 `kinds` | `elec/电能` |
| 设备的品种标记 | 设备 `type1` | `elec` |
| 档案的品种标记 | `device_profile` 的 `energyTypeCode` | `elec` |

判定优先级（后端 `siteVisibleKinds`）：

```
单场站： 场站 energyType → 子树设备档案 energyTypeCode → 不过滤
全部场站：所有场站 energyType 的并集 → 不过滤（一台都没声明时）
```

**禁止用设备名做品种判定**。客户把「电能表」改叫「电度表」就断。

---

## 四、资产与设备的类型码

`asset.type` 与 `device.type` 存的都是**中文类型名**，不是 code。

### 资产类型（`asset.type`）

| 类型 | 用途 |
| --- | --- |
| `场站` | 能耗统计的根，看板按它筛选 |
| `区域` | 空间维度（车间、楼层） |
| `分项` | 用途维度（照明、空调、动力） |
| `组织` | 组织架构（部门） |
| `场站分组` | 维度树的中间层（用能区域/分项下的每场站一个） |
| `energy_*_library` | 六个维度根（用能区域 / 分项 / 性质 / 空间 / 品种 / 组织） |

### 设备的 `additionalInfo` 常用键

| 键 | 含义 |
| --- | --- |
| `siteId` | 所属场站（**仅归档，看板不读**） |
| `simulated` | 是否模拟设备 |
| `deviceVirtual` | **只有明确写 `virtual`/`true` 才算虚拟表**（白名单） |
| `energyTypeCode` | 档案品种（部件优先用它判品种） |
| `parentDeviceId` | 同一接线上「总表 → 分表」的物理父子 |
| `gateway` | 是否网关 |

> `deviceVirtual` 曾经是黑名单式判断（存在且非空就算虚拟），
> 于是想表达「这是实表」而写 `deviceVirtual: 'real'` 的设备被全部剔除，
> 看板恒为空。现在只认白名单值：`true`/`'true'`/`1`/`'1'`/`'virtual'`。

---

## 五、一张图看懂

```
tenant（租户）
  ├── customer（客户）──── custom_menu_id ──→ custom_menu
  │     ├── asset（场站/区域/分项/组织）
  │     │     └── relation: SiteContains / Contains ──→ device
  │     ├── device ──→ device_profile（档案，带 energyTypeCode）
  │     ├── dashboard（看板副本）
  │     └── tb_user（客户账号）
  │
  ├── asset「能源参数字典」── SERVER_SCOPE.dictionaries（六类字典）
  ├── device_profile（租户级共用档案）
  ├── rate_template / tou_scheme（费率与分时）
  └── widget_type（部件定义，系统级在 tenant_id = NULL）
```

**读图要点**：

- 客户只碰得到自己的 `asset` / `device` / `dashboard` / `tb_user`
- 字典、档案、费率是**租户级共用**，改一处影响所有客户
- `widget_type` 分**系统级**（`tenant_id` 为 NULL）和**租户级**两套，
  同名时看板取 **version 更大的那份**
