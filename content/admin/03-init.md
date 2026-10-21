# ③ 数据初始化

> 平台装好但没数据，等于不能用。这一页是**初始化清单**：要建什么、什么格式、
> 建完怎么验。
>
> **好消息：全部由一条命令自动完成**（部署第 4 步的 `02-onboard.sh`）。
> 这一页的价值在「验」和「补」—— 判断哪里缺了、怎么单独补。

---

## 一、初始化清单

按依赖顺序，从上到下：

| # | 初始化项 | 谁做的 | 数量 | 缺了会怎样 |
| --- | --- | --- | --- | --- |
| 1 | 系统管理员 | `docker-02-start.sh` | 1 个 | 进不去平台 |
| 2 | 租户 + 租户管理员 | `02-onboard.sh` | 1 + 1 | 无法隔离客户 |
| 3 | 能源参数字典 | 建租户时自动 | 4 品种 / 46 项电能参数 | 参数报表展开空白 |
| 4 | 设备档案 | 建租户时自动 | 7 个 | 建不了设备 |
| 5 | 厂商 / 设备型号 | 建租户时自动 | 17 / 9 | 设备表单下拉为空 |
| 6 | 分时时段方案 | 建租户时自动 | 4 套 | 峰谷报表全算「平」 |
| 7 | 客户 + 客户用户 | `02-onboard.sh` | 1 + 1 | — |
| 8 | 4 个维度根 + 场站容器 | 建客户时自动 | 4 根 / 2 场站 × 4 | 用能结构页空白 |
| 9 | 场站 | 建客户时自动 | 2 个 | 设备无处可挂 |
| 10 | 分项 | 建客户时自动 | 7 个 | 无法按用途统计 |
| 11 | 设备（三级计量） | 建客户时自动 | 11 电表 + 6 水气汽 + 2 温湿度 + 2 虚拟 | 报表无数据 |
| 12 | 演示遥测 | 建客户时自动 | 14 天 × 24 点 ≈ 11 万条 | 图表全空 |
| 13 | 仪表板 | 建客户时复制 | 20 个（模板 20） | 没有可视化 |
| 14 | 客户菜单 | 建客户时自动 | 7 个顶层项 | 左侧是 TB 原生菜单 |

**全部自动**。手工只需要在「补」的时候用。

---

## 二、验一遍（5 条命令）

**在哪执行：【部署机 · 部署目录】**

```bash
cd ~/energy-app

# 1. 账号都能登录
bash scripts/03-verify.sh \
  --base http://127.0.0.1:8090 \
  --tenant tenant@126.com --tenant-pass '12345678' \
  --customer customer@126.com --customer-pass '12345678'

# 2. 数据彼此对得上
bash scripts/04-verify-data.sh
```

**期望**：`通过 22 / 失败 0`、`通过 35 / 失败 0`。

```bash
# 3. 全链路（组织→设备→上报→存储→报表）
bash scripts/06-verify-e2e.sh \
  --base http://127.0.0.1:8090 \
  --tenant tenant@126.com --tenant-pass '12345678' \
  --customer customer@126.com --customer-pass '12345678'
```

**期望**：`通过 39 / 失败 0`。

```bash
# 4. 客户菜单
bash scripts/07-init-menu.sh \
  --tenant tenant@126.com --tenant-pass '12345678' \
  --customer customer@126.com --customer-pass '12345678' --dry-run
```

**期望**：打印出 7 个顶层菜单项（不落库）。

```bash
# 5. 库里到底有多少东西
docker compose exec -T postgres psql -U postgres -d thingsboard -tA -F' | ' -c "
SELECT '设备 '||count(*) FROM device
UNION ALL SELECT '资产 '||count(*) FROM asset
UNION ALL SELECT '仪表板 '||count(*) FROM dashboard
UNION ALL SELECT '遥测点 '||count(*) FROM ts_kv;"
```

**期望**：设备 21、资产 60+、仪表板 40（租户 20 + 客户 20）、遥测点 11 万+。

---

## 三、能源参数字典（字段定义）

这是**全平台的数据字典** —— 设备上报的键名必须与它一致，否则存不进去。

### 4 个品种

| 品种 | code | 单位 | 参数项 |
| --- | --- | --- | --- |
| 电能 | `elec` | kWh | 46 项 |
| 水表 | `water` | m³ | 3 项 |
| 燃气 | `gas` | m³ | 3 项 |
| 蒸汽 | `steam` | t | 3 项 |

### 电能 46 项（最常用的 20 项）

| 键名 | 含义 | 单位 | 聚合 |
| --- | --- | --- | --- |
| `energy` | 本小时用电量（**增量**） | kWh | SUM |
| `energy_reading` | 正向有功总电度（**累积**） | kWh | MAX |
| `energy_day` | 当日累计 | kWh | MAX |
| `energy_peak` / `flat` / `valley` / `deep` / `tip` | 分时电量 | kWh | SUM |
| `power_total` / `power_a` / `_b` / `_c` | 有功功率 | kW | AVG |
| `voltage_a` / `_b` / `_c` | 相电压 | V | AVG |
| `current_a` / `_b` / `_c` | 相电流 | A | AVG |
| `power_factor_total` | 总功率因数 | — | AVG |
| `reactive_power_total` | 总无功功率 | kVar | AVG |
| `frequency` | 频率 | Hz | AVG |
| `demand_max` | 最大需量 | kW | MAX |
| `load_rate` | 负载率 | % | AVG |
| `voltage_unbalance` | 电压不平衡度 | % | AVG |

完整 46 项在平台里看：租户登录 → 能源参数字典 → 电能。

### 水 / 燃气 / 蒸汽（各 3 项）

| 键名 | 含义 | 聚合 |
| --- | --- | --- |
| `energy` | 本小时用量（增量） | SUM |
| `power` | 瞬时流量 | AVG |
| `energy_reading` | 累积表底 | MAX |

### ⚠ 三条铁律（现场接入 90% 的错误来源）

```
energy          本小时用了多少    1.20  1.35  0.98     ← 增量，不是表底
energy_reading  表上显示的总数    33705.42  33706.77  ← 只增不减
相邻两点之差必须相等：energy_reading[n] − energy_reading[n−1] == energy[n]
```

写成「energy = 表底」→ 月报表算出几十万度。

---

## 四、设备档案（7 个）

| 档案名 | 用途 | 认作表计 |
| --- | --- | --- |
| 单相电能表 | 1P2W，照明/插座回路 | ✓ |
| 电能表 | 3P4W，车间动力 | ✓ |
| 水表 | — | ✓ |
| 燃气表 | — | ✓ |
| 蒸汽表 | — | ✓ |
| 温湿度变送器 | 非计量 | ✗ |
| 网关 | RTU 网关本体 | ✗ |

**建档时必填 `isMeter`**：只有 `isMeter=true` 的档案才会被抄表、参数报表、
分项统计识别。建错了表现为「设备在，报表空」。

---

## 五、分时时段方案（4 套）

没这套配置，峰谷报表**不报错但全算「平」** —— 页面有数，数也对，就是分不开。

| 方案名 | season | dayType |
| --- | --- | --- |
| 春秋季工作日 | `spring_autumn` | `weekday` |
| 夏季工作日 | `summer` | `weekday` |
| 冬季工作日 | `winter` | `weekday` |
| 春秋季周末 | `spring_autumn` | `weekend` |

每套含 `blocks`：`[{type, start, end}]`，档位 `tip/peak/flat/valley/deep`。

**时段必须首尾相接、无空洞**（`00:00` 到 `24:00` 全覆盖）。有空洞的小时会被归「平」。

---

## 六、演示数据的具体内容

### 场站一：单相园区（纯单相）

```
单相园区·星河工业园
├─ 单相园-1#进线总表            L1  单相 20kW
├─ 照明分项
│   ├─ 单相园-照明分项总表       L2
│   └─ 单相园-A栋照明回路        L3
├─ 插座分项
│   ├─ 单相园-插座分项总表       L2
│   └─ 单相园-A栋插座回路        L3
├─ 空调分项
│   └─ 单相园-空调虚拟表         （手工填报，当年逐月值）
├─ 给排水分项 → 单相园-生活水表
├─ 炊事分项   → 单相园-食堂燃气表
├─ 蒸汽分项   → 单相园-食堂蒸汽表
└─ 单相园-温湿度-办公区
```

### 场站二：三相园区（单相 + 三相混供）

```
三相园区·星河工业园
├─ 三相园-1#进线总表            L1  三相 630kW
├─ 动力分项
│   ├─ 三相园-车间动力总表       L2
│   ├─ 三相园-空压机组           L3  间歇运行、C 相偏高
│   └─ 三相园-车床组             L3  连续生产、三相平衡
├─ 照明分项
│   ├─ 三相园-办公区总表         L2  单相
│   └─ 三相园-办公照明回路       L3
├─ 给排水分项 → 三相园-生产水表
├─ 蒸汽分项   → 三相园-生产蒸汽表
├─ 锅炉分项   → 三相园-锅炉燃气表
├─ 其他分项   → 三相园-其他虚拟水表（手工填报）
└─ 三相园-温湿度-车间
```

**为什么两个场站**：单相表画不出分相电压/电流（电能质量页会空）；
只有三相表，现场大量单相回路又对不上。

**为什么电表要三级**：只有总表没有分表，分项分析和总分差全是空的；
只有分表没有总表，算不出线损和未装表率。

**设备名都带场站前缀**（`单相园-` / `三相园-`）：设备名在租户内唯一，
两个场站都会有一张「1#进线总表」，不加前缀第二张表会撞唯一索引，
整个演示包在这里中断。

**数据自洽**（每台表每个点都成立）：

```
I_φ = P_φ×1000/(U_φ×cosφ_φ)
S_φ = P_φ/cosφ_φ
Q_φ = √(S_φ²−P_φ²)
P_total = P_a + P_b + P_c          （最后一相用减法兜底）
cosφ_total = P_total / S_total     （不是简单平均）
energy_reading[n] = base + Σenergy[0..n]
Σ(尖峰平谷深谷) = energy
上级表 = 下级之和 × (1+未装表率) × (1+线损率)
```

---

## 六之二、左侧菜单

菜单由**后端初始化时自动装**，两套：租户一份、客户一份。都是自定义菜单
（`custom_menu` 表），不依赖前端构建。

### 客户菜单（13 项）

```
能耗概览                          ← 登录落地页
能耗查询 ▾   实时能耗 / 历史能耗 / 抄表功能
能耗分析 ▾   峰谷分析 / 分项能耗 / 区域能耗 / 用能账单
综合报表 ▾   基础报表 / 手工填报 / 参数报表
能耗优化 ▾   闲时能耗 / 负载预测 / 用能建议 / 用能质量
告警中心 ▾   告警列表
设备运维 ▾   设备管理 / 设备分组 / 设备拓扑
综合能耗
能源流向
电能质量
盘查报告
节能记录
组织                              → /sites
```

**刻意不要的东西**（都是判断过的，别加回来）：

| 不要 | 原因 |
| --- | --- |
| 「首页」独立菜单项 | 落地页已经是「能耗概览」，再列一项是重复 |
| 「仪表板」列表 | TB 的建模入口，客户只需要按用途分好的菜单 |
| 「客户能源档案」 | 租户侧视图，客户看不到别人的档案 |
| 「基础配置中心」 | 时段方案/费率/倍率都是租户定的，客户不改 |
| 「闲时能耗配置」菜单项 | 入口在「闲时能耗」看板右上角的配置按钮 |
| 「我的账单模板」 | 模板由租户定，客户只看「我的账单」 |

### 租户菜单（18 项）

```
首页
能源管理 ▾   客户能源档案 / 基础配置中心
告警中心 ▾   告警列表 / 告警规则
模型训练平台                       → /ngxai/
（以下沿用前端默认菜单）
iot_hub / ai_solution_creator / monitor / entities /
customers_and_users / integrations_center / data_processing /
white_labeling / resources / security_settings /
platform_section / edge_management / trendz_analytics / mobile_center
```

租户展开 `Platform` 能看到能源配置的 7 个页面：
组织与场站、设备分组、厂商与型号、场站告警规则、参数报表、抄表管理、闲时能耗配置
（这一组在前端 `menu.models.ts` 里平铺进 `platform_section`）。

### 两条硬限制

**1. 最多两层。** 侧边栏的 `menu-toggle` 把每个子项一律交给 `menu-link` 渲染，
而 `menu-link` 没有展开能力 —— 第三层点不动或跳到 undefined 路径。

**2. 客户菜单的绑定靠 `customer.customMenuId`，不是菜单的 `customer_id`。**

```
custom_menu.customer_id  →  恒为 NULL_UUID（NOT NULL 约束）
customer.custom_menu_id  →  指向具体菜单 id
```

客户登录时 `findCustomerHierarchyCustomMenu` 的查找顺序：

1. 按 `customer_id` 找默认客户菜单 → 命不中（是 NULL_UUID）
2. 读 `customer.customMenuId` 按 id 找 → **这一步对上才行**
3. 都没有 → 退回 TB 原生菜单

只建菜单不写 `customMenuId`，客户永远看到默认菜单。

---

## 六之三、垃圾数据已剔除

初始化模板里曾有两块没用的看板，已删除。**新部署不会再出现**：

| 删掉的模板 | 曾叫什么 | 为什么删 |
| --- | --- | --- |
| `verify_sankey.json` | 验证·能源流向 | 与 `sankey_flow.json`（能源流向）部件完全相同，是开发时的测试副本 |
| `bill_template.json` | 我的账单模板 | 只有 1 个 `billing_list` 部件，是 `my_bills.json`（4 个部件）的残缺子集 |

现存 **20 个**看板模板。判断标准：

- 与别的看板部件完全相同 → 副本，删
- 部件数明显少于同类看板、又没有独有功能 → 残缺版本，删
- 只有租户用得上（租户配给客户的）→ 保留，但不进客户菜单

**部件 FQN 前缀也修过**：模板里曾写 `tenant.energy_management.*`，
但部件实际建在系统租户（NULL_UUID）下，必须用 `system.` 前缀。
前缀错了前端会报「加载部件配置时出现问题。关联的 部件类型可能已被移除。」
现在 34 种部件类型全部用 `system.` 前缀，逐个实测都能加载。

---

## 七、缺了怎么补

### 补客户菜单

```bash
cd ~/energy-app
bash scripts/07-init-menu.sh \
  --tenant tenant@126.com --tenant-pass '12345678' \
  --customer customer@126.com --customer-pass '12345678'
```

### 补演示数据（不删租户）

```bash
TOK=$(curl -s --noproxy '*' -X POST http://127.0.0.1:8090/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"tenant@126.com","password":"12345678"}' \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])")

# 删客户（连带演示数据）
CID=$(curl -s --noproxy '*' -H "X-Authorization: Bearer $TOK" \
  'http://127.0.0.1:8090/api/customers?pageSize=5&page=0' \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['data'][0]['id']['id'])")
curl -s --noproxy '*' -X DELETE -H "X-Authorization: Bearer $TOK" \
  "http://127.0.0.1:8090/api/customer/$CID"

# 重建（会自动带新演示数据）
bash scripts/02-onboard.sh ...（参数同上）
```

> 这一招只补**客户级**数据。租户级的字典、档案、厂商、分时方案**不会**重建。

### 缺租户级数据（字典/档案/厂商/分时）

只能删租户重建：

```bash
TOK=$(curl -s --noproxy '*' -X POST http://127.0.0.1:8090/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"langmen@126.com","password":"CJLqh@163"}' \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])")

TID=$(curl -s --noproxy '*' -H "X-Authorization: Bearer $TOK" \
  'http://127.0.0.1:8090/api/tenants?pageSize=5&page=0' \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['data'][0]['id']['id'])")
curl -s --noproxy '*' -X DELETE -H "X-Authorization: Bearer $TOK" \
  "http://127.0.0.1:8090/api/tenant/$TID"
```

然后重跑 `02-onboard.sh`。

**删之前先备份**：

```bash
docker compose exec -T postgres pg_dump -U postgres thingsboard \
  | gzip > ~/backup-$(date +%F-%H%M).sql.gz
```

### 全都要重来

```bash
bash shiyongshouce/downloads/deploy/docker-98-rebuild.sh ... --yes
```

见[② 平台部署](/admin/deploy)的「改代码后怎么更新」。

---

## 八、用真数据替换演示数据

演示数据的作用是「让你立刻看到所有功能」。正式上线前应该：

1. **删掉演示实体**：客户 → 场站 → 逐个删（演示实体都带 `demo=true` 标记）
2. **建真实场站**：客户登录 → 组织与场站 → 新建
3. **建分项**：场站 → 用能结构 → 加分项
4. **建设备**：设备管理 → 新增，选对档案、挂对分项、标 `meterLevel`
5. **配 RTU**：拿到每台表的 Access Token，配到网关，见[④ 设备接入](/admin/device-access)
6. **等数据**：实时数据进来后，报表自动出数

**不想手工建**：客户填两张 CSV（场站、设备），用导入脚本：

```bash
bash scripts/05-import-customer-data.py --dir ./客户数据
```

模板在 `templates/` 下：`场站.csv`、`设备.csv`、`点位.csv`。
