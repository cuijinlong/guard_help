# 客户菜单功能专区（架构 · 统计 SQL · AI 算法）

这一页是给**运维和客户对接人**用的：客户登录后左侧每一个菜单，点进去看到的数字
从哪来、存在哪张表、用什么 SQL 能自己核对一遍。

> **为什么不写在客户手册里**：客户只需要看数，不需要知道 `ts_kv` 长什么样。
> 但客户对账时一定会问「你这个 1588.31 是怎么算的」—— 这一页就是答案。

---

## 一、左侧菜单全貌（15 项）

```
客户登录（customer@…）
│
├─ 能耗概览            ← 落地页，登录即见（HomeMenuItem，指向「能耗概览」看板）
│
├─ 能耗查询
│   ├─ 实时能耗        看板：realtime_energy
│   ├─ 历史能耗        看板：history_energy
│   └─ 抄表功能        页面：/meter-reading（抄表台账 + 记录 + 现场补抄）
│
├─ 能耗分析
│   ├─ 峰谷分析        看板：energy_management_analysis_bar + /api/energy/tou-analysis
│   ├─ 分项能耗        看板：item_energy
│   ├─ 区域能耗        看板：area_energy
│   └─ 我的账单        看板：energy_management_billing_list + /api/energy/billing/*
│
├─ 综合报表
│   ├─ 基础报表        看板：basic_report
│   ├─ 手工填报        页面：手工填报（虚拟表月度录入）
│   └─ 参数报表        页面：/param-report（品种 × 指标字典）
│
├─ 能耗优化
│   ├─ 闲时能耗        页面 + /api/energy/idle-analysis
│   ├─ 负载预测  【AI】 /ngxapi/biz/forecast      Prophet
│   ├─ 用能建议  【AI】 /ngxapi/biz/advice        规则引擎（非机器学习）
│   └─ 用能质量  【AI】 /ngxapi/biz/quality       规则 + 统计（非机器学习）
│
├─ 告警中心            /alarm-center + /api/energy/alarms
│
├─ 设备管理
│   ├─ 设备运维        /device-management（设备列表 + 测点参数）
│   ├─ 设备分组        /device-group（分组树 + 设备归属）
│   └─ 设备拓扑        /device-topology + /api/energy/topologies
│
├─ 平台自检            /self-check + /api/energy/self-check
│
├─ 综合能耗            看板：energy_overview
├─ 能源流向            看板：energy_management_sankey_flow
├─ 电能质量            看板：energy_management_power_quality
├─ 盘查报告            看板：energy_management_audit_report
├─ 节能记录            看板：energy_management_saving_records
│
├─ 空调管理
│   ├─ 空调运行监控    看板：hvac_operation_monitor
│   ├─ 运行计划与配置  看板：hvac_plan_config
│   └─ 每日复盘报告    看板：hvac_daily_report
│
└─ 组织                /sites（组织 → 场站 → 设备 三级）
```

> **2026-10-26 改名**：原来一级叫「设备运维」，它下面第一项又叫「设备管理」——
> 两个词互为父子，客户点之前分不清哪个是哪个。
> 现在一级用上位概念「设备管理」，三个二级项用各自的动作：
> **设备运维**（看设备状态与测点）/ **设备分组**（给设备归类）/ **设备拓扑**（看接线）。
> URL 全部不变；「平台自检」升为一级（出问题时第一个该点的地方）。
> 存量客户重启不会自动变，走一次「平台自检 → 一键修复初始化」即可（幂等）。

**四种页面类型**，排查时先分清是哪一种：

| 类型 | 特征 | 数据从哪来 |
| --- | --- | --- |
| ThingsBoard 看板 | URL 里是 `/dashboards/<id>` | 部件直接查 `ts_kv`（前端发查询，后端只做聚合） |
| 自建页面 | 供应商自己的路由（`/meter-reading` 等） | 调 guard-server 的 `/api/energy/*` |
| AI 页面 | 走 `ngx-ai` 服务（18081/18801 端口） | Python 服务读同一份 `ts_kv` 或 tb_rest |
| 静态清单页 | `/self-check`、`/param-report` | 读字典/元数据，不算电量 |

---

## 二、数据存哪（先看这张，再看各功能）

### 2.1 遥测：`ts_kv` 一张表装全部

```text
表结构（分区表，按 ts 范围切分区）
entity_id  uuid     -- 设备/资产 id
key        integer  -- ★ 不是键名，是 key_dictionary.key_id
ts         bigint   -- 毫秒时间戳
bool_v / str_v / long_v / dbl_v / json_v   -- 五种存储列，按值的类型落其中一列
```

**第一个坑**：`ts_kv.key` 存的是**整数 id**，键名在 `key_dictionary`：

```sql
-- 读到键名必须联表
SELECT d.name AS 设备, kd.key AS 指标,
       to_char(to_timestamp(t.ts/1000) AT TIME ZONE 'Asia/Shanghai', 'MM-DD HH24:MI') AS 时间,
       coalesce(t.dbl_v, t.long_v) AS 值
FROM ts_kv t
JOIN key_dictionary kd ON kd.key_id = t.key
JOIN device d ON d.id = t.entity_id
WHERE d.name = '单相园-1#进线总表·星河工业园'
  AND kd.key = 'energy_reading'
ORDER BY t.ts DESC LIMIT 10;
```

**第二个坑**：同一个「数」可能落在不同列。金额类属性存 `str_v`，
计数类存 `dbl_v` —— 读数值一律写 `coalesce(dbl_v, str_v::numeric)`。

### 2.2 属性：`attribute_kv`（分三种作用域）

```text
attribute_type = 1  →  CLIENT_SCOPE（设备可读可写）
attribute_type = 2  →  SERVER_SCOPE（只有服务端，客户看不到）
attribute_type = 3  →  SHARED_SCOPE（设备可读）
```

平台自己的配置几乎都在 **SERVER_SCOPE（=2）**：倍率、计量层级、费率、账单字段。

### 2.3 自建表（不在 ThingsBoard 原生模型里）

| 表 | 存什么 | 谁写 |
| --- | --- | --- |
| `meter_reading_batch` | 每次抄表批次（谁触发、几台、状态） | 抄表任务 |
| `meter_reading_record` | 抄表明细，**按月分区**（`_2026_10`…） | 抄表任务 / 现场补抄 |
| `tb_sync_log` | 与外部系统同步的日志 | 同步任务 |
| `billing` / `billing_detail` | 建好了但**当前不使用**（账单实际存为资产） | — |

> 账单为什么不进 `billing` 表：现有两个消费方（台账金额、账单交叉表）
> 读的都是 `energy_bill` 资产的 SERVER_SCOPE 属性。换表等于把已跑通的链路推倒。

### 2.4 账单位置

```
asset.type = 'energy_bill'
  name = BILL-<客户码8位>-<账期>-<品种>-<表码>   ← 资产名就是账单号
  属性（SERVER_SCOPE）：amount / usage / energyFee / basicFee /
                        powerFactorFee / surchargeFee / meterLevel /
                        status / usageSource / details(JSON) …
```

---

## 三、逐功能：统计 SQL 对照

下面每节给的都是**可直接复制执行**的 SQL。
页面数字与 SQL 结果对不上时，先看该节「口径提示」。

### 3.0 先看两件事：场站和时间

**场站**：在**看板右上角**选，不在左侧「查询设置」里。它是整块看板共用的统计范围，
树形展开（组织 → 子组织 → 场站），只列具体场站 —— 没有「全部场站」，
默认第一个，选择记在 Cookie 里。

新客户第一次登录时若一个场站都没有，会被不可关闭的蒙屏挡住，先建场站才能进系统。

**时间**：在左侧「查询设置」或顶部「分析条件」里选，有「实时 / 历史」两个页签。

换场站后**结果会自动重查**，不用再点「查询」：统计表、曲线、明细表会一起换成新场站的
设备。如果换了场站但数字没变，那是缺陷（见 [③ 初始化 → 场站与查询条件的加载顺序](/admin/03-init)）。

### 3.0.1 时间是怎么选的（每个页面都适用）

所有能源看板的时间都在**部件里**选，不在看板右上角（那里已经隐藏，见
[③ 初始化 → 时间怎么选](/admin/03-init)）。两个部件、两套页签，语义完全相同：

| 页签 | 控件 | 窗口 |
| --- | --- | --- |
| 实时 | `最近 [N] [秒/分钟/小时/天]` | 右端 = 当前时刻，随时间向前滚 |
| 历史 | 按日 / 按月 / 按年 + 起止 | 固定区间 |

**实时模式会自动回看**：部件先探该实体最后一个数据点（按「勾选的设备 → 品种 →
树节点 → 场站」顺序试），若它已落在窗口之外，**整个窗口**滑到能兜住它
（宽度不变），并在标题写 `数据止于 HH:MM`。所以「实时页一片空白」通常不是没数据，
而是数据停在几小时前 —— 标题那行字就是答案，别急着查接口。

**跨度会真实改变结果**：桶宽 = 窗口 ÷ 40（1 秒 ~ 1 小时），随 `payload.intervalMs`
下发。选 5 分钟是 8 秒一桶，选 60 分钟是 90 秒一桶；报表表格的列数也随之变化
（5 分钟约 6 列、60 分钟约 60 列）。若发现改跨度后表格/曲线完全没变，那是缺陷。

**时间入口只有一处**：看板里有查询设置（或分析条件）时，其余部件不再自带
「按日/按月/按年」或「时/日/月/年」控件 —— 它们的粒度由 `payload.grain` 决定。
峰谷分析右侧的时分段已于 2026-10-25 删除。

`数据止于` 只对**演示数据**常见（逐小时快照，初始化后不再增长）。
接真实 RTU 时窗口右端贴着现在，这句话不会出现。

**用实时页验一条数据到底通没通**：

```bash
# 0) 拿一个令牌（客户账号即可，只能读到自己名下的设备）
TOKEN=$(curl -s -X POST http://127.0.0.1:8090/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"customer@126.com","password":"12345678"}' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')

# 1) 这台设备在库里叫什么 id（换成你要查的名字）
DEV=$(docker exec -i energy-postgres psql -U postgres -d thingsboard -tAc \
  "SELECT id FROM device WHERE name='单相园-1#进线总表·星河工业园'")

# 2) 平台侧最后 3 个点（实时页「数据止于」取的就是这里的第一条）
curl -s -H "X-Authorization: Bearer $TOKEN" \
  "http://127.0.0.1:8090/api/plugins/telemetry/DEVICE/$DEV/values/timeseries?keys=energy,power_total&startTs=0&endTs=$(($(date +%s)*1000))&limit=3&orderBy=DESC" \
  | python3 -m json.tool

# 3) 判读
#    最新点是刚才   → 页面选「实时」，窗口调到能覆盖它的跨度，曲线会持续出点
#    最新点早很多   → 设备侧没在报，按 [④ 设备接入](/admin/04-device-access) 的顺序查
#    完全没有返回值 → key 名不对（换品种）或该设备从未上报过
```

**看板级时间窗口**（编辑模式下仍可改）与部件时间是两件事：
部件发布条件时会调 `onUpdateTimewindow` 把看板窗口同步过去，
所以你在部件里选的历史区间，右键「编辑仪表板」看到的时间也是同一段。

---

### 3.0.2 「查询设置」部件里的树长什么样

> **2026-10-29 客户定稿：取消「查询维度」单选，一律按设备层级。**
> 原来给的是「按设备层级 / 按分组维度」两个单选 + 一个分组根下拉。客户实际只用
> 设备层级 —— 多出来的选项让每块看板多一行，还会被误点成按分项出数
> （界面上看不出区别，数字口径却变了）。
>
> 现在维度在控制器里锁死 `scope.dimension = 'device'`，模板里不再给任何入口；
> `showDimension` 这个设置项即使写成 `true` 也不起作用。
> **按分组维度那条链路仍保留在代码与数据模型里**（`buildDimensions` 照旧解析
> 「数据源绑定·维度N」），只是从本部件进不去 —— 将来要做独立的「按分项查询」
> 部件时还能复用。
>
> 顺带：`onDimensionChange` 留了一行 `scope.dimension = 'device'; return;`，
> 防止旧看板缓存里残留的点击把维度切走。

带「查询设置」的看板（历史能耗 / 基础报表 / 参数报表 / 实时能耗 / 分项能耗…）
左侧那棵树只有一种维度 —— **按设备层级**，场站是**根节点**，设备挂在它下面：

```
单相场站                  ← 根：当前选中的场站（虚拟节点，不能勾选）
  单相园-1#进线总表
  单相园-照明分项总表
  单相园-A栋照明回路
```

场站根只是个收拢层：它没有勾选框（场站资产本身没有遥测，勾进来只会在提交载荷里
多一个不产生数据的实体），点箭头可以折起来，切换场站时根名跟着变。
把场站当根是为了让树先回答「这是哪个场站的表」—— 以前设备平铺，
单相场站和三相场站的表混在一起，只能靠名字猜归属。

**按分组维度的渲染规则（已不可达，留档备查）** —— 根是维度容器
（电能 / 用电分项 / 用能区域 / 用能性质 / 空间位置），根下直接是分类节点、没有场站层：

```
用电分项                  ← 根：维度名
  照明
  插座
  给排水
```

数据模型里每个维度下确实有一层「场站分组」（`asset.type='场站分组'`，label = 场站名），
它是**内部隔离层**：同一客户多个场站时，各场的分类不能混在一起。
渲染时只保留当前场站那一个分组，并把它的子节点提升到维度根下 ——
场站是**归属**，不是分项的子类目。

数据模型一行不动，只在渲染时穿透。所以「新建子分类 / 添加设备 / 拖拽落点」的真实
挂载父仍是那个场站分组 —— 否则新节点会挂到维度容器下、脱离场站分区、聚合断掉。
这段逻辑今天仍在 `buildDimensions` 里活着，只是查询设置不再提供入口。

#### 勾选规则：父节点默认**不**连带子节点

部件设置项 `checkChildren` 的默认值是 **`false`** —— 点父节点只勾中它自己，
不会把下面的子孙一起打勾。要级联必须在看板里显式写 `checkChildren: true`。

**为什么默认关**：计量层级下父子级联是**错的**。一级关口表（进线总表）的读数
已经把二级、三级表的电量包含在内，父子一起选中就是重复计量 ——
账单会虚高 2~3 倍。成熟产品的做法也是 `Tree checkStrictly`（父子不关联）。

| 看板 | `checkChildren` | 点父节点的效果 |
| --- | --- | --- |
| 历史能耗 | `false` | 只查被勾中的那一台，逐台对比 |
| 参数报表 / 用能账单 / 抄表功能 / 峰谷分析 | `false` | 同上 |
| 实时能耗 / 基础报表 / 手工填报 | `true` | 连带整棵子树一起勾（"看这一棵子树"） |
| 分项能耗 / 区域能耗 / 能耗概览等 | 未设置（= `false`） | 只勾自己 |

部件底部的提示文案会跟着这个开关变，不要写死任何一句 ——
同一个部件在两种看板里语义不同，写死一半就是错的。

#### 演示数据的时间窗口（默认时间窗对齐）

演示数据是**建客户那一刻**往前 **62 天**生成的一段历史快照（`DEMO_DAYS = 62`），
窗口末端就是生成当天。客户如果隔一周或一个月才登录，「最近 7 天」里什么都没有 ——
每块看板都是空白，看起来像功能坏了。

**做法**：生成演示数据时把窗口记在客户的服务端属性 `energyDemoWindow` 上，
所有部件的默认时间窗对着它算，而不是对着真实的今天。

```json
{"from":"2026-08-27","to":"2026-10-27","days":62,"generatedAt":1793076767584}
```

前端通过 `GET /api/energy/time-anchor` 拿到基准日：

```json
{"today":"2026-10-27","anchor":"2026-10-27","demo":true,
 "windowFrom":"2026-08-27","windowTo":"2026-10-27","days":62}
```

| 账号类型 | `anchor` | `demo` |
| --- | --- | --- |
| 演示客户（客户属性存在） | 窗口末端（生成演示数据那天） | `true` |
| 真实客户 / 租户管理员 / 系统管理员 | 真实的今天 | `false` |

部件把 `anchor` 当作默认时间窗的右端：按日 → `anchor` 往前 6 天到 `anchor`。
结果缓存在 `window.__energyAnchorMs` 上，一页 8 个部件只发一次请求；
3 秒拿不到就按真实今天走，不能让看板开不出来。

**覆盖的部件**：查询设置（历史能耗 / 峰谷分析 / 参数报表 / 基础报表 / 手工填报…）、
分析条件（分项能耗 / 区域能耗 / 能耗概览）、峰谷平用电能耗统计、功率因数与负荷需量。

> **为什么不让前端自己猜**：猜法只能是「往前找有数据的那天」，要么扫遥测（很贵），
> 要么在每块部件里各写一遍。窗口是生成时就知道的确定事实，记一次、读一次，零计算。

> **为什么不做「按天滚动补齐」**：那要写数据、要定时任务，还要处理「客户已经开始
> 用真实数据」的边界。默认时间窗对齐是只读的，不和数据生成纠缠在一起。

> **手动改过的区间会被记住**（2026-10-27 起）：客户调好区间并点「查询」后，
> 刷新页面或下次进来仍按他选的查，不再跳回 `anchor` 的默认区间。
> 规则见下面的[「时间范围的记忆」](#时间范围的记忆刷新不再跳回默认)。

#### 时间范围的记忆（刷新不再跳回默认）

默认区间是**算**出来的（`anchor` + `defaultRangeDays`），它回答的是「没人动过时
该显示哪段」。客户一旦手动调过区间，这个默认值就不该再覆盖他的选择 ——
否则「调好 → 刷新 → 又变回去」，客户会认为筛选没生效。

| 项 | 规则 |
| --- | --- |
| 存哪 | 浏览器 `localStorage`，键 `tb.energy.timeRange.<dashboardId>.<query\|analysis>` |
| 存什么 | `{customerId, grainLevel/format, fromDate/from, toDate/to, savedAt}` |
| 何时写（查询设置） | 点**「查询」**时写 —— 改了日期但没查询，不算确认 |
| 何时写（分析条件） | 改日期 / 切档位**立即**写（这个部件本来就是改完即发布） |
| 何时读 | 部件初始化时，**优先于**顶部时间窗、`anchor` 和 `defaultRangeDays` |
| 客户隔离 | `customerId` 不同不继承（同一台电脑换了账号登录不会串） |
| 看板隔离 | 每个看板各存一份，历史能耗的区间不会带到峰谷分析 |
| 精度校验 | 存的档位与字符串精度必须吻合（`day`↔`2026-09-01`），否则丢弃重算 |
| 只记历史 | 切到「实时」会清掉记忆 —— 实时窗口的右端是「现在」，存下来没有意义 |
| 默认值不固化 | 没手动改过就不写，所以默认区间仍随 `anchor` 天天滚动 |

**想恢复成默认区间**：把「实时 / 历史」切到实时再切回历史；
或者用浏览器的「清除站点数据」。也可以用控制台精确删掉某一块看板的记忆：

```js
// 只删当前看板：key 里的 id 就是地址栏 dashboardId 那一段
localStorage.removeItem('tb.energy.timeRange.<dashboardId>.query');
localStorage.removeItem('tb.energy.timeRange.<dashboardId>.analysis');
```

> **为什么不写进看板配置**：`configuration` 是模板，所有客户共用一份。
> 一个客户改了区间，别的客户跟着变 —— 那是把个人偏好写进公共配置。
>
> **为什么不按「今天往前 7 天」重新算**：那等于把客户的固定区间又变成滚动窗口，
> 他选的 9 月那一段会莫名其妙往前跑。记忆就是记忆，不做二次加工。

#### 时间范围的日期选择器

四个看板（历史能耗 / 峰谷分析 / 分项能耗 / 区域能耗）的时间范围都用
**TB 自带的 `tb-datetime`**（Material 日期面板），不用原生 `<input type="date">`：

| 项 | 约定 |
| --- | --- |
| 组件 | `<tb-datetime type="date\|month\|year">`，`subscriptSizing="none"` |
| 默认区间 | **近 7 天**（右端今天，左端往前 6 天），由 `defaultRangeDays` 控制 |
| 按月 / 按年 | 默认取当前月 / 当前年（本身就"一段"，再往前推会跨到上月/上年） |
| 起止对齐 | 按日 ≤ 30 天、按月 = 同一个月、按年 = 同一年；改哪端就以哪端为准 |
| 值的形式 | 部件内部仍存 `"2026-10-27"` / `"2026-10"` / `"2026"` 字符串，`tsOf()` 现算毫秒 |
| 输入框格式 | **`yyyy-MM-dd`**（按日）、`yyyy-MM`（按月）、`yyyy`（按年） |
| 面板语言 | **全中文**：`十月` / `一 二 三 四 五 六 日` / `周三 10月21日` |
| 间距与图标 | 文字左内边距 8px；日历图标 18px（框高 30px） |

**为什么值不存两份**：`tb-datetime` 的 `ngModel` 是毫秒时间戳，而 `submit` /
`parseDateInfo` / `clampRange` 都按字符串解析（字符串比较恰好等于日期先后）。
模板用 `tsOf(str)` 现算毫秒、`onPick(ts)` 转回字符串 —— 两边各存一份必然不同步
（切档、跨零点、外部改时间窗都会错开）。

**样式必须走 `::ng-deep`**：动态部件模板里的 `<style>` 也会被 Angular 按封装策略
改写，普通后代选择器的**每一段**都会追加 `[_ngcontent-x]`；而 `tb-datetime`
内部 DOM 带的是它自己的 `[_ngcontent-y]`，规则一条都匹配不上
（典型症状：宿主的高度生效了，内部尺寸纹丝不动）。

> **`<style>` 要写在 `templateHtml` 里，不能写 `templateCss`**（2026-10-27 实测）。
> `templateCss` 由 TB 作为组件 styles 注入，并把每条规则前缀成
> `.widget-type-system-energy_management_xxx ...`；其中 `::ng-deep` **被原样保留**，
> 而浏览器不认识这个伪元素 —— **整条规则被丢弃**。
> 症状：写好的 30px 压缩样式一条不生效，日期框仍是 Material 默认的 56px 内框 /
> 78px 外框（「峰谷平用电能耗统计」就是这么栽的）。
> 把同样的规则搬进 `templateHtml` 的 `<style>` 里就好了 —— 那条路径由 Angular
> 动态编译按封装策略改写，`::ng-deep` 会被降级成 `[_ngcontent-x]` 穿透。
>
> 自检：控制台查规则是否存在且命中
>
> ```js
> // 规则被丢弃时只剩不带穿透的那条
> [...document.styleSheets].flatMap(s => { try { return [...s.cssRules]; } catch { return []; } })
>   .map(r => r.selectorText || '').filter(t => /tous-pick/.test(t));
> // 期望看到 .tous-pick ::ng-deep ... 被改写后的 .xxx .tous-pick .mat-mdc-text-field-wrapper
> ```

**外框要自绘**：`appearance="outline"` 的框**不是** wrapper 的 border，而是
`.mdc-notched-outline` 里三块 `notch-piece`（leading / notch / trailing）各画一段
拼出来的 —— 框色 `rgba(0,0,0,.38)`、圆角 4px、字形高 56px，与旁边的下拉框
（`#d9d9d9` / 3px / 30px）完全不是一套。做法是隐藏那三块，在
`.mat-mdc-text-field-wrapper` 上自己画 1px 方框：

```css
.eqp-dates tb-datetime ::ng-deep .mdc-notched-outline { display: none; }
.eqp-dates tb-datetime ::ng-deep .mat-mdc-text-field-wrapper {
  height: 30px; padding: 0; background: #fff;
  border: 1px solid var(--eqp-border, #d3dbd6); border-radius: 3px;
}
```

只压 wrapper 的 `height` 是压不住的 —— 内部 `infix` 仍是 34px，会溢出到框外，
看起来就是"外框特别大、日历图标跑到框外面"。

**下拉框同样是 TB 的控件，不是原生 `<select>`（2026-10-29 统一）**：

查询设置的 6 个下拉（场站 / 能源品种 / 分组维度 / 指标参数 / 实时单位 / 间隔时间）
全部用 `mat-select` + `mat-option`，事件写 `(selectionChange)="fn($event.value)"`，
不是 `(change)="fn($event.target.value)"` —— 后者是原生 `<select>` 的写法，
套在 `mat-select` 上**永远不触发**（下拉能点开、能选，但界面不变、也不查询）。

Material 的 trigger 默认 48px 高、自身不带边框，外观全靠 `mat-form-field` 的
outline 画框。直接放进这一列会和 30px 的日期框一高一低，所以整条压成同一套方框：

| 目标 | 选择器 |
| --- | --- |
| 框体 30px / 1px `--eqp-border` / 3px 圆角 | `mat-select.eqp-select` 自身（`display:flex` + `height:30px`） |
| trigger 压到 28px | `.eqp-select .mat-mdc-select-trigger` |
| 文字 13px | `.eqp-select .mat-mdc-select-value-text` |
| 箭头不撑高 | `.eqp-select .mat-mdc-select-arrow-wrapper` |

面板（`.mat-mdc-select-panel`，选项 48px 高）走 Material 默认 —— 就是 TB 其它页面
的下拉面板，不另写样式，否则又是"自创一套"。

> **`mat-select` 的值不匹配时显示空白**，而原生 `<select>` 会回落到第一项。
> 能源品种是异步加载的，加载完成前 `sourceId` 还是 null —— 必须给
> `placeholder="加载中…"`，否则看板刚打开的那几秒是一个空框（实测冷启动可达数秒）。

**中文化与格式在 `CustomDateAdapter` 里做，不改 `MAT_DATE_LOCALE`**：

`MAT_DATE_LOCALE` 是全局单值 token，改成 `zh-CN` 会连带改变平台里所有 Material
日期组件（设备安装日期、告警计划等）的格式，而且 `NativeDateAdapter` 走 Angular 的
`formatDate()`，还要额外 `registerLocaleData(localeZh)`，否则运行时报
「Missing locale data for the locale "zh-CN"」。

`CustomDateAdapter`（`ui-ngx/src/app/shared/adapter/custom-datatime-adapter.ts`）
只被 `mat-datetimepicker` 使用，影响面正好等于「时间选择器」本身：

| 重写的方法 | 作用 |
| --- | --- |
| `format()` | 按 `displayFormat` 的字段组合反推档位，输出 `yyyy-MM-dd` / `yyyy-MM` / `yyyy` / `yyyy年M月` |
| `getMonthNames()` | 返回中文月份（月份视图的 12 个格子） |
| `getDayOfWeekNames()` | 返回中文星期（表头 `一 二 三 四 五 六 日`） |
| `parse()` | 支持手打 `2026-10-27` / `2026-10` / `2026` |

> **星期数组必须周日起首**（index 0 = 周日）。`mat-datetimepicker` 拿到数组后会按
> `getFirstDayOfWeek()` 旋转：`weekdays.slice(n).concat(weekdays.slice(0, n))`。
> en-GB 的 `weekInfo.firstDay` 是 1（周一），旋转后正好把周一排到第一格。
> 若数组写成周一起首，旋转会让表头整体错位一格（表头写周二、格子却是周一）。

> **按年档的格式是个坑**：`MatDatetimepickerInputDirective.getDisplayFormat()` 是个
> switch，只写了 `date` / `datetime` / `time` / `month` 四个分支，**漏了 `year`** ——
> 于是 `type="year"` 拿到 `undefined`，父类退回 DatePipe 默认格式，en-GB 下就是
> `01/01/2026`（年份档里塞了个月日和它自己无关）。适配器把 `undefined` 精确映射成
> 「只有年」，既修掉格式，也让按年档显示成 `2026` 而不是 `2026-01-01`。
> 若将来库补上 `year` 分支，适配器就走不到这一条 —— 那时显示 `yyyy-MM-dd`，同样合规。

**改完 `CustomDateAdapter` 必须重建前端**（它编译进 `ui-ngx` 的 JS，不是部件 JSON）：

```bash
cd ui-ngx
node --max_old_space_size=8192 ./node_modules/@angular/cli/bin/ng build --configuration production
jar cfM /tmp/ui-ngx.jar -C target/generated-resources .
cp /tmp/ui-ngx.jar ~/Documents/dev_tools/maven_repository/rule-engine/org/thingsboard/ui-ngx/4.4.0/ui-ngx-4.4.0.jar
cd ../guard-server && mvn -o package -DskipTests -q
cp target/guard-server-4.4.0.jar ~/energy-app/
cd ~/energy-app && docker compose --profile split restart energy-server
```

约 13 分钟（Angular 生产构建）。只改部件 JSON 时不需要这一步。

---

#### 查询设置的表单控件：一律 mat-form-field，32px

2026-10-29 客户第三轮反馈：「input 框和 select 表单控件也不是 TB 的样式」。
上一版是自己拿 `border` 画了个 30px 方框套在 `mat-select` 上 —— 看着像方框，
但浮动标签、聚焦态、禁用态、hover 边框全是自绘的，和平台其它页面
（设备管理、规则链配置）的输入框一眼能分出两套。

现在 6 组控件（场站 / 能源品种 / 搜索 / 指标参数 / 实时单位 / 间隔时间）
全部走 `<mat-form-field appearance="outline" subscriptSizing="dynamic">`，
框、标签、箭头、聚焦色都由 TB 主题提供；本部件只压高度（32px，比平台标准
40px 矮一点，因为这一列只有 300px 宽、要装 6 组）。

**压高度必须同时改三个变量**，在元素上写 `height` 是没用的：

```css
.eqp-ff {
  --mat-form-field-container-height: 32px;
  --mat-form-field-container-vertical-padding: 8px;
  --mat-mdc-form-field-label-transform:
      translateY(calc(calc(6.7px + var(--mat-form-field-container-height) / 2) * -1)) scale(0.85);
}
```

原因：`.mdc-text-field` 的高度就是 `height: var(--mat-form-field-container-height)`
（TB 在根级设成 56px），元素上的 `height` 会被它覆盖；
`.mat-mdc-form-field-infix` 的 `min-height` 和上下内边距也从同一个变量算出来。
只改元素尺寸 = 改一半，框仍是 56px（实测过：写 `height:32px` 量出来 57px）。
第三个变量是标签浮起后的位移，公式里含高度 —— 忘了改，标签会按 56px 的居中位算，
直接压到文字上。

**内部元素还必须 `::ng-deep`**：`mat-form-field` 是组件，
`.mat-mdc-text-field-wrapper` / `.mat-mdc-form-field-infix` / `.mdc-floating-label`
带的是组件自己的 `[_ngcontent-y]`，不带本模板的 `[_ngcontent-x]` ——
`.eqp-ff .mat-mdc-text-field-wrapper { height: 32px }` 这种写法**一条都不命中**。
日期框（`tb-datetime`）用的是同一招，两边因此天然一致。

**按钮和分段控件也换成 TB 控件**：

| 控件 | 原来 | 现在 |
| --- | --- | --- |
| 查询按钮 | 自绘 `<button class="eqp-btn">` | `mat-flat-button color="primary"`（32px） |
| 实时 / 历史 | 两个 `<span>` 套 border | `mat-button-toggle-group`（28px） |
| 按日 / 按月 / 按年 | 同上 | 同上 |

分段控件的选中态要显式给主色：Material 默认是灰底，落在白面板里几乎看不出选了哪个。

```css
.eqp-seg ::ng-deep .mat-button-toggle-checked {
  background: color-mix(in srgb, var(--eqp-primary) 12%, #fff);
}
.eqp-seg ::ng-deep .mat-button-toggle-checked .mat-button-toggle-label-content {
  color: var(--eqp-primary); font-weight: 500;
}
```

> `mat-button-toggle-group` 能用，是因为 `SharedModule` 导出了
> `MatButtonToggleModule`，而动态部件模块是 `[SharedModule, WidgetComponentsModule, ...]`。
> 换别的 Material 组件前先确认它在 `SharedModule` 的 exports 里。

#### 树勾选框与设备名对齐（2026-10-29 修）

症状：树里 **复选框比设备名低 8px**，一行 28px 像是歪的。两个页面（查询设置、
一键抄表）都有。实测数据：背景框中心 `y=345`、名字中心 `y=337`，差 8px。

根因是三件事叠在一起，缺一条都修不好：

1. **`.mdc-checkbox` 的内部规则没穿透**。`.mat-mdc-checkbox` 是宿主、带本模板的
   `[_ngcontent-x]`，普通选择器能中；但 `.mdc-checkbox` / `.mdc-checkbox__background` /
   `.mat-mdc-checkbox-touch-target` 是组件内部 DOM，带自己的 `[_ngcontent-y]`。
   于是宿主被压成 24px、内部还是 40px，方框画在 40px 容器的中心 —— 比 24px 的名字行低 8px。
2. **`templateCss` 里的 `::ng-deep` 会被丢弃**。TB 会把 `templateCss` 的每条规则
   前缀成 `.widget-type-system-energy_management_xxx ...`，`::ng-deep` 原样保留，
   浏览器不认识这个伪元素，整条规则作废。所以一键抄表的勾选框压缩规则**必须**
   写在 `templateHtml` 的 `<style>` 里 —— 那条路径由 Angular 动态编译改写，
   `::ng-deep` 会降级成 `[_ngcontent-x]` 穿透。
3. **`box-sizing` 必须是 `border-box`**。默认 `content-box` 时 `width/height: 24px`
   只是内容区，加上 3px 上下内边距后实际 30px —— 比 28px 的行还高，方框又被挤下去。
   `border-box` 后 24px 真含内边距，内容区 18px 正好是方框尺寸。

修完还要补 1.5px：`.mdc-checkbox__background` 是 absolute，包含块是 padding box，
`top: 0` 时方框中心仍比名字高 1.4px。三个部件统一用 `top: 1.5px; left: 3px;`。

对齐自检（任一树看板，控制台）：

```js
const row = [...document.querySelectorAll('.eqp-node, .eqm-tree-row')]
  .find(r => r.querySelector('mat-checkbox'));
const bg = row.querySelector('.mdc-checkbox__background');
const nm = row.querySelector('.eqp-node-name, .eqm-tree-node-name');
const c = e => { const b = e.getBoundingClientRect(); return (b.top + b.bottom) / 2; };
c(bg) - c(nm);   // 期望 |差值| ≤ 0.5
```

#### 树行距 28px（2026-10-29 客户要求 +2px）

两个部件的行盒统一 28px：`line-height: 26px` + 上下 `padding: 1px`。
改之前是 26px（`line-height: 24px`），客户要求「再调大 2 像素」。

| 部件 | 选择器 | 当前值 |
| --- | --- | --- |
| 查询设置 | `.eqp-node` | `line-height: 26px; padding: 1px 6px` |
| 一键抄表 | `.eqm-tree-row` | `line-height: 26px; padding: 1px 6px 1px 0` |

> 两个部件必须一起改。「查询设置」和「一键抄表」的树是同一套视觉，
> 只改一边立刻就能看出谁高谁低。

#### 一键抄表的工具行与主按钮（2026-10-29）

左侧面板 300px 宽，四个元素挤在一行会互相压：

| 元素 | 位置 | 说明 |
| --- | --- | --- |
| 连叶子 | 最左 | **不能定死宽度**。原来 `.eqm-tree-actions .mat-mdc-checkbox { width: 24px }` 把它压成 24px，3 个字的 label 只剩几像素，直接折成两行。只有树行里的勾选框（没有文字 label）才该定宽度 |
| 全选 / 清空 | 靠右 | 中间放 `<span class="flex-1">` 把它们推过去；挤在左边时连叶子没空间 |
| 已选/总数 | 最右 | `margin-left: 6px` 与「清空」拉开 |

主按钮 `.eqm-run-btn` 从 `flex: 1`（撑满整行）改成 `flex: 0 0 auto`：
去掉右侧「抄选中的 N 台」提示后，撑满的按钮会独占 300px 面板宽度，看着像个页脚条。
「勾了几台」已经由工具行右侧的 `已选/总数` 表达，不再重复。

#### 三层计量树长什么样

演示数据里单相 / 三相场站都是 **1 级 → 2 级 → 3 级** 三层
（`meterLevel` 写在设备 `SERVER_SCOPE`，父表写在 `additionalInfo.parentDeviceId`）：

```
单相场站
  单相园-1#进线总表                1 级（关口表，本子树里没有上级表）
    单相园-照明分项总表            2 级
      单相园-A栋照明回路           3 级（叶子表）
    单相园-插座分项总表            2 级
      单相园-A栋插座回路           3 级
    单相园-空调虚拟表              0 级（虚拟表，手工填报用，不参与汇总）

三相场站
  三相园-1#进线总表                1 级
    三相园-办公区总表              2 级
      三相园-办公照明回路          3 级
    三相园-车间动力总表            2 级
      三相园-空压机组              3 级
      三相园-车床组                3 级
```

**层级数字只是档案上的标注，判定一定要走拓扑** —— 现实里会把总表和分项总表
都填成 2 级。口径见 3.5「关口表口径」。

---

### 3.0.3 图表部件的两种形态与统一规格

6 个图表部件（能耗概览 / 分项能耗 / 历史能耗 / 实时能耗 / 能源流向 / 峰谷分析）
都提供 **图表 ⇄ 数据表** 切换，且规格统一：

| 项 | 规格 |
| --- | --- |
| 位置 | 右上角，`top: 34px`（避开 TB 自带的部件操作按钮） |
| 尺寸 | 图标 26×26，容器 padding 2px，圆角 6px |
| 显隐 | 默认 `opacity: 0; pointer-events: none`，`:hover` 时恢复 |
| 激活色 | `--tb-primary-600`（当前形态高亮） |
| 数据 | 两种形态读同一份数据（如 `bEnergy` / `billingRows`），数字必须一致 |

改任一部件时，另外 5 个要一起改 —— 类名与样式分散在各部件内，
没有共享 CSS（TB 部件之间无法互相引用样式）。

**看板高度**：`gridSettings.autoFillHeight` 让网格恰好一屏。
≤ 20 行的看板开启，> 20 行（如 36 行的「我的账单」）保持固定行高、页面可滚 ——
否则行高被均摊到 25px，部件全被压扁。

**查询设置高度**：`query_panel.sizeY` 必须等于「该看板最大底边 − 它自己的 row」，
否则左侧会矮一截或在中间才开始。

#### 时间粒度与范围上限（2026-10-26 统一）

`energy_management.analysis_bar`（「分析条件」部件）定档，结果部件只认下发的
`grain`，两边不各算一套。

**① 默认「历史」**

```
实时 / 历史   两个 tab，默认「历史」
              settings.timeMode 只有显式写成 'realtime' 才进实时模式；
              缺省、写错、留空一律落到「历史」。
```

**② 范围上限（三个档各自封顶，超了自动对齐并给出提示）**

| 档位 | 上限 | 超限行为 |
| --- | --- | --- |
| 按日 | 30 天（含首尾） | 另一端被拉到边界，提示「按日查询最多 30 天，已自动调整另一端日期。」 |
| 按月 | 同一个月 | 起止互相对齐到同一月，提示「按月查询最多选 1 个月，已自动对齐起止月份。」 |
| 按年 | 同一年 | 起止对齐到同一年，提示「按年查询最多选 1 年，已自动对齐起止年份。」 |

实现点：`clampRange()` 做收口、`refreshBounds()` 把原生 `<input min/max>` 也一起限制住
（浏览器选择器里就点不出越界日期，比只做事后校验顺手）。

**③ 粒度与档位严格一一对应（不按跨度降档）**

```
按日  → 每小时一根堆叠柱     30 天 = 720 根
按月  → 每天一根堆叠柱       最多 31 根
按年  → 每月一根堆叠柱       横轴固定 1–12 月，共 12 个位置
```

> 旧实现按跨度降档（按日选 7 天会被降成「每天一根」），与「按日 = 该跨度所有天的
> 24 小时柱」的预期相反，已于 2026-10-26 去掉。范围上限已经保证柱数可控，不需要降档。

**④ 服务端 700 桶上限 → 前端自动分段**

`database.ts_max_intervals`（默认 **700**）会硬拒桶数超限的请求：

```
Incorrect TsKvQuery. Number of intervals is to high - 719.
```

按日 30 天 = 720 桶，一次请求必被拒。`asset_stats_chart` 的 `fetchChunked()`
按 `690 × interval` 切片（留 10 的余量），每段起点落在全局桶相位上，
返回后按 ts 去重合并 —— 段数不足时（按月/按年）自动退化为单次请求。

**⑤ 桶时间戳要吸附，不要精确比对**

服务端 `interval` 聚合返回的 ts 是**桶内最后一个数据点**，不是桶起点：

```
小时桶（数据每 30 分钟一个点）→ xx:30
天桶                          → 12:00 / 11:59:59
```

所以前端一律 `snapTs()` 吸附到 `fromTs + k*iv` 网格（取 floor）。
不吸附会出现「不同序列落在不同槽位」「某一天只剩一根柱子」。

**⑥ 月汇总点要摊平（虚拟表 / 手工填报）**

虚拟表按「月首一个点 = 整月用量」写入 `energy_total`（实测空调分项 09-01 = 1520 kWh，
周围真实小时值约 3）。按小时/按天画柱时必须 `spreadMonthly()` 按桶均分，
总量守恒，否则 Y 轴被拉到 1.5k、其余柱全压成 0.5px。

详情见 [② 常见故障](/admin/05-troubleshoot) 的 Y26。

---

### 3.0.4 数据表格统一规范（`.tb-data-table`）

全系统的表格只有一份定义：`ui-ngx/src/styles.scss` 里的 `.tb-data-table`。
动态部件（`widget_type` 的 `templateHtml`）与普通 Angular 页面共用同一个类名。

**为什么不用 `mat-table`**

仪表板动态部件的 HTML **不参与 Angular 组件编译**。`mat-table` 的样式写在组件
`scss` 里、带 emulated 作用域（`_ngcontent-xxx` 属性选择器），动态部件套上
`.mat-mdc-table` 类名也匹配不到 —— 只会得到一个没有边框、没有内边距、
表头和数据挤在一起的原生表格。所以部件里的 `mat-table` 只是"能跑"，
视觉上并不跟随 TB 主题。

统一规范改为**用 TB 的设计 token（`--tb-*`）复刻 Material 数据表的度量**，
一次定义、全系统共用：

| 项 | 规格 |
| --- | --- |
| 表头 | 高 40px，底色 `#fafafa`，12px / 500，`--tb-ink-2` 灰字，下边框 1px `--tb-line` |
| 数据行 | 高 36px，13px，下边框 1px `rgba(0,0,0,.06)`，最后一行无边框 |
| 内边距 | 横向 16px（密集表 `--compact` 为 10px） |
| 竖线 | **没有**。只有水平分隔线 —— 逐格描边是 Excel 观感，表一宽就像网格纸 |
| 数字列 | `.tb-num` 右对齐 + `tabular-nums`，保证大小数的位数上下对齐 |
| 实体列 | `.tb-name` 字重 500，作为视觉锚点（设备名 / 参数名） |
| 次要信息 | `.tb-muted` 用 `--tb-ink-3`（时间、单位） |
| 空值 | `.tb-empty` 弱化，字符仍由模板决定（设计图用 `/`） |
| 行悬停 | 整行 `#f7f7f7`，横向读数时不串行 |
| 汇总行 | `.tb-sum` 底色 `#fafafa` + 500 字重，与明细区分 |
| 分组段 | `.tb-group-start` 加一条顶部分隔线，把 rowspan 的不同设备切开 |
| 跨行单元格 | `.tb-span` 整块淡底、内部无线、垂直居中（见下） |
| 冻结列 | `.tb-sticky` 必须**不透明底色**，否则横向滚动时内容从底下透出来；`.tb-sticky-last` 在右边缘补一条竖线交代层级 |

**跨行单元格（rowspan）必须加 `.tb-span`**

跨行的语义是「这几行属于同一个设备」，所以它必须是**一整块**：

```html
<td class="tb-name tb-span" [attr.rowspan]="r.deviceSpan">{{ r.deviceName }}</td>
```

```css
.tb-data-table td.tb-span {
  --tb-cell-bg: #fafafa;
  background-color: #fafafa;
  vertical-align: middle;
}
/* 冻列 + 跨行叠加时底色也要跟着走，否则冻结列会是一道白条 */
.tb-data-table .tb-sticky.tb-span { --tb-cell-bg: #fafafa; background-color: #fafafa; }
/* 悬停：必须带 .tb-sticky 组合，(0,3,0) 才能压过上面的规则 */
.tb-data-table :where(tbody tr:hover) .tb-sticky.tb-span { background-color: #f2f2f2; }
```

**走过的两次弯路**（都实装过、都被反馈）：

| 做法 | 结果 |
| --- | --- |
| 什么都不做 | 普通格靠自己的 `border-bottom` 画线，合并后内部一片空白，用户以为**边线丢了** |
| 用等间距渐变把被跨过的行线补齐 | 线确实对齐了（实测误差 1px 内），但跨行格被切成和右侧一模一样的 N 段，**看起来就是 N 个独立格子，完全看不出跨行** |
| **整块淡底 + 内部无线**（当前） | 一眼看出是一整块；外框由普通单元格规则提供，"边线丢了"也不会再发生 |

要点：

- 淡底用 `#fafafa`（与表头同色），一眼看出是层级块，又不抢数据注意力；
- **内部不画任何横线** —— 补线会让跨行失效；
- 冻结列（`.tb-sticky`）必须用 `background-color: var(--tb-cell-bg, #fff)` 而不是
  `background: #fff` 简写，否则会把跨行底色冲掉；
- 设备名**垂直居中**（`vertical-align: middle`）。部件里若写了
  `.eqc-table-ex .eqc-td-dev { vertical-align: top }` 会盖掉它，设备名就贴在上边框，
  看起来像"只占第一行"。

**没有任何竖线**：跨行块与右侧数据列之间那道"线"是淡底与白底的色差边界，
不是边框（实测所有 `td` 的 `border-right: 0px`）。不要为了"更清楚"去加 `border-right`。

```html
<table class="tb-data-table tb-data-table--fill">
  <thead><tr><th class="tb-name">设备</th><th class="tb-num">最大值</th></tr></thead>
  <tbody>
    <tr class="tb-group-start"><td class="tb-name">1#进线总表</td><td class="tb-num">203.7</td></tr>
    <tr><td class="tb-muted">2026-10-25 12:00:00</td><td class="tb-num">67.9</td></tr>
  </tbody>
</table>
```

修饰类只有两个：`--fill`（撑满容器）、`--compact`（密集时间序列，行高 30/32px）。

**迁移注意**：部件自己的 `templateCss` / `<style>` 里若还有 `th, td { padding; border-right; background }`
之类的规则，**必须删掉** —— 部件内联样式会覆盖全局类（全局规则都套了 `:where()`，
特异性只有 `(0,1,0)`；部件写 `.eqd-table td` 是 `(0,1,1)`，一定赢）。留着就把统一规范
覆盖回旧样子，这是迁移后"看起来没变"的最常见原因。部件里只保留"本部件专有"的规则：
列宽、列对齐、冻结列的 `left` 偏移、语义色。

**`mat-table` 能不能用**：能，但**只加类名不够**。`<table mat-table>` 渲染出来的仍是
标准 `<table><thead><tr><th>`，所以 `.tb-data-table` 的 `thead th` / `tbody td` 规则能命中；
但 `mat-table` 自带的「行高 / 内边距 / 分隔线」写在 `@angular/material` 的组件 scss 里、
带 `_ngcontent` 作用域，动态部件拿不到 —— 这才是表格难看的根因。
所以：要么给 `mat-table` 加 `tb-data-table` 类名（推荐，改动最小），
要么改写成原生 `<table>`（结构可控，`timeseries_table` 走的就是这条）。

**已在 2026-10-26 迁移的部件**（全部 `templateHtml` 含 `tb-data-table`）：

| 部件 | 表格 | 备注 |
| --- | --- | --- |
| `timeseries_chart` | 极值表 / 数据表详情 | 基准实现，见 3.2 |
| `statistics_table` | 参数报表 | 设备 / 参数 rowspan |
| `detail_table` | 明细表 | 左右双向冻结列 |
| `tou_analysis` | 峰谷分析 | `--compact` |
| `energy_overview` | 能耗概览排名 | 去掉了硬编码 #f7f9fc / #42576b |
| `power_quality` | 电能质量（2 张） | `--compact` |
| `sankey_flow` | 能源流向 | `--compact` |
| `saving_records` | 节能记录 | `--compact` |
| `audit_report` | 盘查报告（2 张） | `--compact` |
| `billing_crosstab` | 账单交叉表 | 首列 + 表头冻结 |
| `realtime_trend` | 实时能耗 | `--compact` |
| `distribution_chart` | 分项能耗 | |
| `asset_stats_chart` | 资产统计 | `--compact` |
| `timeseries_table` | 时序表 | 由 `mat-table` 改写为原生 |
| `meter_reading_board` | 抄表台账（2 张） | `mat-table` + 类名 |
| `meter_batch_detail` | 抄表明细 | `mat-table` + 类名 |
| `manual_entry` | 手工填报 | `mat-table` + 类名；`.mat-mdc-*` 选择器改为 `thead th` / `tbody td` |
| `idle_energy_analysis_board` | 闲置能耗分析 | |

**故意不迁移的**：

- `calendar_heatmap` —— 日历格子靠 `border-spacing: 3px` 分隔，不是数据表；
- `energy_type_config` —— 后台配置表，里面是 form 控件，行高由输入框决定。

**核查命令**（还有哪些表格没走统一规范）：

```bash
cd guard-server/src/main/data/json/system/widget_types
python3 - <<'PY'
import json, glob, os, re
left = []
for f in sorted(glob.glob('*.json')):
    d = json.load(open(f, encoding='utf-8'))
    tpl = d.get('descriptor', {}).get('templateHtml', '') or ''
    if '<table' in tpl and 'tb-data-table' not in tpl:
        left.append(os.path.basename(f)[:-5])
print('未迁移：', left or '无')
PY
```

当前结果应为 `['energy_management_calendar_heatmap', 'energy_management_energy_type_config']`
（都在上面的"故意不迁移"清单里）。

---

### 3.0.5 选项卡统一规格

历史能耗右侧的三个视图用文字选项卡（`viewTabs=true`）。度量严格对齐
TB 原生 `mat-tab`（Material 3）：

| token | 值 |
| --- | --- |
| `tab-container-height` | 48px |
| `tab-label-text-size` | 14px（`0.875rem`） |
| `tab-label-text-weight` | 500 |
| `tab-label-text-tracking` | `0.006rem` |
| `tab-active-indicator-height` | 2px |
| `tab-divider-height` | 1px |

横向 padding 24px。以前写的是 `padding: 6px 14px` + 13px 字号，
比 TB 任何一处 tab 都小一号，放在看板里像一行普通文字链接，
用户认不出它是可切换的选项卡。

`viewTabs=false` 的部件仍用右上角两个图标切换（图表 / 数据表），
显隐规则见 3.0.3。

---

### 3.0.6 设备显示名一律用 `label`

TB 的实体有两个名字：`name` 是**技术名**（租户内唯一，演示数据里带客户后缀，
如 `三相园-1#进线总表·平台演示中心`），`label` 是**显示名**（`三相园-1#进线总表`）。

**界面上出现的一律是 `label`**，取值写法统一为：

```js
d.label || d.name || d.id.id      // 设备
a.label || a.name                 // 资产
```

技术名只用于：接口按名精确匹配、日志、SQL 排障。
一旦上屏，客户会看到一串带后缀的长名字，既超宽又不像自己的台账。

排查命令：

```sql
-- 找出 label 为空的实体（界面会退化成显技术名）
SELECT 'device' AS 类型, name AS 技术名 FROM device  WHERE label IS NULL OR label=''
UNION ALL
SELECT 'asset',           name          FROM asset   WHERE label IS NULL OR label='';
```

查询设置的搜索框**同时匹配 label 与技术名**：客户可能按台账名搜，也可能按系统名搜。

---

### 3.0.7 场站能源品种决定报表可见品种

**一句话**：场站建档时勾了哪些「能源品种」，报表的品种下拉里就只有那些。

```
场站档案 → 能源品种（多选：电能 / 水 / 燃气 / 蒸汽）
        ↓
GET /api/energy/metric-params?siteId=<场站id>
        ↓
分析条件部件的品种下拉（只列该场站启用的品种）
```

**为什么要有这条**：只装了电表的场站，报表里列出「水 / 燃气 / 蒸汽」，
客户切过去整页空白，会以为功能坏了。

**判定顺序（服务端 `siteVisibleKinds`）**

1. 场站属性 `energyType` 有值 → **严格按它**（客户显式选择优先）；
2. 没配 → 从该场站子树内**设备档案**推断（`device profile.energyTypeCode`）；
3. 两条都空 → 返回全部品种（不能因为没建档就把功能关掉）。

响应里带 `filtered: true/false` 和 `siteKinds`，前端据此区分
「本场站未启用品种」与「加载失败」。

**场站档案的下拉从哪来**

`GET /api/energy/dictionaries` → `admin_settings.energyDictionaries`。
它的 `energyType` 分类由 `EnergyBootstrapInstaller.ensureEnergyDictionaries()`
**从品种库同步**（品种库有哪些品种，这里就有哪些选项），
code 与品种资产的 `code` 严格一致 —— 不一致会导致「场站选了品种、报表却还是全量」。

该字典在建客户流程里自动初始化，存量库用「平台自检 → 一键修复初始化」补装
（返回 `dictionariesFixed`）。

**验证**

```bash
# ① 字典有 4 个品种
TOKEN=$(curl -s -X POST http://127.0.0.1:8090/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"tenant@126.com","password":"12345678"}' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
curl -s -H "X-Authorization: Bearer $TOKEN" \
  http://127.0.0.1:8090/api/energy/dictionaries \
| python3 -c 'import sys,json;d=json.load(sys.stdin);print([i["code"] for i in d["energyType"]["items"]])'
# ['elec', 'water', 'gas', 'steam']

# ② 按场站过滤
SITE=$(docker exec -i energy-postgres psql -U postgres -d thingsboard -t -A -c \
  "SELECT id FROM asset WHERE type='场站' AND label LIKE '单相%' LIMIT 1;")
curl -s -H "X-Authorization: Bearer $TOKEN" \
  "http://127.0.0.1:8090/api/energy/metric-params?siteId=$SITE" \
| python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["filtered"], [k["code"] for k in d["kinds"]])'
```

**实测对照（2026-10-27）**

```
单相场站 energyType=["elec","water","gas","steam"]  → 下拉 4 项：电能 / 燃气 / 水表 / 蒸汽
单相场站 energyType=["elec"]                       → 下拉 1 项：电能
```

> ⚠ 改了场站品种后**刷新页面**才生效（品种清单在部件初始化时拉取，
> 场站切换会自动重拉，但同一场站改档案不会主动推）。

---


### 3.1 能耗概览 / 实时能耗

#### 能耗概览不显示顶栏场站选择器（2026-10-27 客户要求）

能耗概览是**跨场站的概览**，右上角再放一个场站选择器与它的定位矛盾；
需要具体场站的部件改为各自带下拉（峰谷平、功率因数与负荷需量都带了）。
其它看板全部保留顶栏场站。

开关是看板级配置 `configuration.settings.showStationSelect`：

| 看板 | 值 | 说明 |
| --- | --- | --- |
| 能耗概览 | `false` | 顶栏不渲染 `tb-station-select` |
| 其余 21 块 | `true` | 行为不变 |

```sql
-- 核对
SELECT title, configuration::json->'settings'->>'showStationSelect' AS station
FROM dashboard WHERE title IN ('能耗概览','分项能耗','历史能耗');
```

> **关掉之后，`state.siteCtx` 就没有写者了**。`tb-station-select` 是场站的唯一写者
> （部件自己 publish 会与顶栏互相覆盖，早已统一为「只有顶栏写」）。
> 所以凡是要统计具体场站的部件，在 `showStationSelect=false` 的看板上必须
> **自带场站下拉**，否则会退回「第一个可见场站」并且用户无从修改 ——
> 页面上写着「默认场站」，却没有能改的地方。
>
> 部件的开关是 `settings.showSitePicker`：能耗概览的两块统计部件为 `true`，
> 其它看板为 `false`（由顶栏托管，行为一字不变）。

#### 概览里三个部件的时间条（2026-10-27 定稿）

这三块原来是 `timeMode: state`（时间由「分析条件」下发）或两个原生
`<input type="date">`，按日只能选公历日期 —— 按月选不出「2026-10」，
按年更没法选。现在统一切成 `timeMode: own` + TB 自带的 `tb-datetime`，
精度随档位切换（`date` / `month` / `year`）：

| 部件 | 按日 | 按月 | 按年 | 选择器数量 |
| --- | --- | --- | --- | --- |
| 历史用电量统计（`asset_stats_chart`） | 某一天 | 某个月 | 某一年 | **1 个**（单选） |
| 分项用电量对比（`distribution_chart`） | 某一天 | 某个月 | 某一年 | **1 个**（单选） |
| 用电量排名（`ranking_list`） | 起止两天 | 起止两月 | 起止两年 | **2 个**（区间） |

> **为什么排名是区间、另外两个是单选**：排名回答的是「这段时间里谁用得最多」，
> 单日排序信息量太低（一天里各分项的差异常被采样噪声淹没）；而历史统计与
> 分项对比看的是「这一天的构成」，单值才对得上饼图/柱图。
>
> 三个部件的 `pickOwnFmt()` 切档时都**重置到该档的当前单位**（今天 / 本月 / 今年），
> 不从旧值换算 —— 按日选 10-27，切到按月若保留 10-27，月份选择器会拿到非法值被清空。

**另有「表类型」筛选（仅排名部件）**：全部表 / 关口表 / 普通表。
关口表 = 本子树内没有父表的表（读数已含下级，不重复计量）；
筛选到「普通表」时副标题改成「普通表为下级表计，不参与合计」——
普通表彼此重复计量，写「关口表合计 0.00」只会让人以为数据丢了。

#### 工具条统一规范（2026-10-27 客户要求）

能耗概览上六个带查询条件的部件（历史详细 / 历史统计 / 分项对比 / 排名 / 峰谷平 /
功率因数与负荷需量）原来各写一套样式，并排放一行时高低不齐：标题有的 14px 有的 16px，
档位按钮有的 22px 有的 30px，日期框有的 26px 有的 30px 宽 128/132/124 三种。
现在统一成一套：

| 项 | 规格 |
| --- | --- |
| 布局 | 标题在左、查询条件右对齐（标题 `flex: 0 1 auto`，条件组 `margin-left: auto`） |
| 标题 | 13.5px / 600 / `#1f3b52`；副标题 11.5px / `#7e8fa1`，过长时省略（可悬停看全） |
| 档位按钮 | 高 26px、字号 12px、圆角 4px；选中为主色底白字 |
| 日期框 | 高 26px、宽 124px；内部 24px，日历图标 15px |
| 下拉 | 高 26px，`#dce5ed` 边框，右侧自绘箭头 |
| 部件内边距 | `10px 44px 10px 12px` |

**右侧让位：按 TB 图标实际占位分配（2026-10-27 修正）**

TB 在每个部件右上角渲染 `.tb-widget-actions`，**宽度取决于该部件有几个按钮**：

| 部件 | 图标按钮数 | 占宽 | 让位规则 |
| --- | --- | --- | --- |
| 历史详细 / 历史统计 / 分项对比 / 用电量排名 | 1 个 | 32px | 内容区 12px；**顶栏单独再多留 32px** |
| 峰谷平 / 功率因数与负荷需量 | 2 个 | 64px | 整个部件 76px |

- **让位只加在顶栏那一行**：图标垂直位置只在部件顶行，列表/图表铺到 12px 就够，
  给整块留 44px 会让列表每一行右侧都空一大块（客户反馈「内容离右内边距有点大」）。
- **双按钮部件必须整块 76px**：它们的顶栏被档位+日期+下拉占满，无法只缩小顶栏内边距。
- 实测对齐结果：顶栏日期框右端 1626、图标左端 1630 —— 间隙 4px，恰好不压不空。

**图表文字颜色统一为三级**：

| 用途 | 颜色 | 出现处 |
| --- | --- | --- |
| 次要/轴标签 | `#8796a5` | 坐标轴刻度、周标题、分组标题、占比文字 |
| 正文/图例 | `#5b6f82` | 图例名、列表行名、中心说明 |
| 强调数值 | `#1f3b52` | 卡片数值、列表数值、环形图中心值 |

> **标题里不再重复日期范围**。原来自带时间条的部件标题是
> `2026-10-27 ~ 2026-10-27用电量排名` —— 右侧日期框已经写明是哪一天，标题再写一遍，
> 在 12 栅格（约 676px）宽时会把标题挤成「20… 共 13 …」。
> 现在 `timeMode === 'own'` 时 `{date}` 一律留空，标题只剩「用电量排名」。

**排名部件的「表类型」从一个按钮组改成下拉**：三个按钮占 159px，
加上档位与两个日期框共 590px，把标题压到 6px。改成 84px 的 `<select>` 后同排装得下，
也与用户「表类型下拉选」的原话一致。

#### 看板布局：一屏放不下就滚动，不要压缩（2026-10-27 定稿）

能耗概览有 8 个部件，一屏（900px 高的笔记本屏）必然放不下。此前的
`autoFillHeight: true` 会让 gridster 把 **30 行**压进 **12 行**的高度里 ——
部件内部被裁切：日历只露半截、图表只剩标题、日期控件互相重叠。
看起来像"页面太挤"，实际是布局策略选错了。

| gridSettings | 值 | 为什么 |
| --- | --- | --- |
| `autoFillHeight` | `false` | 按行数算真实高度，超出视口就出**纵向滚动条**，部件保持自身尺寸 |
| `columns` / `margin` | `24` / `10` | 与其它看板一致 |
| `mobileRowHeight` | `70` | **只对移动端生效** |

> **桌面端没有「固定行高」这个选项**，别去 `gridSettings` 里写 `rowHeight` ——
> `dashboard.component.ts` 的 `detectRowSize()` 在「非 autofill + 非移动端」分支
> 直接返回 `null`，那个值根本不会进 gridster。
>
> 桌面行高是 **gridster 按看板宽度等比算的**（实测 ≈ 宽度 × 0.034）：
>
> | 视口宽 | 每行高 | 34 行总高 |
> | --- | --- | --- |
> | 1366 | ≈ 46px | ≈ 1560px |
> | 1680 | ≈ 59px | ≈ 2000px |
> | 1920 | ≈ 69px | ≈ 2340px |
>
> 所以**高度只能靠行数（`sizeY`）调**，并且要按**最小 1366 宽**校准 ——
> 在 1920 上刚好合身的行数，到 1366 上会把内容裁掉。

**另：顶部那条红色进度条**

它是 Material 的 `mat-progress-bar mode="indeterminate"`，绑的是**全局** `isLoading`
（任何一次 HTTP 请求都会点亮）。能耗概览有 8 个部件并发取数 + 峰谷平/功率因数的
周期刷新，红条会常驻不消失，看起来像一直加载失败。

看板级开关（`configuration.settings`）关掉它：

```json
{ "suppressLoadingBar": true }
```

`realtime_energy`（实时能耗）早就开了同一个开关，原因是"每几秒拉一次遥测"。
能耗概览按同一标准处理。**只影响这一块看板**，其它看板行为不变。

**部件顺序（自上而下，两个新部件固定在最下面）**：

| 行 | 部件 | 尺寸 | 说明 |
| --- | --- | --- | --- |
| 0 | 分析条件（能源品种） | 24×1 | 时间范围关闭，时间由峰谷平部件自管 |
| 1 | 用电量统计卡 | 24×2 | 今日 / 本月 / 今年 / 总 |
| 3 | 历史用电量详细（日历） | 12×6 | 6 周日历 + 图例，低于 6 行会被裁 |
| 3 | 用电量统计（柱线） | 12×6 | |
| 9 | 分项用电量对比（饼） | 12×6 | |
| 9 | 用电量排名 | 12×6 | |
| 15 | **峰谷平用电能耗统计** | 24×7 | 工具条 + 5 张档位卡 + 柱状图 |
| 22 | **功率因数与负荷需量** | 24×8 | 仪表盘 + 需量曲线 + 3 张指标卡 |

总 30 行 ≈ 2100px。改尺寸只改
`configuration.states.default.layouts.main.widgets`，**不要**去改
`configuration.widgets`（那里只有部件配置，没有尺寸）。

```sql
-- 核对布局（改完库要重启 energy-server，否则读到的是缓存）
SELECT jsonb_pretty((configuration::jsonb)->'states'->'default'->'layouts'->'main'->'gridSettings')
FROM dashboard WHERE title = '能耗概览';
```

> **同名的看板有两块**：`WHERE title='能耗概览'` 会更新**两行**
> （同一租户下新旧两个实例，`created_time` 不同）。这是预期的 —— 两块本来
> 就是同一个模板的副本。也正因如此，改看板时**别用 title 之外的模糊条件**，
> 更不要漏掉 `WHERE`：`dashboard.configuration` 是整份 JSON，误更新会把
> 别的看板覆盖成同一份布局。用 id 最稳 —— 先查出来，再用 id 更新：

```sql
SELECT id, title, created_time FROM dashboard WHERE title LIKE '%能耗%';
```


**看什么**：当前功率、今日电量、负荷率、三相电压电流。

**数据键**：

| 键 | 含义 | 聚合 |
| --- | --- | --- |
| `power_total` | 有功总功率（kW） | 瞬时值（取最新） |
| `energy` | 本小时用电量（kWh） | 求和 |
| `energy_day` | 当日累计电量 | 取最新 |
| `load_rate` | 负荷率（%） | 取最新 |
| `voltage_a/b/c`、`current_a/b/c` | 分相电压/电流 | 取最新 |

```sql
-- 某台设备最近 1 小时的关键指标（实时页的「当前值」）
SELECT kd.key AS 指标,
       to_char(to_timestamp(max(t.ts)/1000) AT TIME ZONE 'Asia/Shanghai','MM-DD HH24:MI:SS') AS 最新时间,
       (array_agg(coalesce(t.dbl_v, t.long_v) ORDER BY t.ts DESC))[1] AS 最新值
FROM ts_kv t
JOIN key_dictionary kd ON kd.key_id = t.key
WHERE t.entity_id = (SELECT id FROM device WHERE name = '单相园-1#进线总表·星河工业园')
  AND kd.key IN ('power_total','energy_day','load_rate','voltage_a','current_a')
  AND t.ts > (extract(epoch from now()) - 3600) * 1000
GROUP BY kd.key
ORDER BY kd.key;
```

**今日电量**（按东八区切天，不能用 UTC）：

```sql
SELECT round(sum(coalesce(t.dbl_v, t.long_v))::numeric, 2) AS 今日电量_kWh
FROM ts_kv t
JOIN key_dictionary kd ON kd.key_id = t.key
WHERE t.entity_id = (SELECT id FROM device WHERE name = '单相园-1#进线总表·星河工业园')
  AND kd.key = 'energy'
  AND t.ts >= (extract(epoch FROM date_trunc('day', now() AT TIME ZONE 'Asia/Shanghai')
                              AT TIME ZONE 'Asia/Shanghai') * 1000)::bigint
  AND t.ts % 3600000 = 0;        -- 只取整点，排除手工注入的测试点
-- 说明：ts_kv.ts 是 bigint 毫秒，比较前必须换算成毫秒数；
--       直接拿 timestamptz 比会报 bigint >= timestamp
```

**口径提示**：

- `energy` 是**本小时增量**，不是累积表底。求和得到区间电量。
- 切天必须用 `Asia/Shanghai`。按 UTC 切会把北京时间 08:00 之后算到前一天。
- 页面上的「实时值」是设备上报的瞬时量，不等于「区间累加」。

**⚠ 「能耗概览」的四张卡读的是资产，不是设备**

上面两条 SQL 查的是**设备**（单台表）。而概览页的
「今日 / 本月 / 今年 / 总用电量」四张卡，取数实体是**场站资产**，
键名也不同：

| 页面卡片 | 取数实体 | 键 | 聚合 |
| --- | --- | --- | --- |
| 今日用电量 | 场站 ASSET | `energy_total` | 按日 SUM |
| 本月用电量 | 场站 ASSET | `energy_total` | 按日 SUM 后累加 |
| 今年用电量 | 场站 ASSET | `energy_total` | 按日 SUM 后累加 |
| 总用电量 | 场站 ASSET | `energy_total` | 全部历史累加 |

```sql
-- 概览页「今日用电量」对应的公开 SQL（与部件同一口径）
-- 部件实际走 timeseries 接口按日聚合；这是一次性核对用的等价写法
SELECT round(sum(coalesce(t.dbl_v, t.long_v))::numeric, 2) AS 今日_场站合计_kWh
FROM ts_kv t
JOIN key_dictionary kd ON kd.key_id = t.key
WHERE t.entity_id = '<场站资产id>'
  AND kd.key = 'energy_total'
  AND t.ts >= (extract(epoch FROM date_trunc('day', now() AT TIME ZONE 'Asia/Shanghai')
                              AT TIME ZONE 'Asia/Shanghai') * 1000)::bigint;
```

资产上的 `energy_total` 由 `AssetTotalsScheduler` 每小时汇总一次
（设备 `energy` → 资产 `energy_total`）。设备有数但场站是 0，就是这一步没跑 ——
成因、SQL 与排查顺序见[⑦ 数据流第六节](/admin/data-pipeline)。

---

#### 两个统计部件（峰谷平 / 功率因数与负荷需量）

能耗概览底部的两块是**自绘 SVG 部件**，不引 ECharts（与其余 29 个部件同技术栈，
不增加打包体积、不受第三方版本约束）。

**峰谷平用电能耗统计**（`energy_management.tou_summary` → `GET /api/energy/tou-analysis`）

| 选中档位 | 横轴每根柱 | 接口 `granularity` | 横轴标签 |
| --- | --- | --- | --- |
| 按日 | 跨度里**每天一根**堆叠柱 | `day` | 「MM-DD」 |
| 按月 | 当月每天的合计 | `day` | 「MM-DD」 |
| 按年 | 每个自然月的合计 | `month` | 「M月」 |

> **按日改成「每天一根」而不是「每小时一根」（2026-10-27 客户定稿）**。
>
> 原来按日 = 每个小时一根（7 天 = 168 根）。这有三个问题：
> ① 标题写着「峰谷平用电能耗统计」，问的是「这几天每天用了多少尖/峰/平/谷电」，
>    逐小时柱回答的是另一个问题（电价时段落在哪几个小时）；
> ② 168 根柱在 24 列宽的部件里挤成一排牙签，看不出每天的构成；
> ③ 横轴标签只能每 20 根抽一个，得到 `01:00 / 21:00 / 17:00…` 这种跨天回绕的读法。
>
> 需要逐小时口径时看「峰谷分析」页 —— 那块专门做时段分析，标题也是这么写的。

档位卡的档名（尖/峰/平/谷/深谷）和颜色**来自接口返回的 `types`**，
按数量渲染 4 或 5 张，不在前端写死 —— 换了分时方案不用改代码。

**统计范围 = 全部可见场站，没有下拉（2026-10-27 定稿）**

峰谷平部件**不带任何统计范围下拉**。能耗概览本身不显示右上角场站选择器，
部件就把该客户权限内的**全部场站**一起统计，范围文字写明
「全部场站（N 个 · M 台表）」。

为什么不做「关口表 / 普通表」切换：分时电价方案挂在场站上，不同场站方案不同，
所以是**逐台表按自己场站的方案判档**，再汇总 —— 全站套一套方案才是错的。
多台表通过 `tou-analysis?devices=<id,id>` 传白名单：
不能只在前端筛，后端要按这些表的方案切档，否则会退回整棵子树（等于没筛）。

> 表清单与场站归属来自 `GET /api/energy/meters`（`meterLevel` / `siteId` 一次返回）。
> 为什么不用 Contains 关系自己算：`meterLevel` 存在 SERVER_SCOPE 属性里，
> 前端读不到；逐台问 `device-config` 要几十次往返（实测十几秒）。

**功率因数与负荷需量**（`energy_management.power_load`）

| 口径 | 算法 | 为什么 |
| --- | --- | --- |
| 平均功率因数 | `PF = ΣP / ΣS`（按视在功率加权） | 多表直接算术平均是错的：10kVA 与 1000kVA 的表不等权 |
| 容量 / 需量 | 每个桶**求和** | 取 MAX 会得到「最大那台表」的值；容量与需量必须同口径，负载率才有意义 |
| 负载率 | 只在配了铭牌容量时算 | 未配置时用「实测峰值视在功率」兜底显示容量，但**不**算负载率 —— 分母自证的比值必然在 100% 附近 |

数据键：`power_factor_total` / `power_total` / `apparent_power_total` / `demand_max`。
口径不符时（如某台表只有有功没有视在）退回算术平均，并在副标题标注。

**时间与范围（2026-10-27 定稿）**

三档都是**选一个具体的日 / 月 / 年**，不是滚动区间：

| 档位 | 选择器精度 | 统计区间 | 左面板标题 |
| --- | --- | --- | --- |
| 按日 | `date` → `2026-10-27` | 当天 00:00 ~ 23:59 | 平均功率因数 · 2026年10月27日 |
| 按月 | `month` → `2026-10` | 该月 1 日 ~ 月末 | 平均功率因数 · 2026年10月 |
| 按年 | `year` → `2026` | 1 月 1 日 ~ 12 月 31 日 | 平均功率因数 · 2026年 |

> 原来是「按日 = 近 7 天」「按月 = 近 12 个月」，页面上写着「按月」却看不出
> 是哪几个月，客户对不上账期。现在标题直接写清「哪个月的功率因数」。

**统计范围：两块面板各管各的（2026-10-27 定稿）**

| 面板 | 控件 | 下拉内容 |
| --- | --- | --- |
| 左「平均功率因数」 | `[按场站 \| 按关口表]` 单选开关 + 树形下拉 | 按场站 → 组织 → 场站；按关口表 → 场站 → 关口表 |
| 右「用电容量负荷需量监控」 | 只有树形下拉 | 全部关口表（N 台）/ 场站 → 该站关口表 |

四点设计约束：

- **两块不共用选择**。力率考核看某个站（或某台关口表），负荷曲线常要单看一台进线表，
  绑成一套会互相牵制 —— 左面板固定当月，右面板跟随日期选择，本来就已经是两个口径。
- **树里只出现关口表**（`meterLevel=1`）。回路表常带照明、插座的低功率因数，
  混进来会把加权值拉偏。
- **都是单选**。功率因数与需量在物理上是一个数，多选没有意义。
- **默认值**：左 = 第一个场站（不是组织，否则一上来就把多站加权，用户看着 0.92
  不知道是哪儿的）；右 = 全部关口表。

> 顶栏不再放统计范围控件，只显示一行汇总：
> `功率因数：单相场站（1 台关口表） ｜ 需量：全部关口表（2 台）`。
> 顶栏的场站/树节点因此**不再影响**本部件 —— 与其它报表页不同，见
> [用户手册 · 先看右上角的场站](/user/pages)。

**工具条里的日期选择器与其它部件同一规格**：30px 高、`yyyy-MM-dd`、图标 18px。
样式写在 `templateHtml` 的 `<style>` 里（原因见
[时间范围的日期选择器](#时间范围的日期选择器) 里的 `templateCss` 说明）。


**布局（2026-10-26）**：

```
查询设置 7×15  │  查询结果 17×15（内部三个选项卡）
```

右侧原来有三个独立部件（最大值/最小值 3 行 + 统计分析 5 行 + 数据表详情 7 行），
纵向把图表压到 5 行。现在合并成一个 `timeseries_chart`，用 `viewTabs=true`
打开文字选项卡（选项卡规格见 3.0.5）：

| 选项卡 | 内容 |
| --- | --- |
| **最大值最小值** | 设备 / 参数 / 最大值 / 最大值时间 / 最小值 / 最小值时间；**设备列 rowspan 跨行** |
| **数据折线图** | 折线图 + 图上极值标注 + Y 轴 6 档网格 |
| **数据表详情** | 左侧固定两列（设备 rowspan + 参数）+ 右侧横向滚动时间列 + 底部分页 |

顺序与默认项对齐设计图：**默认落「最大值最小值」**（第一个）。

三块共用同一份数据（`allSeries[].pts`），切换不重新取数 —— 极值表与折线图的
标注必然一致（实测 `203.7 / 20.1` 两处相同）。

**部件标题是「查询结果」**，不是「统计分析」—— 三个选项卡里有两个根本不是统计图，
标题叫"统计分析"会让人以为只有第一个选项卡是对的。
`config.title` 与 `config.settings.title` 两处都要改（前者是部件头，后者是设置里的默认值）。

**副标题那行去掉了**。原来图表上方有
`2026-10-20 ~ 2026-10-26相电流报表折线图 · 4 条序列`——
查询条件在左侧「查询设置」里已经写明一次，这里再写一次属于重复，
而且把选项卡往下挤。模板里用 `*ngIf="lineCount && !viewTabs"` 排除历史能耗；
其它看板没有选项卡，那行是唯一的说明文字，保留。

**最大值最小值表：设备列 rowspan**

```html
<tr *ngFor="let r of extremaRows"
    [class.tb-group-start]="r.deviceSpan > 0 && r.deviceGroupIdx > 0">
  <td class="tb-name" *ngIf="r.deviceSpan > 0" [attr.rowspan]="r.deviceSpan">{{ r.deviceName }}</td>
  ...
```

`deviceSpan === 0` 表示"被上一行跨过"，**不输出 `<td>`** —— 输出空单元格会多出一列，
表格宽度和边框全部错开。`deviceGroupIdx` 是本页第几组，用来给非首组加段间分隔线
（同名的两台设备被切成两段时不会连在一起）。

无数据写 `/`（不是空白，也不是 `-`），时间是完整 `YYYY-MM-DD HH:mm:ss`。

**数据表详情：5 分钟列 + 冻结列 + 横向滚动 + 分页**

行 = **设备 × 参数 × 日期**（三个维度各自 rowspan 跨行），
列 = 当天的 **288 个 5 分钟**（`00:00` / `00:05` … `23:55`）。
一天一行、288 格 —— 看某天几点最高最直观。

> 不是 24 个小时列。用户口径（2026-10-26）：「每天的列间隔是 5 分钟，不是 1 小时」，
> 与设计图一致（原型 `for (h<24) for (m+=5)` 生成 288 列，`.col-time` 宽 60px）。

**取数要按天切块，不能一次要完整区间。**

服务端 `ts_max_intervals` 默认 700，5 分钟 × 700 ≈ 2.4 天。
查 7 天直接超限被拒（报错还是英文的）。所以：

```js
var DETAIL_STEP  = 5 * 60000;      // 5 分钟
var DETAIL_CHUNK = 2 * GRAIN_DAY;  // 2 天 ≈ 576 点 < 700
var DETAIL_MAX_REQ = 80;           // 总请求数预算

// 逐块请求，本地 concat 合并（不能赋值覆盖，否则只剩最后一块）
grab(detailStep, detailRaw, chunk.fromTs, chunk.toTs);
```

- 按 **2 天一块**：7 天 = 4 块。逐天切会让请求数轻易上百；
- 请求数超预算（`块数 × 设备数 × 参数组数 > 80`）时**主动退化回 1 小时**，
  并置 `scope.detailStep = 3600000`，模板给出一行说明；
- 跨度大到连按小时都取不了（`detailStep = 0`）时，时间列全空并说明原因 ——
  总比整张表空白强。

**槽位映射**（`detailSlotOf` / `detailSlotLabel`）：

```
5 分钟 → 288 槽，槽位 = 小时 × 12 + 分钟 / 5，标签 00:00 / 00:05 …
1 小时 →  24 槽，槽位 = 小时，            标签 00:00 / 01:00 …
```

分块边界按毫秒切、不一定对齐整 5 分钟，同一个槽位可能被切到两块里 ——
所以合并时用「同一槽位取平均」而不是后到覆盖，否则边界那一格会丢数据。

**冻结列 + 横向滚动 + 分页**

前三列（设备 / 参数 / 日期）用 `position: sticky` 冻结，宽度**必须写死**：

```css
.eqc-table-detail .eqc-th-dev,  .eqc-table-detail .eqc-td-dev   { left: 0;     width: 160px; }
.eqc-table-detail .eqc-th-param,.eqc-table-detail .eqc-td-param { left: 160px; width: 132px; }
.eqc-table-detail .eqc-th-date, .eqc-table-detail .eqc-td-date  { left: 292px; width: 104px; }
```

sticky 的 `left` 偏移必须**等于前一列的实际宽度**（160 / 160+132=292）。
写成 `min-width` 时浏览器按内容撑开，偏移量却还是写死的 160px，
于是参数列直接压到数据列上（实测：`…功功率` 与 `203.0` 重叠成一坨）。

底部分页：`‹ 1 2 3 ›` + `共 N 条` + `10/20/50 条/页`。
**rowspan 必须在页内重算** —— 跨页不能继承上一页的合并格，否则第一页末尾的设备
会在第二页顶部凭空少一行；`deviceGroupIdx` 同理，否则第二页第一组会缺分隔线。

**数据折线图：Y 轴 6 档网格**

`buildYTicks(vmin, vmax, 5)` 把数据上下界向外扩到整齐步长的整数倍，
再切 5 段出 6 条线（设计图是 `250/200/150/100/50/0`）。曲线仍按真实值绘制，
只是坐标系多留一点余量 —— 这也是 ECharts / TB 原生图表的默认行为。
直接用 `20.1 / 203.7` 当上下界会得到零碎刻度，读数困难。

```js
niceStep(raw)   // 1 / 2 / 2.5 / 5 / 10 × 10^n，保证步长是人能心算的数
snap(step)      // 把 lo/hi 对齐到 step 的整数倍，并算段数
while (count < 4)  { step /= 2; }   // 数据恰好落在整格上时段数会偏少
while (count > 10) { step *= 2; }   // 跨度过大时防止密密麻麻
```

**刻度标签与网格线必须用同一个映射**，都带上绘图区的 `PAD` 内边距：

```js
pct = (PAD + (vmax - v) / (vmax - vmin) * (H - 2 * PAD)) / H * 100
```

刻度容器（`.eqc-ylabels-inner`）的高度还要扣掉 X 轴标签 18px 与缩放条 30px
（`margin-bottom: 48px`）。SVG 只占 `.eqc-plot` 的一部分，刻度若按整个 plot
高度算百分比，最下面那一档会掉到 X 轴标签上。

刻度文案用 `fmtTick`（整数不带 `.0`），不是 `fmtNum` —— 设计图是 `250` 不是 `250.0`。

`viewTabs` 默认 `false`，只有历史能耗打开；其它用 `timeseries_chart` 的看板
（基础报表 / 参数报表 / 手工填报）仍是右上角的两个图标切换。

**查询设置的三处锁定**（对齐设计图，实测 2026-10-26）：

| 设置 | 值 | 效果 |
| --- | --- | --- |
| `fixedRangeOnly` | `true` | 隐藏「实时/历史」与「按日/按月/按年」，只留起止两个日期框；档位固定 `day` |
| `defaultRangeDays` | `7` | 默认最近 7 天 |
| `showDimension` | `false` | 隐藏维度单选，**固定按场站下的设备层级** |
| `defaultParamCode` | `16` | 默认「有功功率」 |
| `multiParam` | `false` | 参数单选（只选一级参数） |
| `labelParam` / `labelTime` | `选择参数` / `选择时间` | 文案对齐设计图 |

`fixedRangeOnly` 的横轴粒度仍按跨度自动定（`grainOfRange`）：
≤1 天→时 / ≤62 天→天 / 更长→月。所以「按日/按月/按年」按钮虽被隐藏，
出数粒度并不会退化成单一档。

**`showDimension=false` 现在等于「锁定按设备层级」**（2026-10-26 加的护栏）：

```js
// buildDimensions() 末尾
if (!scope.showDimension) { scope.dimension = 'device'; }
// onDimensionChange() 开头
if (!scope.showDimension) { return; }
```

隐藏了单选按钮却仍允许 `dimension` 停在某个分组维度，是自相矛盾的：
用户看不到当前是哪个维度，树却按分组渲染 —— 报表板面会莫名其妙变成
「按分项而不是按设备」出数。所以关闭即锁定。

> 参数报表、手工填报也是 `showDimension=false`，行为一致（本来就期望按设备层级）。

**一级参数 → 二级指标展开**：

选「有功功率」（`code=16`）后，`timeseries_chart` 按 `paramSeries` 展开该参数的全部
`children`：`power_a` / `power_b` / `power_c` / `power_total` → A/B/C 相 + 总有功功率。
单相表只有 `power_a` / `power_total`（本来没有 B/C 相），所以只出两条线 ——
不是丢数据。同理相电压、相电流、无功功率、视在功率、功率因数都是 3+1 展开。

**查询设置宽度**：所有含该部件的看板都是 `sizeX=7`（原 6），
同排右侧部件左移 1 列、收窄 1 列（`col=7 / sizeX=17`）。
左右内边距 `12px / 22px` —— 右边略大于左边，首行 `.eqp-head` 再留 26px 避开
TB 部件右上角的操作按钮。

**看什么**：任意时间段内的电量趋势（小时/日/月粒度）。

```sql
-- 按日汇总某设备一个月的电量
SELECT to_char(to_timestamp(t.ts/1000) AT TIME ZONE 'Asia/Shanghai','YYYY-MM-DD') AS 日期,
       round(sum(coalesce(t.dbl_v, t.long_v))::numeric, 3) AS 电量
FROM ts_kv t
JOIN key_dictionary kd ON kd.key_id = t.key
WHERE t.entity_id = (SELECT id FROM device WHERE name = '单相园-1#进线总表·星河工业园')
  AND kd.key = 'energy'
  AND t.ts >= 1790784000000 AND t.ts < 1793462400000   -- 2026-10 全月
  AND t.ts % 3600000 = 0
GROUP BY 1 ORDER BY 1;
```

**口径提示**：区间上界用 `<`，不要用 `<=` —— `energy[t]` 覆盖 `(t−1h, t]`，
含上界会把下个账期第一个小时算进来。

---

### 3.3 抄表功能（抄表台账 / 记录 / 现场补抄）

**看什么**：每台表的本期表底、上期表底、用量、抄表质量。

**核心表**：`meter_reading_record`（按月分区）

```sql
-- 本账期每台表的账期累计用量（台账页的「用量」列）
WITH rec AS (
    SELECT r.* FROM meter_reading_record r
    WHERE r.tenant_id = '<租户id>' AND r.period = '2026-10'
      AND (r.quality <> 'abnormal' OR r.curr_reading IS NOT NULL)
), agg AS (
    SELECT device_id,
           max(CASE WHEN rn_first = 1
                    THEN coalesce(prev_reading, curr_reading) END) AS 期初表底,
           max(CASE WHEN rn_last  = 1 THEN curr_reading END)       AS 期末表底,
           max(ratio) AS 倍率
    FROM (
        SELECT r.*,
               row_number() OVER (PARTITION BY r.device_id ORDER BY r.created_time ASC)  AS rn_first,
               row_number() OVER (PARTITION BY r.device_id ORDER BY r.created_time DESC) AS rn_last
        FROM rec r WHERE r.curr_reading IS NOT NULL
    ) t GROUP BY device_id
)
SELECT (SELECT name FROM device WHERE id = a.device_id) AS 设备,
       期初表底, 期末表底, 倍率,
       round(((期末表底 - 期初表底) * coalesce(倍率,1))::numeric, 4) AS 用量
FROM agg a ORDER BY 设备;
```

**口径提示（最容易搞错的一条）**：

台账用量 = **期末表底 − 期初表底**，不是「最后一次抄表的 usage 增量」。

现场一个月会抄多次（建基线 / 月中核对 / 月末出账）。取「最新一条的 usage」
在月末那次没有新增读数时就会显示 0 —— 实测踩过：实际用了 94.575 kWh，台账报 0。

`DISTINCT ON (device_id) ORDER BY created_time DESC` 取的是「最新一条记录」，
不是「账期累计」。要累计就必须像上面这样算首末差。

**现场补抄的三个字段**：

| 字段 | 含义 |
| --- | --- |
| `field_status` | `pending`（待审）/ `approved` / `rejected` |
| `field_value` | 现场抄回的表底 |
| `field_note` | 现场备注（表位、异常情况） |

```sql
-- 待审的现场补抄
SELECT to_char(to_timestamp(reading_time/1000) AT TIME ZONE 'Asia/Shanghai','MM-DD HH24:MI') AS 抄表时间,
       device_name AS 设备, field_value AS 现场表底, field_note AS 备注
FROM meter_reading_record
WHERE tenant_id = '<租户id>' AND field_status = 'pending'
ORDER BY reading_time DESC;
```

---

### 3.4 峰谷分析

**看什么**：尖 / 峰 / 平 / 谷 / 深谷 五档电量，逐小时或逐日。

**数据链路**（三层，逐层可验证）：

```
① ts_kv       energy_reading（累积表底，每小时一个点）
      ↓  HOUR + MAX 聚合（TB 内部）
② 小时表底    bucket_center_ms → reading
      ↓  相邻两点求差 × 倍率
③ 逐小时用量  inc × ratio → usage
      ↓  按 tou_scheme 判档
④ 五档合计    Σ = 总量
```

```sql
-- ① 原始小时表底
SELECT entity_id,
       (ts / 3600000) * 3600000 + 1800000 AS 桶中心ms,
       max(coalesce(dbl_v, long_v))       AS 表底
FROM ts_kv
WHERE entity_id = '<设备id>'
  AND key = (SELECT key_id FROM key_dictionary WHERE key = 'energy_reading')
  AND ts > 1792465033230 AND ts <= 1792727833230
GROUP BY entity_id, ts / 3600000
ORDER BY 桶中心ms;

-- ②③ 逐小时用量 + 区间两个口径
WITH pts AS (
    SELECT entity_id,
           (ts / 3600000) * 3600000 + 1800000 AS bucket_center_ms,
           max(coalesce(dbl_v, long_v))       AS reading
    FROM ts_kv
    WHERE entity_id = '<设备id>'
      AND key = (SELECT key_id FROM key_dictionary WHERE key = 'energy_reading')
      AND ts > 1792465033230 AND ts <= 1792727833230
    GROUP BY entity_id, ts / 3600000
), diff AS (
    SELECT entity_id, bucket_center_ms, reading,
           reading - lag(reading) OVER (PARTITION BY entity_id ORDER BY bucket_center_ms) AS inc
    FROM pts
)
SELECT count(*) AS 点数,
       min(reading) AS 首表底, max(reading) AS 末表底,
       round(((max(reading) - min(reading)) * 1)::numeric, 4)                     AS 首末差_台账口径,
       round((sum(CASE WHEN inc >= 0 THEN inc ELSE 0 END) * 1)::numeric, 4)       AS 正增量累加_页面口径,
       count(*) FILTER (WHERE inc < 0)                                            AS 倒走段数
FROM diff GROUP BY entity_id;
```

**口径提示（关键）**：

1. **桶中心**：TB 小时聚合返回桶中心（整点数据 → `:30`）。
   所以桶时间要还原成 `(ts/3600000)*3600000 + 1800000`，否则边界判断会错半小时。
2. **上界 `+1ms`**：TB 的区间是左闭右开，`<= to` 要写 `to + 1`，
   否则 `to` 那一刻的点取不回来 —— 每天少 1/24。
3. **两个口径不等是正常的**：表底倒走（换表/归零/报错值）时，
   `首末差 > 正增量累加`。页面 `backwardSegments > 0` 就说明有跳过。
4. **五档怎么判**：`tou_scheme` 存在租户级资产上，Java 按时段定义判档，
   SQL 给不出 —— 但 `Σ各档 == 总量` 一定成立，可用上面的总量反验。

---

### 3.5 分项能耗 / 区域能耗

**看什么**：按「用能分项」或「用能区域」聚合电量。

**两页的查询口径完全一致，只有分组维度不同**

```
分析条件（analysis_bar）  电能品种 + 场站/全部 + 按日/按月/按年 + 起止日期
统计图（asset_stats_chart）  堆叠柱：按日=小时柱 / 按月=天柱 / 按年=月柱
分布（distribution_chart）   环形图 + 图例（label）
排名（ranking_list）        分项页 1 个（设备）；区域页 2 个（区域 / 单元）
```

**「实时 / 历史」切换默认隐藏，且隐藏时一律按历史走。**

这两页回答的是「这段时间各分项用了多少」，天生是区间对比。多一个「实时」页签，
用户点进去只会看到一段刚过去几分钟的曲线，与下面按日/按月/按年的档位互相矛盾
（档位写着「按日」，横轴却只有 10 分钟）。

隐藏不是靠 CSS，而是初始化时就把 `timeMode` 钉死成 `history`：

```js
scope.showTimeMode = settings.showTimeMode === true;
scope.timeMode = (scope.showTimeMode && settings.timeMode === 'realtime') ? 'realtime' : 'history';
```

> **为什么不能只用 `*ngIf` 藏起来**：那样 `timeMode` 仍可能被
> `settings.timeMode` 设成 `realtime`，界面上却没有开关能改回来 ——
> 板面会永久停在实时窗口，而且从界面上找不到原因。
> 开关和取值必须在同一处判断。

实时模式本身没删，只是不再默认出现。现场调试要看「设备有没有在报数」时，
把部件的 `showTimeMode`（【外观】→「显示实时/历史切换」）打开即可。

> **`showTimeMode` 只在 `showTimeRange=true` 时可见。** 模板结构是
> `<div class="eqab-right" *ngIf="showTimeRange">` 里再套
> `<ul class="eqab-modes" *ngIf="showTimeMode">` —— 整块时间控件（实时/历史 +
> 档位 + 日期）都在 `eqab-right` 里。
> 「能耗概览」「综合能耗」两块看板配的是 `showTimeRange=false`，
> 它们的分析条件只有品种与场站，本来就不显示实时/历史（不是这次改出来的）。

配置差异**只有一处**：`analysis_bar.settings.siteChildType`
（分项页 `分项`、区域页 `区域`）。其余部件的 `metricKey` / `agg` / 几何必须相同 ——
两页画出来的形状才会是「同一批数据、不同分组」，而不是两套逻辑。

范围上限、粒度、分段取数、月汇总点摊平的规则见 [3.0.3](#303-图表部件的两种形态与统一规格) 的
「时间粒度与范围上限」。

**实测（2026-10-26，演示客户 · 平台演示中心 · 09-01~09-30）**

```
分项能耗   6 条序列（照明/插座/空调/炊事/给排水/蒸汽）  合计 5781.48 kW·h
           4320 根柱 = 6 × 720，Y 轴 10.5（小时合计）
区域能耗   2 条序列（公共区域/A栋办公区）              合计 6370.58 kW·h
           1440 根柱 = 2 × 720，Y 轴 12.5
```

两页总量不等是正常的：分项是「按用途切」、区域是「按位置切」，
同一度电可以同时属于某个分项和某个区域，但两套切法的覆盖面不同
（演示数据里区域分到的是场站下的回路设备，分项分到的是分项汇总表）。

> ⚠ **这两页必须显示不同数据。** 如果两页的图例和图完全一样
> （都是「照明 插座 炊事 … A栋办公区 食堂」这种混在一起），
> 说明踩了三个坑之一，按顺序查：
>
> **① 演示数据只建了「分项」一条分类线**
> 「用能区域」维度下只有空的场站容器，0 个区域节点。
> 查：`SELECT count(*) FROM asset WHERE type='区域' AND customer_id='<客户id>';`
> 修：重跑 `POST /api/energy/demo-data`（会调 `backfillDemoAreas` 补齐）。
>
> **② `siteChildType` 没配**
> 场站的 Contains 里同时有分项和区域，不配置就会把两套混在一起。
> 修：分项能耗配 `siteChildType: "分项"`，区域能耗配 `"区域"`
> （`analysis_bar` 的【外观】→「场站下的子节点类型」）。
> 结果部件靠 state 里的 `childType` 同步剪枝，所以要连模板一起推、刷客户副本。
>
> **③ 区域资产没有汇总遥测**
> 图例只显示**有 data 的序列**。区域没有 `energy_total` 时一条都画不出来，
> 页面看起来还是分项的数据。查：
> `SELECT a.label, count(*) FROM asset a JOIN ts_kv kv ON kv.entity_id=a.id WHERE a.type='区域' GROUP BY 1;`
> 修：`POST /api/energy/asset-totals/rebuild`（要**客户身份**，会写自己域内资产）。
>
> 正确形态（2026-10-26 实测，演示客户本月）：
>
> ```
> 分项能耗   7 条序列   总 4.58 kW·h   照明分项总表 / A栋照明回路 / 插座分项总表 …
> 区域能耗   3 条序列   总 4.58 kW·h   公共区域 2.21 / A栋办公区 1.92 / 食堂 0.45
> ```
>
> 总量一致（同一批设备的不同分组方式），明细完全不同。
> 详见 `03-init.md` 的「用能维度：分项 / 区域 / 性质 / 位置 各自独立」。

**分组靠 `relation` 表（Contains 关系）**：

```sql
-- 某场站下每台设备的电量合计
SELECT d.name AS 设备,
       round(sum(coalesce(t.dbl_v, t.long_v))::numeric, 3) AS 电量
FROM ts_kv t
JOIN key_dictionary kd ON kd.key_id = t.key
JOIN device d ON d.id = t.entity_id
WHERE kd.key = 'energy'
  AND d.additional_info::jsonb->>'siteId' = '<场站资产id>'
  AND t.ts >= 1790784000000 AND t.ts < 1793462400000
  AND t.ts % 3600000 = 0
GROUP BY d.name ORDER BY 电量 DESC;
```

**设备属于哪个场站**：`device.additional_info ->> 'siteId'`（不是 relation！）

```sql
-- 列出某客户全部设备及其场站
SELECT d.name AS 设备, d.label AS 显示名,
       a.name AS 场站, d.additional_info::jsonb->>'siteId' AS 场站id
FROM device d
LEFT JOIN asset a ON a.id = (d.additional_info::jsonb->>'siteId')::uuid
WHERE d.customer_id = '<客户id>'
ORDER BY 1;
```

**口径提示**：分项/区域聚合时，如果该分项里有「总表 + 分表」父子关系，
直接 `sum` 会把同一度电算两遍。

#### 关口表口径（2026-10-26 定稿，方案 A）

**规则一句话：合计 = 关口表之和；关口表下面的普通表一分都不加。**

判定「关口表」的判据是**拓扑**，不是层级数字：

```
关口表 = 在本子树范围内没有上级表的表
       （parentDeviceId 为空，或它的父表不在这棵子树里）
普通表 = 父表也在这棵子树里的表 → 只列明细，不进合计
```

为什么不能看 `meterLevel`：层级是人工填的档案字段，会出现「总表和分项总表都填成 2 级」
或漏填；而 `parentDeviceId`（同时双写 `DEVICE --Contains--> DEVICE`）是物理接线，
判得出同级的父子。

**实测（演示客户 · 单相园 · 10-26 当天）**

```
关口表（不重复计量，参与合计）
  单相园-1#进线总表      107.84 kW·h
  单相园-食堂燃气表       24.76 m³
  单相园-生活水表          2.97 m³
  单相园-食堂蒸汽表        1.97 t
普通表（下级表计，仅列明细不参与合计）
  单相园-照明分项总表     55.32 kW·h
  单相园-插座分项总表     49.90 kW·h
  单相园-A栋照明回路      49.31 kW·h
  单相园-A栋插座回路      44.47 kW·h

副标题：共 8 项 · 关口表合计 107.84 kW·h · 燃气 24.76 m³ · 水 2.97 m³ · 蒸汽 1.97 t
```

注意三点：

- 合计 **107.84** 就是进线读数。若把下面四行加上会变成 306.24 —— 同一度电算了两遍。
- **跨品种不混算**：水的 m³、燃气的 m³、蒸汽的 t 各自成句附在后面，不进电的合计。
- 每行按自己的品种显示单位，不会出现「24.76 kW·h 的燃气」。

**后端也按同一口径写资产汇总**

`EnergyBootstrapInstaller.writeAssetTotal` 对每个资产节点按 `parentDeviceId`
取拓扑根再求和；并且**先清窗口内旧值再写**（口径变化后旧值必须失效）。
品种来自设备档案，缺失时才查一次，绝不默认按电处理 ——
旧实现默认 `elec`，把燃气/水/蒸汽用量写进了 `energy_total`，
导致「炊事」分项显示 24.76 kW·h、环形图把 m³ 和 kW·h 加在一起。

**区域必须互斥**

区域是空间分区，同一层的区域之间不能重叠。演示数据里区域**只挂叶子表**，
进线总表 / 分项总表留在场站层：

```
三相园   办公区 7495.96 + 生产车间 120567.18 = 128063.14  ≤  场站 146092.59
单相园   A栋办公区 2962.99                                ≤  场站   3407.59
```

差值就是公共用电 / 线损 —— 这才是真实的分区能耗。
如果把进线总表也挂到某个区域，那个区域就等于整个场站，
再和别的区域并列相加，同一度电又要算两遍。

**环形图按同一层取扇区**

分布图不再「从根一路下钻到叶子」，而是定位到**同一维度层**的节点，
读这些节点自身已经汇总好的量：

```
概览页      siteChildType=分项   → 动力 / 三相园·照明 / 单相园·照明 / 插座
分项能耗页  跟随分析条件         → 照明 55.32 + 插座 49.90 = 105.22
区域能耗页  跟随分析条件         → A栋办公区 93.78
```

旧实现会把「区域资产 + 分项资产 + 分项下的设备」混在一张图里相加，
总计 9998.80 这种数字没有任何业务含义。同名分项（两个场站都有「照明」）
现在会自动补场站前缀，不会出现两行一模一样的名字。

> ⚠ **已知限制**：`meters` / `devices` 两种排名模式在分析范围选「全部」时
> 可能显示空态 —— 剪枝发生在根的直接子节点这一层，而「全部」的子节点是
> 「场站分组」，类型既不等于「分项」也不等于「区域」。
> 先在分析条件里选到具体的分项 / 区域节点即可正常出数。
> 这是一处待修的既有缺陷（2026-10-26 记录）。

---

### 3.6 我的账单

**看什么**：每台表一张账单，含四项费用与合计。

```sql
-- 客户某账期的全部账单（逐张，金额 = 四项之和）
WITH bill AS (
    SELECT a.id, a.name,
           max(CASE WHEN kd.key='deviceName'  THEN ak.str_v END) AS 设备,
           max(CASE WHEN kd.key='energy'      THEN ak.str_v END) AS 品种,
           max(CASE WHEN kd.key='status'      THEN ak.str_v END) AS 状态,
           max(CASE WHEN kd.key='usageSource' THEN ak.str_v END) AS 用量来源,
           max(CASE WHEN kd.key='meterLevel'  THEN coalesce(ak.dbl_v, ak.str_v::numeric) END) AS 层级,
           max(CASE WHEN kd.key='usage'       THEN coalesce(ak.dbl_v, ak.str_v::numeric) END) AS 用量,
           max(CASE WHEN kd.key='energyFee'   THEN coalesce(ak.dbl_v, ak.str_v::numeric) END) AS 电度费,
           max(CASE WHEN kd.key='basicFee'    THEN coalesce(ak.dbl_v, ak.str_v::numeric) END) AS 基本费,
           max(CASE WHEN kd.key='powerFactorFee' THEN coalesce(ak.dbl_v, ak.str_v::numeric) END) AS 力调费,
           max(CASE WHEN kd.key='surchargeFee' THEN coalesce(ak.dbl_v, ak.str_v::numeric) END) AS 附加费,
           max(CASE WHEN kd.key='amount'      THEN coalesce(ak.dbl_v, ak.str_v::numeric) END) AS 合计
    FROM asset a
    JOIN attribute_kv ak ON ak.entity_id = a.id AND ak.attribute_type = 2
    JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
    WHERE a.type = 'energy_bill'
      AND a.tenant_id = '<租户id>'
      AND a.name LIKE 'BILL-%2026-10%'
    GROUP BY a.id, a.name
)
SELECT 设备, 品种, 状态, 用量来源, 层级, 用量,
       电度费, 基本费, 力调费, 附加费, 合计,
       round((coalesce(电度费,0)+coalesce(基本费,0)
              +coalesce(力调费,0)+coalesce(附加费,0))::numeric, 2) AS 四项和
FROM bill ORDER BY 品种, 设备;

-- 汇总（对应页头三个数）
WITH bill AS (
    SELECT a.id,
           max(CASE WHEN kd.key='energy'     THEN ak.str_v END) AS energy,
           max(CASE WHEN kd.key='meterLevel' THEN coalesce(ak.dbl_v, ak.str_v::numeric) END) AS lvl,
           max(CASE WHEN kd.key='amount'     THEN coalesce(ak.dbl_v, ak.str_v::numeric) END) AS amount
    FROM asset a
    JOIN attribute_kv ak ON ak.entity_id = a.id AND ak.attribute_type = 2
    JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
    WHERE a.type = 'energy_bill' AND a.tenant_id = '<租户id>'
      AND a.name LIKE 'BILL-%2026-10%'
    GROUP BY a.id
), top AS (
    SELECT DISTINCT energy FROM bill WHERE lvl = 1
)
SELECT count(*) AS 账单数,
       round(sum(CASE WHEN b.lvl = 1 OR t.energy IS NULL THEN b.amount ELSE 0 END)::numeric, 2) AS 应付_进线口径,
       round(sum(b.amount)::numeric, 2)                                                        AS 全表合计
FROM bill b LEFT JOIN top t ON t.energy = b.energy;
```

**口径提示**：

- `合计 = 电度费 + 基本费 + 力调费 + 附加费`，四个字段和必须相等（差 0.01 是舍入）。
- **基本电费/力调电费只算进线总表（`meterLevel=1`）**。11 台表各收 1600 元会高一个数量级。
- **应付 ≠ 全表合计**：同一品种里有进线总表时，只汇总进线（否则总表含的分表被再加一遍）。
  没有进线总表的品种（水/气/汽全是 level 0）按全部表汇总。
- 金额类属性存在 `str_v`，不是 `dbl_v` —— 只读 `dbl_v` 会全是 NULL。

---

### 3.7 一级 / 二级 / 三级计量（`meterLevel`）

**这是「数据准不准」的根基**，单列一节说清楚。

| `meterLevel` | 含义 | 在统计里的作用 |
| --- | --- | --- |
| 1 | 进线总表（关口表） | 站点级费用（基本电费/力调）只算它；同品种汇总只算它 |
| 2 | 分项总表 | 参与明细，不参与「应付」汇总（有 level 1 时） |
| 3 | 回路（末端） | 同上 |
| 0 / 未设置 | 未声明 | 不参与分层 —— 全部相加（可能虚高） |

**存储位置**：`device` 的 SERVER_SCOPE 属性 `meterLevel`

```sql
-- 看全租户设备的计量层级
SELECT d.name AS 设备,
       (SELECT coalesce(ak.dbl_v, ak.long_v, ak.str_v::numeric)
          FROM attribute_kv ak JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
         WHERE ak.entity_id = d.id AND ak.attribute_type = 2 AND kd.key = 'meterLevel') AS 层级,
       d.additional_info::jsonb->>'siteId' AS 场站id
FROM device d
WHERE d.tenant_id = '<租户id>'
ORDER BY 层级 NULLS LAST, 设备;
```

**校验层级守恒**（父表电量 ≥ 子表之和，差额 = 线损 + 未装表）：

```sql
-- 按 Contains 关系找父子对，比较区间增量
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
      AND t.ts >= 1790784000000 AND t.ts < 1793462400000
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

> 演示数据的差额严格等于「线损 + 未装表」系数（如 ×1.025）。
> 差额为**负数**说明父子关系配错了，或某台表被重复计算。

**配置入口**：

```bash
GET  /api/energy/device-config?deviceId=<id>    # 读层级 + 倍率
POST /api/energy/device-config                  # 写
  {"deviceId":"...","meterLevel":1,
   "ctRatio":"200/5","ptRatio":"10000/100","ratioApplied":false}
```

也就在「组织与场站 → 选中场站 → 设备面板」里可视化编辑。

---

### 3.8 手工填报（虚拟表）

**看什么**：没装表的分项（空调、其他水表），按月人工填一个总量。

**看板由三个 TB 原生部件组成**（2026-10-26 拆的，与其它 13 个报表看板同构）：

| 位置 | 部件 | 职责 |
| --- | --- | --- |
| 左 6×11 | `energy_management.query_panel` | 选设备 / 指标 / 时间 |
| 右上 18×7 | `energy_management.timeseries_chart` | 折线图 + 数据表（同一部件内切换） |
| 右下 18×4 | `energy_management.manual_entry` | 「用能数据录入」按钮 + 右侧抽屉 |

拆之前是一个 `manual_entry` 包办三者：查询设置自绘一套、折线图也自绘一套，
于是同类系统里出现两套查询样式、两份图案，而且手工填报的图没有图例开关 / tooltip /
图表-表格切换 / 缩放条（`timeseries_chart` 全都有）。

**查询设置的两个专用开关**（都只在这个看板打开）：

| 设置 | 值 | 为什么 |
| --- | --- | --- |
| `virtualOnly` | `true` | 设备树只列 `additionalInfo.deviceVirtual='virtual'` 的表。默认 `false`，其它看板不受影响 |
| `defaultCurrentYear` | `true` | 时间默认「今年 1/1 ~ 12/31」+ 粒度「按年」。默认 `false` |

`virtualOnly` 打开时**同时跳过品种过滤**（`inSourceProfiles` 直接返回 true）：
虚拟表跨品种，而三相场站唯一的虚拟表是水表 —— 若还按「电能」筛，树是空的。
品种下拉也一并隐藏（`showKind=false`），留着只会误导。

**只对虚拟表开放**（三道门，缺一不可）：

1. 前端设备树：`virtualOnly` 过滤（见上）
2. 后端元数据：`/api/energy/manual-entry/meta` 只返回 `MeteringMath.isVirtual(Device)` 为真的设备
3. 后端保存：`/api/energy/manual-entry/save` 再校验一次，非虚拟设备返回 400

前两道只是体验，**第三道才是门闩** —— 否则改个请求就能写脏数据。

**时间粒度**：`query_panel` 按跨度自动定档（>31 天 → 月）。月度数据在
`timeseries_chart` 里用「日桶 + 前端按自然月归并」的方式取，横轴才是真正的
`2026-01` / `2026-02`。直接给服务端 30 天桶会串月（实测 2 月变 2630、3 月丢失）。

**存储**：写在 `energy` 键的**月首 00:00** 这一个点上（整月总量，不是小时增量）。

```sql
-- 某虚拟表本年各月的填报值
SELECT to_char(to_timestamp(t.ts/1000) AT TIME ZONE 'Asia/Shanghai','YYYY-MM') AS 月份,
       coalesce(t.dbl_v, t.long_v) AS 填报用量
FROM ts_kv t
WHERE t.entity_id = '<虚拟表设备id>'
  AND t.key = (SELECT key_id FROM key_dictionary WHERE key = 'energy')
  AND extract(day from to_timestamp(t.ts/1000) AT TIME ZONE 'Asia/Shanghai') = 1
  AND to_char(to_timestamp(t.ts/1000) AT TIME ZONE 'Asia/Shanghai','HH24:MI') = '00:00'
ORDER BY 月份;
```

**口径提示**：

- 虚拟表**没有** `energy_reading`（没有表底，人工填的就是用量）。
- 出账时整月归「平」档，账单标 `touAssumedFlat=true` ——
  人工填的总量没有小时分布，硬拆峰谷等于编数。
- 判定依据是 `device.additional_info ->> 'deviceVirtual'`，**不是** SERVER_SCOPE 属性。
  平台统一用 `MeteringMath.isVirtual(Device)`，不要再各写一份。

### 3.9 参数报表

**入口**：综合报表 → 参数报表 → **看板**（`query_panel` + `timeseries_table`），
与其它 12 个报表统一。

> 2026-10-26 之前这个菜单项指向独立页面 `/param-report`。那是手写的 Angular 组件
> （`pages/param-report`），自带一套 `tb-pr-query-bar`，与看板里「查询设置」部件的
> 样式、交互、指标口径都不是一套。已改为 `linkType=DASHBOARD`。
> 存量客户的菜单由 `repair-init` 自动重建（检测菜单里是否还残留 `/param-report`）。

**看什么**：先选一只表 → 勾一级指标 → 右侧表格出该指标下的二级指标。

```
左侧「指标参数」                     右侧表格（每台表 × 每个二级指标一列）
  相电压              ← 一级        时间 | …· A相电压 | …· B相电压 | …· C相电压 | …· 平均相电压
    A相电压           ← 二级（= 遥测键 voltage_a）
    B相电压                        voltage_b
    C相电压                        voltage_c
    平均相电压                      voltage_avg
  有功功率 / 功率因数 …（同构）
```

**这条规则适用于所有带「查询设置」的看板**：一级用于选择，二级用于取值。
默认勾哪一组看 `query_panel` 的 `defaultParamCode`：参数报表配「相电压」（code=14），
因为部分表没有用电量历史，默认勾它打开就是空表。

**存储**：租户级资产 `type='default'`，挂在「能源参数字典」下（`relation` 边）。

```sql
-- 电能品种的二级指标清单
SELECT child.name AS 指标名,
       (SELECT ak.str_v FROM attribute_kv ak JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
         WHERE ak.entity_id = child.id AND kd.key = 'key') AS 遥测键,
       (SELECT ak.str_v FROM attribute_kv ak JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
         WHERE ak.entity_id = child.id AND kd.key = 'unit') AS 单位
FROM relation r
JOIN asset lib ON lib.id = r.from_id AND lib.type = 'energy_type_library'
JOIN asset parent ON parent.id = r.to_id AND parent.name LIKE '%电能%'
JOIN relation r2 ON r2.from_id = parent.id
JOIN asset child ON child.id = r2.to_id
WHERE r.from_id = lib.id
ORDER BY 指标名;
```

**口径提示**：字典是**真相源**。报表能显示哪些指标、单位是什么，全看这里。
一级指标上的 `agg`（电压 AVG / 电量 SUM）决定取数聚合方式 ——
混选电压和电量时不会用同一个聚合方式算错。
设备上报了字典里没有的键，报表认不出来（`05-troubleshoot.md` 现象 H）。

**看板入口的归属**：菜单指向的看板是客户自己名下那份副本
（`dashboard.customer_id = 该客户`），所以看板内容可以按客户单独调，
模板则保留在租户级（`customer_id IS NULL`）。

---

### 3.10 闲时能耗

**看什么**：非生产时段是否仍有持续负荷。

**存储**：日粒度结果写 `ts_kv`，四个键：

| 键 | 含义 |
| --- | --- |
| `idle_energy` | 闲时时段电量 |
| `idle_avg_power` | 闲时平均功率 |
| `idle_delta_count` | 与基线的偏差次数 |
| `idle_exceed` | 是否超标（0/1，用来触发告警） |

```sql
-- 某设备近 30 天的闲时判定结果
SELECT to_char(to_timestamp(t.ts/1000) AT TIME ZONE 'Asia/Shanghai','MM-DD') AS 日期,
       max(CASE WHEN kd.key='idle_energy'      THEN coalesce(t.dbl_v,t.long_v) END) AS 闲时电量,
       max(CASE WHEN kd.key='idle_avg_power'   THEN coalesce(t.dbl_v,t.long_v) END) AS 闲时平均功率,
       max(CASE WHEN kd.key='idle_exceed'      THEN coalesce(t.dbl_v,t.long_v) END) AS 是否超标
FROM ts_kv t JOIN key_dictionary kd ON kd.key_id = t.key
WHERE t.entity_id = '<设备id>'
  AND kd.key LIKE 'idle_%'
  AND t.ts > (extract(epoch from now()) - 30*86400) * 1000
GROUP BY 1 ORDER BY 1 DESC;
```

**闲时怎么判定**（不是机器学习，是阈值规则）：

```
某小时属于闲时  ⟺  该小时落在场站配置的「非工作时段」内
                    AND 该小时平均功率 > 待机功率阈值

场站配置存：asset（场站）SERVER_SCOPE 属性 idleConfig
  { "workStart": "08:00", "workEnd": "18:00",
    "workdays": [1,2,3,4,5], "standbyPowerKw": 5.0, "idleRatio": 0.15 }
```

**口径提示**：`idle_exceed` 是「日粒度标记」，由设备档案上的计算字段
「闲时能耗超标」消费并产生告警 —— 不要直接拿它当小时值。

---

### 3.11 告警中心

**存储**：ThingsBoard 原生 `alarm` / `entity_alarm` 表。

```sql
-- 某客户当前未清除的告警
SELECT a.type AS 告警类型, a.severity AS 级别,
       CASE WHEN a.cleared THEN '已清除'
            WHEN a.acknowledged THEN '已确认未清除'
            ELSE '未确认未清除' END AS 状态,
       to_char(to_timestamp(a.start_ts/1000) AT TIME ZONE 'Asia/Shanghai','MM-DD HH24:MI') AS 开始时间,
       d.name AS 设备
FROM alarm a
LEFT JOIN device d ON d.id = a.originator_id
WHERE a.tenant_id = '<租户id>'
  AND a.cleared = false                 -- 只列活动告警
ORDER BY a.start_ts DESC;
-- 说明：alarm 表没有 status 列，状态由 acknowledged / cleared 两个布尔列表达
```

**告警怎么产生**（三层）：

```
① 设备档案上的计算字段（calculated_field）
     「闲时能耗超标」「电压越限」「三相不平衡度」「负荷率」「碳排放」
        ↓ 条件命中
② 计算字段的 alarm 配置 → 产生 entity_alarm
        ↓
③ 告警中心展示（/api/energy/alarms 按 visibleDeviceIds 收口）
```

**口径提示**：客户账号只能看到「自己名下设备」的告警。
授权为场站级时，按 `visibleSiteIds` → `visibleDeviceIds` 过滤。

---

### 3.12 设备管理：设备运维 / 设备分组 / 设备拓扑

**三个页面各自管什么**（2026-10-26 改版后）：

| 菜单 | 路由 | 是干什么的 | 主要数据源 |
| --- | --- | --- | --- |
| 设备运维 | `/device-management` | 看设备**本身**：状态、参数、测点实时值、历史曲线、计量配置 | `/api/customer/{cid}/deviceInfos` + `ts_kv` + `/api/energy/device-config` |
| 设备分组 | `/device-group` | 看设备**归在哪个分类**：分项 / 区域 / 性质 / 位置 | `/api/customer/{cid}/assets` + `relation` |
| 设备拓扑 | `/device-topology` | 看设备**怎么接线**：进线 → 变压器 → 母线 → 出线 | `asset.type='topology'` + `relation` |

**存储**：

| 内容 | 位置 |
| --- | --- |
| 拓扑图 | `asset.type='topology'`，`additionalInfo` 存布局 |
| 拓扑节点/连线 | `relation`（`Contains` + `additionalInfo` 里的坐标） |
| 设备分组 | `entity_group` + `relation` |
| 设备分组内的**人工排序** | `relation.additional_info ->> 'order'`（设备分组页「上移 / 下移」写入） |
| 设备所属场站 | `device.additional_info ->> 'siteId'` |
| 计量层级 / 倍率 | `attribute_kv`（`DEVICE` + `SERVER_SCOPE`：`meterLevel` / `ctRatio` / `ptRatio` / `meterRatio`） |

```sql
-- 某个分组下设备的排列顺序（设备分组页「上移/下移」的结果）
SELECT d.name AS 设备,
       coalesce((r.additional_info::jsonb ->> 'order')::int, 9999) AS 顺序
FROM relation r
JOIN device d ON d.id = r.to_id
WHERE r.from_id = '<分组资产id>'
  AND r.relation_type = 'Contains'
  AND r.to_type = 'DEVICE'
ORDER BY 顺序, d.name;

-- 某台设备的计量配置（attribute_kv 的 key 是整数，要 join key_dictionary）
SELECT k.key AS 字段, a.long_v, a.str_v
FROM attribute_kv a
JOIN key_dictionary k ON k.key_id = a.attribute_key
WHERE a.entity_id = '<设备id>'
  AND a.attribute_type = 2   -- 2 = SERVER_SCOPE（1=CLIENT_SCOPE, 3=SHARED_SCOPE）
  AND k.key IN ('meterLevel','ctRatio','ptRatio','meterRatio','ratioApplied');
```

**设备的三个展示口径**（改造后三处一致，排查时按这张表对）：

| 列 | 取值 | 说明 |
| --- | --- | --- |
| 设备名称 | `asset/device.label`，为空回退 `name` | 客户看到的展示名 |
| 设备编号 | `device.name` | 技术名，租户内唯一；现场对表用它 |
| 设备一级类型 | 按**设备档案名**归类 | 电能 / 水表 / 燃气 / 蒸汽 / 环境 / 接入设备 / 其他 |
| 设备二级类型 | `device_profile.name` | 单相电能表 / 电能表 / 水表 / 温湿度变送器 / 网关… |

**网关不进「设备分组 → 添加设备」的候选**（2026-10-22 定，仍是这个口径）：

**设备分组的每一层都按右上角场站收窄**（2026-10-26 补齐）：

| 位置 | 数据来源 | 收窄依据 |
| --- | --- | --- |
| 左侧分组树 | `/api/customer/{id}/assets` + 关系 | `filterTreeBySite`（场站分组穿透） |
| 右侧设备表 | 选中节点下的设备 | 跟随树（树已裁剪） |
| 添加设备候选 | `/api/customer/{id}/devices` | `additionalInfo.siteId` |

添加设备的候选里保留两类特殊设备：**未分配场站**的（新接入，要在这里归属）
与全局场站为空时的全部（租户视角未定位）。

网关是代下级设备上报的通信代理，本身不产生能耗。把它挂进分项/区域，
上级汇总会多出一行没有电量、也无法解释的节点。抽屉底部会写明「已排除 N 台网关」，
所以它不会凭空消失 —— 在「设备运维」和「组织」里仍然看得到、也仍然统计在线状态。

**「设备分组 → 添加设备」的类型页签是「全部 / 关口表 / 普通表」**（2026-10-26 改）：

判定依据是**计量层级** `meterLevel`（设备的 `SERVER_SCOPE` 属性），不是设备档案名：

| 页签 | `meterLevel` | 含义 |
| --- | --- | --- |
| 全部 | —— | 不筛 |
| 关口表 | `1` | 进线总表（站点算费的入口） |
| 普通表 | `2` / `3` / `0` | 分项总表 / 回路表 / 非计量设备（温湿度、虚拟表…） |

为什么要分成这两档：**关口表读数已含下属分项与回路表**。混在一屏时，客户按页签
批量勾选极易把总表和分表一起选进来，聚合就是重复计量（金额虚高 2~3 倍）。

层级怎么拿到的：`GET /api/energy/meters` 随设备档案一次性下发 `meterLevel`，
前端不逐台请求。逐台请求 `device-config` 要几十次往返（实测十几秒，抽屉一直转圈）。
该接口失败时抽屉**照常打开**，所有设备一律当普通表 —— 漏掉分类远不如漏掉设备严重。

```sql
-- 校验：某场站的关口表 / 普通表各几台
SELECT COALESCE(dbl_v::int, 0) AS 计量层级, count(*) AS 台数
FROM device d
JOIN attribute_kv ak ON ak.entity_id = d.id
JOIN key_dictionary kd ON kd.key_id = ak.attribute_key AND kd.key = 'meterLevel'
WHERE d.customer_id = '<客户id>'
GROUP BY 1 ORDER BY 1;
```

```sql
-- 某场站的设备与拓扑视图
SELECT t.name AS 拓扑名, t.type,
       jsonb_array_length(coalesce(t.additional_info::jsonb->'nodes','[]'::jsonb)) AS 节点数
FROM asset t
WHERE t.type = 'topology'
  AND t.additional_info::jsonb->>'siteId' = '<场站id>';
```

---

### 3.13 平台自检

**看什么**：初始化数据缺不缺（11 项）。**不算电量，只数数量**。

```sql
-- 手工复核自检的核心几项（租户 id 自行替换）
-- ① 能源参数字典品种数（期望 4）
SELECT count(*) AS 品种数
FROM asset child
JOIN relation r ON r.to_id = child.id AND r.to_type = 'ASSET'
JOIN asset lib ON lib.id = r.from_id AND lib.type = 'energy_type_library'
WHERE child.tenant_id = '<租户id>' AND child.type = 'default';

-- ② 设备档案里标了 isMeter 的数量（期望 ≥5）
SELECT count(*) AS 表计档案数
FROM device_profile dp
JOIN attribute_kv ak ON ak.entity_id = dp.id
JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
WHERE dp.tenant_id = '<租户id>' AND kd.key = 'isMeter' AND ak.bool_v = true;

-- ③ 计算字段（告警 + 派生指标）条数（期望 11）
SELECT count(*) AS 规则数
FROM calculated_field cf
JOIN device_profile dp ON dp.id = cf.entity_id
WHERE cf.tenant_id = '<租户id>';

-- ④ 费率配置覆盖的品种数（期望 ≥1）
SELECT count(DISTINCT kind) AS 已配价品种 FROM (
    SELECT json_object_keys(ak.json_v) AS kind
      FROM attribute_kv ak JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
      JOIN asset a ON a.id = ak.entity_id
     WHERE a.tenant_id = '<租户id>' AND kd.key = 'energyRates' AND ak.json_v IS NOT NULL
    UNION
    SELECT json_object_keys(ak.json_v)
      FROM attribute_kv ak JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
      JOIN asset a ON a.id = ak.entity_id
     WHERE a.tenant_id = '<租户id>' AND kd.key = 'siteCustomRates'
       AND ak.json_v IS NOT NULL AND ak.json_v::text <> '{}'
    UNION
    SELECT json_object_keys(c.additional_info::json->'energyRates')
      FROM customer c WHERE c.tenant_id = '<租户id>'
) t;
```

---

### 3.14 组织（组织 → 场站 → 设备）

```sql
-- 组织树：组织 → 场站 → 设备数
SELECT o.name AS 组织, s.name AS 场站,
       (SELECT count(*) FROM device d
         WHERE d.additional_info::jsonb->>'siteId' = s.id::text) AS 设备数
FROM asset o
JOIN relation r ON r.from_id = o.id AND r.relation_type = 'Contains'
JOIN asset s ON s.id = r.to_id AND s.type = '场站'
WHERE o.type = '组织' AND o.tenant_id = '<租户id>'
ORDER BY o.name, s.name;
```

**口径提示**：场站归属客户靠 `asset.customer_id`，设备归属场站靠
`additional_info.siteId` —— 这两条不是同一个机制，别混。

---

### 3.15 空调管理（运行监控 / 计划配置 / 复盘报告）

空调是**独立的业务模块**，不是「能耗查询」的又一张报表 —— 前者看「设备怎么运行」，
后者看「用了多少能源」。一级菜单「空调管理」下挂三块看板，各自独立路由：

| 菜单 | 看板模板 | 回答什么问题 |
| --- | --- | --- |
| 空调运行监控 | `hvac_operation_monitor` | 现在开着没有？锅炉几台？各楼栋温湿度/CO₂ 达标吗 |
| 运行计划与配置 | `hvac_plan_config` | 今天该用哪套模式？这套模式的温度/时段/CO₂ 上限是多少 |
| 每日复盘报告 | `hvac_daily_report` | 昨天能效如何（负荷/COP/减碳）、环境达标率多少、分时能耗曲线 |

#### 数据模型（全部用 TB 原生实体，没有新表）

| 对象 | TB 实体 | 标识 |
| --- | --- | --- |
| 楼栋 | Asset | `type='楼栋'`，`Contains → 场站`，`additionalInfo.siteId` |
| 运行模式 | Asset | `type='运行模式'`，配置存在 `SERVER_SCOPE.hvacMode`（JSON 字符串） |
| 新风机组 / 锅炉 / 热水泵 / 室内环境变送器 | Device | `type` = 档案名；`additionalInfo` 带 `siteId`、`buildingId`、`hvac=true` |

四类设备档案都写死了 **`isMeter=false` + `meterLevel=0`**。
这一点不能改：否则 `rebuildAssetTotals` 会把空调当电表汇总，
场站总电量会凭空翻倍（空调电耗本来就在配电回路的表里）。

空调遥测 key：

```
ahu_mode  ahu_freq                             新风机组：运行模式 / 频率
boiler_water_temp  boiler_run_count            锅炉：出水温度 / 运行台数(0/1)
pump_freq_big  pump_run_big                    热水泵(大)
pump_freq_small  pump_run_small                热水泵(小)
indoor_temp  indoor_humidity  indoor_co2       室内环境变送器
energy  gas                                    设备侧能耗（用于复盘） / 燃气
```

#### 「今天用哪套模式」是算出来的，不是存的

运行模式只有四套模板（夏/冬 × 工作日/节假日），具体某天用哪套由两条规则算：

- **季节**：5–10 月 = 夏季，其余 = 冬季
- **日期类型**：周六/日 = 节假日，其余 = 工作日

匹配不到时回退到「同季节的工作日」；再没有就返回空 —— 页面显示
「该日期未匹配到运行模式」，比硬编一套默认值诚实（客户能立刻发现缺配置）。

存一张「每天一行」的计划表会立刻产生同步问题：改了模式模板，历史计划要不要跟着变？
算出来就没有这个问题。

#### 复盘口径

| 指标 | 公式 | 说明 |
| --- | --- | --- |
| 空调总负荷 | `elec + gas × 10` | 1 m³ 天然气 ≈ 10 kW·h 热值 |
| COP | `gas × 10 / elec` | 只在有燃气（制热）时有意义；无燃气时给 **2.5** 并标 `copEstimated` |
| 能效等级 | COP ≥3.5 一级 / ≥3.0 二级 / ≥2.5 三级 | 对齐 GB 冷热源能效分级 |
| 节电量 | `(1 − 2.5 / COP) × elec` | 与行业基准 2.5 比较；COP 是估算值时给 0（不虚报节能） |
| 减碳量 | `节电量 × 0.581 kgCO₂e/kWh` | 华北电网因子，按现场电网可调 |
| 温度达标率 | 落在**当天运行计划**区间内的点数 / 有效点数 | 注意与监控页不同：监控页用舒适区 18–28 ℃ |
| CO₂ 达标率 | `≤ co2Max`（计划值，默认 1000 ppm） | 监控页用 1500 ppm 宽松限值 |

> **为什么监控页和复盘页的判定区间不一样**：监控页回答「此刻环境能不能接受」，
> 用宽舒适区；复盘页回答「按计划做到了没有」，必须用计划区间。
> 一处用宽、一处用严，是有意的。

#### 告警：走根规则链，不新建规则链

`HvacBootstrapInstaller.ensureHvacAlarmNodes` 在**根规则链**的
`Message Type Switch --Post telemetry-->` 下挂两条分支：

```
Post telemetry ─→ HVAC 温度越界判断 ─[True]→ HVAC 温度越界告警   (MAJOR)
               └→ HVAC CO₂超限判断  ─[True]→ HVAC CO₂超限告警    (WARNING)
```

- 阈值：温度 <16 或 >30 ℃、CO₂ >1200 ppm（固定，写在 JS 过滤节点里）
- 告警详情写 `indoorTemp` / `indoorCo2` / `indoorHumidity` / `deviceName` / `deviceType`
- 为什么不用运行计划里的阈值：规则链沙箱只能读 `msg` / `metadata`，
  跨级查「设备 → 场站 → 运行模式」做不到。计划区间的严格判定放在复盘报告里算。

#### 接口

```
GET    /api/hvac/overview?siteId=            今日计划 + 当前状态 + 楼栋环境
GET    /api/hvac/plan?siteId=&date=          某天用哪套模式
GET    /api/hvac/daily-report?siteId=&date=  能效 / 环境 / 24 点分时
GET    /api/hvac/modes?siteId=               运行模式清单
POST   /api/hvac/modes                       新建（资产 + 配置属性 + Contains 关系）
POST   /api/hvac/modes/{modeId}              更新配置
DELETE /api/hvac/modes/{modeId}              删除
```

#### 页面是空的怎么查

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 三块看板都在，但显示「当前账号没有可见场站」 | 客户名下没有场站 | 「组织」里建场站 |
| 有场站，但计划显示「未匹配到运行模式」 | 四套模式没建全 | 「运行计划与配置」里补建 |
| 监控页「当前状态」全是 — | 设备没有遥测 | 检查 RTU/网关是否上报 `ahu_freq` 等 key |
| 复盘页折线是空的 | 当天没有 `energy` / `gas` 遥测 | 同上；或换一天看 |
| 菜单里没有「空调管理」 | 客户是旧菜单（本模块 2026-10-27 加入） | 「平台自检 → 一键修复初始化」 |
| 点空调子菜单，页面却回到「能耗概览」 | 浏览器里还是**重装前**的页面：菜单缓存在内存里，指向的看板 id 在重装时已重新生成 | Cmd/Ctrl+Shift+R 强刷，或退出重登 |
| 点空调子菜单显示「这个看板不存在或已被删除」 | 菜单指向的看板副本确实没了（手工删过看板 / 看板没复制给该客户） | 「平台自检 → 一键修复初始化」会补建缺失看板并重装菜单 |
| 空调设备创建失败 | 四个设备档案不存在 | 一键修复会先建档案（`ensureHvacProfiles`），按顺序重跑 |

---

## 四、AI 功能：算法与数据集格式

「能耗优化」下三项里，**只有负载预测是真的机器学习**，另外两项是规则/统计。

### 4.1 负载预测 —— Prophet（时序分解 + 加法/乘法模型）

**算法**：Meta 的 **Prophet**（`prophet` Python 包，Stan 后端拟合）。

**为什么是这个**（代码注释里的实测对比）：

| 方案 | 优点 | 在这个场景的问题 |
| --- | --- | --- |
| **Prophet** | 容忍缺口、自带日/周/年季节、可加回归量 | 需要足够历史（≥7 天） |
| ARIMA | 统计上严谨 | 对缺失值敏感，缺口要插补 |
| LSTM | 能学复杂模式 | 需要大量数据；现场只有 14 天 |

实测（同一批数据）：朴素基线 MAE 17.34，Prophet MAE 31.49 —— 数据只有强日周期
没有周周期时，Prophet 默认的周季节反而拖累。所以预测结果里**同时给两个基线**，
让用户自己看谁更准，而不是只报模型输出。

**输入数据格式**（两列，DSL 就这两列）：

```python
# Prophet 要求的 DataFrame
   ds          y
2026-10-01 00:00:00   12.34     # ds: 时间戳（小时粒度）
2026-10-01 01:00:00   11.87     # y : 该小时电量（kWh）
...
```

**取数 SQL**（等价于服务内部的查询）：

```sql
SELECT to_timestamp(t.ts/1000) AT TIME ZONE 'Asia/Shanghai' AS ds,
       coalesce(t.dbl_v, t.long_v)                           AS y
FROM ts_kv t
WHERE t.entity_id = '<设备id>'
  AND key = (SELECT key_id FROM key_dictionary WHERE key = 'energy')
  AND t.ts >= 1790784000000 AND t.ts <= 1793462400000   -- 2026-10 全月，按需改
ORDER BY t.ts;
```

**预处理三步**（不做就会得到垃圾结果）：

1. **去重**：同一小时可能有多条（重传），按均值合并。
2. **补缺口**：`resample('h')` 后缺失小时填 NaN，由 Prophet 内部处理。
3. **数据质量筛查**（`quality.py`）：
   - 点数 < 预期 30% → 该实体剔除
   - 中位采样间隔与其他实体差 3 倍以上 → 多实体聚合时剔除

> 这一步不是可选的。实测：40 台设备里有 27 台只有 1 个数据点（月粒度虚拟表），
> 混进来做 `sum` 会把整月累计值加到 1 个小时上，造出 20150 的假尖峰
> （其余时刻合计只有 188），峰均比虚高 87 倍。

**输出**：

```json
{ "ds": "2026-10-24 00:00:00", "yhat": 12.1, "yhat_lower": 9.8, "yhat_upper": 14.6 }
```

**接口**：`POST /ngxapi/biz/forecast`（客户侧）、`POST /ngxapi/forecast/run`（租户侧）

---

### 4.2 用能建议 —— 规则引擎（**不是**机器学习）

**算法**：确定性规则 + 统计阈值。每类建议的判据：

| 建议类型 | 判据 | 数据要求 |
| --- | --- | --- |
| 峰谷转移 `peak_shift` | 峰段用电占比 + 谷段闲置容量 | 小时粒度 ≥7 天 |
| 待机损耗 `standby_loss` | 非生产时段仍有持续负荷（可削减 60%） | 小时粒度 ≥14 天 |
| 需量控制 `demand_control` | 最大需量出现时刻 + 负荷曲线 | 小时粒度 ≥30 天 |
| 同类对比 `peer_gap` | 同 profile 设备的单位产出能耗 | ≥3 台同类 |
| 异常处置 `anomaly_action` | 异常检测的持续偏差 | 异常检测结果 |
| 容量利用 `capacity` | 峰值 / 变压器容量 | 需提供容量参数 |

**为什么用规则不用模型**：每条建议必须带「触发依据 + 量化影响 + 可执行动作 +
置信度」。模型给不出可解释的依据时，运维看完不知道做什么。

**输入数据**：小时粒度电量序列（同 4.1）+ 场站工业时段配置。
**最少点数**：24（一天的日周期都覆盖不全，任何结论都站不住）。

**接口**：`POST /ngxapi/biz/advice`（客户侧）、`POST /ngxapi/advice/run`（租户侧）

> 两个入口共用同一个执行器（`advice_engine.py`）——
> 各写一遍必然出现「同一批数据在租户页和客户页得出不同建议」。

---

### 4.3 用能质量 —— 统计诊断（**不是**机器学习）

**算法**：数据质量诊断 + 统计量（峰均比、标准差、变异系数）。

**判据**（只看两条客观事实，不按数值大小剔除）：

1. **点数太少**：目标窗口内点数 < 预期点数的 30%
2. **粒度不一致**：该实体中位采样间隔与其他实体差 3 倍以上
   （只在多实体聚合时启用 —— 求和场景特有）

**输出**：每个实体的 `points` / `interval` / `score`，以及整体可用性结论。

**接口**：`GET /ngxapi/biz/quality`

---

## 五、埋点：日志里的可复制 SQL

平台在关键统计接口上打了 **SQL 埋点**，日志里能直接拿到执行过的
等价 SQL（参数已代入），复制到 psql 就能和页面数字对照。

### 5.1 怎么用

```bash
# 实时看（跟着点页面，日志就会输出）
docker logs -f energy-server 2>&1 | grep -A40 "SQL 埋点"

# 只看某个功能
docker logs energy-server 2>&1 | grep -A40 "SQL 埋点 \[峰谷分析\]"
docker logs energy-server 2>&1 | grep -A40 "SQL 埋点 \[抄表台账\]"
docker logs energy-server 2>&1 | grep -A40 "SQL 埋点 \[我的账单"

# 从日志文件（生产 profile 按天落盘）
grep -A40 "SQL 埋点" ~/energy-app/logs/guard-server.log
```

输出长这样：

```
╔══ SQL 埋点 [峰谷分析] GET /api/energy/tou-analysis
║ ⚠ 本埋点用于页面结果与 SQL 结果对照：未经用户同意不得删除；…
║ 参数: scopeType=device, scopeId=66fa…, granularity=day, from=1792…, to=1792…
║ ── 可复制 SQL（参数已代入）──
║ -- (1/3) -- ① 原始小时表底…
║ SELECT entity_id, …
╚════════════════════════════════════════════════════════════════
```

`║ ` 前缀是日志装饰，复制时去掉即可（或用 `sed 's/^║ //'`）。

### 5.2 已覆盖的接口

| 功能 | 接口 | 埋点内容 |
| --- | --- | --- |
| 峰谷分析 | `GET /api/energy/tou-analysis` | ① 小时表底 ② 逐小时用量 ③ 两个口径的区间总量 |
| 抄表台账 | `GET /api/energy/meter-reading/ledger` | 台账主查询（与实现同一份 SQL 文本） |
| 我的账单 | `GET /api/energy/billing/summary` | 账单明细 + 四项和 |
| 出账 | `POST /api/energy/billing/generate` | 落库后的账单 + 汇总口径 |
| 设备计量配置 | `POST /api/energy/device-config` | 写入后的层级/倍率属性 |

### 5.3 开关

```yaml
# 默认 true。关掉会让页面数字无法用 SQL 复核，只在日志噪音影响排查时临时关
energy:
  sql-trace:
    enabled: true
```

### 5.4 ⚠ 给维护者的约定（写在代码注释里）

> **未经用户明确同意，不得删除任何 `SqlTrace.trace(...)` 调用**，
> 也不得为「日志干净」「性能」把它注释掉或降级。
>
> **埋点 SQL 与实现不一致属于缺陷**，可以并且应该更新 ——
> 更新时保证：参数代入方式不变、仍可直接复制执行。
>
> **新增统计接口时必须补埋点**，否则用户无法自行核对数据。

代码位置：`guard-server/src/main/java/com/guard/server/util/SqlTrace.java`（类头有完整约定）。

### 5.5 ⚠ 自绘部件与实时刷新的两条约定

**1）自绘部件必须声明 `self.typeParameters`。**

用 `self.ctx.http` 自己取数的部件（本平台 `energy_management_*` 绝大多数都是），
必须在脚本开头声明：

```js
self.typeParameters = function () {
  return { datasourcesOptional: true, processNoDataByWidget: true, dataKeysOptional: true };
};
```

否则 TB 在「数据源没解析成功」时会**跳过 `onInit`**，页面只显示「部件无数据可显示」。
客户看板里的别名可能指向租户级占位符（`00000000-…`），解析必然失败。
排查与修复见 `05-troubleshoot.md` 现象 Y。

**2）有副作用的结果部件靠 `runId` 判断「用户是否真的点了按钮」。**

`query_panel` 的 `emitRunId=true` 时，每次提交会带一个 `runId`；
结果部件只在收到**新 runId** 时才执行（抄表就是这么做的：
`meter_reading_board` 看到新 runId 才下发 RTU 采集并写库）。

约定：**自动提交（首屏 / 切场站 / 实时轮询）不生成 runId**，
只有用户点「查询」按钮才生成。内部调用必须写成 `scope.submit(true)`。

2026-10-26 修过一个真实缺陷：自动提交也生成 runId，导致**打开抄表页面
就抄了一遍表**（实测三分钟三次打开 → 写了 3 批 18 条 `meter_reading_record`）。
现在首屏空态显示「请在左侧查询设置中选好范围与指标，然后点一键抄表」，
不再偷偷写库。

**3）`refreshSecs` 不低于 10 秒。**

实时部件一轮刷新 = 每台设备一个 telemetry 请求。3 秒一轮会把浏览器的
6 条连接占满，导致切场站后重建设备树要排队十几秒（现象 X）。
看板模板里两个实时部件（`realtime_kpi` / `realtime_trend`）统一填 `10`，
部件代码也会把下限卡在 8 秒。

---

## 六、常见对不上账的四种情况

| 现象 | 真实原因 | 怎么确认 |
| --- | --- | --- |
| 页面电量 > 台账 | 页面按逐小时增量累加，台账按账期首末差 | 看 `backwardSegments` 是否 > 0 |
| 全表合计是应付的 1.8 倍 | 总表 + 分表相加了同一度电 | 看 `meterLevel` 是否配齐（3.7 节） |
| 账单金额是 0 | 该品种没配电价 / 表底不足两点 | `POST /billing/generate` 带 `dryRun` 看 `reason` |
| 虚拟表查不到表底 | 虚拟表本来就没有 `energy_reading` | 查 `energy` 月首点（3.8 节） |
| 峰谷全 0 | 表没挂场站 → 解析不到时段方案 | 看 `device.additional_info.siteId` |
