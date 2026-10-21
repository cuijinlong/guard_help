# 全链路验收：从建场站到报表出数

> 这一页回答一个问题：**这套系统到底能不能用、数到底准不准。**
>
> 前面几页讲「怎么装、怎么开客户」。这一页讲「装完怎么验」——
> 不是点几下看看页面有没有崩，而是一条链走到底：客户自己建场站 → 建设备 →
> 上报数据 → 报表出数 → 数字对得上。
>
> 照着跑一遍约 5 分钟。跑完你就知道哪些环节是通的、哪些还有坑。

## 三个验收脚本，各管一段

| 脚本 | 验什么 | 什么时候跑 |
| --- | --- | --- |
| `03-verify.sh` | 接口能不能用、权限对不对 | 每次部署后 |
| `04-verify-data.sh` | 库里的数彼此对不对得上 | 每次部署后、改过演示数据后 |
| `06-verify-e2e.sh` | 从客户建场站到报表出数的完整业务闭环 | 上线前、改过业务代码后 |

三个都通过，才算这套系统真的能交付。

**在哪执行：【部署机 · 部署目录】**

```bash
cd ~/energy-app

bash scripts/03-verify.sh \
  --base http://127.0.0.1:8090 \
  --tenant tenant@your.com --tenant-pass 'Tenant@123' \
  --customer customer@your.com --customer-pass 'Customer@123' \
  --ai http://127.0.0.1:8090
```

```bash
bash scripts/04-verify-data.sh
```

```bash
bash scripts/06-verify-e2e.sh \
  --base http://127.0.0.1:8090 \
  --tenant tenant@your.com --tenant-pass 'Tenant@123' \
  --customer customer@your.com --customer-pass 'Customer@123'
```

**期望结果**：

```
03-verify.sh        通过 22 / 失败 0
04-verify-data.sh   通过 35 / 失败 0
06-verify-e2e.sh    通过 35 / 失败 0
```

---

## 06 脚本验的 9 个环节

跑的时候会一行行打 `✓`。下面是每一项在验什么、失败了意味着什么。

### 1. 组织管理

| 检查项 | 含义 | 失败说明 |
| --- | --- | --- |
| 租户管理员登录 | 账号密码与租户状态 | 密码错或租户被停用 |
| 客户已建立 | 租户下有客户 | 部署时没跑 `02-onboard.sh` |
| 客户可自建场站 | 客户能建设备 | `Customer User` 角色权限被改回只读 |
| 客户访问租户端点被拒 | 客户之间隔离 | 客户越权，是安全问题 |

**「客户可自建场站」这条最容易失败。** 上游 ThingsBoard 把客户用户定成纯只读，
客户一建场站就返回 `403`。本平台改成了受控写权限 —— 客户能管自己名下的东西，
但转不走、也不能冒充别人。

如果这条挂了，看[开租户与开客户](/admin/tenant)里的权限说明。

### 2. 设备管理：设备树 / 分组 / 拓扑

| 检查项 | 含义 |
| --- | --- |
| 设备总数 | 演示包至少 19 台 |
| 三级计量齐全 | 一级（进线）/ 二级（分项）/ 三级（末端）都有 |
| 维度容器齐备 | 每个场站在 4 个维度下都有同名容器 |
| 拓扑接口可用 | 能按场站画出设备连接图 |

**三级计量为什么必须验**：只有总表没有分表，分项分析、总分差、待机识别
全是空的；只有分表没有总表，算不出线损和未装表率。三级齐全，报表才有意义。

### 3. 数据上报：HTTP 与 MQTT

脚本会**真的发一条数据上去，再读回来**。

| 通道 | 怎么验 | 期望 |
| --- | --- | --- |
| HTTP | `POST /api/v1/{token}/telemetry` | 200，且读回值一致 |
| MQTT | 裸 socket 讲 MQTT 协议连 1883 | CONNACK 接受，且读回值一致 |

**为什么 MQTT 要用裸 socket**：部署机上不一定有 `mosquitto_pub`，
容器镜像里也没有。用 Python 直接构造 MQTT 报文，零依赖、能跑在任何机器上。

**上报失败最常见的原因**：设备接入通道没开。见[设备接入](/admin/device-access)。

### 4. 标准指标化存储

| 检查项 | 含义 |
| --- | --- |
| 核心参数键齐全 | `energy` / `energy_reading` / `power_total` / `voltage_a` 等能读回 |
| 电能参数字典 46 项 | 字典建全了 |
| 分时方案已预置 | 4 套（春秋/夏/冬 × 工作日/周末） |

**分时方案缺了会怎样**：峰谷报表不报错，但**所有电量都算成「平」**，
峰和谷永远是 0。这是最隐蔽的一种错 —— 页面有数，数也对，就是分不开。

### 5. 计算字段

验的是接口可用与可枚举。**0 个是合法的初始状态** —— 计算字段由客户自己建，
平台不预置，因为每个客户的折标系数、单位面积口径都不一样。

### 6. 规则链

验 Root 规则链存在且可读。规则链是数据处理的必经之路：
设备上报 → 规则链 → 存库。链坏了，数据进不了库。

### 7. 报警

验报警列表与报警规则接口可用。**没有报警是正常的** —— 新装系统还没触发过。
要验触发，见下面的「主动造一次报警」。

### 8. 报表可视化

| 检查项 | 为什么这么验 |
| --- | --- |
| 租户侧仪表板 ≥ 20 个 | 演示数据带 22 个模板 |
| **客户可见仪表板 ≥ 20 个** | 看板要复制到客户名下，不是只「分配」 |
| 各档合计 == 总量 | 分时电量不丢不重 |
| 命中了分时方案 | 不是全算平段 |
| 报表总量 == 原始遥测合计 | **这是「数准不准」的最终判据** |

**「客户可见仪表板」这条最容易漏。** 上游的「分配仪表板给客户」只写
`assigned_customers` 与 relation，客户查询走的却是 `dashboard.customer_id = 客户` ——
分配完客户还是看不到。本平台在开客户时把 22 个模板**复制一份**到客户名下，
客户看到的和租户看到的一样全，而且可以自己改而不影响别人。

**最后一条是全篇最重要的断言。**

报表按「表底差值」算电量，数据库里存的是逐小时增量。两者口径不同，
算出来必须一致；差 0.05 kWh 以上就说明有一环算错了。

脚本跑出来的样子：

```
✓ 分时报表：各档合计 == 总量（1474.19 kWh）
✓ 分时报表命中方案：春秋季工作日
✓ 报表总量 == 原始遥测合计（1474.19 vs 1474.19）
```

### 9. 虚拟设备与手工录入

| 检查项 | 含义 |
| --- | --- |
| 手工录入场站可枚举 | 有场站可选 |
| 虚拟设备已建 | 至少 1 台可填报的设备 |
| 月度值可回填 | 历史数据能读出来 |
| 单位识别正确 | 单相电表也认 kWh |

**虚拟设备是什么**：没装表、靠人工抄读的区域。它的月度值由人在页面上填，
不参与实时采集。演示包给了两台样板：空调虚拟表（电）、其他虚拟水表（水）。

---

## 主动造一次报警

报警链路默认没触发过，想看它工作，手工造一次：

**在哪执行：【任意机器 · 能访问平台】**

```bash
# 1. 取一台设备的 token
TOK=$(curl -s --noproxy '*' -X POST http://127.0.0.1:8090/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"tenant@your.com","password":"Tenant@123"}' \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])")

DEV=$(curl -s --noproxy '*' -H "X-Authorization: Bearer $TOK" \
  'http://127.0.0.1:8090/api/tenant/devices?pageSize=200&page=0' \
  | python3 -c "
import json,sys
for d in json.load(sys.stdin)['data']:
    if '进线总表' in d['name']: print(d['id']['id']); break")

AA=$(curl -s --noproxy '*' -H "X-Authorization: Bearer $TOK" \
  "http://127.0.0.1:8090/api/device/$DEV/credentials" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['credentialsId'])")

# 2. 上报一条越限数据（电压 260V，远超 235V 上限）
curl -s --noproxy '*' -X POST "http://127.0.0.1:8090/api/v1/$AA/telemetry" \
  -H 'Content-Type: application/json' \
  -d '{"voltage_a":260.0,"power_total":50.0}'

# 3. 等几秒看报警
sleep 5
curl -s --noproxy '*' -H "X-Authorization: Bearer $TOK" \
  'http://127.0.0.1:8090/api/alarms?pageSize=5&page=0&sortProperty=createdTime&sortOrder=DESC' \
  | python3 -m json.tool | head -20
```

**注意**：报警要靠规则链里的「Create Alarm」节点才会生成。
默认 Root 链只存数据不报警 —— 想让它报，得在规则链里加节点，
或者用平台的「报警规则」页面配一条。

---

## 数字对不上时，按这个顺序查

按「数据从哪来 → 中间经过什么 → 最后怎么算」倒推，不要一上来就怀疑报表。

### 第一步：库里到底有没有数

```bash
cd ~/energy-app

docker compose exec -T postgres psql -U postgres -d thingsboard -tAc "
SELECT k.key, count(*), min(to_timestamp(t.ts/1000)), max(to_timestamp(t.ts/1000))
FROM ts_kv t JOIN key_dictionary k ON k.key_id = t.key
JOIN device d ON d.id = t.entity_id
WHERE d.name LIKE '%进线总表%'
GROUP BY k.key ORDER BY 2 DESC LIMIT 10;"
```

**看到 `energy` 和 `energy_reading` 都有点**，说明采集链路通；
**一个都没有**，问题在上报端（见[设备接入](/admin/device-access)）。

### 第二步：增量与表底对不对

```bash
bash scripts/04-verify-data.sh
```

它逐点验三条：

```
energy_reading[n] − energy_reading[n−1] == energy[n]
energy_day[n]     == 当天 energy 累加
Σ(尖+峰+平+谷+深谷) == energy[n]
```

任一条不过，问题在数据写入端，不在报表。

### 第三步：报表口径对不对

```bash
bash scripts/06-verify-e2e.sh ...
```

它把报表总量与库内原始遥测合计直接相减，差值超过 0.05 就报失败。

### 常见原因对照

| 现象 | 原因 | 怎么办 |
| --- | --- | --- |
| 报表全 0，库里有数 | 时间窗口没对上 | 检查查询的起止时间 |
| 峰谷全是「平」 | 没有分时方案 | 检查 `tou_scheme` 是否预置 |
| 总分差是负数 | 表底被写成了增量 | 看[设备接入：上报哪些字段](/admin/device-access) |
| 报表比库多 | 报表重复计算了同一段 | 检查设备是否被多个分项包含 |
| 只有当天有数 | 演示数据只写了当天 | 重跑 `02-onboard.sh` 重建客户 |
| 单相表出现 B/C 相 | 上报端写了 0 | 单相表不该写 B/C 相键 |

---

## 反复迭代时怎么跑最快

改代码 → 重装 → 验收，这个循环会走很多次。用一条命令跑完全部：

**在哪执行：【构建机 · 仓库根目录】**

```bash
cd /你的仓库路径/iot-rule-engine

bash shiyongshouce/downloads/deploy/docker-98-rebuild.sh \
  --admin admin@your.com --admin-pass 'Admin@123' \
  --tenant tenant@your.com --tenant-pass 'Tenant@123' --tenant-title '星河集团' \
  --customer customer@your.com --customer-pass 'Customer@123' --customer-title '星河工业园' \
  --yes
```

它会依次做 8 件事，每步都打印进度：

```
1/8 卸载旧部署
2/8 重新组装部署目录（带最新 jar 与模板）
3/8 建库并导入部件
4/8 启动服务并创建管理员
5/8 建租户与客户（演示数据在这一步生成）
6/8 结构验收
7/8 数据验收
8/8 全链路验收
```

**耗时约 5–6 分钟**。跑完在部署目录留下 `DEPLOY-CREDENTIALS.txt`（权限 600），
里面是本次的账号密码和重装命令 —— 不用翻历史记录找。

**只在改了 `.env` 时**，不用整个重装：

```bash
cd ~/energy-app
docker compose --profile split up -d
```

**只改了后端代码、想保留数据**：

```bash
bash shiyongshouce/downloads/deploy/docker-98-rebuild.sh \
  ... --keep-data
```

它会先备份数据库，再换 jar 和模板、删租户重建。

---

## 验收通过之后

三个脚本全绿，说明：

- 客户能登录、能自建场站与设备、数据互相隔离
- RTU / 网关能通过 HTTP 和 MQTT 上报
- 数据按标准指标存进库，键名与字典对得上
- 分时、电能质量、分项这些报表能出数，且与原始数据一致
- 虚拟设备的手工填报能用

接下来是客户真实接入，见[新客户上线：按流程做](/admin/customer-data)。
