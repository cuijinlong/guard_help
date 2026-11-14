# ⑤ 数据流

一条数据从表计到看板，中间发生了什么。**页面数字不对时，按这一页的顺序查。**

> 校验用的 SQL 在 [⑧ 运维 SQL](/admin/ops-sql)，这里只讲「应该怎么流」。

---

## 一、八步全景

```
① RTU / 网关 上报
   {"U":220.1,"I":15.2,"P":3.3,"Ep":33705.4}      厂家原始代号
        ↓  MQTT:1883 或 HTTP /api/v1/<token>/telemetry
② 规则链「电表Key标准化」
   U→voltage_a  I→current_a  P→power_total  Ep→energy_reading
   原始键名留在 metadata.rawKeys（可追溯）
        ↓
③ ts_kv 落库
   key = 数字 id（不是字符串！）  ts = 毫秒  dbl_v = 数值
        ↓
④ 计算字段（挂在档案上，同档案设备自动继承）
   energy_day / load_rate / voltage_unbalance / carbon …
        ↓
⑤ 资产汇总（**手工触发**，不再有定时任务）
   设备 energy → 资产 energy_total / energy_day / power_total
   ★ 平台**不会**在每次上报时自动往资产汇总
   ★ 2026-11-14 起也不再自动跑：AssetTotalsScheduler 已删除（空转）
        ↓
⑥ 部件取数
   读资产 energy_total（不是设备 energy）
        ↓
⑦ 换算与分级（倍率、折标煤、费用、碳排）
        ↓
⑧ 页面
```

**最常断的两处是 ⑤ 和 ⑥** —— 设备有数、页面是 0，九成在这两步。

---

## 二、三层键名：混用就查不到

```
设备层  DEVICE
  energy          本小时增量（kWh）      ← RTU 上报
  energy_reading  累积表底（单调递增）    ← RTU 上报
  energy_day      当日累计               ← 计算字段
        ↓  ⑤ 资产汇总（每小时）
资产层  ASSET（场站 / 分项 / 区域 / 组织）
  energy_total    该资产下所有表的本小时合计
  energy_day      当日累计
  power_total     合计功率（仅电）
  water_total / gas_total / steam_total / heat_total（按品种分开）
        ↓  不汇总，也不采集
品种层  ASSET（电能 / 水表 / 燃气 / 蒸汽 / 热力）
  只有 paramDict 属性（指标名、单位）
  ★ 没有任何遥测 —— 它是维度节点，不是计量点
```

**一句话**：设备读 `energy`，资产读 `energy_total`，品种什么都不读。

### 资产键按品种分开（不是所有品种都写 energy_total）

`writeAssetTotal` 落键规则：

| 品种 | 落哪个键 |
| --- | --- |
| 电 | `energy_total` |
| 水 | `water_total` |
| 燃气 | `gas_total` |
| 蒸汽 | `steam_total` |
| 热力 | `heat_total` |

所以「分项能耗」选**电能**时，燃气/水/汽/热分项是空的 —— **这是正确行为**，
不是没数据。切到对应品种才出数。

> **曾经漏了 `heat` 分支**：热力（GJ）被写进 `energy_total`（kWh），
> 于是「锅炉 312 kW·h」——单位混算。2026-11-02 已修。

---

## 三、资产汇总：为什么会是 0

### 3.1 谁写、何时写

```
POST /api/energy/asset-totals/rebuild   （手工触发，无定时任务）
  ↓
rebuildAssetTotals(tenantId, customerId, backfillDays)
  ↓ 按「设备 → 场站 / 分项 / 区域 / 组织 / 维度容器」分组
  ↓ 组内同品种只取「拓扑根」（集合内没有父表的表）→ 避免总表+分表重复计电
  ↓ 按 ts 覆盖写各品种的 *_total / energy_day / power_total
```

> **⚠ 2026-11-14 删除了 `AssetTotalsScheduler`（原每小时自动重算）。**
>
> 它看着在干活、实际上空转：汇总按设备遥测的 `ts` 逐点算，
> 源头没有新点时它一个新点也不写，但日志照样打印
> `资产汇总刷新完成：N 个资产，耗时 X ms`。
> 实测连跑多轮，`ts_kv_latest.energy_total` 一直停在 30 小时前 ——
> **比没有这个任务更糟**，因为它让人以为汇总链路是通的。
>
> 现在只有三个触发点，都需要显式调用：
> 演示数据初始化 / `repair-init` / 上面的手工接口。
>
> **判断汇总是否真的更新了，看 `ts_kv_latest` 的时间戳，不要看日志。**

**为什么用定时任务而不是规则链**：规则链逐条消息触发，一台表一小时一个点，
一次汇总要读该场站下**全部**表的历史。逐条触发等于每点全量重算，
代价随表数平方增长。批处理按小时算一次，与表数线性相关。

**手工触发**（客户 token 即可，只影响自己）：

```bash
curl -s -X POST -H "X-Authorization: Bearer $TOKEN" \
  'http://127.0.0.1:8090/api/energy/asset-totals/rebuild' \
  -H 'Content-Type: application/json' -d '{"days":2}'
# → {"assetsWritten": 26}
```

**什么时候必须手工触发**：

| 场景 | 为什么 |
| --- | --- |
| 刚建完场站/分项/设备 | 等不到下一个整点，客户马上要看 |
| 改了设备的 `meterLevel` | 取根规则变了，旧汇总还是按旧层级算的 |
| 改了关系（挂到别的场站） | 旧汇总留在旧节点上 |
| 清了演示数据 | 空节点必须清掉旧值，否则显示上一次的数 |
| 改了品种判定 | 同一批数据要从 `energy_total` 搬到 `gas_total` |

### 3.2 窗口为什么必须对齐整天

`rebuildAssetTotals` 的起点是「今天 00:00 往前推 N−1 天」，不是「现在往前推 N 天」。

因为 `energy_day` 是**当日累计**，从窗口第一个点开始加。窗口若从某天中途开始，
那天的 `energy_day` 会少算前半段 —— 表现为「某天数据莫名偏低」。

### 3.3 空节点也要写（否则整页空白）

`用电分项 / 用能区域 / 用能性质 / 空间位置` 四个维度下，每个场站有一个
「场站分组」节点。它没有 `Contains` 关系，靠 `SERVER_SCOPE` 的 `siteId`
指向场站（与设备同一口径）。

**不写这些节点，区域能耗 / 综合能耗 / 能源流向三页就是整页空白** ——
而同一页的排名部件走设备级数据照样有数，看起来像「图表坏了」。

反过来，**节点变空时要清掉旧汇总**（`clearAssetTotals`），
否则会一直显示错误的历史值，且与新区数据加起来超过场站总量。

### 3.4 部件怎么选取数实体

三个部件（`overview_stats` / `calendar_heatmap` / `asset_stats_chart`）
用同一套优先级：

```
① state.treeNode（用户在分析范围树里点选）
② state.entityId（状态实体）
③ 部件数据源别名
```

**品种资产只用来提供指标名和单位，绝不能当取数目标**：

1. 它没有遥测 → 查 `energy_total` 返回空 → 页面 0
2. 它的 `Contains` 子节点**横跨同租户下所有客户** → 遍历会读到别家的分项

> 历史版本把品种放在优先级第一，于是「接口 200 + 空对象 + 页面 0」。

---

## 四、计量层级：总表与分表

### 4.1 平台怎么表达

两个字段配合，**不是二选一**：

| 字段 | 位置 | 答什么 |
| --- | --- | --- |
| `meterLevel` | 设备 `SERVER_SCOPE` | `1`=进线总表 / `2`=分项或回路 / `0`=非计量 |
| `parentDeviceId` | 设备 `additionalInfo` | 同一条接线上「总表 → 分表」的物理父子 |

**取根规则**：资产汇总时，组内只取「集合里没有父表的表」（拓扑根），
不按 `meterLevel` 最小取。

原因：`meterLevel` 是人工填的，可能填错、可能同级；父子关系是建模时双写的
（`additionalInfo.parentDeviceId` + `DEVICE --Contains--> DEVICE`），更可靠。

### 4.2 配错的典型症状

| 症状 | 原因 |
| --- | --- |
| 场站总量恰好是分项之和的两倍 | 总表和分表都被当成根，重复计电 |
| 分项加起来小于场站总量 | 有分表没配 `parentDeviceId`，被当成了独立根 |
| 整个节点没有数 | `meterLevel = 0`（被当成非计量） |

判据见 [⑧ 运维 SQL](/admin/ops-sql#计量层级)。

---

## 五、倍率（CT × PT）

### 5.1 四个字段

| 字段 | 位置 | 含义 |
| --- | --- | --- |
| `ct` | 设备 `SERVER_SCOPE` | 电流互感器变比（如 100/5 → 20） |
| `pt` | 设备 `SERVER_SCOPE` | 电压互感器变比（低压通常 1） |
| `ratio` | 设备 `SERVER_SCOPE` | 综合倍率（可直接填，优先于 ct×pt） |
| `meterConstant` | 设备 `SERVER_SCOPE` | 表常数（脉冲表用） |

**计算**：`effectiveRatio = ratio`（若填了）`否则 ct × pt`，都为空则 1。

### 5.2 三种典型错误

| 错误 | 后果 |
| --- | --- |
| 表本身已乘过倍率，又填了倍率 | 数字放大 N 倍 |
| `ct` 填了「100/5」而不是「20」 | 解析失败 → 按 1 算 → 少算 20 倍 |
| 一个档案下的设备倍率各不相同，却只在档案上配 | 档案值是默认值，设备级会覆盖 |

**判据**：拿电费单和平台数字对。差整数倍 → 倍率错；差 ±5% → 抄表时段错。

---

## 六、表底 vs 增量

### 6.1 两个键，两个语义

| 键 | 语义 | 单调性 | 谁报 |
| --- | --- | --- | --- |
| `energy_reading` | 累积表底（表盘上的那个数） | 单调递增 | 几乎所有表 |
| `energy` | 本周期增量 | 每周期重新计 | 部分表（含国内多数多功能表） |

### 6.2 为什么两个都要存

- **`energy_reading`** 是唯一能对账的数（与电费单一致），也是表底差分的基础
- **`energy`** 直接可用，但**丢点就永久丢失**（表不会补发）

### 6.3 用量一律用「表底差」

```
用量 = energy_reading(本期) − energy_reading(上期)
```

**不要 `sum(energy)`**：漏一个点就少一段，且无法发现。表底差是自纠错的 ——
中间丢再多的点，只要首尾在，总量就对。

平台的实际做法（`MeteringMath.usageOfSegment`）：

```
优先 energy_reading 差分
  ↓ 没有表底
退回 energy 求和
  ↓ 都不行
记 abnormal，不猜
```

**注意**：真实仪表大多**只报表底不报增量**。汇总时如果只读 `energy`，
会得到 0 点 → 整个品种被跳过 → 场站 `energy_total` 恒为 0。
这就是后端 `diffReadingSeries` 存在的原因。

### 6.4 表底异常值

真实表在调试期会上报哨兵值（实测 DDSU666 报过 `7777.7` / `8888.8`，
正常是 8.37~8.47）。差分后会把分项顶到天文数字。

清理 SQL 见 [⑧ 运维 SQL · 哨兵读数](/admin/ops-sql#哨兵读数)。

---

## 七、厂家指标名不一样

### 7.1 真相源是字典

平台标准名（`voltage_a` / `energy_reading`…）定义在
「能源参数字典」的 `standardKeys` 里。RTU 上报的键必须能映射到它，
否则**存不进业务视图**（数据在 `ts_kv` 里，但看板读不到）。

### 7.2 转换在哪做

```
规则链「电表Key标准化」节点
  输入：厂家原始键  U / I / P / Ep
  输出：平台标准键  voltage_a / current_a / power_total / energy_reading
  原始键留在 metadata.rawKeys（可追溯）
```

**三处存放位置，别找错**：

| 找什么 | 在哪 |
| --- | --- |
| 平台标准键定义 | 字典 `standardKeys` |
| 设备的测点映射 | 设备 `SERVER_SCOPE.measurePoints`（数组） |
| 规则链映射 | 规则链节点的 `renameKeys` 配置 |

### 7.3 怎么发现映射没生效

判据：`ts_kv` 里有数据，但键名是**厂家代号**（如 `U`、`Ep`），
不是标准名。查：

```sql
SELECT kd.key, count(*) FROM ts_kv t
JOIN ts_kv_dictionary kd ON kd.key_id = t.key
WHERE t.entity_id = '<设备id>' GROUP BY 1 ORDER BY 2 DESC;
```

看到 `U` / `Ep` 这种短名 → 映射没生效，数据进不了业务视图。

---

## 八、八步各自的「断点症状」

| 断在哪 | 症状 | 查法 |
| --- | --- | --- |
| ① 设备没上报 | 设备详情「最新遥测」空 | 看 MQTT 连接、网关在线状态 |
| ② 映射没生效 | `ts_kv` 键名是厂家代号 | 上一节的 SQL |
| ③ 落库失败 | 上报成功但库里没有 | 看后端日志、`ts_kv` 分区 |
| ④ 计算字段没跑 | `energy_day` 空但 `energy` 有 | 看档案的计算字段配置 |
| ⑤ 汇总没写 | 设备有数、资产 `*_total` 空 | `POST /asset-totals/rebuild` 手工补 |
| ⑤ 汇总写错品种 | 分项显示 `energy_total` 但装的是水表 | 查档案 `energyTypeCode` |
| ⑥ 部件选错实体 | 接口 200、页面 0 | 看部件的数据源配置 |
| ⑦ 倍率错 | 数字差整数倍 | 与电费单对账 |
| ⑧ 缓存 | 改了没生效 | 硬刷新 `Cmd+Shift+R` |

**排障顺序就是 ①→⑧**，不要跳步。设备没上报就去查看板，永远查不出来。
