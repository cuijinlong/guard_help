# 看懂分析页

> 每个页面在算什么、怎么读、什么时候不能信。
> 按「先看什么 → 再看什么」的顺序组织，不用按菜单顺序读。

## 先看右上角的场站

下面每一页讲的都是「某个场站」的数据。进页面先确认**右上角**选的场站是你想看的那个 ——
换场站后整页（图表、表格、告警）一起变，不需要在各页重新选一次。

场站选择是全局的：在设备管理里切到「三相场站」，再点进能耗概览，看到的也是三相场站。
唯一例外是「组织与场站」页 —— 它管整棵树，不按场站过滤。

> 没有「全部场站」这一档。跨场站求和没有业务意义，必须落到具体场站。

## 阅读顺序建议

```
① 能耗概览        ← 每天第一眼，看整体有没有异常
② 分项 / 区域      ← 钱花在哪
③ 峰谷 / 电能质量   ← 用得好不好
④ 节能记录 / 盘查   ← 能省多少
⑤ 参数报表 / 账单   ← 出正式数据
```

---

## 这一页的数据是怎么汇聚来的（先读这段）

每一个图表背后都是同一套路：

```
① 设备上报 / RTU
      ↓  规则链「电表Key标准化」把 U/I/P/Ep 翻成标准名
② ts_kv  ← 设备遥测（energy / energy_reading / power_total / voltage_a …）
      ↓  按设备 sum(energy)，或按相邻表底求差 × 倍率
③ 汇总到资产  ← 看板「选场站 / 选分项」读的是资产上的 energy_total
      ↓  energy_total = 该资产子树内「最上层表计」的 energy 之和
④ 页面图表
      ↓  按天/小时分桶，SUM 聚合
⑤ 你看到的数字
```

**三个必须记住的对应关系**：

| 你选的是 | 页面读的实体 | 读的键 | 等价 SQL 的关键条件 |
| --- | --- | --- | --- |
| 一台设备 | `DEVICE` | `energy`（小时增量） | `entity_id = 设备id AND key='energy'` |
| 一个场站 / 分项 | `ASSET` | `energy_total`（汇总） | `entity_id = 资产id AND key='energy_total'` |
| 品种（电能/水…） | `ASSET`（品种节点） | `energy_total` | 同上，但目标资产是品种节点 |

> **选设备能用 `energy`，选场站必须用 `energy_total`。**
> 这两个键不能互换 —— 场站本身不上报遥测，`energy_total` 是由平台按
> 「最上层表计」汇总写进去的。看板上「选场站后是空的」几乎都是这个原因。

#### ⚠ 自己新建场站/设备后，要点一次「重算汇总」

平台的汇总不是实时的（设备每次上报不会自动改写资产）。你**自建**完场站、分项、
设备之后，要让看板按场站维度看到数，必须重算一次：

```bash
curl --noproxy '*' -s -X POST \
  -H "X-Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"days":60}' \
  http://127.0.0.1:8090/api/energy/asset-totals/rebuild
```

客户账号只能重算自己名下的资产；返回 `assetsWritten` 是写入的资产数。
`days` 是回溯天数（默认 60，够看本月 + 上月）。

也可以让运营在「客户列表」点 **初始化演示数据**（会顺带重算），
或在「平台自检 → 一键修复初始化」里重算全租户。

**怎么自己核对 SQL**：点一下页面，然后

```bash
docker logs energy-server 2>&1 | grep -A40 "SQL 埋点"
```

日志里会打印这一页用到的等价 SQL（参数已代入），复制到 psql 就能和页面数字逐项对。
覆盖峰谷分析、抄表台账、我的账单、出账、设备计量配置五处。

---

### 实测：SQL 与页面数字对得上吗

对得上。以下是 2026-10-23 在演示库（客户「星河工业园」）的实测快照：

> **数字只作示意**：重新初始化演示数据、或跨天后重算汇总，这些值都会变
> （表底累计在增长）。要核对当天的数，用各页下方「SQL 怎么查」自己跑一遍 ——
> 方法不变，数字以库里为准。

| 页面 / 卡片 | 页面显示 | SQL 结果 | 一致 |
| --- | --- | --- | --- |
| 能耗概览 · 单相园区本月电量 | `1177.28` kWh | `1177.28` | ✓ |
| 能耗概览 · 单相园区今年电量 | `2697.28` kWh | `2697.28` | ✓ |
| 能耗概览 · 单相园区近 30 天 | `1517.77` kWh | `1517.77` | ✓ |
| 能耗概览 · 三相园区近 30 天 | `64872.35` kWh | `64872.35` | ✓ |
| 能耗概览 · 组织（两场站合计） | `66390.12` kWh | `66390.12`（= 1517.77 + 64872.35） | ✓ |
| 分项能耗 · 单相园照明 | `779.39` kWh | `779.39` | ✓ |
| 峰谷分析 · 单相园进线 7 天 | `763.07` kWh | 各档相加 `0 + 249.79 + 295.52 + 109.82 + 107.94 = 763.07` | ✓ |
| 我的账单 · 应付合计 | `125463.82` 元 | 四费之和逐张核对，19 张全部相等 | ✓ |
| 抄表台账 · 电力合计 | `66330.04` kWh | 账期首末表底差 × 倍率 | ✓ |

对应的 SQL 见下面各页的「SQL 怎么查」。

---

## 第一组：总览类

### 能耗概览

**算什么**

| 卡片 | 口径 |
| --- | --- |
| 本月用电量 | 本月 1 日 0 点至今，所有设备 `energy` 之和 |
| 本月电费 | 电量 × 分时电价，按峰谷时段分别计算后求和 |
| 同比 | 与去年同月同期对比 |
| 环比 | 与上月同期对比 |

下方三张图：24 小时负荷曲线、分项占比饼图、区域排名柱状图。

**怎么读**

- 负荷曲线应该和生产节律吻合。连续几天曲线走平 → 可能有表计停了
- 分项占比里如果某一项超过 60%，先确认它是真的还是分项没配全
- 区域排名看第一名是否合理，异常高通常是漏了分表

**什么时候不能信**

- 本月还没过完时，同比/环比是与上月**同期**比，不是与上月全月比
- 电价配置不完整时，电费只算了已配置的时段，会偏低
- 设备刚接入的前几天，历史不足，同比无意义

---

### 实时能耗

**算什么**：当前功率（`power_total`）+ 今日电量 + 今日最大需量 + 契约需量占比，
下方是**滚动曲线**（示波器式：横轴按真实时间前进，曲线向左移出）。

**怎么读**：这是唯一「此刻」的页面。看曲线是否在动 —— 不动说明采集断了。
**横轴和有没有新数据无关**：没有新点时轴照样走，右侧留白，曲线停在最后一个点。

**窗口多久、怎么改**：趋势部件右上角有下拉，`1 / 2 / 5 / 15 / 30 / 60 / 120 分钟`，
默认 120 分钟。选完记在本机浏览器里，下次打开还是这个值。

> 报表类页面（历史能耗 / 基础报表 / 峰谷分析…）的时间在左侧「查询设置」里选，
> 有「实时 / 历史」两个页签。实时选 `最近 N 分钟`，跨度会同时决定统计的桶宽 ——
> 选 5 分钟是每 8 秒一个点，选 60 分钟是每 90 秒一个点，表格列数也跟着变。

- 想看清「每秒都在动」→ 选 1~2 分钟（每秒推进约 1% 宽度，肉眼明显）
- 想看趋势形状 → 30~120 分钟
- 选太短 + 设备上报间隔长（例如 15 分钟）→ 窗口里可能一个点都没有，右侧全白，这是数据节奏，不是故障

**为什么没有顶部的红色加载条**：那条进度条绑的是全局请求状态，实时页每 3 秒主动拉一次遥测，
红条会跟着闪，看起来像一直在加载。这个看板在 `configuration.settings` 里设了
`suppressLoadingBar: true` —— **只对实时类看板生效**，其它看板行为不变。

**曲线多久出现一个新折点**：取决于设备上报周期（RTU 默认 5 秒）。横轴是每秒前进的，
但折点是每个上报周期才新增一个 —— 这是真实数据节奏，不是卡顿。
要让折点也每秒前进，改 `rtu/main.py` 的 `REPORT_INTERVAL_SECS = 1`
（并同步把看板趋势部件的 `rawSecs` 改成 `1`），代价是规则链与写库压力约 5 倍。

**数据不新鲜时会怎样**：当前功率那格会显示读数，但脚注标明「最后更新 10-24 04:00（非实时）」。
平台不会把最后一次读数伪装成实时值。

**数据滞后时轴照样走**：标题旁会写「数据滞后 2 小时 13 分（最后一点 07:00:00）」——
轴在走、线在左侧、文字说明原因，三者一致。设备恢复上报后，新点会从右侧接进来。

> **演示数据为什么常看到「滞后」**：演示包是初始化时生成的逐小时快照，
> 之后不再增长。所以几小时后打开实时页，窗口里自然没有新点 ——
> 这句「数据滞后」就是给你解释这件事的，不是故障提示。
> 接入真实设备并持续上报后不会出现。

**窗口会不会自己变**：不会。你选多少就是多少，只有你改下拉或改部件设置才变。

**什么时候不能信**：RTU 上报周期如果是 15 分钟，这页看起来会「跳变」，不是故障。

---

### 历史能耗

**算什么**：按日/月/年聚合的用能总量，可对比多个场站或设备。

**怎么读**

- 看趋势：整体是升是降
- 看台阶：某天突然跳一个台阶，通常是新增设备或表计更换
- 看周期：周末明显低于工作日说明生产型；如果周末不降，查是否有人加班或设备空转

**什么时候不能信**

- 跨月对比要按自然月，不要按 30 天
- 表计更换当天数据会缺失或跳变，属正常

---

## 第二组：结构类（钱花在哪）

### 分项能耗

**算什么**：按「用能分项」维度汇总。动力、照明、空调各占多少。

**怎么读**：占比 + 环比。某一项环比涨了 20% 以上，值得追。

**口径按当前「能源品种」过滤**：电能视图只列电类分项（照明、插座、空调、动力…）；
给排水、炊事、蒸汽、锅炉属水 / 气 / 汽品种，把上方品种切过去才会出现。
所以「电能」下看到 4~5 项是正常的，不是分项丢了。

**手工填报表不进自动统计**：演示数据里「空调分项」挂的是虚拟表（用来演示手工填报），
它没有自动采集点，分项能耗页因此少这一条线。到「手工填报」页补录当月用量后，
账单和台账会算进去，自动采集口径仍不包含它。

**什么时候不能信**

- 设备没配分项 → 这部分计入「未分类」，占比会虚高
- 分项没双挂品种 → 该项显示 0（见[核心概念](/user/concepts) 铁律③）

### 区域能耗

**算什么**：按「用能区域」维度汇总。生产区、办公区、仓储区各占多少。

**怎么读**：看单位面积能耗（kWh/m²）比看总量更有意义 —— 大车间总量自然高。

**什么时候不能信**：区域是手工划的，划得粗就看不出问题。建议按实际功能分区，不要一个「全厂」了事。

**新建区域后要点一次「重算汇总」**：区域页读的是资产上的 `energy_total`，
平台不会在设备上报时自动往上汇总。改完区域归属，到设备运维 → 重算汇总（或等每小时一次的定时任务）。

### 综合能耗

**算什么**：把电、水、燃气、蒸汽按折标系数换算成**吨标准煤**，汇总成一个数。

| 品种 | 折标系数（参考） |
| --- | --- |
| 电 | 0.1229 kgce/kWh（等价值） |
| 水 | 0.0857 kgce/m³ |
| 燃气 | 1.33 kgce/m³ |
| 蒸汽 | 0.09 kgce/kg |

**怎么读**：这是对外报口径用的（政府报表、集团考核），内部管理还是看分品种。

**什么时候不能信**：折标系数各地各行业不同，平台用的是通用值。正式上报前要按当地要求核对。

### 能源流向（桑基图）

**算什么**：能源从进线 → 各分项 → 各设备的流向与损耗。

**怎么读**

- 线条越粗流量越大
- **末端有缺口 = 有回路没装表**，这个缺口就是「不明损耗」
- 正常情况下缺口应该小于 10%，超过说明计量不全

**什么时候不能信**：层级（level）没配好时，流向图会乱。总表必须是 1，分表是 2，支路是 3。

---

## 第三组：质量类（用得好不好）

### 峰谷分析

**算什么**：把用电量按分时电价时段拆开，算各时段占比与电费。

| 时段 | 时间（春秋季工作日示例） |
| --- | --- |
| 尖 | （部分地区无尖峰） |
| 峰 | 11–13、17–22 |
| 平 | 8–11、13–17 |
| 谷 | 6–8、22–24 |
| 深谷 | 0–6 |

**怎么读**：峰段占比越高，电费越贵。理想结构是深谷多做、峰段少做。

**默认范围**：查询面板默认「今天往前 7 天」（按日分桶）。单日只有 24 个点，
设备当天还没上报时整页会是空的；看趋势用 7 天更稳。要单日就在「时间范围」里改成同一天。

**顶部时间窗是相对的**：抄表功能=当天、参数报表=当天至今、历史能耗=本月、区域能耗=本年、
基础报表=本周至今。都是「相对当前时间」计算的，不会因为装得久了变成过去某一天。

**什么时候不能信**：电价方案按地区/季节不同，平台按租户配置的 `tou_scheme` 算。没配就用默认值，可能与你实际电费单不符。

### 电能质量

**算什么**：六项判据

| 指标 | 国标限值 | 超标意味着 |
| --- | --- | --- |
| 电压偏差 | ±7%（220V） | 供电距离过远或变压器容量不足 |
| 频率偏差 | ±0.2 Hz | 电网侧问题，一般不是内部原因 |
| 三相电压不平衡 | ≤ 2% | 单相负载分配不均 |
| 功率因数 | ≥ 0.9 | 低于 0.9 会被电业局罚款 |
| 电压 THD | ≤ 5% | 谐波源设备多（变频器、UPS） |
| 电流 THD | ≤ 15% | 同上 |

**怎么读**：功率因数低于 0.9 是最常见的罚款原因，加补偿电容即可。三相不平衡说明单相设备挂得不均，调一下相序。

**什么时候不能信**：只有三相表才有三相指标。单相表看这些是空的，属正常。

**改阈值（客户可自定义）**

上表是国标默认值。如果当地电业局要求不同，或现场负载本身就严重不平衡，可以按客户实际情况改：

1. 打开「电能质量」页面
2. 右上角 **⋮ → 编辑部件**
3. 找到六个输入框，直接改数字：

| 输入框 | 默认 | 说明 |
| --- | --- | --- |
| 功率因数下限 | 0.9 | 低于此值判不合格 |
| 三相不平衡度上限 % | 2 | |
| 电压 THD 上限 % | 5 | |
| 电流 THD 上限 % | 15 | 工程值，非国标直接限值 |
| 电压偏差允许 % | 7 | |
| 频率偏差允许 Hz | 0.2 | |

4. **留空或清空 = 恢复国标默认值**
5. 保存后立即生效，无需重启

改的是**这一个仪表板上的这一个部件**。多个仪表板各配一份，互不影响。

> 高级项：`高级：其他阈值 JSON` 可以覆盖上面没列出的阈值
> （如 `{"gapBadPct":15}` 控制总分表差额告警线）。

### 能耗洞察

**算什么**：自动找出异常点 —— 突增、突降、夜间空转、周末不降、同类设备差异大。

**怎么读**：按「影响金额」排序，先处理钱多的。

**什么时候不能信**：刚接入的前两周基线不稳，误报会多。

### 闲时能耗

**算什么**：非生产时段（夜间、周末、节假日）的用电量与占比。

**怎么读**：闲时占比超过 20% 通常说明有设备空转。逐台查是哪台。

**合计已经去重**：一个场站里，进线总表下还挂着分项表和回路表。页面顶部的
「周期总能耗 / 闲时能耗」只取**层级最小（1 级进线）的那几台**，下级表不再重复计入；
下方明细仍逐台列出，方便定位是哪台在空转。改过计量层级后等每小时一次的汇总，
或到设备运维点一次「重算汇总」。

**什么时候不能信**：班次制度不同的企业，闲时定义要改。默认是 22:00–6:00 + 周末。
周末和节假日整体计入闲时 —— 周六看到「闲时占比 100%」不是故障。

---

## 第四组：收益类（能省多少）

### 节能记录

**算什么**：每条节能措施记录「基准期用量」和「实施后用量」，算出节电量与节费。

```
节电量 = 基准期日均用量 × 实施后天数 − 实施后实际用量
节费   = 节电量 × 对应时段电价
```

**怎么读**：重点看「验证状态」列 —— 只有标记为「已验证」的才是实际测量结果，其余是估算。

**什么时候不能信**

- 基准期遇上停产、检修、极端天气，节电量会虚高
- 实施后不足一个完整周期（比如刚改完一周）就算，误差大
- 产量变化大的企业，应该按「单位产品能耗」算，不是按总量

### 盘查报告

**算什么**：六步准备度评估 —— 计量覆盖、数据完整、分项齐全、区域齐全、设备台账、节能记录。

**怎么读**：这是「体检报告」。准备度低的项就是下一步该补的。

**什么时候不能信**：准备度是规则算的，不代表数据一定准。它检查的是「有没有配」，不是「配得对不对」。

---

## 第五组：报表类（出正式数据）

### 参数报表

**算什么**：按设备 × 参数项展开的明细表。左侧选参数（用电量、相电压…），右侧按子项展开。

**怎么读**：这是最细的一页，适合导出给财务或做台账。

**什么时候不能信**：某个参数列全空 = 该点位没配。去「设备 → 最新遥测」确认。

### 基础报表

**算什么**：按场站/时间汇总的标准报表，可导出 Excel。

### 手工填报

**算什么**：没有自动采集的地方（比如人工抄的旧表），手工录入用量。

**怎么读**：填报的数据会与自动采集的数据合并统计。注意别重复 —— 同一块表既接了 RTU 又手工填，会算两遍。

### 设备计量配置（设备管理 → 点设备行）

**配什么**：计量层级（1 进线 / 2 分项 / 3 回路 / 不计入）、CT 变比、PT 变比、综合倍率、
「上报值是否已乘倍率」。

**为什么必须配**：

- **层级错** → 分层汇总会把总表和分表一起加，金额虚高 2~3 倍。平台按「上级表含下级」去重，
  只取集合里没有上级的那一层；层级全填成同一级就等于没去重。
- **倍率缺** → 平台读到的是寄存器整数（2283 而不是 228.3），报表数字差几十倍。
  CT 200/5 会自动算出有效倍率 40；CT/PT 都留空时用「综合倍率」。

保存后立即生效（报表下一次取数就按新配置）。演示客户的表计不需要配倍率 ——
它们的值已经是物理量。

### 抄表功能

**算什么**：按周期生成抄表任务，记录表底读数，自动计算区间用量。

**失败（数据陈旧）是什么意思**：这台表最近 10 分钟没有新上报。抄表只认此刻的读数，
平台不会拿几小时前的值冒充本次抄表结果。设备恢复上报后重抄即可。

**演示环境为什么总是这样**：演示遥测是一次性快照、不会持续增长，所以演示客户点抄表
必然显示「数据陈旧」。接入真实设备后正常。

### 我的账单

**算什么**：按电价方案生成的月度账单，含分时电费、基本电费、力调电费。

**打开即自动出数**：页面进入后自动按「当月」提交一次查询，不用先点「查询」。
（账单不是实时算的，是出账动作落成的 `energy_bill` 资产；初始化末尾会自动跑一次当月出账。）

**两个口径并列看**：上方合计按「全部表计累加」，含上下级重复，用于分层分摊；
绿色提示条里的「实际用电 / 实际电费」是**站点级**（只算 1 级进线表），
才是园区真正用掉的电和对应的电费。两者不能互相替代。

**什么时候不能信**：电价方案没配全时，账单只是电量 × 单一电价，与实际电费单会有差异。

---

## 每个页面读的是哪个键、SQL 怎么查

下面按菜单顺序，一页一节。每节三件事：**读什么键**、**什么聚合**、**等价 SQL**。

统一约定：
- `<设备id>` 换成设备 uuid（页面 URL 或「设备管理」里能看到）
- `<场站id>` / `<分项id>` 换成资产 uuid
- 时间都是毫秒时间戳；`Asia/Shanghai` 不能省（按 UTC 切天会错 8 小时）

---

### 能耗概览

**读什么**：`energy_total`（场站/分项/品种资产）或 `energy`（设备）

**怎么汇聚**：

```
场站 energy_total = 该场站子树内「最上层表计」的 energy 之和
                    最上层 = meterLevel 最小（1 进线 > 2 分项 > 3 回路）
                    只算电（水/气/汽各写 water_total / gas_total / steam_total）
```

**SQL**（本月 / 今年 / 全部）：

```sql
SELECT
  round(sum(CASE WHEN ts >= (extract(epoch from date_trunc('month', now() AT TIME ZONE 'Asia/Shanghai') AT TIME ZONE 'Asia/Shanghai')*1000)::bigint
                 THEN coalesce(dbl_v, long_v) ELSE 0 END)::numeric, 2) AS 本月电量,
  round(sum(CASE WHEN ts >= (extract(epoch from date_trunc('year', now() AT TIME ZONE 'Asia/Shanghai') AT TIME ZONE 'Asia/Shanghai')*1000)::bigint
                 THEN coalesce(dbl_v, long_v) ELSE 0 END)::numeric, 2) AS 今年电量,
  round(sum(coalesce(dbl_v, long_v))::numeric, 2) AS 累计电量
FROM ts_kv
WHERE entity_id = '<场站id>'
  AND key = (SELECT key_id FROM key_dictionary WHERE key = 'energy_total');
```

**实测**：单相园区本月 `1177.28`、今年 `2697.28`，与页面完全一致。

**口径提示**：

- 页面按天分桶后累加（`interval=86400000&agg=SUM`），结果与上面一次求和等价
- 组织卡 = 各场站之和（实测 `66390.12 = 1517.77 + 64872.35`）
- 「本月」是**自然月至今**，不与上月全月比

---

### 实时能耗

**读什么**：`power_total`、`voltage_a`、`current_a`、`power_factor_total`

**怎么汇聚**：取**最新一个点**，不做区间聚合（看板 `hideAggregation=true`）

```sql
SELECT kd.key AS 指标,
       to_char(to_timestamp(max(t.ts)/1000) AT TIME ZONE 'Asia/Shanghai','MM-DD HH24:MI:SS') AS 最新时间,
       (array_agg(coalesce(t.dbl_v, t.long_v) ORDER BY t.ts DESC))[1] AS 当前值
FROM ts_kv t
JOIN key_dictionary kd ON kd.key_id = t.key
WHERE t.entity_id = '<设备id>'
  AND kd.key IN ('power_total','voltage_a','current_a','power_factor_total')
  AND t.ts > (extract(epoch from now()) - 7200) * 1000
GROUP BY kd.key
ORDER BY kd.key;
```

**口径提示**：这是「此刻」，不是区间累加。曲线不跳说明采集断了（或 RTU 上报周期长）。

---

### 历史能耗

**读什么**：`energy`（设备）/ `energy_total`（资产）

**怎么汇聚**：按查询面板选的粒度分桶（小时 / 日 / 月），`SUM`

```sql
-- 按日看某设备一个月的电量
SELECT to_char(to_timestamp(t.ts/1000) AT TIME ZONE 'Asia/Shanghai','YYYY-MM-DD') AS 日期,
       round(sum(coalesce(t.dbl_v, t.long_v))::numeric, 3) AS 电量
FROM ts_kv t
WHERE t.entity_id = '<设备id>'
  AND t.key = (SELECT key_id FROM key_dictionary WHERE key = 'energy')
  AND t.ts >= 1790784000000 AND t.ts < 1793462400000
GROUP BY 1 ORDER BY 1;
```

**口径提示**：区间上界用 `<`，不要 `<=` —— `energy[t]` 覆盖 `(t−1h, t]`，
含上界会把下一账期第一个小时算进来。

---

### 分项能耗

**读什么**：`energy_total`（分项资产）

**怎么汇聚**：分项资产 → 子树内最上层表计 → 求和

```sql
SELECT a.name AS 分项,
       round(sum(coalesce(t.dbl_v, t.long_v))::numeric, 2) AS 电量
FROM asset a
JOIN ts_kv t ON t.entity_id = a.id
WHERE a.type = '分项'
  AND a.customer_id = '<客户id>'
  AND t.key = (SELECT key_id FROM key_dictionary WHERE key = 'energy_total')
  AND t.ts >= 1790784000000 AND t.ts < 1793462400000
GROUP BY a.name ORDER BY 电量 DESC;
```

**实测**：单相园照明 `779.39`、插座 `701.47`，与页面一致。

**口径提示**：各分项相加 ≈ 进线（差额是线损 + 未装表）。若相加明显超过进线，
说明分项里混进了「总表 + 分表」（查 `meterLevel`）。

---

### 区域能耗

**读什么**：`energy_total`，按「用能区域 / 空间位置」分组的资产

**怎么汇聚**：与分项相同，只是分组维度换成区域树

```sql
-- 看某台设备挂在哪些区域/分项下（一台设备可同时属于位置与用途）
SELECT parent.name AS 上级资产, parent.type AS 类型
FROM relation r
JOIN asset parent ON parent.id = r.from_id
WHERE r.to_id = '<设备id>'
  AND r.to_type = 'DEVICE'
  AND r.relation_type = 'Contains';
```

**口径提示**：区域与分项是**两个正交维度**，同一度电会在两个页面上各出现一次 ——
这是设计，不是重复计算。核对总量时只看其中一个维度。

**维度容器没有 `Contains` 子资产**：区域节点靠 SERVER_SCOPE 的 `siteId` 指向场站，
汇总任务按这个属性收集设备。所以「重算汇总」必须覆盖到维度容器 ——
一键修复初始化（`POST /api/energy/repair-init`）会做，单独调
`/api/energy/asset-totals/rebuild` 也会做。

---

### 综合能耗 / 能源流向

**读什么**：`energy_total`（资产）、`energy`（设备）

**怎么汇聚**：组织 → 场站 → 分项 逐层汇总；桑基图按关系边连线

```sql
-- 组织 → 场站 → 电量（桑基图的数据源）
SELECT o.name AS 组织, s.name AS 场站,
       round(sum(coalesce(t.dbl_v, t.long_v))::numeric, 2) AS 电量
FROM asset o
JOIN relation r ON r.from_id = o.id AND r.relation_type = 'Contains'
JOIN asset s ON s.id = r.to_id AND s.type = '场站'
LEFT JOIN ts_kv t ON t.entity_id = s.id
  AND t.key = (SELECT key_id FROM key_dictionary WHERE key = 'energy_total')
  AND t.ts >= 1790784000000 AND t.ts < 1793462400000
WHERE o.type = '组织' AND o.customer_id = '<客户id>'
GROUP BY o.name, s.name ORDER BY 组织, 场站;
```

**口径提示**：桑基图的宽度就是该层电量；如果某条流明显细，通常是该分项没配表。

---

### 峰谷分析

**读什么**：`energy_reading`（累积表底），**不是** `energy`

**怎么汇聚**：

```
小时表底 = MAX(energy_reading) 按小时分桶
小时增量 = 相邻两个表底之差 × 倍率（负值跳过）
档位     = 按 tou_scheme 判定尖/峰/平/谷/深谷
```

```sql
WITH pts AS (
    SELECT (ts / 3600000) * 3600000 + 1800000 AS 桶中心,
           max(coalesce(dbl_v, long_v))       AS 表底
    FROM ts_kv
    WHERE entity_id = '<设备id>'
      AND key = (SELECT key_id FROM key_dictionary WHERE key = 'energy_reading')
      AND ts > 1790780400000 AND ts <= 1793462400000
    GROUP BY ts / 3600000
), diff AS (
    SELECT 桶中心, 表底,
           表底 - lag(表底) OVER (ORDER BY 桶中心) AS 增量
    FROM pts
)
SELECT round(sum(CASE WHEN 增量 >= 0 THEN 增量 ELSE 0 END)::numeric, 2) AS 区间电量,
       count(*) FILTER (WHERE 增量 < 0) AS 倒走段数
FROM diff;
```

**实测**：单相园进线 7 天，各档相加 `0 + 249.79 + 295.52 + 109.82 + 107.94 = 763.07`，
与页面 `763.07` 一致。

**口径提示**：

- **必须用表底差，不能用 `sum(energy)`**：`energy` 的桶边界会让首尾差 1 小时
- 桶中心是「整点 + 30 分」，SQL 里要还原
- 倒走段数 > 0 时，「首末差」会大于「正增量累加」，页面取后者
- 五档相加恒等于总量（页面据此自洽，可用上面 SQL 反验）

---

### 电能质量

**读什么**：`voltage_a/b/c`、`voltage_thd_a`、`current_thd_a`、`voltage_unbalance`、
`power_factor_total`、`frequency`

**怎么汇聚**：区间**均值**（`agg=AVG`），再与阈值比较

```sql
SELECT kd.key AS 指标,
       round(avg(coalesce(t.dbl_v, t.long_v))::numeric, 2) AS 区间均值,
       round(min(coalesce(t.dbl_v, t.long_v))::numeric, 2) AS 最小值,
       round(max(coalesce(t.dbl_v, t.long_v))::numeric, 2) AS 最大值,
       count(*) AS 点数
FROM ts_kv t
JOIN key_dictionary kd ON kd.key_id = t.key
WHERE t.entity_id = '<设备id>'
  AND kd.key IN ('voltage_a','voltage_b','voltage_c',
                 'voltage_thd_a','current_thd_a','voltage_unbalance',
                 'power_factor_total','frequency')
  AND t.ts >= 1790784000000 AND t.ts < 1793462400000
GROUP BY kd.key ORDER BY kd.key;
```

**口径提示**：这是「期间均值越限」，不是「逐点报警事件」。
要逐点事件看「告警中心」（计算字段产生 `entity_alarm`）。

---

### 闲时能耗

**读什么**：`idle_energy`、`idle_avg_power`、`idle_delta_count`、`idle_exceed`

**怎么汇聚**：按场站配置的「工作时段 + 待机功率阈值」逐小时判定，日粒度落库

```sql
SELECT to_char(to_timestamp(t.ts/1000) AT TIME ZONE 'Asia/Shanghai','YYYY-MM-DD') AS 日期,
       max(CASE WHEN kd.key='idle_energy'    THEN coalesce(t.dbl_v,t.long_v) END) AS 闲时电量,
       max(CASE WHEN kd.key='idle_avg_power' THEN coalesce(t.dbl_v,t.long_v) END) AS 闲时平均功率,
       max(CASE WHEN kd.key='idle_exceed'    THEN coalesce(t.dbl_v,t.long_v) END) AS 是否超标
FROM ts_kv t JOIN key_dictionary kd ON kd.key_id = t.key
WHERE t.entity_id = '<设备id>'
  AND kd.key LIKE 'idle_%'
  AND t.ts > (extract(epoch from now()) - 30*86400) * 1000
GROUP BY 1 ORDER BY 1 DESC;
```

**口径提示**：`idle_exceed` 是**日粒度标记**，由设备档案的计算字段消费并产生告警。
不要拿它当小时值。合计口径按「上级表含下级」去重，与账单一致。

---

### 节能记录 / 盘查报告

**读什么**：`energy`（基线对比）、`saving_records` 类资产属性

**怎么汇聚**：拿「改造前后同期电量」对比，差额 × 电价 = 节省金额

```sql
-- 同一台设备两个时间段的电量对比（节能量的原始数据）
SELECT '改造前' AS 期间,
       round(sum(coalesce(dbl_v, long_v))::numeric, 2) AS 电量
FROM ts_kv
WHERE entity_id = '<设备id>'
  AND key = (SELECT key_id FROM key_dictionary WHERE key = 'energy')
  AND ts >= 1788192000000 AND ts < 1790784000000
UNION ALL
SELECT '改造后',
       round(sum(coalesce(dbl_v, long_v))::numeric, 2)
FROM ts_kv
WHERE entity_id = '<设备id>'
  AND key = (SELECT key_id FROM key_dictionary WHERE key = 'energy')
  AND ts >= 1790784000000 AND ts < 1793462400000;
```

**口径提示**：节能量是**估算**，前提是「两个期间生产工况可比」。
工况变了（产量、季节、班次）结论就不成立 —— 页面上会标注这个前提。

---

### 参数报表

**读什么**：能源参数字典（`asset.type='default'`），不是遥测

```sql
-- 电能品种的指标清单（报表列头就是它）
SELECT child.name AS 指标名,
       (SELECT ak.str_v FROM attribute_kv ak JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
         WHERE ak.entity_id = child.id AND kd.key = 'key') AS 遥测键,
       (SELECT ak.str_v FROM attribute_kv ak JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
         WHERE ak.entity_id = child.id AND kd.key = 'unit') AS 单位
FROM asset parent
JOIN relation r ON r.from_id = parent.id
JOIN asset child ON child.id = r.to_id
WHERE parent.name LIKE '%电能%' AND parent.type = 'default'
ORDER BY 指标名;
```

**口径提示**：设备上报了字典里没有的键 → 报表显示不出来。
用「设备接入」页的「上报了但字典里没有的键」自查。

---

### 基础报表 / 抄表功能

**读什么**：`meter_reading_record`（抄表记录表，不是遥测）

```sql
SELECT to_char(to_timestamp(reading_time/1000) AT TIME ZONE 'Asia/Shanghai','MM-DD HH24:MI') AS 抄表时间,
       device_name AS 设备, prev_reading AS 上期表底, curr_reading AS 本期表底,
       usage AS 本次增量, quality AS 质量, source AS 来源
FROM meter_reading_record
WHERE tenant_id = '<租户id>' AND period = '2026-10'
ORDER BY reading_time DESC LIMIT 50;
```

**口径提示**：台账的「用量」是**账期首末差**（累计），不是 `usage` 列（本次增量）。
详见 `05-troubleshoot.md` 现象 K。

---

### 手工填报

**读什么**：`energy` 的**月首 00:00** 单点（整月总量）

```sql
SELECT to_char(to_timestamp(t.ts/1000) AT TIME ZONE 'Asia/Shanghai','YYYY-MM') AS 月份,
       coalesce(t.dbl_v, t.long_v) AS 填报用量
FROM ts_kv t
WHERE t.entity_id = '<设备id>'
  AND t.key = (SELECT key_id FROM key_dictionary WHERE key = 'energy')
  AND extract(day from to_timestamp(t.ts/1000) AT TIME ZONE 'Asia/Shanghai') = 1
ORDER BY 月份;
```

**口径提示**：虚拟表**没有** `energy_reading`。出账时整月归「平」档并标 `touAssumedFlat=true`。

---

### 我的账单

**读什么**：`asset.type='energy_bill'` 的 SERVER_SCOPE 属性

```sql
SELECT a.name AS 账单号,
       max(CASE WHEN kd.key='deviceName' THEN ak.str_v END) AS 设备,
       max(CASE WHEN kd.key='energy'     THEN ak.str_v END) AS 品种,
       max(CASE WHEN kd.key='status'     THEN ak.str_v END) AS 状态,
       max(CASE WHEN kd.key='usage'      THEN coalesce(ak.dbl_v, ak.str_v::numeric) END) AS 用量,
       max(CASE WHEN kd.key='energyFee'  THEN coalesce(ak.dbl_v, ak.str_v::numeric) END) AS 电度费,
       max(CASE WHEN kd.key='basicFee'   THEN coalesce(ak.dbl_v, ak.str_v::numeric) END) AS 基本费,
       max(CASE WHEN kd.key='powerFactorFee' THEN coalesce(ak.dbl_v, ak.str_v::numeric) END) AS 力调费,
       max(CASE WHEN kd.key='surchargeFee' THEN coalesce(ak.dbl_v, ak.str_v::numeric) END) AS 附加费,
       max(CASE WHEN kd.key='amount'     THEN coalesce(ak.dbl_v, ak.str_v::numeric) END) AS 合计
FROM asset a
JOIN attribute_kv ak ON ak.entity_id = a.id AND ak.attribute_type = 2
JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
WHERE a.type = 'energy_bill' AND a.customer_id = '<客户id>'
  AND a.name LIKE 'BILL-%2026-10%'
GROUP BY a.id, a.name ORDER BY 设备;
```

**实测**：19 张账单，应付 `125463.82`、全表合计 `226196.78`，与页面一致；
每张「合计 = 四项之和」全部相符。

**口径提示**：

- 金额属性存在 `str_v`，不是 `dbl_v` —— 只读 `dbl_v` 会全是 NULL
- 基本电费/力调费只算进线总表（`meterLevel=1`）
- 应付 ≠ 全表合计：有进线时只汇总进线，避免总表含的分表被再加一遍

---

## 一页速查表

| 页面 | 一句话 | 最大的坑 |
| --- | --- | --- |
| 能耗概览 | 整体情况 | 电价没配全，电费偏低 |
| 实时能耗 | 此刻功率 | 上报周期长，看起来跳变 |
| 历史能耗 | 趋势对比 | 表计更换当天跳变 |
| 分项能耗 | 按用途拆 | 分项没双挂，显示 0 |
| 区域能耗 | 按位置拆 | 区域划得太粗 |
| 综合能耗 | 折标煤汇总 | 折标系数各地不同 |
| 能源流向 | 流向与损耗 | level 没配好，图会乱 |
| 峰谷分析 | 分时结构 | 电价方案与实际不符 |
| 电能质量 | 六项判据 | 单相表没有三相指标 |
| 能耗洞察 | 自动找异常 | 前两周误报多 |
| 闲时能耗 | 非生产时段 | 班次不同要改定义 |
| 节能记录 | 省了多少 | 基准期不具代表性 |
| 盘查报告 | 六步准备度 | 只查有没有配，不查对不对 |
| 参数报表 | 最细的明细 | 点位没配就全空 |
| 我的账单 | 月度费用 | 电价方案不完整 |

## 下一步

想接入自己的真实设备 → [换成自己的数据](/user/onboarding)
