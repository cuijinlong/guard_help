# ⑬ 测试与验收（用例与判据）

这一页回答一个问题：**改完之后，怎么证明系统还是对的。**

素材全部来自本仓库已存在的可执行脚本与实测数据，每条用例都给出「不符时查哪里」，
不写「应该没问题」这类无法判定的结论。

---

## 先说结论：不要给 26 个页面各写一个脚本

这是最容易走错的一步。26 个页面 × 每页一个 E2E = 26 份维护负担，
而且绝大多数页面共用同一批接口（见 [⑫ 页面链路卡](/admin/page-map) 的「七个基础设施接口」）。
接口一改，26 个脚本全红，但真正坏的只有一处。

正确做法是按**风险**分层，只给「算错了不会报错」的地方写自动化：

| 层 | 验什么 | 出错的后果 | 工具 |
| --- | --- | --- | --- |
| **单元** | 倍率、用量、解析这类纯算法 | 静默算错，页面照常显示 | JUnit（本仓库） |
| **结构** | 接口通不通、权限越不越界 | 报错或越权，能被发现 | `03-verify.sh` |
| **数据** | 库里各表彼此对不对得上 | 数字自相矛盾 | `04-verify-data.sh` |
| **闭环** | 客户建数据到报表出数 | 流程走不通 | `06-verify-e2e.sh` |
| **发布内容** | 这一版的每项改动是否落地 | 装了旧版本 | `08-verify-release.sh` |
| **回归** | 历史统计值变没变 | 口径被改了没人知道 | `baseline-snapshot.mjs` |

页面长什么样、按钮在不在，靠下面的[手工用例](#六手工用例按业务链路不按页面)。
这类东西用脚本守住成本极高、收益极低 —— 页面重构一次就全废。

---

## 一、四层自动化，各管一段

前三层分工写在脚本头部注释里，是设计约束，不是巧合：

```bash
# 全部在部署目录内执行（scripts/ 与 data/ 同级）
cd ~/energy-app

# ① 结构：接口可用 + 权限正确
bash scripts/03-verify.sh \
  --base http://127.0.0.1:8090 \
  --tenant tenant@example.com --tenant-pass '...' \
  --customer customer@example.com --customer-pass '...'

# ② 数据：库里的数彼此自洽（直连 psql，不走 REST）
bash scripts/04-verify-data.sh
bash scripts/04-verify-data.sh --site 单相园区 --verbose   # 只验一个场站

# ③ 闭环：从客户自己建数据，到报表出数
bash scripts/06-verify-e2e.sh \
  --base http://127.0.0.1:8090 \
  --tenant tenant@example.com --tenant-pass '...' \
  --customer customer@example.com --customer-pass '...'

# ④ 发布内容：这一版改的每一项是否真的落地
bash scripts/08-verify-release.sh \
  --tenant tenant@example.com --tenant-pass '...' \
  --customer customer@example.com --customer-pass '...'
```

全部以 `0 = 通过 / 1 = 有失败项` 退出，可以直接串进发布流程：

```bash
set -e
bash scripts/08-verify-release.sh ... || { echo '发布内容未到位，禁止上线'; exit 1; }
bash scripts/04-verify-data.sh       || { echo '数据不自洽'; exit 1; }
```

### 各自到底覆盖什么

`04-verify-data.sh` 的 9 个检查组（这是「统计准不准」的主力）：

| # | 检查组 | 核心断言 |
| --- | --- | --- |
| 1 | 演示包规模 | 该有的设备、表计数量对得上 |
| 2 | 电表计量层级 | 一级 / 二级 / 三级表都在，且挂了关系 |
| 3 | 增量与表底守恒 | 逐点比对「表底差」与「上报增量」，偏差超阈值即失败 |
| 4 | 上下级汇总 | 上级 ≥ 下级之和，差额 = 线损 + 未装表 |
| 5 | 电气量物理自洽 | U×I×√3×PF ≈ P，功率因数在 (0,1] |
| 6 | 水 / 燃气 / 蒸汽表 | 各品种表底单调、增量非负 |
| 7 | 温湿度 | 量程合理 |
| 8 | 数据覆盖 | 每台表最近 N 小时有点 |
| 9 | 虚拟设备与手工填报 | 手工录入回填到正确位置 |

`06-verify-e2e.sh` 的 9 个环节：组织管理、设备管理、数据上报（HTTP + MQTT）、
标准指标化、计算字段、规则链、报警、报表可视化（看板 + 分时数值与原始遥测一致）、
虚拟设备。

> **为什么 04 直连 psql 而不是走 REST**：一次要拉 11 台表 × 336 点 × 20 个键 ≈ 7 万行，
> REST 要几十秒且分页易漏；psql 一条聚合能直接算「表底差 vs 增量」这种跨行断言。
> 非 PostgreSQL 部署才需要 REST 版。

---

## 二、单元测试：算法口径（这一层原来完全没有）

### 为什么只有这几个类值得单测

判据只有一条：**算错了页面照样正常显示**。

| 类 | 位置 | 为什么危险 |
| --- | --- | --- |
| `MeteringMath` | `guard-server/src/main/java/com/guard/server/util/MeteringMath.java` | 倍率、表底差、解析全是纯函数，算错不抛异常，账单直接错钱 |

反过来，Controller 里的逻辑不值得单测：它有 HTTP 状态码、有日志，
04 / 06 两层能抓到，再包一层 mock 只是把同一件事测两遍。

### 怎么跑

```bash
cd guard-server
mvn -Dtest=MeteringMathTest test

# 硬证据不看 exit code，看报告：
cat target/surefire-reports/com.guard.server.util.MeteringMathTest.txt
```

正常输出：

```
Tests run: 29, Failures: 0, Errors: 0, Skipped: 0
```

> **为什么强调看报告不看 exit code**：`mvn -q` 会把统计一起静默掉，
> `exit=0` 只能说明「没崩」，不能说明「断言真的跑了」。
> 外层测试类如果全在 `@Nested` 里，`.txt` 会显示 `Tests run: 0` ——
> **那也是正常的**，真实计数在 `TEST-*.xml` 的 `tests` 属性里。

### 29 条断言覆盖什么

| 分组 | 条数 | 覆盖的关键点 |
| --- | --- | --- |
| `parseRatio` | 5 | `200/5` → 40；空/null → 1；`5/200`、`0/5`、`abc` 必须抛异常（不许静默兜底成 1） |
| `nameplateRatio` | 2 | `200/5 × 10000/100 = 4000`（黄金用例）；缺一侧按 1 |
| `effectiveRatio` | 4 | `ratioApplied=true → 1`；变比优先于综合倍率；仅 CT/PT 全空才用 `meterRatio` |
| `usageOfSegment` | 6 | `(1250.00 − 1234.50) × 4000 = 62000`；倒走 → `abnormal` 且不给用量；缺表底 → `estimated`；系数 null 按 1 |
| `num` | 3 | 空串/非法 → `null` 而不是 `0` |
| `isVirtual` | 4 | 只认 `device.additionalInfo.deviceVirtual`，不认 SERVER_SCOPE 属性 |
| `participates` | 3 | **缺省即参与**，只有显式为假才排除 |
| `truthy` | 2 | `t/true/1` 为真；与 `participates` 默认值相反，不许混用 |

### 期望值是从哪来的（这条最重要）

**不是照着 Java 实现反推的** —— 那是把 bug 写成断言。

期望值来自 `nenghaobao/energy-config/lib/metering.mjs` 的**实际运行输出**。
那是同一套算法的独立实现，可以当 oracle 交叉核对。

复现 oracle：

```bash
node --input-type=module -e "
import * as M from './nenghaobao/energy-config/lib/metering.mjs';
console.log(M.usageOfSegment({from:1234.50, to:1250.00, ratio:4000}));  // 62000
console.log(M.usageAcrossSegments([{from:1000,to:1880,ratio:1},{from:20,to:62,ratio:1}])); // 922
"
```

### 三处与 Node 版的有意差异（别为了「同口径」改掉）

| # | 差异 | 原因 |
| --- | --- | --- |
| ① | Java 的 `parseRatio` 接受纯数字字符串 `"1"` / `"40"` | 台账上可能只记综合倍率，写不进 `200/5` 这种形式 |
| ② | Java 有 `meterRatio` 兜底 | Node 版只认 CT/PT，现场说不出变比时倍率会静默失效 |
| ③ | Node 的 `usageAcrossSegments` / `allocateToPeriod` 在 Java **无对应实现** | 系统没有换表登记入口；账单走「自然月 + 小时表底差分」，比区间线性分摊更精确 |

> 差异 ③ 不是缺陷。如果将来真要做换表登记，先加 `usageAcrossSegments` 再改账单，
> 不要直接把 Node 的区间分摊搬过来 —— 那会把精度降下去。

### 已知风险：CT/PT 填 `"1"` 会遮蔽综合倍率

```java
MeteringMath.effectiveRatio("1", "1", "40", false)  // → 1，不是 40
```

`nameplateRatio("1","1") = 1×1 = 1`，所以填了 `meterRatio=40` 也不生效。
当前库里 35 台设备**倍率属性全部缺失**（都按 1 计算），不会触发；
但现场若把表单默认值写成 `"1"` 而不是留空，就会踩到。

这条已写成测试固化。**要改行为必须先改测试**，否则等于悄悄改口径。

---

## 三、统计基线快照：改了口径怎么知道数变没变

### 它解决什么问题

`04-verify-data.sh` 验的是「库里各表彼此自洽」，但验不了
「和上个月比，这个场站的用电量有没有被改口径改掉」。

页面上的数随实时数据一直在动，肉眼看不出来。
「改了统计逻辑但没人发现」和「没改」在证据上无法区分 —— 这就是这个工具存在的理由。

### 生成与比对

```bash
# 在仓库根目录（需要 energy-postgres 在跑）

# 生成基线（默认窗口 2026-09-01 ~ 2026-11-01）
node tools/baseline-snapshot.mjs

# 换窗口
node tools/baseline-snapshot.mjs --from 2026-10-01 --to 2026-11-01

# 改了统计代码后，和基线比
node tools/baseline-snapshot.mjs --compare tools/baseline/window-2026-09-01_2026-11-01.json
```

| 退出码 | 含义 |
| --- | --- |
| 0 | 同一历史窗口的统计值与基线一致 |
| 1 | 有差异（逐条打印每处 Δ） |
| 2 | 执行失败（基线不存在 / 连不上库） |

### 为什么按「窗口」命名而不是按「运行日期」

固定历史窗口 `[from, to)` 内的统计值**本应是常量**。
所以文件名由窗口决定，而脚本在**数字没变时根本不改写文件**：

- 数字没变 → 文件一字不动 → `git diff` 为空；
- 数字变了 → 覆盖，`git diff` 里出现的**就是变化本身**（不会混入时间戳噪声）。

这个设计是整个工具的关键。如果按日期命名，每天都是新文件，
基线永远和今天比，任何差异都会被「数据变多了」掩盖；
如果每次都刷新 `generated_at`，则即使数字一模一样也会产生 diff，
「看到变化就是统计被改了」这个判断就不再成立。

### 怎么判读差异

```
✗ 发现 2 处差异：
  ~ 用量变化 三相园区/PowerMeter-1: 70847.41 → 70847.41（Δ 0）
  ~ key energy_reading: 159898 行/31 台 → 160021 行/31 台
```

`--compare` 与「生成」的区别：前者只比较、不影响文件；后者在发现数字变化时
**会先打印变化清单再覆盖**，所以你可以直接看它打印了什么：

```
! 统计值有 1 处变化，将覆盖基线（请确认都是预期改动）：
  ~ 用量变化 AHU-SIM·平台演示中心: 99.9 → null（Δ n/a）
```

- **用量变化**：口径被改了。先确认是不是有意改的，再决定更新基线。
- **只 key 行数变**：数据在增长，窗口没锁住 → 说明 `--to` 落在了「现在」之后。
  把 `--to` 设成明确的过去日期。
- **设备增删**：`+ 新增设备` / `- 删除设备`，属于业务变更，更新基线。

### 两条自检（换环境后必跑，证明它不是摆设）

只验「跑得通」不够 —— 一个什么都不检查的脚本也会「跑通」。

```bash
# ① 可重复性：删掉重建两次，两次从库算出的数字必须一致
#    （不能只重跑一次 —— 数字没变时脚本不改写文件，那样测不出东西）
f=tools/baseline/window-2026-09-01_2026-11-01.json
cp "$f" /tmp/base-orig.json
rm -f "$f" && node tools/baseline-snapshot.mjs >/dev/null && cp "$f" /tmp/snap-a.json
rm -f "$f" && node tools/baseline-snapshot.mjs >/dev/null && cp "$f" /tmp/snap-b.json
python3 -c "
import json
def s(p):
    d=json.load(open(p)); d.pop('meta',None); return d
print('✓ 可重复' if s('/tmp/snap-a.json')==s('/tmp/snap-b.json') else '✗ 不可重复')
"
cp /tmp/base-orig.json "$f"   # 恢复（内容应当与重建的完全一致）
cat /tmp/base-orig.json | python3 -c "
import json,sys
def s(d): d.pop('meta',None); return d
print('✓ 与出厂基线一致' if s(json.load(sys.stdin))==s(json.load(open('$f'))) else '✗ 不一致')
"

# ② 有效性：故意改坏一个数，必须报出来
python3 - <<'EOF'
import json
p='tools/baseline/window-2026-09-01_2026-11-01.json'
d=json.load(open(p))
for dev in d['devices']:
    if dev['usage'] is not None:
        dev['usage'] += 123.4567
        print('篡改:', dev['name'])
        break
json.dump(d, open('/tmp/snap-tampered.json','w'), ensure_ascii=False)
EOF
node tools/baseline-snapshot.mjs --compare /tmp/snap-tampered.json
# 必须报 Δ -123.4567 且 exit=1；报不出来说明比对逻辑坏了
```

### 口径必须与账单一致

每设备用量 = 相邻小时表底差 × 倍率，负差分（换表 / 归零 / 错值）跳过并计数 ——
与 `EnergyBillingService#readUsage` 同一套算法。

**基线通过 ≠ 账单对。** 两者口径不一致时，基线只能证明「和上次一样」，
不能证明「算得对」。核对口径差异时看这两处：

```bash
grep -n "readHourlyMax\|backwardSegments" guard-server/src/main/java/com/guard/server/service/energy/EnergyBillingService.java
grep -n "hourly\|lag(v)" tools/baseline-snapshot.mjs
```

---

## 四、发布前跑什么（两档）

### 15 分钟档：只改了业务代码 / 部件 / 字典

```bash
cd guard-server && mvn -Dtest=MeteringMathTest test && cd ..   # 30 秒
node tools/baseline-snapshot.mjs --compare tools/baseline/window-2026-09-01_2026-11-01.json
node tools/verify-deploy.mjs                                    # 源码/物料/库 三段一致
bash guard-server/sync-data.sh                                  # 只读，看数据差异
```

### 1 小时档：发版 / 换了环境 / 动过统计口径

在上面基础上加：

```bash
bash scripts/08-verify-release.sh ...    # 这一版每项改动是否落地
bash scripts/03-verify.sh ...            # 结构 + 权限
bash scripts/04-verify-data.sh           # 数据自洽（含表底守恒）
bash scripts/06-verify-e2e.sh ...        # 业务闭环
node tools/verify-org-module.mjs --with-permissions   # 组织模块 20+10 条
node tools/verify-org-page.mjs --shot /tmp/org.png    # 页面渲染 12 条
```

---

## 五、手工用例（按业务链路，不按页面）

自动化守住的是「数对不对」，下面这些守住「用户能不能用」。
每条给：**操作 → 期望 → 不符怎么查**。

### A. 上报数据

| # | 操作 | 期望 | 不符怎么查 |
| --- | --- | --- | --- |
| A1 | 真实 RTU 上电，等 2 分钟 | `bash scripts/29-rtu-demo-up.sh --status` 显示真实表在报 | `scripts/34-rtu-diagnose.sh`；再看网关日志 |
| A2 | `bash scripts/29-rtu-demo-up.sh --sim-only` | 模拟表开始出数，页面曲线在走 | 进程是否退出；MQTT 通道 `node tools/mqtt-gateway-check.mjs` |
| A3 | 停掉模拟器 10 分钟后再开 | 抄表页把这台表标为「陈旧」，不是静默沿用旧值 | 设备属性 `lastConnectedGateway` / 抄表接口的 stale 字段 |
| A4 | 断网 1 小时后恢复 | 数据补传，页面时间轴有缺口而不是整段平滑（不编数） | `ts_kv` 按小时 count，缺口应真实存在 |

**判据是「不编数」**：缺就是缺、倒走就留痕。任何把缺口填成平滑曲线的实现都是错。

### B. 标准 key

| # | 操作 | 期望 | 不符怎么查 |
| --- | --- | --- | --- |
| B1 | 开户脚本跑完 | 打印「标准 key 核对通过」 | 见 [③ 开户](/admin/onboard) 的核对小节 |
| B2 | 查字典与设备属性是否对齐 | 电表需要的一级指标在 `key_dictionary` 里都有 | 下面的 SQL |
| B3 | 看某台表实际报了哪些 key | 至少含 `energy_reading`；三相表含 `U/I/P/Q/S/PF/Freq` | 下面第二条 SQL |

```sql
-- B2：电表档案声明要的 key，逐个查是否已注册
SELECT k.key FROM key_dictionary k WHERE k.key LIKE 'energy%' ORDER BY 1;

-- B3：这台表窗口内实际报了什么（设备名换成实际名称）
SELECT k.key, count(*) AS rows,
       to_timestamp(min(t.ts)/1000)::date AS first_day,
       to_timestamp(max(t.ts)/1000)::date AS last_day
FROM ts_kv t
JOIN key_dictionary k ON t.key = k.key_id
JOIN device d ON d.id = t.entity_id
WHERE d.name = 'PowerMeter-1P-SIM·平台演示中心'
GROUP BY 1 ORDER BY 1;
```

**本仓库实测输出（2026-11-15）**，单相表报了 12 个 key：

```
energy_reading | 5473 | 2026-10-03 | 2026-11-15
energy         | 5380 | 2026-10-03 | 2026-11-15
voltage_a      | 5473 | ...
current_a      | 5473 | ...
power_total    | 5473 | ...
power_factor_total | 5473 | ...
frequency      | 5473 | ...
carbon_emission    | 4635 | ...
current_thd_a / voltage_deviation_a / power_a / power_factor_a | 97~758 | ...
```

> **两条容易搞反的判断**：
> 1. **别把「字典里有」当成「设备报了」**。字典是期望，`ts_kv` 才是事实。
> 2. **别把「只报了 energy_reading」当成故障** —— 但也有反面：
>    实测这台**单相**表连 `current_a` / `power_total` / 谐波都有，
>    所以「单相表只有总电量」这个预判是错的。以这台表实际档案要求为准。
>
> 返回空则先确认设备名（用 `SELECT d.name FROM device d WHERE d.name ILIKE '%Meter%'` 核对），
> 再确认该时间窗内有没有数据 —— 新接入的表可能当月才开始报。

### C. 统计准确率（客户最关心的一条）

| # | 操作 | 期望 | 不符怎么查 |
| --- | --- | --- | --- |
| C1 | 挑一台表，页面月用量 vs SQL 手算 | 两个数一致（差 < 0.01） | 用下面 C1 的 SQL 逐小时看，定位是哪个小时差 |
| C2 | 上级表 vs 下级表之和 | 上级 ≥ 下级之和，差额能解释为线损 | `04-verify-data.sh` 第 4 组 |
| C3 | 峰 / 平 / 谷三项相加 | 严格等于总量 | `EnergyBillingService#readUsage` 的 byType 累加 |
| C4 | 账单金额 vs 用量 × 电价 | 分毫不差（金额走「分」运算，不走浮点） | `EnergyBillingService` 的 `centsToYuan` / `totalCents` |
| C5 | 改一次倍率再出账 | 金额按倍数变化，不是不变 | 倍率来源见 [④ 数据模型](/admin/data-model)；`effectiveRatio` 三处差异见上文 |

**C1 的验算 SQL**（与账单、基线快照同一套口径）：

```sql
WITH hourly AS (
  SELECT date_trunc('hour', to_timestamp(t.ts/1000)) AS h,
         max(t.dbl_v) AS v
  FROM ts_kv t
  JOIN key_dictionary k ON t.key = k.key_id
  JOIN device d ON d.id = t.entity_id
  WHERE k.key = 'energy_reading'
    AND d.name = 'PowerMeter-1P-SIM·平台演示中心'
    AND t.ts >= EXTRACT(EPOCH FROM TIMESTAMPTZ '2026-10-03 00:00:00+08') * 1000
    AND t.ts <  EXTRACT(EPOCH FROM TIMESTAMPTZ '2026-11-01 00:00:00+08') * 1000
  GROUP BY 1
), diffed AS (
  SELECT h, v - lag(v) OVER (ORDER BY h) AS delta FROM hourly
)
SELECT round(sum(CASE WHEN delta > 0 THEN delta ELSE 0 END)::numeric, 4) AS usage,
       count(*) FILTER (WHERE delta < 0) AS backward_segments,
       count(*) FILTER (WHERE delta IS NOT NULL) AS segments
FROM diffed WHERE delta IS NOT NULL;
```

**本仓库实测输出（2026-11-15）**：

```
   usage   | backward_segments | segments
-----------+-------------------+----------
 4633.6200 |                 1 |      695
```

这个 `4633.62` 与基线快照里「单相园区 / elec / 用量 4633.62 / 倒走 1」
**逐位一致** —— 三者（本 SQL、账单口径、基线快照）互相印证。
如果你跑出来的数与页面不一致，先看下面三个数怎么读。

三个数怎么读：

- `usage` 应与页面「本期用量」一致（未乘倍率；页面若已乘倍率，除以倍率再比）；
- `backward_segments > 0` 说明这期间有表底倒走，页面上应该**有提示**，没有就是缺陷；
- `segments` 太少（比如整月只有 3 个点）说明数据断过，页面数字不可信，
  先去查 A3 / A4。

### D. 组织与权限

| # | 操作 | 期望 | 不符怎么查 |
| --- | --- | --- | --- |
| D1 | 客户账号登录，看场站列表 | 只出现自己名下场站 | `visible-sites` 返回体；`EnergyScopeService` |
| D2 | 给客户只授权 A 场站，然后改 B 场站费率 | 403，且库里没有新记录 | `node tools/verify-org-module.mjs --with-permissions` |
| D3 | 改一个场站档案名 | 组织级费率接口仍按 id 工作，不因改名 404 | 同上脚本的改名回归项 |
| D4 | 客户账号看左侧菜单 | 有「仪表板」且能进 `/dashboards/all` | 见 F1 |

> D2 是真出过的漏洞：原实现只比 `customer_id`，同客户下的未授权场站可写。
> 现在走场站组授权，验收必须覆盖「已授权 200 / 未授权 403」两侧。

### E. 抄表与账单

| # | 操作 | 期望 | 不符怎么查 |
| --- | --- | --- | --- |
| E1 | 新表第一次抄表 | 只建基线，用量为空，不报 0 | 抄表记录里应有首抄标记 |
| E2 | 人为把表底改小再抄 | `quality=abnormal`，不给用量，**基线不更新** | 抄表结果字段 `quality` / `reason` |
| E3 | 表连续 2 小时无上报 | 标「陈旧」，不沿用旧值当新读数 | 抄表接口的 stale 字段 |
| E4 | 出账前检查电价 | 未配电价的表在「跳过」清单里，并注明原因 | 出账返回的 `items[].reason` |
| E5 | 虚拟表（手工填报）出账 | 全部归入「平」档，并标 `touAssumedFlat=true` | 页面应显示「按时段方案估算」提示 |

### F. 看板与菜单

| # | 操作 | 期望 | 不符怎么查 |
| --- | --- | --- | --- |
| F1 | 客户账号进「仪表板」列表 | 只看到自己建的，**26 个能源套件一个都不出现** | 这是设计（铁律 D20）；出现即缺陷 |
| F2 | 客户从左侧菜单进「仪表板」 | HTTP 200，不是空白页 | `EnergyMenuInstaller#customerItems` |
| F3 | 租户账号看套件看板 | 26 个都在，能打开 | `DashboardController#ENERGY_TEMPLATE_DASHBOARDS` |
| F4 | 重装后首次登录 | 菜单与看板自动就位（启动期自愈） | `SystemPatchApplier#syncWidgetTypesOnBoot`；`node tools/check-ui-freshness.mjs` |

> F1 与 F3 是一对：客户看不到、租户看得到，才是对的。
> 只验一侧会把「过滤过宽」当成正常。

---

## 六、明确不测什么（写下来避免反复讨论）

| 不测 | 原因 |
| --- | --- |
| 每个页面的每个按钮 | 26 页面 × 全按钮，维护成本远高于收益；页面重构即全废 |
| 第三方 TB 内核行为 | 不是我们的代码；升级时由上游回归 |
| 性能 / 并发压测 | 当前规模（35 设备 / 千万级遥测）未到瓶颈；要做另开一次专项 |
| 浏览器兼容矩阵 | 现场只用 Chrome / Edge |
| 视觉像素比对 | 无基线图，且主题会变；靠人工看截图 |

需要时再单独开专项，不要偷偷塞进日常验收 —— 那会让「全绿」失去意义。

---

## 七、改统计口径的固定流程（铁律 D21）

任何会改变历史数字的改动（倍率、差分方式、峰谷归段、资产预汇总、单位换算），
按这个顺序做，**不许跳步**：

1. **先跑基线**，确认当前值与仓库里的基线一致（不一致先查清为什么）；
2. **改代码**；
3. **再跑 `--compare`**，逐条看 Δ —— 每一条差异都要能解释成「这次要改的目的」；
4. 解释不了的那条 = 意外影响，修掉；
5. 确认全部差异都可解释后，**重新生成基线并一起提交**（基线变更是改动的一部分，不是副作用）；
6. 手册的对应页同步更新口径描述（见 [运维总览](/admin/index) 的维护表）。

```bash
# 完整一轮
node tools/baseline-snapshot.mjs --compare tools/baseline/window-2026-09-01_2026-11-01.json
# ...改代码...
mvn -Dtest=MeteringMathTest test
node tools/baseline-snapshot.mjs --compare tools/baseline/window-2026-09-01_2026-11-01.json
# ...确认差异都能解释...
node tools/baseline-snapshot.mjs          # 覆盖基线
git add tools/baseline/ && git commit -m '口径变更：<说明>，基线同步'
```

**为什么要走这一套**：没有基线的口径改动，事后无法回答「这个数以前是多少」。
真出争议时（客户说「上个月不是这个数」），只有能 diff 的基线是证据。

---

## 八、清空重测：从零核对每个数字

调统计口径时，最麻烦的不是“算错”，而是**分不清这个数是这次改对了、还是上一轮留下的**。
这一节把“清空 → 灌已知数据 → 核对”变成可重复的三步。

### 为什么不能直接清库

实测（2026-11-15）：现场 RTU **每 3 秒上报一轮**。只清库不停上报，
清完 30 秒又有一千多条数据——“库里只有我灌的 2 条”这个前提根本不成立，
于是没法手算、也就没法判断对错。

更隐蔽的是：RTU 走 **MQTT 网关模式**（`v1/gateway/telemetry`），
鉴权用的是**网关**的令牌。只改子设备令牌，数据照样进来 ——
子设备令牌在这条路径上不参与鉴权。这一点是实测踩出来的，
第一版只暂停子设备，验证时发现还在写。

所以顺序必须是：**先暂停上报，再清库**。

### 一条命令：`rehearse-meters.py`

现在不用手工拼四步。这个脚本一次做完：清历史 → 每块表发 2 条 → 填报虚拟表
→ 重建汇总 → 打印对账清单 → 回读验证。

> **两个脚本在不同目录跑**，因为依赖不同：
> `47/48` 读 `.env` 找数据库 → 在**部署目录**；
> `rehearse-meters.py` 要读型号定义 `vendor_models.json` → 在**仓库根**。
> 写错目录会报「找不到设备」或「缺少 .env」。

`47` / `48` 放在**手册下载区**（`downloads/scripts/`），部署目录里默认没有。
首次使用先复制一次（脚本自己找 `.env`，复制不改任何配置）：

```bash
cp /path/to/iot-rule-engine/shiyongshouce/downloads/scripts/4[78]-*.sh ~/energy-app/scripts/
chmod +x ~/energy-app/scripts/4[78]-*.sh
```

```bash
# ── ① 暂停真实设备上报（部署目录，否则每 3 秒的实时数据会混进来）
cd ~/energy-app
bash scripts/48-pause-rtu-reporting.sh --pause

# ── ②③ 对账演练（仓库根）
cd /path/to/iot-rule-engine

python3 tools/rehearse-meters.py --date 2026-11-15 --dry-run        # 只看清单
python3 tools/rehearse-meters.py --date 2026-11-15 --clean true     # 清空→发数→验证

# ── ④ 测完恢复真实上报（部署目录）
cd ~/energy-app
bash scripts/48-pause-rtu-reporting.sh --resume
```

`rehearse-meters.py` 用 `docker exec energy-postgres psql` 直连数据库清数据，
所以**不需要 `.env`**；但它要读型号定义才能知道「该发哪些厂家代号」，
那份文件在仓库里，所以必须在仓库根执行。

参数：

| 参数 | 作用 |
| --- | --- |
| `--date YYYY-MM-DD` | 数据日期。**柱状图横轴选这一天**，只显示这一次的数据 |
| `--at HH:MM` | 第一个时间点（默认 10:00） |
| `--hours N` | 两点间隔小时（默认 1），第二个点因此是 11:00 |
| `--clean true` | 清该客户全部设备遥测 + 资产汇总 + 抄表记录 + 抄表基线 |
| `--clean meters-only` | 只清几块电表，不动其他设备 |
| `--clean false` | 追加，不清 |
| `--continue` | 接续库里最新表底（验证抄表用量时用） |
| `--virtual true\|false` | 是否同时填报虚拟表（默认 true） |
| `--dry-run` | 只打印计划与期望值 |

### 每块表只发 2 条，为什么

用量 = 相邻两个表底的差 × 倍率。**2 条 = 1 个差分区间 = 1 个用量值**，
每个数字都能手算。3 条以上会拆出多个区间，反而要分辨「哪个区间归哪个时段」。

时段归属是「用量记在**后一个点**所在时段」。第二个点定在 11:00 ——
这个时刻在冬季工作日方案（08-11 平 / 11-13 峰）和周末方案里**都是峰**，
所以峰一定有数、平/尖/谷为 0，不会出现「一半在峰一半在平」需要猜。

### 5 台设备分别挂在不同维度，柱子才有层次

分项能耗页、区域能耗页的柱子高度 = 该节点下所有表的合计。
若两台表挂在同一个分项下，它们会被合并成一根柱子，看不出谁贡献多少。
所以 5 台表**一个分项只放一台、一个区域只放一台、一个能耗类型只放一台**：

```
生产园区  动力分项 / 生产车间区域 / 生产用能   正泰三相 DTSD3366D   10000
          照明分项 / 锅炉房区域 / 公共用能     雅达三相 YDPQ200-A      240
          给排水分项 / 办公区区域 / 办公用能   虚拟三相                800
办公园区  照明分项 / A栋办公区区域 / 办公用能  正泰单相 DDSU666         10
          插座分项 / 公共区域区域 / 公共用能   虚拟单相                120
```

重排用的脚本：

```bash
python3 tools/spread-meter-dims.py --dry-run
python3 tools/spread-meter-dims.py
```

### 页面上怎么分开看：数据来源下拉

5 台表里有两台是**虚拟表**（手工填报，一个月一个数）。它们与实时表混在一起看时，
月值会被摊成日均（800 ÷ 30 = 26.7）—— 所以顶部「数据来源」下拉要分开选：

```
实时设备（默认）  → 只有 RTU / 采集上来的真实表
虚拟设备         → 只有手工填报的虚拟表，且粒度锁定「按年」
```

> 选「虚拟设备」时「按日 / 按月」会被自动收起，只剩「按年」。
> 原因：手工填报本身是**月粒度**，没有日/小时分布；
> 允许按日查看就只能靠「月值 ÷ 当月天数」编一个日值出来 —— 那是造数，不是统计。

> **注意**：虚拟表的分项关系由**手工填报接口**决定 —— 保存时它会把设备挂到
> 这次传的 `itemId` 下并解除旧关系。所以 `rehearse-meters.py` 里的
> `VIRTUAL_PLAN.item` 必须与 `spread-meter-dims.py` 的分配一致，
> 否则每跑一次演练柱子就挪一次位置，看着像「分摊随机变了」。

### 两个脚本的边界

| 脚本 | 做什么 | 不做什么 |
| --- | --- | --- |
| `47-reset-customer-data.sh` | 清遥测/抄表/账单/告警/诊断/抄表基线 | 不删客户、设备、组织、看板、字典、费率 |
| `48-pause-rtu-reporting.sh` | 轮换令牌暂停上报，`--resume` 原样恢复 | 不动硬件、不断网、不改网络配置 |

`47` 的安全机制（每次都会跑，不是可选）：

- 删前删后各取一次“非目标客户”的实体指纹（数量 + id md5），必须逐位相同；
- 遥测总数必须满足「删后 = 删前 − 实删」；
- 不清零就退出码 2，不会静默通过。

### 为什么必须清“抄表基线”

抄表把上次读数存在**设备属性** `lastReading` 里，不在遥测里。
只清 `ts_kv` 不清基线，下一轮会拿旧基线（例如 12970）去减新种子值（例如 100）
→ 判「表底倒走」→ `quality=abnormal`、用量为空。
**症状看起来像统计坏了，实际是基线没清。**

### 实测结果（可作对照）

三块真实表各 2 条（10:00 / 11:00），两个虚拟表各填一个月用量：

```
表           表底 10:00  表底 11:00  表底差  倍率   用量 kWh
正泰单相          1000        1010      10     1        10
正泰三相          2000        2005       5  2000     10000
雅达三相          3000        3006       6    40       240
虚拟单相             —           —       —     —       120（月）
虚拟三相             —           —       —     —       800（月）
```

按「日」查看（2026-11-15）—— 只有真实表：

```
峰谷 · 生产园区    峰 10240   平 0   合计 10240
峰谷 · 办公园区    峰    10   平 0   合计    10
峰谷 · 总部        峰 10250         合计 10250
```

按「自然月」查看（2026-11）—— 真实表 + 虚拟表：

```
场站 · 三相园区    10240 + 800 = 11040
场站 · 单相园区       10 + 120 =   130
场站 · 总部        10250 + 920 = 11170
峰谷 · 总部        峰 10250   平 920（虚拟表无小时分布，全归平档）
```

三个维度各 5 根柱子（值相同，只是切法不同）：

```
10000 / 800 / 240 / 120 / 10
```

> **判据**：如果某个维度只有 2~3 根柱子，或某根柱子是两根表之和（例如 10800），
> 说明设备还挂在同一个节点下 —— 跑 `spread-meter-dims.py` 重排。

### 两个必须分开看的时间点

上面的对账表里出现两种时间点，它们**不是重复计数**：

| 时间点 | 来源 | 含义 |
| --- | --- | --- |
| `11-01 00:00` | 虚拟表 | 整月用量（月粒度） |
| `11-15 11:00` | 真实表 | 当天这一小时的用量（小时粒度） |

所以按「某一天」查时看不到虚拟表，按「自然月」查时两者都在。
对账前先确认自己在哪个粒度上，否则会误判成「少了 800」。

### ⚠️ 一个会让数字凭空消失的坑：`dbl_v` 与 `long_v`

时间序列的值在 `ts_kv` 里**分列存储**，TB 按值本身选列：

| 上报的值 | 落在哪列 |
| --- | --- |
| `1010.5`（带小数） | `dbl_v` |
| `1010`（整数） | **`long_v`** |

所以 `SELECT ... max(t.dbl_v)` 对**整数表底的设备**会返回空。
实测：某设备 2 个点，只查 `dbl_v` 得 **0 条**，加 coalesce 得 **2 条**。

正确写法：

```text
coalesce(t.dbl_v, t.long_v::double precision)
```

> **这坑影响了哪些脚本**（2026-11-15 已全部修复）：
> `04-verify-data.sh`、`06-verify-e2e.sh`、
> `08-verify-release.sh`（两处）、`09-onboard-customer.sh`、
> `tools/baseline-snapshot.mjs`。
>
> 后端 Java 不受影响 —— TB 的 `TsKvEntry.getDoubleValue()` 内部兼容两列。
> 只有**直查 SQL 的脚本**会中招。

这和铁律 E1 里「查属性不能只查一列」是同一类错误，只是从 `attribute_kv` 搬到了 `ts_kv`。

### 核对 SQL

```sql
WITH hourly AS (
  SELECT date_trunc('hour', to_timestamp(ts/1000)) AS h,
         max(coalesce(dbl_v, long_v::double precision)) AS v
  FROM ts_kv t JOIN key_dictionary k ON k.key_id = t.key
  WHERE k.key = 'energy_reading'
    AND t.entity_id = '<设备id>'
    AND coalesce(dbl_v, long_v::double precision) IS NOT NULL
  GROUP BY 1
), diffed AS (
  SELECT h, v - lag(v) OVER (ORDER BY h) AS d FROM hourly
)
SELECT round(sum(CASE WHEN d > 0 THEN d ELSE 0 END)::numeric, 4) AS usage,
       count(*) FILTER (WHERE d < 0) AS backward_segments,
       count(*) FILTER (WHERE d IS NOT NULL) AS segments
FROM diffed WHERE d IS NOT NULL;
```

期望：`usage = 10.0000`、`backward_segments = 0`、`segments = 1`。

### 资产汇总要手动触发一次

设备数据不会自动流到资产维度（`energy_total` 是另写的汇总）。
灌完数据后调一次：

```bash
curl -X POST "$BASE/api/energy/asset-totals/rebuild" \
  -H "X-Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"customerId":"<客户id>","days":30}'
```

返回 `{"ok":true,"assetsWritten":12,...}`。然后再查资产 `energy_total` 是否为 10。

---

## 九、逐功能对账 SQL（复制即用）

这一节的 SQL 回答一个问题：**页面上那个数字，库里到底是多少。**
全部实测跑通 —— `check-docs.py` 会逐条执行，跑不通就算文档错误。

在部署目录里这样调用（`-f -` 从标准输入读）：

```bash
cd ~/energy-app
docker compose exec -T postgres psql -U postgres -d thingsboard -v ON_ERROR_STOP=1 < 查询.sql
```

或者交互式进去粘贴：

```bash
docker compose exec postgres psql -U postgres -d thingsboard
```

> **两条铁律，先记住再看 SQL**
> 1. 值分列存储：小数在 `dbl_v`，**整数在 `long_v`**。所有取值一律
>    `coalesce(t.dbl_v, t.long_v::double precision)`，只查 `dbl_v` 会把整数表底整个漏掉。
> 2. `ts_kv.key` 是**整数外键**，必须 `JOIN key_dictionary k ON k.key_id = t.key`
>    （字典表列是 `key` / `key_id`，没有 `id`）。

### 9.1 设备层：表底与派生用量

对账对象：抄表页的「当前表底」、峰谷分析的「用量」。

```sql
SELECT d.name AS 设备,
       k.key AS 指标,
       to_timestamp(t.ts/1000)::timestamp(0) AS 时间,
       coalesce(t.dbl_v, t.long_v::double precision) AS 值
FROM ts_kv t
JOIN key_dictionary k ON k.key_id = t.key
JOIN device d ON d.id = t.entity_id
WHERE k.key IN ('energy_reading', 'energy')
  AND d.name IN ('PowerMeter-DDSU666', 'PowerMeter-3P-CHINT·平台演示中心',
                 'PowerMeter-3P-YADA·平台演示中心')
ORDER BY d.name, k.key, t.ts;
```

实测输出（`rehearse-meters.py --date 2026-11-15` 之后）：

```
设备                             指标            时间                 值
PowerMeter-3P-CHINT·平台演示中心 energy          2026-11-15 11:00:00  10000
PowerMeter-3P-CHINT·平台演示中心 energy_reading  2026-11-15 10:00:00  2000
PowerMeter-3P-CHINT·平台演示中心 energy_reading  2026-11-15 11:00:00  2005
PowerMeter-3P-YADA·平台演示中心  energy          2026-11-15 11:00:00  240
PowerMeter-3P-YADA·平台演示中心  energy_reading  2026-11-15 10:00:00  3000
PowerMeter-3P-YADA·平台演示中心  energy_reading  2026-11-15 11:00:00  3006
PowerMeter-DDSU666              energy          2026-11-15 11:00:00  10
PowerMeter-DDSU666              energy_reading  2026-11-15 10:00:00  1000
PowerMeter-DDSU666              energy_reading  2026-11-15 11:00:00  1010
```

怎么读：

- `energy_reading` 是**表底**（两次上报的差就是用量）；
- `energy` 是**平台算出的用量**（表底差 × 倍率），由重建汇总时派生写回；
- 上面还有第 4 个点（脚本刷新 latest 的时刻），表底与 11:00 相同 → 差为 0 →
  **不产生 `energy` 点**。这是设计：「表底没动」不等于「用了 0」。

### 9.2 场站层：三个汇总键一起看

对账对象：概览页的「今日用电」、实时功率。

```sql
SELECT a.name AS 场站,
       k.key AS 指标,
       to_timestamp(t.ts/1000)::timestamp(0) AS 时间,
       round(coalesce(t.dbl_v, t.long_v::double precision)::numeric, 2) AS 值
FROM ts_kv t
JOIN key_dictionary k ON k.key_id = t.key
JOIN asset a ON a.id = t.entity_id
WHERE k.key IN ('energy_total', 'energy_day', 'power_total')
  AND a.name IN ('三相园区·平台演示中心', '单相园区·平台演示中心', '总部·平台演示中心')
ORDER BY a.name, k.key, t.ts;
```

实测输出：

```
场站                 指标          时间                 值
三相园区·平台演示中心 energy_day    2026-11-01 00:00:00   800.00
三相园区·平台演示中心 energy_day    2026-11-15 11:00:00 10240.00
三相园区·平台演示中心 energy_total  2026-11-01 00:00:00   800.00
三相园区·平台演示中心 energy_total  2026-11-15 11:00:00 10240.00
三相园区·平台演示中心 power_total   2026-11-15 10:00:00 10240.00
三相园区·平台演示中心 power_total   2026-11-15 11:00:00 10240.00
单相园区·平台演示中心 energy_day    2026-11-01 00:00:00   120.00
单相园区·平台演示中心 energy_day    2026-11-15 11:00:00    10.00
总部·平台演示中心     energy_day    2026-11-01 00:00:00   920.00
总部·平台演示中心     energy_day    2026-11-15 11:00:00 10250.00
```

怎么读：

- **两个时间点是两种数据**：`11-01 00:00` 是虚拟表的**月点**（整月用量），
  `11-15 11:00` 是真实表的**日用量**。它们不是重复计数，是不同粒度；
- `energy_day` 与 `energy_total` 在这套数据里数值相同 —— `energy_total` 是该时刻的
  区间用量，`energy_day` 是当日累计，单日数据下两者重合；
- `power_total` 只有真实表有（虚拟表没有瞬时功率）。

### 9.3 三个维度：分项 / 区域 / 能耗类型

对账对象：分项能耗页、区域能耗页、综合能耗的图例与柱高。

一条 SQL 把三个维度一起列出来：

```sql
SELECT a.type AS 维度,
       a.name AS 节点,
       round(sum(coalesce(t.dbl_v, t.long_v::double precision))::numeric, 2) AS 合计
FROM ts_kv t
JOIN key_dictionary k ON k.key_id = t.key
JOIN asset a ON a.id = t.entity_id
WHERE k.key = 'energy_total'
  AND a.type IN ('分项', '区域', '能耗类型')
  AND (a.name LIKE '%生产园区%' OR a.name LIKE '%办公园区%')
GROUP BY a.type, a.name
ORDER BY a.type, 合计 DESC;
```

实测输出（三个维度各 5 根柱子，值完全一致）：

```
维度     节点                                  合计
分项     动力分项·生产园区·平台演示中心        10000.00
分项     给排水分项·生产园区·平台演示中心        800.00
分项     照明分项·生产园区·平台演示中心          240.00
分项     插座分项·办公园区·平台演示中心          120.00
分项     照明分项·办公园区·平台演示中心           10.00
区域     生产车间区域·生产园区·平台演示中心    10000.00
区域     办公区区域·生产园区·平台演示中心        800.00
区域     锅炉房区域·生产园区·平台演示中心        240.00
区域     公共区域区域·办公园区·平台演示中心      120.00
区域     A栋办公区区域·办公园区·平台演示中心      10.00
能耗类型 生产用能能耗类型·生产园区·平台演示中心 10000.00
能耗类型 办公用能能耗类型·生产园区·平台演示中心   800.00
能耗类型 公共用能能耗类型·生产园区·平台演示中心   240.00
能耗类型 公共用能能耗类型·办公园区·平台演示中心   120.00
能耗类型 办公用能能耗类型·办公园区·平台演示中心    10.00
```

> **三个维度必须数值一致**。同一台表只能挂一个分项、一个区域、一个能耗类型，
> 所以三个维度是同一批用电的三种切法，合计必然相同。
> 如果某维度多出柱子、或数值翻倍，就是设备被挂了两个同类节点 ——
> 用 9.7 的「维度唯一性」SQL 能查出来。

### 9.4 峰谷：按小时差分

对账对象：峰谷分析页的峰/平/尖/谷/深谷。

```sql
WITH hourly AS (
  SELECT t.entity_id,
         date_trunc('hour', to_timestamp(t.ts / 1000)) AS 小时,
         max(coalesce(t.dbl_v, t.long_v::double precision)) AS 表底
  FROM ts_kv t
  JOIN key_dictionary k ON k.key_id = t.key
  WHERE k.key = 'energy_reading'
    AND coalesce(t.dbl_v, t.long_v::double precision) IS NOT NULL
  GROUP BY 1, 2
), diffed AS (
  SELECT entity_id, 小时,
         表底 - lag(表底) OVER (PARTITION BY entity_id ORDER BY 小时) AS 表底差
  FROM hourly
)
SELECT to_timestamp(extract(epoch FROM 小时))::timestamp(0) AS 时段,
       count(*) FILTER (WHERE 表底差 > 0) AS 有增量表数,
       round(sum(表底差) FILTER (WHERE 表底差 > 0)::numeric, 2) AS 表底差合计,
       count(*) FILTER (WHERE 表底差 < 0) AS 倒走表数
FROM diffed
WHERE 表底差 IS NOT NULL
  AND entity_id IN (SELECT id FROM device WHERE name IN
      ('PowerMeter-DDSU666', 'PowerMeter-3P-CHINT·平台演示中心',
       'PowerMeter-3P-YADA·平台演示中心'))
GROUP BY 1 ORDER BY 1;
```

实测输出：

```
时段                 有增量表数 表底差合计 倒走表数
2026-11-15 11:00:00          3      21.00        0
2026-11-16 00:00:00          0                  0
```

怎么读：

- `表底差合计 21` = 10 + 5 + 6（三块表的表底差之和，**未乘倍率**）；
- 乘倍率后才是页面上看到的：`10×1 + 5×2000 + 6×40 = 10250`；
- 时段归属规则是「用量算在**后一个点**所在时段」。两点是 10:00 和 11:00，
  所以整段归 11:00 —— 11:00 在冬季工作日与周末方案里都是「峰」；
- 第二行 `有增量表数 = 0` 是刷新 latest 产生的（表底未变），不产生用量。

### 9.5 抄表：基线与用量

对账对象：抄表页的「上次/本次读数」「用量」「倍率」。

```sql
SELECT device_name AS 设备,
       period AS 账期,
       prev_reading AS 上期表底,
       curr_reading AS 本期表底,
       usage AS 用量,
       ratio AS 倍率,
       quality AS 质量,
       source AS 来源
FROM meter_reading_record
WHERE period = '2026-11'
ORDER BY created_time DESC
LIMIT 20;
```

实测输出（首次抄表只建基线，`usage` 为空是对的）：

```
设备                     账期    上期表底 本期表底 用量    倍率    质量   来源
正泰三相电表 DTSD3366D   2026-11          2005.0000        2000.0 normal auto
正泰单相电表 DDSU666     2026-11          1010.0000           1.0 normal auto
雅达三相电表 YDPQ200-A   2026-11          3006.0000          40.0 normal auto
```

> **`device_name` 存的是设备 label，不是 name**。所以这里看到「正泰三相电表 DTSD3366D」，
> 而 `device` 表里叫 `PowerMeter-3P-CHINT·平台演示中心`。按 name 查抄表记录会查不到 ——
> 这不是数据丢了。

想验证「抄表乘倍率」，再跑一次 `--continue` 让表底前进，然后对比：

```
正泰三相：表底 2005 → 2010，差 5，× 2000 = 10000
雅达三相：表底 3006 → 3012，差 6，× 40   = 240
```

### 9.6 虚拟表：月首一个点

对账对象：手工填报页、分项能耗里的虚拟表贡献。

```sql
SELECT d.name AS 虚拟表,
       d.additional_info::jsonb->>'deviceVirtual' AS 虚拟标记,
       to_timestamp(t.ts/1000)::timestamp(0) AS 时间,
       coalesce(t.dbl_v, t.long_v::double precision) AS 月用量
FROM ts_kv t
JOIN key_dictionary k ON k.key_id = t.key
JOIN device d ON d.id = t.entity_id
WHERE k.key = 'energy'
  AND d.additional_info::jsonb->>'deviceVirtual' = 'virtual'
ORDER BY d.name, t.ts;
```

实测输出：

```
虚拟表                 虚拟标记 时间                月用量
VirtualMeter-1P-Socket virtual  2026-11-01 00:00:00    120
VirtualMeter-3P-Power  virtual  2026-11-01 00:00:00    800
```

> **虚拟表是月粒度**：一个点代表整月用量。所以按「某一天」查询时它不出现，
> 只有查询范围包含当月 1 号、或按自然月统计时才看得到。
> 这不是缺数据，是两种粒度共存 —— 对账时必须分开看（见 9.2 的两类时间点）。

### 9.7 设备挂载检查：维度唯一性与标准 key 覆盖

**维度唯一性**（每台表应各挂 1 个分项 / 区域 / 能耗类型）：

```sql
SELECT d.name AS 设备,
       count(*) FILTER (WHERE ap.name = '分项') AS 分项数,
       count(*) FILTER (WHERE ap.name = '区域') AS 区域数,
       count(*) FILTER (WHERE ap.name = '能耗类型') AS 类型数
FROM device d
JOIN relation r ON r.to_id = d.id AND r.to_type = 'DEVICE'
JOIN asset a ON a.id = r.from_id
JOIN asset_profile ap ON ap.id = a.asset_profile_id
WHERE ap.name IN ('分项', '区域', '能耗类型')
GROUP BY d.name
HAVING count(*) > 0
ORDER BY d.name;
```

每个数字都应为 `1`。出现 `2` 就是同一台表挂在两个同类节点下 → 图上重复计数。

**标准 key 覆盖**（声明的指标是否真的落库）：

```sql
SELECT d.name AS 设备,
       count(DISTINCT mp.key) AS 声明指标数,
       count(DISTINCT kk.key) FILTER (WHERE t.entity_id IS NOT NULL) AS 已落库指标数
FROM device d
JOIN attribute_kv ak ON ak.entity_id = d.id AND ak.attribute_type = 2
JOIN key_dictionary kd ON kd.key_id = ak.attribute_key AND kd.key = 'measurePoints'
JOIN LATERAL (
  SELECT jsonb_array_elements(ak.json_v::jsonb) ->> 'standardField' AS key
) mp ON true
LEFT JOIN key_dictionary kk ON kk.key = mp.key
LEFT JOIN ts_kv t ON t.key = kk.key_id AND t.entity_id = d.id
WHERE d.name IN ('PowerMeter-DDSU666', 'PowerMeter-3P-CHINT·平台演示中心',
                 'PowerMeter-3P-YADA·平台演示中心')
GROUP BY d.name ORDER BY d.name;
```

实测输出：

```
设备                             声明指标数 已落库指标数
PowerMeter-3P-CHINT·平台演示中心         60           34
PowerMeter-3P-YADA·平台演示中心          61           45
PowerMeter-DDSU666                      60            8
```

怎么读：

- `声明指标数` 来自设备的 `measurePoints`，**含通用兜底**（单相表上也带着 Ub / Ic / Pa
  这些三相代号），所以是 60 左右；
- `已落库指标数` 是这台表实际报上来的 —— 正好等于该型号的寄存器条数
  （正泰三相 34、雅达 45、正泰单相 8）；
- 两者差距正常，**不是缺数据**。要判断「该报的有没有报」，看型号寄存器条数，不看 60。

### 9.8 数据新鲜度：抄表前必查

抄表只认「此刻」的读数，超过 10 分钟判陈旧、不出用量。所以抄表前先看这张表：

```sql
SELECT d.name AS 设备,
       coalesce(t.dbl_v, t.long_v::double precision) AS 最新表底,
       to_timestamp(t.ts / 1000)::timestamp(0) AS 上报时间,
       round((extract(epoch FROM (now() - to_timestamp(t.ts / 1000))) / 60)::numeric, 1) AS 分钟前,
       CASE WHEN extract(epoch FROM (now() - to_timestamp(t.ts / 1000))) <= 600
            THEN '新鲜（可抄表）' ELSE '陈旧（需先补数据）' END AS 判定
FROM ts_kv_latest t
JOIN key_dictionary k ON k.key_id = t.key
JOIN device d ON d.id = t.entity_id
WHERE k.key = 'energy_reading'
  AND d.name IN ('PowerMeter-DDSU666', 'PowerMeter-3P-CHINT·平台演示中心',
                 'PowerMeter-3P-YADA·平台演示中心')
ORDER BY d.name;
```

实测输出：

```
设备                             最新表底 上报时间             分钟前 判定
PowerMeter-3P-CHINT·平台演示中心     2005 2026-11-16 00:28:28    1.4 新鲜（可抄表）
PowerMeter-3P-YADA·平台演示中心      3006 2026-11-16 00:28:28    1.4 新鲜（可抄表）
PowerMeter-DDSU666                 1010 2026-11-16 00:28:28    1.4 新鲜（可抄表）
```

判「陈旧」时的补救（不改任何统计值，只把 latest 时间戳推到当下）：

```bash
# 仓库根执行
python3 tools/rehearse-meters.py --clean false --continue
```

---


### 9.9 分源键：实时设备 vs 虚拟设备

**为什么有这一节**（2026-11-16 客户实测反馈）：

> 「分项能耗里虚拟表『给排水』应该是 800 kWh 的月值，
>  怎么每天都是 26.7？这样不合理。」

根因不是算错，是**两种粒度被混在一起**：

- 实时表（RTU / 采集）上报的是**小时级**表底，日、月、年都能算；
- 虚拟表是**手工填报**，一个月只有一个数（月首 00:00 一个点 = 整月用量）。

混在同一个 `energy_total` 里时，统计图为了让月点能画在日轴上，
会把它按天数摊开：800 ÷ 30 = 26.7/天。数字看着像真曲线，其实是除出来的。

现在后端按来源分别落键：

```
energy_total          全部（实时 + 虚拟，兼容旧看板）
energy_total_real     只有实时表
energy_total_virtual  只有虚拟表（月级）
```

功率与日累计同理：`power_total_real` / `power_total_virtual`、
`energy_day_real` / `energy_day_virtual`。

**按年合计对账（实测输出）**：

```sql
SELECT a.type AS 维度, a.name AS 节点,
       round(sum(CASE WHEN k.key = 'energy_total'
                      THEN coalesce(t.dbl_v, t.long_v::double precision) ELSE 0 END)::numeric, 1) AS 全部,
       round(sum(CASE WHEN k.key = 'energy_total_real'
                      THEN coalesce(t.dbl_v, t.long_v::double precision) ELSE 0 END)::numeric, 1) AS 实时设备,
       round(sum(CASE WHEN k.key = 'energy_total_virtual'
                      THEN coalesce(t.dbl_v, t.long_v::double precision) ELSE 0 END)::numeric, 1) AS 虚拟设备
FROM asset a
LEFT JOIN ts_kv t ON t.entity_id = a.id
LEFT JOIN key_dictionary k ON k.key_id = t.key AND k.key LIKE 'energy_total%'
WHERE a.type IN ('分项', '区域', '场站')
  AND a.name LIKE '%平台演示中心%'
GROUP BY a.type, a.name
HAVING count(k.key) > 0
ORDER BY a.type, a.name;
```

实测输出：

```
维度  节点                                全部     实时设备  虚拟设备
分项  动力分项·生产园区                   10000.0  10000.0     0.0
分项  插座分项·办公园区                     120.0      0.0   120.0
分项  照明分项·办公园区                      10.0     10.0     0.0
分项  照明分项·生产园区                     240.0    240.0     0.0
分项  给排水分项·生产园区                   800.0      0.0   800.0
区域  A栋办公区区域·办公园区                 10.0     10.0     0.0
区域  公共区域区域·办公园区                 120.0      0.0   120.0
区域  办公区区域·生产园区                   800.0      0.0   800.0
区域  生产车间区域·生产园区               10000.0  10000.0     0.0
区域  锅炉房区域·生产园区                   240.0    240.0     0.0
场站  三相园区                            11040.0  10240.0   800.0
场站  单相园区                              130.0     10.0   120.0
```

怎么读：

- **场站「全部」= 实时 + 虚拟**：三相园区 11040 = 10240 + 800；单相园区 130 = 10 + 120。
  这是「按年合计」，两个时间点相加本来就对 —— 一个是 11 月的月值，一个是 11-15 的日值；
- **每个叶子节点只属于一个来源**：一台表要么是实时表、要么是虚拟表，
  所以同级的「实时设备」与「虚拟设备」两列必有一列为 0。
  两列同时非零说明该节点下混挂了两类表（本身合法，但要按来源分开看）；
- 页面上的对应开关：分项能耗 / 区域能耗 / 能耗概览顶部的**「数据来源」下拉**。
  选「实时设备」时统计图读 `_real` 键、粒度仍是按日/按月/按年；
  选「虚拟设备」时读 `_virtual` 键，且**只允许按年**（虚拟表是月粒度，
  按月/按日去查只能靠除法造数）。

> **判据**：切到「虚拟设备 → 按年」，给排水分项应该只有 11 月一根柱 = **800**；
> 切到「实时设备」，给排水分项应该是**空**（它下面只有虚拟表）。
> 如果实时档下给排水还有 26.7/天，说明还在读旧的 `energy_total`。

### 9.10 改了部件为什么不生效（两个必知的坑）

改完 `guard-server/src/main/data/json/system/widget_types/*.json` 后，
页面刷新看不到变化，通常是下面两个原因之一：

**坑一：系统部件的真正来源是部署目录，不是 jar**

启动时平台从 **`~/energy-app/data/json/system/widget_types/`** 导入系统部件
（该目录 `data` 挂载到容器的 `/opt/energy/data`）。只改仓库里的 JSON、
不复制到部署目录，重启也还是旧部件。

```bash
# 改完仓库里的部件后，必须同步一次
cp guard-server/src/main/data/json/system/widget_types/<部件>.json \
   ~/energy-app/data/json/system/widget_types/

cd ~/energy-app && docker compose restart energy-server
```

**坑二：`check-widget-sync.mjs` 会真的写文件**

它的用途是「检查源码生成脚本是否与线上部件一致」，
但**执行时会真的运行构建脚本**。实测（2026-11-16）：
跑一次它把 `energy_management_distribution_chart.json` 覆盖成了旧版源码，
丢了 9 个函数（`pickable` / `batchSeries` / `loadBrief` …），
而它自己的输出只是「会被改动：templateHtml, controllerScript」——
看起来像只做了检查。

> 要跑它，先 `cp` 一份 widget_types 目录；或者干脆别跑，
> 用 `node --check` 校验脚本语法 + 页面实测。

**怎么确认线上部件是新版**

```bash
TOK=$(curl -s -X POST http://127.0.0.1:8090/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"tenant@126.com","password":"12345678"}' | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')

curl -s -H "X-Authorization: Bearer $TOK" \
  "http://127.0.0.1:8090/api/widgetTypes?isSystem=true&bundleAlias=energy_management" \
  | python3 -c "
import json,sys
for w in json.load(sys.stdin):
    cs=(w.get('descriptor') or {}).get('controllerScript') or ''
    print(w['fqn'], 'v' + str(w.get('version')), '长度', len(cs),
          '含新逻辑' if 'sourceMode' in cs else '还是旧的')
"
```

看板引用的是 `system.energy_management.*`（系统级），
所以用租户账号 `POST /api/widgetType` 只会建出一个**租户级副本**，
看板根本不会用它 —— 这一点也是实测踩出来的。

## 十、出问题时的第一反应

| 现象 | 先看 |
| --- | --- |
| 验收脚本红了 | 脚本输出的失败项自带「缺什么、怎么修」；再看 [⑨ 排障](/admin/troubleshoot) |
| 页面数字和 SQL 不一致 | 先确认口径（是否乘倍率、时区、窗口边界 `[from, to)`），再查 `04-verify-data.sh` 第 3 组 |
| 单测红了 | 先判断是「预期变更」还是「真回归」；预期变更要**同时**改测试和口径注释（铁律 E1d） |
| 基线 diff 出现无法解释的 Δ | 停下来查清再继续，不许「先合了再说」 |

> 铁律 E1c：结论必须当时可验证。报告里写「全部通过」时，附上退出码或报告路径，
> 不要只写结论。
