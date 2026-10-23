# 客户生命周期：开户 · 演示数据 · 销户

这一页把「一家合作企业从开通到退出」的完整流程写全，每条命令都能直接复制执行。

适用对象：**平台运营方**。客户自己只需要登录、建设备、接 RTU。

---

## 一、全景：一家客户的一生

```
① 开户（一条命令，约 3 分钟）
      bash scripts/09-onboard-customer.sh --email 客户邮箱 --password 密码 --name 客户名
      ↓
② 交钥匙（把账号发给客户）
      客户登录 → 直接看到「能耗概览」+ 13 项菜单 + 演示数据
      ↓
③ 客户动手（改造成自己的）
      a. 清掉演示数据
      b. 建自己的场站 → 分项 → 设备 → 拓扑
      c. 点一次「重算汇总」（★ 容易漏）
      d. 接 RTU
      ↓
④ 日常运营（费率、账单、告警）
      ↓
⑤ 销户（合作结束，或建错了要重来）
      bash scripts/10-cleanup-customer.sh --name 客户名 --dry-run   # 先看
      bash scripts/10-cleanup-customer.sh --name 客户名 --yes       # 再删
```

**两条硬规矩**：

1. **开户后一定能看到数** —— 演示数据 + 资产汇总遥测都会自动就位。
   如果客户登录看到空页面，不是「还没配」，是故障 —— 见[⑦ 数据流第六节](/admin/data-pipeline)。
2. **销户只动这一家** —— 脚本在删前删后各拍一次「其他世界」的指纹快照，
   不一致就报错退出，绝不静默通过。

---

## 二、开户：一条命令

### 2.1 命令

```bash
cd ~/energy-app
bash scripts/09-onboard-customer.sh \
  --email customer2@company.com \
  --password 'Cust@123456' \
  --name '某某公司'
```

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `--email` | ✓ | 客户登录账号，也是客户名默认来源（邮箱前缀） |
| `--password` | ✓ | 初始密码（客户首次登录后可改） |
| `--name` | | 客户名称；不传则取邮箱前缀 |
| `--no-demo` | | **不**生成演示数据（客户要直接用自己的数据时用） |
| `--base` | | 平台地址，默认 `http://127.0.0.1:8090` |
| `--tenant-email` / `--tenant-pass` | | 租户管理员凭据；默认从 `../DEPLOY-CREDENTIALS.txt` 读 |

### 2.2 它做了什么

| 步骤 | 动作 | 幂等 |
| --- | --- | --- |
| 1/3 | 建客户 + 建客户管理员账号并激活 | 同邮箱重跑会复用并重置密码 |
| 2/3 | 确保演示数据（2 场站 / 12 分项 / 21 设备 / 2 拓扑） | 已有则跳过 |
| 2/3 | **重算资产汇总遥测** | 按时间戳重写，不产生重复点 |
| 2/3 | 复制 20 个看板到客户名下 + 绑定 13 项菜单 | 已存在则跳过 |
| 3/3 | 逐项验证，缺任何一项就报错 | — |

### 2.3 期望输出

```
步骤 1/3　建客户与账号（复用 02-onboard.sh）
  ✓ 客户已建成
  ✓ 客户账号可登录
  ✓ 客户菜单已绑定（13 项）
    …（共 11 项验证）
步骤 2/3　确保演示数据（幂等：已有则跳过）
  ✓ 场站：2
  ✓ 分项（分类）：12
  ✓ 设备：21
  ✓ 拓扑图：2
  ✓ 客户看板：20
  ✓ 资产汇总已写入（15 个资产，看板场站维度可用）
步骤 3/3　逐项验证
  ✓ 客户菜单项：13
  ✓ 落地页（菜单第一项是 home）

  客户已开通
 账号       customer2@company.com
 客户名     某某公司
 客户 ID    2b22b6d0-…
```

同时生成 `ONBOARDED-<客户id>.txt`（权限 600），里面有账号密码，交付给客户后可以删掉。

### 2.4 交付给客户时说什么

```
平台地址   http://<你的域名或IP>:8090
账号       customer2@company.com
初始密码   Cust@123456

登录后你会看到「能耗概览」和左侧 13 项菜单，里面已经有一套演示数据
（2 个场站、21 台设备）—— 那是给你看效果的样板，不是真实数据。

接下来三步：
1. 设备运维 → 平台自检 → 「清除演示数据」
2. 自己建场站 / 分项 / 设备 / 拓扑（照着演示数据的结构建）
3. 建完点一次「重算汇总」，然后接 RTU
```

---

## 三、演示数据：四种操作，别搞混

演示数据只认一个标记：`additionalInfo.demo = true`。
**平台只删带这个标记的实体**，客户自己建的同名资产也不会被误删。

### 3.1 四种操作对照表

| 操作 | 谁来做 | 在哪做 | 效果 |
| --- | --- | --- | --- |
| **初始化** | 运营 / 租户管理员 | 客户列表 → 某行 → 「初始化演示数据」图标 | 补一套演示数据（已有则跳过） |
| **清除** | 运营 / 租户管理员 | 客户列表 → 某行 → 「清除演示数据」图标 | 删该客户的全部演示实体 |
| **客户自清** | 客户 | 设备运维 → 平台自检 → 「清除演示数据」 | 同上，但只作用于自己 |
| **重算汇总** | 客户 / 运营 | 接口（见 3.5）或客户列表初始化时自动 | 刷新 `energy_total`，不增删数据 |

### 3.2 初始化（运营侧）

**页面**：左侧「客户」→ 找到那家客户 → 行尾图标 → **初始化演示数据**

弹窗会说明：将生成 2 个场站、约 21 台设备、近 14 天逐小时遥测。
确认后返回「资产 N 个 / 设备 M 台」。

**接口**：

```bash
curl --noproxy '*' -s -X POST \
  -H "X-Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"customerId":"<客户id>","customerName":"某某公司"}' \
  http://127.0.0.1:8090/api/energy/demo-data
```

**什么时候用**：客户把演示数据清空了，又想看看样板；或者初始化时某步失败了要补。

### 3.3 清除（运营侧）

**页面**：左侧「客户」→ 行尾图标 → **清除演示数据**

点击时先查量：没有演示数据就直接提示「无需清理」，不弹确认框。
有的话弹窗写明「将删除资产 N 个、设备 M 台，此操作不可恢复；
只删带 demo 标记的实体，客户自建的不受影响」。

**接口**：

```bash
# 先看有多少
curl --noproxy '*' -s -H "X-Authorization: Bearer $TOKEN" \
  "http://127.0.0.1:8090/api/energy/demo-data?customerId=<客户id>"
# → {"devices":21,"assets":25,"customerId":"..."}

# 再删
curl --noproxy '*' -s -X DELETE -H "X-Authorization: Bearer $TOKEN" \
  "http://127.0.0.1:8090/api/energy/demo-data?customerId=<客户id>"
```

**什么时候用**：客户接入真实设备前清场；试用客户退出前清数据（但**客户本身**还在，
要连同账号一起删请走第五节销户）。

### 3.4 客户自己清（客户侧）

**路径**：客户登录 → 设备运维 → **平台自检** → 「演示数据」区块 → **清除演示数据**

客户账号调接口时不传 `customerId`，后端强制落到自己身上 —— 传别人的也会被忽略。

> 「生成演示数据」按钮**只对运营/租户显示**。客户点了会 403（后端只允许租户建），
> 所以前端干脆隐藏，避免让人看到点不动的按钮。
> 客户想恢复演示数据，请运营在客户列表一键初始化。

### 3.5 重算汇总（最容易被漏掉的一步）

**为什么需要**：看板在「选场站 / 选分项」时，读的是**资产**上的
`energy_total`，不是设备的 `energy`。平台不会在设备每次上报时
自动把电量汇总到资产 —— 所以你自建完场站/设备后，不重算，页面就是空的。

```bash
curl --noproxy '*' -s -X POST \
  -H "X-Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"days":60}' \
  http://127.0.0.1:8090/api/energy/asset-totals/rebuild
# → {"ok":true,"assetsWritten":15,"days":60}
```

- `days`：回溯天数，默认 60（够看本月 + 上月）
- 客户账号只能重算自己名下资产
- 只重写汇总，**不增删**任何业务数据
- 幂等：按同一批时间戳重写，不会产生重复点

**汇总口径**（与账单、台账、闲时能耗同一套）：

```
资产汇总 = 该资产子树内「最上层表计」的 energy 之和
最上层   = meterLevel 最小（1 进线 > 2 分项 > 3 回路）
按品种分 key：elec→energy_total，water→water_total，gas→gas_total，steam→steam_total
```

> 实测（2026-10-23）：`组织 67372.52` 恰好等于 `单相园区 1536.77 + 三相园区 65835.75`。
> 分毫不差说明口径没算重也没漏。

---

## 四、客户自建：照着演示数据建自己的

演示数据的结构就是**推荐结构**，照它建不会错。

### 4.1 层级关系

```
组织（可选，客户级费率维护层）
└─ 场站                          ← 一个物理站点，一进线户号
   ├─ 分项「照明」                 ← 用途维度
   │  ├─ 照明分项总表（meterLevel=2）
   │  │  └─ A栋照明回路（meterLevel=3）
   │  └─ …
   ├─ 分项「动力」
   │  ├─ 车间动力总表（meterLevel=2）
   │  │  ├─ 空压机组（meterLevel=3）
   │  │  └─ 车床组（meterLevel=3）
   │  └─ …
   └─ 1#进线总表（meterLevel=1）    ← 站点级费用只算这一级
```

### 4.2 建的顺序（不能颠倒）

| 顺序 | 建什么 | 在哪 | 关键字段 |
| --- | --- | --- | --- |
| 1 | 场站 | 组织与场站 | 名称、客户归属 |
| 2 | 分项 | 组织与场站 → 分项 | 挂到「用电分项」树下 |
| 3 | 设备 | 组织与场站 → 设备 | **必须设 `meterLevel`**（1/2/3） |
| 4 | 设备倍率 | 同上，设备面板 | `ctRatio` / `ptRatio`（见 4.4） |
| 5 | 拓扑 | 设备拓扑 | 选场站 → 拖设备连线 |
| 6 | **重算汇总** | 接口 / 客户列表初始化 | `{"days":60}` |

**为什么 `meterLevel` 不能漏**：它是「分层汇总」的唯一依据。
没设的话，总表 + 分表会被一起相加，同一度电算两遍（实测虚高 2.8 倍），
账单的基本电费也会每台都收。

### 4.3 计量层级怎么定

| 值 | 含义 | 判断方法 |
| --- | --- | --- |
| `1` | 进线总表（关口表） | 直接从电网/变压器进来的那块表，一个站点通常一块 |
| `2` | 分项总表 | 一个分项（照明/动力/空调）的总表 |
| `3` | 回路（末端） | 具体机台、具体楼层回路 |
| `0` / 未设 | 不参与分层 | **别留空**，会算错 |

配法两种：

```bash
# ① 页面：组织与场站 → 选中场站 → 设备面板 → 计量层级
# ② 接口
curl --noproxy '*' -s -X POST \
  -H "X-Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"deviceId":"<设备id>","meterLevel":1}' \
  http://127.0.0.1:8090/api/energy/device-config
```

### 4.4 倍率怎么填

| 字段 | 例 | 什么时候填 |
| --- | --- | --- |
| `ctRatio` | `200/5` | 有电流互感器（大表必填） |
| `ptRatio` | `10000/100` | 有电压互感器（高压计量） |
| `meterRatio` | `4000` | 只知道「这块表乘 40」，说不出变比 |
| `ratioApplied` | `true` | **RTU 已经乘过倍率**时必须设，否则再乘一次 |

计算系数 = `ratioApplied ? 1 : (CT/PT 都空 ? meterRatio : CT×PT)`
用量 = `(本期表底 − 上期表底) × 计算系数`

> 进线表的 CT/PT 都为空，基本可以确定是漏配了 —— 大表不可能没有互感器。

### 4.5 接 RTU

**通道二选一**：

```bash
# MQTT（推荐，设备侧）
地址  mqtt://<平台IP>:1883
用户  <设备访问令牌>
主题  v1/devices/me/telemetry
消息  {"U":220.1,"I":15.2,"P":3.3,"Ep":33705.42}

# HTTP
POST http://<平台IP>:8090/api/v1/<设备访问令牌>/telemetry
{"U":220.1,"I":15.2,"P":3.3,"Ep":33705.42}
```

厂家原始代号（`U`/`I`/`P`/`Ep`）会由规则链「电表Key标准化」翻成标准名
（`voltage_a` / `current_a` / `power_total` / `energy_reading`）。

**接完先验一条**：

```sql
-- 看设备有没有收到数据（期望 > 0 行，且键名是标准的）
SELECT kd.key AS 键, count(*) AS 点数,
       to_char(to_timestamp(max(t.ts)/1000) AT TIME ZONE 'Asia/Shanghai','MM-DD HH24:MI') AS 最后上报
FROM ts_kv t JOIN key_dictionary kd ON kd.key_id = t.key
WHERE t.entity_id = '<设备id>'
GROUP BY kd.key ORDER BY 点数 DESC;
```

- 只有 `U`/`I`/`P` → 标准化节点没生效（平台自检 → 一键修复初始化）
- 有标准键但点数很少 → 上报周期太长或设备离线

### 4.6 建完后的验收清单

| 检查 | 怎么看 | 期望 |
| --- | --- | --- |
| 设备有数据 | 上面的 SQL | 点数在涨，键名标准化 |
| 层级配齐 | 平台自检 / `device-config` | 每台表都有 `meterLevel` 1/2/3 |
| 倍率对 | `device-config` 返回的 `effectiveRatio` | 与现场表倍数一致 |
| 汇总有了 | 看板选场站 | 不是 `--` |
| 峰谷有数 | 峰谷分析选设备 | 五档相加 = 总量 |
| 台账有量 | 抄表功能 → 台账 | 用量 > 0 |

---

## 五、销户：合作结束或建错了

### 5.1 先看要删什么（永远先 dry-run）

```bash
cd ~/energy-app
bash scripts/10-cleanup-customer.sh --name '某某公司' --dry-run
```

输出：

```
✓ 预检：21 台设备全部属于「某某公司」
✓ 预检：客户名下实体租户归属一致

  即将删除：「某某公司」
 客户 ID    2b22b6d0-…
 场站 2   分项 12   拓扑图 2   资产合计 29
 设备       21
 看板副本   20
 用户       1
 遥测数据   126212 个数据点（一并删除）
------------------------------------------------------------
 影响面     仅此客户。其他客户 150 个实体（含租户级）已拍快照，
            删后逐项校验，不一致会报错退出。
------------------------------------------------------------
  此操作不可恢复。平台没有客户级回收站。
```

### 5.2 确认后执行

```bash
bash scripts/10-cleanup-customer.sh --name '某某公司' --yes
```

**定位客户的三种方式**（优先 `--id`，其次 `--name`，最后 `--email`）：

```bash
--id 2b22b6d0-ceaf-11f1-b87c-97366d49105d   # 最直接
--name '某某公司'                            # 名称完全匹配
--email customer2@company.com                # 邮箱前缀 / 反查用户表
```

**可选参数**：

| 参数 | 作用 |
| --- | --- |
| `--yes` / `-y` | 跳过输入 YES 确认（脚本化用） |
| `--keep-telemetry` | 保留遥测数据（只想删账号时用） |
| `--dry-run` | 只盘点不删除 |

### 5.3 它删什么

```
customer                     客户主体
tb_user                      客户账号
user_credentials             账号凭据
asset                        资产（场站/分项/组织/拓扑/账单）
device                       设备
device_credentials           设备令牌
relation / attribute_kv      关系与属性
dashboard                    复制给该客户的看板副本
custom_menu                  该客户的菜单（无其他客户引用时）
ts_kv                        遥测（默认删；--keep-telemetry 保留）
```

> ThingsBoard 删设备**不会**删遥测 —— 数据按 `entity_id` 存在分区表里。
> 所以脚本要在删客户**之前**先记下设备 id，删完再按 id 精确清 `ts_kv`。
> 不清理会一直占盘（实测 3 台已删设备残留 228 点）。

### 5.4 三道安全闸

脚本在动手前后各做一次校验，任何一项不符就退出码 2：

1. **预检**：待删设备必须真的都属于该客户（防止拿错 id 去删别人的遥测）
2. **预检**：目标不能是 null uuid（租户/系统实体）
3. **删后校验**：其他客户与租户级数据的指纹（实体数 + 全库 id 的 md5）必须逐位相同；
   遥测满足「删后总数 = 删前总数 − 实删点数」

实测（2026-10-23）：

```
✓ 遥测：目标以外 149252 → 149258 点（本次删了 127759 点，未波及他人）
✓ 遥测：目标设备已无残留（0 点）
✓ 隔离校验通过：其他客户 131 个实体与租户级数据均未受影响
```

### 5.5 销户之后

- 租户、租户管理员、租户级主数据（字典/费率模板/分时方案）**全部不动**
- 其他客户完全不受影响（有指纹校验作证）
- 客户名可以立刻复用（`tb_user` 和 `customer` 都已清干净）

---

## 六、出问题时先看这里

| 现象 | 最可能的原因 | 怎么办 |
| --- | --- | --- |
| 客户登录后场站/分项页全 `--` | 资产汇总遥测没写 | 调 `asset-totals/rebuild`（3.5 节） |
| 客户看不到菜单 | 菜单没绑定 | 客户列表 → 初始化演示数据，或平台自检 → 一键修复 |
| 客户点「生成演示数据」报 403 | 该按钮只给运营 | 正常。让运营在客户列表初始化 |
| 开户命令报「查不到客户」 | 客户名有空格/特殊字符 | 用 `--email` 或事后按 `--id` 清理 |
| 销户脚本退出码 2 | 删后指纹不一致 | **别重试**，先看它打印的差异项 |
| 清完演示数据后看板还空 | 清数据不等于重算 | 调 `asset-totals/rebuild` |
| 重复跑开户命令 | 幂等，会复用并**重置密码** | 注意：会把客户改过的密码改回初始值 |

---

## 七、速查：一条命令做一件事

```bash
cd ~/energy-app

# 开户
bash scripts/09-onboard-customer.sh --email x@y.com --password 'Pass@123' --name '某公司'

# 开户但不带演示数据（客户直接用自己的数据）
bash scripts/09-onboard-customer.sh --email x@y.com --password 'Pass@123' --no-demo

# 初始化演示数据（运营侧，也可以用客户列表的图标）
curl --noproxy '*' -s -X POST -H "X-Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d '{"customerId":"<id>"}' \
  http://127.0.0.1:8090/api/energy/demo-data

# 清除演示数据
curl --noproxy '*' -s -X DELETE -H "X-Authorization: Bearer $TOKEN" \
  "http://127.0.0.1:8090/api/energy/demo-data?customerId=<id>"

# 重算资产汇总（自建场站/设备后必做）
curl --noproxy '*' -s -X POST -H "X-Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d '{"days":60}' \
  http://127.0.0.1:8090/api/energy/asset-totals/rebuild

# 销户（先 dry-run）
bash scripts/10-cleanup-customer.sh --name '某公司' --dry-run
bash scripts/10-cleanup-customer.sh --name '某公司' --yes
```

---

## 八、新装平台后，第一家长什么样（完整走一遍）

```bash
# ── 1. 全新部署（会删库，谨慎）
bash shiyongshouce/downloads/deploy/docker-98-rebuild.sh \
  --admin admin@your.com --admin-pass 'Admin@123' \
  --tenant tenant@your.com --tenant-pass 'Tenant@123' --tenant-title '你的租户' \
  --customer demo@your.com --customer-pass 'Demo@123' --customer-title '演示客户' \
  --yes

# ── 2. 验收（这一步决定能不能交给客户）
cd ~/energy-app
bash scripts/03-verify.sh --base http://127.0.0.1:8090 \
  --tenant tenant@your.com --tenant-pass 'Tenant@123' \
  --customer demo@your.com --customer-pass 'Demo@123'
bash scripts/04-verify-data.sh
bash scripts/06-verify-e2e.sh --base http://127.0.0.1:8090 \
  --tenant tenant@your.com --tenant-pass 'Tenant@123' \
  --customer demo@your.com --customer-pass 'Demo@123'
bash scripts/08-verify-release.sh --base http://127.0.0.1:8090 \
  --tenant tenant@your.com --tenant-pass 'Tenant@123' \
  --customer demo@your.com --customer-pass 'Demo@123'
# 期望：18/0、35/0、53/0、74/74

# ── 3. 开第一家真客户
bash scripts/09-onboard-customer.sh \
  --email customer1@partner.com --password 'Cust@123456' --name '第一家合作企业'

# ── 4. 把账号发给客户，按第四节的顺序建自己的东西
```

**第 2 步不能跳。** 全新库如果验收不过，问题在平台不在客户 ——
交给客户只会变成「他们的数据不对」，排查成本翻十倍。
