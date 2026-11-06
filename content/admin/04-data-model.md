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
| `billing` / `billing_detail` | ⚠️ **空表，建了没用**（0 行）。账单存在 `asset`（`type='energy_bill'`）+ `attribute_kv`，见下 |
| `rate_template` | 电价模板（峰平谷单价） |
| `tou_scheme` | 分时时段方案 |
| `alarm` / `alarm_rule` | 告警与告警规则 |
| `calculated_field` | 派生指标定义（如三相不平衡度） |
| `audit_log` | 审计日志 |
| `api_usage_state` | 接口调用计次（限流用） |

**⚠️ 账单不在 `billing` 表**（2026-11-06 实测：`billing` / `billing_detail` 各 0 行）：

出账由 `EnergyBillingService` 完成，写的是**资产**，不是这两张表：

- 账单资产：`asset` 里 `type = 'energy_bill'`，`name` = `BILL-<客户码>-<账期>-<品种>`
- 账单字段：`attribute_kv` 里 `attribute_type = 2`（SERVER_SCOPE），
  键包括 `period` / `energy` / `usage` / `amount` / `energyFee` / `basicFee` / `status` / `details` 等
- 归属：`asset.customer_id`，客户账号靠 TB owner 机制隔离

后端注释原文：「不写 `billing` 表 —— 现有两个消费方（抄表台账的「账单金额」、
峰谷页的账单交叉表）读的都是资产属性；换表等于把已跑通的链路推倒。」

排查账单请用 `08-ops-sql.md` §6.2c 的 SQL，别去 `billing` 表里找（永远 0 行）。

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

### 是否参与厂站能耗计算（`participateEnergyCalc`）

设备详情里那个「参与 / 不参与」下拉，表达的是
**「这台表的数据留着，但不进任何合计」**——转供、临时用电、
与厂内重复计量的备用表，都是典型场景。

| 项 | 值 |
| --- | --- |
| 属性名 | `participateEnergyCalc` |
| 存在哪 | `attribute_kv`，`attribute_type = 2`（SERVER_SCOPE） |
| 类型 | 布尔 |
| 默认 | **参与**（缺失 / 空串 / 认不出的值一律当参与） |
| 界面位置 | 设备详情 → 「是否参与厂站能耗计算」 |

**为什么默认是「参与」而不是「不参与」**：这个字段 2026-10-28 才加，
存量设备全都没有它。默认不参与，升级当天所有看板会变成一片 0 ——
那是把「没配上」当成了「客户明确不要」。判据统一在
`MeteringMath.participates()`，只认**显式为假**。

**表单里它是二选一显示的**：二级类型是「未知 / 普通表 / 并网表」才出现这个下拉；
「用户关口表」出现的是「额定容量」。见 `device-panel.component.html` 里
`showParticipate` / `showRatedCapacity` 的说明。

#### 改完之后为什么数字没变

场站 / 分项 / 区域 / 能耗概览读的是**资产上的 `energy_total`**，
不是设备遥测。这个值由 `AssetTotalsScheduler` 每小时重算一次
（`energy.asset-totals.refresh.enabled`，默认开，`matchIfMissing = true`）。

所以关掉一台表的「参与」，**要等下一次汇总**，看板合计才会少掉它。
不想等就手工触发：

```bash
curl -s --noproxy '*' -X POST -H "X-Authorization: Bearer $TOKEN" \
  http://127.0.0.1:8090/api/energy/asset-totals/rebuild
```

> 设备自己的遥测**一个点都不会删**。关掉「参与」只是不进汇总，
> 想看这台表的历史曲线，在查询设置里照样勾得到它。

#### 时区：全栈必须是北京时间（影响账单口径）

容器默认是 UTC，不设的话峰谷时段会**整体错位 8 小时** —— 尖/峰/平/谷
按 UTC 小时划分，账单金额直接算错。这不仅是显示问题。

`docker-compose.yml` 已给全部 7 个服务注入 `TZ: ${TZ:-Asia/Shanghai}`：

| 服务 | 为什么需要 |
| --- | --- |
| `energy-server` | 日志时间戳、峰谷时段划分、`energy_day` 日边界 |
| `postgres` | `now()` / `date_trunc('day')` 的「今天」 |
| `gateway` | nginx access log 时间戳 |
| `cassandra` / `install` / `ngxai-backend` / `allinone` | 保持一致，避免排查时心算时差 |

**`postgres` 光给 `TZ` 环境变量不够**（实测 2026-11-06）：
`TZ` 只在数据库集群**首次初始化**时写进 `postgresql.conf`，
已经有数据卷的机器重启多少次都不会变。所以 compose 里额外传了启动参数：

```yaml
command:
  - postgres
  - -c
  - timezone=${TZ:-Asia/Shanghai}   # 每次都生效
```

**验证（三条都要对）**：

```bash
# ① 容器时间
docker exec energy-server date        # 期望带 CST，且与宿主机 `date` 一致

# ② 数据库会话时区（最容易漏的一条）
docker exec energy-postgres psql -U postgres -d thingsboard -tAc \
  "SELECT now(), current_setting('TimeZone')"
# 期望：...+08 | Asia/Shanghai

# ③ 应用日志
docker logs energy-server 2>&1 | tail -3 | cut -c1-60
# 期望时间与宿主机一致
```

**换其他时区**：在 `~/energy-app/.env` 里加 `TZ=Asia/Tokyo`，
然后 `docker compose --profile split up -d`（`restart` 不会重读 environment，
必须 `up -d` 重建容器）。

#### 宿主机本身要不要改

**关键认识：容器时区与宿主机时区是两件独立的事。**
容器里的 `TZ` 是自己设的，不跟随宿主机 —— 所以即使宿主机是 UTC，
只要 compose 里写了 `TZ`，容器照样是北京时间。

但宿主机时区错了会让你**看日志时对不上时间**（容器说 23:50，宿主机说 15:50），
排查时极易误判。建议一并改对。

**macOS（你本机）**

```bash
# 查看（不用 sudo）
date                          # 期望尾部是 CST，且小时数与北京时间一致
ls -l /etc/localtime          # 期望 -> .../zoneinfo/Asia/Shanghai
```

典型正确输出：

```
2026年11月 6日 星期五 23时50分39秒 CST
/etc/localtime -> /var/db/timezone/zoneinfo/Asia/Shanghai
```

**已经是这样就不用改。** 如果不对（显示 UTC 或其他时区）：

```bash
sudo systemsetup -settimezone Asia/Shanghai
# 若提示 “You need administrator access”，前面必须加 sudo
```

图形界面等效操作：系统设置 → 通用 → 日期与时间 → 时区。

**Linux 服务器（部署机）**

```bash
date
timedatectl status | grep -E "Time zone|Local time"
```

不对就改：

```bash
sudo timedatectl set-timezone Asia/Shanghai
# 没 systemd 的老系统：
sudo ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
```

> **NTP 也是必要条件**：时区对了但系统时间漂移，遥测的 `ts` 会写错，
> 表现为曲线错位或抄表差分算出奇怪值。确认一下：
>
> ```bash
> timedatectl status | grep -i "synchronized"   # Linux，期望 yes
> ```
>
> macOS 默认开自动对时，一般不用管。

> **存量数据不受影响**：遥测的 `ts` 是 epoch 毫秒（绝对时间），
> 改时区不会让已有的点搬家。变的只是「日期/小时边界」怎么切。
> 但已生成的**账单**是按旧口径算的 —— 改时区后建议对受影响月份重算一次。

#### 分组维度的四个树根（用能分项 / 用能区域 / 空间位置 / 能耗类型）

「查询维度 → 按分组维度」下拉里的选项来自**四个资产库**，靠 `asset.type` 区分：

| 资产 type | 界面上叫 | 子节点 |
| --- | --- | --- |
| `energy_item_library` | 用能分项 | 场站分组 → 分项（照明 / 插座 / 空调…） |
| `energy_area_library` | 用能区域 | 场站分组 → 区域（办公区 / 公共区域…） |
| `energy_space_library` | 空间位置 | 场站分组 → 楼栋 / 楼层 |
| `energy_usage_library` | 能耗类型 | 场站分组 → 能耗类型 |

**它们下面都隔着一层「场站分组」**（`type = '场站分组'`）。
那是内部隔离层 —— 同一维度里两个场站可能有同名分项，必须分组隔开。
界面上会**自动穿透这层**，直接用当前右上角场站的那个分组，客户看不到它。

**排查「按分组维度下拉是空的 / 只剩品种根」**

部件解析维度根的优先级：
1. 看板数据源「按分组维度」引用的实体别名（`entityList` / `singleEntity` / `entityType`）
2. 解析出的 id 在库里**不存在**（换客户、重建演示数据、设计稿占位 id）→ 一个根都没有
3. 兜底：按 `asset.type` 从本租户资产里找上面那四个库

2026-11-06 实测：基础报表的别名里配的是
`00000000-0000-0000-0000-00000000d101 ~ d104` 四个**占位 id**，库里从来没有过
→ 维度下拉只剩「电能」，树是一个空节点。加了第 3 步兜底后
正确出现「用能分项 / 用能区域 / 空间位置 / 能耗类型」。

```sql
-- 本租户有哪些维度库（兜底逻辑认的就是这四类）
SET TIME ZONE 'Asia/Shanghai';
SELECT id, name, label, type
FROM asset
WHERE type IN ('energy_item_library','energy_area_library',
               'energy_space_library','energy_usage_library')
ORDER BY type;
```

**默认选中项**：第一次切到「按分组维度」→ **用能分项**（最常用）；
之后切能源品种 → 跟到该品种的根（水表/燃气没有分项树，跟着品种走才不会空白）。

#### 哪些看板显示「查询维度」

部件设置项 `showDimension`：

| 值 | 行为 | 哪些看板 |
| --- | --- | --- |
| `true` | 出现「按设备层级 / 按分组维度」分段按钮 | **基础报表** |
| `false` | 不出现入口，控制器里锁死「按设备层级」 | 我的账单 / 峰谷分析 / 实时能耗 / 历史能耗 / 手工填报 / 抄表功能 / 参数报表 |

只有一种维度可选时（数据源里没配维度根），即使 `true` 也不显示 —— 一个选项的分段按钮没有意义。

> 2026-10-29 曾把所有看板统一锁死成「按设备层级」；
> 2026-11-06 客户要求基础报表恢复，改成**按看板设置**决定。

#### 各处的判断口径（2026-11-06 全仓排查，逐处实测）

| 位置 | 判断 | 怎么判 |
| --- | --- | --- |
| 设备档案表单 | 写入 | `participateEnergyCalc`（布尔） |
| 资产预汇总 `rebuildAssetTotals` | **是** | 显式 false → 不进任何合计 |
| 峰谷分析 `EnergyAnalysisController` | **是** | 工作线程内判，排除并计入 `excludedMeters` |
| 表计清单 `EnergyMeterReadingController` | **是**（下发） | 返回 `participate` 字段给前端 |
| 部件 `power_load`（功率因数与负荷需量） | **是** | 过滤 `participate === false`，不进负荷统计 |
| 部件 `tou_summary`（峰谷平统计） | **是** | 不进峰谷合计 |
| 部件 `ranking_list`（排名） | **是** | 从排名里剔除 |
| 查询设置的设备树 | **只对虚拟表** | `settings.participatingVirtual` 打开时，虚拟表按它过滤；**实时设备不过滤** |
| 分析条件部件 `analysis_bar` | 不适用 | 它只下发时间窗 / 指标，不筛设备 —— 设备范围由查询设置负责 |
| 能耗概览（`overview_stats` / `calendar_heatmap`） | **间接** | 读资产 `energy_total`，而预汇总已排除 |
| 分项 / 区域图表（`asset_stats_chart` / `distribution_chart`） | **间接** | 同上，读资产树 + 预汇总 |
| **用能账单出账** | **是**（2026-11-06 新增） | 显式 false → 跳过，原因写进 `items[].reason` |
| **空闲能耗 `IdleEnergyService`** | **否**（已知缺口） | 按场站取设备，不判这个开关 |
| **负荷预测 `EnergyForecastController`** | **否**（已知缺口） | 按设备 id 直读遥测 |

**两条要记住的**：

1. **查询设置的树不过滤实时设备**。客户在树里仍能看到并勾选
   「不参与」的表，勾了之后右侧图表会出数（那是这台表自己的数据），
   但合计/账单里不会有它 —— **这是设计，不是 bug**：
   客户要能查这台表的历史，只是不参与汇总。
2. 上面标「已知缺口」的两处**尚未接这个开关**。如果要让空闲能耗 /
   负荷预测也遵守它，得改后端（当前口径是「按场站 / 按设备 id 全取」）。
   改之前，客户在设备档案里关掉「参与」，这两块**不会跟着变**。
   **2026-11-06 客户明确决定：维持现状，不接。** 别再当成待办去做 ——
   空闲能耗要算「一台设备闲下来的待机功率」，负荷预测要算「这台设备会不会过载」，
   两者都是**设备级**分析，不是「场站用能合计」；把不参与合计的表剔掉，
   反而会让这两张图少掉真实的设备。口径不同，不该硬套同一个开关。

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
